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

Game methods (NPCs, decisions, world state, content) have their own helpers::

    world = await bridge.create_world({"player": {"name": "Aria", "gold": 60}}, world="village")
    gorm = await bridge.create_npc({"name": "Gorm", "role": "the village blacksmith"},
                                   tools=["check_inventory"], world=world.id,
                                   options={"groundingTool": "check_inventory"})
    turn = await gorm.talk("Got any iron swords?", on_line=print)  # the line so far, as it streams
    print(turn["emotion"], turn["playerOptions"])
    decision = await bridge.decide("The goblin has 3 HP left.", ["attack", "flee", "beg"], actor="gorm")

The library is located via, in order: the ``library`` argument, the
``OAM_LIBRARY`` environment variable, the repository's ``.build/release`` and
``.build/debug`` folders, then the system search path. Build it with
``swift build -c release --product OpenAppleModelsFFI``.

Requires Python 3.9+. Protocol reference: docs/PROTOCOL.md.
"""

import asyncio
import atexit
import contextlib
import ctypes
import ctypes.util
import datetime
import decimal
import enum
import inspect
import itertools
import json
import os
import threading
from typing import Any, Awaitable, Callable, Dict, Iterable, Iterator, List, Optional, Union

__all__ = ["Bridge", "BridgeError", "NPC", "Session", "ToolError", "ToolContext", "World",
           "find_library", "load_library"]

_CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)

# Distinguishes "not passed" from an explicit None (which is sent as JSON null).
_UNSET: Any = object()


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

# Bridges not yet closed. The native side holds a raw pointer to each bridge's
# ctypes callback, so an open Bridge must never be garbage collected: keep it
# here until close(), and destroy leftovers before the interpreter shuts down.
_live_bridges: Dict[int, "Bridge"] = {}
_live_lock = threading.Lock()


def _close_all_bridges() -> None:
    with _live_lock:
        bridges = list(_live_bridges.values())
    for bridge in bridges:
        bridge._destroy_native()


atexit.register(_close_all_bridges)


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
# JSON encoding
# --------------------------------------------------------------------------------------------

def _json_default(value: Any) -> Any:
    """Converts common non-JSON Python values (sets, Decimal, numpy scalars and arrays,
    dates, enums, bytes) to JSON; anything else raises TypeError."""
    if isinstance(value, (set, frozenset)):
        return list(value)
    if isinstance(value, decimal.Decimal):
        if not value.is_finite():
            raise ValueError("Out of range decimal values are not JSON compliant: {}".format(value))
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, enum.Enum):
        return value.value
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, (bytes, bytearray)):
        return value.decode("utf-8", errors="replace")
    if hasattr(value, "tolist") and callable(value.tolist):  # numpy arrays and scalars
        return value.tolist()
    if hasattr(value, "item") and callable(value.item):  # other array-library scalars
        return value.item()
    if isinstance(value, dict) or hasattr(value, "keys"):
        return dict(value)
    if isinstance(value, (tuple, list)) or hasattr(value, "__iter__"):
        return list(value)
    raise TypeError("Object of type {} is not JSON serializable".format(type(value).__name__))


def _encode(message: Any) -> bytes:
    """Strict JSON for the bridge: NaN and infinities raise ValueError (the bridge only
    accepts standard JSON), unsupported types raise TypeError."""
    return json.dumps(message, separators=(",", ":"), ensure_ascii=False, allow_nan=False,
                      default=_json_default).encode("utf-8")


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
        self.npc: Optional[str] = params.get("npc")
        self.request_id: Any = params.get("requestId")
        self.params = params

    def __repr__(self) -> str:
        return "ToolContext(name={!r}, session={!r}, npc={!r}, call_id={!r})".format(
            self.name, self.session, self.npc, self.call_id)


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

def _shut_down_error(message: str = "The bridge was closed.") -> BridgeError:
    return BridgeError(-32023, message, {"code": "shut_down"})


class Bridge:
    """One bridge instance (one ``oam_bridge``), bound to an asyncio event loop.

    Messages from the bridge arrive on a background thread and are handed to the
    loop with ``call_soon_threadsafe``; every future, event handler and tool
    handler runs on the loop's thread. The bridge binds to the loop of its first
    request and moves to a new loop once that one has stopped (for example
    across ``asyncio.run`` calls) if no request is pending.

    Always :meth:`close` the bridge (or use it as a context manager). An unclosed
    bridge stays alive until the interpreter exits, when it is destroyed.
    Values sent to the bridge must be strict JSON: NaN and infinities raise
    ``ValueError``; sets, ``Decimal``, numpy values, dates and enums are converted.
    """

    def __init__(self, library: Optional[str] = None, loop: Optional[asyncio.AbstractEventLoop] = None):
        self._lib = load_library(library)
        self._loop = loop
        # Native calls in flight (send, call_blocking); close() waits for them before destroying
        # the handle, so a concurrent close never frees it mid-call.
        self._native_condition = threading.Condition()
        self._native_calls = 0
        self._ids = itertools.count(1)
        self._pending: Dict[str, "asyncio.Future[Any]"] = {}
        self._event_handlers: Dict[Any, Callable[[Dict[str, Any]], None]] = {}
        self._notification_handlers: Dict[str, List[Callable[[Dict[str, Any]], None]]] = {}
        self._tools: Dict[str, _Tool] = {}
        self._tool_tasks: Dict[str, "asyncio.Task[None]"] = {}
        self._world_handlers: Dict[str, Callable[[Dict[str, Any]], None]] = {}
        self._closed = False
        self._callback = _CALLBACK(self._on_message)  # keep a reference for the bridge's lifetime
        handle = self._lib.oam_bridge_create(self._callback, None)
        if not handle:
            raise OSError("oam_bridge_create failed")
        self._handle = ctypes.c_void_p(handle)
        with _live_lock:
            _live_bridges[id(self)] = self

    # ---- lifecycle ---------------------------------------------------------------------------

    @property
    def version(self) -> str:
        return self._lib.oam_version().decode()

    def close(self) -> None:
        """Destroys the bridge: cancels running turns; no messages arrive afterwards.
        Pending requests fail with ``shut_down``."""
        if not self._destroy_native():
            return
        error = BridgeError(-32023, "The bridge was closed.", {"code": "shut_down"})
        for future in list(self._pending.values()):
            if not future.done():
                try:
                    future.set_exception(error)
                except RuntimeError:  # the event loop is already closed
                    pass
        self._pending.clear()
        for task in list(self._tool_tasks.values()):
            try:
                task.cancel()
            except RuntimeError:
                pass

    def _destroy_native(self) -> bool:
        """Destroys the native bridge once; returns False if it was already destroyed."""
        with self._native_condition:
            with _live_lock:
                if self._closed:
                    return False
                self._closed = True  # new native calls now raise shut_down
                _live_bridges.pop(id(self), None)
            if self._native_calls:
                # A call_blocking may be waiting for a slow turn: shutting down cancels it.
                self._lib.oam_bridge_send(self._handle, b'{"jsonrpc":"2.0","method":"shutdown"}')
                while self._native_calls:
                    self._native_condition.wait()
        # Waits for an in-flight callback; ctypes releases the GIL during the call.
        self._lib.oam_bridge_destroy(self._handle)
        return True

    @contextlib.contextmanager
    def _native_handle(self) -> Iterator[ctypes.c_void_p]:
        """The live handle for one native call; raises shut_down once the bridge is closed."""
        with self._native_condition:
            if self._closed:
                raise _shut_down_error()
            self._native_calls += 1
        try:
            yield self._handle
        finally:
            with self._native_condition:
                self._native_calls -= 1
                if not self._native_calls:
                    self._native_condition.notify_all()

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
        """The loop messages are delivered to: the running loop. A bridge moves to a new loop
        only when its previous loop has stopped and no request is waiting on it."""
        running = asyncio.get_running_loop()
        loop = self._loop
        if loop is running:
            return loop
        if loop is not None and not loop.is_closed() and loop.is_running():
            raise RuntimeError("This Bridge is bound to another running event loop; "
                               "use one Bridge per event loop.")
        if self._pending:
            raise RuntimeError("This Bridge still has {} request(s) pending on its previous event loop; "
                               "close it or finish them there before using it from a new loop."
                               .format(len(self._pending)))
        self._loop = running
        return running

    # ---- low-level messaging -----------------------------------------------------------------

    def send_message(self, message: Dict[str, Any]) -> None:
        """Sends one raw JSON-RPC message. Raises ``ValueError``/``TypeError`` for values
        that are not strict JSON (see the class docs)."""
        if self._closed:
            raise _shut_down_error()
        self._send_line(_encode(message))

    def _send_line(self, line: bytes) -> None:
        with self._native_handle() as handle:
            status = self._lib.oam_bridge_send(handle, line)
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
        message: Dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        line = _encode(message)  # serialization errors surface before anything is registered
        future: "asyncio.Future[Any]" = loop.create_future()
        self._pending[request_id] = future
        if on_event is not None:
            self._event_handlers[request_id] = on_event
        try:
            self._send_line(line)
            return await future
        finally:
            self._pending.pop(request_id, None)
            self._event_handlers.pop(request_id, None)

    def call_blocking(self, method: str, params: Optional[Dict[str, Any]] = None, timeout: float = 30.0) -> Any:
        """Synchronous request/response via ``oam_call_blocking`` (no asyncio needed).

        Do not use for sessions with tools: tool/call requests need the event loop. Streamed
        notifications carry this call's id (``"py-<n>"``) as ``requestId``. Safe to call from
        any thread; :meth:`close` cancels an in-flight call and waits for it to return.
        """
        message: Dict[str, Any] = {"jsonrpc": "2.0", "id": "py-{}".format(next(self._ids)), "method": method}
        if params is not None:
            message["params"] = params
        line = _encode(message)
        with self._native_handle() as handle:
            raw = self._lib.oam_call_blocking(handle, line, int(timeout * 1000))
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

    def _tool_list(self, tools: Iterable[Union[str, Dict[str, Any]]]) -> List[Dict[str, Any]]:
        """Registered tool names become their definitions; dicts pass through."""
        return [self.tool_definitions([tool])[0] if isinstance(tool, str) else tool for tool in tools]

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
            params["tools"] = self._tool_list(tools)
        if options is not None:
            params["options"] = options
        if model is not None:
            params["model"] = model
        if history is not None:
            params["history"] = history
        result = await self.request("session/create", params)
        return Session(self, result["session"], result.get("warnings", []))


    # ---- NPCs (docs/PROTOCOL.md section 6) ---------------------------------------------------

    async def create_npc(self, persona: Dict[str, Any],
                         tools: Optional[Iterable[Union[str, Dict[str, Any]]]] = None,
                         world: Optional[str] = None, options: Optional[Dict[str, Any]] = None,
                         memory: Optional[Dict[str, Any]] = None, model: Any = None,
                         npc: Optional[str] = None) -> "NPC":
        """Creates an NPC. ``persona`` needs at least ``name``; ``tools`` lists registered
        tool names or raw definitions; ``world`` is a world id; ``options`` are NPC options
        such as ``{"groundingTool": "check_inventory", "replyFormat": "text"}``."""
        params: Dict[str, Any] = {"persona": persona}
        if npc is not None:
            params["npc"] = npc
        if tools is not None:
            params["tools"] = self._tool_list(tools)
        if world is not None:
            params["world"] = world
        if options is not None:
            params["options"] = options
        if memory is not None:
            params["memory"] = memory
        if model is not None:
            params["model"] = model
        result = await self.request("npc/create", params)
        return NPC(self, result["npc"], result.get("tools", []), result.get("warnings", []))

    async def restore_npc(self, state: Dict[str, Any], npc: Optional[str] = None,
                          tools: Any = _UNSET, options: Any = _UNSET, world: Any = _UNSET,
                          model: Any = None) -> "NPC":
        """Rebuilds an NPC from :meth:`NPC.state`. Tools, options and world default to the
        saved ones; pass them (even ``None``) to override. The model is not saved."""
        params: Dict[str, Any] = {"state": state}
        if npc is not None:
            params["npc"] = npc
        if tools is not _UNSET:
            params["tools"] = None if tools is None else self._tool_list(tools)
        if options is not _UNSET:
            params["options"] = options
        if world is not _UNSET:
            params["world"] = world
        if model is not None:
            params["model"] = model
        result = await self.request("npc/restore", params)
        return NPC(self, result["npc"], result.get("tools", []), result.get("warnings", []))

    def npc(self, npc_id: str) -> "NPC":
        """A handle for an existing NPC (no request is sent)."""
        return NPC(self, npc_id, [], [])

    async def list_npcs(self) -> List[Dict[str, Any]]:
        return (await self.request("npc/list"))["npcs"]

    # ---- decisions and content ---------------------------------------------------------------

    async def decide(self, situation: Any, options: Iterable[Union[str, Dict[str, Any]]],
                     actor: Any = None, context: Any = None,
                     tools: Optional[Iterable[Union[str, Dict[str, Any]]]] = None,
                     tool_choice: Any = None, fallback: Optional[str] = None,
                     **settings: Any) -> Dict[str, Any]:
        """Picks one option id (``result["optionID"]``). ``options`` are id strings or
        ``{"id", "description"}`` dicts; ``actor`` is a persona dict or an NPC id;
        ``fallback`` is returned (``isFallback``) when guardrails block the decision.
        ``settings``: ``instructions``, ``temperature``, ``maxToolRounds``,
        ``toolTimeoutSeconds``, ``model``."""
        params = self._decision_params(situation, options, actor, context, tools, tool_choice, fallback)
        params.update(settings)
        return await self.request("decision/decide", params)

    async def decide_many(self, requests: Iterable[Dict[str, Any]], max_concurrency: Optional[int] = None,
                          **settings: Any) -> List[Dict[str, Any]]:
        """Several independent decisions (raw ``decision/decide`` params each). Returns one
        entry per request, in order: a decision, or ``{"error": {...}}``."""
        prepared = []
        for request in requests:
            request = dict(request)
            if "tools" in request and request["tools"] is not None:
                request["tools"] = self._tool_list(request["tools"])
            prepared.append(request)
        params: Dict[str, Any] = {"requests": prepared}
        if max_concurrency is not None:
            params["maxConcurrency"] = max_concurrency
        params.update(settings)
        return (await self.request("decision/decideMany", params))["results"]

    def _decision_params(self, situation: Any, options: Iterable[Union[str, Dict[str, Any]]], actor: Any,
                         context: Any, tools: Optional[Iterable[Union[str, Dict[str, Any]]]],
                         tool_choice: Any, fallback: Optional[str]) -> Dict[str, Any]:
        params: Dict[str, Any] = {"situation": situation, "options": list(options)}
        if actor is not None:
            params["actor"] = actor
        if context is not None:
            params["context"] = context
        if tools is not None:
            params["tools"] = self._tool_list(tools)
        if tool_choice is not None:
            params["toolChoice"] = tool_choice
        if fallback is not None:
            params["fallbackOptionID"] = fallback
        return params

    async def generate(self, prompt: str, schema: Dict[str, Any], instructions: Optional[str] = None,
                       context: Any = None, tools: Optional[Iterable[Union[str, Dict[str, Any]]]] = None,
                       **settings: Any) -> Any:
        """Generates JSON matching ``schema`` (``content/generate``) and returns it.
        ``settings``: ``temperature``, ``toolTimeoutSeconds``, ``model``."""
        params: Dict[str, Any] = {"prompt": prompt, "schema": schema}
        if instructions is not None:
            params["instructions"] = instructions
        if context is not None:
            params["context"] = context
        if tools is not None:
            params["tools"] = self._tool_list(tools)
        params.update(settings)
        return (await self.request("content/generate", params))["content"]

    # ---- world state ---------------------------------------------------------------------------

    async def create_world(self, state: Optional[Dict[str, Any]] = None, world: Optional[str] = None) -> "World":
        """Creates a shared JSON world state (an object) and returns its handle."""
        params: Dict[str, Any] = {}
        if world is not None:
            params["world"] = world
        if state is not None:
            params["state"] = state
        result = await self.request("world/create", params)
        return World(self, result["world"])

    def world(self, world_id: str) -> "World":
        """A handle for an existing world (no request is sent)."""
        return World(self, world_id)

    async def list_worlds(self) -> List[Dict[str, Any]]:
        return (await self.request("world/list"))["worlds"]

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
            if method == "world/changed" and isinstance(params, dict):
                world_handler = self._world_handlers.get(str(params.get("subscription")))
                if world_handler is not None:
                    self._safely(world_handler, params)
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
            # Encoded here so an output that is not strict JSON (NaN, an unknown type)
            # becomes an error the model sees instead of a reply that is never sent.
            line = _encode({"jsonrpc": "2.0", "id": request_id,
                            "result": {"output": value if value is not None else ""}})
        except asyncio.CancelledError:
            return  # the bridge sent tool/cancel; it no longer wants the output
        except Exception as error:
            line = _encode({"jsonrpc": "2.0", "id": request_id,
                            "result": {"output": str(error) or type(error).__name__, "isError": True}})
        self._send_quietly(line)

    def _reply_error(self, request_id: Any, code: int, text: str) -> None:
        self._send_quietly(_encode({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": text}}))

    def _send_quietly(self, line: bytes) -> None:
        """Sends a reply to the bridge unless it was closed meanwhile (then nobody waits for it)."""
        try:
            self._send_line(line)
        except BridgeError:
            pass


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


class NPC:
    """A non-player character on the bridge (``npc/*`` methods)."""

    def __init__(self, bridge: Bridge, npc_id: str, tools: List[str], warnings: List[str]):
        self.bridge = bridge
        self.id = npc_id
        self.tools = tools
        self.warnings = warnings

    def __repr__(self) -> str:
        return "NPC({!r})".format(self.id)

    async def talk(self, line: str, context: Any = None,
                   on_line: Optional[Callable[[str], None]] = None,
                   on_emotion: Optional[Callable[[str], None]] = None,
                   on_event: Optional[Callable[[Dict[str, Any]], None]] = None,
                   tool_choice: Any = None) -> Dict[str, Any]:
        """One conversation turn. Returns the dialogue turn (``line``, ``emotion``,
        ``playerOptions``, ``endsConversation``, ``toolCalls``, ``relationship``,
        ``isFallback``, ``usage``).

        ``on_line`` receives the whole line shown so far after every change (a
        typewriter effect), ``on_emotion`` the emotion as soon as it is known, and
        ``on_event`` every raw ``npc/event`` payload. Any of them turns on streaming.
        """
        params: Dict[str, Any] = {"npc": self.id, "line": line}
        if context is not None:
            params["context"] = context
        if tool_choice is not None:
            params["toolChoice"] = tool_choice
        handler = None
        if on_line is not None or on_emotion is not None or on_event is not None:
            params["stream"] = True
            shown = [""]

            def handler(notification: Dict[str, Any]) -> None:
                event = notification.get("event", {})
                kind = event.get("type")
                if on_event is not None:
                    on_event(event)
                if kind == "emotion" and on_emotion is not None:
                    on_emotion(event.get("emotion", "neutral"))
                elif kind in ("lineDelta", "lineReset"):
                    shown[0] = shown[0] + event.get("delta", "") if kind == "lineDelta" else event.get("line", "")
                    if on_line is not None:
                        on_line(shown[0])
        return await self.bridge.request("npc/talk", params, on_event=handler)

    async def bark(self, situation: Any = None) -> str:
        """A short ambient line (fast; no history). Raises on guardrail blocks: skip the bark."""
        params: Dict[str, Any] = {"npc": self.id}
        if situation is not None:
            params["situation"] = situation
        return (await self.bridge.request("npc/bark", params))["line"]

    async def state(self, settle: bool = True) -> Dict[str, Any]:
        """The save state (persona, memory, transcript, options, tools, world) for :meth:`Bridge.restore_npc`."""
        return (await self.bridge.request("npc/state", {"npc": self.id, "settle": settle}))["state"]

    async def update(self, persona: Optional[Dict[str, Any]] = None, options: Optional[Dict[str, Any]] = None,
                     memory: Optional[Dict[str, Any]] = None,
                     tools: Optional[Iterable[Union[str, Dict[str, Any]]]] = None) -> List[str]:
        """Merge-patches persona, options and memory (``None`` values reset fields) and
        replaces tools; applies from the next turn. Returns warnings."""
        params: Dict[str, Any] = {"npc": self.id}
        if persona is not None:
            params["persona"] = persona
        if options is not None:
            params["options"] = options
        if memory is not None:
            params["memory"] = memory
        if tools is not None:
            params["tools"] = self.bridge._tool_list(tools)
        return (await self.bridge.request("npc/update", params)).get("warnings", [])

    async def reset(self, clear_memory: bool = False) -> None:
        await self.bridge.request("npc/reset", {"npc": self.id, "clearMemory": clear_memory})

    async def cancel(self) -> int:
        return (await self.bridge.request("npc/cancel", {"npc": self.id}))["cancelled"]

    async def delete(self) -> None:
        await self.bridge.request("npc/delete", {"npc": self.id})


class World:
    """A shared JSON world state (``world/*`` methods). Paths are dot paths such as
    ``"player.gold"``; ``""`` is the root."""

    def __init__(self, bridge: Bridge, world_id: str):
        self.bridge = bridge
        self.id = world_id

    def __repr__(self) -> str:
        return "World({!r})".format(self.id)

    async def get(self, path: str = "", default: Any = None) -> Any:
        result = await self.bridge.request("world/get", {"world": self.id, "path": path})
        return result["value"] if result["exists"] else default

    async def set(self, path: str, value: Any) -> int:
        """Writes ``value`` (``None`` stores JSON null); returns the new version."""
        return (await self.bridge.request("world/set", {"world": self.id, "path": path, "value": value}))["version"]

    async def merge(self, patch: Dict[str, Any], path: str = "") -> int:
        """Applies a JSON merge patch (``None`` deletes keys); returns the new version."""
        return (await self.bridge.request("world/merge", {"world": self.id, "path": path, "patch": patch}))["version"]

    async def remove(self, path: str) -> Any:
        """Removes the value at ``path`` and returns it (``None`` if there was none)."""
        return (await self.bridge.request("world/remove", {"world": self.id, "path": path}))["oldValue"]

    async def snapshot(self) -> Dict[str, Any]:
        return (await self.bridge.request("world/snapshot", {"world": self.id}))["state"]

    async def subscribe(self, handler: Callable[[Dict[str, Any]], None], path: str = "") -> str:
        """Calls ``handler`` with every ``world/changed`` notification (``path``,
        ``oldValue``?, ``newValue``?) at, inside or above ``path``. Returns the subscription id."""
        result = await self.bridge.request("world/subscribe", {"world": self.id, "path": path})
        self.bridge._world_handlers[result["subscription"]] = handler
        return result["subscription"]

    async def unsubscribe(self, subscription: str) -> None:
        self.bridge._world_handlers.pop(subscription, None)
        await self.bridge.request("world/unsubscribe", {"subscription": subscription})

    async def delete(self) -> None:
        await self.bridge.request("world/delete", {"world": self.id})
