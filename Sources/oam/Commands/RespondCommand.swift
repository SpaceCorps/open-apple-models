import ArgumentParser
import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsBridge

/// `oam respond`: one turn, with tools.
struct RespondCommand: AsyncParsableCommand, ReportsErrorsAsJSON {
    static let configuration = CommandConfiguration(
        commandName: "respond",
        abstract: "Generate a response to a prompt, calling tools as needed.",
        discussion: """
            Tools come from an OpenAI-format tools file. A tool with an "x-oam" command runs \
            locally: the arguments JSON arrives on stdin (and in $OAM_TOOL_ARGUMENTS), stdout is the \
            output, and a non-zero exit is reported to the model as an error. Tools without a command \
            are external: oam prints {"status":"tool_calls","calls":[...],"transcript":"<file>"} and \
            exits with code 10. Run the calls yourself, then continue with:

              oam respond --resume <file> --tool-output <call_id>=<text|@file> ...

            Exit codes: 0 ok, 1 error, 2 usage/invalid input, 3 model unavailable, 4 guardrail or \
            refusal, 5 context exceeded, 6 rate limited, 10 external tool calls pending.

            EXAMPLES
              oam respond 'What is Swift?'
              cat notes.txt | oam respond 'Summarize these notes:'
              oam respond --tools tools.json --tool-choice required 'Weather in Paris?'
              oam respond --schema person.json --json 'Invent a character'
              oam respond --resume /tmp/oam-1a2b.json --tool-output call_1=@result.json
            """)

    @Argument(help: "Prompt for the model. Piped standard input is appended (or used alone when omitted).")
    var prompt: [String] = []

    @Option(name: [.short, .long], help: ArgumentHelp("Instructions (system prompt) for the model to follow.", valueName: "text"))
    var instructions: String?

    @OptionGroup(title: "Tools")
    var toolFlags: ToolFlags

    @Option(help: ArgumentHelp("JSON Schema file for structured output (also accepts 'fm schema object' files).", valueName: "file"))
    var schema: String?

    @Option(help: ArgumentHelp("Image file to include in the prompt (repeatable).", valueName: "path"))
    var image: [String] = []

    @Flag(help: "Print one JSON result: {status, text, structured, toolCalls, usage, steps}.")
    var json = false

    @Flag(help: "Print JSON-lines events as the turn runs (ends with a completed, tool_calls or error event).")
    var events = false

    @Flag(inversion: .prefixedNo, help: "Stream text as it is generated.")
    var stream = true

    @OptionGroup(title: "Sampling")
    var generation: GenerationFlags

    @Option(name: .customLong("save-transcript"), help: ArgumentHelp("Save the conversation to a file after responding.", valueName: "file"))
    var saveTranscript: String?

    @Option(help: ArgumentHelp("Continue a saved conversation (from --save-transcript, exit code 10, or 'fm respond --save-transcript').", valueName: "file"))
    var resume: String?

    @Option(name: .customLong("tool-output"), help: ArgumentHelp(
        "Output for a pending external tool call: <call_id>=<text>, <call_id>=@<file> or <call_id>=@- (stdin). Repeatable.",
        valueName: "id=value"))
    var toolOutputs: [String] = []

    @Option(name: .customLong("tool-error"), help: ArgumentHelp(
        "Report a pending external tool call as failed: <call_id>=<message>. Repeatable.", valueName: "id=message"))
    var toolErrors: [String] = []

    @Flag(name: .customLong("ask-tools"), help: "Ask for external tool outputs on the terminal instead of exiting with code 10.")
    var askTools = false

    @Flag(name: .customLong("no-stdin"), help: "Never read the prompt from standard input.")
    var noStdin = false

    @Flag(name: [.short, .long], help: "Show tool calls, model steps and token usage on standard error.")
    var verbose = false

    var reportsErrorsAsJSON: Bool { json || events }
    var reportsErrorsAsEvents: Bool { events }

    func validate() throws {
        if json && events { throw ValidationError("Use either --json or --events, not both.") }
        if resume == nil, !toolOutputs.isEmpty || !toolErrors.isEmpty {
            throw ValidationError("--tool-output and --tool-error continue a conversation: add --resume <file>.")
        }
    }

    private var outputMode: OutputMode {
        if json { return .json }
        if events { return .events }
        return .text(stream: stream, showsTools: verbose || Console.stderrIsTerminal)
    }

    /// What a turn starts from: a fresh prompt, or the outputs of a pending
    /// tool round.
    private struct TurnSetup {
        var prompt: Prompt
        var history: Transcript?
        var policy: ToolPolicy
        /// Tool records from earlier invocations of the same turn.
        var priorRecords: [JSONValue] = []
        /// Tool rounds and calls used by earlier invocations of the same turn.
        var priorRounds = 0
        var priorCalls = 0
    }

    func run() async throws {
        let mode = outputMode
        let saved = try resume.map { path throws(CLIError) in try SavedConversation.load(path) }

        // Tools: --tools, else those saved with the conversation.
        var toolSet = try toolFlags.loadTools()
        if toolSet == nil, let saved {
            toolSet = try Self.restoreTools(from: saved, source: resume ?? "")
        }
        let tools = toolSet ?? ToolSet()
        if case .text = mode {
            for warning in tools.warnings { Console.errLine(Style.yellow.apply("warning: ") + warning) }
        }

        // Structured output: --schema, else the pending turn's schema.
        let schemaJSON = try schema.map { path throws(CLIError) in try SchemaInput.load(path) }
            ?? (saved?.pending != nil ? saved?.schema : nil)
        var generationSchema: GenerationSchema?
        if let schemaJSON {
            let converted = try Self.convertSchema(schemaJSON, source: schema ?? "saved schema")
            generationSchema = converted.schema
            if case .text = mode, verbose {
                for warning in converted.warnings { Console.errLine(Style.yellow.apply("warning: ") + "schema: " + warning) }
            }
        }

        let setup = try await prepareTurn(saved: saved, tools: tools)
        if askTools, !LineReader.hasTerminal {
            throw CLIError.usage("--ask-tools needs a terminal; without one, handle exit code 10 and resume with --tool-output.")
        }

        let model = try ModelProvider.makeModel()
        let agent: Agent
        do {
            agent = try Agent(
                model: model,
                instructions: instructions ?? saved?.savedInstructions,
                tools: try tools.agentTools(),
                configuration: generation.configuration(),
                history: setup.history)
        } catch {
            throw CLIError(normalizing: error)
        }

        let run = generationSchema.map { agent.run(setup.prompt, schema: $0, policy: setup.policy) }
            ?? agent.run(setup.prompt, policy: setup.policy)
        let runner = TurnRunner(agent: agent, run: run, mode: mode, external: askTools ? .ask : .stop, showsSteps: verbose)

        switch try await runner.drive() {
        case .completed(let response):
            if let saveTranscript {
                try SavedConversation(
                    transcript: agent.transcript, modelName: ModelProvider.modelName,
                    tools: tools.isEmpty ? nil : tools.definitions, schema: nil, pending: nil
                ).save(to: saveTranscript)
            }
            printCompleted(response, mode: mode, priorRecords: setup.priorRecords, warnings: tools.warnings)
        case .pending(var round, let transcript):
            // Budgets and records cover the whole turn, across resumes.
            round.records = setup.priorRecords + round.records
            round.roundsUsed += setup.priorRounds
            round.callsUsed += setup.priorCalls
            let path = saveTranscript ?? SavedConversation.temporaryPath()
            try SavedConversation(
                transcript: transcript, modelName: ModelProvider.modelName,
                tools: tools.definitions, schema: schemaJSON, pending: round
            ).save(to: path)
            printPending(round, transcriptPath: path, mode: mode)
            throw ExitRequest(code: ExitStatus.toolCallsPending)
        }
    }

    /// The prompt, history and policy of this invocation.
    private func prepareTurn(saved: SavedConversation?, tools: ToolSet) async throws(CLIError) -> TurnSetup {
        let policy = try toolFlags.policy(toolNames: tools.names)
        guard let saved, let pending = saved.pending else {
            let readsStandardInput = !noStdin && !toolOutputs.contains { $0.hasSuffix("=@-") }
            guard let text = PromptInput.text(arguments: prompt, readsStandardInput: readsStandardInput) ?? (image.isEmpty ? nil : "") else {
                throw .usage("No prompt: pass a prompt argument or pipe text on standard input.")
            }
            return TurnSetup(prompt: try PromptInput.prompt(text: text, images: image), history: saved?.transcript, policy: policy)
        }

        // Continuing a turn that stopped for external tools.
        guard prompt.isEmpty else {
            throw .usage("This conversation is waiting for tool outputs (\(pending.calls.map(\.id).joined(separator: ", "))); "
                + "answer them with --tool-output before sending a new prompt.")
        }
        let outputs = try await collectOutputs(for: pending)
        var continued = policy
        // The answered round already satisfied a required choice; continue in
        // auto mode with what is left of the turn's budget.
        continued.choice = try toolFlags.choice(toolNames: tools.names) ?? .auto
        continued.maxToolRounds = max(0, policy.maxToolRounds - pending.roundsUsed)
        continued.maxToolCalls = max(0, policy.maxToolCalls - pending.callsUsed)
        let answered = outputs.map { output in
            let call = pending.calls.first { $0.id == output.id }
            return BridgeCoding.json(ToolRecord(
                call: ToolCall(id: output.id, name: output.name, arguments: call?.arguments ?? [:]),
                output: output.output, duration: 0))
        }
        return TurnSetup(
            prompt: Prompt(""),  // generation continues after the tool outputs
            history: try saved.answering(outputs),
            policy: continued,
            priorRecords: pending.records + answered,
            priorRounds: pending.roundsUsed,
            priorCalls: pending.callsUsed)
    }

    // MARK: Output

    /// `{"status": "tool_calls", "calls", "transcript"}` (an event line with `--events`).
    private func printPending(_ round: PendingRound, transcriptPath: String, mode: OutputMode) {
        var status: [(String, JSONValue)] = [
            ("status", "tool_calls"),
            ("calls", .array(round.calls.map(BridgeCoding.json))),
            ("transcript", .string(InputFiles.absolute(transcriptPath))),
        ]
        if mode == .events { status.insert(("type", "tool_calls"), at: 0) }
        Console.outJSON(.object(JSONObject(status)))
    }

    private func printCompleted(_ response: AgentResponse, mode: OutputMode, priorRecords: [JSONValue], warnings: [String]) {
        var result: JSONObject = ["status": "completed"]
        for (key, value) in BridgeCoding.json(response) { result[key] = value }
        result["toolCalls"] = .array(priorRecords + response.toolCalls.map(BridgeCoding.json))
        if let saveTranscript { result["transcript"] = .string(InputFiles.absolute(saveTranscript)) }
        if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }

        switch mode {
        case .json:
            Console.outJSON(.object(result))
        case .events:
            Console.outJSON(["type": "completed", "response": .object(result)])
        case .text(let streamed, _):
            if let structured = response.structured {
                Console.outJSON(structured, pretty: true)
            } else if !streamed {
                Console.outLine(response.text)
            }
            if verbose {
                let usage = response.usage
                let calls = priorRecords.count + response.toolCalls.count
                Console.errLine(Style.dim.apply(
                    "· \(usage.inputTokens) input tokens (\(usage.cachedInputTokens) cached), \(usage.outputTokens) output tokens, "
                        + "\(response.steps.count) step\(response.steps.count == 1 ? "" : "s"), \(calls) tool call\(calls == 1 ? "" : "s")"))
            }
            if let saveTranscript {
                Console.errLine(Style.dim.apply("Transcript saved to: \(InputFiles.absolute(saveTranscript))"))
            }
        }
    }

    // MARK: Resuming

    /// Outputs for the pending calls, from `--tool-output` / `--tool-error`
    /// or, with `--ask-tools`, the terminal.
    private func collectOutputs(for pending: PendingRound) async throws(CLIError) -> [RoundOutput] {
        let calls = Dictionary(pending.calls.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var supplied: [String: ToolOutput] = [:]
        func record(_ argument: String, option: String, isError: Bool) throws(CLIError) {
            let (id, value) = try ToolOutputInput.split(argument, option: option)
            guard calls[id] != nil else {
                throw .usage("\(option): no pending tool call has id '\(id)'. Pending: "
                    + pending.calls.map { "\($0.id) (\($0.name))" }.joined(separator: ", ") + ".")
            }
            guard supplied[id] == nil else { throw .usage("\(option): more than one output for tool call '\(id)'.") }
            supplied[id] = try ToolOutputInput.parse(value, isError: isError)
        }
        for argument in toolOutputs { try record(argument, option: "--tool-output", isError: false) }
        for argument in toolErrors { try record(argument, option: "--tool-error", isError: true) }

        let missing = pending.calls.filter { supplied[$0.id] == nil }
        if !missing.isEmpty {
            guard askTools, LineReader.hasTerminal else {
                throw CLIError(
                    code: "missing_tool_output",
                    message: "Missing output for pending tool call(s): "
                        + missing.map { "\($0.id) = \($0.name) \($0.arguments.serialized())" }.joined(separator: "; ")
                        + ". Pass --tool-output <call_id>=<text|@file> for each.",
                    exitCode: ExitStatus.usage)
            }
            for call in missing { supplied[call.id] = await ToolOutputInput.ask(for: call) }
        }
        return pending.calls.map { call in RoundOutput(id: call.id, name: call.name, output: supplied[call.id]!) }
    }

    /// Tools of a saved conversation: the saved definitions (with commands),
    /// else the transcript's tool definitions as external tools.
    static func restoreTools(from saved: SavedConversation, source: String) throws(CLIError) -> ToolSet? {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if let definitions = saved.tools {
            return try ToolFile.parse(definitions, baseDirectory: base, source: "\(source) (saved tools)")
        }
        guard let setup = BridgeCoding.savedSetup(of: saved.transcript), !setup.tools.isEmpty else { return nil }
        var set = ToolSet()
        for definition in setup.tools {
            guard let parameters = try? JSONSchema(definition.parameters) else {
                set.warnings.append("\(definition.name): could not restore its schema; pass --tools.")
                continue
            }
            set.specs.append(ToolSpec(name: definition.name, description: definition.description, parameters: parameters, command: nil))
        }
        return set
    }

    /// Converts a JSON Schema for structured output.
    static func convertSchema(_ value: JSONValue, source: String) throws(CLIError) -> SchemaConverter.Result {
        guard value.objectValue != nil else { throw .invalidInput("\(source): a schema must be a JSON object.") }
        do {
            return try SchemaConverter.convert(JSONSchema(value), rootName: "Response")
        } catch {
            throw CLIError(code: AgentError.Code.invalidSchema.rawValue, message: "\(source): \(error.description)", exitCode: ExitStatus.usage)
        }
    }
}
