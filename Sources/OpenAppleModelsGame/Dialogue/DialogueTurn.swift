import Foundation
import FoundationModels
import OpenAppleModels

/// One reply from an ``NPC``.
public struct DialogueTurn: Sendable, Hashable, Codable {
    /// What the NPC says (cleaned: no speaker label or wrapping quotes).
    public var line: String
    /// How the NPC feels saying it.
    public var emotion: Emotion
    /// Short replies the player might choose next (may be empty).
    public var playerOptions: [String]
    /// Whether the NPC ended the conversation.
    public var endsConversation: Bool
    /// Tools executed during this turn, in completion order.
    public var toolCalls: [ToolRecord]
    /// The NPC's attitude toward the player after this turn (`-100...100`).
    public var relationship: Int
    /// True when the model was blocked (guardrail or refusal) and a fallback
    /// line from ``NPCOptions/fallbackLines`` was used instead.
    public var isFallback: Bool
    /// Tokens used by this turn.
    public var usage: TokenUsage

    public init(
        line: String,
        emotion: Emotion = .neutral,
        playerOptions: [String] = [],
        endsConversation: Bool = false,
        toolCalls: [ToolRecord] = [],
        relationship: Int = 0,
        isFallback: Bool = false,
        usage: TokenUsage = TokenUsage()
    ) {
        self.line = line
        self.emotion = emotion
        self.playerOptions = playerOptions
        self.endsConversation = endsConversation
        self.toolCalls = toolCalls
        self.relationship = relationship
        self.isFallback = isFallback
        self.usage = usage
    }
}

/// Events streamed by ``NPC/talkStream(_:context:toolChoice:)``.
///
/// For a typewriter effect, append ``lineDelta(_:)`` text and replace the
/// displayed text on ``lineReset(_:)``. By the time ``completed(_:)``
/// arrives, the deltas and resets add up to exactly ``DialogueTurn/line``.
public enum DialogueEvent: Sendable {
    /// The NPC's emotion for this turn, sent as soon as it is known (before
    /// most of the line) so a portrait or animation can react early. Sent at
    /// least once per turn; a later one replaces an earlier one.
    case emotion(Emotion)
    /// New text to append to the displayed line.
    case lineDelta(String)
    /// Replace the displayed line with this text (rare: the model rewrote
    /// its output, or a fallback line replaced a blocked one).
    case lineReset(String)
    /// A local tool started running.
    case toolCall(ToolCall)
    /// An external tool needs the game to run it. Reply with
    /// ``DialogueStream/submit(_:for:)``; the turn waits until you do.
    case externalToolCall(ToolCall)
    /// A tool (local or external) finished.
    case toolResult(ToolRecord)
    /// The turn finished. Always the last event of a successful turn.
    case completed(DialogueTurn)
}

/// Everything needed to restore an ``NPC``: who it is, what it remembers
/// and the conversation so far. Encode with `JSONEncoder` into a save file.
public struct NPCSaveState: Sendable, Codable {
    /// Format version, for migrations.
    public var version: Int
    public var persona: Persona
    public var memory: NPCMemory
    /// The conversation, trimmed to complete turns.
    public var transcript: Transcript

    public init(version: Int = 1, persona: Persona, memory: NPCMemory, transcript: Transcript) {
        self.version = version
        self.persona = persona
        self.memory = memory
        self.transcript = transcript
    }
}
