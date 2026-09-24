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
struct ServerLogger: Sendable {
    let sink: (@Sendable (ServerLogEntry) -> Void)?

    func log(_ level: ServerLogEntry.Level, _ message: @autoclosure () -> String) {
        guard let sink else { return }
        sink(ServerLogEntry(level: level, message: message()))
    }
}
