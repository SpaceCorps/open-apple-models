import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import Testing

/// Game methods against the real on-device model. Opt in with OAM_LIVE_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OAM_LIVE_TESTS"] == "1"), .serialized, .timeLimit(.minutes(3)))
struct LiveGameBridgeTests {
    static func liveHarness() -> BridgeHarness {
        BridgeHarness { $0.modelAvailability = { ModelAvailability.system() } }
    }

    /// Creates a shopkeeper through the bridge and talks to it twice; the
    /// game answers the inventory tool over `tool/call`.
    @Test func npcConversationWithClientTool() async throws {
        let harness = Self.liveHarness()
        harness.box.setResponder { call, _ in
            let item = call["arguments"]?["item"]?.stringValue?.lowercased() ?? ""
            if item.contains("sword") { return ["output": ["item": "iron sword", "stock": 3, "price_gold": 45]] }
            if item.contains("shield") { return ["output": ["item": "steel shield", "stock": 1, "price_gold": 80]] }
            return ["output": ["item": .string(item), "stock": 0]]
        }
        _ = try await harness.result("world/create", ["world": "village", "state": ["player": ["name": "Aria", "gold": 60]]])
        let created = try await harness.result("npc/create", [
            "npc": "gorm",
            "persona": [
                "name": "Gorm", "role": "the village blacksmith",
                "personality": "Gruff but fair.", "speakingStyle": "Short, blunt sentences. Calls people 'lad' or 'lass'.",
            ],
            "tools": [[
                "name": "check_inventory",
                "description": "Look up the stock and price of an item in Gorm's shop.",
                "parameters": ["type": "object", "properties": ["item": ["type": "string", "description": "Item name"]], "required": ["item"]],
            ]],
            "world": "village",
            "options": ["groundingTool": "check_inventory", "worldReadable": [], "worldContextPaths": ["player"]],
        ])
        print("[live] npc/create:", created)

        let clock = ContinuousClock()
        for line in ["Do you have any iron swords?", "And a steel shield? I only have 60 gold."] {
            let start = clock.now
            let request = harness.send("npc/talk", ["npc": "gorm", "line": .string(line), "stream": true])
            let response = try await harness.response(to: request, timeout: .seconds(90))
            let result = try #require(response["result"], "error: \(response)")
            let events = harness.notifications("npc/event", requestID: request).compactMap { $0["params"]?["event"]?["type"]?.stringValue }
            let calls = result["toolCalls"]?.arrayValue?.map { "\($0["call"]?["name"] ?? .null) \($0["call"]?["arguments"] ?? .null)" } ?? []
            print("[live] talk (\(clock.now - start)): [\(result["emotion"]?.stringValue ?? "?")] \(result["line"]?.stringValue ?? "")",
                  "| fallback:", result["isFallback"] ?? .null, "| tools:", calls, "| options:", result["playerOptions"] ?? .null,
                  "| events:", Dictionary(grouping: events, by: { $0 }).mapValues(\.count))
            let spoken = result["line"]?.stringValue ?? ""
            #expect(!spoken.isEmpty)
            if result["isFallback"] == false {
                #expect(result["toolCalls"]?[0]?["call"]?["name"] == "check_inventory")
            }
        }
        let state = try await harness.result("npc/state", ["npc": "gorm"])
        let list = try await harness.result("npc/list")
        print("[live] turns:", list["npcs"]?[0]?["turnCount"] ?? .null, "save bytes:", state.serialized().utf8.count)
    }

    @Test func decisionAndContent() async throws {
        let harness = Self.liveHarness()
        let clock = ContinuousClock()
        var start = clock.now
        let decision = try await harness.result("decision/decide", [
            "situation": "A goblin scout sees an armed adventurer approaching its camp.",
            "options": [
                ["id": "ambush", "description": "Hide and ambush the adventurer"],
                ["id": "flee", "description": "Run to warn the tribe"],
                ["id": "parley", "description": "Try to trade"],
            ],
            "actor": ["name": "Snik", "personality": "Timid and greedy."],
            "fallbackOptionID": "flee",
        ])
        print("[live] decision (\(clock.now - start)):", decision["optionID"] ?? .null, decision["confidence"] ?? .null, decision["reasoning"] ?? .null)
        let chosen = decision["optionID"]?.stringValue ?? ""
        #expect(["ambush", "flee", "parley"].contains(chosen))

        start = clock.now
        let content = try await harness.result("content/generate", [
            "prompt": "A rumor a tavern keeper tells about the old mine.",
            "schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Three to five words"],
                    "rumor": ["type": "string", "description": "One sentence"],
                    "truthful": ["type": "boolean"],
                ],
                "required": ["title", "rumor", "truthful"],
            ],
        ])
        print("[live] content (\(clock.now - start)):", content["content"] ?? .null)
        let rumor = content["content"]?["rumor"]?.stringValue
        #expect(rumor != nil)
    }
}
