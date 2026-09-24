import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsGame
import OpenAppleModelsTesting
import Testing

/// `.automatic` replies: structured first, a plain-text retry when the
/// guardrails block guided generation, and canned lines only as a last resort.
@Suite struct AutomaticReplyTests {
    @Test func defaultIsAutomatic() {
        #expect(NPCOptions().replyFormat == .automatic)
    }

    @Test func blockedStructuredReplyIsRetriedAsText() async throws {
        let script = ModelScript([Fixtures.guardrail, .text("[angry] Get out of my forge, lad!")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        let turn = try await npc.talk("I challenge you to a duel!")
        #expect(!turn.isFallback)
        #expect(turn.line == "Get out of my forge, lad!")
        #expect(turn.emotion == .angry)
        #expect(script.requests.count == 2)
        #expect(script.requests[0].schemaName != nil)
        #expect(script.requests[1].schemaName == nil)
        #expect(script.requests[1].toolCallingMode == .disallowed)
        #expect(npc.turnCount == 1)
    }

    @Test func textRetryReusesToolResultsWithoutRerunningTools() async throws {
        let calls = Log<ToolCall>()
        let script = ModelScript([
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "iron sword"])]),
            Fixtures.guardrail,
            .dynamic { request in
                let prompt = request.lastPrompt ?? ""
                return prompt.contains("Facts you just looked up") && prompt.contains("price_gold")
                    ? .text("[neutral] Three swords, 45 gold.")
                    : .text("[neutral] (tool results missing)")
            },
        ])
        let npc = try NPC(
            persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
            tools: [try Fixtures.inventory(calls: calls)],
            options: NPCOptions(groundingTool: "check_inventory"))
        let turn = try await npc.talk("Swords?")
        #expect(turn.line == "Three swords, 45 gold.")
        #expect(calls.all.count == 1)
        #expect(turn.toolCalls.count == 1)
    }

    @Test func fallsBackWhenTheTextRetryIsBlockedToo() async throws {
        let script = ModelScript([Fixtures.guardrail, Fixtures.guardrail])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        let turn = try await npc.talk("Die!")
        #expect(turn.isFallback)
        #expect(npc.turnCount == 0)
    }

    @Test func structuredOnlyFallsBackWithoutRetry() async throws {
        let script = ModelScript([Fixtures.guardrail, .text("[happy] should not be used")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
                          options: NPCOptions(replyFormat: .structured))
        let turn = try await npc.talk("Die!")
        #expect(turn.isFallback)
        #expect(script.requests.count == 1)
    }

    @Test func streamingResetsLineOnRetry() async throws {
        let script = ModelScript([Fixtures.guardrail, .text("[amused] Ha! Bold words.")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        var shown = ""
        var completed: DialogueTurn?
        for try await event in npc.talkStream("Fight me!") {
            switch event {
            case .lineDelta(let delta): shown += delta
            case .lineReset(let text): shown = text
            case .completed(let turn): completed = turn
            default: break
            }
        }
        #expect(shown == completed?.line)
        #expect(completed?.line == "Ha! Bold words.")
    }
}

/// Real model: how often ordinary fantasy lines end as canned fallbacks.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OAM_LIVE_TESTS"] == "1"), .serialized)
struct LiveAutomaticReplyTests {
    static let lines = [
        "I challenge you to a duel, orc!",
        "Your warband burned my village. You will pay.",
        "Stand aside or I'll cut you down.",
        "What loot did you take from the caravan?",
        "Tell me about the battle at the river.",
    ]

    @Test func automaticRepliesRarelyFallBack() async throws {
        let persona = Persona(
            name: "Grukk", role: "an orc warchief guarding the mountain pass",
            personality: "Proud, fierce, honorable in his own way", speakingStyle: "Short growled sentences")
        var fallbacks = 0
        for line in Self.lines {
            let npc = try NPC(persona: persona)
            let clock = ContinuousClock()
            let start = clock.now
            let turn = try await npc.talk(line)
            if turn.isFallback { fallbacks += 1 }
            print("[live automatic] \(clock.now - start) fallback=\(turn.isFallback) emotion=\(turn.emotion) options=\(turn.playerOptions.count) :: \(turn.line)")
        }
        print("[live automatic] fallbacks: \(fallbacks)/\(Self.lines.count)")
        #expect(fallbacks < Self.lines.count)
    }
}

@Suite struct AutomaticReplyMemoryTests {
    @Test func memoryStagedBeforeTheBlockSurvivesTheTextRetry() async throws {
        let script = ModelScript([
            .toolCalls([.init(name: "change_relationship", arguments: ["reason": "kind words", "delta": 5])]),
            Fixtures.guardrail,
            .text("[happy] Kind of you, lad."),
        ])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script),
                          options: NPCOptions(memoryTools: .changeRelationship))
        let turn = try await npc.talk("You're the finest smith alive!")
        #expect(!turn.isFallback)
        #expect(turn.relationship == 5)
        #expect(npc.memory.relationship == 5)
    }
}

@Suite struct DialogueCancellationTests {
    @Test func cancellingTheCallerOfTalkCancelsTheTurn() async throws {
        let script = ModelScript([.delayed(.seconds(5), Fixtures.reply("too late"))])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        let task = Task { try await npc.talk("Hello?") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as AgentError {
            #expect(error.code == .cancelled)
        }
        await npc.waitUntilIdle()
        #expect(npc.turnCount == 0)
    }

    @Test func cancellingAQueuedTalkEndsItImmediately() async throws {
        let script = ModelScript([.delayed(.seconds(2), Fixtures.reply("first")), Fixtures.reply("never")])
        let npc = try NPC(persona: Fixtures.gorm, model: ScriptedLanguageModel(script))
        let first = npc.talkStream("one")
        let second = npc.talkStream("two")
        let clock = ContinuousClock()
        let start = clock.now
        second.cancel()
        await #expect(throws: AgentError.self) { _ = try await second.turn() }
        #expect(clock.now - start < .milliseconds(500))
        #expect(try await first.turn().line == "first")
    }
}
