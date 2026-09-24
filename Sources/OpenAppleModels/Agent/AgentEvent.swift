import Foundation
import FoundationModels

/// A completed tool invocation.
public struct ToolRecord: Sendable, Hashable, Codable {
    public var call: ToolCall
    public var output: ToolOutput
    /// Wall-clock seconds spent in the tool (including waiting for an external host).
    public var duration: Double

    public init(call: ToolCall, output: ToolOutput, duration: Double) {
        self.call = call
        self.output = output
        self.duration = duration
    }
}

/// Token usage for a turn.
public struct TokenUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    init(_ usage: LanguageModelSession.Usage) {
        inputTokens = usage.input.totalTokenCount
        cachedInputTokens = usage.input.cachedTokenCount
        outputTokens = usage.output.totalTokenCount
    }
}

/// The result of one agent turn.
public struct AgentResponse: Sendable, Hashable {
    /// The final text. For structured turns, the JSON text of ``structured``.
    public var text: String
    /// The structured output, when the turn requested a schema.
    public var structured: JSONValue?
    /// Tools called during the turn, in completion order.
    public var toolCalls: [ToolRecord]
    public var usage: TokenUsage
    /// Model steps taken (one per model inference; tool rounds add steps).
    public var steps: [ModelStep]

    public init(text: String, structured: JSONValue? = nil, toolCalls: [ToolRecord] = [], usage: TokenUsage = TokenUsage(), steps: [ModelStep] = []) {
        self.text = text
        self.structured = structured
        self.toolCalls = toolCalls
        self.usage = usage
        self.steps = steps
    }
}

/// Events emitted while an agent turn runs.
public enum AgentEvent: Sendable {
    /// The model is about to run an inference step.
    case modelStep(ModelStep)
    /// New response text. `delta` is the new suffix; `text` is the full
    /// response so far. If the model rewrites earlier text, `delta` is the
    /// entire new text and `isReset` is true.
    case text(delta: String, text: String, isReset: Bool)
    /// Partially generated structured output (streams as properties fill in).
    case partial(JSONValue)
    /// A local tool started running.
    case toolCallStarted(ToolCall)
    /// An external tool needs the host to execute it. Reply with
    /// ``AgentRun/submit(_:for:)``; the turn waits until you do.
    case toolCallRequested(ToolCall)
    /// A tool finished (local or external).
    case toolCallCompleted(ToolRecord)
    /// The turn finished. Always the last event of a successful turn.
    case completed(AgentResponse)
}
