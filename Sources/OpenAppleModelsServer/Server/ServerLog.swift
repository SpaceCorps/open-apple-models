import Foundation

/// A diagnostic message from ``OpenAIServer``.
public struct ServerLogEntry: Sendable, CustomStringConvertible {
    /// Severity, from routine diagnostics to failures.
    public enum Level: Int, Sendable, Comparable, CustomStringConvertible {
        case debug, info, warning, error

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var description: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .warning: "warning"
            case .error: "error"
            }
        }
    }

    /// Severity of the entry.
    public var level: Level
    /// Human-readable text, e.g. an access-log line `POST /v1/chat/completions → 200 0.61s`.
    public var message: String
    /// When the entry was created.
    public var date: Date

    /// Creates a log entry.
    public init(level: Level, message: String, date: Date = Date()) {
        self.level = level
        self.message = message
        self.date = date
    }

    public var description: String { "[\(level)] \(message)" }
}

/// Forwards log entries to the configured sink, if any.
///
/// Messages often quote client input (paths are percent-decoded, header
/// values may hold control characters), so control, line-separator and
/// bidi-formatting characters are percent-encoded: a client cannot forge
/// log lines or restyle a terminal.
struct ServerLogger: Sendable {
    let sink: (@Sendable (ServerLogEntry) -> Void)?

    func log(_ level: ServerLogEntry.Level, _ message: @autoclosure () -> String) {
        guard let sink else { return }
        sink(ServerLogEntry(level: level, message: Self.escapingControlCharacters(message())))
    }

    /// `text` with control characters (C0, DEL, C1), line and paragraph
    /// separators and format characters (such as bidi overrides)
    /// percent-encoded as UTF-8, e.g. a newline becomes `%0A`.
    static func escapingControlCharacters(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsEscaping) else { return text }
        var result = ""
        result.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if needsEscaping(scalar) {
                for byte in String(scalar).utf8 { result += "%" + (byte < 16 ? "0" : "") + String(byte, radix: 16, uppercase: true) }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func needsEscaping(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}
