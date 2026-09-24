import Foundation
import FoundationModels
import OpenAppleModels
import Synchronization

/// An agent owned by a bridge client, addressed by id.
///
/// Turn-affecting operations (`session/respond`, `reset`, `compact`,
/// `setInstructions`, `setTools`, `setContextNote`) are queued with
/// ``schedule(_:)`` and run one after another in arrival order, so a client
/// can pipeline them. ``cancelAll()`` cancels the running and queued ones.
public final class BridgeSession: Sendable {
    public let id: String
    public let agent: Agent
    /// The model kind (`system`, `scripted` or a custom type).
    public let modelKind: String
    public let createdAt: Date
    /// Time limit applied to client tools added later via `session/setTools`.
    public let toolTimeout: Duration?

    private struct State {
        var tail: Task<Void, Never>?
        var work: [Int: Task<Void, Never>] = [:]
        var nextToken = 0
    }

    private let state = Mutex(State())

    public init(id: String, agent: Agent, modelKind: String, toolTimeout: Duration?, createdAt: Date = Date()) {
        self.id = id
        self.agent = agent
        self.modelKind = modelKind
        self.toolTimeout = toolTimeout
        self.createdAt = createdAt
    }

    /// Queues `work` behind this session's earlier work and returns a reply
    /// that completes with its result. The queue position is taken now, so
    /// call this from the (ordered) handler, not from inside deferred work.
    public func schedule(_ work: @escaping @Sendable () async throws -> JSONValue) -> BridgeReply {
        let outcome = OneShot<Result<JSONValue, BridgeError>>()
        let token = state.withLock { state -> Int in
            let token = state.nextToken
            state.nextToken += 1
            let previous = state.tail
            let task = Task { [self] in
                await previous?.value
                let result: Result<JSONValue, BridgeError>
                if Task.isCancelled {
                    result = .failure(.cancelled("The request was cancelled before it started."))
                } else {
                    do {
                        result = .success(try await work())
                    } catch {
                        result = .failure(BridgeError(normalizing: error))
                    }
                }
                _ = self.state.withLock { $0.work.removeValue(forKey: token) }
                outcome.resolve(result)
            }
            state.tail = task
            state.work[token] = task
            return token
        }
        return .deferred { [self] in
            let result = await withTaskCancellationHandler {
                await outcome.value()
            } onCancel: {
                self.cancel(token: token)
            }
            return try result.get()
        }
    }

    /// Cancels running and queued work. Returns how many operations were cancelled.
    @discardableResult
    public func cancelAll() -> Int {
        let tasks = state.withLock { Array($0.work.values) }
        for task in tasks { task.cancel() }
        return tasks.count
    }

    /// Operations running or waiting on this session.
    public var pendingOperations: Int { state.withLock { $0.work.count } }

    private func cancel(token: Int) {
        state.withLock { $0.work[token] }?.cancel()
    }

    /// A summary for `session/list`.
    public var summary: JSONValue {
        var object: JSONObject = [
            "session": .string(id),
            "model": .string(modelKind),
        ]
        if let instructions = agent.instructions { object["instructions"] = .string(instructions) }
        object["tools"] = .array(agent.tools.map { .string($0.name) })
        object["busy"] = .bool(pendingOperations > 0)
        object["pendingOperations"] = .number(Double(pendingOperations))
        object["entries"] = .number(Double(agent.history.count))
        object["createdAt"] = .string(Self.timestamp(createdAt))
        return .object(object)
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
