import Foundation
import FoundationModels
import OpenAppleModels
import Synchronization

/// A transport-agnostic JSON-RPC 2.0 engine that lets game engines and other
/// languages drive agents: the stdio CLI pipes it over stdin/stdout, and the
/// C ABI (`OpenAppleModelsFFI`) exposes the same messages to Unity, Godot,
/// Unreal, Python and friends. See `docs/PROTOCOL.md` for the message reference.
///
/// ```swift
/// let engine = BridgeEngine { line in print(line) }   // outgoing messages
/// engine.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
/// ```
///
/// **Ordering.** Incoming requests are handled in arrival order: each
/// handler validates its input and does its order-sensitive part before the
/// next message is looked at, then long work (model turns) continues
/// concurrently. Turn-affecting operations on one session run in arrival
/// order. Responses from the peer (to our `tool/call` requests) bypass that
/// queue, so a slow turn never blocks them.
///
/// **Delivery.** Outgoing messages are single-line JSON strings passed to
/// `send` one at a time, from a private serial queue, in the order they were
/// produced. For a request, every notification and `tool/call` it causes is
/// sent before its response.
public final class BridgeEngine: Sendable {
    public let configuration: BridgeConfiguration

    private let outbox: Outbox
    private let inbound: AsyncStream<Inbound>.Continuation
    private let state: Mutex<State>

    private enum Phase: Equatable {
        case running
        case shutDown
        case closed
    }

    private struct State {
        var registry = BridgeMethodRegistry()
        var sessions: [String: BridgeSession] = [:]
        var sessionOrder: [String] = []
        var clientRequests: [String: ClientRequest] = [:]
        var nextClientRequest = 1
        var nextLocalCall = 1
        var nextSession = 1
        var nextToken = 0
        var deferred: [Int: Task<Void, Never>] = [:]
        var phase = Phase.running
        var client: JSONValue?
        var shutdownHookPending = false
    }

    struct Inbound: Sendable {
        var method: String
        var id: JSONRPCID?
        var params: JSONValue?
        var sink: Sink
    }

    enum Sink: Sendable {
        /// Reply through `send`.
        case peer
        /// Reply to an in-process ``call(_:_:id:)``.
        case local(LocalCall)
    }

    /// Creates an engine.
    /// - Parameters:
    ///   - configuration: Model factory, limits, logger and extensions.
    ///   - send: Receives each outgoing message as one line of JSON (no
    ///     trailing newline). Called from a private serial queue, never
    ///     concurrently with itself.
    public init(configuration: BridgeConfiguration = BridgeConfiguration(), send: @escaping @Sendable (String) -> Void) {
        self.configuration = configuration
        outbox = Outbox(deliver: send)
        let (stream, continuation) = AsyncStream<Inbound>.makeStream(bufferingPolicy: .unbounded)
        inbound = continuation
        state = Mutex(State())

        var registry = BridgeMethodRegistry()
        BuiltinMethods.register(in: &registry)
        for bridgeExtension in configuration.extensions {
            bridgeExtension.register(in: &registry, engine: self)
        }
        state.withLock { $0.registry = registry }

        Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                await self.process(item)
            }
        }
    }

    deinit {
        inbound.finish()
    }

    // MARK: Incoming messages

    /// Handles one incoming message (a request, a notification, or a response
    /// to one of the engine's own requests). Returns immediately; results are
    /// delivered through `send`. Blank lines are ignored.
    public func receive(_ line: String) {
        guard line.contains(where: { !$0.isWhitespace }) else { return }
        let message: JSONValue
        do {
            message = try JSONValue(parsing: line)
        } catch {
            outbox.send(JSONRPCMessage.error(id: nil, .parseError(error.description)))
            return
        }
        receive(message: message)
    }

    /// Handles one already-parsed incoming message.
    public func receive(message: JSONValue) {
        guard case .object(let object) = message else {
            let reason = message.arrayValue != nil
                ? "Batch requests are not supported; send one message per line."
                : "A JSON-RPC message must be an object."
            outbox.send(JSONRPCMessage.error(id: nil, .invalidRequest(reason)))
            return
        }
        let rawID = object["id"]
        let id = rawID.flatMap(JSONRPCID.init)
        guard object["jsonrpc"] == "2.0" else {
            outbox.send(JSONRPCMessage.error(id: id, .invalidRequest("Missing or unsupported 'jsonrpc' version; expected \"2.0\".")))
            return
        }
        if let rawID, id == nil {
            outbox.send(JSONRPCMessage.error(id: nil, .invalidRequest(JSONRPCID.rejectionReason(rawID))))
            return
        }
        if let methodValue = object["method"] {
            guard let method = methodValue.stringValue, !method.isEmpty else {
                outbox.send(JSONRPCMessage.error(id: id, .invalidRequest("'method' must be a non-empty string.")))
                return
            }
            enqueue(Inbound(method: method, id: id, params: object["params"], sink: .peer))
            return
        }
        if let id, object["result"] != nil || object["error"] != nil {
            let result: Result<JSONValue, BridgeError> = if let error = object["error"] {
                .failure(BridgeError(json: error))
            } else {
                .success(object["result"] ?? .null)
            }
            completeClientRequest(id: id, with: result)
            return
        }
        outbox.send(JSONRPCMessage.error(id: id, .invalidRequest("A message needs 'method' (request or notification) or 'result'/'error' (response).")))
    }

    /// Calls a method in-process and returns its result, as if a peer had
    /// sent the request. Notifications and `tool/call` requests the method
    /// causes still go through `send` (answer those with ``receive(_:)``).
    /// Cancelling the calling task cancels the request.
    ///
    /// - Parameter id: The request id those notifications and `tool/call`
    ///   requests carry as `requestId`, so the caller can route them. When
    ///   `nil`, a private `local-<n>` id is used.
    public func call(_ method: String, _ params: JSONValue? = nil, id callerID: JSONRPCID? = nil) async throws(BridgeError) -> JSONValue {
        let local = LocalCall()
        let id = callerID ?? state.withLock { state in
            defer { state.nextLocalCall += 1 }
            return JSONRPCID("local-\(state.nextLocalCall)")
        }
        guard case .enqueued = inbound.yield(Inbound(method: method, id: id, params: params, sink: .local(local))) else {
            throw .shutDown
        }
        let result = await withTaskCancellationHandler {
            await local.result()
        } onCancel: {
            local.cancel()
        }
        return try result.get()
    }

    /// Waits until every message produced so far has been passed to `send`.
    public func flush() async {
        await outbox.flush()
    }

    private func enqueue(_ item: Inbound) {
        if case .terminated = inbound.yield(item) {
            log(.debug, "Dropped '\(item.method)': the engine is closed.")
        }
    }

    private func process(_ item: Inbound) async {
        let (handler, phase) = state.withLock { ($0.registry.handler(for: item.method), $0.phase) }
        guard phase == .running else {
            deliver(.failure(.shutDown), to: item)
            return
        }
        guard let handler else {
            deliver(.failure(.methodNotFound(item.method)), to: item)
            return
        }
        let reply: BridgeReply
        do {
            let request = BridgeRequest(engine: self, method: item.method, id: item.id, params: try BridgeParams(item.params))
            reply = try await handler(request)
        } catch {
            deliver(.failure(BridgeError(normalizing: error)), to: item)
            return
        }
        switch reply {
        case .result(let value):
            deliver(.success(value), to: item)
        case .deferred(let work):
            startDeferred(work, for: item)
        }
        fireShutdownHookIfPending()
    }

    private func startDeferred(_ work: @escaping @Sendable () async throws -> JSONValue, for item: Inbound) {
        let started = state.withLock { state -> Bool in
            guard state.phase == .running else { return false }
            let token = state.nextToken
            state.nextToken += 1
            // Registered under the lock, so the task's own removal (which
            // takes the lock) always happens after the insertion.
            let task = Task { [self] in
                let result: Result<JSONValue, BridgeError>
                do {
                    result = .success(try await work())
                } catch {
                    result = .failure(BridgeError(normalizing: error))
                }
                _ = self.state.withLock { $0.deferred.removeValue(forKey: token) }
                self.deliver(result, to: item)
            }
            state.deferred[token] = task
            if case .local(let call) = item.sink { call.attach(task) }
            return true
        }
        if !started { deliver(.failure(.shutDown), to: item) }
    }

    private func deliver(_ result: Result<JSONValue, BridgeError>, to item: Inbound) {
        switch item.sink {
        case .peer:
            guard let id = item.id else {
                if case .failure(let error) = result {
                    log(.debug, "Notification '\(item.method)' failed: \(error)")
                }
                return
            }
            switch result {
            case .success(let value): outbox.send(JSONRPCMessage.result(id: id, value))
            case .failure(let error): outbox.send(JSONRPCMessage.error(id: id, error))
            }
        case .local(let call):
            call.resolve(result)
        }
    }

    // MARK: Outgoing messages

    /// Sends a notification to the peer.
    public func notify(_ method: String, _ params: JSONValue) {
        outbox.send(JSONRPCMessage.notification(method: method, params: params))
    }

    /// Sends a request to the peer (for example `tool/call`) and returns a
    /// handle for its response. The message is queued for delivery before
    /// this returns, so it is ordered before anything sent afterwards.
    public func sendRequest(_ method: String, params: JSONValue) -> ClientRequest {
        let request = state.withLock { state -> ClientRequest? in
            guard state.phase == .running else { return nil }
            let id = "t-\(state.nextClientRequest)"
            state.nextClientRequest += 1
            let request = ClientRequest(id: id, method: method) { [weak self] id in
                _ = self?.state.withLock { $0.clientRequests.removeValue(forKey: id) }
            }
            state.clientRequests[id] = request
            return request
        }
        guard let request else {
            let failed = ClientRequest(id: "t-0", method: method) { _ in }
            failed.complete(.failure(.shutDown))
            return failed
        }
        outbox.send(JSONRPCMessage.request(id: JSONRPCID(request.id), method: method, params: params))
        return request
    }

    private func completeClientRequest(id: JSONRPCID, with result: Result<JSONValue, BridgeError>) {
        let key = id.value.stringValue ?? id.description
        guard let request = state.withLock({ $0.clientRequests.removeValue(forKey: key) }) else {
            log(.warning, "Ignoring a response to unknown or finished request '\(id)'.")
            return
        }
        request.complete(result)
    }

    // MARK: Sessions

    /// Looks up a session.
    public func session(_ id: String) throws(BridgeError) -> BridgeSession {
        guard let session = state.withLock({ $0.sessions[id] }) else { throw .sessionNotFound(id) }
        return session
    }

    /// Live sessions, in creation order.
    public var sessions: [BridgeSession] {
        state.withLock { state in state.sessionOrder.compactMap { state.sessions[$0] } }
    }

    /// Adds a session, enforcing ``BridgeConfiguration/maxSessions`` and unique ids.
    public func insert(_ session: BridgeSession) throws(BridgeError) {
        let limit = configuration.maxSessions
        try state.withLock { state throws(BridgeError) in
            guard state.phase == .running else { throw .shutDown }
            guard state.sessions[session.id] == nil else { throw .sessionExists(session.id) }
            guard state.sessions.count < limit else { throw .sessionLimitReached(limit) }
            state.sessions[session.id] = session
            state.sessionOrder.append(session.id)
        }
    }

    /// Removes a session and cancels its running and queued turns.
    @discardableResult
    public func removeSession(_ id: String) -> BridgeSession? {
        let session = state.withLock { state -> BridgeSession? in
            guard let session = state.sessions.removeValue(forKey: id) else { return nil }
            state.sessionOrder.removeAll { $0 == id }
            return session
        }
        session?.cancelAll()
        return session
    }

    /// Whether a session id is free to use.
    public func isSessionIDAvailable(_ id: String) -> Bool {
        state.withLock { $0.sessions[id] == nil }
    }

    /// Generates an unused session id (`s1`, `s2`, …).
    public func makeSessionID() -> String {
        state.withLock { state in
            while true {
                let id = "s\(state.nextSession)"
                state.nextSession += 1
                if state.sessions[id] == nil { return id }
            }
        }
    }

    /// Creates a language model for a `model` parameter via
    /// ``BridgeConfiguration/modelFactory``.
    public func makeModel(_ spec: BridgeModelSpec) throws(BridgeError) -> any LanguageModel {
        if case .scripted = spec, !configuration.allowsScriptedModels {
            throw .invalidParams("Scripted models are disabled on this bridge.")
        }
        do {
            return try configuration.modelFactory(spec)
        } catch {
            throw BridgeError(normalizing: error)
        }
    }

    // MARK: Lifecycle

    /// Client information from `initialize`, if the peer sent any.
    public var clientInfo: JSONValue? { state.withLock { $0.client } }

    func recordClient(_ info: JSONValue?) {
        state.withLock { $0.client = info }
    }

    /// Registered method names, sorted.
    public var methods: [String] { state.withLock { $0.registry.methods } }

    /// Registers (or replaces) a method at runtime.
    public func register(_ method: String, _ handler: @escaping BridgeMethodHandler) {
        state.withLock { $0.registry.register(method, handler) }
    }

    /// Whether `shutdown` (or ``close()``) has run.
    public var isShutDown: Bool { state.withLock { $0.phase != .running } }

    /// How long ``shutdown()`` waits for extensions and cancelled requests.
    static let shutdownGracePeriod: Duration = .seconds(2)

    /// Cancels all turns, fails pending `tool/call` requests, removes all
    /// sessions and shuts down extensions. Later requests fail with
    /// `shut_down`. Waits at most about two seconds for extensions to shut
    /// down and for cancelled requests to send their error responses; work
    /// that ignores cancellation is left to finish in the background.
    public func shutdown() async {
        guard let work = takeEverything(nextPhase: .shutDown) else { return }
        for session in work.sessions { session.cancelAll() }
        for request in work.requests { request.complete(.failure(.shutDown)) }
        for task in work.tasks { task.cancel() }
        let extensions = configuration.extensions
        let tasks = work.tasks
        await Self.run(for: Self.shutdownGracePeriod) {
            for bridgeExtension in extensions { await bridgeExtension.shutdown() }
            for task in tasks { await task.value }
        }
    }

    /// Runs `work` in a new task and returns when it finishes or `limit`
    /// has passed, whichever comes first. Nothing here awaits the work
    /// structurally, so the bound holds even when the work cannot be
    /// cancelled (`Task.value` never is).
    static func run(for limit: Duration, _ work: @escaping @Sendable () async -> Void) async {
        let finished = OneShot<Void>()
        Task {
            await work()
            finished.resolve(())
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            finished.resolve(())
        }
        await finished.value()
        timer.cancel()
    }

    /// Shuts down immediately without waiting, and stops delivering
    /// messages: once this returns, `send` is never called again (unless
    /// `close()` is called from inside `send`, in which case the current
    /// call is the last). Used by the C ABI's `oam_bridge_destroy`.
    public func close() {
        let work = takeEverything(nextPhase: .closed)
        inbound.finish()
        if let work {
            for session in work.sessions { session.cancelAll() }
            for request in work.requests { request.complete(.failure(.shutDown)) }
            for task in work.tasks { task.cancel() }
            let extensions = configuration.extensions
            if !extensions.isEmpty {
                Task { for bridgeExtension in extensions { await bridgeExtension.shutdown() } }
            }
        }
        outbox.close()
    }

    func markShutdownHookPending() {
        state.withLock { $0.shutdownHookPending = true }
    }

    private func fireShutdownHookIfPending() {
        let fire = state.withLock { state in
            defer { state.shutdownHookPending = false }
            return state.shutdownHookPending
        }
        if fire, let hook = configuration.onShutdown { outbox.perform(hook) }
    }

    private struct Teardown {
        var sessions: [BridgeSession]
        var requests: [ClientRequest]
        var tasks: [Task<Void, Never>]
    }

    private func takeEverything(nextPhase: Phase) -> Teardown? {
        state.withLock { state -> Teardown? in
            let wasRunning = state.phase == .running
            if nextPhase == .closed || wasRunning { state.phase = nextPhase }
            guard wasRunning else { return nil }
            let teardown = Teardown(
                sessions: state.sessionOrder.compactMap { state.sessions[$0] },
                requests: Array(state.clientRequests.values),
                tasks: Array(state.deferred.values))
            state.sessions = [:]
            state.sessionOrder = []
            state.clientRequests = [:]
            return teardown
        }
    }

    func log(_ level: BridgeLogLevel, _ message: @autoclosure () -> String) {
        configuration.logger?(level, message())
    }
}

// MARK: - Client requests

/// A request the engine sent to the peer (such as `tool/call`), awaiting
/// the peer's response.
public final class ClientRequest: Sendable {
    /// The JSON-RPC id used on the wire (`t-<n>`).
    public let id: String
    public let method: String

    private let outcome = OneShot<Result<JSONValue, BridgeError>>()
    private let forget: @Sendable (String) -> Void

    init(id: String, method: String, forget: @escaping @Sendable (String) -> Void) {
        self.id = id
        self.method = method
        self.forget = forget
    }

    /// Waits for the peer's response. A JSON-RPC error response becomes a
    /// failure. Cancelling the waiting task cancels the request.
    public func result() async -> Result<JSONValue, BridgeError> {
        await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            self.cancel()
        }
    }

    /// Waits for the peer's response, throwing its error.
    public func response() async throws(BridgeError) -> JSONValue {
        try await result().get()
    }

    /// Stops waiting; a later response from the peer is ignored.
    public func cancel() {
        if outcome.resolve(.failure(.cancelled("The request was cancelled."))) { forget(id) }
    }

    /// Whether a response (or cancellation) has arrived.
    public var isFinished: Bool { outcome.current != nil }

    func complete(_ result: Result<JSONValue, BridgeError>) {
        outcome.resolve(result)
    }
}

/// The reply slot of an in-process ``BridgeEngine/call(_:_:id:)``.
final class LocalCall: Sendable {
    private let outcome = OneShot<Result<JSONValue, BridgeError>>()
    private let work = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))

    func attach(_ task: Task<Void, Never>) {
        let cancelled = work.withLock { state in
            state.task = task
            return state.cancelled
        }
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = work.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
        outcome.resolve(.failure(.cancelled("The call was cancelled.")))
    }

    func resolve(_ result: Result<JSONValue, BridgeError>) {
        outcome.resolve(result)
    }

    func result() async -> Result<JSONValue, BridgeError> {
        await outcome.value()
    }
}

// MARK: - Outbox

/// Delivers outgoing lines one at a time, in order, from a serial queue.
final class Outbox: Sendable {
    private let queue = DispatchQueue(label: "dev.spacecorps.open-apple-models.bridge.outbox", qos: .userInitiated)
    private let deliver: @Sendable (String) -> Void
    /// `closed`, and the thread currently inside `deliver` (0 when idle).
    private let state = Mutex<(closed: Bool, thread: UInt)>((false, 0))

    init(deliver: @escaping @Sendable (String) -> Void) {
        self.deliver = deliver
    }

    private static var currentThread: UInt { UInt(bitPattern: pthread_self()) }

    func send(_ line: String) {
        perform { [deliver] in deliver(line) }
    }

    /// Runs `action` on the delivery queue, after everything queued before it.
    func perform(_ action: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            let open = state.withLock { state in
                if !state.closed { state.thread = Self.currentThread }
                return !state.closed
            }
            guard open else { return }
            action()
            state.withLock { $0.thread = 0 }
        }
    }

    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Stops delivery. Waits for an in-progress delivery unless called from
    /// inside it.
    func close() {
        let insideDelivery = state.withLock { state in
            state.closed = true
            return state.thread == Self.currentThread
        }
        if !insideDelivery { queue.sync {} }
    }
}
