import Foundation
import Synchronization

/// A counting semaphore with a bounded FIFO queue, deadlines and cancellation.
final class ConcurrencyLimiter: Sendable {
    enum Outcome: Sendable, Equatable {
        case acquired
        case queueFull
        case timedOut
        case cancelled
    }

    private struct State {
        var active = 0
        var queue: [UInt64] = []
        var waiters: [UInt64: CheckedContinuation<Outcome, Never>] = [:]
        /// Waiters resolved (timed out or cancelled) before they registered.
        var early: [UInt64: Outcome] = [:]
        var nextID: UInt64 = 0
    }

    let limit: Int
    let maxQueued: Int
    private let state = Mutex(State())

    init(limit: Int, maxQueued: Int) {
        self.limit = max(1, limit)
        self.maxQueued = max(0, maxQueued)
    }

    /// Requests currently holding a slot.
    var activeCount: Int { state.withLock { $0.active } }
    /// Requests waiting for a slot.
    var queuedCount: Int { state.withLock { $0.queue.count } }

    /// Waits for a slot until `deadline`. On `.acquired` the caller must
    /// call ``release()`` exactly once.
    func acquire(until deadline: ContinuousClock.Instant) async -> Outcome {
        enum Admission { case acquired, full, queued(UInt64) }
        let admission: Admission = state.withLock { state in
            if state.active < limit {
                state.active += 1
                return .acquired
            }
            guard state.queue.count < maxQueued else { return .full }
            let id = state.nextID
            state.nextID += 1
            state.queue.append(id)
            return .queued(id)
        }
        let ticket: UInt64
        switch admission {
        case .acquired: return .acquired
        case .full: return .queueFull
        case .queued(let id): ticket = id
        }

        let timer = Task { [self] in
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            resolve(ticket, with: .timedOut)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let early: Outcome? = state.withLock { state in
                    if let outcome = state.early.removeValue(forKey: ticket) { return outcome }
                    state.waiters[ticket] = continuation
                    return nil
                }
                if let early { continuation.resume(returning: early) }
            }
        } onCancel: {
            resolve(ticket, with: .cancelled)
        }
    }

    /// Frees a slot, handing it to the longest-waiting request if any.
    func release() {
        let next: CheckedContinuation<Outcome, Never>? = state.withLock { state in
            guard !state.queue.isEmpty else {
                state.active = max(0, state.active - 1)
                return nil
            }
            // Hand the slot over; `active` stays the same.
            let id = state.queue.removeFirst()
            if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
            // Queued but not yet registered: grant it when it registers.
            state.early[id] = .acquired
            return nil
        }
        next?.resume(returning: .acquired)
    }

    /// Resolves a waiting ticket with a failure outcome, if still waiting.
    private func resolve(_ ticket: UInt64, with outcome: Outcome) {
        let waiter: CheckedContinuation<Outcome, Never>? = state.withLock { state in
            guard let index = state.queue.firstIndex(of: ticket) else { return nil }  // Already granted.
            state.queue.remove(at: index)
            if let waiter = state.waiters.removeValue(forKey: ticket) { return waiter }
            state.early[ticket] = outcome
            return nil
        }
        waiter?.resume(returning: outcome)
    }
}
