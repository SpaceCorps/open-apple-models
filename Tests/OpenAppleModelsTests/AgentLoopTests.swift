import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsTesting
import Synchronization
import Testing

final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

@Suite struct AgentLoopTests {
    static func inventoryTool(counter: Counter? = nil) throws -> AgentTool {
        try AgentTool(
            name: "check_inventory",
            description: "Look up stock and price of an item.",
            parameters: .object(["item": .string(description: "Item name")])
        ) { call in
            counter?.increment()
            let item = try call.string("item")
            return .json(["item": .string(item), "stock": 3, "price_gold": 45])
        }
    }

    @Test func localToolRoundTrip() async throws {
        let script = ModelScript([
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "iron sword"])]),
            .text("I have three iron swords at 45 gold each."),
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), instructions: "You are Gorm.", tools: [Self.inventoryTool()])
        let response = try await agent.respond(to: "Swords?")
        #expect(response.text == "I have three iron swords at 45 gold each.")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].call.arguments["item"] == "iron sword")
        #expect(response.toolCalls[0].output == .json(["item": "iron sword", "stock": 3, "price_gold": 45]))
        // The second model request saw the tool output.
        #expect(script.requests.count == 2)
        #expect(script.requests[1].toolOutputs.count == 1)
    }

    @Test func requiredChoiceAppliesToFirstStepOnly() async throws {
        let script = ModelScript([
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "shield"])]),
            .text("Shields in stock."),
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [Self.inventoryTool()])
        _ = try await agent.respond(to: "Shields?", policy: ToolPolicy(choice: .required))
        #expect(script.requests.map(\.toolCallingMode) == [.required, .allowed])
    }

    @Test func namedToolChoiceNarrowsFirstStep() async throws {
        let mood = try AgentTool(name: "get_mood", description: "Mood.") { _ in "grumpy" }
        let script = ModelScript([
            .toolCalls([.init(name: "get_mood")]),
            .text("Hmph."),
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [Self.inventoryTool(), mood])
        _ = try await agent.respond(to: "Hi", policy: ToolPolicy(choice: .tool("get_mood")))
        #expect(script.requests[0].enabledTools == ["get_mood"])
        #expect(script.requests[0].toolCallingMode == .required)
        #expect(Set(script.requests[1].enabledTools) == ["check_inventory", "get_mood"])
    }

    @Test func roundBudgetDisablesTools() async throws {
        let script = ModelScript([
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "a"])]),
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "b"])]),
            .text("done"),
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [Self.inventoryTool()])
        let response = try await agent.respond(to: "?", policy: ToolPolicy(maxToolRounds: 2))
        #expect(script.requests.map(\.toolCallingMode) == [.allowed, .allowed, .disallowed])
        #expect(response.toolCalls.count == 2)
        #expect(response.steps.count == 3)
    }

    @Test func callBudgetReturnsErrorOutput() async throws {
        let counter = Counter()
        let script = ModelScript([
            .toolCalls([
                .init(name: "check_inventory", arguments: ["item": "a"]),
                .init(name: "check_inventory", arguments: ["item": "b"]),
                .init(name: "check_inventory", arguments: ["item": "c"]),
            ]),
            .text("ok"),
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [Self.inventoryTool(counter: counter)])
        let response = try await agent.respond(to: "?", policy: ToolPolicy(maxToolCalls: 2))
        #expect(counter.count == 2)
        #expect(response.toolCalls.filter(\.output.isError).count == 1)
    }

    @Test func noneChoiceDisallowsTools() async throws {
        let script = ModelScript([.text("no tools")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [Self.inventoryTool()])
        _ = try await agent.respond(to: "?", policy: ToolPolicy(choice: .none))
        #expect(script.requests[0].toolCallingMode == .disallowed)
    }

    @Test func toolErrorsAreReportedToTheModel() async throws {
        let failing = try AgentTool(name: "open_door", description: "Open a door.",
                                    parameters: .object(["door": .string()])) { _ in
            throw ToolArgumentError(message: "The door is locked.")
        }
        let script = ModelScript([
            .toolCalls([.init(name: "open_door", arguments: ["door": "north"])]),
            .dynamic { request in .text("Saw: " + (request.toolOutputs.last.map { "\($0.segments)" } ?? "")) },
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [failing])
        let response = try await agent.respond(to: "Open it")
        #expect(response.toolCalls[0].output == ToolOutput.error("The door is locked."))
        #expect(response.text.contains("Error: The door is locked."))
    }

    @Test func toolTimeout() async throws {
        let slow = try AgentTool(name: "slow", description: "Slow.", timeout: .milliseconds(100)) { _ in
            try await Task.sleep(for: .seconds(5))
            return "late"
        }
        let script = ModelScript([.toolCalls([.init(name: "slow")]), .text("ok")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [slow])
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await agent.respond(to: "?")
        #expect(clock.now - start < .seconds(2))
        #expect(response.toolCalls[0].output.isError)
    }

    @Test func externalToolWaitsForHost() async throws {
        let door = try AgentTool.external(name: "open_door", description: "Open a door.",
                                          parameters: .object(["door": .string()]))
        let script = ModelScript([
            .toolCalls([.init(name: "open_door", arguments: ["door": "north"])]),
            .dynamic { request in .text("Result: \(request.toolOutputs.count)") },
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [door])
        let run = agent.run("Open the north door")
        var requested: [ToolCall] = []
        var final: AgentResponse?
        for try await event in run {
            switch event {
            case .toolCallRequested(let call):
                requested.append(call)
                #expect(run.pendingToolCalls.map(\.id) == [call.id])
                #expect(run.submit(.text("The door creaks open."), for: call.id))
                #expect(!run.submit(.text("again"), for: call.id))
            case .completed(let response):
                final = response
            default:
                break
            }
        }
        #expect(requested.count == 1)
        #expect(requested[0].arguments["door"] == "north")
        #expect(final?.toolCalls.first?.output == .text("The door creaks open."))
        #expect(final?.text == "Result: 1")
    }

    @Test func externalToolsViaResponseHandler() async throws {
        let dice = try AgentTool.external(name: "roll_dice", description: "Roll dice.",
                                          parameters: .object(["sides": .integer(minimum: 2, maximum: 100)]))
        let script = ModelScript([
            .toolCalls([.init(name: "roll_dice", arguments: ["sides": 20]), .init(name: "roll_dice", arguments: ["sides": 6])]),
            .text("Rolled."),
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [dice])
        let response = try await agent.respond(to: "Roll") { call in
            .json(["roll": .number(Double(try call.int("sides")))])
        }
        #expect(Set(response.toolCalls.map(\.output)) == [.json(["roll": 20]), .json(["roll": 6])])
    }

    @Test func streamingTextDeltas() async throws {
        let script = ModelScript([.text("Hello there, traveler.", chunks: 4)])
        let agent = try Agent(model: ScriptedLanguageModel(script))
        var deltas: [String] = []
        for try await event in agent.run("Hi") {
            if case .text(let delta, _, let reset) = event {
                #expect(!reset)
                deltas.append(delta)
            }
        }
        // Snapshots may coalesce, so the delta count varies; the text must not.
        #expect(!deltas.isEmpty)
        #expect(deltas.joined() == "Hello there, traveler.")
    }

    @Test func structuredOutputAfterTools() async throws {
        let schema = JSONSchema.object([
            "reasoning": .string(),
            "choice": .string(enum: ["attack", "flee", "trade"]),
        ])
        let script = ModelScript([
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "potion"])]),
            .json(["reasoning": "Low on potions.", "choice": "flee"]),
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [Self.inventoryTool()])
        let response = try await agent.respond(to: "Decide", schema: schema)
        #expect(response.structured?["choice"] == "flee")
        #expect(response.structured?.objectValue?.keys == ["reasoning", "choice"])
        #expect(script.requests.last?.schemaName == "Response")
    }

    @Test func turnsAreSerialized() async throws {
        let script = ModelScript([
            .delayed(.milliseconds(200), .text("first")),
            .text("second"),
        ])
        let agent = try Agent(model: ScriptedLanguageModel(script))
        async let a = agent.respond(to: "one")
        async let b = agent.respond(to: "two")
        let (first, second) = try await (a, b)
        // Which turn is queued first is unspecified; what matters is that they
        // never overlap (an overlapping request would fail with .busy).
        #expect(Set([first.text, second.text]) == ["first", "second"])
        let kinds = agent.history.map { entry -> String in
            switch entry {
            case .prompt: "prompt"
            case .response: "response"
            default: "other"
            }
        }
        #expect(kinds == ["prompt", "response", "prompt", "response"])
    }

    @Test func cancellation() async throws {
        let script = ModelScript([.delayed(.seconds(5), .text("too late"))])
        let agent = try Agent(model: ScriptedLanguageModel(script))
        let run = agent.run("wait")
        Task { try? await Task.sleep(for: .milliseconds(100)); run.cancel() }
        await #expect(throws: AgentError.self) { _ = try await run.response() }
        // The failed turn is rolled back.
        #expect(agent.history.isEmpty)
    }

    @Test func modelErrorsAreNormalized() async throws {
        let script = ModelScript([.fail(LanguageModelError.guardrailViolation(.init(debugDescription: "blocked")))])
        let agent = try Agent(model: ScriptedLanguageModel(script))
        do {
            _ = try await agent.respond(to: "x")
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .guardrailViolation)
        }
    }

    @Test func historyRestoresAcrossAgents() async throws {
        let script = ModelScript([.text("Name's Gorm."), .dynamic { request in .text("history=\(request.transcript.count)") }])
        let first = try Agent(model: ScriptedLanguageModel(script), instructions: "You are Gorm.")
        _ = try await first.respond(to: "Who are you?")
        let data = try JSONEncoder().encode(first.transcript)
        let restored = try Agent(model: ScriptedLanguageModel(script), instructions: "You are Gorm.",
                                 history: try JSONDecoder().decode(Transcript.self, from: data))
        let response = try await restored.respond(to: "Again?")
        // instructions + 2 prior entries + new prompt
        #expect(response.text == "history=4")
    }

    @Test func toolsCanChangeBetweenTurns() async throws {
        let script = ModelScript([.text("a"), .text("b")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [Self.inventoryTool()])
        _ = try await agent.respond(to: "1")
        try agent.setTools([try AgentTool(name: "wave", description: "Wave.") { _ in "waved" }])
        agent.instructions = "New persona."
        _ = try await agent.respond(to: "2")
        #expect(script.requests[0].enabledTools == ["check_inventory"])
        #expect(script.requests[1].enabledTools == ["wave"])
        #expect(agent.history.count == 4)
    }

    @Test func duplicateToolNamesAreRejected() throws {
        #expect(throws: AgentError.self) {
            _ = try Agent(tools: [try Self.inventoryTool(), try Self.inventoryTool()])
        }
    }
}

@Suite struct ToolChoiceCodingTests {
    @Test(arguments: [
        (ToolChoice.auto, #""auto""#), (.none, #""none""#), (.required, #""required""#), (.tool("open_gate"), #"{"tool":"open_gate"}"#),
    ])
    func roundTrips(_ choice: ToolChoice, _ json: String) throws {
        #expect(String(decoding: try JSONEncoder().encode(choice), as: UTF8.self) == json)
        #expect(try JSONDecoder().decode(ToolChoice.self, from: Data(json.utf8)) == choice)
    }

    @Test func acceptsOpenAIShape() throws {
        let json = #"{"type":"function","function":{"name":"roll_dice"}}"#
        #expect(try JSONDecoder().decode(ToolChoice.self, from: Data(json.utf8)) == .tool("roll_dice"))
    }

    @Test func immediateSubmitFromTheEventIsNeverLost() async throws {
        let tool = try AgentTool.external(name: "ping", description: "Ping.")
        for _ in 0..<50 {
            let script = ModelScript([.toolCalls([.init(name: "ping")]), .text("pong")])
            let agent = try Agent(model: ScriptedLanguageModel(script), tools: [tool])
            let run = agent.run("ping")
            for try await event in run {
                if case .toolCallRequested(let call) = event {
                    #expect(run.submit("ok", for: call.id))
                }
            }
        }
    }
}

@Suite struct ExplicitToolChoiceTests {
    static func menu() throws -> AgentTool {
        try AgentTool(name: "check_menu", description: "Menu.") { _ in .json([["item": "ale", "price_gold": 2]]) }
    }

    @Test func respondDirectlySkipsLookupsAndStaysInvisible() async throws {
        let script = ModelScript([.toolCalls([.init(name: AgentTool.respondDirectlyName)]), .text("Evening, traveler!")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [try Self.menu()])
        var events: [String] = []
        let run = agent.run("Hello!", policy: ToolPolicy(choice: .explicit))
        for try await event in run {
            switch event {
            case .toolCallStarted(let call), .toolCallRequested(let call): events.append(call.name)
            case .toolCallCompleted(let record): events.append(record.call.name)
            default: break
            }
        }
        let response = try await agent.respond(to: "again", policy: ToolPolicy(choice: .none))
        _ = response
        #expect(events.isEmpty)
        #expect(script.requests[0].toolCallingMode == .required)
        #expect(Set(script.requests[0].enabledTools) == ["check_menu", AgentTool.respondDirectlyName])
        #expect(script.requests[1].toolCallingMode == .disallowed)
        #expect(script.requests[1].enabledTools.isEmpty)
    }

    @Test func aRealToolCallThenAnswersNormally() async throws {
        let script = ModelScript([.toolCalls([.init(name: "check_menu")]), .text("Ale is 2 gold.")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [try Self.menu()])
        let response = try await agent.respond(to: "Menu?", policy: ToolPolicy(choice: .explicit))
        #expect(response.toolCalls.map(\.call.name) == ["check_menu"])
        #expect(script.requests[1].toolCallingMode == .allowed)
        #expect(script.requests[1].enabledTools == ["check_menu"])
        #expect(response.steps[0].enabledTools == ["check_menu"])
    }

    @Test func otherChoicesNeverSeeTheBuiltInTool() async throws {
        let script = ModelScript([.text("hi")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [try Self.menu()])
        _ = try await agent.respond(to: "hi")
        #expect(script.requests[0].enabledTools == ["check_menu"])
        let instructions = script.requests[0].transcript.first.map { "\($0)" } ?? ""
        #expect(!instructions.contains(AgentTool.respondDirectlyName))
    }

    @Test func reservedNameIsRejected() throws {
        #expect(throws: AgentError.self) {
            _ = try Agent(tools: [try AgentTool(name: AgentTool.respondDirectlyName, description: "x") { _ in "x" }])
        }
    }

    @Test func codes() throws {
        #expect(String(decoding: try JSONEncoder().encode(ToolChoice.explicit), as: UTF8.self) == #""explicit""#)
        #expect(try JSONDecoder().decode(ToolChoice.self, from: Data(#""explicit""#.utf8)) == .explicit)
    }
}
