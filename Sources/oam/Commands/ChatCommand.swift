import ArgumentParser
import Foundation
import FoundationModels
import OpenAppleModels
import Synchronization

/// `oam chat`: an interactive conversation with live tool calls.
struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Start an interactive chat session with tools.",
        discussion: """
            Responses stream as they are generated; tool calls and results are shown as they \
            happen. Command tools ("x-oam") run automatically; for external tools you are asked \
            to type the output (text, @file, or !error). Ctrl-C stops a response; Ctrl-D exits.

            COMMANDS
              /tools          list the tools
              /reset          clear the conversation
              /save <file>    save the conversation (resume with --resume)
              /usage          tokens used so far
              /exit           quit

            EXAMPLES
              oam chat --tools tools.json
              oam chat -i 'You are a terse assistant.' --resume chat.json
            """)

    @Option(name: [.short, .long], help: ArgumentHelp("Instructions (system prompt) for the model.", valueName: "text"))
    var instructions: String?

    @OptionGroup(title: "Tools")
    var toolFlags: ToolFlags

    @OptionGroup(title: "Sampling")
    var generation: GenerationFlags

    @Option(help: ArgumentHelp("Continue a saved conversation.", valueName: "file"))
    var resume: String?

    @Option(name: .customLong("save-transcript"), help: ArgumentHelp("Save the conversation to this file after every turn.", valueName: "file"))
    var saveTranscript: String?

    func run() async throws {
        let saved = try resume.map { path throws(CLIError) in try SavedConversation.load(path) }
        if saved?.pending != nil {
            throw CLIError.usage("\(resume ?? "") is waiting for tool outputs; finish it with 'oam respond --resume … --tool-output …' first.")
        }
        var toolSet = try toolFlags.loadTools()
        if toolSet == nil, let saved { toolSet = try RespondCommand.restoreTools(from: saved, source: resume ?? "") }
        let tools = toolSet ?? ToolSet()
        for warning in tools.warnings { Console.errLine(Style.yellow.apply("warning: ") + warning) }
        let policy = try toolFlags.policy(toolNames: tools.names)

        let model = try ModelProvider.makeModel()
        let agent: Agent
        do {
            agent = try Agent(
                model: model,
                instructions: instructions ?? saved?.savedInstructions,
                tools: try tools.agentTools(),
                configuration: generation.configuration(),
                history: saved?.transcript)
        } catch {
            throw CLIError(normalizing: error)
        }
        agent.prewarm()

        let active = Locked<TurnRunner?>(nil)
        let trap = SignalTrap([SIGINT]) { _ in
            if let runner = active.value {
                runner.cancel()
            } else {
                Console.errLine("")
                Foundation.exit(ExitStatus.interrupted)
            }
        }
        defer { trap.cancel() }

        printBanner(tools: tools, resumed: saved != nil, turns: saved.map { Self.turnCount($0.transcript) } ?? 0)
        let interactive = Console.stdinIsTerminal
        while true {
            if interactive { Console.out(Style.bold.apply("› ", on: .standardOutput)) }
            guard let line = await LineReader.readLine() else {
                if interactive { Console.outLine() }
                break
            }
            let input = line.trimmingCharacters(in: .whitespaces)
            if input.isEmpty { continue }
            if !interactive { Console.outLine(Style.bold.apply("› ", on: .standardOutput) + input) }
            if input.hasPrefix("/") {
                if try await handleCommand(input, agent: agent, tools: tools) { break }
                continue
            }
            let run = agent.run(input, policy: policy)
            let runner = TurnRunner(agent: agent, run: run, mode: .text(stream: true, showsTools: true), external: .ask)
            active.value = runner
            do {
                let outcome = try await runner.drive()
                if case .completed(let response) = outcome, response.text.isEmpty, response.structured == nil {
                    Console.outLine(Style.dim.apply("(empty response)", on: .standardOutput))
                }
            } catch {
                if error.code == AgentError.Code.cancelled.rawValue {
                    Console.errLine(Style.dim.apply("(stopped)"))
                } else {
                    Console.errLine(Style.red.apply("Error: ") + error.message + Self.hint(for: error))
                }
            }
            active.value = nil
            if let saveTranscript { try save(agent, tools: tools, to: saveTranscript, announce: false) }
        }
    }

    /// Handles a slash command. Returns true to quit.
    private func handleCommand(_ input: String, agent: Agent, tools: ToolSet) async throws -> Bool {
        let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch parts[0].lowercased() {
        case "/exit", "/quit", "/q":
            return true
        case "/help", "/?":
            Console.outLine("/tools  /reset  /save <file>  /usage  /exit")
        case "/tools":
            if tools.isEmpty { Console.outLine("No tools. Start with --tools <file>.") }
            for spec in tools.specs {
                let kind = spec.command.map { "runs " + $0.argv.map { ($0 as NSString).lastPathComponent }.joined(separator: " ") } ?? "external: you type the output"
                Console.outLine("  " + Style.cyan.apply(spec.name, on: .standardOutput) + "  " + Style.dim.apply(kind, on: .standardOutput))
                if !spec.description.isEmpty { Console.outLine("    " + spec.description) }
            }
        case "/reset":
            await agent.reset()
            Console.outLine(Style.dim.apply("Conversation cleared.", on: .standardOutput))
        case "/save":
            guard !argument.isEmpty else {
                Console.outLine("Usage: /save <file>")
                return false
            }
            do {
                try save(agent, tools: tools, to: argument, announce: true)
            } catch {
                Console.errLine(Style.red.apply("Error: ") + error.message)
            }
        case "/usage":
            let usage = agent.totalUsage
            Console.outLine("\(usage.inputTokens) input tokens (\(usage.cachedInputTokens) cached), \(usage.outputTokens) output tokens, "
                + "\(Self.turnCount(agent.transcript)) turns")
        default:
            Console.outLine("Unknown command \(parts[0]). Try /help.")
        }
        return false
    }

    private func save(_ agent: Agent, tools: ToolSet, to path: String, announce: Bool) throws(CLIError) {
        try SavedConversation(
            transcript: agent.transcript, modelName: ModelProvider.modelName,
            tools: tools.isEmpty ? nil : tools.definitions, schema: nil, pending: nil
        ).save(to: path)
        if announce { Console.outLine(Style.dim.apply("Saved to \(InputFiles.absolute(path)). Resume with: oam chat --resume \(path)", on: .standardOutput)) }
    }

    private func printBanner(tools: ToolSet, resumed: Bool, turns: Int) {
        var line = "oam chat · model: \(ModelProvider.modelName)"
        if !tools.isEmpty {
            line += " · tools: " + tools.specs.map { $0.isExternal ? "\($0.name) (external)" : $0.name }.joined(separator: ", ")
        }
        if resumed { line += " · resumed \(turns) turn\(turns == 1 ? "" : "s")" }
        Console.errLine(Style.dim.apply(line))
        Console.errLine(Style.dim.apply("/help for commands · Ctrl-C stops a response · Ctrl-D exits"))
    }

    static func turnCount(_ transcript: Transcript) -> Int {
        transcript.reduce(0) { count, entry in if case .prompt = entry { count + 1 } else { count } }
    }

    static func hint(for error: CLIError) -> String {
        switch error.exitCode {
        case ExitStatus.blocked: " (the guardrails blocked this turn; rephrase and try again)"
        case ExitStatus.contextExceeded: " (the conversation is too long; /save it and /reset)"
        default: ""
        }
    }
}
