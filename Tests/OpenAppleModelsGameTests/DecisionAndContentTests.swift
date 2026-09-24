import Foundation
import FoundationModels
import OpenAppleModels
@testable import OpenAppleModelsGame
import OpenAppleModelsTesting
import Testing

@Suite struct DecisionEngineTests {
    static let options = [
        DecisionOption(id: "attack", description: "Keep fighting"),
        DecisionOption(id: "flee", description: "Run into the woods"),
        DecisionOption(id: "beg", description: "Beg for mercy"),
    ]

    @Test func decideUsesEnumOfOptionIDs() async throws {
        let script = ModelScript([.json(["reasoning": "Three HP left against a full-health hero.", "choice": "flee", "confidence": 82])])
        let engine = DecisionEngine(model: ScriptedLanguageModel(script))
        let decision = try await engine.decide(
            situation: "The goblin has 3 HP; the player is at full health.",
            options: Self.options,
            actor: Persona(name: "Snik", role: "a cowardly goblin", personality: "Greedy and timid", goals: ["Survive"]),
            context: ["goblin_hp": 3, "player_hp": 40])
        #expect(decision.optionID == "flee")
        #expect(decision.reasoning == "Three HP left against a full-health hero.")
        #expect(decision.confidence == 82)
        #expect(decision.toolCalls.isEmpty)

        let request = try #require(script.requests.last)
        #expect(request.schemaName == "Response")
        #expect(request.toolCallingMode == .disallowed)
        let schema = try request.responseSchema()
        #expect(schema.propertyOrder == ["reasoning", "choice", "confidence"])
        #expect(schema.enumStrings.sorted() == ["attack", "beg", "flee"])
        #expect(request.lastPrompt == """
            Situation: The goblin has 3 HP; the player is at full health.
            Facts: {"goblin_hp":3,"player_hp":40}
            Options:
            - attack: Keep fighting
            - flee: Run into the woods
            - beg: Beg for mercy
            """)
        #expect(request.instructionsText.contains("You decide for Snik, a cowardly goblin."))
        #expect(request.instructionsText.contains("Goals: Survive."))
    }

    @Test func invalidOptionsAreRejectedWithoutCallingTheModel() async throws {
        let script = ModelScript([])
        let engine = DecisionEngine(model: ScriptedLanguageModel(script))
        for options in [
            [],
            [DecisionOption(id: "a"), DecisionOption(id: "a")],
            [DecisionOption(id: "a"), DecisionOption(id: "  ")],
            [DecisionOption(id: "a"), DecisionOption(id: " a ")],
        ] {
            do {
                _ = try await engine.decide(situation: "x", options: options)
                Issue.record("expected invalidRequest for \(options)")
            } catch {
                #expect(error.code == .invalidRequest)
            }
        }
        #expect(script.requests.isEmpty)
    }

    @Test func singleOptionShortCircuits() async throws {
        let script = ModelScript([])
        let decision = try await DecisionEngine(model: ScriptedLanguageModel(script))
            .decide(situation: "Cornered.", options: [DecisionOption(id: "fight")])
        #expect(decision.optionID == "fight")
        #expect(decision.confidence == 100)
        #expect(script.requests.isEmpty)
    }

    @Test func toolsCanBeRequiredBeforeDeciding() async throws {
        let calls = Log<ToolCall>()
        let script = ModelScript([
            .toolCalls([.init(name: "check_inventory", arguments: ["item": "potion"])]),
            .json(["reasoning": "Potions in stock.", "choice": "attack", "confidence": 140]),
        ])
        let decision = try await DecisionEngine(model: ScriptedLanguageModel(script)).decide(
            situation: "Low health.", options: Self.options,
            tools: [Fixtures.inventory(calls: calls)], toolChoice: .required)
        #expect(decision.optionID == "attack")
        #expect(decision.confidence == 100)  // clamped
        #expect(decision.toolCalls.count == 1)
        #expect(script.requests.map(\.toolCallingMode) == [.required, .allowed])
    }

    @Test func choicesOutsideTheOptionsFail() async throws {
        let script = ModelScript([
            .json(["reasoning": "r", "choice": "dance", "confidence": 50]),
            .json(["reasoning": "r", "choice": "FLEE"]),
        ])
        let engine = DecisionEngine(model: ScriptedLanguageModel(script))
        do {
            _ = try await engine.decide(situation: "x", options: Self.options)
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .generationFailed)
        }
        // Case differences are tolerated; missing confidence defaults to 50.
        let decision = try await engine.decide(situation: "x", options: Self.options)
        #expect(decision.optionID == "flee")
        #expect(decision.confidence == 50)
    }

    @Test func modelErrorsPropagate() async throws {
        let script = ModelScript([Fixtures.guardrail])
        await #expect(throws: AgentError.self) {
            _ = try await DecisionEngine(model: ScriptedLanguageModel(script)).decide(situation: "x", options: Self.options)
        }
    }

    @Test func guardrailFallbackOption() async throws {
        let script = ModelScript([Fixtures.guardrail, .fail(LanguageModelError.contextSizeExceeded(.init(contextSize: 1, tokenCount: 2, debugDescription: "x")))])
        let engine = DecisionEngine(model: ScriptedLanguageModel(script))
        let decision = try await engine.decide(situation: "Blocked.", options: Self.options, fallbackOptionID: "flee")
        #expect(decision == Decision(optionID: "flee", reasoning: "", confidence: 0, isFallback: true))
        // Other errors still throw; unknown fallback ids are rejected up front.
        await #expect(throws: AgentError.self) {
            _ = try await engine.decide(situation: "x", options: Self.options, fallbackOptionID: "flee")
        }
        do {
            _ = try await engine.decide(situation: "x", options: Self.options, fallbackOptionID: "dance")
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .invalidRequest)
        }
        #expect(script.requests.count == 2)
    }

    @Test func decideManyKeepsOrderAndIsolatesFailures() async throws {
        // Each request's prompt names the option the scripted model picks.
        let script = ModelScript([], fallback: .dynamic { request in
            let prompt = request.lastPrompt ?? ""
            let choice = ["attack", "flee", "beg"].first { prompt.contains("pick \($0)") } ?? "attack"
            return .json(["reasoning": "Scripted.", "choice": .string(choice), "confidence": 70])
        })
        let engine = DecisionEngine(model: ScriptedLanguageModel(script))
        let picks = ["flee", "beg", "attack", "flee", "beg"]
        var requests = picks.enumerated().map { index, pick in
            DecisionRequest(situation: "Guard \(index): pick \(pick)", options: Self.options)
        }
        requests.insert(DecisionRequest(situation: "broken", options: [DecisionOption(id: "x"), DecisionOption(id: "x")]), at: 2)

        let results = await engine.decideMany(requests, maxConcurrency: 3)
        #expect(results.count == 6)
        let chosen = results.map { result -> String in
            switch result {
            case .success(let decision): decision.optionID
            case .failure(let error): "error:\(error.code.rawValue)"
            }
        }
        #expect(chosen == ["flee", "beg", "error:invalid_request", "attack", "flee", "beg"])
        #expect(script.requests.count == 5)
        #expect(await engine.decideMany([]).isEmpty)
    }

    @Test func decisionTypesAreCodable() throws {
        let decision = Decision(optionID: "flee", reasoning: "r", confidence: 3)
        #expect(try JSONDecoder().decode(Decision.self, from: JSONEncoder().encode(decision)) == decision)
        let minimal = try JSONDecoder().decode(Decision.self, from: Data(#"{"optionID":"wait"}"#.utf8))
        #expect(minimal == Decision(optionID: "wait", reasoning: "", confidence: 50))
        let option = try JSONDecoder().decode(DecisionOption.self, from: Data(#"{"id":"wait"}"#.utf8))
        #expect(option == DecisionOption(id: "wait", description: ""))
    }
}

@Suite struct ContentGeneratorTests {
    struct Item: Decodable, Equatable {
        var name: String
        var rarity: String
        var damage: Int
    }

    static let itemSchema = JSONSchema.object([
        "name": .string(description: "Two or three words"),
        "rarity": .string(enum: ["common", "rare", "legendary"]),
        "damage": .integer(minimum: 1, maximum: 50),
    ])

    @Test func generatesAndDecodesItems() async throws {
        let script = ModelScript([.json(["damage": 12, "name": "Drowned Blade", "rarity": "rare"])])
        let generator = ContentGenerator(model: ScriptedLanguageModel(script))
        let item = try await generator.generate("A cursed sword from a sunken temple.", as: Item.self, schema: Self.itemSchema)
        #expect(item == Item(name: "Drowned Blade", rarity: "rare", damage: 12))
        let request = try #require(script.requests.last)
        #expect(request.instructionsText == ContentGenerator.defaultInstructions)
        #expect(request.toolCallingMode == .disallowed)
        #expect(try request.responseSchema().enumStrings.sorted() == ["common", "legendary", "rare"])
    }

    @Test func rawJSONFollowsSchemaOrderAndUsesContext() async throws {
        let script = ModelScript([.json(["damage": 5, "rarity": "common", "name": "Rusty Knife"])])
        let generator = ContentGenerator(model: ScriptedLanguageModel(script))
        let json = try await generator.generate(
            "A starter weapon.", schema: Self.itemSchema,
            instructions: "You design loot.", context: ["player_level": 1])
        #expect(json.objectValue?.keys == ["name", "rarity", "damage"])
        #expect(script.requests.last?.instructionsText == "You design loot.")
        #expect(script.requests.last?.lastPrompt == "A starter weapon.\nFacts: {\"player_level\":1}")
    }

    @Test func decodeFailuresAreReported() async throws {
        let script = ModelScript([.json(["name": "Nameless", "rarity": "rare", "damage": "lots"])])
        let generator = ContentGenerator(model: ScriptedLanguageModel(script))
        do {
            _ = try await generator.generate("x", as: Item.self, schema: .object(["name": .string(), "rarity": .string(), "damage": .string()]))
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .generationFailed)
            #expect(error.message.contains("Could not decode"))
        }
    }

    @Test func lootTableArrays() async throws {
        let script = ModelScript([.json(["drops": [["item": "Gold", "weight": 60], ["item": "Gem", "weight": 5]]])])
        struct Table: Decodable { struct Drop: Decodable { var item: String; var weight: Int }; var drops: [Drop] }
        let table = try await ContentGenerator(model: ScriptedLanguageModel(script)).generate(
            "Loot for a goblin camp.", as: Table.self,
            schema: .object(["drops": .array(of: .object(["item": .string(), "weight": .integer(minimum: 1, maximum: 100)]), minItems: 2, maxItems: 5)]))
        #expect(table.drops.map(\.item) == ["Gold", "Gem"])
    }

    @Test func invalidSchemasSurfaceAsErrors() async throws {
        let generator = ContentGenerator(model: ScriptedLanguageModel(ModelScript([])))
        do {
            _ = try await generator.generate("x", schema: JSONSchema(["type": "object", "properties": ["a": 5]]))
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .invalidSchema)
        }
    }
}
