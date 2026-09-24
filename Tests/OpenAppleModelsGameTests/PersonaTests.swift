import Foundation
import OpenAppleModels
@testable import OpenAppleModelsGame
import Testing

@Suite struct PersonaTests {
    @Test func instructionsCoverCharacterAndRules() {
        let text = Fixtures.gorm.instructions()
        #expect(text.hasPrefix("You play Gorm, the village blacksmith, a character in a video game."))
        #expect(text.contains("Personality: Gruff and proud, but fair."))
        #expect(text.contains("Speaking style: Short, blunt sentences. Calls people 'lad'."))
        #expect(text.contains("Goals: Sell his weapons at a fair price."))
        #expect(text.contains("You know: The mine to the north is haunted."))
        #expect(text.contains("Your secret: He forged the blade that killed the old king."))
        #expect(text.contains("Never say you are an AI"))
        #expect(text.contains("at most 2 short sentences"))
        #expect(text.contains("Use your tools to check facts"))
        #expect(text.contains("Keep your secret unless the player has truly earned your trust."))
    }

    @Test func instructionsStayCompact() {
        // ~4 characters per token: a full persona stays well under 250 tokens.
        let text = Fixtures.gorm.instructions(extra: "The town is under siege.")
        #expect(text.count < 1000, "\(text.count) characters")
        let minimal = Persona(name: "Guard").instructions()
        #expect(minimal.count < 400, "\(minimal.count) characters")
        #expect(!minimal.contains("Personality:"))
        #expect(!minimal.contains("secret"))
    }

    @Test func instructionVariants() {
        var persona = Fixtures.gorm
        persona.maxSentences = 1
        let noTools = persona.instructions(usesTools: false)
        #expect(noTools.contains("at most 1 short sentence."))
        #expect(noTools.contains("say so in character. Never invent it."))
        #expect(!noTools.contains("Use your tools"))

        let hidden = persona.instructions(secrets: .hidden)
        #expect(!hidden.contains("killed the old king"))
        #expect(!hidden.contains("secret"))
        let shareable = persona.instructions(secrets: .shareable)
        #expect(shareable.contains("killed the old king"))
        #expect(shareable.contains("You may share your secret if asked."))

        #expect(persona.instructions(extra: "Setting: a frozen port.").hasSuffix("Setting: a frozen port."))
    }

    @Test func personaDecodesWithDefaults() throws {
        let persona = try JSONDecoder().decode(Persona.self, from: Data(#"{"name":"Mira","secrets":["Owes the guild"],"defaultEmotion":"happy"}"#.utf8))
        #expect(persona.name == "Mira")
        #expect(persona.maxSentences == 2)
        #expect(persona.secrets == ["Owes the guild"])
        #expect(persona.defaultEmotion == .happy)
        let data = try JSONEncoder().encode(Fixtures.gorm)
        #expect(try JSONDecoder().decode(Persona.self, from: data) == Fixtures.gorm)
    }

    @Test func emotionParsing() throws {
        #expect(Emotion(matching: "Angry") == .angry)
        #expect(Emotion(matching: " scared! ") == .afraid)
        #expect(Emotion(matching: "grumpy") == .annoyed)
        #expect(Emotion(matching: "flabbergasted") == nil)
        let decoded = try JSONDecoder().decode([Emotion].self, from: Data(#"["happy","MAD","???"]"#.utf8))
        #expect(decoded == [.happy, .angry, .neutral])
        #expect(String(decoding: try JSONEncoder().encode(Emotion.proud), as: UTF8.self) == "\"proud\"")
    }

    @Test func memoryClampsRelationship() throws {
        var memory = NPCMemory(relationship: 250)
        #expect(memory.relationship == 100)
        let lowered = memory.adjustRelationship(by: -500)
        #expect(lowered == -100)
        #expect(memory.attitude == "hostile")
        memory.relationship = 30
        #expect(memory.attitude == "friendly")
        let maxed = memory.adjustRelationship(by: .max)
        #expect(maxed == 100)
        let floored = memory.adjustRelationship(by: .min)
        #expect(floored == -100)
        let decoded = try JSONDecoder().decode(NPCMemory.self, from: Data(#"{"relationship":999}"#.utf8))
        #expect(decoded.relationship == 100)
        #expect(decoded.facts.isEmpty)
    }

    @Test func memoryDeduplicatesAndLimitsFacts() {
        var memory = NPCMemory()
        let added = memory.remember("The player's name is Aria.")
        let duplicate = memory.remember("the players name is aria")
        let blank = memory.remember("   ")
        #expect(added && !duplicate && !blank)
        for index in 0..<5 { memory.remember("Fact \(index)", limit: 3) }
        #expect(memory.facts == ["Fact 2", "Fact 3", "Fact 4"])
    }

    @Test func memoryNoteRendering() {
        #expect(NPCMemory().note(includeRelationship: false) == nil)
        let note = NPCMemory(facts: ["Aria owes 10 gold"], relationship: 35, summary: "They haggled over a sword.")
            .note(includeRelationship: false)
        #expect(note == """
            Memory:
            - You feel friendly toward the player (35 on a scale from -100 to 100).
            - You remember: Aria owes 10 gold.
            - Earlier conversation: They haggled over a sword.
            """)
    }

    @Test func optionsDecodeWithDefaults() throws {
        let options = try JSONDecoder().decode(NPCOptions.self, from: Data(#"{"groundingTool":"check_inventory","playerOptionCount":0,"memoryTools":3}"#.utf8))
        #expect(options.groundingTool == "check_inventory")
        #expect(options.playerOptionCount == 0)
        #expect(options.memoryTools == .all)
        #expect(options.compactAfterTurns == NPCOptions().compactAfterTurns)
        #expect(options.fallbackOnGuardrail)
        #expect(options.secretsUnlockAtRelationship == 50)
        let guarded = try JSONDecoder().decode(NPCOptions.self, from: Data(#"{"secretsUnlockAtRelationship":null}"#.utf8))
        #expect(guarded.secretsUnlockAtRelationship == nil)
        let roundTrip = try JSONDecoder().decode(NPCOptions.self, from: JSONEncoder().encode(options))
        #expect(roundTrip == options)
    }

    @Test func dialogueTurnCodable() throws {
        let turn = DialogueTurn(
            line: "Aye.", emotion: .amused, playerOptions: ["Bye."], endsConversation: true,
            toolCalls: [ToolRecord(call: ToolCall(id: "c1", name: "t", arguments: [:]), output: .text("ok"), duration: 0.1)],
            relationship: 5, isFallback: false, usage: TokenUsage(inputTokens: 10, outputTokens: 3))
        let decoded = try JSONDecoder().decode(DialogueTurn.self, from: JSONEncoder().encode(turn))
        #expect(decoded == turn)
    }

    @Test func replySchemaOrderAndShape() {
        let schema = NPC.replySchema(persona: Fixtures.gorm, options: NPCOptions(emotions: [.happy, .angry, .happy], playerOptionCount: 2))
        #expect(schema.json["properties"]?.objectValue?.keys == ["emotion", "line", "player_options", "ends_conversation"])
        #expect(schema.json["properties"]?["emotion"]?["enum"] == ["happy", "angry"])
        #expect(schema.json["properties"]?["player_options"]?["maxItems"] == 2)
        let minimal = NPC.replySchema(persona: Fixtures.gorm, options: NPCOptions(playerOptionCount: 0, canEndConversation: false))
        #expect(minimal.json["properties"]?.objectValue?.keys == ["emotion", "line"])
    }

    @Test func replyParsingIsDefensive() {
        let reply = NPC.parseReply(
            ["emotion": "MAD", "line": "Gorm: \"Get out, lad.\"", "player_options": ["1. Sorry!", "- Sorry!", "\"Make me.\"", 7, ""], "ends_conversation": true],
            persona: Fixtures.gorm, options: NPCOptions(canEndConversation: false))
        #expect(reply.emotion == .angry)
        #expect(reply.line == "Get out, lad.")
        #expect(reply.playerOptions == ["Sorry!", "Make me."])
        #expect(!reply.endsConversation)
        let empty = NPC.parseReply(nil, persona: Fixtures.gorm, options: NPCOptions())
        #expect(empty == NPC.Reply(line: "", emotion: .neutral, playerOptions: [], endsConversation: false))
    }

    @Test func promptFormatting() {
        #expect(NPC.prompt(playerLine: "Hello", context: nil, worldSummary: nil) == "Player: Hello")
        #expect(NPC.prompt(playerLine: " ", context: nil, worldSummary: "") == "Player: (The player says nothing.)")
        #expect(NPC.prompt(playerLine: "Hi", context: "It is night.", worldSummary: "player.gold: 3") == """
            Game state:
            player.gold: 3
            Situation: It is night.
            Player: Hi
            """)
    }

    @Test func emotionTagParsing() {
        #expect(NPC.splitEmotionTag("[angry] Get out!") == ("angry", "Get out!", false))
        #expect(NPC.splitEmotionTag("  [gru") == (nil, "", true))
        #expect(NPC.splitEmotionTag("No tag here.") == (nil, "No tag here.", false))
        #expect(NPC.splitEmotionTag("[this is a very long bracketed aside without end") == (nil, "[this is a very long bracketed aside without end", false))
        let reply = NPC.parseTextReply("[gruff] Gorm: \"Aye, lad.\"", persona: Fixtures.gorm)
        #expect(reply == NPC.Reply(line: "Aye, lad.", emotion: .annoyed, playerOptions: [], endsConversation: false))
        #expect(NPC.parseTextReply("[sighs] Fine.", persona: Fixtures.gorm).emotion == Fixtures.gorm.defaultEmotion)
        #expect(NPC.partialTextReply("[hap") == nil)
        #expect(NPC.partialTextReply("[happy] Hel") == ["emotion": "happy", "line": "Hel"])
    }

    @Test func streamingLineTracker() {
        var tracker = LineTracker(speaker: "Gorm")
        var events: [String] = []
        let record: (DialogueEvent) -> Void = { event in
            switch event {
            case .emotion(let emotion): events.append("emotion:\(emotion.rawValue)")
            case .lineDelta(let text): events.append("+\(text)")
            case .lineReset(let text): events.append("=\(text)")
            default: events.append("?")
            }
        }
        tracker.consume(["emotion": "hap"], emit: record)
        tracker.consume(["emotion": "happy", "line": "Go"], emit: record)  // could become "Gorm:"
        tracker.consume(["emotion": "happy", "line": "Gorm: Aye"], emit: record)
        tracker.consume(["emotion": "happy", "line": "Gorm: Aye, lad"], emit: record)
        tracker.finish(line: "Aye, lad.", emotion: .happy, emit: record)
        #expect(events == ["emotion:happy", "+Aye", "+, lad", "+."])
        tracker.finish(line: "Something else.", emotion: .sad, emit: record)
        #expect(events.suffix(2) == ["emotion:sad", "=Something else."])
    }
}
