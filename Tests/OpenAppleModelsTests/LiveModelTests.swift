import Foundation
import FoundationModels
import OpenAppleModels
import Testing

/// Runs against the real on-device model. Opt in with OAM_LIVE_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OAM_LIVE_TESTS"] == "1"), .serialized)
struct LiveModelTests {
    static let gorm = "You are Gorm, a grumpy blacksmith in a fantasy game. Reply in at most two sentences."

    static func inventory() throws -> AgentTool {
        try AgentTool(
            name: "check_inventory",
            description: "Look up how many of an item the blacksmith has and its price in gold.",
            parameters: .object(["item": .string(description: "Item name")])
        ) { call in
            .json(["item": .string(try call.string("item")), "stock": 3, "price_gold": 45])
        }
    }

    @Test func requiredFirstStepGroundsTheAnswer() async throws {
        let agent = try Agent(instructions: Self.gorm, tools: [try Self.inventory()])
        let response = try await agent.respond(to: "Got any iron swords? How much?", policy: ToolPolicy(choice: .required))
        print("[live] required:", response.text, response.steps.map(\.toolCallingMode))
        #expect(response.toolCalls.count >= 1)
        #expect(response.text.contains("45"))
    }

    @Test func noneChoiceStillAnswers() async throws {
        let agent = try Agent(instructions: Self.gorm, tools: [try Self.inventory()])
        let response = try await agent.respond(to: "How are you today?", policy: ToolPolicy(choice: .none))
        print("[live] none:", response.text)
        #expect(response.toolCalls.isEmpty)
        #expect(!response.text.isEmpty)
    }

    @Test func externalToolRoundTrip() async throws {
        let open = try AgentTool.external(
            name: "open_gate",
            description: "Ask the game engine to open a named gate. Returns whether it opened.",
            parameters: .object(["gate": .string(description: "Gate name")]))
        let agent = try Agent(instructions: "You are a castle guard in a game. Use tools to act. Reply in one sentence.", tools: [open])
        let response = try await agent.respond(
            to: "Please open the north gate for me.", policy: ToolPolicy(choice: .required)
        ) { call in
            #expect(call.name == "open_gate")
            return .json(["opened": false, "reason": "the portcullis chain is jammed"])
        }
        print("[live] external:", response.text)
        #expect(response.toolCalls.count >= 1)
    }

    @Test func structuredDecisionAfterTool() async throws {
        let agent = try Agent(instructions: Self.gorm, tools: [try Self.inventory()])
        let schema = JSONSchema.object([
            "reasoning": .string(description: "One short sentence"),
            "choice": .string(enum: ["sell", "refuse", "haggle"]),
        ])
        let response = try await agent.respond(
            to: "A customer offers 30 gold for an iron sword. Check stock, then decide.",
            schema: schema, policy: ToolPolicy(choice: .tool("check_inventory")))
        print("[live] decision:", response.text)
        #expect(["sell", "refuse", "haggle"].contains(response.structured?["choice"]?.stringValue ?? ""))
        #expect(response.structured?.objectValue?.keys == ["reasoning", "choice"])
    }
}
