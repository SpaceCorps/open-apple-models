import Foundation

/// Who a character is: the data an ``NPC`` turns into compact instructions
/// for the on-device model.
///
/// Keep every field short. The on-device model has an 8K-token context
/// shared by instructions, tools, the conversation and the answer, and a
/// small model follows a few crisp lines better than a page of lore. Put
/// large or changing facts (stock, prices, quest state) in tools or a
/// ``WorldState`` instead.
///
/// `Codable` with defaults: a JSON persona only needs a `name`.
///
/// ```swift
/// let gorm = Persona(
///     name: "Gorm",
///     role: "the village blacksmith",
///     personality: "Gruff and proud, but fair. Secretly soft-hearted.",
///     speakingStyle: "Short, blunt sentences. Calls people 'lad' or 'lass'.",
///     goals: ["Sell his weapons at a fair price"],
///     secrets: ["He forged the blade that killed the old king."])
/// ```
public struct Persona: Sendable, Hashable, Codable {
    /// The character's name, e.g. `"Gorm"`.
    public var name: String
    /// A short noun phrase, e.g. `"the village blacksmith"`.
    public var role: String
    /// Temperament in a sentence or two.
    public var personality: String
    /// How the character talks: vocabulary, rhythm, catchphrases.
    public var speakingStyle: String
    /// A few sentences of history.
    public var backstory: String
    /// What the character wants.
    public var goals: [String]
    /// Guarded knowledge the character keeps from the player until it is
    /// earned. See ``SecretVisibility``.
    public var secrets: [String]
    /// Facts the character knows and may share freely.
    public var knowledge: [String]
    /// Emotion used when the model gives none, and for fallback lines.
    public var defaultEmotion: Emotion
    /// Upper bound on sentences per reply (at least 1).
    public var maxSentences: Int

    public init(
        name: String,
        role: String = "",
        personality: String = "",
        speakingStyle: String = "",
        backstory: String = "",
        goals: [String] = [],
        secrets: [String] = [],
        knowledge: [String] = [],
        defaultEmotion: Emotion = .neutral,
        maxSentences: Int = 2
    ) {
        self.name = name
        self.role = role
        self.personality = personality
        self.speakingStyle = speakingStyle
        self.backstory = backstory
        self.goals = goals
        self.secrets = secrets
        self.knowledge = knowledge
        self.defaultEmotion = defaultEmotion
        self.maxSentences = maxSentences
    }

    private enum CodingKeys: String, CodingKey {
        case name, role, personality, speakingStyle, backstory, goals, secrets, knowledge, defaultEmotion, maxSentences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            role: try container.decode(.role, default: ""),
            personality: try container.decode(.personality, default: ""),
            speakingStyle: try container.decode(.speakingStyle, default: ""),
            backstory: try container.decode(.backstory, default: ""),
            goals: try container.decode(.goals, default: []),
            secrets: try container.decode(.secrets, default: []),
            knowledge: try container.decode(.knowledge, default: []),
            defaultEmotion: try container.decode(.defaultEmotion, default: .neutral),
            maxSentences: try container.decode(.maxSentences, default: 2))
    }

    /// How a persona's ``secrets`` appear in its instructions.
    public enum SecretVisibility: String, Sendable, Hashable, Codable {
        /// Included, with a rule to keep them hidden unless the player earns them.
        case guarded
        /// Included, and the character may share them when asked.
        case shareable
        /// Left out entirely — the model cannot leak what it never sees.
        case hidden
    }

    /// Renders compact system instructions (typically 100–250 tokens) tuned
    /// for a ~3B on-device model: role-play framing, the character sheet,
    /// then a few short rules (stay in character, never mention being an AI,
    /// reply length, use tools instead of inventing facts, guard secrets).
    ///
    /// - Parameters:
    ///   - extra: Additional lines appended at the end (setting, quest hints, rules).
    ///   - usesTools: Whether the character has tools for looking up facts.
    ///     When false, the model is told to admit ignorance instead.
    ///   - secrets: How to include ``secrets``.
    public func instructions(extra: String? = nil, usesTools: Bool = true, secrets visibility: SecretVisibility = .guarded) -> String {
        var lines: [String] = []
        let who = role.trimmedOrNil.map { "\(name), \($0)" } ?? name
        lines.append("You play \(who), a character in a video game.")
        if let personality = personality.trimmedOrNil { lines.append("Personality: \(Self.sentence(personality))") }
        if let style = speakingStyle.trimmedOrNil { lines.append("Speaking style: \(Self.sentence(style))") }
        if let backstory = backstory.trimmedOrNil { lines.append("Background: \(Self.sentence(backstory))") }
        if let goals = Self.list(goals) { lines.append("Goals: \(goals)") }
        if let knowledge = Self.list(knowledge) { lines.append("You know: \(knowledge)") }
        let secretText = Self.list(secrets)
        if let secretText, visibility != .hidden { lines.append("Your secret: \(secretText)") }

        lines.append("Rules:")
        lines.append("- Speak only as \(name). Never say you are an AI, a model or an assistant.")
        let limit = max(1, maxSentences)
        lines.append("- Reply in at most \(limit) short \(limit == 1 ? "sentence" : "sentences").")
        if usesTools {
            lines.append("- Use your tools to check facts about the world, such as items, prices, people and places. Never invent them.")
        } else {
            lines.append("- If you do not know a fact about the world, say so in character. Never invent it.")
        }
        if secretText != nil {
            switch visibility {
            case .guarded: lines.append("- Keep your secret unless the player has truly earned your trust.")
            case .shareable: lines.append("- The player has earned your trust. You may share your secret if asked.")
            case .hidden: break
            }
        }
        if let extra = extra?.trimmedOrNil { lines.append(extra) }
        return lines.joined(separator: "\n")
    }

    /// Joins list items into one line: `"a; b; c."`.
    static func list(_ items: [String]) -> String? {
        let cleaned = items.compactMap(\.trimmedOrNil)
        guard !cleaned.isEmpty else { return nil }
        return sentence(cleaned.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: "; "))
    }

    /// Ensures text ends with terminal punctuation.
    static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?\"'".contains(last) ? text : text + "."
    }
}
