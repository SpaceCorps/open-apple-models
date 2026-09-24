import Foundation
import OpenAppleModels
import Synchronization

/// What a method handler returns.
///
/// Handlers run one at a time, in the order messages arrive, so a client can
/// pipeline `session/create` and `session/respond` without waiting. That
/// makes the handler itself the place for validation and anything
/// order-sensitive; slow work (model turns, waiting for other turns) must be
/// returned as ``deferred(_:)`` so the next message can be processed.
public enum BridgeReply: Sendable {
    /// The result, ready now.
    case result(JSONValue)
    /// Work that finishes later. It runs concurrently with other requests;
    /// its result (or thrown error) becomes the response. Cancelled on
    /// `shutdown`.
    case deferred(@Sendable () async throws -> JSONValue)
}

/// A method implementation. Errors are converted with
/// ``BridgeError/init(normalizing:)``: throw a ``BridgeError`` for exact
/// control, or any error (for example an ``AgentError``) for automatic mapping.
public typealias BridgeMethodHandler = @Sendable (BridgeRequest) async throws -> BridgeReply

/// The table of methods a ``BridgeEngine`` serves.
///
/// ```swift
/// registry.register("npc/say") { request in
///     let npc = try store.npc(request.params.string("npc"))
///     let prompt = try request.params.string("text")
///     let stream = try request.params.optionalBool("stream") ?? false
///     return .deferred {
///         let run = npc.agent.run(prompt)
///         let response = try await request.drive(run, stream: stream, context: ["npc": .string(npc.id)])
///         return .object(BridgeCoding.json(response))
///     }
/// }
/// ```
public struct BridgeMethodRegistry: Sendable {
    private(set) var handlers: [String: BridgeMethodHandler] = [:]

    public init() {}

    /// Registers (or replaces) a method. Names use `namespace/verb`.
    public mutating func register(_ method: String, _ handler: @escaping BridgeMethodHandler) {
        handlers[method] = handler
    }

    /// Removes a method.
    public mutating func unregister(_ method: String) {
        handlers[method] = nil
    }

    /// Registered method names, sorted.
    public var methods: [String] { handlers.keys.sorted() }

    public func handler(for method: String) -> BridgeMethodHandler? { handlers[method] }
}

/// A set of methods plugged into a ``BridgeEngine`` through
/// ``BridgeConfiguration/extensions`` (e.g. NPC, decision and world methods).
///
/// Extensions keep their own state (use a `final class` with a `Mutex`) and
/// reuse the engine's helpers: ``BridgeRequest/drive(_:stream:context:eventMethod:)``
/// runs an agent turn with streaming and client tools, ``BridgeCoding`` parses
/// and encodes the shared JSON shapes, and ``BridgeEngine/makeModel(_:)``
/// resolves `model` parameters.
///
/// The engine owns its extensions, so an extension must not keep a strong
/// reference to the engine; use ``BridgeRequest/engine`` inside handlers.
public protocol BridgeExtension: Sendable {
    /// Registers the extension's methods. Called once, when the engine starts.
    /// Built-in methods are registered first, so an extension may override them.
    func register(in registry: inout BridgeMethodRegistry, engine: BridgeEngine)

    /// Notification methods the extension sends (e.g. `npc/event`), listed in
    /// `initialize`'s `capabilities.notifications`. Defaults to none.
    var notificationMethods: [String] { get }

    /// Cancels the extension's work. Called on `shutdown` and when the engine closes.
    func shutdown() async
}

extension BridgeExtension {
    public var notificationMethods: [String] { [] }
    public func shutdown() async {}
}

/// One incoming request or notification, as seen by a method handler.
public struct BridgeRequest: Sendable {
    /// The engine serving the request.
    public let engine: BridgeEngine
    /// The method name.
    public let method: String
    /// The request id; `nil` for notifications (no response is sent).
    public let id: JSONRPCID?
    /// The by-name parameters (empty when absent).
    public let params: BridgeParams

    public init(engine: BridgeEngine, method: String, id: JSONRPCID?, params: BridgeParams) {
        self.engine = engine
        self.method = method
        self.id = id
        self.params = params
    }

    /// Whether the peer expects a response.
    public var isNotification: Bool { id == nil }

    /// Sends a notification to the peer.
    public func notify(_ method: String, _ params: JSONValue) {
        engine.notify(method, params)
    }
}

// MARK: - One-shot value

/// A value that is set once and awaited by any number of tasks.
final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Mutex(State())

    /// Sets the value; returns false if it was already set.
    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let waiters: [CheckedContinuation<Value, Never>]? = state.withLock { state in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: value) }
        return true
    }

    var current: Value? { state.withLock { $0.value } }

    /// Waits for the value. Does not observe cancellation; pair it with a
    /// cancellation handler that resolves the value.
    func value() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let ready: Value? = state.withLock { state in
                if let value = state.value { return value }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
