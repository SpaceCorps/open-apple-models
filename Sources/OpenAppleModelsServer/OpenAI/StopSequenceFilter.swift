import Foundation

/// Releases streamed text while enforcing OpenAI `stop` sequences.
///
/// Text that could be the beginning of a stop sequence is held back until
/// it is disambiguated, so a stop sequence never leaks to the client even
/// when it arrives split across several model snapshots.
struct StopSequenceFilter: Sendable {
    let stops: [String]
    /// Text released so far.
    private(set) var released = ""
    /// Set once a stop sequence was found; no further text is released.
    private(set) var stopped = false

    init(stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }
    }

    /// Updates with the full text generated so far and returns newly
    /// releasable text. Returns `nil` if the text no longer extends what was
    /// already released (the model rewrote earlier output).
    mutating func update(fullText: String) -> String? {
        guard !stopped else { return "" }
        var releasable = Substring(fullText)
        if let stop = earliestStop(in: fullText) {
            releasable = fullText[..<stop]
            stopped = true
        } else if let held = heldBackSuffixLength(of: fullText), held > 0 {
            releasable = fullText.dropLast(held)
        }
        return release(releasable)
    }

    /// Releases everything left at the end of generation.
    mutating func finish(fullText: String) -> String? {
        guard !stopped else { return "" }
        if let stop = earliestStop(in: fullText) {
            stopped = true
            return release(fullText[..<stop])
        }
        return release(Substring(fullText))
    }

    private mutating func release(_ releasable: Substring) -> String? {
        guard releasable.hasPrefix(released) else { return nil }
        let delta = String(releasable.dropFirst(released.count))
        released = String(releasable)
        return delta
    }

    private func earliestStop(in text: String) -> String.Index? {
        stops.compactMap { text.range(of: $0)?.lowerBound }.min()
    }

    /// Length of the longest suffix of `text` that is a proper prefix of a stop sequence.
    private func heldBackSuffixLength(of text: String) -> Int? {
        var best = 0
        for stop in stops {
            var length = min(stop.count - 1, text.count)
            while length > best {
                if text.hasSuffix(stop.prefix(length)) {
                    best = length
                    break
                }
                length -= 1
            }
        }
        return best
    }
}
