import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import Testing

/// Runs the bridge against the real on-device model. Opt in with OAM_LIVE_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OAM_LIVE_TESTS"] == "1"), .serialized, .timeLimit(.minutes(2)))
struct LiveBridgeTests {
    /// A harness that uses the real availability check (the default configuration).
    static func liveHarness() -> BridgeHarness {
        BridgeHarness { $0.modelAvailability = { ModelAvailability.system() } }
    }

    @Test func availabilityReportsTheSystemModel() async throws {
        let harness = Self.liveHarness()
        let availability = try await harness.result("model/availability")
        print("[live] availability:", availability)
        #expect(availability["available"] == true)
        #expect((availability["contextSize"]?.intValue ?? 0) >= 4096)
    }

    @Test func clientToolRoundTripWithStreaming() async throws {
        let harness = Self.liveHarness()
        harness.box.setResponder { call, _ in
            ["output": ["opened": false, "reason": "the portcullis chain is jammed", "gate": call["arguments"]?["gate"] ?? "?"]]
        }
        let created = try await harness.result("session/create", [
            "instructions": "You are a castle guard in a game. Use tools to act. Reply in one sentence.",
            "tools": [[
                "name": "open_gate",
                "description": "Ask the game engine to open a named gate. Returns whether it opened.",
                "parameters": ["type": "object", "properties": ["gate": ["type": "string", "description": "Gate name"]], "required": ["gate"]],
            ]],
            "options": ["toolChoice": "required"],
        ])
        let session = try #require(created["session"])
        let clock = ContinuousClock()
        let start = clock.now
        let request = harness.send("session/respond", ["session": session, "prompt": "Please open the north gate.", "stream": true])
        let response = try await harness.response(to: request, timeout: .seconds(60))
        let result = try #require(response["result"], "error: \(response)")
        print("[live] tool round trip (\(clock.now - start)):", result["text"] ?? .null, result["toolCalls"] ?? .null)
        #expect((result["toolCalls"]?.arrayValue?.count ?? 0) >= 1)
        #expect(result["toolCalls"]?[0]?["call"]?["name"] == "open_gate")
        let text = result["text"]?.stringValue ?? ""
        #expect(!text.isEmpty)
        let textEvents = harness.notifications("session/event", requestID: request).filter { $0["params"]?["event"]?["type"] == "text" }
        #expect(!textEvents.isEmpty)
    }

    @Test func structuredDecision() async throws {
        let harness = Self.liveHarness()
        let created = try await harness.result("session/create", ["instructions": "You are a merchant NPC in a fantasy game."])
        let session = try #require(created["session"])
        let result = try await harness.result("session/respond", [
            "session": session,
            "prompt": "A customer offers 30 gold for a sword you sell for 45. Decide.",
            "schema": [
                "type": "object",
                "properties": [
                    "reasoning": ["type": "string", "description": "One short sentence"],
                    "choice": ["type": "string", "enum": ["sell", "refuse", "haggle"]],
                ],
                "required": ["reasoning", "choice"],
            ],
        ])
        print("[live] decision:", result["structured"] ?? .null)
        let choice = result["structured"]?["choice"]?.stringValue ?? ""
        #expect(["sell", "refuse", "haggle"].contains(choice))
    }
}
