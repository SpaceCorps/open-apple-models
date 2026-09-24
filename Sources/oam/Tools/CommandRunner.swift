import Foundation
import OpenAppleModels
import Synchronization

/// How a command-backed tool runs (the `"x-oam"` block of a tool definition).
struct CommandSpec: Sendable, Hashable {
    /// Program and arguments. The program is an absolute path.
    var argv: [String]
    /// Working directory; `nil` runs in the CLI's current directory.
    var workingDirectory: String?
    /// Time limit for one call.
    var timeout: Duration
    /// Extra environment variables.
    var environment: [String: String]
    /// Longest output passed to the model; longer output is cut.
    var maxOutputCharacters: Int

    static let defaultTimeoutSeconds = 30.0
    static let defaultMaxOutputCharacters = 8000
}

/// Runs a command-backed tool: the call's arguments JSON goes to standard
/// input (and to `OAM_TOOL_ARGUMENTS`), standard output becomes the tool
/// output, and a non-zero exit becomes an error the model sees.
enum CommandRunner {
    /// Output collected from one run.
    struct Result: Sendable {
        var status: Int32
        var terminatedBySignal: Bool
        var stdout: String
        var stderr: String
        var stdoutOverflow: Int
        var timedOut: Bool
    }

    /// Runs the command for `call` and converts the result into tool output.
    static func output(for call: ToolCall, spec: CommandSpec) async -> ToolOutput {
        let result: Result
        do {
            result = try await run(spec, input: call.arguments.serialized(), environment: [
                "OAM_TOOL_NAME": call.name,
                "OAM_TOOL_CALL_ID": call.id,
                "OAM_TOOL_ARGUMENTS": call.arguments.serialized(),
            ])
        } catch is CancellationError {
            return .error("The tool call was cancelled.")
        } catch {
            return .error("Tool '\(call.name)' could not start \(spec.argv[0]): \(error.localizedDescription)")
        }
        if result.timedOut {
            return .error("Tool '\(call.name)' timed out after \(format(spec.timeout)) and was stopped.")
        }
        var text = result.stdout
        if text.hasSuffix("\n") { text.removeLast() }
        if result.stdoutOverflow > 0 { text += "\n…[output truncated: \(result.stdoutOverflow) more bytes]" }
        guard result.status == 0, !result.terminatedBySignal else {
            let detail = [result.stderr, text]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let how = result.terminatedBySignal ? "was killed by signal \(result.status)" : "exited with status \(result.status)"
            return .error("Tool '\(call.name)' \(how)" + (detail.map { ": \(String($0.prefix(2000)))" } ?? "."))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .text("(no output)") }
        if result.stdoutOverflow == 0, trimmed.first == "{" || trimmed.first == "[",
           let json = try? JSONValue(parsing: trimmed) {
            return .json(json)
        }
        return .text(text)
    }

    /// Runs a command to completion (or until its time limit).
    static func run(_ spec: CommandSpec, input: String, environment extra: [String: String]) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.argv[0])
        process.arguments = Array(spec.argv.dropFirst())
        if let directory = spec.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: ModelProvider.scriptVariable)
        for (key, value) in spec.environment { environment[key] = value }
        for (key, value) in extra { environment[key] = value }
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let limit = spec.maxOutputCharacters
        let outCollector = PipeCollector(limit: limit)
        let errCollector = PipeCollector(limit: 4000)
        let exit = ExitSignal()
        process.terminationHandler = { finished in
            exit.fire(status: finished.terminationStatus, signaled: finished.terminationReason == .uncaughtSignal)
        }

        try process.run()
        outCollector.start(stdout.fileHandleForReading)
        errCollector.start(stderr.fileHandleForReading)
        // Feed the arguments on a separate thread: a command that never reads
        // its input must not block us once the pipe buffer fills.
        let writer = stdin.fileHandleForWriting
        let payload = Data(input.utf8)
        Thread.detachNewThread {
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }

        let pid = process.processIdentifier
        let timedOut = Locked(false)
        let watchdog = Task {
            try await Task.sleep(for: spec.timeout)
            timedOut.value = true
            terminate(pid: pid)
        }
        let (status, signaled) = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            terminate(pid: pid)
        }
        watchdog.cancel()
        // Background children may keep the pipes open; do not wait forever.
        await outCollector.waitForEnd(upTo: .seconds(1))
        await errCollector.waitForEnd(upTo: .milliseconds(200))
        try Task.checkCancellation()

        let (outText, overflow) = outCollector.result()
        let (errText, _) = errCollector.result()
        return Result(
            status: status, terminatedBySignal: signaled, stdout: outText, stderr: errText,
            stdoutOverflow: overflow, timedOut: timedOut.value)
    }

    /// SIGTERM, then SIGKILL if the process is still alive a second later.
    private static func terminate(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 1)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return seconds == seconds.rounded() ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
    }
}

/// Resumes waiters once a process has exited.
private final class ExitSignal: Sendable {
    private struct State {
        var result: (Int32, Bool)?
        var waiters: [CheckedContinuation<(Int32, Bool), Never>] = []
    }

    private let state = Mutex(State())

    func fire(status: Int32, signaled: Bool) {
        let waiters = state.withLock { state in
            state.result = (status, signaled)
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: (status, signaled)) }
    }

    func wait() async -> (Int32, Bool) {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> (Int32, Bool)? in
                if let result = state.result { return result }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Drains a pipe on its own thread, keeping at most `limit` bytes.
private final class PipeCollector: Sendable {
    private struct State {
        var data = Data()
        var overflow = 0
        var finished = false
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) { self.limit = limit }

    func start(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            while true {
                let chunk = (try? handle.read(upToCount: 64 << 10)) ?? nil
                guard let chunk, !chunk.isEmpty else { break }
                state.withLock { state in
                    let room = max(0, limit - state.data.count)
                    state.data.append(chunk.prefix(room))
                    state.overflow += max(0, chunk.count - room)
                }
            }
            state.withLock { $0.finished = true }
        }
    }

    func waitForEnd(upTo limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !state.withLock({ $0.finished }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func result() -> (String, Int) {
        state.withLock { state in
            (String(decoding: state.data, as: UTF8.self), state.overflow)
        }
    }
}
