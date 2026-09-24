import Foundation

extension KeyedDecodingContainer {
    /// Decodes `key` if present (and not `null`), otherwise returns `fallback`.
    /// Lets games write partial JSON (a persona with only a name, options
    /// with one field) and get sensible defaults for the rest.
    func decode<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
