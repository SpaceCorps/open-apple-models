// OpenAppleModels.cs — Unity / .NET binding for open-apple-models.
//
// Drive on-device Apple Foundation Models agents from C#, with tool calls your
// game executes (animations, game logic). Wraps the C ABI in
// bindings/c/open_apple_models.h; the message reference is docs/PROTOCOL.md.
//
// Setup (Unity):
//   * macOS editor/standalone: put libOpenAppleModelsFFI.dylib in Assets/Plugins/macOS
//     (build: swift build -c release --product OpenAppleModelsFFI).
//   * iOS: add OpenAppleModelsFFI.xcframework (a dynamic framework; build it with Xcode) to
//     Assets/Plugins/iOS and embed it; calls go through [DllImport("__Internal")].
//     See bindings/README.md.
//   * Add an OamBridgeRunner component (or call bridge.Pump() from your own Update) so
//     messages, results and tool calls are handled on the main thread.
//
//   var bridge = OamBridgeRunner.Create().Bridge;
//   bridge.RegisterTool("open_gate", "Open a named gate.",
//       Json.Parse("{\"type\":\"object\",\"properties\":{\"gate\":{\"type\":\"string\"}},\"required\":[\"gate\"]}"),
//       (call, reply) => StartCoroutine(OpenGate((string)call.Arguments["gate"], reply)));   // reply.Ok(...) later
//   var guard = await bridge.CreateSessionAsync("You are a castle guard.", new[] { "open_gate" },
//       options: new Dictionary<string, object> { ["toolChoice"] = "required" });
//   var result = await guard.RespondAsync("Open the north gate!", onText: delta => subtitle.text += delta);
//
// Game methods (NPCs, decisions, world state, content) have typed helpers:
//
//   var world = await bridge.CreateWorldAsync(Json.Parse("{\"player\":{\"name\":\"Aria\",\"gold\":60}}") as Dictionary<string, object>);
//   var gorm = await bridge.CreateNpcAsync(new Dictionary<string, object> { ["name"] = "Gorm", ["role"] = "the village blacksmith" },
//       tools: new[] { "check_inventory" }, world: world.Id,
//       options: new Dictionary<string, object> { ["groundingTool"] = "check_inventory" });
//   var turn = await gorm.TalkAsync("Got any iron swords?", onLine: text => subtitle.text = text, onEmotion: portrait.Show);
//   var decision = await bridge.DecideAsync("The goblin has 3 HP left.", new object[] { "attack", "flee", "beg" }, actor: "gorm");
//
// Outside Unity (plain .NET) everything works the same; call Pump() from your loop, or
// construct with dispatchOnCallbackThread: true to handle messages on the bridge thread.

using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
#if UNITY_5_3_OR_NEWER
using UnityEngine;
#endif

#if !UNITY_5_3_OR_NEWER
namespace AOT
{
    /// <summary>Marks native callbacks for AOT compilers (Unity provides its own definition).</summary>
    [AttributeUsage(AttributeTargets.Method)]
    public sealed class MonoPInvokeCallbackAttribute : Attribute
    {
        public MonoPInvokeCallbackAttribute(Type type) { }
    }
}
#endif

namespace OpenAppleModels
{
    internal static class Native
    {
#if (UNITY_IOS || UNITY_TVOS || UNITY_VISIONOS) && !UNITY_EDITOR
        private const string Library = "__Internal";
#else
        private const string Library = "OpenAppleModelsFFI";
#endif

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void MessageCallback(IntPtr jsonLine, IntPtr userData);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr oam_bridge_create(MessageCallback callback, IntPtr userData);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern int oam_bridge_send(IntPtr bridge, byte[] jsonLine);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern void oam_bridge_destroy(IntPtr bridge);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr oam_version();

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr oam_call_blocking(IntPtr bridge, byte[] requestJson, int timeoutMs);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        public static extern void oam_string_free(IntPtr value);

        /// <summary>Null-terminated UTF-8.</summary>
        public static byte[] Utf8(string text)
        {
            var bytes = new byte[Encoding.UTF8.GetByteCount(text) + 1];
            Encoding.UTF8.GetBytes(text, 0, text.Length, bytes, 0);
            return bytes;
        }

        public static string FromUtf8(IntPtr pointer)
        {
            if (pointer == IntPtr.Zero) return null;
            int length = 0;
            while (Marshal.ReadByte(pointer, length) != 0) length++;
            var bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }
    }

    /// <summary>A JSON-RPC error response. <see cref="Name"/> is the stable string code
    /// (e.g. "session_not_found", "guardrail_violation", "cancelled").</summary>
    public sealed class OamException : Exception
    {
        public int Code { get; }
        public object ErrorData { get; }
        public string Name => ErrorData is Dictionary<string, object> data && data.TryGetValue("code", out var name) ? name as string : null;

        public OamException(int code, string message, object data = null) : base(message)
        {
            Code = code;
            ErrorData = data;
        }

        internal static OamException FromJson(object error)
        {
            var e = error as Dictionary<string, object> ?? new Dictionary<string, object>();
            var code = e.TryGetValue("code", out var c) ? Convert.ToInt32(c, CultureInfo.InvariantCulture) : -32603;
            var message = e.TryGetValue("message", out var m) ? m as string : "Unknown error";
            e.TryGetValue("data", out var data);
            return new OamException(code, message, data);
        }
    }

    /// <summary>A tool call the model made; your game executes it.</summary>
    public sealed class ToolCall
    {
        /// <summary>The model's call id.</summary>
        public string Id { get; internal set; }
        public string Name { get; internal set; }
        public Dictionary<string, object> Arguments { get; internal set; }
        /// <summary>The session the call belongs to (null for NPC, decision and content calls).</summary>
        public string Session { get; internal set; }
        /// <summary>The NPC whose turn made the call (npc/talk), or null.</summary>
        public string Npc { get; internal set; }
        /// <summary>The id of the request whose turn made the call.</summary>
        public object RequestId { get; internal set; }
        /// <summary>The raw tool/call params.</summary>
        public Dictionary<string, object> Params { get; internal set; }
    }

    /// <summary>Answers one tool call, now or later (e.g. when an animation finishes).
    /// Thread-safe; only the first answer counts.</summary>
    public sealed class ToolReply
    {
        private readonly OamBridge _bridge;
        private readonly object _rpcId;
        private int _answered;

        internal ToolReply(OamBridge bridge, object rpcId)
        {
            _bridge = bridge;
            _rpcId = rpcId;
        }

        /// <summary>True once the bridge sent tool/cancel (turn cancelled or timed out).</summary>
        public bool IsCancelled { get; private set; }
        /// <summary>Raised (on the dispatch thread) when the bridge no longer wants the output.</summary>
        public event Action Cancelled;

        /// <summary>Returns output to the model: a string, or any JSON value (dictionaries, lists, numbers…).</summary>
        public void Ok(object output) => Send(new Dictionary<string, object> { ["output"] = output ?? "" });

        /// <summary>Reports a failure the model sees and may recover from.</summary>
        public void Error(string message) => Send(new Dictionary<string, object> { ["output"] = message ?? "Error", ["isError"] = true });

        internal void MarkCancelled()
        {
            IsCancelled = true;
            Interlocked.Exchange(ref _answered, 1);
            Cancelled?.Invoke();
        }

        private void Send(Dictionary<string, object> result)
        {
            if (Interlocked.Exchange(ref _answered, 1) == 1) return;
            _bridge.ForgetCall(_rpcId);
            if (_bridge.IsDisposed) return;  // a late answer after Dispose has nowhere to go
            try
            {
                _bridge.SendMessage(new Dictionary<string, object> { ["jsonrpc"] = "2.0", ["id"] = _rpcId, ["result"] = result });
            }
            catch (ObjectDisposedException)
            {
                // Disposed concurrently; the bridge no longer needs the output.
            }
        }
    }

    /// <summary>One bridge instance (one oam_bridge). Always Dispose it: the native side keeps it
    /// alive (through a GCHandle) until then.</summary>
    public sealed class OamBridge : IDisposable
    {
        // Static delegate: IL2CPP requires native callbacks to be static methods, and the
        // delegate must never be garbage collected while the native side holds it.
        private static readonly Native.MessageCallback s_callback = OnNativeMessage;

        private readonly ConcurrentQueue<string> _inbox = new ConcurrentQueue<string>();
        private readonly object _lock = new object();
        private readonly Dictionary<string, TaskCompletionSource<object>> _pending = new Dictionary<string, TaskCompletionSource<object>>();
        private readonly Dictionary<string, Action<Dictionary<string, object>>> _eventHandlers = new Dictionary<string, Action<Dictionary<string, object>>>();
        private readonly Dictionary<string, Action<Dictionary<string, object>>> _worldHandlers = new Dictionary<string, Action<Dictionary<string, object>>>();
        private readonly Dictionary<string, RegisteredTool> _tools = new Dictionary<string, RegisteredTool>();
        private readonly Dictionary<string, ToolReply> _openCalls = new Dictionary<string, ToolReply>();
        private readonly bool _dispatchOnCallbackThread;
        private IntPtr _handle;
        private GCHandle _self;
        private int _nextId;

        private sealed class RegisteredTool
        {
            public string Name, Description;
            public object Parameters;
            public double? TimeoutSeconds;
            public Action<ToolCall, ToolReply> Handler;
        }

        /// <summary>Raised for every notification (method, params), on the dispatch thread.</summary>
        public event Action<string, Dictionary<string, object>> NotificationReceived;

        /// <param name="dispatchOnCallbackThread">Handle messages directly on the bridge's thread instead of
        /// queueing them for <see cref="Pump"/>. Leave false in Unity.</param>
        public OamBridge(bool dispatchOnCallbackThread = false)
        {
            _dispatchOnCallbackThread = dispatchOnCallbackThread;
            _self = GCHandle.Alloc(this, GCHandleType.Normal);
            _handle = Native.oam_bridge_create(s_callback, GCHandle.ToIntPtr(_self));
            if (_handle == IntPtr.Zero)
            {
                _self.Free();
                throw new InvalidOperationException("oam_bridge_create failed");
            }
        }

        public static string Version => Native.FromUtf8(Native.oam_version());

        public bool IsDisposed => _handle == IntPtr.Zero;

        [AOT.MonoPInvokeCallback(typeof(Native.MessageCallback))]
        private static void OnNativeMessage(IntPtr jsonLine, IntPtr userData)
        {
            // Runs on a bridge thread: copy the line and hand it over. Never throw into native code.
            try
            {
                var bridge = GCHandle.FromIntPtr(userData).Target as OamBridge;
                var line = Native.FromUtf8(jsonLine);
                if (bridge == null || line == null) return;
                if (bridge._dispatchOnCallbackThread) bridge.Dispatch(line);
                else bridge._inbox.Enqueue(line);
            }
            catch (Exception)
            {
                // Swallow: an exception must not unwind through native frames.
            }
        }

        /// <summary>Handles queued messages on the calling thread (call every frame from the main thread).
        /// Returns the number of messages handled.</summary>
        public int Pump(int maxMessages = int.MaxValue)
        {
            int handled = 0;
            while (handled < maxMessages && _inbox.TryDequeue(out var line))
            {
                Dispatch(line);
                handled++;
            }
            return handled;
        }

        // ---- requests ----------------------------------------------------------------------

        /// <summary>Sends a request; the task completes (during Pump) with its result or an OamException.
        /// <paramref name="onEvent"/> receives the params of notifications tagged with this request.</summary>
        public Task<object> RequestAsync(string method, object parameters = null, Action<Dictionary<string, object>> onEvent = null)
        {
            var id = "cs-" + Interlocked.Increment(ref _nextId).ToString(CultureInfo.InvariantCulture);
            var completion = new TaskCompletionSource<object>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_lock)
            {
                _pending[id] = completion;
                if (onEvent != null) _eventHandlers[id] = onEvent;
            }
            var message = new Dictionary<string, object> { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method };
            if (parameters != null) message["params"] = parameters;
            try
            {
                SendMessage(message);
            }
            catch (Exception error)
            {
                lock (_lock) { _pending.Remove(id); _eventHandlers.Remove(id); }
                completion.TrySetException(error);
            }
            return completion.Task;
        }

        /// <summary>Callback-style request, for code that does not use async/await.</summary>
        public void Request(string method, object parameters, Action<object> onResult, Action<OamException> onError = null)
        {
            RequestAsync(method, parameters).ContinueWith(task =>
            {
                if (task.IsFaulted) onError?.Invoke(task.Exception?.InnerException as OamException ?? new OamException(-32603, task.Exception?.Message));
                else onResult?.Invoke(task.Result);
            }, TaskScheduler.Default);
        }

        /// <summary>Sends a notification (no response).</summary>
        public void Notify(string method, object parameters = null)
        {
            var message = new Dictionary<string, object> { ["jsonrpc"] = "2.0", ["method"] = method };
            if (parameters != null) message["params"] = parameters;
            SendMessage(message);
        }

        /// <summary>Synchronous request via oam_call_blocking. Not for sessions with tools.</summary>
        public object CallBlocking(string method, object parameters = null, int timeoutMs = 30000)
        {
            EnsureAlive();
            var message = new Dictionary<string, object> { ["jsonrpc"] = "2.0", ["id"] = 0, ["method"] = method };
            if (parameters != null) message["params"] = parameters;
            var raw = Native.oam_call_blocking(_handle, Native.Utf8(Json.Serialize(message)), timeoutMs);
            if (raw == IntPtr.Zero) throw new InvalidOperationException("oam_call_blocking failed");
            string line;
            try { line = Native.FromUtf8(raw); } finally { Native.oam_string_free(raw); }
            var response = (Dictionary<string, object>)Json.Parse(line);
            if (response.TryGetValue("error", out var error)) throw OamException.FromJson(error);
            response.TryGetValue("result", out var result);
            return result;
        }

        /// <summary>Sends one raw JSON-RPC message. Thread-safe.</summary>
        public void SendMessage(Dictionary<string, object> message)
        {
            EnsureAlive();
            var status = Native.oam_bridge_send(_handle, Native.Utf8(Json.Serialize(message)));
            if (status != 0) throw new InvalidOperationException("oam_bridge_send failed with status " + status);
        }

        private void EnsureAlive()
        {
            if (_handle == IntPtr.Zero) throw new ObjectDisposedException(nameof(OamBridge));
        }

        // ---- tools -------------------------------------------------------------------------

        /// <summary>Registers a tool answered immediately: return a string or JSON value; throw to report an error.</summary>
        public void RegisterTool(string name, string description, object parameters, Func<ToolCall, object> handler, double? timeoutSeconds = null)
        {
            RegisterTool(name, description, parameters, (call, reply) =>
            {
                object output;
                try { output = handler(call); }
                catch (Exception error) { reply.Error(error.Message); return; }
                reply.Ok(output);
            }, timeoutSeconds);
        }

        /// <summary>Registers a tool answered later through <see cref="ToolReply"/> (animations, coroutines).</summary>
        public void RegisterTool(string name, string description, object parameters, Action<ToolCall, ToolReply> handler, double? timeoutSeconds = null)
        {
            lock (_lock)
            {
                _tools[name] = new RegisteredTool
                {
                    Name = name,
                    Description = description,
                    Parameters = parameters ?? new Dictionary<string, object> { ["type"] = "object", ["properties"] = new Dictionary<string, object>() },
                    TimeoutSeconds = timeoutSeconds,
                    Handler = handler,
                };
            }
        }

        /// <summary>Definitions for session/create's "tools" (all registered tools when no names are given).</summary>
        public List<object> ToolDefinitions(params string[] names)
        {
            if (names != null && names.Length > 0) return DefinitionsOf(names);
            lock (_lock) return DefinitionsOf(new List<string>(_tools.Keys));
        }

        /// <summary>Definitions of exactly the named tools (an empty list gives no tools).</summary>
        internal List<object> DefinitionsOf(IEnumerable<string> names)
        {
            var result = new List<object>();
            lock (_lock)
            {
                foreach (var name in names)
                {
                    if (!_tools.TryGetValue(name, out var tool)) throw new KeyNotFoundException("Unknown tool " + name);
                    var definition = new Dictionary<string, object>
                    {
                        ["name"] = tool.Name,
                        ["description"] = tool.Description,
                        ["parameters"] = tool.Parameters,
                        ["execution"] = "client",
                    };
                    if (tool.TimeoutSeconds.HasValue) definition["timeoutSeconds"] = tool.TimeoutSeconds.Value;
                    result.Add(definition);
                }
            }
            return result;
        }

        // ---- sessions ----------------------------------------------------------------------

        public Task<object> InitializeAsync(string clientName = "unity") =>
            RequestAsync("initialize", new Dictionary<string, object>
            {
                ["client"] = new Dictionary<string, object> { ["name"] = clientName, ["version"] = Version },
                ["protocolVersion"] = "1.0",
            });

        /// <summary>Creates a session. <paramref name="tools"/> are names of registered tools.</summary>
        public async Task<OamSession> CreateSessionAsync(string instructions = null, IEnumerable<string> tools = null,
            Dictionary<string, object> options = null, object model = null, object history = null, string session = null)
        {
            var parameters = new Dictionary<string, object>();
            if (session != null) parameters["session"] = session;
            if (instructions != null) parameters["instructions"] = instructions;
            if (tools != null) parameters["tools"] = DefinitionsOf(tools);
            if (options != null) parameters["options"] = options;
            if (model != null) parameters["model"] = model;
            if (history != null) parameters["history"] = history;
            var result = (Dictionary<string, object>)await RequestAsync("session/create", parameters).ConfigureAwait(false);
            return new OamSession(this, (string)result["session"]);
        }


        // ---- NPCs, decisions, world state, content (docs/PROTOCOL.md section 6) -------------

        /// <summary>Creates an NPC. <paramref name="persona"/> needs at least "name";
        /// <paramref name="tools"/> are names of registered tools; <paramref name="world"/> is a world id;
        /// <paramref name="options"/> are NPC options such as "groundingTool" or "replyFormat".</summary>
        public async Task<OamNpc> CreateNpcAsync(Dictionary<string, object> persona, IEnumerable<string> tools = null,
            string world = null, Dictionary<string, object> options = null, Dictionary<string, object> memory = null,
            object model = null, string npc = null)
        {
            var parameters = new Dictionary<string, object> { ["persona"] = persona };
            if (npc != null) parameters["npc"] = npc;
            if (tools != null) parameters["tools"] = DefinitionsOf(tools);
            if (world != null) parameters["world"] = world;
            if (options != null) parameters["options"] = options;
            if (memory != null) parameters["memory"] = memory;
            if (model != null) parameters["model"] = model;
            var result = (Dictionary<string, object>)await RequestAsync("npc/create", parameters).ConfigureAwait(false);
            return new OamNpc(this, (string)result["npc"]);
        }

        /// <summary>Rebuilds an NPC from <see cref="OamNpc.StateAsync"/>. Its id, tools, options and world
        /// come from the save; the model does not (pass it unless it is the system model). For other
        /// overrides send "npc/restore" with RequestAsync.</summary>
        public async Task<OamNpc> RestoreNpcAsync(object state, string npc = null, object model = null)
        {
            var parameters = new Dictionary<string, object> { ["state"] = state };
            if (npc != null) parameters["npc"] = npc;
            if (model != null) parameters["model"] = model;
            var result = (Dictionary<string, object>)await RequestAsync("npc/restore", parameters).ConfigureAwait(false);
            return new OamNpc(this, (string)result["npc"]);
        }

        /// <summary>A handle for an existing NPC (no request is sent).</summary>
        public OamNpc Npc(string id) => new OamNpc(this, id);

        /// <summary>Picks one option; the result's "optionID" is the chosen id. <paramref name="options"/> are id
        /// strings or {"id", "description"} dictionaries; <paramref name="actor"/> is a persona dictionary or an
        /// NPC id; <paramref name="fallbackOptionId"/> is returned (with "isFallback") when guardrails block.</summary>
        public async Task<Dictionary<string, object>> DecideAsync(string situation, IEnumerable<object> options,
            object actor = null, object context = null, IEnumerable<string> tools = null, string toolChoice = null,
            string fallbackOptionId = null, object model = null)
        {
            var parameters = new Dictionary<string, object> { ["situation"] = situation, ["options"] = new List<object>(options) };
            if (actor != null) parameters["actor"] = actor;
            if (context != null) parameters["context"] = context;
            if (tools != null) parameters["tools"] = DefinitionsOf(tools);
            if (toolChoice != null) parameters["toolChoice"] = ToolChoiceValue(toolChoice);
            if (fallbackOptionId != null) parameters["fallbackOptionID"] = fallbackOptionId;
            if (model != null) parameters["model"] = model;
            return (Dictionary<string, object>)await RequestAsync("decision/decide", parameters).ConfigureAwait(false);
        }

        /// <summary>Several independent decisions (raw decision/decide params each). Returns one entry per
        /// request, in order: a decision dictionary, or {"error": {...}}.</summary>
        public async Task<List<object>> DecideManyAsync(IEnumerable<Dictionary<string, object>> requests,
            int? maxConcurrency = null, object model = null)
        {
            var parameters = new Dictionary<string, object> { ["requests"] = new List<object>(requests) };
            if (maxConcurrency.HasValue) parameters["maxConcurrency"] = maxConcurrency.Value;
            if (model != null) parameters["model"] = model;
            var result = (Dictionary<string, object>)await RequestAsync("decision/decideMany", parameters).ConfigureAwait(false);
            return (List<object>)result["results"];
        }

        /// <summary>Generates JSON matching <paramref name="schema"/> (items, quests, rumors…) and returns it.</summary>
        public async Task<object> GenerateAsync(string prompt, object schema, string instructions = null,
            object context = null, IEnumerable<string> tools = null, object model = null)
        {
            var parameters = new Dictionary<string, object> { ["prompt"] = prompt, ["schema"] = schema };
            if (instructions != null) parameters["instructions"] = instructions;
            if (context != null) parameters["context"] = context;
            if (tools != null) parameters["tools"] = DefinitionsOf(tools);
            if (model != null) parameters["model"] = model;
            var result = (Dictionary<string, object>)await RequestAsync("content/generate", parameters).ConfigureAwait(false);
            return result["content"];
        }

        /// <summary>Creates a shared JSON world state (an object).</summary>
        public async Task<OamWorld> CreateWorldAsync(Dictionary<string, object> state = null, string world = null)
        {
            var parameters = new Dictionary<string, object>();
            if (world != null) parameters["world"] = world;
            if (state != null) parameters["state"] = state;
            var result = (Dictionary<string, object>)await RequestAsync("world/create", parameters).ConfigureAwait(false);
            return new OamWorld(this, (string)result["world"]);
        }

        /// <summary>A handle for an existing world (no request is sent).</summary>
        public OamWorld World(string id) => new OamWorld(this, id);

        internal void SetWorldHandler(string subscription, Action<Dictionary<string, object>> handler)
        {
            lock (_lock)
            {
                if (handler == null) _worldHandlers.Remove(subscription);
                else _worldHandlers[subscription] = handler;
            }
        }

        /// <summary>"auto", "none" and "required" pass through; anything else names a tool.</summary>
        internal static object ToolChoiceValue(string toolChoice) =>
            toolChoice == "auto" || toolChoice == "none" || toolChoice == "required"
                ? (object)toolChoice
                : new Dictionary<string, object> { ["tool"] = toolChoice };

        // ---- dispatch ----------------------------------------------------------------------

        private void Dispatch(string line)
        {
            Dictionary<string, object> message;
            try { message = Json.Parse(line) as Dictionary<string, object>; }
            catch (FormatException) { return; }
            if (message == null) return;

            message.TryGetValue("method", out var methodValue);
            var method = methodValue as string;
            message.TryGetValue("params", out var paramsValue);
            var parameters = paramsValue as Dictionary<string, object> ?? new Dictionary<string, object>();

            if (method != null && message.ContainsKey("id"))
            {
                if (method == "tool/call") HandleToolCall(message["id"], parameters);
                else SendMessage(new Dictionary<string, object>
                {
                    ["jsonrpc"] = "2.0", ["id"] = message["id"],
                    ["error"] = new Dictionary<string, object> { ["code"] = -32601, ["message"] = "Client does not implement " + method },
                });
                return;
            }
            if (method != null)
            {
                if (method == "tool/cancel" && parameters.TryGetValue("id", out var rpcId))
                {
                    ToolReply reply;
                    lock (_lock) { if (_openCalls.TryGetValue(Convert.ToString(rpcId, CultureInfo.InvariantCulture), out reply)) _openCalls.Remove(Convert.ToString(rpcId, CultureInfo.InvariantCulture)); }
                    reply?.MarkCancelled();
                }
                else if (method == "world/changed" && parameters.TryGetValue("subscription", out var subscription) && subscription is string subscriptionId)
                {
                    Action<Dictionary<string, object>> handler;
                    lock (_lock) _worldHandlers.TryGetValue(subscriptionId, out handler);
                    try { handler?.Invoke(parameters); } catch (Exception thrown) { Log("world handler threw: " + thrown); }
                }
                else if (parameters.TryGetValue("requestId", out var requestId) && requestId is string key)
                {
                    Action<Dictionary<string, object>> handler;
                    lock (_lock) _eventHandlers.TryGetValue(key, out handler);
                    try { handler?.Invoke(parameters); } catch (Exception thrown) { Log("event handler threw: " + thrown); }
                }
                try { NotificationReceived?.Invoke(method, parameters); } catch (Exception thrown) { Log("notification handler threw: " + thrown); }
                return;
            }

            if (!message.TryGetValue("id", out var idValue) || !(idValue is string id)) return;
            TaskCompletionSource<object> completion;
            lock (_lock)
            {
                if (!_pending.TryGetValue(id, out completion)) return;
                _pending.Remove(id);
                _eventHandlers.Remove(id);
            }
            if (message.TryGetValue("error", out var error)) completion.TrySetException(OamException.FromJson(error));
            else
            {
                message.TryGetValue("result", out var result);
                completion.TrySetResult(result);
            }
        }

        private void HandleToolCall(object rpcId, Dictionary<string, object> parameters)
        {
            var call = parameters.TryGetValue("call", out var c) ? c as Dictionary<string, object> : null;
            var toolCall = new ToolCall
            {
                Id = call != null && call.TryGetValue("id", out var id) ? id as string : null,
                Name = call != null && call.TryGetValue("name", out var name) ? name as string : null,
                Arguments = (call != null && call.TryGetValue("arguments", out var args) ? args as Dictionary<string, object> : null) ?? new Dictionary<string, object>(),
                Session = parameters.TryGetValue("session", out var session) ? session as string : null,
                Npc = parameters.TryGetValue("npc", out var npc) ? npc as string : null,
                RequestId = parameters.TryGetValue("requestId", out var requestId) ? requestId : null,
                Params = parameters,
            };
            var reply = new ToolReply(this, rpcId);
            RegisteredTool tool;
            lock (_lock)
            {
                _tools.TryGetValue(toolCall.Name ?? "", out tool);
                if (tool != null) _openCalls[Convert.ToString(rpcId, CultureInfo.InvariantCulture)] = reply;
            }
            if (tool == null)
            {
                reply.Error("No handler is registered for tool '" + toolCall.Name + "'.");
                return;
            }
            try { tool.Handler(toolCall, reply); }
            catch (Exception error) { reply.Error(error.Message); }
        }

        /// <summary>Drops the bookkeeping for an answered tool call.</summary>
        internal void ForgetCall(object rpcId)
        {
            lock (_lock) _openCalls.Remove(Convert.ToString(rpcId, CultureInfo.InvariantCulture));
        }

        private static void Log(string message)
        {
#if UNITY_5_3_OR_NEWER
            Debug.LogWarning("[OpenAppleModels] " + message);
#else
            Console.Error.WriteLine("[OpenAppleModels] " + message);
#endif
        }

        /// <summary>Cancels all work and releases the native bridge. No callbacks happen afterwards.</summary>
        public void Dispose()
        {
            var handle = _handle;
            if (handle == IntPtr.Zero) return;
            _handle = IntPtr.Zero;
            Native.oam_bridge_destroy(handle);  // waits for an in-flight callback, then never calls back
            if (_self.IsAllocated) _self.Free();
            List<TaskCompletionSource<object>> pending;
            lock (_lock)
            {
                pending = new List<TaskCompletionSource<object>>(_pending.Values);
                _pending.Clear();
                _eventHandlers.Clear();
                _worldHandlers.Clear();
                _openCalls.Clear();
            }
            foreach (var completion in pending)
                completion.TrySetException(new OamException(-32023, "The bridge was disposed."));
        }
    }

    /// <summary>A bridge session: one agent with its own conversation.</summary>
    public sealed class OamSession
    {
        public OamBridge Bridge { get; }
        public string Id { get; }

        internal OamSession(OamBridge bridge, string id)
        {
            Bridge = bridge;
            Id = id;
        }

        /// <summary>Runs a turn. <paramref name="onText"/> receives text deltas as they stream.
        /// <paramref name="toolChoice"/>: "auto", "none", "required" or a tool name.</summary>
        public async Task<Dictionary<string, object>> RespondAsync(string prompt, Action<string> onText = null,
            Action<Dictionary<string, object>> onEvent = null, object schema = null, string toolChoice = null)
        {
            var parameters = new Dictionary<string, object> { ["session"] = Id, ["prompt"] = prompt };
            if (schema != null) parameters["schema"] = schema;
            if (toolChoice != null) parameters["toolChoice"] = OamBridge.ToolChoiceValue(toolChoice);
            Action<Dictionary<string, object>> handler = null;
            if (onText != null || onEvent != null)
            {
                parameters["stream"] = true;
                handler = notification =>
                {
                    if (!(notification.TryGetValue("event", out var e) && e is Dictionary<string, object> evt)) return;
                    onEvent?.Invoke(evt);
                    if (onText != null && evt.TryGetValue("type", out var type) && (string)type == "text")
                    {
                        var reset = evt.TryGetValue("isReset", out var r) && r is bool b && b;
                        onText((string)(reset ? evt["text"] : evt["delta"]));
                    }
                };
            }
            return (Dictionary<string, object>)await Bridge.RequestAsync("session/respond", parameters, handler).ConfigureAwait(false);
        }

        public Task<object> CancelAsync() => Bridge.RequestAsync("session/cancel", new Dictionary<string, object> { ["session"] = Id });
        public Task<object> ResetAsync() => Bridge.RequestAsync("session/reset", new Dictionary<string, object> { ["session"] = Id });
        public Task<object> DeleteAsync() => Bridge.RequestAsync("session/delete", new Dictionary<string, object> { ["session"] = Id });

        /// <summary>The conversation as a JSON value; save it with Json.Serialize and pass it back as history.</summary>
        public async Task<object> TranscriptAsync()
        {
            var result = (Dictionary<string, object>)await Bridge.RequestAsync("session/transcript", new Dictionary<string, object> { ["session"] = Id }).ConfigureAwait(false);
            return result["transcript"];
        }

        public Task<object> SetInstructionsAsync(string instructions) =>
            Bridge.RequestAsync("session/setInstructions", new Dictionary<string, object> { ["session"] = Id, ["instructions"] = instructions });

        public Task<object> SetContextNoteAsync(string note) =>
            Bridge.RequestAsync("session/setContextNote", new Dictionary<string, object> { ["session"] = Id, ["note"] = note });

        /// <summary>Replaces the session's tools (names of registered tools) from the next turn.</summary>
        public Task<object> SetToolsAsync(IEnumerable<string> tools) =>
            Bridge.RequestAsync("session/setTools", new Dictionary<string, object>
            {
                ["session"] = Id,
                ["tools"] = Bridge.DefinitionsOf(tools ?? new string[0]),
            });

        /// <summary>Summarizes older turns into the context note; the task's result is the summary or null.</summary>
        public async Task<string> CompactAsync(int keepRecentTurns = 2)
        {
            var result = (Dictionary<string, object>)await Bridge.RequestAsync("session/compact",
                new Dictionary<string, object> { ["session"] = Id, ["keepRecentTurns"] = keepRecentTurns }).ConfigureAwait(false);
            return result.TryGetValue("summary", out var summary) ? summary as string : null;
        }
    }

    /// <summary>A non-player character on the bridge (npc/* methods).</summary>
    public sealed class OamNpc
    {
        public OamBridge Bridge { get; }
        public string Id { get; }

        internal OamNpc(OamBridge bridge, string id)
        {
            Bridge = bridge;
            Id = id;
        }

        /// <summary>One conversation turn. The result has "line", "emotion", "playerOptions", "endsConversation",
        /// "toolCalls", "relationship", "isFallback" and "usage". <paramref name="onLine"/> receives the whole line
        /// shown so far after each change (typewriter), <paramref name="onEmotion"/> the emotion as soon as it is
        /// known, <paramref name="onEvent"/> every raw npc/event payload; any of them turns on streaming.</summary>
        public async Task<Dictionary<string, object>> TalkAsync(string line, object context = null,
            Action<string> onLine = null, Action<string> onEmotion = null,
            Action<Dictionary<string, object>> onEvent = null, string toolChoice = null)
        {
            var parameters = new Dictionary<string, object> { ["npc"] = Id, ["line"] = line ?? "" };
            if (context != null) parameters["context"] = context;
            if (toolChoice != null) parameters["toolChoice"] = OamBridge.ToolChoiceValue(toolChoice);
            Action<Dictionary<string, object>> handler = null;
            if (onLine != null || onEmotion != null || onEvent != null)
            {
                parameters["stream"] = true;
                var shown = "";
                handler = notification =>
                {
                    if (!(notification.TryGetValue("event", out var e) && e is Dictionary<string, object> evt)) return;
                    onEvent?.Invoke(evt);
                    evt.TryGetValue("type", out var typeValue);
                    switch (typeValue as string)
                    {
                        case "emotion":
                            onEmotion?.Invoke(evt.TryGetValue("emotion", out var emotion) ? emotion as string : "neutral");
                            break;
                        case "lineDelta":
                            shown += evt.TryGetValue("delta", out var delta) ? delta as string : "";
                            onLine?.Invoke(shown);
                            break;
                        case "lineReset":
                            shown = evt.TryGetValue("line", out var reset) ? reset as string ?? "" : "";
                            onLine?.Invoke(shown);
                            break;
                    }
                };
            }
            return (Dictionary<string, object>)await Bridge.RequestAsync("npc/talk", parameters, handler).ConfigureAwait(false);
        }

        /// <summary>A short ambient line (fast, no history). Throws on guardrail blocks: skip the bark.</summary>
        public async Task<string> BarkAsync(string situation = null)
        {
            var parameters = new Dictionary<string, object> { ["npc"] = Id };
            if (situation != null) parameters["situation"] = situation;
            var result = (Dictionary<string, object>)await Bridge.RequestAsync("npc/bark", parameters).ConfigureAwait(false);
            return (string)result["line"];
        }

        /// <summary>The save state (persona, memory, transcript, options, tools, world); store it with
        /// Json.Serialize and pass it to <see cref="OamBridge.RestoreNpcAsync"/>.</summary>
        public async Task<object> StateAsync(bool settle = true)
        {
            var result = (Dictionary<string, object>)await Bridge.RequestAsync("npc/state",
                new Dictionary<string, object> { ["npc"] = Id, ["settle"] = settle }).ConfigureAwait(false);
            return result["state"];
        }

        /// <summary>Merge-patches persona, options and memory (null values reset fields) and replaces the tools
        /// (names of registered tools). Applies from the next turn.</summary>
        public Task<object> UpdateAsync(Dictionary<string, object> persona = null, Dictionary<string, object> options = null,
            Dictionary<string, object> memory = null, IEnumerable<string> tools = null)
        {
            var parameters = new Dictionary<string, object> { ["npc"] = Id };
            if (persona != null) parameters["persona"] = persona;
            if (options != null) parameters["options"] = options;
            if (memory != null) parameters["memory"] = memory;
            if (tools != null) parameters["tools"] = Bridge.DefinitionsOf(tools);
            return Bridge.RequestAsync("npc/update", parameters);
        }

        public Task<object> ResetAsync(bool clearMemory = false) =>
            Bridge.RequestAsync("npc/reset", new Dictionary<string, object> { ["npc"] = Id, ["clearMemory"] = clearMemory });
        public Task<object> CancelAsync() => Bridge.RequestAsync("npc/cancel", new Dictionary<string, object> { ["npc"] = Id });
        public Task<object> DeleteAsync() => Bridge.RequestAsync("npc/delete", new Dictionary<string, object> { ["npc"] = Id });
    }

    /// <summary>A shared JSON world state (world/* methods). Paths are dot paths such as "player.gold";
    /// "" is the root.</summary>
    public sealed class OamWorld
    {
        public OamBridge Bridge { get; }
        public string Id { get; }

        internal OamWorld(OamBridge bridge, string id)
        {
            Bridge = bridge;
            Id = id;
        }

        /// <summary>The value at <paramref name="path"/>, or null when there is none.</summary>
        public async Task<object> GetAsync(string path = "")
        {
            var result = (Dictionary<string, object>)await Bridge.RequestAsync("world/get",
                new Dictionary<string, object> { ["world"] = Id, ["path"] = path }).ConfigureAwait(false);
            return result["value"];
        }

        /// <summary>Writes a value (null stores JSON null).</summary>
        public Task<object> SetAsync(string path, object value) =>
            Bridge.RequestAsync("world/set", new Dictionary<string, object> { ["world"] = Id, ["path"] = path, ["value"] = value });

        /// <summary>Applies a JSON merge patch (null members delete keys).</summary>
        public Task<object> MergeAsync(Dictionary<string, object> patch, string path = "") =>
            Bridge.RequestAsync("world/merge", new Dictionary<string, object> { ["world"] = Id, ["path"] = path, ["patch"] = patch });

        public Task<object> RemoveAsync(string path) =>
            Bridge.RequestAsync("world/remove", new Dictionary<string, object> { ["world"] = Id, ["path"] = path });

        public async Task<object> SnapshotAsync()
        {
            var result = (Dictionary<string, object>)await Bridge.RequestAsync("world/snapshot",
                new Dictionary<string, object> { ["world"] = Id }).ConfigureAwait(false);
            return result["state"];
        }

        /// <summary>Calls <paramref name="onChange"/> (on the dispatch thread) with every world/changed
        /// notification — "path", "oldValue"?, "newValue"? — at, inside or above <paramref name="path"/>.
        /// Returns the subscription id.</summary>
        public async Task<string> SubscribeAsync(Action<Dictionary<string, object>> onChange, string path = "")
        {
            var result = (Dictionary<string, object>)await Bridge.RequestAsync("world/subscribe",
                new Dictionary<string, object> { ["world"] = Id, ["path"] = path }).ConfigureAwait(false);
            var subscription = (string)result["subscription"];
            Bridge.SetWorldHandler(subscription, onChange);
            return subscription;
        }

        public Task<object> UnsubscribeAsync(string subscription)
        {
            Bridge.SetWorldHandler(subscription, null);
            return Bridge.RequestAsync("world/unsubscribe", new Dictionary<string, object> { ["subscription"] = subscription });
        }

        public Task<object> DeleteAsync() => Bridge.RequestAsync("world/delete", new Dictionary<string, object> { ["world"] = Id });
    }

#if UNITY_5_3_OR_NEWER
    /// <summary>Owns an <see cref="OamBridge"/>, pumps it every frame and disposes it with the GameObject.</summary>
    public sealed class OamBridgeRunner : MonoBehaviour
    {
        public OamBridge Bridge { get; private set; }

        /// <summary>Creates a persistent GameObject with a runner and a new bridge.</summary>
        public static OamBridgeRunner Create(string name = "OpenAppleModels")
        {
            var gameObject = new GameObject(name);
            DontDestroyOnLoad(gameObject);
            var runner = gameObject.AddComponent<OamBridgeRunner>();
            runner.Bridge = new OamBridge();
            return runner;
        }

        private void Update() => Bridge?.Pump();

        private void OnDestroy()
        {
            Bridge?.Dispose();
            Bridge = null;
        }
    }
#endif

    /// <summary>Minimal JSON codec: objects are Dictionary&lt;string, object&gt;, arrays List&lt;object&gt;,
    /// numbers long (integral) or double, plus string, bool and null.</summary>
    public static class Json
    {
        public static object Parse(string text)
        {
            var parser = new Parser(text);
            var value = parser.ParseValue(0);
            parser.SkipWhitespace();
            if (!parser.AtEnd) throw new FormatException("Unexpected trailing characters in JSON");
            return value;
        }

        public static string Serialize(object value)
        {
            var builder = new StringBuilder();
            Write(builder, value, 0);
            return builder.ToString();
        }

        private static void Write(StringBuilder builder, object value, int depth)
        {
            if (depth > 100) throw new InvalidOperationException("JSON nesting too deep");
            switch (value)
            {
                case null: builder.Append("null"); break;
                case string s: WriteString(builder, s); break;
                case bool b: builder.Append(b ? "true" : "false"); break;
                case double d: builder.Append(double.IsNaN(d) || double.IsInfinity(d) ? "null" : d.ToString("R", CultureInfo.InvariantCulture)); break;
                case float f: builder.Append(float.IsNaN(f) || float.IsInfinity(f) ? "null" : ((double)f).ToString("R", CultureInfo.InvariantCulture)); break;
                case decimal m: builder.Append(m.ToString(CultureInfo.InvariantCulture)); break;
                case int _: case long _: case short _: case byte _: case uint _: case ulong _: case ushort _: case sbyte _:
                    builder.Append(Convert.ToString(value, CultureInfo.InvariantCulture)); break;
                case Enum e: WriteString(builder, e.ToString()); break;
                case IDictionary dictionary:
                    builder.Append('{');
                    var first = true;
                    foreach (DictionaryEntry entry in dictionary)
                    {
                        if (!first) builder.Append(',');
                        first = false;
                        WriteString(builder, Convert.ToString(entry.Key, CultureInfo.InvariantCulture));
                        builder.Append(':');
                        Write(builder, entry.Value, depth + 1);
                    }
                    builder.Append('}');
                    break;
                case IEnumerable list:
                    builder.Append('[');
                    var firstItem = true;
                    foreach (var item in list)
                    {
                        if (!firstItem) builder.Append(',');
                        firstItem = false;
                        Write(builder, item, depth + 1);
                    }
                    builder.Append(']');
                    break;
                default: WriteString(builder, value.ToString()); break;
            }
        }

        private static void WriteString(StringBuilder builder, string text)
        {
            builder.Append('"');
            foreach (var ch in text)
            {
                switch (ch)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    default:
                        if (ch < 0x20 || ch == (char)0x2028 || ch == (char)0x2029) builder.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                        else builder.Append(ch);
                        break;
                }
            }
            builder.Append('"');
        }

        private sealed class Parser
        {
            private readonly string _text;
            private int _index;

            public Parser(string text) { _text = text ?? ""; }

            public bool AtEnd => _index >= _text.Length;

            public void SkipWhitespace()
            {
                while (_index < _text.Length && (_text[_index] == ' ' || _text[_index] == '\t' || _text[_index] == '\n' || _text[_index] == '\r')) _index++;
            }

            private FormatException Error(string message) => new FormatException(message + " at " + _index);

            public object ParseValue(int depth)
            {
                if (depth > 100) throw Error("JSON nesting too deep");
                SkipWhitespace();
                if (AtEnd) throw Error("Unexpected end of JSON");
                var ch = _text[_index];
                switch (ch)
                {
                    case '{': return ParseObject(depth);
                    case '[': return ParseArray(depth);
                    case '"': return ParseString();
                    case 't': Expect("true"); return true;
                    case 'f': Expect("false"); return false;
                    case 'n': Expect("null"); return null;
                    default:
                        if (ch == '-' || (ch >= '0' && ch <= '9')) return ParseNumber();
                        throw Error("Unexpected character '" + ch + "'");
                }
            }

            private void Expect(string literal)
            {
                if (string.CompareOrdinal(_text, _index, literal, 0, literal.Length) != 0) throw Error("Invalid literal");
                _index += literal.Length;
            }

            private Dictionary<string, object> ParseObject(int depth)
            {
                var result = new Dictionary<string, object>();
                _index++;
                SkipWhitespace();
                if (!AtEnd && _text[_index] == '}') { _index++; return result; }
                while (true)
                {
                    SkipWhitespace();
                    if (AtEnd || _text[_index] != '"') throw Error("Expected object key");
                    var key = ParseString();
                    SkipWhitespace();
                    if (AtEnd || _text[_index] != ':') throw Error("Expected ':'");
                    _index++;
                    result[key] = ParseValue(depth + 1);
                    SkipWhitespace();
                    if (AtEnd) throw Error("Unterminated object");
                    if (_text[_index] == ',') { _index++; continue; }
                    if (_text[_index] == '}') { _index++; return result; }
                    throw Error("Expected ',' or '}'");
                }
            }

            private List<object> ParseArray(int depth)
            {
                var result = new List<object>();
                _index++;
                SkipWhitespace();
                if (!AtEnd && _text[_index] == ']') { _index++; return result; }
                while (true)
                {
                    result.Add(ParseValue(depth + 1));
                    SkipWhitespace();
                    if (AtEnd) throw Error("Unterminated array");
                    if (_text[_index] == ',') { _index++; continue; }
                    if (_text[_index] == ']') { _index++; return result; }
                    throw Error("Expected ',' or ']'");
                }
            }

            private string ParseString()
            {
                var builder = new StringBuilder();
                _index++;
                while (!AtEnd)
                {
                    var ch = _text[_index++];
                    if (ch == '"') return builder.ToString();
                    if (ch != '\\') { builder.Append(ch); continue; }
                    if (AtEnd) break;
                    var escape = _text[_index++];
                    switch (escape)
                    {
                        case '"': builder.Append('"'); break;
                        case '\\': builder.Append('\\'); break;
                        case '/': builder.Append('/'); break;
                        case 'b': builder.Append('\b'); break;
                        case 'f': builder.Append('\f'); break;
                        case 'n': builder.Append('\n'); break;
                        case 'r': builder.Append('\r'); break;
                        case 't': builder.Append('\t'); break;
                        case 'u':
                            if (_index + 4 > _text.Length) throw Error("Truncated \\u escape");
                            builder.Append((char)int.Parse(_text.Substring(_index, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                            _index += 4;
                            break;
                        default: throw Error("Invalid escape");
                    }
                }
                throw Error("Unterminated string");
            }

            private object ParseNumber()
            {
                var start = _index;
                if (_text[_index] == '-') _index++;
                var integral = true;
                while (!AtEnd)
                {
                    var ch = _text[_index];
                    if (ch >= '0' && ch <= '9') { _index++; continue; }
                    if (ch == '.' || ch == 'e' || ch == 'E' || ch == '+' || ch == '-') { integral = false; _index++; continue; }
                    break;
                }
                var token = _text.Substring(start, _index - start);
                if (integral && long.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out var whole)) return whole;
                if (double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)) return number;
                throw Error("Invalid number '" + token + "'");
            }
        }
    }
}
