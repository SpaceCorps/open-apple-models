import Foundation

/// How a character feels while speaking a line — drive portraits,
/// animations, voice or text color from it.
///
/// Encodes as its lowercase raw value (`"angry"`). Unknown values decode as
/// ``neutral`` so saves stay loadable if cases are added or removed.
public enum Emotion: String, Sendable, Hashable, CaseIterable, Codable {
    case neutral
    case happy
    case sad
    case angry
    case afraid
    case surprised
    case suspicious
    case amused
    case disgusted
    case excited
    case curious
    case confused
    case worried
    case grateful
    case annoyed
    case proud

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Emotion(matching: raw) ?? .neutral
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Parses model output leniently: case-insensitive, surrounding
    /// punctuation ignored, common synonyms mapped (`"mad"` → ``angry``,
    /// `"scared"` → ``afraid``). Returns `nil` if nothing matches.
    public init?(matching text: String) {
        let key = text.lowercased().trimmingCharacters(in: .letters.inverted)
        if let exact = Emotion(rawValue: key) {
            self = exact
            return
        }
        guard let synonym = Self.synonyms[key] else { return nil }
        self = synonym
    }

    private static let synonyms: [String: Emotion] = [
        "calm": .neutral, "content": .neutral, "indifferent": .neutral, "bored": .neutral,
        "joyful": .happy, "glad": .happy, "cheerful": .happy, "pleased": .happy, "friendly": .happy, "warm": .happy,
        "unhappy": .sad, "sorrowful": .sad, "melancholy": .sad, "grieving": .sad,
        "mad": .angry, "furious": .angry, "enraged": .angry, "hostile": .angry,
        "scared": .afraid, "fearful": .afraid, "frightened": .afraid, "terrified": .afraid, "nervous": .worried,
        "shocked": .surprised, "astonished": .surprised, "startled": .surprised,
        "wary": .suspicious, "distrustful": .suspicious, "skeptical": .suspicious, "sceptical": .suspicious,
        "amusement": .amused, "playful": .amused, "laughing": .amused,
        "disgust": .disgusted, "revolted": .disgusted,
        "eager": .excited, "thrilled": .excited, "enthusiastic": .excited,
        "interested": .curious, "intrigued": .curious,
        "puzzled": .confused, "uncertain": .confused,
        "anxious": .worried, "concerned": .worried,
        "thankful": .grateful,
        "irritated": .annoyed, "grumpy": .annoyed, "impatient": .annoyed, "gruff": .annoyed,
        "confident": .proud, "smug": .proud,
    ]
}
