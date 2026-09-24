import Foundation
import OpenAppleModels

/// Built-in memory tools an ``NPC`` can offer the model.
public struct NPCMemoryTools: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `remember_fact(fact)`: the model stores a fact in ``NPCMemory/facts``.
    public static let rememberFact = NPCMemoryTools(rawValue: 1 << 0)
    /// `change_relationship(delta, reason)`: the model adjusts ``NPCMemory/relationship``.
    public static let changeRelationship = NPCMemoryTools(rawValue: 1 << 1)
    public static let all: NPCMemoryTools = [.rememberFact, .changeRelationship]
}

/// How an ``NPC`` asks the model for its reply.
public enum NPCReplyFormat: String, Sendable, Hashable, Codable, CaseIterable {
    /// Schema-guided output: emotion, line, suggested player replies and
    /// whether the conversation ends. The default.
    case structured
    /// Plain text that starts with an emotion tag (`[angry] Get out!`). No
    /// suggested replies, and ``DialogueTurn/endsConversation`` is always
    /// false, but it streams straight from the model and works with a
    /// `SystemLanguageModel` configured with
    /// `guardrails: .permissiveContentTransformations`, which applies only to
    /// plain-text generation (see docs/GAMES.md before using it).
    case text
}

/// Behavior settings for an ``NPC``. `Codable` with defaults, so a game can
/// load them from JSON with only the fields it wants to change.
public struct NPCOptions: Sendable, Hashable, Codable {
    // MARK: Grounding and tools

    /// Tool policy for the first model step of each turn when
    /// ``groundingTool`` is not set. `.auto` is fastest, but the small model
    /// often skips tools and invents facts; `.required` makes it call a tool
    /// first on every turn.
    public var toolChoice: ToolChoice
    /// A tool the NPC must call first on every turn (e.g. `check_inventory`
    /// for a shopkeeper, `read_world_state` for a quest giver). Overrides
    /// ``toolChoice``. Adds one tool round (~2–5 s on device) per turn.
    public var groundingTool: String?
    /// Maximum model steps that may call tools in one turn.
    public var maxToolRounds: Int
    /// Maximum tool calls in one turn.
    public var maxToolCalls: Int
    /// World paths the NPC may read through `read_world_state` (when the NPC
    /// has a world). `[]` omits the tool.
    public var worldReadable: [String]
    /// World paths the NPC may change through `update_world_state`. Empty
    /// (the default) omits the tool.
    public var worldWritable: [String]
    /// World paths summarized into every prompt. This grounds the NPC in
    /// small, always-relevant facts (time of day, player name, quest stage)
    /// without a tool round-trip.
    public var worldContextPaths: [String]
    /// Built-in memory tools to offer (none by default: each tool costs
    /// prompt tokens and the model may spend a tool round on it).
    public var memoryTools: NPCMemoryTools
    /// Most facts kept in memory; older facts are dropped first.
    public var maxFacts: Int
    /// Largest relationship change one `change_relationship` call may make.
    public var maxRelationshipChange: Int
    /// ``Persona/secrets`` are left out of the instructions until
    /// ``NPCMemory/relationship`` reaches this value, then offered as
    /// shareable (default 50). `nil` always includes them with a rule to
    /// keep them — but the ~3B on-device model leaks guarded secrets
    /// readily (observed in live tests), so prefer a threshold.
    public var secretsUnlockAtRelationship: Int?

    // MARK: Reply shape

    /// Structured (default) or plain-text replies.
    public var replyFormat: NPCReplyFormat
    /// Emotions the model may choose from (all by default; structured replies only).
    public var emotions: [Emotion]
    /// Number of suggested player replies per turn (0–4; structured replies
    /// only). 0 removes the field from the schema, which makes turns a
    /// little faster.
    public var playerOptionCount: Int
    /// Whether the model may end the conversation (``DialogueTurn/endsConversation``).
    public var canEndConversation: Bool
    /// Extra lines appended to the persona's instructions.
    public var extraInstructions: String?

    // MARK: Context management

    /// Once the history holds this many turns, older turns are summarized
    /// into ``NPCMemory/summary`` in the background. 0 disables compaction
    /// (the history is then only trimmed to fit the context window).
    public var compactAfterTurns: Int
    /// Turns kept verbatim when compacting.
    public var keepRecentTurns: Int

    // MARK: Failures

    /// When the model's guardrails block a turn (or it refuses), return an
    /// in-character fallback line (``DialogueTurn/isFallback``) instead of
    /// throwing. The failed exchange is not added to the history.
    public var fallbackOnGuardrail: Bool
    /// Fallback lines, used in rotation. Empty uses neutral defaults.
    public var fallbackLines: [String]

    // MARK: Sampling

    /// Sampling temperature (`nil` = model default).
    public var temperature: Double?
    /// Response token limit per model step (`nil` = none). Too low a limit
    /// can cut structured replies short and fail the turn.
    public var maximumResponseTokens: Int?
    /// Response token limit for ``NPC/bark(situation:)``.
    public var barkMaximumTokens: Int

    public init(
        toolChoice: ToolChoice = .auto,
        groundingTool: String? = nil,
        maxToolRounds: Int = 2,
        maxToolCalls: Int = 6,
        worldReadable: [String] = [""],
        worldWritable: [String] = [],
        worldContextPaths: [String] = [],
        memoryTools: NPCMemoryTools = [],
        maxFacts: Int = 12,
        maxRelationshipChange: Int = 10,
        secretsUnlockAtRelationship: Int? = 50,
        replyFormat: NPCReplyFormat = .structured,
        emotions: [Emotion] = Emotion.allCases,
        playerOptionCount: Int = 3,
        canEndConversation: Bool = true,
        extraInstructions: String? = nil,
        compactAfterTurns: Int = 8,
        keepRecentTurns: Int = 2,
        fallbackOnGuardrail: Bool = true,
        fallbackLines: [String] = [],
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        barkMaximumTokens: Int = 48
    ) {
        self.toolChoice = toolChoice
        self.groundingTool = groundingTool
        self.maxToolRounds = maxToolRounds
        self.maxToolCalls = maxToolCalls
        self.worldReadable = worldReadable
        self.worldWritable = worldWritable
        self.worldContextPaths = worldContextPaths
        self.memoryTools = memoryTools
        self.maxFacts = maxFacts
        self.maxRelationshipChange = maxRelationshipChange
        self.secretsUnlockAtRelationship = secretsUnlockAtRelationship
        self.replyFormat = replyFormat
        self.emotions = emotions
        self.playerOptionCount = playerOptionCount
        self.canEndConversation = canEndConversation
        self.extraInstructions = extraInstructions
        self.compactAfterTurns = compactAfterTurns
        self.keepRecentTurns = keepRecentTurns
        self.fallbackOnGuardrail = fallbackOnGuardrail
        self.fallbackLines = fallbackLines
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.barkMaximumTokens = barkMaximumTokens
    }

    /// Neutral lines used when ``fallbackLines`` is empty.
    public static let defaultFallbackLines = [
        "Let's talk about something else.",
        "I'd rather not speak of that.",
        "Hmm. Ask me something else.",
    ]

    private enum CodingKeys: String, CodingKey {
        case toolChoice, groundingTool, maxToolRounds, maxToolCalls, worldReadable, worldWritable, worldContextPaths
        case memoryTools, maxFacts, maxRelationshipChange, secretsUnlockAtRelationship
        case replyFormat, emotions, playerOptionCount, canEndConversation, extraInstructions
        case compactAfterTurns, keepRecentTurns, fallbackOnGuardrail, fallbackLines
        case temperature, maximumResponseTokens, barkMaximumTokens
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NPCOptions()
        self.init(
            toolChoice: try c.decode(.toolChoice, default: defaults.toolChoice),
            groundingTool: try c.decodeIfPresent(String.self, forKey: .groundingTool),
            maxToolRounds: try c.decode(.maxToolRounds, default: defaults.maxToolRounds),
            maxToolCalls: try c.decode(.maxToolCalls, default: defaults.maxToolCalls),
            worldReadable: try c.decode(.worldReadable, default: defaults.worldReadable),
            worldWritable: try c.decode(.worldWritable, default: defaults.worldWritable),
            worldContextPaths: try c.decode(.worldContextPaths, default: defaults.worldContextPaths),
            memoryTools: try c.decode(.memoryTools, default: defaults.memoryTools),
            maxFacts: try c.decode(.maxFacts, default: defaults.maxFacts),
            maxRelationshipChange: try c.decode(.maxRelationshipChange, default: defaults.maxRelationshipChange),
            secretsUnlockAtRelationship: c.contains(.secretsUnlockAtRelationship)
                ? try c.decodeIfPresent(Int.self, forKey: .secretsUnlockAtRelationship)
                : defaults.secretsUnlockAtRelationship,
            replyFormat: try c.decode(.replyFormat, default: defaults.replyFormat),
            emotions: try c.decode(.emotions, default: defaults.emotions),
            playerOptionCount: try c.decode(.playerOptionCount, default: defaults.playerOptionCount),
            canEndConversation: try c.decode(.canEndConversation, default: defaults.canEndConversation),
            extraInstructions: try c.decodeIfPresent(String.self, forKey: .extraInstructions),
            compactAfterTurns: try c.decode(.compactAfterTurns, default: defaults.compactAfterTurns),
            keepRecentTurns: try c.decode(.keepRecentTurns, default: defaults.keepRecentTurns),
            fallbackOnGuardrail: try c.decode(.fallbackOnGuardrail, default: defaults.fallbackOnGuardrail),
            fallbackLines: try c.decode(.fallbackLines, default: defaults.fallbackLines),
            temperature: try c.decodeIfPresent(Double.self, forKey: .temperature),
            maximumResponseTokens: try c.decodeIfPresent(Int.self, forKey: .maximumResponseTokens),
            barkMaximumTokens: try c.decode(.barkMaximumTokens, default: defaults.barkMaximumTokens))
    }
}
