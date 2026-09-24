import Foundation
import Synchronization

/// A running agent turn: an async sequence of ``AgentEvent``s plus a channel
/// for supplying external tool outputs.
///
/// ```swift
/// let run = agent.run("Open the gate for me")
/// for try await event in run {
///     switch event {
///     case .text(let delta, _, _): print(delta, terminator: "")
///     case .toolCallRequested(let call): run.submit(await game.perform(call), for: call.id)
///     case .completed(let response): print("\n", response.toolCalls.count, "tool calls")
///     default: break
///     }
/// }
/// ```
///
/// The event sequence can be iterated once. Cancelling the iterating task
/// does not cancel the turn; call ``cancel()`` for that.
public final class AgentRun: AsyncSequence, Sendable {
    public typealias Element = AgentEvent
    public typealias AsyncIterator = AsyncThrowingStream<AgentEvent, any Error>.AsyncIterator

    private let events: AsyncThrowingStream<AgentEvent, any Error>
    let context: TurnContext
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(policy: ToolPolicy, defaultToolTimeout: Duration?) {
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, any Error>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        context = TurnContext(policy: policy, defaultToolTimeout: defaultToolTimeout, continuation: continuation)
    }

    func attach(_ task: Task<Void, Never>) {
        self.task.withLock { $0 = task }
    }

    public func makeAsyncIterator() -> AsyncIterator { events.makeAsyncIterator() }

    /// Supplies the output of an external tool call announced by
    /// ``AgentEvent/toolCallRequested(_:)``. Returns false if no such call is pending.
    @discardableResult
    public func submit(_ output: ToolOutput, for callID: String) -> Bool {
        context.submit(output, for: callID)
    }

    /// External tool calls waiting for output.
    public var pendingToolCalls: [ToolCall] { context.pendingCalls }

    /// Cancels the turn. Pending external calls resolve with an error.
    public func cancel() {
        context.cancelPending(reason: "The turn was cancelled.")
        task.withLock { $0?.cancel() }
        // A turn still queued behind another ends now; a running turn ends
        // once it has rolled back its partial work.
        _ = context.finishIfNotStarted(with: AgentError(.cancelled, "The turn was cancelled."))
    }

    /// Consumes the events and returns the final response.
    ///
    /// - Parameter externalTools: Called for each external tool request; its
    ///   result is submitted automatically. Without it, external calls receive
    ///   an error output.
    public func response(
        externalTools: (@Sendable (ToolCall) async throws -> ToolOutput)? = nil
    ) async throws(AgentError) -> AgentResponse {
        // Cancelling the awaiting task cancels the turn.
        let result: Result<AgentResponse, AgentError> = await withTaskCancellationHandler {
            do {
                return .success(try await consume(externalTools: externalTools))
            } catch {
                return .failure(AgentError(error))
            }
        } onCancel: {
            self.cancel()
        }
        return try result.get()
    }

    private func consume(
        externalTools: (@Sendable (ToolCall) async throws -> ToolOutput)?
    ) async throws -> AgentResponse {
        do {
            for try await event in self {
                switch event {
                case .toolCallRequested(let call):
                    if let externalTools {
                        Task {
                            let output: ToolOutput
                            do { output = try await externalTools(call) } catch { output = .error(ToolRuntime.describe(error)) }
                            self.submit(output, for: call.id)
                        }
                    } else {
                        submit(.error("No handler is registered for external tool '\(call.name)'."), for: call.id)
                    }
                case .completed(let response):
                    return response
                default:
                    break
                }
            }
        } catch {
            throw AgentError(error)
        }
        if Task.isCancelled { throw AgentError(.cancelled, "The turn was cancelled.") }
        throw AgentError(.generationFailed, "The turn ended without a response.")
    }
}
