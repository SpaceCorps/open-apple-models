import ArgumentParser
import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsBridge
import OpenAppleModelsTesting
import Synchronization

/// `oam stdio`: the JSON-RPC bridge over standard input and output.
struct StdioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stdio",
        abstract: "Serve the JSON-RPC 2.0 bridge protocol over stdin/stdout (one message per line).",
        discussion: """
            For game engines and other languages: spawn 'oam stdio', write requests as single-line \
            JSON, read responses, session/event notifications and tool/call requests from stdout. \
            Standard output carries only protocol messages; logs go to standard error. See \
            docs/PROTOCOL.md for the methods (initialize, session/create, session/respond, …).

            EXAMPLE
              printf '%s\\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | oam stdio
            """)

    @Option(name: .customLong("log-level"), help: ArgumentHelp("debug, info, warning or error (to standard error).", valueName: "level"))
    var logLevel = "warning"

    @Option(name: .customLong("max-sessions"), help: ArgumentHelp("Maximum live sessions.", valueName: "n"))
    var maxSessions = 64

    @Option(name: .customLong("tool-timeout"), help: ArgumentHelp("Seconds to wait for a tool/call answer (0 = forever).", valueName: "seconds"))
    var toolTimeout = 120.0

    @Flag(name: .customLong("no-scripted-models"), help: "Reject sessions that ask for a scripted model.")
    var noScriptedModels = false

    func validate() throws {
        if BridgeLogLevel(rawValue: logLevel.lowercased()) == nil { throw ValidationError("--log-level must be debug, info, warning or error.") }
        if maxSessions < 1 { throw ValidationError("--max-sessions must be at least 1.") }
        if toolTimeout < 0 { throw ValidationError("--tool-timeout must be 0 or more.") }
    }

    func run() async throws {
        let minimum = BridgeLogLevel(rawValue: logLevel.lowercased()) ?? .warning
        var configuration = BridgeConfiguration(
            maxSessions: maxSessions,
            allowsScriptedModels: !noScriptedModels,
            defaultToolTimeout: toolTimeout == 0 ? nil : .milliseconds(Int(toolTimeout * 1000)),
            logger: { level, message in
                guard level >= minimum else { return }
                Console.errLine("[oam stdio] \(level.rawValue): \(message)")
            },
            onShutdown: { Foundation.exit(ExitStatus.success) })
        if ModelProvider.isScripted {
            // Validate the steps file now, then give every "system" session its own copy.
            _ = try ModelProvider.loadScript()
            configuration.modelFactory = { (spec: BridgeModelSpec) throws -> any LanguageModel in
                if case .system = spec, let script = try ModelProvider.loadScript() {
                    return ScriptedLanguageModel(script)
                }
                return try BridgeConfiguration.defaultModelFactory(spec)
            }
            configuration.modelAvailability = { ModelProvider.availability() }
        }

        let outstanding = OutstandingRequests()
        let engine = BridgeEngine(configuration: configuration) { line in
            outstanding.noteOutgoing(line)
            Console.write(line + "\n", to: .standardOutput)
        }
        // One reader thread feeds the engine; receive() returns immediately.
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                while let line = Swift.readLine(strippingNewline: true) {
                    outstanding.noteIncoming(line)
                    engine.receive(line)
                }
                finished.resume()
            }
        }
        // End of input: let requests already sent finish (a client may pipe
        // a whole script and close stdin), then shut down.
        while !outstanding.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await engine.shutdown()
        await engine.flush()
    }
}

/// Tracks client requests that have not been answered yet.
private final class OutstandingRequests: Sendable {
    private let ids = Mutex<Set<String>>([])

    var isEmpty: Bool { ids.withLock { $0.isEmpty } }

    func noteIncoming(_ line: String) {
        guard let message = try? JSONValue(parsing: line), message["method"]?.stringValue != nil,
              let id = message["id"], !id.isNull else { return }
        ids.withLock { _ = $0.insert(id.serialized()) }
    }

    func noteOutgoing(_ line: String) {
        // Responses carry an id and no method; requests to the client carry both.
        guard line.contains("\"id\""), let message = try? JSONValue(parsing: line),
              message["method"] == nil, let id = message["id"], !id.isNull else { return }
        ids.withLock { _ = $0.remove(id.serialized()) }
    }
}
