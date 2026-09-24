import ArgumentParser
import Foundation
import OpenAppleModels
import OpenAppleModelsBridge

/// The `oam` command: Apple's on-device Foundation Models with real tool calls.
struct OAM: AsyncParsableCommand {
    static let version = BridgeVersion.library

    static let configuration = CommandConfiguration(
        commandName: "oam",
        abstract: "Apple's on-device Foundation Models, with real tool calls.",
        discussion: """
            Like Apple's 'fm', plus tools: shell commands as tools, external tools answered by \
            your program, an OpenAI-compatible server that returns tool_calls, and a JSON-RPC \
            bridge for game engines.

            EXAMPLES
              oam respond --tools tools.json 'What is the weather in Paris?'
              oam chat --tools tools.json
              oam serve --port 1976
              oam demo tavern
              oam agent-readme

            Set OAM_SCRIPT=<steps.json> to replace the model with a deterministic script (for tests).
            """,
        version: version,
        subcommands: [
            RespondCommand.self,
            ChatCommand.self,
            ServeCommand.self,
            StdioCommand.self,
            SchemaCommand.self,
            ToolsCommand.self,
            AvailableCommand.self,
            DemoCommand.self,
            AgentReadmeCommand.self,
        ])

    /// Parses the command line, runs the command and exits with the
    /// documented exit codes (see ``ExitStatus``).
    static func runMain() async -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var reportsJSON = arguments.contains("--json") || arguments.contains("--events")
        var reportsEvents = false
        do {
            var command = try await asyncParseAsRoot(arguments)
            if let reporting = command as? ReportsErrorsAsJSON {
                reportsJSON = reporting.reportsErrorsAsJSON
                reportsEvents = reporting.reportsErrorsAsEvents
            }
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            Foundation.exit(ExitStatus.success)
        } catch let request as ExitRequest {
            Foundation.exit(request.code)
        } catch let error as CLIError {
            report(error, asJSON: reportsJSON, asEvent: reportsEvents)
        } catch let error as AgentError {
            report(CLIError(error), asJSON: reportsJSON, asEvent: reportsEvents)
        } catch let error as BridgeError {
            report(CLIError(normalizing: error), asJSON: reportsJSON, asEvent: reportsEvents)
        } catch {
            // Argument parsing: help, version, and usage errors.
            let code = exitCode(for: error)
            if code == .success {
                Console.outLine(fullMessage(for: error))
                Foundation.exit(ExitStatus.success)
            }
            if error is ExitCode { Foundation.exit(code.rawValue) }
            if reportsJSON {
                Console.errJSON(["error": ["code": "usage", "message": .string(message(for: error))]])
            } else {
                Console.errLine(fullMessage(for: error))
            }
            Foundation.exit(code == .validationFailure ? ExitStatus.usage : code.rawValue)
        }
    }

    private static func report(_ error: CLIError, asJSON: Bool, asEvent: Bool) -> Never {
        error.report(asJSON: asJSON, asEvent: asEvent)
        Foundation.exit(error.exitCode)
    }
}
