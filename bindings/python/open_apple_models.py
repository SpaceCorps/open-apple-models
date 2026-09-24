"""Python binding for open-apple-models (ctypes over the OpenAppleModelsFFI C ABI).

Drive on-device Apple Foundation Models agents from Python, with real tool
calls executed by your code::

    import asyncio
    from open_apple_models import Bridge

    async def main():
        async with Bridge() as bridge:
            @bridge.tool("open_gate", "Open a named gate.",
                         {"type": "object", "properties": {"gate": {"type": "string"}}, "required": ["gate"]})
            async def open_gate(args):
                return {"opened": True, "gate": args["gate"]}

            guard = await bridge.create_session(
                instructions="You are a castle guard. Use tools to act.",
                tools=["open_gate"], options={"toolChoice": "required"})
            reply = await guard.respond("Open the north gate!", on_text=lambda d: print(d, end=""))
            print()
            print(reply["toolCalls"])

    asyncio.run(main())

The library is located via, in order: the ``library`` argument, the
``OAM_LIBRARY`` environment variable, the repository's ``.build/release`` and
``.build/debug`` folders, then the system search path. Build it with
``swift build -c release --product OpenAppleModelsFFI``.

Requires Python 3.9+. Protocol reference: docs/PROTOCOL.md.
"""

import asyncio
import ctypes
import ctypes.util
import inspect
import itertools
import json
import os
import threading
from typing import Any, Awaitable, Callable, Dict, Iterable, List, Optional, Union

__all__ = ["Bridge", "BridgeError", "Session", "ToolError", "ToolContext", "find_library", "load_library"]

_CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)


# --------------------------------------------------------------------------------------------
# Library loading
# --------------------------------------------------------------------------------------------

def find_library(path: Optional[str] = None) -> str:
    """Returns the path of libOpenAppleModelsFFI.dylib (see module docs for the search order)."""
    candidates: List[str] = []
    if path:
        candidates.append(path)
    if os.environ.get("OAM_LIBRARY"):
        candidates.append(os.environ["OAM_LIBRARY"])
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    for configuration in ("release", "debug"):
        candidates.append(os.path.join(root, ".build", configuration, "libOpenAppleModelsFFI.dylib"))
    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate
    found = ctypes.util.find_library("OpenAppleModelsFFI")
    if found:
        return found
    raise OSError(
        "libOpenAppleModelsFFI.dylib not found. Build it with "
        "'swift build -c release --product OpenAppleModelsFFI' or set OAM_LIBRARY.")


_libraries: Dict[str, ctypes.CDLL] = {}
_libraries_lock = threading.Lock()


def load_library(path: Optional[str] = None) -> ctypes.CDLL:
    """Loads the C library (once per path) and declares its signatures."""
    resolved = find_library(path)
    with _libraries_lock:
        if resolved in _libraries:
            return _libraries[resolved]
        lib = ctypes.CDLL(resolved)  # CDLL releases the GIL during calls, which oam_bridge_destroy needs.
        lib.oam_bridge_create.argtypes = [_CALLBACK, ctypes.c_void_p]
        lib.oam_bridge_create.restype = ctypes.c_void_p
        lib.oam_bridge_send.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.oam_bridge_send.restype = ctypes.c_int
        lib.oam_bridge_destroy.argtypes = [ctypes.c_void_p]
        lib.oam_bridge_destroy.restype = None
        lib.oam_version.argtypes = []
        lib.oam_version.restype = ctypes.c_char_p
        lib.oam_call_blocking.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        lib.oam_call_blocking.restype = ctypes.c_void_p  # freed with oam_string_free, so keep the raw pointer
        lib.oam_string_free.argtypes = [ctypes.c_void_p]
        lib.oam_string_free.restype = None
        _libraries[resolved] = lib
        return lib


# --------------------------------------------------------------------------------------------
# Errors and tool helpers
# --------------------------------------------------------------------------------------------

class BridgeError(Exception):
    """A JSON-RPC error response. ``name`` is the stable string code (``data.code``),
    e.g. ``"session_not_found"``, ``"guardrail_violation"``, ``"cancelled"``."""

    def __init__(self, code: int, message: str, data: Any = None):
        name = data.get("code") if isinstance(data, dict) else None
        super().__init__("{} [{}{}]".format(message, code, " " + name if name else ""))
        self.code = code
        self.message = message
        self.data = data

    @property
    def name(self) -> Optional[str]:
        return self.data.get("code") if isinstance(self.data, dict) else None

    @classmethod
    def from_json(cls, error: Dict[str, Any]) -> "BridgeError":
        return cls(int(error.get("code", -32603)), str(error.get("message", "Unknown error")), error.get("data"))


class ToolError(Exception):
    """Raise from a tool handler to report a failure the model sees (``isError: true``)."""


class ToolContext:
    """Where a tool call came from; passed to handlers that accept a second argument."""

    def __init__(self, params: Dict[str, Any]):
        call = params.get("call", {})
        self.call_id: str = call.get("id", "")
        self.name: str = call.get("name", "")
        self.arguments: Dict[str, Any] = call.get("arguments") or {}
        self.session: Optional[str] = params.get("session")
        self.request_id: Any = params.get("requestId")
        self.params = params

    def __repr__(self) -> str:
        return "ToolContext(name={!r}, session={!r}, call_id={!r})".format(self.name, self.session, self.call_id)


ToolHandler = Callable[..., Union[Any, Awaitable[Any]]]


class _Tool:
    def __init__(self, name: str, description: str, parameters: Optional[Dict[str, Any]],
                 handler: ToolHandler, timeout: Optional[float]):
        self.name = name
        self.description = description
        self.parameters = parameters or {"type": "object", "properties": {}}
        self.handler = handler
        self.timeout = timeout
        try:
            self.wants_context = len(inspect.signature(handler).parameters) >= 2
        except (TypeError, ValueError):
            self.wants_context = False

    def definition(self) -> Dict[str, Any]:
        definition = {"name": self.name, "description": self.description,
                      "parameters": self.parameters, "execution": "client"}
        if self.timeout is not None:
            definition["timeoutSeconds"] = self.timeout
        return definition


# --------------------------------------------------------------------------------------------
# Bridge
# --------------------------------------------------------------------------------------------

class Bridge:
    """One bridge instance (one ``oam_bridge``), bound to an asyncio event loop.

    Messages from the bridge arrive on a background thread and are handed to the
    loop with ``call_soon_threadsafe``; every future, event handler and tool
    handler runs on the loop's thread.
    """

    def __init__(self, library: Optional[str] = None, loop: Optional[asyncio.AbstractEventLoop] = None):
        self._lib = load_library(library)
        self._loop = loop
        self._ids = itertools.count(1)
        self._pending: Dict[str, "asyncio.Future[Any]"] = {}
        self._event_handlers: Dict[Any, Callable[[Dict[str, Any]], None]] = {}
        self._notification_handlers: Dict[str, List[Callable[[Dict[str, Any]], None]]] = {}
        self._tools: Dict[str, _Tool] = {}
        self._tool_tasks: Dict[str, "asyncio.Task[None]"] = {}
        self._closed = False
        self._callback = _CALLBACK(self._on_message)  # keep a reference for the bridge's lifetime
        handle = self._lib.oam_bridge_create(self._callback, None)
        if not handle:
            raise OSError("oam_bridge_create failed")
        self._handle = ctypes.c_void_p(handle)

    # ---- lifecycle ---------------------------------------------------------------------------

    @property
    def version(self) -> str:
        return self._lib.oam_version().decode()

    def close(self) -> None:
        """Destroys the bridge: cancels running turns; no messages arrive afterwards."""
        if self._closed:
            return
        self._closed = True
        self._lib.oam_bridge_destroy(self._handle)
        error = BridgeError(-32023, "The bridge was closed.", {"code": "shut_down"})
        for future in list(self._pending.values()):
            if not future.done():
                future.set_exception(error)
        self._pending.clear()
        for task in list(self._tool_tasks.values()):
            task.cancel()

    async def __aenter__(self) -> "Bridge":
        self._bind_loop()
        return self

    async def __aexit__(self, *exc: Any) -> None:
        self.close()

    def __enter__(self) -> "Bridge":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def _bind_loop(self) -> asyncio.AbstractEventLoop:
        if self._loop is None:
            self._loop = asyncio.get_running_loop()
        return self._loop

    # ---- low-level messaging -----------------------------------------------------------------

    def send_message(self, message: Dict[str, Any]) -> None:
        """Sends one raw JSON-RPC message."""
        if self._closed:
            raise BridgeError(-32023, "The bridge was closed.", {"code": "shut_down"})
        line = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        status = self._lib.oam_bridge_send(self._handle, line)
        if status != 0:
            raise OSError("oam_bridge_send failed with status {}".format(status))

    def notify(self, method: str, params: Optional[Dict[str, Any]] = None) -> None:
        """Sends a notification (no response)."""
        message: Dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send_message(message)

    async def request(self, method: str, params: Optional[Dict[str, Any]] = None,
                      on_event: Optional[Callable[[Dict[str, Any]], None]] = None) -> Any:
        """Sends a request and awaits its result (raises :class:`BridgeError` on error).

        ``on_event`` receives the ``params`` of every notification tagged with this
        request's id (``session/event`` and extension event methods).
        """
        loop = self._bind_loop()
        request_id = "py-{}".format(next(self._ids))
        future: "asyncio.Future[Any]" = loop.create_future()
        self._pending[request_id] = future
        if on_event is not None:
            self._event_handlers[request_id] = on_event
        message: Dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        try:
            self.send_message(message)
            return await future
        finally:
            self._pending.pop(request_id, None)
            self._event_handlers.pop(request_id, None)

    def call_blocking(self, method: str, params: Optional[Dict[str, Any]] = None, timeout: float = 30.0) -> Any:
        """Synchronous request/response via ``oam_call_blocking`` (no asyncio needed).

        Do not use for sessions with tools: tool/call requests need the event loop.
        """
        message: Dict[str, Any] = {"jsonrpc": "2.0", "id": 0, "method": method}
        if params is not None:
            message["params"] = params
        raw = self._lib.oam_call_blocking(self._handle, json.dumps(message).encode("utf-8"), int(timeout * 1000))
        if not raw:
            raise OSError("oam_call_blocking failed")
        try:
            response = json.loads(ctypes.string_at(raw).decode("utf-8"))
        finally:
            self._lib.oam_string_free(raw)
        if "error" in response:
            raise BridgeError.from_json(response["error"])
        return response.get("result")

    def on_notification(self, method: str, handler: Callable[[Dict[str, Any]], None]) -> None:
        """Registers a handler for every notification with ``method`` (receives its params)."""
        self._notification_handlers.setdefault(method, []).append(handler)

    # ---- tools -------------------------------------------------------------------------------

    def tool(self, name: str, description: str, parameters: Optional[Dict[str, Any]] = None,
             timeout: Optional[float] = None) -> Callable[[ToolHandler], ToolHandler]:
        """Decorator registering a client tool handler.

        The handler receives the arguments dict (and, if it accepts a second
        parameter, a :class:`ToolContext`). It may be sync or async and returns a
        string (text output) or any JSON value; raising :class:`ToolError` (or any
        exception) reports an error the model can react to.
        """
        def register(handler: ToolHandler) -> ToolHandler:
            self.register_tool(name, description, parameters, handler, timeout)
            return handler
        return register

    def register_tool(self, name: str, description: str, parameters: Optional[Dict[str, Any]],
                      handler: ToolHandler, timeout: Optional[float] = None) -> None:
        self._tools[name] = _Tool(name, description, parameters, handler, timeout)

    def tool_definitions(self, names: Optional[Iterable[str]] = None) -> List[Dict[str, Any]]:
        """Definitions for ``session/create``'s ``tools`` (all registered tools by default)."""
        selected = list(names) if names is not None else list(self._tools)
        missing = [name for name in selected if name not in self._tools]
        if missing:
            raise KeyError("Unknown tools: {}".format(", ".join(missing)))
        return [self._tools[name].definition() for name in selected]

    # ---- sessions ----------------------------------------------------------------------------

    async def initialize(self, client_name: str = "python") -> Dict[str, Any]:
        return await self.request("initialize", {"client": {"name": client_name, "version": self.version},
                                                 "protocolVersion": "1.0"})

    async def create_session(self, instructions: Optional[str] = None,
                             tools: Optional[Iterable[Union[str, Dict[str, Any]]]] = None,
                             options: Optional[Dict[str, Any]] = None,
                             model: Any = None, history: Optional[Dict[str, Any]] = None,
                             session: Optional[str] = None) -> "Session":
        """Creates a session. ``tools`` lists registered tool names or raw definitions."""
        params: Dict[str, Any] = {}
        if session is not None:
            params["session"] = session
        if instructions is not None:
            params["instructions"] = instructions
        if tools is not None:
            params["tools"] = [self.tool_definitions([tool])[0] if isinstance(tool, str) else tool for tool in tools]
        if options is not None:
            params["options"] = options
        if model is not None:
            params["model"] = model
        if history is not None:
            params["history"] = history
        result = await self.request("session/create", params)
        return Session(self, result["session"], result.get("warnings", []))

    # ---- incoming ----------------------------------------------------------------------------

    def _on_message(self, line: bytes, _user_data: Any) -> None:
        # Runs on a bridge thread. Never raise into C.
        try:
            message = json.loads(line.decode("utf-8"))
            loop = self._loop
            if loop is None or loop.is_closed():
                return
            loop.call_soon_threadsafe(self._dispatch, message)
        except Exception:  # pragma: no cover - defensive
            pass

    def _dispatch(self, message: Dict[str, Any]) -> None:
        method = message.get("method")
        if method is not None and "id" in message:
            if method == "tool/call":
                self._start_tool_call(message)
            else:
                self._reply_error(message["id"], -32601, "The client does not implement '{}'.".format(method))
            return
        if method is not None:
            params = message.get("params") or {}
            if method == "tool/cancel":
                task = self._tool_tasks.pop(str(params.get("id")), None)
                if task is not None:
                    task.cancel()
            handler = self._event_handlers.get(params.get("requestId")) if isinstance(params, dict) else None
            if handler is not None and method != "tool/cancel":
                self._safely(handler, params)
            for listener in self._notification_handlers.get(method, []):
                self._safely(listener, params)
            return
        future = self._pending.get(str(message.get("id")))
        if future is None or future.done():
            return
        if "error" in message:
            future.set_exception(BridgeError.from_json(message["error"]))
        else:
            future.set_result(message.get("result"))

    @staticmethod
    def _safely(handler: Callable[[Dict[str, Any]], None], params: Dict[str, Any]) -> None:
        try:
            handler(params)
        except Exception as error:  # an event handler bug must not break the bridge
            print("open_apple_models: event handler raised {!r}".format(error))

    def _start_tool_call(self, message: Dict[str, Any]) -> None:
        request_id = message["id"]
        task = asyncio.ensure_future(self._run_tool(request_id, message.get("params") or {}))
        self._tool_tasks[str(request_id)] = task
        task.add_done_callback(lambda _: self._tool_tasks.pop(str(request_id), None))

    async def _run_tool(self, request_id: Any, params: Dict[str, Any]) -> None:
        context = ToolContext(params)
        tool = self._tools.get(context.name)
        if tool is None:
            self._reply_error(request_id, -32601, "No handler is registered for tool '{}'.".format(context.name))
            return
        try:
            value = tool.handler(context.arguments, context) if tool.wants_context else tool.handler(context.arguments)
            if inspect.isawaitable(value):
                value = await value
            result: Dict[str, Any] = {"output": value if value is not None else ""}
        except asyncio.CancelledError:
            return  # the bridge sent tool/cancel; it no longer wants the output
        except Exception as error:
            result = {"output": str(error) or type(error).__name__, "isError": True}
        if not self._closed:
            self.send_message({"jsonrpc": "2.0", "id": request_id, "result": result})

    def _reply_error(self, request_id: Any, code: int, text: str) -> None:
        if not self._closed:
            self.send_message({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": text}})


class Session:
    """A bridge session (an agent with its own conversation)."""

    def __init__(self, bridge: Bridge, session_id: str, warnings: List[str]):
        self.bridge = bridge
        self.id = session_id
        self.warnings = warnings

    def __repr__(self) -> str:
        return "Session({!r})".format(self.id)

    async def respond(self, prompt: str, schema: Optional[Dict[str, Any]] = None,
                      on_text: Optional[Callable[[str], None]] = None,
                      on_event: Optional[Callable[[Dict[str, Any]], None]] = None,
                      **policy: Any) -> Dict[str, Any]:
        """Runs a turn. ``on_text`` receives text deltas; ``on_event`` every event dict.

        Extra keyword arguments are passed through (``toolChoice``, ``maxToolRounds``,
        ``maxToolCalls``, ``enabledTools``).
        """
        params: Dict[str, Any] = {"session": self.id, "prompt": prompt}
        if schema is not None:
            params["schema"] = schema
        params.update(policy)
        handler = None
        if on_text is not None or on_event is not None:
            params["stream"] = True

            def handler(notification: Dict[str, Any]) -> None:
                event = notification.get("event", {})
                if on_event is not None:
                    on_event(event)
                if on_text is not None and event.get("type") == "text":
                    on_text(event["text"] if event.get("isReset") else event.get("delta", ""))
        return await self.bridge.request("session/respond", params, on_event=handler)

    async def cancel(self) -> int:
        return (await self.bridge.request("session/cancel", {"session": self.id}))["cancelled"]

    async def reset(self) -> None:
        await self.bridge.request("session/reset", {"session": self.id})

    async def delete(self) -> None:
        await self.bridge.request("session/delete", {"session": self.id})

    async def transcript(self) -> Dict[str, Any]:
        return (await self.bridge.request("session/transcript", {"session": self.id}))["transcript"]

    async def set_instructions(self, instructions: Optional[str]) -> None:
        await self.bridge.request("session/setInstructions", {"session": self.id, "instructions": instructions})

    async def set_context_note(self, note: Optional[str]) -> None:
        await self.bridge.request("session/setContextNote", {"session": self.id, "note": note})

    async def set_tools(self, tools: Iterable[Union[str, Dict[str, Any]]]) -> List[str]:
        definitions = [self.bridge.tool_definitions([tool])[0] if isinstance(tool, str) else tool for tool in tools]
        result = await self.bridge.request("session/setTools", {"session": self.id, "tools": definitions})
        return result.get("warnings", [])

    async def compact(self, keep_recent_turns: int = 2) -> Optional[str]:
        result = await self.bridge.request("session/compact", {"session": self.id, "keepRecentTurns": keep_recent_turns})
        return result.get("summary")
