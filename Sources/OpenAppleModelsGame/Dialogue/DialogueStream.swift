import Foundation
import OpenAppleModels
import Synchronization

/// A streaming NPC turn: an async sequence of ``DialogueEvent``s plus a
/// channel for supplying external tool outputs.
///
/// ```swift
/// let stream = npc.talkStream("What's that glowing sword?")
/// for try await event in stream {
///     switch event {
///     case .emotion(let emotion): portrait.show(emotion)
///     case .lineDelta(let text): label.text += text
///     case .lineReset(let text): label.text = text
///     case .externalToolCall(let call): stream.submit(game.run(call), for: call.id)
///     case .completed(let turn): showOptions(turn.playerOptions)
///     default: break
///     }
/// }
/// ```
///
/// The sequence can be iterated once. The turn runs even if nobody iterates;
/// call ``cancel()`` to stop it.
public final class DialogueStream: AsyncSequence, Sendable {
    public typealias Element = DialogueEvent
    public typealias AsyncIterator = AsyncThrowingStream<DialogueEvent, any Error>.AsyncIterator

    private let events: AsyncThrowingStream<DialogueEvent, any Error>
    private let continuation: AsyncThrowingStream<DialogueEvent, any Error>.Continuation

    private struct State {
        var run: AgentRun?
        var cancelled = false
    }

    private let state = Mutex(State())

    init() {
        (events, continuation) = AsyncThrowingStream<DialogueEvent, any Error>.makeStream(bufferingPolicy: .unbounded)
    }

    public func makeAsyncIterator() -> AsyncIterator { events.makeAsyncIterator() }

    /// Supplies the output of an external tool call announced by
    /// ``DialogueEvent/externalToolCall(_:)``. Returns false if no such call is pending.
    @discardableResult
    public func submit(_ output: ToolOutput, for callID: String) -> Bool {
        // The agent registers an external call before announcing it, so an
        // answer sent from the announcement can never arrive too early.
        guard let run = state.withLock({ $0.run }) else { return false }
        return run.submit(output, for: callID)
    }

    /// External tool calls waiting for output.
    public var pendingToolCalls: [ToolCall] {
        state.withLock { $0.run }?.pendingToolCalls ?? []
    }

    /// Cancels the turn (also if it has not started yet). The sequence then
    /// throws ``AgentError`` with code `.cancelled`; the history is unchanged.
    public func cancel() {
        let run = state.withLock { state in
            state.cancelled = true
            return state.run
        }
        run?.cancel()
    }

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Consumes the events and returns the finished turn.
    ///
    /// - Parameter externalTools: Runs each external tool call; its result is
    ///   submitted automatically. Without it, external calls receive an error output.
    public func turn(
        externalTools: (@Sendable (ToolCall) async throws -> ToolOutput)? = nil
    ) async throws(AgentError) -> DialogueTurn {
        do {
            for try await event in self {
                switch event {
                case .externalToolCall(let call):
                    if let externalTools {
                        Task {
                            let output: ToolOutput
                            do { output = try await externalTools(call) } catch { output = .error(ToolOutputText.describe(error)) }
                            self.submit(output, for: call.id)
                        }
                    } else {
                        submit(.error("No handler is registered for external tool '\(call.name)'."), for: call.id)
                    }
                case .completed(let turn):
                    return turn
                default:
                    break
                }
            }
        } catch {
            throw AgentError(error)
        }
        throw AgentError(.generationFailed, "The dialogue turn ended without a reply.")
    }

    // MARK: Producer side

    /// Associates the running agent turn. Returns false (and cancels `run`)
    /// if the stream was already cancelled.
    func attach(_ run: AgentRun) -> Bool {
        let cancelled = state.withLock { state in
            state.run = run
            return state.cancelled
        }
        if cancelled { run.cancel() }
        return !cancelled
    }

    func emit(_ event: DialogueEvent) {
        continuation.yield(event)
    }

    func finish(_ turn: DialogueTurn) {
        continuation.yield(.completed(turn))
        continuation.finish()
    }

    func fail(_ error: AgentError) {
        continuation.finish(throwing: error)
    }
}
