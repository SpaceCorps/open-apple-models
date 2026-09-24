import Foundation
import OpenAppleModels

/// One tool from a tools file.
struct ToolSpec: Sendable {
    var name: String
    var description: String
    var parameters: JSONSchema
    /// Set for command-backed (local) tools; `nil` for external tools, whose
    /// output the caller supplies.
    var command: CommandSpec?

    var isExternal: Bool { command == nil }

    /// The definition in OpenAI function format, with the resolved `x-oam`
    /// block (absolute paths), as stored in saved transcripts.
    var definition: JSONValue {
        var function: JSONObject = ["name": .string(name)]
        if !description.isEmpty { function["description"] = .string(description) }
        function["parameters"] = parameters.json
        var tool: JSONObject = ["type": "function", "function": .object(function)]
        if let command {
            var options: JSONObject = ["command": .array(command.argv.map(JSONValue.string))]
            if let directory = command.workingDirectory { options["cwd"] = .string(directory) }
            let seconds = Double(command.timeout.components.seconds) + Double(command.timeout.components.attoseconds) / 1e18
            options["timeout"] = .number(seconds)
            if !command.environment.isEmpty {
                options["env"] = .object(JSONObject(command.environment.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))
            }
            if command.maxOutputCharacters != CommandSpec.defaultMaxOutputCharacters {
                options["maxOutputChars"] = .number(Double(command.maxOutputCharacters))
            }
            tool["x-oam"] = .object(options)
        }
        return .object(tool)
    }

    /// Creates the agent tool: command tools run locally, the rest are external.
    func agentTool() throws(CLIError) -> AgentTool {
        do {
            if let command {
                // The runner enforces the time limit (and stops the process);
                // the agent's limit is a backstop.
                return try AgentTool(
                    name: name, description: description, parameters: parameters,
                    timeout: command.timeout + .seconds(5)
                ) { call in
                    await CommandRunner.output(for: call, spec: command)
                }
            }
            return try AgentTool.external(name: name, description: description, parameters: parameters)
        } catch {
            throw .invalidInput("Tool '\(name)': \(error.description)")
        }
    }
}

/// The tools of one invocation, parsed from a tools file.
struct ToolSet: Sendable {
    var specs: [ToolSpec] = []
    /// Conversion and definition warnings, prefixed with the tool name.
    var warnings: [String] = []

    var isEmpty: Bool { specs.isEmpty }
    var names: [String] { specs.map(\.name) }
    var hasExternalTools: Bool { specs.contains(where: \.isExternal) }

    /// Definitions with resolved commands, for saving.
    var definitions: JSONValue { .array(specs.map(\.definition)) }

    func agentTools() throws(CLIError) -> [AgentTool] {
        var tools: [AgentTool] = []
        for spec in specs { tools.append(try spec.agentTool()) }
        return tools
    }
}

/// Parses tools files: OpenAI tool definitions (an array, or an object with a
/// `tools` array), each optionally extended with an `x-oam` block that turns
/// it into a command-backed local tool:
///
/// ```json
/// {"type": "function",
///  "function": {"name": "get_weather", "description": "…", "parameters": {…}},
///  "x-oam": {"command": ["./weather.sh", "--celsius"], "timeout": 10, "cwd": ".", "env": {"UNITS": "metric"}}}
/// ```
///
/// `command` may also be a string, run with `/bin/sh -c`. Relative program
/// paths (containing a `/`) and `cwd` are resolved against the tools file's
/// directory; bare program names are looked up in `PATH`. Tools without a
/// command are external: the caller supplies their output.
enum ToolFile {
    /// Loads and parses a tools file (`-` reads standard input).
    static func load(_ path: String) throws(CLIError) -> ToolSet {
        let value = try InputFiles.readJSON(path, what: "tools file")
        let base = path == "-"
            ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            : URL(fileURLWithPath: InputFiles.absolute(path)).deletingLastPathComponent()
        return try parse(value, baseDirectory: base, source: path)
    }

    /// Parses tool definitions.
    static func parse(_ value: JSONValue, baseDirectory: URL, source: String) throws(CLIError) -> ToolSet {
        let list: [JSONValue]
        if let array = value.arrayValue {
            list = array
        } else if let array = value["tools"]?.arrayValue {
            list = array
        } else {
            throw .invalidInput("\(source): expected an array of tool definitions or {\"tools\": [...]}.")
        }
        var set = ToolSet()
        var seen: Set<String> = []
        for (index, element) in list.enumerated() {
            let path = "\(source): tools[\(index)]"
            let spec = try parseTool(element, path: path, baseDirectory: baseDirectory, warnings: &set.warnings)
            guard seen.insert(spec.name).inserted else { throw .invalidInput("\(path): duplicate tool name '\(spec.name)'.") }
            set.specs.append(spec)
        }
        if set.specs.count > 5 {
            set.warnings.append("\(set.specs.count) tools defined; Apple recommends at most 3–5 per request for the on-device model.")
        }
        return set
    }

    private static func parseTool(_ element: JSONValue, path: String, baseDirectory: URL, warnings: inout [String]) throws(CLIError) -> ToolSpec {
        guard let object = element.objectValue else { throw .invalidInput("\(path) must be an object.") }
        var definition = object
        if let function = object["function"]?.objectValue {
            if let type = object["type"]?.stringValue, type != "function" {
                throw .invalidInput("\(path).type must be \"function\"; got '\(type)'.")
            }
            definition = function
        }
        guard let name = definition["name"]?.stringValue, isValidName(name) else {
            throw .invalidInput("\(path) needs a 'name' of 1–64 letters, digits, '_', '-' or '.'.")
        }
        let description = definition["description"]?.stringValue ?? ""
        if description.isEmpty { warnings.append("\(name): no description; the model may not know when to call it.") }
        var parameters = JSONSchema.empty
        if let raw = definition["parameters"], !raw.isNull {
            guard raw.objectValue != nil else { throw .invalidInput("\(path) (\(name)): 'parameters' must be a JSON Schema object.") }
            parameters = JSONSchema(SchemaInput.normalized(raw))
        }
        let options = object["x-oam"]?.objectValue ?? definition["x-oam"]?.objectValue
        var command: CommandSpec?
        if let options {
            command = try parseCommand(options, tool: name, path: "\(path).x-oam", baseDirectory: baseDirectory, warnings: &warnings)
        }
        let spec = ToolSpec(name: name, description: description, parameters: parameters, command: command)
        // Validate the schema now, so errors name the file.
        do {
            let converted = try SchemaConverter.convert(parameters, rootName: "Arguments")
            warnings.append(contentsOf: converted.warnings.map { "\(name): \($0)" })
        } catch {
            throw .invalidInput("\(path) (\(name)) parameters: \(error.description)")
        }
        return spec
    }

    private static func parseCommand(
        _ options: JSONObject, tool: String, path: String, baseDirectory: URL, warnings: inout [String]
    ) throws(CLIError) -> CommandSpec? {
        let known: Set<String> = ["command", "timeout", "cwd", "env", "maxOutputChars"]
        for key in options.keys where !known.contains(key) {
            warnings.append("\(tool): unknown x-oam option '\(key)' ignored (known: \(known.sorted().joined(separator: ", "))).")
        }
        guard let raw = options["command"], !raw.isNull else { return nil }
        var argv: [String]
        switch raw {
        case .string(let script):
            guard !script.trimmingCharacters(in: .whitespaces).isEmpty else { throw .invalidInput("\(path).command must not be empty.") }
            argv = ["/bin/sh", "-c", script]
        case .array(let parts):
            argv = []
            for part in parts {
                guard let text = part.stringValue else { throw .invalidInput("\(path).command must be an array of strings.") }
                argv.append(text)
            }
            guard let first = argv.first, !first.isEmpty else { throw .invalidInput("\(path).command must not be empty.") }
        default:
            throw .invalidInput("\(path).command must be an array of strings or a shell command string.")
        }
        argv[0] = try resolveProgram(argv[0], baseDirectory: baseDirectory, path: path)

        var directory: String?
        if let cwd = options["cwd"] {
            guard let text = cwd.stringValue else { throw .invalidInput("\(path).cwd must be a string.") }
            let resolved = InputFiles.absolute(text, relativeTo: baseDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw .invalidInput("\(path).cwd '\(text)' is not a directory (resolved to \(resolved)).")
            }
            directory = resolved
        }

        var timeout = CommandSpec.defaultTimeoutSeconds
        if let value = options["timeout"] {
            guard let seconds = value.doubleValue, seconds > 0 else { throw .invalidInput("\(path).timeout must be a positive number of seconds.") }
            timeout = seconds
        }

        var environment: [String: String] = [:]
        if let env = options["env"] {
            guard let object = env.objectValue else { throw .invalidInput("\(path).env must be an object of strings.") }
            for (key, value) in object {
                guard let text = value.stringValue ?? value.doubleValue.map({ _ in value.serialized() }) else {
                    throw .invalidInput("\(path).env.\(key) must be a string.")
                }
                environment[key] = text
            }
        }

        var maxOutput = CommandSpec.defaultMaxOutputCharacters
        if let value = options["maxOutputChars"] {
            guard let count = value.intValue, count > 0 else { throw .invalidInput("\(path).maxOutputChars must be a positive integer.") }
            maxOutput = count
        }
        return CommandSpec(
            argv: argv, workingDirectory: directory,
            timeout: .milliseconds(Int((timeout * 1000).rounded())),
            environment: environment, maxOutputCharacters: maxOutput)
    }

    /// Resolves a program to an absolute path: paths with a `/` against the
    /// tools file's directory, bare names through `PATH`.
    private static func resolveProgram(_ program: String, baseDirectory: URL, path: String) throws(CLIError) -> String {
        let manager = FileManager.default
        if program.contains("/") || program.hasPrefix("~") {
            let resolved = InputFiles.absolute(program, relativeTo: baseDirectory)
            guard manager.isExecutableFile(atPath: resolved) else {
                let exists = manager.fileExists(atPath: resolved)
                throw .invalidInput("\(path).command: '\(program)' " + (exists
                    ? "is not executable (resolved to \(resolved); try chmod +x)."
                    : "does not exist (resolved to \(resolved); relative paths are resolved against the tools file's directory)."))
            }
            return resolved
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = String(directory) + "/" + program
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw .invalidInput("\(path).command: program '\(program)' was not found in PATH.")
    }

    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || "_-.".unicodeScalars.contains(scalar)
        }
    }
}
