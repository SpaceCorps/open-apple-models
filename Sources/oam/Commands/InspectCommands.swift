import ArgumentParser
import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsBridge

/// `oam available`: model availability as JSON.
struct AvailableCommand: AsyncParsableCommand, ReportsErrorsAsJSON {
    static let configuration = CommandConfiguration(
        commandName: "available",
        abstract: "Check model availability (JSON; exit code 3 when unavailable).",
        discussion: """
            Prints {"available", "reason"?, "model", "contextSize", "variant", "supportedLanguages"}. \
            reason is one of device_not_eligible, apple_intelligence_not_enabled, model_not_ready, unknown.
            """)

    @Flag(help: "Print compact single-line JSON.")
    var compact = false

    var reportsErrorsAsJSON: Bool { true }

    func run() async throws {
        let availability = ModelProvider.availability()
        var object: JSONObject = ["available": .bool(availability.available)]
        if let reason = availability.reason { object["reason"] = .string(reason) }
        object["model"] = .string(ModelProvider.modelName)
        for (key, value) in availability.json.objectValue ?? [:] where object[key] == nil {
            object[key] = value
        }
        Console.outJSON(.object(object), pretty: !compact)
        if !availability.available { throw ExitRequest(code: ExitStatus.modelUnavailable) }
    }
}

/// `oam schema …`.
struct SchemaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Inspect structured-output schemas.",
        subcommands: [SchemaConvertCommand.self])
}

/// `oam schema convert <file>`: JSON Schema → GenerationSchema.
struct SchemaConvertCommand: AsyncParsableCommand, ReportsErrorsAsJSON {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert a JSON Schema to the GenerationSchema the model sees, with warnings.",
        discussion: """
            Accepts plain JSON Schema and files from 'fm schema object'. Warnings name constraints \
            the model cannot enforce (they are described to the model instead). Exit code 2 when \
            the schema cannot be used.

            EXAMPLES
              oam schema convert person.json
              fm schema object --name Person --string name --integer age | oam schema convert -
            """)

    @Argument(help: "JSON Schema file ('-' for standard input).")
    var file: String

    @Option(help: ArgumentHelp("Root type name when the schema has no title.", valueName: "name"))
    var name = "Response"

    @Flag(help: "Print {\"warnings\": [...], \"generationSchema\": {...}} as one JSON object.")
    var json = false

    var reportsErrorsAsJSON: Bool { json }

    func run() async throws {
        let value = try SchemaInput.load(file)
        let converted: SchemaConverter.Result
        do {
            converted = try SchemaConverter.convert(JSONSchema(value), rootName: name)
        } catch {
            throw CLIError(code: AgentError.Code.invalidSchema.rawValue, message: "\(file): \(error.description)", exitCode: ExitStatus.usage)
        }
        let generation = BridgeCoding.json(converted.schema)
        if json {
            Console.outJSON([
                "warnings": .array(converted.warnings.map(JSONValue.string)),
                "generationSchema": generation,
            ], pretty: Console.stdoutIsTerminal)
            return
        }
        for warning in converted.warnings { Console.errLine(Style.yellow.apply("warning: ") + warning) }
        if converted.warnings.isEmpty { Console.errLine(Style.green.apply("✓ ") + "No warnings: every constraint is enforced.") }
        Console.outJSON(generation, pretty: true)
    }
}

/// `oam tools …`.
struct ToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "Inspect tools files.",
        subcommands: [ToolsValidateCommand.self])
}

/// `oam tools validate <file>`.
struct ToolsValidateCommand: AsyncParsableCommand, ReportsErrorsAsJSON {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a tools file: commands, schemas, and the GenerationSchema of each tool.",
        discussion: "Exit code 2 when the file is invalid (missing command, bad schema, duplicate names).")

    @Argument(help: "Tools file ('-' for standard input).")
    var file: String

    @Flag(help: "Print the result as JSON: {\"tools\": [{name, execution, command?, warnings, generationSchema}], \"warnings\"}.")
    var json = false

    var reportsErrorsAsJSON: Bool { json }

    func run() async throws {
        let set = try ToolFile.load(file)
        var entries: [JSONValue] = []
        for spec in set.specs {
            let tool = try spec.agentTool()
            var entry: JSONObject = [
                "name": .string(spec.name),
                "execution": spec.isExternal ? "external" : "command",
            ]
            if let command = spec.command {
                entry["command"] = .array(command.argv.map(JSONValue.string))
                if let directory = command.workingDirectory { entry["cwd"] = .string(directory) }
                entry["timeoutSeconds"] = .number(Double(command.timeout.components.seconds))
            }
            entry["warnings"] = .array(tool.schemaWarnings.map(JSONValue.string))
            entry["generationSchema"] = BridgeCoding.json(tool.generationSchema)
            entries.append(.object(entry))
        }
        if json {
            Console.outJSON(["tools": .array(entries), "warnings": .array(set.warnings.map(JSONValue.string))],
                            pretty: Console.stdoutIsTerminal)
            return
        }
        Console.outLine(Style.bold.apply("\(set.specs.count) tool\(set.specs.count == 1 ? "" : "s") in \(file)", on: .standardOutput))
        for spec in set.specs {
            let kind = spec.command.map { "command: " + $0.argv.map(Self.quoted).joined(separator: " ") } ?? "external (your program supplies the output)"
            Console.outLine("  " + Style.cyan.apply(spec.name, on: .standardOutput) + "  " + Style.dim.apply(kind, on: .standardOutput))
            if !spec.description.isEmpty { Console.outLine("    " + spec.description) }
            let properties = spec.parameters.json["properties"]?.objectValue?.keys ?? []
            Console.outLine("    arguments: " + (properties.isEmpty ? "(none)" : properties.joined(separator: ", ")))
        }
        for warning in set.warnings { Console.errLine(Style.yellow.apply("warning: ") + warning) }
        if set.warnings.isEmpty { Console.errLine(Style.green.apply("✓ ") + "Valid, no warnings.") }
    }

    private static func quoted(_ argument: String) -> String {
        argument.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" }) ? "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" : argument
    }
}
