import ArgumentParser
import Foundation
import OpenAppleModels
import OpenAppleModelsServer

/// `oam serve`: the OpenAI-compatible server with real tool calls.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run an OpenAI-compatible Chat Completions server that returns real tool_calls.",
        discussion: """
            Unlike 'fm serve', requests with "tools" get finish_reason "tool_calls" with the calls; \
            send the results back as "tool" messages (the standard OpenAI tool loop). tool_choice \
            "required" and {"type":"function","function":{"name":…}} work, as do json_schema \
            responses, streaming and images.

            ENDPOINTS
              POST /v1/chat/completions   GET /v1/models   GET /health

            EXAMPLES
              oam serve
              oam serve --port 0 --tools server-tools.json --model-alias gpt-4o-mini=system
              oam serve --socket /tmp/oam.sock
              OAM_API_KEY=secret oam serve --host 0.0.0.0
            """)

    @Option(help: ArgumentHelp("Address to bind (TCP). Keep 127.0.0.1 unless you also set --api-key.", valueName: "host"))
    var host = "127.0.0.1"

    @Option(help: ArgumentHelp("TCP port (0 picks a free one; default 1976, or none with --socket).", valueName: "port"))
    var port: Int?

    @Option(help: ArgumentHelp("Also (or, without --port, only) listen on this Unix domain socket.", valueName: "path"))
    var socket: String?

    @Option(help: ArgumentHelp(
        "Tools file with command tools the server runs itself (\"x-oam\" commands). The model may call them in any request; clients never see those calls.",
        valueName: "file"))
    var tools: String?

    @Option(name: [.short, .long], help: ArgumentHelp("Instructions prepended to every request's system message.", valueName: "text"))
    var instructions: String?

    @Option(name: .customLong("api-key"), help: ArgumentHelp("Require 'Authorization: Bearer <key>' (default: $OAM_API_KEY).", valueName: "key"))
    var apiKey: String?

    @Option(name: .customLong("allow-origin"), help: ArgumentHelp("Browser origin allowed to call the server, or '*' (repeatable).", valueName: "origin"))
    var allowOrigin: [String] = []

    @Option(name: .customLong("model-alias"), help: ArgumentHelp("Extra model id mapped to a served model, e.g. gpt-4o-mini=system (repeatable).", valueName: "alias=model"))
    var modelAlias: [String] = []

    @Option(name: .customLong("max-concurrent"), help: ArgumentHelp("Completions generated at once; others queue.", valueName: "n"))
    var maxConcurrent = 4

    @Option(help: ArgumentHelp("Time limit per completion in seconds, including queueing.", valueName: "seconds"))
    var timeout = 120.0

    @Option(name: .customLong("log-level"), help: ArgumentHelp("debug, info, warning or error (to standard error).", valueName: "level"))
    var logLevel = "info"

    func validate() throws {
        if let port, !(0...65535).contains(port) { throw ValidationError("--port must be between 0 and 65535.") }
        if maxConcurrent < 1 { throw ValidationError("--max-concurrent must be at least 1.") }
        if timeout <= 0 { throw ValidationError("--timeout must be positive.") }
        if Self.level(logLevel) == nil { throw ValidationError("--log-level must be debug, info, warning or error.") }
    }

    private static func level(_ name: String) -> ServerLogEntry.Level? {
        switch name.lowercased() {
        case "debug": .debug
        case "info": .info
        case "warning", "warn": .warning
        case "error": .error
        default: nil
        }
    }

    func run() async throws {
        let model = try ModelProvider.makeModel()
        var serverTools: [AgentTool] = []
        if let tools {
            let set = try ToolFile.load(tools)
            for spec in set.specs where spec.isExternal {
                throw CLIError.invalidInput("\(tools): server tool '\(spec.name)' has no \"x-oam\" command. "
                    + "Server tools run in the server; client tools arrive in each request's \"tools\".")
            }
            for warning in set.warnings { Console.errLine(Style.yellow.apply("warning: ") + warning) }
            serverTools = try set.agentTools()
        }
        var aliases: [String: String] = [:]
        for entry in modelAlias {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex, entry.index(after: equals) != entry.endIndex else {
                throw CLIError.usage("--model-alias expects alias=model; got '\(entry)'.")
            }
            aliases[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        for target in aliases.values where target != "system" {
            throw CLIError.usage("--model-alias: unknown model '\(target)'; the served model is 'system'.")
        }

        let minimum = Self.level(logLevel) ?? .info
        let key = apiKey ?? ProcessInfo.processInfo.environment["OAM_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        let configuration = ServerConfiguration(
            host: host,
            port: socket != nil && port == nil ? nil : (port ?? 1976),
            unixSocketPath: socket.map { InputFiles.absolute($0) },
            models: ["system": model],
            modelAliases: aliases,
            serverTools: serverTools,
            serverInstructions: instructions,
            apiKey: key,
            allowedOrigins: Set(allowOrigin),
            maxConcurrentRequests: maxConcurrent,
            requestTimeout: .milliseconds(Int(timeout * 1000)),
            logger: { entry in
                guard entry.level >= minimum else { return }
                Console.errLine(Style.dim.apply("[\(entry.level)] ") + entry.message)
            })

        let server = OpenAIServer(configuration: configuration)
        do {
            try await server.start()
        } catch {
            throw CLIError(code: "server_start_failed", message: error.message, exitCode: ExitStatus.failure)
        }
        let trap = SignalTrap { _ in server.stop() }
        defer { trap.cancel() }

        printBanner(port: server.port, apiKey: key, toolNames: serverTools.map(\.name))
        await server.waitUntilStopped()
    }

    private func printBanner(port: Int?, apiKey: String?, toolNames: [String]) {
        let modelName = ModelProvider.isScripted ? "system (scripted via \(ModelProvider.scriptVariable))" : "system"
        let hostPart = host.contains(":") ? "[\(host)]" : host
        var base: String?
        if let port {
            let url = "http://\(hostPart):\(port)"
            base = url
            Console.outLine("oam serve listening on \(url)/v1  (model: \(modelName))")
        }
        if let socket {
            Console.outLine("oam serve listening on unix:\(InputFiles.absolute(socket))  (model: \(modelName))")
        }
        if !toolNames.isEmpty { Console.outLine("server tools: " + toolNames.joined(separator: ", ")) }
        let curlTarget = base.map { "\($0)/v1/chat/completions" }
            ?? "--unix-socket \(InputFiles.absolute(socket ?? "")) http://localhost/v1/chat/completions"
        let auth = apiKey == nil ? "" : " \\\n    -H \"Authorization: Bearer $OAM_API_KEY\""
        Console.outLine("""

            Try it:
              curl \(curlTarget) \\
                -H 'Content-Type: application/json'\(auth) \\
                -d '{"model": "system", "tool_choice": "required",
                     "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
                     "tools": [{"type": "function", "function": {"name": "get_weather",
                       "description": "Current weather for a city",
                       "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]}'

            Any OpenAI SDK works: base_url=\(base.map { $0 + "/v1" } ?? "(unix socket)"), api_key=\(apiKey == nil ? "anything" : "$OAM_API_KEY"), model="system".
            Press Ctrl-C to stop.
            """)
    }
}
