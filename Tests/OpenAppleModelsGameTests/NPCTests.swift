import Foundation
import FoundationModels
import OpenAppleModels
@testable import OpenAppleModelsGame
import OpenAppleModelsTesting
import Testing

@Suite struct NPCTests {
    // MARK: Talking

    @Test func groundedTurnWithToolRoundAndStructuredLine() async throws {
        let calls = Log<ToolCall>()
        let script = ModelScript([
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "iron sword"])]),
            Fixtures.reply("Gorm: \"Three iron swords, lad. 45 gold each.\"", emotion: "annoyed",
                           options: ["I'll take one.", "Too pricey.", "Goodbye."]),
        ])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
            tools: [Fixtures.inventory(calls: calls)],
            options: NPCOptions(groundingTool: "check_inventory"))
        let turn = try await npc.talk("Got any iron swords?")

        #expect(turn.line == "Three iron swords, lad. 45 gold each.")
        #expect(turn.emotion == .annoyed)
        #expect(turn.playerOptions == ["I'll take one.", "Too pricey.", "Goodbye."])
        #expect(!turn.endsConversation)
        #expect(!turn.isFallback)
        #expect(turn.toolCalls.map(\.call.name) == ["check_inventory"])
        #expect(calls.all.first?.arguments["item"] == "iron sword")

        // Grounding forced the tool on the first step only.
        #expect(script.requests.map(\.toolCallingMode) == [.required, .allowed])
        #expect(script.requests[0].enabledTools == ["check_inventory"])
        #expect(script.requests[1].toolOutputs.count == 1)
        // The reply schema was requested, and the persona is in the instructions.
        let schema = try script.requests[1].responseSchema()
        #expect(schema.propertyOrder == ["emotion", "line", "player_options", "ends_conversation"])
        #expect(Set(schema.enumStrings).isSuperset(of: ["angry", "happy", "neutral"]))
        #expect(script.requests[0].instructionsText.hasPrefix("You play Gorm, the village blacksmith"))
        #expect(npc.turnCount == 1)
    }

    @Test func autoChoiceAndPerTurnOverride() async throws {
        let script = ModelScript([Fixtures.reply("Hmph."), Fixtures.reply("Nothing to say.")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), tools: [Fixtures.inventory()])
        _ = try await npc.talk("Hello")
        _ = try await npc.talk("Bye", toolChoice: ToolChoice.none)
        #expect(script.requests.map(\.toolCallingMode) == [.allowed, .disallowed])
    }

    @Test func npcWithoutToolsDisallowsToolCalls() async throws {
        let script = ModelScript([Fixtures.reply("Hello there.")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        let turn = try await npc.talk("Hi")
        #expect(turn.line == "Hello there.")
        #expect(script.requests[0].toolCallingMode == .disallowed)
        #expect(script.requests[0].instructionsText.contains("say so in character"))
    }

    @Test func worldToolsAndContextInjection() async throws {
        let world = WorldState(["player": ["name": "Aria", "gold": 12], "time": "night"])
        let script = ModelScript([
            .toolCalls([.init(name: "read_world_state", arguments: ["path": "player.gold"])]),
            .dynamic { request in
                let output = request.toolOutputs.last.map { "\($0.segments)" } ?? ""
                return Fixtures.reply(output.contains("12") ? "You have 12 gold, Aria." : "Hm?")
            },
            .toolCalls([.init(name: "update_world_state", arguments: ["path": "npcs.gorm.mood", "value": "pleased"])]),
            Fixtures.reply("Pleasure doing business."),
        ])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script), world: world,
            options: NPCOptions(worldWritable: ["npcs.gorm"], worldContextPaths: ["player.name", "time"]))
        let first = try await npc.talk("How much gold do I have?", context: "The forge is hot.")
        #expect(first.line == "You have 12 gold, Aria.")
        #expect(script.requests[0].enabledTools == ["read_world_state", "update_world_state"])
        #expect(script.requests[0].lastPrompt == """
            Game state:
            player.name: Aria
            time: night
            Situation: The forge is hot.
            Player: How much gold do I have?
            """)

        let second = try await npc.talk("Thanks!")
        #expect(second.toolCalls.first?.output.isError == false)
        #expect(world.get("npcs.gorm.mood") == "pleased")
    }

    // MARK: Streaming

    @Test func streamingEmitsEmotionThenLineDeltas() async throws {
        let json: JSONValue = [
            "emotion": "happy",
            "line": "Welcome to my forge, lad. Mind the sparks.",
            "player_options": ["Thanks.", "Nice forge.", "Bye."],
            "ends_conversation": false,
        ]
        let script = ModelScript([.text(json.serialized(), chunks: 12)])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        var kinds: [String] = []
        var displayed = ""
        var final: DialogueTurn?
        for try await event in npc.talkStream("Hello") {
            switch event {
            case .emotion(let emotion):
                kinds.append("emotion")
                #expect(emotion == .happy)
            case .lineDelta(let delta):
                kinds.append("delta")
                displayed += delta
            case .lineReset(let text):
                kinds.append("reset")
                displayed = text
            case .completed(let turn):
                kinds.append("completed")
                final = turn
            default:
                kinds.append("other")
            }
        }
        let turn = try #require(final)
        #expect(displayed == turn.line)
        #expect(turn.line == "Welcome to my forge, lad. Mind the sparks.")
        #expect(kinds.first == "emotion")
        #expect(kinds.last == "completed")
        #expect(kinds.filter { $0 == "emotion" }.count == 1)
        #expect(!kinds.contains("reset"))
        #expect(kinds.filter { $0 == "delta" }.count >= 1)
    }

    @Test func plainTextRepliesStreamWithEmotionTags() async throws {
        let script = ModelScript([
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "iron sword"])]),
            .text("[grumpy] Three swords, lad. Forty-five gold each.", chunks: 8),
        ])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script), tools: [Fixtures.inventory()],
            options: NPCOptions(groundingTool: "check_inventory", replyFormat: .text))
        var emotions: [Emotion] = []
        var displayed = ""
        var final: DialogueTurn?
        for try await event in npc.talkStream("Swords?") {
            switch event {
            case .emotion(let emotion): emotions.append(emotion)
            case .lineDelta(let delta): displayed += delta
            case .lineReset(let text): displayed = text
            case .completed(let turn): final = turn
            default: break
            }
        }
        let turn = try #require(final)
        #expect(turn.line == "Three swords, lad. Forty-five gold each.")
        #expect(turn.emotion == .annoyed)
        #expect(emotions == [.annoyed])
        #expect(displayed == turn.line)
        #expect(!displayed.contains("["))
        #expect(turn.playerOptions.isEmpty && !turn.endsConversation)
        #expect(turn.toolCalls.count == 1)
        // No schema was requested; the tag rule is in the instructions.
        #expect(script.requests[1].schemaName == nil)
        #expect(script.requests[0].instructionsText.contains("Begin every reply with your current emotion in square brackets"))
    }

    @Test func streamingSurfacesToolActivityAndExternalCalls() async throws {
        let gate = try AgentTool.external(name: "open_gate", description: "Open a gate.", parameters: .object(["gate": .string()]))
        let script = ModelScript([
            .toolCalls([.init(name: "open_gate", arguments: ["gate": "north"])]),
            .dynamic { request in
                Fixtures.reply(request.toolOutputs.isEmpty ? "?" : "The gate is open.")
            },
        ])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), tools: [gate])
        let stream = npc.talkStream("Open the north gate", toolChoice: .required)
        var requested: [ToolCall] = []
        var results: [ToolRecord] = []
        var final: DialogueTurn?
        for try await event in stream {
            switch event {
            case .externalToolCall(let call):
                requested.append(call)
                #expect(stream.pendingToolCalls.map(\.id) == [call.id])
                #expect(stream.submit(.json(["opened": true]), for: call.id))
            case .toolResult(let record): results.append(record)
            case .completed(let turn): final = turn
            default: break
            }
        }
        #expect(requested.map(\.name) == ["open_gate"])
        #expect(results.first?.output == .json(["opened": true]))
        #expect(final?.line == "The gate is open.")
        #expect(final?.toolCalls.count == 1)
    }

    @Test func talkRunsExternalToolsWithHandler() async throws {
        let gate = try AgentTool.external(name: "open_gate", description: "Open a gate.", parameters: .object(["gate": .string()]))
        let script = ModelScript([
            .toolCalls([.init(name: "open_gate", arguments: ["gate": "north"])]),
            Fixtures.reply("Done."),
        ])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), tools: [gate])
        let turn = try await npc.talk("Open it") { call in .text("opened \(try call.string("gate"))") }
        #expect(turn.toolCalls.first?.output == .text("opened north"))
    }

    @Test func cancellationLeavesHistoryClean() async throws {
        let script = ModelScript([.delayed(.seconds(5), Fixtures.reply("too late"))])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        let stream = npc.talkStream("Wait")
        Task { try? await Task.sleep(for: .milliseconds(100)); stream.cancel() }
        do {
            _ = try await stream.turn()
            Issue.record("expected cancellation")
        } catch {
            #expect(error.code == .cancelled)
        }
        #expect(npc.turnCount == 0)
        // A stream cancelled before it starts never reaches the model.
        let early = npc.talkStream("Never mind")
        early.cancel()
        await #expect(throws: AgentError.self) { _ = try await early.turn() }
        #expect(script.requests.count == 1)
    }

    // MARK: Memory

    @Test func memoryToolsStageAndCommitOnSuccess() async throws {
        let script = ModelScript([
            .toolCalls([
                .init(name: "remember_fact", arguments: ["fact": "The player's name is Aria."]),
                .init(name: "change_relationship", arguments: ["reason": "She complimented my work.", "delta": 8]),
            ]),
            Fixtures.reply("Aria, eh? Kind words.", emotion: "proud"),
            Fixtures.reply("Back again, Aria?"),
        ])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
            options: NPCOptions(memoryTools: .all))
        let first = try await npc.talk("I'm Aria. Your blades are the finest in the land!")
        #expect(first.relationship == 8)
        #expect(npc.memory.facts == ["The player's name is Aria."])
        #expect(npc.memory.relationship == 8)
        #expect(Set(first.toolCalls.map(\.call.name)) == ["remember_fact", "change_relationship"])
        #expect(script.requests[0].instructionsText.contains("call remember_fact"))

        _ = try await npc.talk("Hello again")
        // The next turn's instructions carry the memory.
        let instructions = script.requests[2].instructionsText
        #expect(instructions.contains("You remember: The player's name is Aria."))
        #expect(instructions.contains("You feel neutral toward the player (8 on a scale from -100 to 100)."))
    }

    @Test func relationshipChangesAreClampedPerCallAndOverall() async throws {
        let script = ModelScript([
            .toolCalls([.init(name: "change_relationship", arguments: ["reason": "Insulted my mother.", "delta": -50])]),
            Fixtures.reply("Get out!", emotion: "angry"),
        ])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
            options: NPCOptions(memoryTools: .changeRelationship, maxRelationshipChange: 10),
            memory: NPCMemory(relationship: -95))
        let turn = try await npc.talk("Your mother was a goblin.")
        #expect(turn.relationship == -100)
        #expect(turn.toolCalls.first?.output.modelText.contains("hostile") == true)
        #expect(npc.memory.relationship == -100)
    }

    @Test func secretsAreGuardedWhenThresholdDisabled() async throws {
        let script = ModelScript([Fixtures.reply("No.")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), options: NPCOptions(secretsUnlockAtRelationship: nil))
        _ = try await npc.talk("Any secrets?")
        #expect(script.requests[0].instructionsText.contains("Your secret: He forged the blade that killed the old king."))
        #expect(script.requests[0].instructionsText.contains("Keep your secret unless"))
    }

    @Test func secretsUnlockWithRelationship() async throws {
        let script = ModelScript([Fixtures.reply("No."), Fixtures.reply("Fine. I'll tell you.")])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
            options: NPCOptions(secretsUnlockAtRelationship: 60),
            memory: NPCMemory(relationship: 10))
        _ = try await npc.talk("Any secrets?")
        #expect(!script.requests[0].instructionsText.contains("killed the old king"))
        npc.memory.relationship = 75
        _ = try await npc.talk("Any secrets now?")
        #expect(script.requests[1].instructionsText.contains("killed the old king"))
        #expect(script.requests[1].instructionsText.contains("You may share your secret"))
    }

    // MARK: Context management

    @Test func compactionSummarizesOlderTurnsIntoMemory() async throws {
        let script = ModelScript([
            Fixtures.reply("One."), Fixtures.reply("Two."), Fixtures.reply("Three."),
            .text("Aria asked about swords three times; Gorm stayed gruff."),
            Fixtures.reply("Four."),
        ])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
            options: NPCOptions(compactAfterTurns: 3, keepRecentTurns: 1))
        for line in ["a", "b"] { _ = try await npc.talk(line) }
        await npc.waitUntilIdle()
        #expect(npc.memory.summary == nil)
        #expect(npc.turnCount == 2)

        _ = try await npc.talk("c")
        let settled = await npc.settledState()
        #expect(settled.memory.summary == "Aria asked about swords three times; Gorm stayed gruff.")
        #expect(settled.transcript.filter { if case .prompt = $0 { true } else { false } }.count == 1)
        #expect(npc.memory.summary == "Aria asked about swords three times; Gorm stayed gruff.")
        #expect(npc.turnCount == 1)
        let summarizer = script.requests[3]
        #expect(summarizer.instructionsText.contains("Gorm's memory"))
        #expect(summarizer.lastPrompt?.contains("Player: a") == true)
        #expect(summarizer.lastPrompt?.contains("Gorm: ") == true)

        _ = try await npc.talk("d")
        let next = script.requests[4]
        #expect(next.instructionsText.contains("Earlier conversation: Aria asked about swords three times"))
        // Kept turn + the new prompt.
        #expect(next.promptCount == 2)
    }

    @Test func manualCompactionWithTooLittleHistory() async throws {
        let script = ModelScript([Fixtures.reply("Hi.")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), options: NPCOptions(compactAfterTurns: 0))
        _ = try await npc.talk("hello")
        #expect(try await npc.compact() == nil)
        #expect(npc.turnCount == 1)
    }

    // MARK: Guardrails

    @Test func guardrailFallbackKeepsHistoryAndMemoryClean() async throws {
        let script = ModelScript([
            Fixtures.reply("Welcome."),
            .toolCalls([.init(name: "change_relationship", arguments: ["reason": "x", "delta": 5])]),
            Fixtures.guardrail,
            Fixtures.reply("Anything else?"),
        ])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
            options: NPCOptions(memoryTools: .changeRelationship, fallbackLines: ["Watch your tongue."]))
        _ = try await npc.talk("Hello")
        let historyBefore = npc.transcript.count

        let blocked = try await npc.talk("<something the guardrails block>")
        #expect(blocked.isFallback)
        #expect(blocked.line == "Watch your tongue.")
        #expect(blocked.emotion == Fixtures.gorm.defaultEmotion)
        #expect(blocked.playerOptions.isEmpty)
        #expect(blocked.relationship == 0)
        #expect(blocked.toolCalls.map(\.call.name) == ["change_relationship"])
        // Neither the failed exchange nor its staged memory change survive.
        #expect(npc.transcript.count == historyBefore)
        #expect(npc.turnCount == 1)
        #expect(npc.memory.relationship == 0)

        let next = try await npc.talk("Sorry.")
        #expect(next.line == "Anything else?")
        #expect(script.requests[3].promptCount == 2)
    }

    @Test func guardrailFallbackInStreamingReplacesPartialText() async throws {
        let script = ModelScript([Fixtures.guardrail])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        var displayed = ""
        var final: DialogueTurn?
        for try await event in npc.talkStream("<blocked>") {
            switch event {
            case .lineDelta(let delta): displayed += delta
            case .lineReset(let text): displayed = text
            case .completed(let turn): final = turn
            default: break
            }
        }
        #expect(final?.isFallback == true)
        #expect(NPCOptions.defaultFallbackLines.contains(displayed))
        #expect(displayed == final?.line)
    }

    @Test func guardrailThrowsWhenFallbackDisabled() async throws {
        let script = ModelScript([.fail(LanguageModelError.refusal(.init(explanation: "No.", debugDescription: "refused")))])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), options: NPCOptions(fallbackOnGuardrail: false))
        do {
            _ = try await npc.talk("x")
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .refusal)
        }
        #expect(npc.turnCount == 0)
    }

    @Test func otherErrorsAreNotMaskedByFallback() async throws {
        let script = ModelScript([.fail(LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "too long")))])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        await #expect(throws: AgentError.self) { _ = try await npc.talk("x") }
    }

    // MARK: Barks

    @Test func barkIsASingleCleanLineWithoutHistory() async throws {
        let script = ModelScript([Fixtures.reply("Hello."), .text("Gorm: \"Fine steel, fresh from the forge!\"\nAnd more text.")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), tools: [Fixtures.inventory()])
        _ = try await npc.talk("Hi")
        let bark = try await npc.bark(situation: "A customer walks past the stall.")
        #expect(bark == "Fine steel, fresh from the forge!")
        let request = try #require(script.requests.last)
        #expect(request.enabledTools.isEmpty)
        #expect(request.promptCount == 1)
        #expect(request.lastPrompt == "Situation: A customer walks past the stall.\nPlayer: (The player says nothing.)")
        #expect(request.instructionsText.contains("at most 1 short sentence"))
        #expect(!request.instructionsText.contains("killed the old king"))
        #expect(npc.turnCount == 1)
    }

    @Test func barkErrorsAreThrown() async throws {
        let script = ModelScript([Fixtures.guardrail])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        do {
            _ = try await npc.bark(situation: "x")
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .guardrailViolation)
        }
    }

    // MARK: Persistence

    @Test func saveAndRestore() async throws {
        let script = ModelScript([
            .toolCalls([.init(name: "remember_fact", arguments: ["fact": "Aria wants a shield."])]),
            Fixtures.reply("A shield, then."),
            .dynamic { request in Fixtures.reply("turns=\(request.promptCount)") },
        ])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), options: NPCOptions(memoryTools: .rememberFact))
        _ = try await npc.talk("I need a shield.")
        let data = try JSONEncoder().encode(npc.saveState())

        let saved = try JSONDecoder().decode(NPCSaveState.self, from: data)
        #expect(saved.version == 1)
        #expect(saved.persona == Fixtures.gorm)
        #expect(saved.memory.facts == ["Aria wants a shield."])
        let restored = try NPC(restoring: saved, model: ScriptedLanguageModel(script), options: NPCOptions(memoryTools: .rememberFact))
        #expect(restored.memory == npc.memory)
        #expect(restored.turnCount == 1)
        let turn = try await restored.talk("Remember me?")
        #expect(turn.line == "turns=2")
        #expect(script.requests.last?.instructionsText.contains("Aria wants a shield.") == true)
    }

    @Test func saveStateDropsIncompleteTurn() throws {
        let entries: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "hi"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: "hello"))])),
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "again"))])),
        ]
        let trimmed = NPC.completeTurns(of: Transcript(entries: entries))
        #expect(trimmed.count == 2)
    }

    @Test func resetConversation() async throws {
        let script = ModelScript([Fixtures.reply("One."), Fixtures.reply("Fresh start.")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), memory: NPCMemory(facts: ["x"], relationship: 20))
        _ = try await npc.talk("a")
        await npc.resetConversation()
        #expect(npc.turnCount == 0)
        #expect(npc.memory.relationship == 20)
        await npc.resetConversation(clearingMemory: true)
        #expect(npc.memory == NPCMemory())
        _ = try await npc.talk("b")
        #expect(!script.requests[1].instructionsText.contains("Memory:"))
    }

    // MARK: Validation

    @Test func invalidConfigurationIsRejected() throws {
        #expect(throws: AgentError.self) { _ = try NPC(persona: Persona(name: " ")) }
        #expect(throws: AgentError.self) {
            _ = try NPC(persona: Fixtures.gorm, tools: [try Fixtures.inventory()], options: NPCOptions(groundingTool: "missing_tool"))
        }
        let clash = try AgentTool(name: "read_world_state", description: "Mine.") { _ in "x" }
        #expect(throws: AgentError.self) { _ = try NPC(persona: Fixtures.gorm, tools: [clash], world: WorldState()) }
        let npc = try NPC(persona: Fixtures.gorm, tools: [try Fixtures.inventory()])
        #expect(throws: AgentError.self) { try npc.setOptions(NPCOptions(groundingTool: "nope")) }
        try npc.setOptions(NPCOptions(groundingTool: "check_inventory"))
        #expect(npc.options.groundingTool == "check_inventory")
    }

    @Test func toolAndOptionChangesApplyNextTurn() async throws {
        let script = ModelScript([Fixtures.reply("a"), Fixtures.reply("b")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script), tools: [try Fixtures.inventory()])
        _ = try await npc.talk("1")
        try npc.setTools([])
        try npc.setOptions(NPCOptions(memoryTools: .rememberFact, playerOptionCount: 0))
        _ = try await npc.talk("2")
        #expect(script.requests[0].enabledTools == ["check_inventory"])
        #expect(script.requests[1].enabledTools == ["remember_fact"])
        let schema = try script.requests[1].responseSchema()
        #expect(schema["properties"]?["player_options"] == nil)
    }

    @Test func differentNPCsTalkConcurrently() async throws {
        let script = ModelScript([], fallback: .dynamic { request in
            Fixtures.reply("echo: \(request.lastPrompt ?? "")")
        })
        let a = try NPC(persona: Persona(name: "A"), model: ScriptedLanguageModel(script))
        let b = try NPC(persona: Persona(name: "B"), model: ScriptedLanguageModel(script))
        async let first = a.talk("one")
        async let second = b.talk("two")
        let (x, y) = try await (first, second)
        #expect(x.line == "echo: Player: one")
        #expect(y.line == "echo: Player: two")
    }
}
