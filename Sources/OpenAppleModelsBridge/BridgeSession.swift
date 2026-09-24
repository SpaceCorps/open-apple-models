import Foundation
import FoundationModels
import OpenAppleModels

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

    private let queue = WorkQueue()

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
    ///
    /// Cancellation (``cancelAll()``, `session/delete`, `shutdown`) cancels
    /// the work's task. Work that finishes successfully after it was
    /// cancelled is reported as `cancelled`, so call ``commit()`` right
    /// before the work changes anything.
    public func schedule(_ work: @escaping @Sendable () async throws -> JSONValue) -> BridgeReply {
        queue.schedule(work)
    }

    /// Inside ``schedule(_:)`` work: marks the point of no return, right
    /// before the work changes state. Throws `cancelled` if the operation was
    /// already cancelled (then change nothing); otherwise later cancellation
    /// no longer applies to it and its result is reported as-is. Outside
    /// scheduled work it only checks `Task.isCancelled`.
    public static func commit() throws(BridgeError) {
        try WorkQueue.commit()
    }

    /// Cancels running and queued work. Returns how many operations were cancelled.
    @discardableResult
    public func cancelAll() -> Int {
        queue.cancelAll()
    }

    /// Operations running or waiting on this session.
    public var pendingOperations: Int { queue.pendingOperations }

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
