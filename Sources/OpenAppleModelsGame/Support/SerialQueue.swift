import Foundation
import Synchronization

/// Runs async jobs one at a time, in submission order.
///
/// Used by ``NPC`` so a conversation turn, its bookkeeping (memory,
/// compaction) and the next turn never interleave.
final class SerialQueue: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    @discardableResult
    func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        tail.withLock { tail in
            let previous = tail
            let task = Task {
                await previous?.value
                await work()
            }
            tail = task
            return task
        }
    }

    /// Runs `work` after every job enqueued so far and returns its result.
    func perform<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: await work()) }
        }
    }

    /// Waits until every job enqueued so far (and any enqueued meanwhile) has finished.
    func waitUntilIdle() async {
        while true {
            let current = tail.withLock { $0 }
            guard let current else { return }
            await current.value
            let latest = tail.withLock { $0 }
            if latest == current { return }
        }
    }
}
