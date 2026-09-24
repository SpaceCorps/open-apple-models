import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsBridge
import OpenAppleModelsTesting
import Synchronization
import Testing

/// Sessions, turns, streaming and client tools.
@Suite(.timeLimit(.minutes(1)))
struct SessionTests {
    static let openGate: JSONValue = [
        "name": "open_gate",
        "description": "Ask the game to open a gate.",
        "parameters": ["type": "object", "properties": ["gate": ["type": "string"]], "required": ["gate"]],
    ]

    @Test func lifecycle() async throws {
        let harness = BridgeHarness()
        let created = try await harness.result("session/create", [
            "session": "gorm", "instructions": "You are Gorm.",
            "model": ["type": "scripted", "steps": [["text": "Hmph."]]],
        ])
        #expect(created == ["session": "gorm", "warnings": []])

        let generated = try await harness.result("session/create", ["model": "scripted"])
        #expect(generated["session"] == "s1")

        let duplicate = try await harness.call("session/create", ["session": "gorm", "model": "scripted"])
        #expect(duplicate.errorCode == -32021)
        #expect(duplicate.errorName == "session_exists")

        let list = try await harness.result("session/list")
        #expect(list["sessions"]?.arrayValue?.compactMap { $0["session"]?.stringValue } == ["gorm", "s1"])
        #expect(list["sessions"]?[0]?["instructions"] == "You are Gorm.")
        #expect(list["sessions"]?[0]?["model"] == "scripted")

        _ = try await harness.result("session/respond", ["session": "gorm", "prompt": "Hello"])
        let transcript = try await harness.result("session/transcript", ["session": "gorm"])
        #expect(transcript["transcript"]?.objectValue != nil)

        #expect(try await harness.result("session/delete", ["session": "gorm"]) == ["session": "gorm", "deleted": true])
        let missing = try await harness.call("session/respond", ["session": "gorm", "prompt": "Hello?"])
        #expect(missing.errorCode == -32020)
        #expect(missing.errorName == "session_not_found")
        #expect(missing["error"]?["data"]?["session"] == "gorm")
        let deleteAgain = try await harness.call("session/delete", ["session": "gorm"])
        #expect(deleteAgain.errorCode == -32020)
    }

    @Test func sessionLimit() async throws {
        let harness = BridgeHarness { $0.maxSessions = 1 }
        _ = try await harness.createSession(steps: [])
        let second = try await harness.call("session/create", ["model": "scripted"])
        #expect(second.errorCode == -32022)
        #expect(second.errorName == "session_limit")
    }

    @Test func createWarnsAboutUnknownKeysAndUnavailableModel() async throws {
        let harness = BridgeHarness {
            $0.modelAvailability = { ModelAvailability(available: false, reason: "apple_intelligence_not_enabled", contextSize: 4096) }
            $0.modelFactory = { _ in ScriptedLanguageModelFactory.make() }
        }
        let result = try await harness.result("session/create", ["instructionz": "typo", "options": ["temprature": 0.5]])
        let warnings = result["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings.contains { $0.contains("'instructionz'") })
        #expect(warnings.contains { $0.contains("'options.temprature'") })
        #expect(warnings.contains { $0.contains("apple_intelligence_not_enabled") })
    }

    @Test func respondWithoutStreaming() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [["text": "Welcome to the forge."]])
        let request = harness.send("session/respond", ["session": .string(id), "prompt": "Hi"])
        let response = try await harness.response(to: request)
        let result = try #require(response["result"])
        #expect(result["session"] == .string(id))
        #expect(result["text"] == "Welcome to the forge.")
        #expect(result["toolCalls"] == [])
        #expect(result["usage"]?["outputTokens"]?.intValue != nil)
        #expect(result["steps"]?.arrayValue?.count == 1)
        #expect(result["steps"]?[0]?["toolCallingMode"] == "disallowed")
        #expect(result.objectValue?.keys == ["session", "text", "toolCalls", "usage", "steps"])
        #expect(harness.notifications("session/event", requestID: request).isEmpty)
    }

    @Test func streamingEventsPrecedeTheResult() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [["text": "Steel is forged in fire and patience.", "chunks": 5]])
        let request = harness.send("session/respond", ["session": .string(id), "prompt": "Wisdom?", "stream": true])
        let response = try await harness.response(to: request)
        let events = harness.notifications("session/event", requestID: request)
        let responseIndex = try #require(harness.box.index { $0["id"] == .string(request) && $0["method"] == nil })
        let lastEventIndex = try #require(harness.box.messages.lastIndex { $0["method"] == "session/event" })
        #expect(lastEventIndex < responseIndex)

        let types = events.compactMap { $0["params"]?["event"]?["type"]?.stringValue }
        #expect(types.first == "modelStep")
        #expect(types.contains("text"))
        #expect(events.allSatisfy { $0["params"]?["session"] == .string(id) })
        let deltas = events.compactMap { event -> String? in
            guard event["params"]?["event"]?["type"] == "text" else { return nil }
            return event["params"]?["event"]?["delta"]?.stringValue
        }
        #expect(deltas.joined() == "Steel is forged in fire and patience.")
        #expect(response["result"]?["text"] == "Steel is forged in fire and patience.")
    }

    @Test func structuredOutput() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [["json": ["choice": "haggle", "reasoning": "Too cheap."]]])
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "reasoning": ["type": "string"],
                "choice": ["type": "string", "enum": ["sell", "refuse", "haggle"]],
            ],
            "required": ["reasoning", "choice"],
        ]
        let request = harness.send("session/respond", ["session": .string(id), "prompt": "Decide", "schema": schema, "stream": true])
        let result = try #require(try await harness.response(to: request)["result"])
        #expect(result["structured"]?["choice"] == "haggle")
        #expect(result["structured"]?.objectValue?.keys == ["reasoning", "choice"])
        #expect(result["text"]?.stringValue?.contains("haggle") == true)
        let types = harness.notifications("session/event", requestID: request).compactMap { $0["params"]?["event"]?["type"]?.stringValue }
        #expect(types.contains("partial"))

        let invalid = try await harness.call("session/respond", ["session": .string(id), "prompt": "x", "schema": ["type": "nope"]])
        #expect(invalid.errorCode == -32007)
    }

    @Test func clientToolRoundTrip() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [
            ["toolCalls": [["name": "open_gate", "arguments": ["gate": "north"]]]],
            ["template": "Gate result: {toolOutput}"],
        ], tools: [Self.openGate], options: ["toolChoice": "required"])
        let request = harness.send("session/respond", ["session": .string(id), "prompt": "Open the north gate", "stream": true])

        let toolCall = try await harness.box.wait { $0["method"] == "tool/call" }
        let params = try #require(toolCall["params"])
        #expect(params["session"] == .string(id))
        #expect(params["requestId"] == .string(request))
        #expect(params["call"]?["name"] == "open_gate")
        #expect(params["call"]?["arguments"] == ["gate": "north"])
        let callID = try #require(toolCall["id"]?.stringValue)
        #expect(callID.hasPrefix("t-"))

        // The turn waits for the engine.
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.box.index { $0["id"] == .string(request) } == nil)

        harness.engine.receive(JSONValue.object(["jsonrpc": "2.0", "id": .string(callID), "result": ["output": ["opened": true]]]).serialized())
        let result = try #require(try await harness.response(to: request)["result"])
        #expect(result["text"] == #"Gate result: {"opened":true}"#)
        let record = try #require(result["toolCalls"]?[0])
        #expect(record["call"]?["name"] == "open_gate")
        #expect(record["output"] == ["opened": true])
        #expect(record["isError"] == false)
        #expect(result["steps"]?[0]?["toolCallingMode"] == "required")

        let events = harness.notifications("session/event", requestID: request).compactMap { $0["params"]?["event"] }
        let started = try #require(events.first { $0["type"] == "toolCallStarted" })
        #expect(started["execution"] == "client")
        #expect(events.contains { $0["type"] == "toolCallCompleted" })
        // tool/call went out before the response.
        let toolIndex = try #require(harness.box.index { $0["method"] == "tool/call" })
        let responseIndex = try #require(harness.box.index { $0["id"] == .string(request) && $0["method"] == nil })
        #expect(toolIndex < responseIndex)
    }

    @Test func toolErrorReplies() async throws {
        let harness = BridgeHarness()
        harness.box.setResponder { call, _ in
            switch call["arguments"]?["gate"]?.stringValue {
            case "north": ["error": ["code": -32000, "message": "Gate subsystem offline"]]
            default: ["output": "The chain is jammed.", "isError": true]
            }
        }
        let id = try await harness.createSession(steps: [
            ["toolCalls": [["name": "open_gate", "arguments": ["gate": "north"]]]],
            ["template": "1:{toolOutput}"],
            ["toolCalls": [["name": "open_gate", "arguments": ["gate": "south"]]]],
            ["template": "2:{toolOutput}"],
        ], tools: [Self.openGate])
        let first = try await harness.result("session/respond", ["session": .string(id), "prompt": "north"])
        #expect(first["toolCalls"]?[0]?["isError"] == true)
        #expect(first["toolCalls"]?[0]?["output"] == "Gate subsystem offline")
        #expect(first["text"] == "1:Error: Gate subsystem offline")

        let second = try await harness.result("session/respond", ["session": .string(id), "prompt": "south"])
        #expect(second["toolCalls"]?[0]?["isError"] == true)
        #expect(second["text"] == "2:Error: The chain is jammed.")
    }

    @Test func textAndLenientToolOutputs() async throws {
        let harness = BridgeHarness()
        harness.box.setResponder { call, _ in
            call["arguments"]?["gate"] == "east" ? ["output": "Opened."] : ["opened": false]
        }
        let id = try await harness.createSession(steps: [
            ["toolCalls": [["name": "open_gate", "arguments": ["gate": "east"]], ["name": "open_gate", "arguments": ["gate": "west"]]]],
            ["template": "{toolOutputs}"],
        ], tools: [Self.openGate])
        let result = try await harness.result("session/respond", ["session": .string(id), "prompt": "both"])
        let outputs = Set(result["toolCalls"]?.arrayValue?.compactMap { $0["output"] } ?? [])
        #expect(outputs == ["Opened.", ["opened": false]])
        #expect(result["text"]?.stringValue?.contains("Opened.") == true)
    }

    @Test func toolTimeoutSendsToolCancel() async throws {
        let harness = BridgeHarness()
        var gate = Self.openGate
        gate["timeoutSeconds"] = 0.2
        let id = try await harness.createSession(steps: [
            ["toolCalls": [["name": "open_gate", "arguments": ["gate": "north"]]]],
            ["template": "{toolOutput}"],
        ], tools: [gate])
        let request = harness.send("session/respond", ["session": .string(id), "prompt": "Open"])
        let toolCall = try await harness.box.wait { $0["method"] == "tool/call" }
        let result = try #require(try await harness.response(to: request)["result"])
        #expect(result["toolCalls"]?[0]?["isError"] == true)
        #expect(result["text"]?.stringValue?.contains("timed out") == true)

        let cancel = try #require(harness.box.messages.first { $0["method"] == "tool/cancel" })
        #expect(cancel["params"]?["id"] == toolCall["id"])
        #expect(cancel["params"]?["callId"] == toolCall["params"]?["call"]?["id"])
        #expect(cancel["params"]?["session"] == .string(id))
        let cancelIndex = try #require(harness.box.index { $0["method"] == "tool/cancel" })
        let responseIndex = try #require(harness.box.index { $0["id"] == .string(request) && $0["method"] == nil })
        #expect(cancelIndex < responseIndex)

        // A late reply is ignored.
        harness.engine.receive(JSONValue.object(["jsonrpc": "2.0", "id": toolCall["id"]!, "result": ["output": "late"]]).serialized())
        _ = try await harness.result("ping")
    }

    @Test func slowTurnsDoNotBlockOtherRequests() async throws {
        let harness = BridgeHarness()
        let a = try await harness.createSession(steps: [["text": "A done", "delayMs": 400]])
        let b = try await harness.createSession(steps: [["text": "B done", "delayMs": 400]])
        let clock = ContinuousClock()
        let start = clock.now
        let requestA = harness.send("session/respond", ["session": .string(a), "prompt": "go"])
        let requestB = harness.send("session/respond", ["session": .string(b), "prompt": "go"])
        // Other requests are served while both turns run.
        let created = try await harness.call("session/create", ["model": "scripted"])
        #expect(harness.box.index { $0["id"] == .string(requestA) } == nil)
        #expect(created["result"] != nil)
        let responseA = try await harness.response(to: requestA)
        let responseB = try await harness.response(to: requestB)
        #expect(responseA["result"]?["text"] == "A done")
        #expect(responseB["result"]?["text"] == "B done")
        // The two sessions ran concurrently.
        #expect(clock.now - start < .milliseconds(750))
    }

    @Test func pipelinedRequestsKeepTheirOrder() async throws {
        let harness = BridgeHarness()
        let model: JSONValue = ["type": "scripted", "steps": [["template": "A:{prompt}", "delayMs": 50], ["template": "B:{prompt}"]]]
        // Nothing awaited between these sends.
        let create = harness.send("session/create", ["session": "pipe", "model": model])
        let first = harness.send("session/respond", ["session": "pipe", "prompt": "first"])
        let second = harness.send("session/respond", ["session": "pipe", "prompt": "second"])
        let rename = harness.send("session/setInstructions", ["session": "pipe", "instructions": "Later."])
        #expect(try await harness.response(to: create)["result"]?["session"] == "pipe")
        #expect(try await harness.response(to: first)["result"]?["text"] == "A:first")
        #expect(try await harness.response(to: second)["result"]?["text"] == "B:second")
        #expect(try await harness.response(to: rename)["result"] == ["session": "pipe"])
    }

    @Test func cancelRunningAndQueuedTurns() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [["text": "slow", "delayMs": 5000], ["text": "slower", "delayMs": 5000]])
        let first = harness.send("session/respond", ["session": .string(id), "prompt": "one"])
        let second = harness.send("session/respond", ["session": .string(id), "prompt": "two"])
        try await Task.sleep(for: .milliseconds(100))
        let cancel = try await harness.result("session/cancel", ["session": .string(id)])
        #expect(cancel["cancelled"] == 2)
        let firstResponse = try await harness.response(to: first)
        let secondResponse = try await harness.response(to: second)
        #expect(firstResponse.errorCode == -32009)
        #expect(firstResponse.errorName == "cancelled")
        #expect(secondResponse.errorCode == -32009)
        // Cancelled turns leave no history.
        let list = try await harness.result("session/list")
        #expect(list["sessions"]?[0]?["entries"] == 0)
        #expect(list["sessions"]?[0]?["busy"] == false)
    }

    @Test func cancelWhileWaitingForClientTool() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [["toolCalls": [["name": "open_gate", "arguments": ["gate": "x"]]]]],
                                                 tools: [Self.openGate])
        let request = harness.send("session/respond", ["session": .string(id), "prompt": "Open"])
        let toolCall = try await harness.box.wait { $0["method"] == "tool/call" }
        harness.notify("session/cancel", ["session": .string(id)])
        let response = try await harness.response(to: request)
        #expect(response.errorCode == -32009)
        let cancel = try await harness.box.wait { $0["method"] == "tool/cancel" }
        #expect(cancel["params"]?["id"] == toolCall["id"])
    }

    @Test func modelErrorsMapToApplicationCodes() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [
            ["error": "guardrail_violation", "message": "Unsafe content."],
            ["error": "context_size_exceeded"],
            ["text": "Recovered."],
        ])
        let guardrail = try await harness.call("session/respond", ["session": .string(id), "prompt": "x"])
        #expect(guardrail.errorCode == -32002)
        #expect(guardrail.errorName == "guardrail_violation")
        #expect(guardrail["error"]?["message"]?.stringValue?.contains("Unsafe content.") == true)
        let context = try await harness.call("session/respond", ["session": .string(id), "prompt": "y"])
        #expect(context.errorCode == -32004)
        #expect(context.errorName == "context_size_exceeded")
        // The session is still usable afterwards.
        #expect(try await harness.result("session/respond", ["session": .string(id), "prompt": "z"])["text"] == "Recovered.")
    }

    @Test func transcriptExportAndRestore() async throws {
        let harness = BridgeHarness()
        let original = try await harness.createSession(steps: [["text": "Name's Gorm."]], instructions: "You are Gorm.")
        _ = try await harness.result("session/respond", ["session": .string(original), "prompt": "Who are you?"])
        let exported = try await harness.result("session/transcript", ["session": .string(original)])
        let transcript = try #require(exported["transcript"])

        // Round-trips through text, as a game would save it to disk.
        let saved = try JSONValue(parsing: transcript.serialized())
        let restored = try await harness.result("session/create", [
            "instructions": "You are Gorm.",
            "history": saved,
            "model": ["type": "scripted", "steps": [["template": "Again: {prompt}"]]],
        ])
        let restoredID = try #require(restored["session"])
        let list = try await harness.result("session/list")
        let entry = list["sessions"]?.arrayValue?.first { $0["session"] == restoredID }
        #expect(entry?["entries"] == 2)
        let reply = try await harness.result("session/respond", ["session": restoredID, "prompt": "Still Gorm?"])
        #expect(reply["text"] == "Again: Still Gorm?")
        let after = try await harness.result("session/transcript", ["session": restoredID])
        let entries = try await harness.result("session/list")["sessions"]?.arrayValue?.first { $0["session"] == restoredID }
        #expect(entries?["entries"] == 4)
        #expect(after["transcript"] != nil)

        // The whole session/transcript result is accepted too.
        let wrapped = try await harness.call("session/create", ["history": exported, "model": "scripted"])
        #expect(wrapped["result"] != nil)
        let garbage = try await harness.call("session/create", ["history": ["entries": 5], "model": "scripted"])
        #expect(garbage.errorCode == -32602)
    }

    @Test func mutatingSessionSettings() async throws {
        let harness = BridgeHarness()
        harness.box.setResponder { call, _ in ["output": .string("waved at \(call["arguments"]?["target"]?.stringValue ?? "?")")] }
        let id = try await harness.createSession(steps: [
            ["toolCalls": [["name": "wave", "arguments": ["target": "player"]]]],
            ["template": "{toolOutput}"],
        ], tools: [Self.openGate])
        let setTools = try await harness.result("session/setTools", [
            "session": .string(id),
            "tools": [["name": "wave", "description": "Wave at someone.",
                       "parameters": ["type": "object", "properties": ["target": ["type": "string"]]]]],
        ])
        #expect(setTools["warnings"] == [])
        _ = try await harness.result("session/setInstructions", ["session": .string(id), "instructions": "You are friendly."])
        _ = try await harness.result("session/setContextNote", ["session": .string(id), "note": "The player saved the village."])
        let list = try await harness.result("session/list")
        #expect(list["sessions"]?[0]?["tools"] == ["wave"])
        #expect(list["sessions"]?[0]?["instructions"] == "You are friendly.")

        let reply = try await harness.result("session/respond", [
            "session": .string(id), "prompt": "Greet the player", "toolChoice": ["tool": "wave"],
        ])
        #expect(reply["text"] == "waved at player")
        #expect(reply["steps"]?[0]?["enabledTools"] == ["wave"])
        #expect(reply["steps"]?[0]?["toolCallingMode"] == "required")

        _ = try await harness.result("session/reset", ["session": .string(id)])
        let afterReset = try await harness.result("session/list")
        #expect(afterReset["sessions"]?[0]?["entries"] == 0)
    }

    @Test func compactHistory() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [
            ["text": "one"], ["text": "two"], ["text": "three"],
            ["text": "The player asked three things."],
        ])
        for prompt in ["a", "b", "c"] {
            _ = try await harness.result("session/respond", ["session": .string(id), "prompt": .string(prompt)])
        }
        let compacted = try await harness.result("session/compact", ["session": .string(id), "keepRecentTurns": 1])
        #expect(compacted["summary"] == "The player asked three things.")
        let list = try await harness.result("session/list")
        #expect(list["sessions"]?[0]?["entries"] == 2)
        let nothing = try await harness.result("session/compact", ["session": .string(id), "keepRecentTurns": 5])
        #expect(nothing["summary"] == .null)
    }

    @Test func perTurnPolicyOverrides() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [["text": "no tools today"]], tools: [Self.openGate],
                                                 options: ["toolChoice": "required", "maxToolRounds": 2])
        let reply = try await harness.result("session/respond", ["session": .string(id), "prompt": "hi", "toolChoice": "none"])
        #expect(reply["steps"]?[0]?["toolCallingMode"] == "disallowed")
        #expect(reply["toolCalls"] == [])
        let unknown = try await harness.call("session/respond", ["session": .string(id), "prompt": "hi", "toolChoice": ["tool": "ghost"]])
        #expect(unknown.errorCode == -32602)
    }
}

/// A factory returning scripted models for every spec, so "system" sessions
/// work in tests without Apple Intelligence.
enum ScriptedLanguageModelFactory {
    static func make() -> any LanguageModel {
        ScriptedLanguageModel(ModelScript([]))
    }
}
