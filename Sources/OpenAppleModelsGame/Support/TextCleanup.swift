import Foundation

/// Small, conservative fixes for quirks of small on-device models.
enum TextCleanup {
    private static let openingQuotes: Set<Character> = ["\"", "\u{201C}", "'", "\u{2018}", "\u{00AB}"]
    private static let closingQuotes: Set<Character> = ["\"", "\u{201D}", "'", "\u{2019}", "\u{00BB}"]

    /// Cleans a spoken line: trims whitespace, removes a leading speaker label
    /// ("Gorm:", "**Gorm**:") and quotes wrapping the whole line.
    static func spokenLine(_ raw: String, speaker: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = strippingSpeakerLabel(text, speaker: speaker)
        if text.count >= 2, let first = text.first, let last = text.last,
           openingQuotes.contains(first), closingQuotes.contains(last) {
            let inner = text.dropFirst().dropLast()
            // Only unwrap when the quotes enclose the whole line.
            if !inner.contains(where: { $0 == "\"" || $0 == "\u{201C}" || $0 == "\u{201D}" }) {
                text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// Cleans the prefix of a line that is still streaming. Returns `nil`
    /// while the text could still turn out to be a speaker label, so nothing
    /// that would later be removed is shown.
    static func streamingLine(_ raw: String, speaker: String) -> String? {
        let text = String(raw.drop { $0.isWhitespace })
        let lowered = text.lowercased()
        // "Gor" could still become "Gorm:" – wait for more text.
        let couldBecomeLabel = !text.isEmpty && speakerLabels(speaker).contains { label in
            label.count > text.count && label.lowercased().hasPrefix(lowered)
        }
        if couldBecomeLabel { return nil }
        var result = strippingSpeakerLabel(text, speaker: speaker)
        if let first = result.first, openingQuotes.contains(first), first != "'" {
            result = String(result.dropFirst()).trimmingPrefixWhitespace()
        }
        return result
    }

    static func strippingSpeakerLabel(_ text: String, speaker: String) -> String {
        guard !speaker.isEmpty else { return text }
        let lowered = text.lowercased()
        for label in speakerLabels(speaker) where lowered.hasPrefix(label.lowercased()) {
            return String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func speakerLabels(_ speaker: String) -> [String] {
        guard !speaker.isEmpty else { return [] }
        return ["\(speaker) says:", "**\(speaker)**:", "**\(speaker):**", "*\(speaker)*:", "\(speaker):"]
    }

    /// The first non-empty line of `text`, cleaned as a spoken line.
    static func singleLine(_ text: String, speaker: String) -> String {
        let first = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return spokenLine(first, speaker: speaker)
    }
}

extension String {
    func trimmingPrefixWhitespace() -> String {
        String(drop { $0.isWhitespace })
    }
}
