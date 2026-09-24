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
        var finished = false
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
                let immediate: ToolOutput? = state.withLock { state in
                    if state.finished { return .error("The turn has ended.") }
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
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for entry in pending { entry.resume.resume(returning: .error(reason)) }
    }
}

/// Routes tool invocations from FoundationModels to the active turn.
final class ToolRuntime: Sendable {
    private let current = Mutex<TurnContext?>(nil)

    func begin(_ turn: TurnContext) { current.withLock { $0 = turn } }
    func end() { current.withLock { $0 = nil } }

    func invoke(_ tool: AgentTool, arguments: GeneratedContent) async throws -> String {
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
        guard let timeout else { return await body() }
        return await withTimeout(timeout, call: call, body)
    }

    private static func withTimeout(_ timeout: Duration, call: ToolCall, _ body: @escaping @Sendable () async -> ToolOutput) async -> ToolOutput {
        await withTaskGroup(of: ToolOutput?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return Task.isCancelled ? nil : .error("Tool '\(call.name)' timed out after \(timeout.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))).")
            }
            var result: ToolOutput = .error("Tool '\(call.name)' produced no output.")
            for await value in group {
                if let value {
                    result = value
                    break
                }
            }
            group.cancelAll()
            return result
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
