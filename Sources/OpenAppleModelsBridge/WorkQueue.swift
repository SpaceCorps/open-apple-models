import Foundation
import OpenAppleModels
import Synchronization

/// Runs operations one after another in the order they were scheduled.
/// Each session and each NPC has one, so pipelined requests apply in
/// arrival order.
///
/// **Cancellation and results agree.** A cancelled operation must not report
/// `cancelled` and then change state anyway (or the reverse):
///
/// - Work that changes state calls ``commit()`` right before the change.
///   It throws `cancelled` if the operation was already cancelled; otherwise
///   the operation passes its point of no return: later cancellation no
///   longer applies to it (``cancelAll()`` skips it) and its result is
///   reported as-is.
/// - Work whose change happens elsewhere (a model turn committing its
///   transcript) calls ``markCommitted()`` once the change has happened.
/// - Work that returns successfully after being cancelled without reaching
///   a commit point is reported as `cancelled`.
final class WorkQueue: Sendable {
    private struct Item {
        var task: Task<Void, Never>?
        var cancelled = false
        var committed = false
    }

    private struct State {
        var tail: Task<Void, Never>?
        var items: [Int: Item] = [:]
        var nextToken = 0
    }

    /// Identifies the operation running in the current task.
    private struct Slot: Sendable {
        let queue: WorkQueue
        let token: Int
    }

    @TaskLocal private static var current: Slot?

    private let state = Mutex(State())

    /// Queues `work` behind earlier work and returns a reply that completes
    /// with its result. The queue position is taken now, so call this from
    /// the (ordered) method handler, not from inside deferred work.
    func schedule(_ work: @escaping @Sendable () async throws -> JSONValue) -> BridgeReply {
        let outcome = OneShot<Result<JSONValue, BridgeError>>()
        let token = state.withLock { state -> Int in
            let token = state.nextToken
            state.nextToken += 1
            let previous = state.tail
            // Registered under the lock, so everything the task does with
            // `state` happens after the insertion below.
            let task = Task { [self] in
                await previous?.value
                var result: Result<JSONValue, BridgeError>
                if Task.isCancelled {
                    result = .failure(.cancelled("The request was cancelled before it started."))
                } else {
                    do {
                        result = .success(try await Self.$current.withValue(Slot(queue: self, token: token)) {
                            try await work()
                        })
                    } catch {
                        result = .failure(BridgeError(normalizing: error))
                    }
                }
                let item = self.state.withLock { $0.items.removeValue(forKey: token) }
                if case .success = result, let item, item.cancelled, !item.committed {
                    result = .failure(.cancelled("The request was cancelled."))
                }
                outcome.resolve(result)
            }
            state.tail = task
            state.items[token] = Item(task: task)
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

    /// Cancels running and queued work that has not passed its commit
    /// point. Returns how many operations were cancelled.
    @discardableResult
    func cancelAll() -> Int {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            var tasks: [Task<Void, Never>] = []
            for (token, item) in state.items where !item.committed {
                state.items[token]?.cancelled = true
                if let task = item.task { tasks.append(task) }
            }
            return tasks
        }
        for task in tasks { task.cancel() }
        return tasks.count
    }

    /// Operations running or waiting.
    var pendingOperations: Int { state.withLock { $0.items.count } }

    private func cancel(token: Int) {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard let item = state.items[token], !item.committed else { return nil }
            state.items[token]?.cancelled = true
            return item.task
        }
        task?.cancel()
    }

    // MARK: Commit points

    /// Marks the current operation's point of no return: throws `cancelled`
    /// if it was cancelled, and otherwise makes it immune to later
    /// cancellation. Call right before changing state. Outside scheduled
    /// work, only checks `Task.isCancelled`.
    static func commit() throws(BridgeError) {
        guard let slot = current else {
            if Task.isCancelled { throw .cancelled("The request was cancelled.") }
            return
        }
        let cancelled = slot.queue.state.withLock { state -> Bool in
            guard let item = state.items[slot.token] else { return false }
            if item.cancelled { return true }
            state.items[slot.token]?.committed = true
            return false
        }
        if cancelled { throw .cancelled("The request was cancelled.") }
    }

    /// Records that the current operation's change has already happened
    /// (for example, a turn completed and is in the transcript), so it is
    /// reported as succeeded even if it was cancelled meanwhile.
    static func markCommitted() {
        guard let slot = current else { return }
        slot.queue.state.withLock { $0.items[slot.token]?.committed = true }
    }
}
