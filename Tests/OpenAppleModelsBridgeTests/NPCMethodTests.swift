import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import OpenAppleModelsGame
import Synchronization
import Testing

enum GameFixtures {
    static let gorm: JSONValue = [
        "name": "Gorm",
        "role": "the village blacksmith",
        "personality": "Gruff but fair.",
        "speakingStyle": "Short, blunt sentences.",
    ]

    static let checkInventory: JSONValue = [
        "name": "check_inventory",
        "description": "Look up stock and price of an item.",
        "parameters": ["type": "object", "properties": ["item": ["type": "string"]], "required": ["item"]],
    ]

    /// A structured NPC reply step.
    static func reply(_ line: String, emotion: String = "neutral", options: [String] = ["Buy one.", "Goodbye."], ends: Bool = false) -> JSONValue {
        ["json": [
            "emotion": .string(emotion),
            "line": .string(line),
            "player_options": .array(options.map(JSONValue.string)),
            "ends_conversation": .bool(ends),
        ]]
    }
}

extension BridgeHarness {
    /// Creates a scripted NPC and returns the `npc/create` result.
    @discardableResult
    func createNPC(
        _ id: String? = "gorm",
        steps: [JSONValue],
        persona: JSONValue = GameFixtures.gorm,
        tools: [JSONValue]? = nil,
        options: JSONValue? = nil,
        world: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> JSONValue {
        var params: JSONObject = ["persona": persona, "model": ["type": "scripted", "steps": .array(steps)]]
        if let id { params["npc"] = .string(id) }
        if let tools { params["tools"] = .array(tools) }
        if let options { params["options"] = options }
        if let world { params["world"] = .string(world) }
        return try await result("npc/create", .object(params), sourceLocation: sourceLocation)
    }
}

/// `npc/*` methods with scripted models.
@Suite(.timeLimit(.minutes(1)))
struct NPCMethodTests {
    @Test func lifecycle() async throws {
        let harness = BridgeHarness()
        let created = try await harness.createNPC(steps: [])
        #expect(created == ["npc": "gorm", "tools": [], "warnings": []])

        let generated = try await harness.result("npc/create", ["persona": ["name": "Mira"], "model": "scripted"])
        #expect(generated["npc"] == "npc1")

        let duplicate = try await harness.call("npc/create", ["npc": "gorm", "persona": ["name": "Gorm"], "model": "scripted"])
        #expect(duplicate.errorCode == BridgeError.Code.npcExists)
        #expect(duplicate.errorName == "npc_exists")

        let list = try await harness.result("npc/list")
        let npcs = list["npcs"]?.arrayValue ?? []
        #expect(npcs.compactMap { $0["npc"]?.stringValue } == ["gorm", "npc1"])
        #expect(npcs.first?["name"] == "Gorm")
        #expect(npcs.first?["role"] == "the village blacksmith")
        #expect(npcs.first?["model"] == "scripted")
        #expect(npcs.first?["world"] == .null)
        #expect(npcs.first?["turnCount"] == 0)
        #expect(npcs.first?["busy"] == false)

        #expect(try await harness.result("npc/delete", ["npc": "gorm"]) == ["npc": "gorm", "deleted": true])
        let missing = try await harness.call("npc/talk", ["npc": "gorm", "line": "Hello?"])
        #expect(missing.errorCode == -32050)
        #expect(missing.errorName == "npc_not_found")
        #expect(missing["error"]?["data"]?["npc"] == "gorm")
        #expect(try await harness.call("npc/delete", ["npc": "gorm"]).errorCode == -32050)
    }

    @Test func talkReturnsADialogueTurn() async throws {
        let harness = BridgeHarness()
        try await harness.createNPC(steps: [GameFixtures.reply("Three swords, lad. Forty-five gold.", emotion: "proud")])
        let result = try await harness.result("npc/talk", ["npc": "gorm", "line": "Got any swords?", "context": "The player just walked in."])
        #expect(result["npc"] == "gorm")
        #expect(result["line"] == "Three swords, lad. Forty-five gold.")
        #expect(result["emotion"] == "proud")
        #expect(result["playerOptions"] == ["Buy one.", "Goodbye."])
        #expect(result["endsConversation"] == false)
        #expect(result["toolCalls"] == [])
        #expect(result["relationship"] == 0)
        #expect(result["isFallback"] == false)
        #expect(result["usage"]?["totalTokens"]?.intValue != nil)
        #expect(result.objectValue?.keys == [
            "npc", "line", "emotion", "playerOptions", "endsConversation", "toolCalls", "relationship", "isFallback", "usage",
        ])
        let list = try await harness.result("npc/list")
        #expect(list["npcs"]?[0]?["turnCount"] == 1)
    }

    @Test func streamedEventsPrecedeTheResult() async throws {
        let harness = BridgeHarness()
        try await harness.createNPC(steps: [GameFixtures.reply("Steel is patient, lad.", emotion: "amused")])
        let request = harness.send("npc/talk", ["npc": "gorm", "line": "Any wisdom?", "stream": true])
        let response = try await harness.response(to: request)
        let result = try #require(response["result"])
        let events = harness.notifications("npc/event", requestID: request)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0["params"]?["npc"] == "gorm" })
        let responseIndex = try #require(harness.box.index { $0["id"] == .string(request) && $0["method"] == nil })
        let lastEvent = try #require(harness.box.messages.lastIndex { $0["method"] == "npc/event" })
        #expect(lastEvent < responseIndex)

        let payloads = events.compactMap { $0["params"]?["event"] }
        #expect(payloads.first { $0["type"] == "emotion" }?["emotion"] == "amused")
        // Deltas and resets add up to the final line.
        var shown = ""
        for event in payloads {
            if event["type"] == "lineDelta" { shown += event["delta"]?.stringValue ?? "" }
            if event["type"] == "lineReset" { shown = event["line"]?.stringValue ?? "" }
        }
        #expect(shown == "Steel is patient, lad.")
        #expect(result["line"] == "Steel is patient, lad.")

        // Without `stream`, no events.
        try await harness.createNPC("quiet", steps: [GameFixtures.reply("Hm.")])
        let quiet = harness.send("npc/talk", ["npc": "quiet", "line": "Hi"])
        _ = try await harness.response(to: quiet)
        #expect(harness.notifications("npc/event", requestID: quiet).isEmpty)
    }

    @Test func clientToolRoundTrip() async throws {
        let harness = BridgeHarness()
        let calls = Mutex<[JSONValue]>([])
        harness.box.setResponder { call, params in
            calls.withLock { $0.append(params) }
            #expect(call["name"] == "check_inventory")
            return ["output": ["item": call["arguments"]?["item"] ?? .null, "stock": 3, "price_gold": 45]]
        }
        let created = try await harness.createNPC(
            steps: [
                ["toolCalls": [["name": "check_inventory", "arguments": ["item": "iron sword"]]]],
                GameFixtures.reply("Three iron swords, forty-five gold each."),
            ],
            tools: [GameFixtures.checkInventory],
            options: ["groundingTool": "check_inventory"])
        #expect(created["tools"] == ["check_inventory"])

        let request = harness.send("npc/talk", ["npc": "gorm", "line": "Iron swords?", "stream": true])
        let result = try #require(try await harness.response(to: request)["result"])
        #expect(result["line"] == "Three iron swords, forty-five gold each.")
        let record = try #require(result["toolCalls"]?[0])
        #expect(record["call"]?["name"] == "check_inventory")
        #expect(record["call"]?["arguments"] == ["item": "iron sword"])
        #expect(record["output"]?["stock"] == 3)
        #expect(record["isError"] == false)

        let toolCall = try #require(calls.withLock { $0.first })
        #expect(toolCall["npc"] == "gorm")
        #expect(toolCall["requestId"] == .string(request))
        #expect(toolCall["call"]?["id"] == record["call"]?["id"])

        let types = harness.notifications("npc/event", requestID: request).compactMap { event -> String? in
            guard let payload = event["params"]?["event"] else { return nil }
            if payload["type"] == "toolCallStarted" { return "started:\(payload["execution"]?.stringValue ?? "?")" }
            return payload["type"]?.stringValue
        }
        let started = try #require(types.firstIndex(of: "started:client"))
        let completed = try #require(types.firstIndex(of: "toolCallCompleted"))
        #expect(started < completed)
        // The tool/call request precedes the response.
        let callIndex = try #require(harness.box.index { $0["method"] == "tool/call" })
        let responseIndex = try #require(harness.box.index { $0["id"] == .string(request) && $0["method"] == nil })
        #expect(callIndex < responseIndex)
    }

    @Test func clientToolErrorsReachTheModel() async throws {
        let harness = BridgeHarness()
        harness.box.setResponder { _, _ in ["error": ["code": -32000, "message": "The shop is closed."]] }
        try await harness.createNPC(
            steps: [
                ["toolCalls": [["name": "check_inventory", "arguments": ["item": "axe"]]]],
                GameFixtures.reply("Shop's closed, lad."),
            ],
            tools: [GameFixtures.checkInventory])
        let result = try await harness.result("npc/talk", ["npc": "gorm", "line": "Axes?"])
        #expect(result["toolCalls"]?[0]?["isError"] == true)
        #expect(result["toolCalls"]?[0]?["output"] == "The shop is closed.")
        #expect(result["line"] == "Shop's closed, lad.")
    }

    @Test func toolTimeoutSendsToolCancel() async throws {
        let harness = BridgeHarness()
        var tool = GameFixtures.checkInventory.objectValue!
        tool["timeoutSeconds"] = 0.05
        try await harness.createNPC(
            steps: [
                ["toolCalls": [["name": "check_inventory", "arguments": ["item": "bow"]]]],
                GameFixtures.reply("My ledger is slow today."),
            ],
            tools: [.object(tool)])
        let request = harness.send("npc/talk", ["npc": "gorm", "line": "Bows?"])
        let result = try #require(try await harness.response(to: request)["result"])
        #expect(result["line"] == "My ledger is slow today.")
        #expect(result["toolCalls"]?[0]?["isError"] == true)
        let cancel = try await harness.box.wait(timeout: .seconds(2), "tool/cancel") { $0["method"] == "tool/cancel" }
        let call = try #require(harness.box.messages.first { $0["method"] == "tool/call" })
        #expect(cancel["params"]?["id"] == call["id"])
        #expect(cancel["params"]?["npc"] == "gorm")
        #expect(cancel["params"]?["callId"] == call["params"]?["call"]?["id"])
    }

    @Test func cancelStopsAWaitingTurn() async throws {
        let harness = BridgeHarness { $0.defaultToolTimeout = nil }
        try await harness.createNPC(
            steps: [["toolCalls": [["name": "check_inventory", "arguments": ["item": "shield"]]]], GameFixtures.reply("Never mind.")],
            tools: [GameFixtures.checkInventory])
        let talk = harness.send("npc/talk", ["npc": "gorm", "line": "Shields?"])
        let queued = harness.send("npc/talk", ["npc": "gorm", "line": "And helmets?"])
        _ = try await harness.box.wait(timeout: .seconds(2), "tool/call") { $0["method"] == "tool/call" }
        let cancelled = try await harness.result("npc/cancel", ["npc": "gorm"])
        #expect(cancelled["cancelled"] == 2)
        let first = try await harness.response(to: talk)
        #expect(first.errorName == "cancelled")
        #expect(first.errorCode == BridgeError.Code.cancelled)
        #expect(try await harness.response(to: queued).errorName == "cancelled")
        _ = try await harness.box.wait(timeout: .seconds(2), "tool/cancel") { $0["method"] == "tool/cancel" }
        // The history is unchanged.
        let list = try await harness.result("npc/list")
        #expect(list["npcs"]?[0]?["turnCount"] == 0)
    }

    @Test func guardrailFallbackAndTextFormat() async throws {
        let harness = BridgeHarness()
        // Structured only: a blocked turn becomes a fallback line.
        try await harness.createNPC(
            "strict", steps: [["error": "guardrail_violation"]],
            options: ["replyFormat": "structured", "fallbackLines": ["Not now, lad."]])
        let blocked = try await harness.result("npc/talk", ["npc": "strict", "line": "Tell me about the war."])
        #expect(blocked["isFallback"] == true)
        #expect(blocked["line"] == "Not now, lad.")

        // Automatic (the default): retried once as plain text.
        try await harness.createNPC("auto", steps: [["error": "guardrail_violation"], ["text": "[worried] Let's not speak of it."]])
        let retried = try await harness.result("npc/talk", ["npc": "auto", "line": "Tell me about the war."])
        #expect(retried["isFallback"] == false)
        #expect(retried["line"] == "Let's not speak of it.")
        #expect(retried["emotion"] == "worried")

        // Text format: an emotion tag, then the line.
        try await harness.createNPC("plain", steps: [["text": "[happy] Welcome to the forge!"]], options: ["replyFormat": "text"])
        let plain = try await harness.result("npc/talk", ["npc": "plain", "line": "Hello"])
        #expect(plain["line"] == "Welcome to the forge!")
        #expect(plain["emotion"] == "happy")

        // Without the fallback, the error is returned.
        try await harness.createNPC("raw", steps: [["error": "guardrail_violation"]], options: ["replyFormat": "structured", "fallbackOnGuardrail": false])
        let raw = try await harness.call("npc/talk", ["npc": "raw", "line": "Tell me about the war."])
        #expect(raw.errorCode == BridgeError.Code.guardrailViolation)
    }

    @Test func barkUsesAOneOffSession() async throws {
        let harness = BridgeHarness()
        try await harness.createNPC(steps: [["text": "Rain again. Good for quenching."]])
        let bark = try await harness.result("npc/bark", ["npc": "gorm", "situation": "It starts to rain."])
        #expect(bark == ["npc": "gorm", "line": "Rain again. Good for quenching."])
        let list = try await harness.result("npc/list")
        #expect(list["npcs"]?[0]?["turnCount"] == 0)

        try await harness.createNPC("blocked", steps: [["error": "guardrail_violation"]])
        let failed = try await harness.call("npc/bark", ["npc": "blocked", "situation": "A fight breaks out."])
        #expect(failed.errorName == "guardrail_violation")
    }

    @Test func stateAndRestoreRoundTrip() async throws {
        let harness = BridgeHarness()
        _ = try await harness.result("world/create", ["world": "village", "state": ["player": ["name": "Aria"]]])
        harness.box.setResponder { _, _ in ["output": "3 in stock"] }
        try await harness.createNPC(
            steps: [GameFixtures.reply("Welcome, Aria.")],
            tools: [GameFixtures.checkInventory],
            options: ["memoryTools": ["rememberFact"], "playerOptionCount": 2, "toolTimeoutSeconds": 30],
            world: "village")
        _ = try await harness.result("npc/talk", ["npc": "gorm", "line": "Hello!"])
        _ = try await harness.result("npc/update", ["npc": "gorm", "memory": ["relationship": 25, "facts": ["Aria likes axes."]]])

        let saved = try await harness.result("npc/state", ["npc": "gorm"])
        let state = try #require(saved["state"])
        #expect(state["version"] == 1)
        #expect(state["npc"] == "gorm")
        #expect(state["persona"]?["name"] == "Gorm")
        #expect(state["memory"]?["relationship"] == 25)
        #expect(state["memory"]?["facts"] == ["Aria likes axes."])
        #expect(state["transcript"]?.objectValue != nil)
        #expect(state["tools"] == [GameFixtures.checkInventory])
        #expect(state["world"] == "village")
        #expect(state["options"]?["memoryTools"] == ["rememberFact"])
        #expect(state["options"]?["playerOptionCount"] == 2)
        #expect(state["options"]?["toolTimeoutSeconds"] == 30)
        #expect(state["options"]?["secretsUnlockAtRelationship"] == 50)

        _ = try await harness.result("npc/delete", ["npc": "gorm"])
        // The save alone restores the NPC: id, tools, options and world.
        let restored = try await harness.result("npc/restore", [
            "state": state,
            "model": ["type": "scripted", "steps": [
                ["toolCalls": [["name": "check_inventory", "arguments": ["item": "axe"]]]],
                GameFixtures.reply("Axes, you said? Three."),
            ]],
        ])
        #expect(restored["npc"] == "gorm")
        #expect(restored["warnings"] == [])
        let tools = restored["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(tools.contains("check_inventory"))
        #expect(tools.contains(WorldState.readToolName))
        #expect(tools.contains(NPC.rememberFactToolName))

        let list = try await harness.result("npc/list")
        #expect(list["npcs"]?[0]?["turnCount"] == 1)
        #expect(list["npcs"]?[0]?["relationship"] == 25)
        #expect(list["npcs"]?[0]?["world"] == "village")
        let turn = try await harness.result("npc/talk", ["npc": "gorm", "line": "Axes?"])
        #expect(turn["line"] == "Axes, you said? Three.")
        #expect(turn["toolCalls"]?[0]?["output"] == "3 in stock")
        #expect(turn["relationship"] == 25)

        // Restoring into a taken id fails; a new id works.
        let taken = try await harness.call("npc/restore", ["state": state, "model": "scripted"])
        #expect(taken.errorName == "npc_exists")
        let copy = try await harness.result("npc/restore", ["state": saved, "npc": "gorm2", "world": nil, "tools": [], "model": "scripted"])
        #expect(copy["tools"]?.arrayValue?.compactMap(\.stringValue) == [NPC.rememberFactToolName])

        // A save whose world is gone restores without it, with a warning.
        _ = try await harness.result("world/delete", ["world": "village"])
        let orphan = try await harness.result("npc/restore", ["state": state, "npc": "gorm3", "model": "scripted"])
        #expect(orphan["warnings"]?[0]?.stringValue?.contains("village") == true)

        let invalid = try await harness.call("npc/restore", ["state": ["persona": ["role": "no name"]]])
        #expect(invalid.errorCode == BridgeError.Code.invalidParams)
    }

    @Test func updatesApplyInArrivalOrder() async throws {
        let harness = BridgeHarness()
        try await harness.createNPC(steps: [GameFixtures.reply("First."), ["text": "[angry] Second."]])
        // Pipelined: the update waits for the first turn and applies before the second.
        let first = harness.send("npc/talk", ["npc": "gorm", "line": "One"])
        let update = harness.send("npc/update", [
            "npc": "gorm",
            "persona": ["personality": "Furious today.", "goals": ["Close early"]],
            "options": ["replyFormat": "text", "fallbackLines": ["Go away."]],
            "memory": ["relationship": -30],
        ])
        let second = harness.send("npc/talk", ["npc": "gorm", "line": "Two"])
        let state = harness.send("npc/state", ["npc": "gorm"])
        #expect(try await harness.response(to: first)["result"]?["line"] == "First.")
        #expect(try await harness.response(to: update)["result"] == ["npc": "gorm", "warnings": []])
        let secondResult = try await harness.response(to: second)["result"]
        #expect(secondResult?["line"] == "Second.")
        #expect(secondResult?["emotion"] == "angry")
        #expect(secondResult?["relationship"] == -30)
        let saved = try #require(try await harness.response(to: state)["result"]?["state"])
        #expect(saved["persona"]?["personality"] == "Furious today.")
        #expect(saved["persona"]?["name"] == "Gorm")
        #expect(saved["persona"]?["role"] == "the village blacksmith")
        #expect(saved["options"]?["replyFormat"] == "text")
        #expect(saved["memory"]?["relationship"] == -30)

        // Tools and a grounding tool can change together.
        let both = try await harness.result("npc/update", [
            "npc": "gorm", "tools": [GameFixtures.checkInventory], "options": ["groundingTool": "check_inventory"],
        ])
        #expect(both["warnings"] == [])
        let listed = try await harness.result("npc/list")
        #expect(listed["npcs"]?[0]?["tools"] == ["check_inventory"])

        // Invalid updates fail and change nothing.
        let unknownTool = try await harness.call("npc/update", ["npc": "gorm", "tools": [], "options": ["groundingTool": "nope"]])
        #expect(unknownTool.errorCode == BridgeError.Code.invalidParams)
        let badName = try await harness.call("npc/update", ["npc": "gorm", "persona": ["name": ""]])
        #expect(badName.errorCode == BridgeError.Code.invalidParams)
        let after = try await harness.result("npc/state", ["npc": "gorm", "settle": false])
        #expect(after["state"]?["options"]?["groundingTool"] == "check_inventory")
        #expect(after["state"]?["tools"] == [GameFixtures.checkInventory])
        #expect(after["state"]?["persona"]?["name"] == "Gorm")

        // Reset clears the conversation, optionally the memory too.
        _ = try await harness.result("npc/reset", ["npc": "gorm", "clearMemory": true])
        let reset = try await harness.result("npc/list")
        #expect(reset["npcs"]?[0]?["turnCount"] == 0)
        #expect(reset["npcs"]?[0]?["relationship"] == 0)
    }

    @Test func worldToolsAndNotifications() async throws {
        let harness = BridgeHarness()
        _ = try await harness.result("world/create", ["world": "village", "state": ["player": ["name": "Aria", "gold": 60]]])
        let subscription = try await harness.result("world/subscribe", ["world": "village", "path": "quests"])
        try await harness.createNPC(
            steps: [
                ["toolCalls": [["name": "read_world_state", "arguments": ["path": "player.gold"]]]],
                ["toolCalls": [["name": "update_world_state", "arguments": ["path": "quests.ring", "value": "started"]]]],
                GameFixtures.reply("Sixty gold, Aria. Find my ring."),
            ],
            options: ["groundingTool": "read_world_state", "worldWritable": ["quests"], "maxToolRounds": 3],
            world: "village")
        let request = harness.send("npc/talk", ["npc": "gorm", "line": "What can I afford?", "stream": true])
        let result = try #require(try await harness.response(to: request)["result"])
        #expect(result["toolCalls"]?[0]?["output"] == 60)
        #expect(result["toolCalls"]?[1]?["call"]?["name"] == "update_world_state")
        let snapshot = try await harness.result("world/get", ["world": "village", "path": "quests.ring"])
        #expect(snapshot["value"] == "started")

        let change = try #require(harness.box.messages.first { $0["method"] == "world/changed" })
        #expect(change["params"]?["world"] == "village")
        #expect(change["params"]?["subscription"] == subscription["subscription"])
        #expect(change["params"]?["path"] == "quests.ring")
        #expect(change["params"]?["newValue"] == "started")
        #expect(change["params"]?["oldValue"] == nil)
        // The change happened during the turn, so it precedes the response.
        let changeIndex = try #require(harness.box.index { $0["method"] == "world/changed" })
        let responseIndex = try #require(harness.box.index { $0["id"] == .string(request) && $0["method"] == nil })
        #expect(changeIndex < responseIndex)
        let local = harness.notifications("npc/event", requestID: request).compactMap { $0["params"]?["event"] }
            .filter { $0["type"] == "toolCallStarted" }
        #expect(local.allSatisfy { $0["execution"] == "local" })
        #expect(local.count == 2)
    }

    @Test func invalidParametersAreRejected() async throws {
        let harness = BridgeHarness()
        let noPersona = try await harness.call("npc/create", ["model": "scripted"])
        #expect(noPersona.errorCode == BridgeError.Code.invalidParams)
        #expect(noPersona["error"]?["message"]?.stringValue?.contains("'persona'") == true)

        let noName = try await harness.call("npc/create", ["persona": ["role": "a ghost"], "model": "scripted"])
        #expect(noName["error"]?["message"] == "Missing required parameter 'persona.name'.")

        let badGoals = try await harness.call("npc/create", ["persona": ["name": "Ann", "goals": "gold"], "model": "scripted"])
        #expect(badGoals["error"]?["message"] == "Parameter 'persona.goals' must be an array.")

        let badFormat = try await harness.call("npc/create", ["persona": ["name": "Ann"], "options": ["replyFormat": "json"], "model": "scripted"])
        #expect(badFormat["error"]?["message"]?.stringValue?.contains("options.replyFormat") == true)

        let badMemoryTool = try await harness.call("npc/create", ["persona": ["name": "Ann"], "options": ["memoryTools": ["dance"]], "model": "scripted"])
        #expect(badMemoryTool["error"]?["message"]?.stringValue?.contains("dance") == true)

        let badChoice = try await harness.call("npc/create", ["persona": ["name": "Ann"], "options": ["toolChoice": "sometimes"], "model": "scripted"])
        #expect(badChoice["error"]?["message"]?.stringValue?.contains("options.toolChoice") == true)

        let unknownGrounding = try await harness.call("npc/create", ["persona": ["name": "Ann"], "options": ["groundingTool": "check_inventory"], "model": "scripted"])
        #expect(unknownGrounding.errorCode == BridgeError.Code.invalidParams)
        #expect(unknownGrounding["error"]?["message"]?.stringValue?.contains("groundingTool") == true)

        let noWorld = try await harness.call("npc/create", ["persona": ["name": "Ann"], "world": "atlantis", "model": "scripted"])
        #expect(noWorld.errorName == "world_not_found")

        let badID = try await harness.call("npc/create", ["npc": "", "persona": ["name": "Ann"], "model": "scripted"])
        #expect(badID.errorCode == BridgeError.Code.invalidParams)

        // Nothing above created an NPC.
        #expect(try await harness.result("npc/list") == ["npcs": []])

        let warned = try await harness.result("npc/create", [
            "persona": ["name": "Ann", "personalty": "typo"],
            "options": ["temprature": 0.5, "memoryTools": "all"],
            "voice": "deep",
            "model": "scripted",
        ])
        let warnings = warned["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings.contains { $0.contains("'persona.personalty'") })
        #expect(warnings.contains { $0.contains("'options.temprature'") })
        #expect(warnings.contains { $0.contains("'voice'") })
        #expect(warned["tools"] == [.string(NPC.rememberFactToolName), .string(NPC.changeRelationshipToolName)])

        let missingLine = try await harness.call("npc/talk", ["npc": warned["npc"]!])
        #expect(missingLine["error"]?["message"] == "Missing required parameter 'line'.")
        let unknownChoice = try await harness.call("npc/talk", ["npc": warned["npc"]!, "line": "hi", "toolChoice": ["tool": "nope"]])
        #expect(unknownChoice.errorName == "invalid_request")
    }

    @Test func manyToolsAreWarnedAbout() async throws {
        let harness = BridgeHarness()
        let tools: [JSONValue] = (1...4).map { ["name": .string("tool_\($0)"), "description": .string("Does thing \($0).")] }
        _ = try await harness.result("world/create", ["world": "w"])
        let created = try await harness.result("npc/create", [
            "persona": ["name": "Ann"], "tools": .array(tools), "world": "w",
            "options": ["worldWritable": [""]], "model": "scripted",
        ])
        let warnings = created["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings.contains { $0.contains("6 tools") })
    }

    @Test func limitsAndShutdown() async throws {
        let game = GameExtension(maxNPCs: 1)
        let harness = BridgeHarness { $0.extensions = [game] }
        try await harness.createNPC(steps: [])
        let second = try await harness.call("npc/create", ["persona": ["name": "Two"], "model": "scripted"])
        #expect(second.errorName == "limit_reached")
        #expect(second.errorCode == BridgeError.Code.limitReached)
        #expect(game.npc("gorm")?.persona.name == "Gorm")

        let initialize = try await harness.result("initialize")
        let notifications = initialize["capabilities"]?["notifications"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(notifications.contains("npc/event"))
        #expect(notifications.contains("world/changed"))
        let methods = initialize["capabilities"]?["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for method in ["npc/create", "npc/talk", "npc/bark", "npc/state", "npc/restore", "npc/delete", "npc/list",
                       "decision/decide", "decision/decideMany", "world/create", "world/get", "world/set",
                       "world/snapshot", "world/delete", "world/subscribe", "content/generate"] {
            #expect(methods.contains(method), "missing \(method)")
        }

        _ = try await harness.result("shutdown")
        #expect(game.npcIDs.isEmpty)
        #expect(game.worldIDs.isEmpty)
    }

    @Test func standardExtensionsServeTheGameMethods() async throws {
        #expect(BridgeConfiguration.standardExtensions().contains { $0 is GameExtension })
        let harness = BridgeHarness()
        #expect(harness.engine.methods.contains("npc/talk"))
    }
}
