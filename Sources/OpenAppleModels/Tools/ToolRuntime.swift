import Foundation
import FoundationModels
import Synchronization

/// State for one agent turn: the event sink, tool budget, pending external
/// calls and completed tool records.
final class TurnContext: Sendable {
    let policy: ToolPolicy
    let defaultToolTimeout: Duration?
    private let continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation

    private struct State {
        var callCount = 0
        var pending: [String: (call: ToolCall, resume: CheckedContinuation<ToolOutput, Never>)] = [:]
        var records: [ToolRecord] = []
        var steps: [ModelStep] = []
        var started = false
        var finished = false
        var cancelled = false
    }

    private let state = Mutex(State())

    init(policy: ToolPolicy, defaultToolTimeout: Duration?, continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation) {
        self.policy = policy
        self.defaultToolTimeout = defaultToolTimeout
        self.continuation = continuation
    }

    func emit(_ event: AgentEvent) {
        if case .modelStep(let step) = event { state.withLock { $0.steps.append(step) } }
        continuation.yield(event)
    }

    func finish(with result: Result<AgentResponse, AgentError>) {
        let alreadyFinished = state.withLock { state in
            defer { state.finished = true }
            return state.finished
        }
        guard !alreadyFinished else { return }
        cancelPending(reason: "The turn ended before the tool output arrived.")
        switch result {
        case .success(let response):
            continuation.yield(.completed(response))
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        }
    }

    /// Marks the turn as running. Returns false if it already ended (e.g. it
    /// was cancelled while queued).
    func markStarted() -> Bool {
        state.withLock { state in
            guard !state.finished else { return false }
            state.started = true
            return true
        }
    }

    /// Ends a turn that has not started yet. Returns false if it is running
    /// (it will finish itself, after rolling back) or already ended.
    func finishIfNotStarted(with error: AgentError) -> Bool {
        let shouldFinish = state.withLock { !$0.started && !$0.finished }
        if shouldFinish { finish(with: .failure(error)) }
        return shouldFinish
    }

    /// Increments the call counter; returns false when over budget.
    func admitCall() -> Bool {
        state.withLock { state in
            state.callCount += 1
            return state.callCount <= policy.maxToolCalls
        }
    }

    func record(_ record: ToolRecord) {
        state.withLock { $0.records.append(record) }
        emit(.toolCallCompleted(record))
    }

    var records: [ToolRecord] { state.withLock { $0.records } }
    /// Tool invocations admitted so far (started, whether or not finished).
    var invokedToolCount: Int { state.withLock { $0.callCount } }
    var steps: [ModelStep] { state.withLock { $0.steps } }
    var pendingCalls: [ToolCall] { state.withLock { $0.pending.values.map(\.call).sorted { $0.id < $1.id } } }

    /// Registers an external call, then announces it via `announce`, then
    /// waits for the host to submit its output. Registering first means a host
    /// that replies immediately from the announcement can never miss the call.
    func awaitExternalOutput(for call: ToolCall, announce: @Sendable () -> Void) async -> ToolOutput {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<ToolOutput, Never>) in
                let alreadyCancelled = Task.isCancelled
                let immediate: ToolOutput? = state.withLock { state in
                    if state.finished { return .error("The turn has ended.") }
                    // The cancellation handler may have run before this
                    // registration; never park a call nobody can answer.
                    if state.cancelled || alreadyCancelled { return .error("The tool call was cancelled.") }
                    state.pending[call.id] = (call, resume)
                    return nil
                }
                if let immediate {
                    resume.resume(returning: immediate)
                } else {
                    announce()
                }
            }
        } onCancel: {
            _ = self.submit(.error("The tool call was cancelled."), for: call.id)
        }
    }

    /// Delivers output for a pending external call. Returns false if no call
    /// with that id is pending (it may have already completed).
    @discardableResult
    func submit(_ output: ToolOutput, for callID: String) -> Bool {
        let resume = state.withLock { state in state.pending.removeValue(forKey: callID)?.resume }
        guard let resume else { return false }
        resume.resume(returning: output)
        return true
    }

    func cancelPending(reason: String) {
        let pending = state.withLock { state in
            state.cancelled = true
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for entry in pending { entry.resume.resume(returning: .error(reason)) }
    }
}

/// Routes tool invocations from FoundationModels to the active turn.
final class ToolRuntime: Sendable {
    private let current = Mutex<TurnContext?>(nil)
    private let active = Mutex(0)

    /// Tool invocations still running inside the framework.
    var runningInvocations: Int { active.withLock { $0 } }

    func begin(_ turn: TurnContext) { current.withLock { $0 = turn } }
    func end() { current.withLock { $0 = nil } }

    func invoke(_ tool: AgentTool, arguments: GeneratedContent) async throws -> String {
        active.withLock { $0 += 1 }
        defer { active.withLock { $0 -= 1 } }
        if tool.name == AgentTool.respondDirectlyName { return "Reply now." }
        guard let turn = current.withLock({ $0 }) else {
            return ToolOutput.error("Tool '\(tool.name)' is not available right now.").modelText
        }
        let call = ToolCall(name: tool.name, arguments: JSONValue(arguments))
        let start = ContinuousClock.now

        guard turn.admitCall() else {
            let output = ToolOutput.error("The tool budget for this turn is used up. Answer with the information you already have.")
            turn.record(ToolRecord(call: call, output: output, duration: 0))
            return output.modelText
        }

        let output: ToolOutput
        switch tool.execution {
        case .local(let handler):
            turn.emit(.toolCallStarted(call))
            output = await Self.run(handler, call: call, timeout: tool.timeout ?? turn.defaultToolTimeout)
        case .external:
            let announce: @Sendable () -> Void = { turn.emit(.toolCallRequested(call)) }
            if let timeout = tool.timeout {
                output = await Self.withTimeout(timeout, call: call) { await turn.awaitExternalOutput(for: call, announce: announce) }
            } else {
                output = await turn.awaitExternalOutput(for: call, announce: announce)
            }
        }
        try Task.checkCancellation()
        let elapsed = ContinuousClock.now - start
        turn.record(ToolRecord(call: call, output: output, duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
        return output.modelText
    }

    private static func run(_ handler: @escaping AgentTool.Handler, call: ToolCall, timeout: Duration?) async -> ToolOutput {
        let body: @Sendable () async -> ToolOutput = {
            do {
                return try await handler(call)
            } catch is CancellationError {
                return .error("The tool call was cancelled.")
            } catch {
                return .error(Self.describe(error))
            }
        }
        // Always race the handler against cancellation (and the timeout): a
        // handler that ignores cancellation must not keep the framework's
        // turn alive, or its late completion can roll back newer history.
        return await withTimeout(timeout, call: call, body)
    }

    /// Races `body` against a timer. Unlike a task group, this returns as soon
    /// as either finishes, even if `body` ignores cancellation (it is
    /// cancelled and left to finish on its own).
    private static func withTimeout(_ timeout: Duration?, call: ToolCall, _ body: @escaping @Sendable () async -> ToolOutput) async -> ToolOutput {
        let race = FirstResult<ToolOutput>()
        return await withTaskCancellationHandler {
            await race.wait { race in
                let work = Task { race.deliver(await body()) }
                let timer = timeout.map { timeout in
                    Task {
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        race.deliver(.error("Tool '\(call.name)' timed out after \(timeout.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))."))
                    }
                }
                race.onDelivery {
                    work.cancel()
                    timer?.cancel()
                }
            }
        } onCancel: {
            race.deliver(.error("The tool call was cancelled."))
        }
    }

    static func describe(_ error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return String(describing: error)
    }
}

/// Adapts an ``AgentTool`` to the FoundationModels `Tool` protocol.
struct ToolAdapter: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let tool: AgentTool
    let runtime: ToolRuntime

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: GenerationSchema { tool.generationSchema }

    func call(arguments: GeneratedContent) async throws -> String {
        try await runtime.invoke(tool, arguments: arguments)
    }
}

/// A one-shot rendezvous: the first delivered value wins and resumes the waiter.
final class FirstResult<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Never>?
        var value: Value?
        var cleanup: [@Sendable () -> Void] = []
        var done = false
    }

    private let state = Mutex(State())

    /// Suspends until a value is delivered. `start` runs once the waiter is
    /// installed (deliveries before that are kept and returned immediately).
    func wait(_ start: (FirstResult<Value>) -> Void) async -> Value {
        await withCheckedContinuation { continuation in
            let early: Value? = state.withLock { state in
                if let value = state.value { return value }
                state.continuation = continuation
                return nil
            }
            if let early {
                continuation.resume(returning: early)
                return
            }
            start(self)
        }
    }

    func onDelivery(_ cleanup: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { state in
            if state.done { return true }
            state.cleanup.append(cleanup)
            return false
        }
        if runNow { cleanup() }
    }

    func deliver(_ value: Value) {
        let (continuation, cleanup) = state.withLock { state -> (CheckedContinuation<Value, Never>?, [@Sendable () -> Void]) in
            guard !state.done else { return (nil, []) }
            state.done = true
            if state.continuation == nil { state.value = value }
            defer { state.continuation = nil; state.cleanup = [] }
            return (state.continuation, state.cleanup)
        }
        continuation?.resume(returning: value)
        cleanup.forEach { $0() }
    }
}
