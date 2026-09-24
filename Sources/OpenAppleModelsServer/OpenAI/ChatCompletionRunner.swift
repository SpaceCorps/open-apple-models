import Foundation
import FoundationModels
import OpenAppleModels
import Synchronization

/// Why a completion ended (OpenAI `finish_reason`).
enum FinishReason: String, Sendable {
    case stop
    case length
    case toolCalls = "tool_calls"
}

/// Token counts reported in `usage`.
struct CompletionUsage: Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int

    var totalTokens: Int { promptTokens + completionTokens }
}

/// What a running completion produces, in order: content (or a refusal, or
/// tool calls), then exactly one `finished`.
enum CompletionEvent: Sendable {
    case content(String)
    case refusal(String)
    case toolCalls([ToolCall])
    case finished(FinishReason, CompletionUsage)
}

/// Runs a ``CompletionPlan`` on a fresh ``Agent`` and translates agent
/// events into chat-completion events.
///
/// Client tools are external agent tools: when the model calls one, the
/// runner waits a short debounce window for parallel calls, then cancels the
/// turn and reports the calls — the client executes them and sends the
/// results in its next request. Server tools run in-process and never
/// surface.
enum ChatCompletionRunner {
    struct Settings: Sendable {
        var deadline: ContinuousClock.Instant
        var timeout: Duration
        var debounce: Duration
        var log: ServerLogger
    }

    static func events(for plan: CompletionPlan, settings: Settings) -> AsyncThrowingStream<CompletionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<CompletionEvent, any Error>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            await Execution(plan: plan, settings: settings, continuation: continuation).run()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// State for one execution. Several tasks (the event loop, the tool-call
    /// debounce timer, the deadline timer) may try to end the completion;
    /// the first one wins.
    private final class Execution: Sendable {
        let plan: CompletionPlan
        let settings: Settings
        let continuation: AsyncThrowingStream<CompletionEvent, any Error>.Continuation

        private struct State {
            var finished = false
            var calls: [ToolCall] = []
            var debounce: Task<Void, Never>?
            var run: AgentRun?
            var agent: Agent?
        }

        private let state = Mutex(State())

        init(plan: CompletionPlan, settings: Settings, continuation: AsyncThrowingStream<CompletionEvent, any Error>.Continuation) {
            self.plan = plan
            self.settings = settings
            self.continuation = continuation
        }

        func run() async {
            let agent: Agent
            do {
                agent = try Agent(
                    model: plan.model,
                    instructions: plan.instructions,
                    tools: plan.tools,
                    configuration: plan.configuration,
                    history: plan.conversation.history.isEmpty ? nil : Transcript(entries: plan.conversation.history))
            } catch {
                end(throwing: OpenAIError(error))
                return
            }
            let run: AgentRun
            switch plan.format {
            case .schema(let schema):
                run = agent.run(plan.conversation.prompt, schema: schema, policy: plan.policy)
            case .text, .jsonObject:
                run = agent.run(plan.conversation.prompt, policy: plan.policy)
            }
            state.withLock { state in
                state.run = run
                state.agent = agent
            }

            let timeout = settings.timeout
            let watchdog = Task { [self] in
                try? await Task.sleep(until: settings.deadline)
                guard !Task.isCancelled else { return }
                end(throwing: .timeout(after: timeout))
            }
            defer {
                watchdog.cancel()
                run.cancel()
            }

            await withTaskCancellationHandler {
                await consume(run)
            } onCancel: {
                run.cancel()
            }
        }

        private func consume(_ run: AgentRun) async {
            var filter = StopSequenceFilter(stops: plan.stop)
            var streamedAny = false
            do {
                for try await event in run {
                    if isFinished { return }
                    switch event {
                    case .text(_, let text, _):
                        guard case .text = plan.format else { continue }
                        var released = filter.update(fullText: text)
                        if released == nil {
                            // The model restarted its answer (a retried attempt).
                            guard !streamedAny || !plan.stream else {
                                end(throwing: .server("The model restarted its answer after a transient failure; retry the request.",
                                                      code: "generation_restarted"))
                                return
                            }
                            filter = StopSequenceFilter(stops: plan.stop)
                            released = filter.update(fullText: text)
                        }
                        if plan.stream, let released, !released.isEmpty {
                            streamedAny = true
                            continuation.yield(.content(released))
                        }
                        if filter.stopped {
                            if !plan.stream { continuation.yield(.content(filter.released)) }
                            end(.stop, usage: estimatedUsage(completionText: filter.released))
                            return
                        }
                    case .toolCallRequested(let call):
                        if plan.clientToolNames.contains(call.name) {
                            collect(call)
                        } else {
                            run.submit(.error("Tool '\(call.name)' is not available."), for: call.id)
                        }
                    case .toolCallStarted(let call):
                        settings.log.log(.debug, "server tool \(call.name) \(call.arguments.serialized())")
                    case .completed(let response):
                        complete(with: response, filter: &filter)
                        return
                    case .modelStep, .partial, .toolCallCompleted:
                        break
                    }
                }
                if !isFinished {
                    end(throwing: .server("The model ended without a response."))
                }
            } catch {
                guard !isFinished else { return }
                let agentError = AgentError(error)
                if agentError.code == .refusal {
                    continuation.yield(.refusal(agentError.message))
                    end(.stop, usage: estimatedUsage(completionText: agentError.message))
                } else if agentError.code == .cancelled, Task.isCancelled {
                    end(throwing: .server("The request was cancelled.", code: "cancelled"))
                } else {
                    end(throwing: OpenAIError(agentError))
                }
            }
        }

        private func complete(with response: AgentResponse, filter: inout StopSequenceFilter) {
            let usage = CompletionUsage(
                promptTokens: response.usage.inputTokens,
                completionTokens: response.usage.outputTokens,
                cachedTokens: response.usage.cachedInputTokens)
            var reason = FinishReason.stop
            if let maxTokens = plan.maxTokens, response.usage.outputTokens >= maxTokens { reason = .length }
            switch plan.format {
            case .text:
                if plan.stream {
                    if let rest = filter.finish(fullText: response.text), !rest.isEmpty { continuation.yield(.content(rest)) }
                } else {
                    var final = StopSequenceFilter(stops: plan.stop)
                    _ = final.finish(fullText: response.text)
                    continuation.yield(.content(final.released))
                }
            case .schema:
                continuation.yield(.content(response.text))
            case .jsonObject:
                guard let json = ChatCompletionRunner.extractJSONObject(response.text) else {
                    end(throwing: .server("The model did not produce a valid JSON object. Consider response_format json_schema, "
                                          + "which constrains generation. Output was: \(response.text.prefix(200))",
                                          code: "invalid_json_output"))
                    return
                }
                continuation.yield(.content(json))
            }
            end(reason, usage: usage.completionTokens == 0 && usage.promptTokens == 0
                ? estimatedUsage(completionText: response.text) : usage)
        }

        // MARK: Tool calls

        private func collect(_ call: ToolCall) {
            let debounce = settings.debounce
            state.withLock { state in
                guard !state.finished else { return }
                state.calls.append(call)
                state.debounce?.cancel()
                state.debounce = Task { [self] in
                    try? await Task.sleep(for: debounce)
                    guard !Task.isCancelled else { return }
                    finishWithToolCalls()
                }
            }
        }

        private func finishWithToolCalls() {
            let pending: (calls: [ToolCall], agent: Agent?)? = state.withLock { state in
                guard !state.finished, !state.calls.isEmpty else { return nil }
                return (state.calls, state.agent)
            }
            guard let pending else { return }
            // Parallel calls run concurrently, so they arrive in any order;
            // report them in the order the model generated them.
            let calls = pending.agent.map { ChatCompletionRunner.order(pending.calls, as: $0.transcript) } ?? pending.calls
            let returned = plan.parallelToolCalls ? calls : [calls[0]]
            let usage = estimatedUsage(completionText: returned.map { $0.name + $0.arguments.serialized() }.joined())
            end(.toolCalls, usage: usage, before: .toolCalls(returned))
        }

        // MARK: Ending

        private var isFinished: Bool { state.withLock { $0.finished } }

        /// Marks the completion finished; returns false if it already was.
        private func markFinished() -> Bool {
            let (first, run, debounce) = state.withLock { state in
                defer { state.finished = true }
                return (!state.finished, state.run, state.debounce)
            }
            guard first else { return false }
            debounce?.cancel()
            // Tool calls the client will execute must not also get an error
            // output; cancelling the turn discards them.
            run?.cancel()
            return true
        }

        private func end(_ reason: FinishReason, usage: CompletionUsage, before event: CompletionEvent? = nil) {
            guard markFinished() else { return }
            if let event { continuation.yield(event) }
            continuation.yield(.finished(reason, usage))
            continuation.finish()
        }

        private func end(throwing error: OpenAIError) {
            guard markFinished() else { return }
            continuation.finish(throwing: error)
        }

        /// Usage estimate (about four characters per token) for completions
        /// that end without a model response (tool calls, stop sequences).
        private func estimatedUsage(completionText: String) -> CompletionUsage {
            let promptCharacters = (plan.instructions?.count ?? 0)
                + Agent.render(plan.conversation.history).count
                + plan.conversation.promptText.count
            return CompletionUsage(
                promptTokens: (promptCharacters + 3) / 4,
                completionTokens: (completionText.count + 3) / 4,
                cachedTokens: 0)
        }
    }

    /// Sorts tool calls into the order of the transcript's latest tool-call
    /// entry, matching by name and arguments. Unmatched calls keep their
    /// relative order at the end.
    static func order(_ calls: [ToolCall], as transcript: Transcript) -> [ToolCall] {
        guard calls.count > 1 else { return calls }
        let generated: [Transcript.ToolCall]? = transcript.reversed().lazy.compactMap { entry -> [Transcript.ToolCall]? in
            if case .toolCalls(let calls) = entry { Array(calls) } else { nil }
        }.first
        guard let generated else { return calls }
        var unmatched = Array(generated.enumerated())
        let ranked = calls.enumerated().map { position, call -> (rank: Int, position: Int, call: ToolCall) in
            if let index = unmatched.firstIndex(where: { $0.element.toolName == call.name && JSONValue($0.element.arguments) == call.arguments }) {
                return (unmatched.remove(at: index).offset, position, call)
            }
            return (Int.max, position, call)
        }
        return ranked.sorted { ($0.rank, $0.position) < ($1.rank, $1.position) }.map(\.call)
    }

    /// Extracts a JSON object from model text, tolerating code fences and
    /// surrounding prose.
    static func extractJSONObject(_ text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate = String(candidate.drop { $0 != "\n" }.dropFirst())
            if let fence = candidate.range(of: "```", options: .backwards) { candidate = String(candidate[..<fence.lowerBound]) }
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if case .object? = try? JSONValue(parsing: candidate) { return candidate }
        guard let open = candidate.firstIndex(of: "{"), let close = candidate.lastIndex(of: "}"), open < close else { return nil }
        let inner = String(candidate[open...close])
        if case .object? = try? JSONValue(parsing: inner) { return inner }
        return nil
    }
}
