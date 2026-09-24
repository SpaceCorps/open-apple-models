import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import OpenAppleModelsTesting
import Synchronization
import Testing

/// An example extension, shaped like the NPC methods a game layer adds:
/// its own object store, its own event method, the shared turn driver.
final class EchoExtension: BridgeExtension {
    private let agents = Mutex<[String: Agent]>([:])
    let shutDown = Mutex(false)

    func register(in registry: inout BridgeMethodRegistry, engine: BridgeEngine) {
        registry.register("echo/create") { [self] request in
            let id = try request.params.string("npc")
            let spec = try BridgeCoding.modelSpec(request.params["model"])
            let tools = try request.params["tools"].map { value throws(BridgeError) in
                try BridgeCoding.tools(from: value, defaultTimeout: .seconds(5)).tools
            } ?? []
            let agent = try Agent(model: request.engine.makeModel(spec), tools: tools)
            agents.withLock { $0[id] = agent }
            return .result(["npc": .string(id)])
        }
        registry.register("echo/say") { [self] request in
            let id = try request.params.string("npc")
            guard let agent = agents.withLock({ $0[id] }) else {
                throw BridgeError(code: -32050, name: "npc_not_found", message: "No NPC '\(id)'.")
            }
            let text = try request.params.string("text")
            let run = agent.run(text)  // queued in order, before the next message is handled
            return .deferred {
                let response = try await request.drive(run, stream: true, context: ["npc": .string(id)], eventMethod: "echo/event")
                var result: JSONObject = ["npc": .string(id)]
                for (key, value) in BridgeCoding.json(response) { result[key] = value }
                return .object(result)
            }
        }
        // Extensions may replace built-ins.
        registry.register("ping") { _ in .result(["pong": true]) }
    }

    var notificationMethods: [String] { ["echo/event"] }

    func shutdown() async {
        shutDown.withLock { $0 = true }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ExtensionTests {
    @Test func extensionMethodsUseTheSharedDriver() async throws {
        let echo = EchoExtension()
        let harness = BridgeHarness { $0.extensions = [echo] }
        harness.box.setResponder { _, params in
            #expect(params["npc"] == "gorm")
            return ["output": "3 swords"]
        }
        _ = try await harness.result("echo/create", [
            "npc": "gorm",
            "model": ["type": "scripted", "steps": [
                ["toolCalls": [["name": "stock", "arguments": [:]]]],
                ["template": "I have {toolOutput}."],
            ]],
            "tools": [["name": "stock", "description": "Check stock."]],
        ])
        let request = harness.send("echo/say", ["npc": "gorm", "text": "Swords?"])
        let result = try #require(try await harness.response(to: request)["result"])
        #expect(result["npc"] == "gorm")
        #expect(result["text"] == "I have 3 swords.")
        let events = harness.box.messages.filter { $0["method"] == "echo/event" }
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0["params"]?["npc"] == "gorm" && $0["params"]?["requestId"] == .string(request) })

        let initialize = try await harness.result("initialize")
        let methods = initialize["capabilities"]?["methods"]?.arrayValue ?? []
        #expect(methods.contains("echo/say"))
        #expect(initialize["capabilities"]?["notifications"] == ["session/event", "tool/cancel", "echo/event"])
        #expect(try await harness.result("ping") == ["pong": true])

        let custom = try await harness.call("echo/say", ["npc": "nobody", "text": "hi"])
        #expect(custom.errorCode == -32050)
        #expect(custom.errorName == "npc_not_found")

        _ = try await harness.result("shutdown")
        #expect(echo.shutDown.withLock { $0 })
    }

    @Test func runtimeRegistration() async throws {
        let harness = BridgeHarness()
        harness.engine.register("world/time") { request in
            .result(["hour": .number(Double((try request.params.optionalInt("offset") ?? 0) + 12))])
        }
        #expect(try await harness.result("world/time") == ["hour": 12])
        #expect(try await harness.result("world/time", ["offset": 3]) == ["hour": 15])
        #expect(harness.engine.methods.contains("world/time"))
    }
}
