import ArgumentParser
import Foundation
import FoundationModels
import OpenAppleModels

/// Sampling flags shared by `respond` and `chat`.
struct GenerationFlags: ParsableArguments {
    @Option(help: ArgumentHelp("Sampling temperature (0 = most deterministic, 2 = most varied).", valueName: "t"))
    var temperature: Double?

    @Option(name: .customLong("max-tokens"), help: ArgumentHelp("Maximum tokens per model response step.", valueName: "n"))
    var maxTokens: Int?

    @Flag(name: [.short, .long], help: "Use greedy sampling (deterministic output).")
    var greedy = false

    func validate() throws {
        if let temperature, !(0...2).contains(temperature) {
            throw ValidationError("--temperature must be between 0 and 2.")
        }
        if let maxTokens, maxTokens < 1 {
            throw ValidationError("--max-tokens must be at least 1.")
        }
    }

    /// Agent configuration with these sampling settings.
    func configuration() -> AgentConfiguration {
        AgentConfiguration(
            temperature: temperature,
            maximumResponseTokens: maxTokens,
            sampling: greedy ? .greedy : nil)
    }
}

/// Tool flags shared by `respond` and `chat`.
struct ToolFlags: ParsableArguments {
    @Option(help: ArgumentHelp(
        "Tools file: OpenAI tool definitions (array or {\"tools\": [...]}). Tools with an \"x-oam\" command run locally; the rest are external.",
        valueName: "file"))
    var tools: String?

    @Option(name: .customLong("tool-choice"), help: ArgumentHelp(
        "auto, none, required, explicit, or a tool name. required/<name> force a tool call on the first step only; explicit makes the model either call a tool or state it needs none.",
        valueName: "choice"))
    var toolChoice: String?

    @Option(name: .customLong("max-tool-rounds"), help: ArgumentHelp("Maximum model steps that may call tools (default 4).", valueName: "n"))
    var maxToolRounds: Int?

    @Option(name: .customLong("max-tool-calls"), help: ArgumentHelp("Maximum tool calls per turn (default 12).", valueName: "n"))
    var maxToolCalls: Int?

    func validate() throws {
        if let maxToolRounds, maxToolRounds < 0 { throw ValidationError("--max-tool-rounds must be 0 or more.") }
        if let maxToolCalls, maxToolCalls < 0 { throw ValidationError("--max-tool-calls must be 0 or more.") }
    }

    @Option(name: .customLong("tool-json"), help: ArgumentHelp(
        "An inline tool definition as JSON (OpenAI format or {\"name\", \"description\", \"parameters\"}), repeatable; combined with --tools. Tools without an x-oam command are external.",
        valueName: "json"))
    var toolJSON: [String] = []

    /// Loads the tools file and inline `--tool-json` definitions, if any.
    func loadTools() throws(CLIError) -> ToolSet? {
        var set: ToolSet?
        if let tools { set = try ToolFile.load(tools) }
        guard !toolJSON.isEmpty else { return set }
        var values: [JSONValue] = []
        for (index, text) in toolJSON.enumerated() {
            let value: JSONValue
            do {
                value = try JSONValue(parsing: text)
            } catch {
                throw .invalidInput("--tool-json #\(index + 1): \(error.description)")
            }
            if let array = value.arrayValue { values.append(contentsOf: array) } else { values.append(value) }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let inline = try ToolFile.parse(.array(values), baseDirectory: cwd, source: "--tool-json")
        guard var merged = set else { return inline }
        for spec in inline.specs {
            guard !merged.names.contains(spec.name) else {
                throw .invalidInput("--tool-json: tool '\(spec.name)' is also defined in \(tools ?? "the tools file").")
            }
            merged.specs.append(spec)
        }
        merged.warnings.append(contentsOf: inline.warnings)
        return merged
    }

    /// The parsed `--tool-choice`, validated against the available tools.
    func choice(toolNames: [String]) throws(CLIError) -> ToolChoice? {
        guard let toolChoice else { return nil }
        switch toolChoice {
        case "auto": return .auto
        case "none": return ToolChoice.none
        case "explicit":
            return .explicit
        case "required", "any":
            guard !toolNames.isEmpty else { throw .usage("--tool-choice required needs tools (--tools).") }
            return .required
        default:
            guard toolNames.contains(toolChoice) else {
                let known = toolNames.isEmpty ? "no tools are defined" : "tools: " + toolNames.joined(separator: ", ")
                throw .usage("--tool-choice '\(toolChoice)' is not auto, none, required, explicit or a tool name (\(known)).")
            }
            return .tool(toolChoice)
        }
    }

    /// The tool policy for a turn.
    func policy(toolNames: [String], defaultChoice: ToolChoice = .auto) throws(CLIError) -> ToolPolicy {
        var policy = ToolPolicy()
        policy.choice = try choice(toolNames: toolNames) ?? defaultChoice
        if let maxToolRounds { policy.maxToolRounds = maxToolRounds }
        if let maxToolCalls { policy.maxToolCalls = maxToolCalls }
        return policy
    }
}

extension ToolChoice {
    /// The `--tool-choice` spelling.
    var flagValue: String {
        switch self {
        case .auto: "auto"
        case .none: "none"
        case .required: "required"
        case .explicit: "explicit"
        case .tool(let name): name
        }
    }
}
