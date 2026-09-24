import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import Synchronization
import Testing

/// `decision/*` and `content/generate`.
@Suite(.timeLimit(.minutes(1)))
struct DecisionMethodTests {
    static let goblinOptions: JSONValue = [
        ["id": "attack", "description": "Keep fighting"],
        ["id": "flee", "description": "Run into the woods"],
        "beg",
    ]

    static func scripted(_ steps: [JSONValue]) -> JSONValue {
        ["type": "scripted", "steps": .array(steps)]
    }

    @Test func decide() async throws {
        let harness = BridgeHarness()
        let result = try await harness.result("decision/decide", [
            "situation": "The goblin has 3 HP left.",
            "options": Self.goblinOptions,
            "actor": ["name": "Snik", "personality": "Timid and greedy."],
            "context": ["hp": 3, "playerHp": 40],
            "model": Self.scripted([["json": ["reasoning": "Snik is timid.", "choice": "flee", "confidence": 78]]]),
        ])
        #expect(result == [
            "optionID": "flee", "reasoning": "Snik is timid.", "confidence": 78, "toolCalls": [],
            "usage": result["usage"] ?? .null, "isFallback": false,
        ])
        #expect(result.objectValue?.keys == ["optionID", "reasoning", "confidence", "toolCalls", "usage", "isFallback"])

        // A single option needs no model.
        let only = try await harness.result("decision/decide", ["situation": "Cornered.", "options": ["fight"], "model": "scripted"])
        #expect(only["optionID"] == "fight")
        #expect(only["confidence"] == 100)
    }

    @Test func invalidDecisionsFailBeforeTheModel() async throws {
        let harness = BridgeHarness()
        let duplicate = try await harness.call("decision/decide", ["situation": "x", "options": ["a", "a"], "model": "scripted"])
        #expect(duplicate["error"]?["message"]?.stringValue?.contains("Duplicate option id 'a'") == true)
        let empty = try await harness.call("decision/decide", ["situation": "x", "options": [], "model": "scripted"])
        #expect(empty.errorCode == BridgeError.Code.invalidParams)
        let fallback = try await harness.call("decision/decide", ["situation": "x", "options": ["a", "b"], "fallbackOptionID": "c", "model": "scripted"])
        #expect(fallback["error"]?["message"]?.stringValue?.contains("fallbackOptionID") == true)
        let choice = try await harness.call("decision/decide", ["situation": "x", "options": ["a", "b"], "toolChoice": ["tool": "scout"], "model": "scripted"])
        #expect(choice["error"]?["message"]?.stringValue?.contains("scout") == true)
        let noSituation = try await harness.call("decision/decide", ["options": ["a", "b"], "model": "scripted"])
        #expect(noSituation["error"]?["message"] == "Missing required parameter 'situation'.")
        let unknownActor = try await harness.call("decision/decide", ["situation": "x", "options": ["a", "b"], "actor": "nobody", "model": "scripted"])
        #expect(unknownActor.errorName == "npc_not_found")
    }

    @Test func guardrailsUseTheFallbackOption() async throws {
        let harness = BridgeHarness()
        let result = try await harness.result("decision/decide", [
            "situation": "The ogre swings its club.", "options": Self.goblinOptions, "fallbackOptionID": "flee",
            "model": Self.scripted([["error": "guardrail_violation"]]),
        ])
        #expect(result["optionID"] == "flee")
        #expect(result["isFallback"] == true)

        let failed = try await harness.call("decision/decide", [
            "situation": "The ogre swings its club.", "options": Self.goblinOptions,
            "model": Self.scripted([["error": "guardrail_violation"]]),
        ])
        #expect(failed.errorCode == BridgeError.Code.guardrailViolation)
    }

    @Test func clientToolsAndNPCActors() async throws {
        let harness = BridgeHarness()
        let seen = Mutex<[JSONValue]>([])
        harness.box.setResponder { call, params in
            seen.withLock { $0.append(params) }
            return ["output": ["distance": 12, "target": call["arguments"]?["target"] ?? .null]]
        }
        try await harness.createNPC("snik", steps: [], persona: ["name": "Snik", "role": "a goblin scout"])
        let request = harness.send("decision/decide", [
            "situation": "An adventurer approaches.",
            "options": Self.goblinOptions,
            "actor": "snik",
            "tools": [["name": "measure", "description": "Distance to a target in meters.",
                       "parameters": ["type": "object", "properties": ["target": ["type": "string"]]]]],
            "toolChoice": "required",
            "model": Self.scripted([
                ["toolCalls": [["name": "measure", "arguments": ["target": "adventurer"]]]],
                ["json": ["reasoning": "Far enough to run.", "choice": "flee", "confidence": 60]],
            ]),
        ])
        let result = try #require(try await harness.response(to: request)["result"])
        #expect(result["optionID"] == "flee")
        #expect(result["toolCalls"]?[0]?["call"]?["name"] == "measure")
        #expect(result["toolCalls"]?[0]?["output"]?["distance"] == 12)
        let params = try #require(seen.withLock { $0.first })
        #expect(params["requestId"] == .string(request))
        #expect(params["call"]?["arguments"] == ["target": "adventurer"])
    }

    @Test func forwardedToolTimeoutSendsToolCancel() async throws {
        let harness = BridgeHarness()
        let result = try await harness.result("decision/decide", [
            "situation": "Night falls.",
            "options": ["camp", "march"],
            "tools": [["name": "weather", "description": "Current weather."]],
            "toolTimeoutSeconds": 0.05,
            "model": Self.scripted([
                ["toolCalls": [["name": "weather"]]],
                ["json": ["reasoning": "Unknown weather; rest.", "choice": "camp", "confidence": 40]],
            ]),
        ])
        #expect(result["optionID"] == "camp")
        #expect(result["toolCalls"]?[0]?["isError"] == true)
        let cancel = try await harness.box.wait(timeout: .seconds(2), "tool/cancel") { $0["method"] == "tool/cancel" }
        let call = try #require(harness.box.messages.first { $0["method"] == "tool/call" })
        #expect(cancel["params"]?["id"] == call["id"])
        #expect(cancel["params"]?["callId"] == call["params"]?["call"]?["id"])
    }

    @Test func decideManyKeepsOrderAndIsolatesFailures() async throws {
        let harness = BridgeHarness()
        let result = try await harness.result("decision/decideMany", [
            "maxConcurrency": 1,
            "requests": [
                ["situation": "Guard A hears a noise.", "options": ["investigate", "ignore"]],
                ["situation": "Guard B sees blood.", "options": ["investigate", "ignore"]],
                ["situation": "Guard C is alone.", "options": ["wait"]],
            ],
            "model": Self.scripted([
                ["json": ["reasoning": "Duty.", "choice": "investigate", "confidence": 90]],
                ["error": "guardrail_violation"],
            ]),
        ])
        let results = try #require(result["results"]?.arrayValue)
        #expect(results.count == 3)
        #expect(results[0]["optionID"] == "investigate")
        #expect(results[1]["error"]?["data"]?["code"] == "guardrail_violation")
        #expect(results[1]["error"]?["code"] == .number(Double(BridgeError.Code.guardrailViolation)))
        #expect(results[2]["optionID"] == "wait")

        let invalid = try await harness.call("decision/decideMany", ["requests": [["situation": "x", "options": ["a"]], ["situation": "y"]]])
        #expect(invalid["error"]?["message"] == "Missing required parameter 'requests[1].options'.")
        let none = try await harness.call("decision/decideMany", ["requests": []])
        #expect(none.errorCode == BridgeError.Code.invalidParams)
    }

    @Test func generateContent() async throws {
        let harness = BridgeHarness()
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "rarity": ["type": "string", "enum": ["common", "rare", "legendary"]],
                "damage": ["type": "integer", "minimum": 1, "maximum": 50],
            ],
            "required": ["name", "rarity", "damage"],
        ]
        let result = try await harness.result("content/generate", [
            "prompt": "A cursed sword from a drowned temple.",
            "schema": schema,
            "context": ["playerLevel": 7],
            "model": Self.scripted([["json": ["damage": 45, "name": "Drowned Fang", "rarity": "legendary"]]]),
        ])
        #expect(result["content"] == ["name": "Drowned Fang", "rarity": "legendary", "damage": 45])
        // Keys come back in schema order.
        #expect(result["content"]?.objectValue?.keys == ["name", "rarity", "damage"])
        #expect(result["warnings"] == nil)

        let invalid = try await harness.call("content/generate", ["prompt": "x", "schema": ["type": "nope"], "model": "scripted"])
        #expect(invalid.errorCode == BridgeError.Code.invalidSchema)
        let noPrompt = try await harness.call("content/generate", ["schema": schema, "model": "scripted"])
        #expect(noPrompt.errorCode == BridgeError.Code.invalidParams)

        harness.box.setResponder { _, _ in ["output": ["biome": "swamp"]] }
        let withTool = try await harness.result("content/generate", [
            "prompt": "A monster for the current biome.",
            "schema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
            "tools": [["name": "biome", "description": "The current biome."]],
            "model": Self.scripted([["toolCalls": [["name": "biome"]]], ["json": ["name": "Bog Lurker"]]]),
        ])
        #expect(withTool["content"] == ["name": "Bog Lurker"])
    }
}
