import Foundation
import OpenAppleModels
import Synchronization

/// Terminal output for the CLI.
///
/// All writes are unbuffered and go straight to the file descriptor, so text
/// written from different tasks never interleaves mid-write and nothing is
/// lost when the process exits early. Colors follow the `NO_COLOR`
/// convention and are only used on terminals.
enum Console {
    enum Stream {
        case standardOutput
        case standardError

        var descriptor: Int32 { self == .standardOutput ? STDOUT_FILENO : STDERR_FILENO }
    }

    static let stdinIsTerminal = isatty(STDIN_FILENO) != 0
    static let stdoutIsTerminal = isatty(STDOUT_FILENO) != 0
    static let stderrIsTerminal = isatty(STDERR_FILENO) != 0

    private static let lock = Mutex(())

    /// Whether ANSI styling is used on `stream`.
    static func usesColor(_ stream: Stream) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["NO_COLOR"].map({ !$0.isEmpty }) == true { return false }
        if environment["TERM"] == "dumb" { return false }
        return stream == .standardOutput ? stdoutIsTerminal : stderrIsTerminal
    }

    /// Writes `text` as-is to standard output.
    static func out(_ text: String) { write(text, to: .standardOutput) }

    /// Writes `text` followed by a newline to standard output.
    static func outLine(_ text: String = "") { write(text + "\n", to: .standardOutput) }

    /// Writes `text` followed by a newline to standard error.
    static func errLine(_ text: String = "") { write(text + "\n", to: .standardError) }

    /// Writes raw text to a stream, retrying partial writes.
    static func write(_ text: String, to stream: Stream) {
        guard !text.isEmpty else { return }
        lock.withLock { _ in
            var bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeMutableBytes { buffer in
                    Foundation.write(stream.descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    return  // EPIPE or a closed stream: drop the output.
                }
                offset += written
            }
            bytes.removeAll()
        }
    }

    /// Writes a JSON value to standard output: one compact line, or
    /// indented when `pretty` is set.
    static func outJSON(_ value: JSONValue, pretty: Bool = false) {
        outLine(value.serialized(pretty ? [.prettyPrinted] : []))
    }

    /// Writes one compact JSON value per line to standard error.
    static func errJSON(_ value: JSONValue) {
        errLine(value.serialized())
    }
}

/// ANSI styles, applied only when the target stream supports color.
enum Style {
    case bold, dim, italic, red, green, yellow, blue, magenta, cyan

    private var code: String {
        switch self {
        case .bold: "1"
        case .dim: "2"
        case .italic: "3"
        case .red: "31"
        case .green: "32"
        case .yellow: "33"
        case .blue: "34"
        case .magenta: "35"
        case .cyan: "36"
        }
    }

    /// `text` wrapped in this style for `stream` (unchanged without color).
    func apply(_ text: String, on stream: Console.Stream = .standardError) -> String {
        guard Console.usesColor(stream), !text.isEmpty else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }
}

/// Reads lines without blocking Swift's cooperative thread pool.
enum LineReader {
    /// Reads one line from standard input on a dedicated thread. Returns
    /// `nil` at end of input.
    static func readLine() async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Swift.readLine(strippingNewline: true))
            }
        }
    }

    /// Asks a question on the controlling terminal (`/dev/tty`), so it works
    /// even when standard input and output are redirected. Returns `nil` when
    /// there is no terminal or at end of input.
    static func ask(_ question: String) async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: askSynchronously(question))
            }
        }
    }

    private static func askSynchronously(_ question: String) -> String? {
        guard let tty = fopen("/dev/tty", "r+") else { return nil }
        defer { fclose(tty) }
        fputs(question, tty)
        fflush(tty)
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        let count = getline(&line, &capacity, tty)
        guard count >= 0, let line else { return nil }
        var text = String(cString: line)
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    /// Whether a controlling terminal is available for ``ask(_:)``.
    static var hasTerminal: Bool {
        let descriptor = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
