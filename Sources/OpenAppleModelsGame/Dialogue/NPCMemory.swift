import Foundation

/// What an ``NPC`` remembers across turns and saves: facts about the player
/// and world, its attitude toward the player, and a running summary of older
/// conversation.
///
/// Memory is injected into the NPC's instructions each turn, so keep it
/// short (see ``NPCOptions/maxFacts``).
public struct NPCMemory: Sendable, Hashable, Codable {
    /// Allowed values of ``relationship``.
    public static let relationshipRange: ClosedRange<Int> = -100...100

    /// Remembered facts, oldest first.
    public var facts: [String]
    private var storedRelationship: Int
    /// Summary of conversation that was compacted out of the history.
    public var summary: String?

    /// Attitude toward the player, clamped to `-100...100`
    /// (below -60 hostile, above 60 trusting).
    public var relationship: Int {
        get { storedRelationship }
        set { storedRelationship = Self.clamp(newValue) }
    }

    public init(facts: [String] = [], relationship: Int = 0, summary: String? = nil) {
        self.facts = facts
        self.storedRelationship = Self.clamp(relationship)
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey { case facts, relationship, summary }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            facts: try container.decode(.facts, default: []),
            relationship: try container.decode(.relationship, default: 0),
            summary: try container.decodeIfPresent(String.self, forKey: .summary))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(facts, forKey: .facts)
        try container.encode(relationship, forKey: .relationship)
        try container.encodeIfPresent(summary, forKey: .summary)
    }

    /// Adds a fact unless an equal one (ignoring case and punctuation) is
    /// already known. When `limit` is exceeded the oldest facts are dropped.
    /// - Returns: Whether the fact was new.
    @discardableResult
    public mutating func remember(_ fact: String, limit: Int? = nil) -> Bool {
        guard let fact = fact.trimmedOrNil else { return false }
        let key = Self.normalized(fact)
        guard !facts.contains(where: { Self.normalized($0) == key }) else { return false }
        facts.append(fact)
        if let limit, limit >= 0, facts.count > limit { facts.removeFirst(facts.count - limit) }
        return true
    }

    /// Adds `delta` to ``relationship`` (clamped) and returns the new value.
    @discardableResult
    public mutating func adjustRelationship(by delta: Int) -> Int {
        let (sum, overflow) = relationship.addingReportingOverflow(delta)
        relationship = overflow ? (delta > 0 ? Int.max : Int.min) : sum
        return relationship
    }

    /// A one-word description of ``relationship``: hostile, unfriendly,
    /// neutral, friendly or trusting.
    public var attitude: String { Self.attitude(for: relationship) }

    static func attitude(for value: Int) -> String {
        switch value {
        case ..<(-60): "hostile"
        case ..<(-20): "unfriendly"
        case ...20: "neutral"
        case ...60: "friendly"
        default: "trusting"
        }
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, relationshipRange.lowerBound), relationshipRange.upperBound)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The memory block appended to the NPC's instructions, or `nil` when
    /// there is nothing worth saying.
    func note(includeRelationship: Bool) -> String? {
        var lines: [String] = []
        if includeRelationship || relationship != 0 {
            lines.append("- You feel \(attitude) toward the player (\(relationship) on a scale from -100 to 100).")
        }
        if let facts = Persona.list(facts) { lines.append("- You remember: \(facts)") }
        if let summary = summary?.trimmedOrNil { lines.append("- Earlier conversation: \(summary)") }
        guard !lines.isEmpty else { return nil }
        return "Memory:\n" + lines.joined(separator: "\n")
    }
}

extension NPCMemory: CustomStringConvertible {
    public var description: String {
        "NPCMemory(relationship: \(relationship), facts: \(facts), summary: \(summary.map { "\"\($0)\"" } ?? "nil"))"
    }
}
