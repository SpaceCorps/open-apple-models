import Foundation
import OpenAppleModels
import OpenAppleModelsBridge

/// Process exit codes. Stable: scripts and agents branch on them.
enum ExitStatus {
    static let success: Int32 = 0
    /// Any other failure (generation failed, I/O error, tool failure…).
    static let failure: Int32 = 1
    /// Invalid command line or input files (bad flags, schema, tools, transcript).
    static let usage: Int32 = 2
    /// The model is unavailable (device not eligible, Apple Intelligence off, model downloading).
    static let modelUnavailable: Int32 = 3
    /// Guardrail violation or refusal.
    static let blocked: Int32 = 4
    /// The conversation exceeds the context window.
    static let contextExceeded: Int32 = 5
    /// The system rate-limited the request.
    static let rateLimited: Int32 = 6
    /// External tool calls are pending; answer them with `--resume … --tool-output`.
    static let toolCallsPending: Int32 = 10
    /// Interrupted (Ctrl-C).
    static let interrupted: Int32 = 130
}

/// An error the CLI reports and exits with.
///
/// Printed as `Error: <message>` on a terminal, or as
/// `{"error":{"code","message"}}` on standard error in JSON modes.
struct CLIError: Error, CustomStringConvertible {
    /// Machine-readable code: an ``AgentError/Code`` raw value, or a CLI code
    /// such as `usage`, `invalid_input`, `io_error`.
    var code: String
    var message: String
    var exitCode: Int32

    init(code: String, message: String, exitCode: Int32) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
    }

    var description: String { message }

    /// A problem with the command line.
    static func usage(_ message: String) -> CLIError {
        CLIError(code: "usage", message: message, exitCode: ExitStatus.usage)
    }

    /// A problem with an input file or value (tools, schema, transcript, image).
    static func invalidInput(_ message: String) -> CLIError {
        CLIError(code: "invalid_input", message: message, exitCode: ExitStatus.usage)
    }

    /// A file could not be read or written.
    static func io(_ message: String) -> CLIError {
        CLIError(code: "io_error", message: message, exitCode: ExitStatus.failure)
    }

    /// Maps an agent error to its exit code.
    init(_ error: AgentError) {
        let exitCode: Int32 = switch error.code {
        case .modelUnavailable: ExitStatus.modelUnavailable
        case .guardrailViolation, .refusal: ExitStatus.blocked
        case .contextSizeExceeded: ExitStatus.contextExceeded
        case .rateLimited: ExitStatus.rateLimited
        case .invalidSchema, .invalidRequest, .unsupportedLanguage: ExitStatus.usage
        case .cancelled: ExitStatus.interrupted
        default: ExitStatus.failure
        }
        self.init(code: error.code.rawValue, message: error.message, exitCode: exitCode)
    }

    /// Normalizes any error.
    init(normalizing error: any Error) {
        switch error {
        case let error as CLIError: self = error
        case let error as AgentError: self.init(error)
        case let error as BridgeError:
            self.init(code: error.name ?? "invalid_input", message: error.message, exitCode: ExitStatus.usage)
        case let error as SchemaConversionError:
            self.init(code: AgentError.Code.invalidSchema.rawValue, message: error.description, exitCode: ExitStatus.usage)
        case let error as JSONParseError:
            self.init(code: "invalid_input", message: error.description, exitCode: ExitStatus.usage)
        default:
            self.init(AgentError(error))
        }
    }

    /// `{"error": {"code", "message"}}`.
    var json: JSONValue {
        ["error": ["code": .string(code), "message": .string(message)]]
    }

    /// Prints the error to standard error, as JSON or text (and as a final
    /// event line on standard output when `asEvent` is set).
    func report(asJSON: Bool, asEvent: Bool = false) {
        if asEvent {
            Console.outJSON(["type": "error", "error": json["error"] ?? .null])
        }
        if asJSON {
            Console.errJSON(json)
        } else {
            Console.errLine(Style.red.apply("Error:") + " " + message)
        }
    }
}

/// Commands that report errors as JSON when asked to.
protocol ReportsErrorsAsJSON {
    /// Whether errors should be printed as `{"error": …}` JSON on standard error.
    var reportsErrorsAsJSON: Bool { get }
    /// Whether errors should also end the standard-output event stream with
    /// a `{"type": "error", "error": …}` line.
    var reportsErrorsAsEvents: Bool { get }
}

extension ReportsErrorsAsJSON {
    var reportsErrorsAsEvents: Bool { false }
}

/// Ends the process with an exit code, without printing an error (the
/// command already printed its result).
struct ExitRequest: Error {
    var code: Int32
}
