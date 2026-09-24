import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsBridge
import Synchronization

/// How a turn's progress and result are printed.
enum OutputMode: Sendable, Equatable {
    /// Human-readable text on standard output; tool activity on standard
    /// error when `showsTools` is set.
    case text(stream: Bool, showsTools: Bool)
    /// One JSON result object at the end.
    case json
    /// JSON-lines events as the turn runs.
    case events

    /// JSON output (errors are then reported as JSON too).
    var isMachineReadable: Bool { if case .text = self { false } else { true } }
}

/// How a turn ended.
enum TurnOutcome: Sendable {
    /// The model answered.
    case completed(AgentResponse)
    /// The model called external tools; the conversation (ending with the
    /// tool calls) must be saved so the caller can supply their outputs.
    case pending(PendingRound, Transcript)
}

/// Where external tool outputs come from.
enum ExternalToolHandling: Sendable {
    /// Stop the turn and report the calls (exit code 10).
    case stop
    /// Ask on the terminal.
    case ask
}

/// Drives one agent turn: prints events in the chosen format, runs the
/// external-tool protocol, and returns the outcome.
///
/// When the model calls external tools and ``ExternalToolHandling/stop`` is
/// in effect, the runner waits until every call of the tool round is either
/// an external call or a finished local call (parallel calls arrive within
/// milliseconds of each other), captures the live transcript — which then
/// ends with the round's tool-call entry — and cancels the turn.
final class TurnRunner: Sendable {
    private let agent: Agent
    private let run: AgentRun
    private let mode: OutputMode
    private let external: ExternalToolHandling
    private let showsSteps: Bool
    private let asker = SerialQueue()

    private struct State {
        var text = ""
        var printed = false
        var records: [ToolRecord] = []
        var roundRecords: [ToolRecord] = []
        var localInFlight: Set<String> = []
        var pending: [ToolCall] = []
        var lastStep: ModelStep?
        var check: Task<Void, Never>?
        var stopped: (PendingRound, Transcript)?
    }

    private let state = Mutex(State())

    /// - Parameter showsSteps: In text mode, also print each model step
    ///   after the first (tool-calling mode and enabled tools).
    init(agent: Agent, run: AgentRun, mode: OutputMode, external: ExternalToolHandling, showsSteps: Bool = false) {
        self.agent = agent
        self.run = run
        self.mode = mode
        self.external = external
        self.showsSteps = showsSteps
    }

    /// Runs the turn to its end.
    func drive() async throws(CLIError) -> TurnOutcome {
        do {
            for try await event in run {
                if state.withLock({ $0.stopped != nil }) { break }
                if case .completed(let response) = event {
                    finishText()
                    return .completed(response)
                }
                handle(event)
            }
        } catch {
            if let stopped = state.withLock({ $0.stopped }) { return .pending(stopped.0, stopped.1) }
            finishText()
            throw CLIError(normalizing: error)
        }
        if let stopped = state.withLock({ $0.stopped }) { return .pending(stopped.0, stopped.1) }
        throw CLIError(AgentError(.generationFailed, "The turn ended without a response."))
    }

    /// Cancels the turn (e.g. on Ctrl-C).
    func cancel() { run.cancel() }

    // MARK: Events

    private func handle(_ event: AgentEvent) {
        if mode == .events, let json = BridgeCoding.json(event) {
            Console.outJSON(json)
        }
        switch event {
        case .modelStep(let step):
            state.withLock { state in
                state.lastStep = step
                state.roundRecords = []
            }
            if showsSteps, case .text = mode, step.index > 0 || step.toolCallingMode != .allowed {
                let tools = step.enabledTools.isEmpty ? "" : " [\(step.enabledTools.joined(separator: ", "))]"
                Console.errLine(Style.dim.apply("· step \(step.index + 1): tools \(BridgeCoding.json(step)["toolCallingMode"]?.stringValue ?? "")\(tools)"))
            }
        case .text(let delta, let text, let isReset):
            let (shouldPrint, needsBreak) = state.withLock { state -> (Bool, Bool) in
                state.text = text
                guard case .text(true, _) = mode else { return (false, false) }
                defer { state.printed = true }
                return (true, isReset && state.printed)
            }
            if shouldPrint {
                if needsBreak { Console.out("\n") }
                Console.out(delta)
            }
        case .partial:
            break
        case .toolCallStarted(let call):
            state.withLock { _ = $0.localInFlight.insert(call.id) }
            showToolCall(call, external: false)
        case .toolCallRequested(let call):
            showToolCall(call, external: true)
            switch external {
            case .ask:
                asker.enqueue { [run] in
                    let output = await ToolOutputInput.ask(for: call)
                    run.submit(output, for: call.id)
                }
            case .stop:
                state.withLock { $0.pending.append(call) }
                scheduleRoundCheck()
            }
        case .toolCallCompleted(let record):
            let hasPending = state.withLock { state in
                state.records.append(record)
                state.roundRecords.append(record)
                state.localInFlight.remove(record.call.id)
                return !state.pending.isEmpty
            }
            showToolResult(record)
            if hasPending { scheduleRoundCheck() }
        case .completed:
            break
        }
    }

    private func finishText() {
        let printed = state.withLock { $0.printed }
        if printed { Console.out("\n") }
    }

    private var showsTools: Bool {
        if case .text(_, let showsTools) = mode { return showsTools }
        return false
    }

    private func showToolCall(_ call: ToolCall, external: Bool) {
        guard showsTools else { return }
        let kind = external ? "external tool" : "tool"
        Console.errLine(Style.cyan.apply("→ \(call.name)") + Style.dim.apply(" \(call.arguments.serialized())  (\(kind))"))
    }

    private func showToolResult(_ record: ToolRecord) {
        guard showsTools else { return }
        var text = record.output.modelText.replacingOccurrences(of: "\n", with: " ")
        if text.count > 160 { text = String(text.prefix(157)) + "…" }
        let style: Style = record.output.isError ? .red : .green
        Console.errLine(style.apply("← \(record.call.name)") + Style.dim.apply(" \(text)  (\(String(format: "%.2f", record.duration))s)"))
    }

    // MARK: Stopping for external tools

    /// Checks the round after a short quiet period (parallel calls of one
    /// round arrive within milliseconds). With `force`, stops even if the
    /// transcript's tool-call entry cannot be matched (after a longer wait).
    private func scheduleRoundCheck(force: Bool = false) {
        state.withLock { state in
            state.check?.cancel()
            state.check = Task { [self] in
                try? await Task.sleep(for: force ? .seconds(2) : .milliseconds(60))
                guard !Task.isCancelled else { return }
                stopIfRoundSettled(force: force)
            }
        }
    }

    private func stopIfRoundSettled(force: Bool) {
        let snapshot = state.withLock { state -> (pending: [ToolCall], round: [ToolRecord], all: [ToolRecord], step: ModelStep?)? in
            guard state.stopped == nil, !state.pending.isEmpty, state.localInFlight.isEmpty else { return nil }
            return (state.pending, state.roundRecords, state.records, state.lastStep)
        }
        guard let snapshot else { return }
        guard let (round, transcript) = Self.resolveRound(
            transcript: agent.transcript, pending: snapshot.pending, roundRecords: snapshot.round,
            allRecords: snapshot.all, roundsUsed: (snapshot.step?.completedToolRounds ?? 0) + 1,
            allowsFallback: force)
        else {
            // A call of the round has not reported yet; its completion
            // triggers another check, and this one is the backstop.
            scheduleRoundCheck(force: true)
            return
        }
        let first = state.withLock { state -> Bool in
            guard state.stopped == nil else { return false }
            state.stopped = (round, transcript)
            return true
        }
        if first { run.cancel() }
    }

    /// Matches the round's calls to the transcript's latest tool-call entry,
    /// so the ids the caller answers are the ids the model generated. The
    /// returned transcript ends with that entry (outputs of the round's local
    /// calls are kept in the round and re-added on resume).
    ///
    /// - Parameter allowsFallback: When the entry is missing or has calls
    ///   that match no pending or finished call, describe the round with an
    ///   entry of our own instead of returning `nil`.
    static func resolveRound(
        transcript: Transcript, pending: [ToolCall], roundRecords: [ToolRecord],
        allRecords: [ToolRecord], roundsUsed: Int, allowsFallback: Bool = true
    ) -> (PendingRound, Transcript)? {
        var entries = Array(transcript)
        let lastPrompt = entries.lastIndex { if case .prompt = $0 { true } else { false } } ?? -1
        let records = allRecords.map(BridgeCoding.json)
        let callsUsed = allRecords.count + pending.count

        if let callsIndex = entries.lastIndex(where: { if case .toolCalls = $0 { true } else { false } }),
           callsIndex > lastPrompt,
           entries[(callsIndex + 1)...].allSatisfy({ if case .toolOutput = $0 { true } else { false } }),
           case .toolCalls(let generated) = entries[callsIndex] {
            var unmatchedPending = pending
            var unmatchedRecords = roundRecords
            var calls: [ToolCall] = []
            var completed: [RoundOutput] = []
            var matchedAll = true
            for call in generated {
                let arguments = JSONValue(call.arguments)
                if let index = unmatchedPending.firstIndex(where: { $0.name == call.toolName && $0.arguments == arguments }) {
                    unmatchedPending.remove(at: index)
                    calls.append(ToolCall(id: call.id, name: call.toolName, arguments: arguments))
                } else if let index = unmatchedRecords.firstIndex(where: { $0.call.name == call.toolName && $0.call.arguments == arguments }) {
                    let record = unmatchedRecords.remove(at: index)
                    completed.append(RoundOutput(id: call.id, name: call.toolName, output: record.output))
                } else {
                    matchedAll = false
                    break
                }
            }
            if matchedAll, unmatchedPending.isEmpty {
                let round = PendingRound(
                    calls: calls, completed: completed, order: generated.map(\.id),
                    records: records, roundsUsed: roundsUsed, callsUsed: callsUsed)
                return (round, Transcript(entries: entries[...callsIndex]))
            }
            guard allowsFallback else { return nil }
            entries.removeSubrange(callsIndex...)
        } else if !allowsFallback {
            return nil
        }

        // Fallback: describe the round ourselves, with our own call ids.
        let roundCalls = roundRecords.map(\.call) + pending
        entries.append(.toolCalls(Transcript.ToolCalls(roundCalls.map { call in
            Transcript.ToolCall(id: call.id, toolName: call.name, arguments: call.arguments.generatedContent)
        })))
        let round = PendingRound(
            calls: pending,
            completed: roundRecords.map { RoundOutput(id: $0.call.id, name: $0.call.name, output: $0.output) },
            order: roundCalls.map(\.id), records: records, roundsUsed: roundsUsed, callsUsed: callsUsed)
        return (round, Transcript(entries: entries))
    }
}

/// Parsing tool outputs given on the command line or typed at a prompt.
enum ToolOutputInput {
    /// `text` → text output; `@file` → the file's contents; `@-` → standard
    /// input. A JSON object or array becomes JSON output. With `isError`, an
    /// error output.
    static func parse(_ value: String, isError: Bool = false) throws(CLIError) -> ToolOutput {
        var content = value
        if value.hasPrefix("@"), value.count > 1 {
            let path = String(value.dropFirst())
            let data = try InputFiles.read(path, what: "tool output file")
            content = String(decoding: data, as: UTF8.self)
            if content.hasSuffix("\n") { content.removeLast() }
        }
        if isError { return .error(content) }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" || trimmed.first == "[", let json = try? JSONValue(parsing: trimmed) {
            return .json(json)
        }
        return .text(content)
    }

    /// Splits `id=value`.
    static func split(_ argument: String, option: String) throws(CLIError) -> (id: String, value: String) {
        guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else {
            throw .usage("\(option) expects <call_id>=<value>; got '\(argument)'.")
        }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }

    /// Asks for one call's output on the terminal.
    static func ask(for call: ToolCall) async -> ToolOutput {
        let header = Style.yellow.apply("Tool call") + " \(call.name) \(call.arguments.serialized())\n"
        let question = "Output for \(call.name) (text, @file, or !error): "
        guard let answer = await LineReader.ask(header + question) else {
            return .error("No output was provided for '\(call.name)'.")
        }
        if answer.hasPrefix("!") { return .error(String(answer.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        do {
            return try parse(answer)
        } catch {
            return .error(error.message)
        }
    }
}

/// Runs closures one after another (for terminal prompts).
final class SerialQueue: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        tail.withLock { tail in
            let previous = tail
            tail = Task {
                await previous?.value
                await work()
            }
        }
    }
}
