import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsGame
import Testing

/// Runs against the real on-device model. Opt in with OAM_LIVE_TESTS=1.
/// Outputs vary run to run; assertions only check structure.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OAM_LIVE_TESTS"] == "1"), .serialized)
struct LiveGameTests {
    static let gorm = Persona(
        name: "Gorm",
        role: "the village blacksmith",
        personality: "Gruff and proud, but fair. Secretly soft-hearted.",
        speakingStyle: "Short, blunt sentences. Calls people 'lad' or 'lass'.",
        goals: ["Sell his weapons at a fair price"],
        secrets: ["He forged the blade that killed the old king"],
        defaultEmotion: .neutral,
        maxSentences: 2)

    static func inventory() throws -> AgentTool {
        let stock: [(name: String, count: Int, price: Int)] = [("iron sword", 3, 45), ("steel shield", 1, 80), ("dagger", 6, 12)]
        return try AgentTool(
            name: "check_inventory",
            description: "Look up whether the forge has an item in stock, how many, and its price in gold.",
            parameters: .object(["item": .string(description: "Item name, e.g. 'iron sword'")])
        ) { call in
            let query = try call.string("item").lowercased()
            guard let item = stock.first(where: { query.contains($0.name) || $0.name.contains(query) }) else {
                return .json(["item": .string(query), "in_stock": 0, "note": "Not sold here. Stock: iron sword, steel shield, dagger."])
            }
            return .json(["item": .string(item.name), "in_stock": .number(Double(item.count)), "price_gold": .number(Double(item.price))])
        }
    }

    static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(format: "%.2fs", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    static func show(_ label: String, _ turn: DialogueTurn, _ time: String) {
        print("[live] \(label) (\(time)) emotion=\(turn.emotion.rawValue) fallback=\(turn.isFallback) ends=\(turn.endsConversation) relationship=\(turn.relationship)")
        print("[live]   line: \(turn.line)")
        print("[live]   options: \(turn.playerOptions)")
        for record in turn.toolCalls {
            print("[live]   tool: \(record.call.name) \(record.call.arguments.serialized()) -> \(record.output.modelText)")
        }
        print("[live]   tokens: in=\(turn.usage.inputTokens) cached=\(turn.usage.cachedInputTokens) out=\(turn.usage.outputTokens)")
    }

    @Test func gormConversation() async throws {
        let world = WorldState(["player": ["name": "Aria", "gold": 60], "time_of_day": "evening", "weather": "rain"])
        let npc = try NPC(
            persona: Self.gorm,
            tools: [try Self.inventory()],
            world: world,
            options: NPCOptions(
                groundingTool: "check_inventory",
                worldContextPaths: ["player.name", "player.gold", "time_of_day"],
                memoryTools: .changeRelationship))
        npc.prewarm()

        // Turn 1, streamed: forced inventory lookup.
        var start = ContinuousClock.now
        var firstEmotion: String?
        var firstDelta: String?
        var deltas = 0
        var turn: DialogueTurn?
        for try await event in npc.talkStream("Evening! Got any iron swords? How much?") {
            switch event {
            case .emotion: if firstEmotion == nil { firstEmotion = Self.seconds(since: start) }
            case .lineDelta:
                deltas += 1
                if firstDelta == nil { firstDelta = Self.seconds(since: start) }
            case .completed(let completed): turn = completed
            default: break
            }
        }
        let first = try #require(turn)
        Self.show("turn 1 (streamed; emotion at \(firstEmotion ?? "-"), first delta at \(firstDelta ?? "-"), \(deltas) deltas)", first, Self.seconds(since: start))
        #expect(!first.line.isEmpty)
        #expect(first.toolCalls.contains { $0.call.name == "check_inventory" })

        // Turn 2: grounded again (shield price).
        start = ContinuousClock.now
        let second = try await npc.talk("Can I afford a steel shield as well?")
        Self.show("turn 2", second, Self.seconds(since: start))
        #expect(!second.line.isEmpty)

        // Turn 3: free choice of tools; a friendly goodbye.
        start = ContinuousClock.now
        let third = try await npc.talk("Just the sword then. Thank you, Gorm, your work is the finest in the land. Farewell!", toolChoice: .auto)
        Self.show("turn 3 (auto)", third, Self.seconds(since: start))
        #expect(!third.line.isEmpty)
        print("[live] memory: \(npc.memory)")
    }

    @Test func goblinDecision() async throws {
        let engine = DecisionEngine()
        let start = ContinuousClock.now
        let decision = try await engine.decide(
            situation: "You are cornered in a cave. The armored knight in front of you has full health; you have 3 of 20 HP.",
            options: [
                DecisionOption(id: "attack", description: "Stab the knight with your rusty dagger"),
                DecisionOption(id: "flee", description: "Squeeze through the narrow crack behind you"),
                DecisionOption(id: "beg", description: "Drop the dagger and beg for mercy"),
            ],
            actor: Persona(name: "Snik", role: "a cowardly goblin", personality: "Greedy, timid and sly", goals: ["Survive at any cost"]),
            context: ["goblin_hp": 3, "knight_hp": 60, "escape_route": true])
        print("[live] decision (\(Self.seconds(since: start))): \(decision.optionID) confidence=\(decision.confidence) reasoning=\(decision.reasoning)")
        #expect(["attack", "flee", "beg"].contains(decision.optionID))
    }

    @Test func gormBark() async throws {
        let npc = try NPC(persona: Self.gorm)
        let start = ContinuousClock.now
        let bark = try await npc.bark(situation: "A customer walks past the forge in the rain without stopping.")
        print("[live] bark (\(Self.seconds(since: start))): \(bark)")
        #expect(!bark.isEmpty)
    }

    @Test func lootGeneration() async throws {
        let start = ContinuousClock.now
        let item = try await ContentGenerator().generate(
            "A cursed sword found in a drowned temple.",
            schema: .object([
                "name": .string(description: "Two or three words"),
                "description": .string(description: "One sentence of flavor text"),
                "rarity": .string(enum: ["common", "rare", "legendary"]),
                "damage": .integer(minimum: 1, maximum: 50),
            ]))
        print("[live] item (\(Self.seconds(since: start))): \(item.serialized())")
        #expect(item.objectValue?.keys == ["name", "description", "rarity", "damage"])
    }

    /// How often typical (violent-themed) game lines trip the guardrails.
    @Test func guardrailSurvey() async throws {
        let lines = [
            "Can you sharpen my sword? I need to slay the dragon tomorrow.",
            "The bandits killed my brother. I want revenge.",
            "How do I kill the goblin chief?",
            "Your mother was a goblin.",
            "Sell me some poison for the rats.",
            "What's the best weapon against skeletons?",
        ]
        var blocked = 0
        for line in lines {
            let npc = try NPC(persona: Self.gorm, options: NPCOptions(playerOptionCount: 0))
            let start = ContinuousClock.now
            let turn = try await npc.talk(line)
            if turn.isFallback { blocked += 1 }
            print("[live] guardrail \(turn.isFallback ? "BLOCKED" : "ok") (\(Self.seconds(since: start))) \(line) -> \(turn.line)")
        }
        print("[live] guardrail survey: \(blocked)/\(lines.count) blocked")
    }

    /// Plain-text replies with permissive guardrails (which only apply to
    /// plain-text generation) and a forced inventory lookup.
    @Test func textRepliesWithPermissiveGuardrails() async throws {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        var blocked = 0
        for line in ["Got any iron swords? How much?", "Can you sharpen my sword? I need to slay the dragon tomorrow.", "How do I kill the goblin chief?"] {
            let npc = try NPC(
                persona: Self.gorm, model: model, tools: [try Self.inventory()],
                options: NPCOptions(groundingTool: "check_inventory", replyFormat: .text))
            let start = ContinuousClock.now
            let turn = try await npc.talk(line)
            if turn.isFallback { blocked += 1 }
            Self.show("text+permissive: \(line)", turn, Self.seconds(since: start))
        }
        print("[live] text+permissive: \(blocked)/3 blocked")
    }

    /// A lean structured configuration: few emotions, no suggested replies.
    @Test func leanStructuredTurn() async throws {
        let npc = try NPC(
            persona: Self.gorm, tools: [try Self.inventory()],
            options: NPCOptions(
                groundingTool: "check_inventory", emotions: [.neutral, .happy, .annoyed, .angry, .suspicious],
                playerOptionCount: 0, canEndConversation: false))
        let start = ContinuousClock.now
        let turn = try await npc.talk("Got any steel shields? How much?")
        Self.show("lean structured", turn, Self.seconds(since: start))
    }

    @Test func threateningPlayerLine() async throws {
        let npc = try NPC(persona: Self.gorm, options: NPCOptions(playerOptionCount: 2))
        let start = ContinuousClock.now
        let turn = try await npc.talk("Hand over your gold or I'll run you through with your own sword, old man!")
        Self.show("threat", turn, Self.seconds(since: start))
        #expect(!turn.line.isEmpty)
    }
}
