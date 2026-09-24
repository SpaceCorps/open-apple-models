import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import Synchronization
import Testing

/// Regression tests for hostile or unusual input, cancellation races and
/// shutdown bounds.
@Suite(.timeLimit(.minutes(1)))
struct RobustnessTests {
    // MARK: Time limits

    @Test func outOfRangeTimeoutsAreRejectedNotTrapped() async throws {
        let harness = BridgeHarness()
        let cases: [(String, JSONValue)] = [
            ("session/create", ["options": ["toolTimeoutSeconds": 1e19]]),
            ("session/create", ["options": ["toolTimeoutSeconds": -1]]),
            ("session/create", ["tools": [["name": "a", "description": "x", "timeoutSeconds": 1e19]]]),
            ("tools/validate", ["tools": [["name": "a", "description": "x", "timeoutSeconds": 1e300]]]),
            ("npc/create", ["persona": ["name": "Gorm"], "options": ["toolTimeoutSeconds": 1e19]]),
            ("decision/decide", ["situation": "x", "options": ["a", "b"], "toolTimeoutSeconds": 1e19, "model": "scripted"]),
            ("content/generate", ["prompt": "x", "schema": ["type": "object", "properties": ["name": ["type": "string"]]],
                                  "tools": [["name": "a", "description": "x"]], "toolTimeoutSeconds": 1e19, "model": "scripted"]),
        ]
        for (method, params) in cases {
            let response = try await harness.call(method, params)
            #expect(response.errorCode == -32602, "\(method) \(params)")
        }
        let session = try await harness.createSession(steps: [])
        let setTools = try await harness.call("session/setTools", [
            "session": .string(session), "tools": [["name": "a", "description": "x", "timeoutSeconds": 1e19]],
        ])
        #expect(setTools.errorCode == -32602)

        // `1e999` parses to infinity.
        harness.engine.receive(#"{"jsonrpc":"2.0","id":"inf","method":"session/create","params":{"options":{"toolTimeoutSeconds":1e999}}}"#)
        #expect(try await harness.response(to: "inf").errorCode == -32602)

        // NaN can only come from in-process callers; it must not slip past the minimum check.
        for options: JSONValue in [["toolTimeoutSeconds": .number(.nan)], ["temperature": .number(.nan)]] {
            await #expect(throws: BridgeError.self) {
                _ = try await harness.engine.call("session/create", ["options": options])
            }
        }

        // The limits themselves are accepted, and the engine is still alive.
        _ = try await harness.result("session/create", ["options": ["toolTimeoutSeconds": .number(BridgeParams.maxTimeoutSeconds)]])
        _ = try await harness.result("session/create", ["options": ["toolTimeoutSeconds": 0]])
        #expect(try await harness.result("ping") == [:])
    }

    // MARK: Request ids

    @Test func largeNumericIDsAreEchoedExactly() async throws {
        let harness = BridgeHarness()
        for id in ["1000000000000000", "9007199254740991", "-9007199254740991", "4503599627370497"] {
            harness.engine.receive(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#)
        }
        _ = try await harness.result("ping")
        await harness.engine.flush()
        let lines = harness.box.lines
        for id in ["1000000000000000", "9007199254740991", "-9007199254740991", "4503599627370497"] {
            #expect(lines.contains(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#), "id \(id): \(lines)")
        }
    }

    @Test func numericIDsThatCannotRoundTripAreRejected() async throws {
        let harness = BridgeHarness()
        // 2^53 + 1 would come back as 2^53; 1e999 is infinite.
        for id in ["9007199254740993", "9007199254740992", "1e999", "-1e300"] {
            harness.engine.receive(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#)
        }
        await harness.engine.flush()
        let errors = harness.box.messages
        #expect(errors.count == 4)
        #expect(errors.allSatisfy { $0.errorCode == -32600 && $0["id"] == .null })
        #expect(errors.first?["error"]?["message"]?.stringValue?.contains("string id") == true)
    }

    @Test func requestIDTagsKeepLargeNumericIDsExact() async throws {
        let harness = BridgeHarness()
        harness.box.setResponder { _, _ in ["output": "opened"] }
        let session = try await harness.createSession(
            steps: [["toolCalls": [["name": "open_gate", "arguments": ["gate": "x"]]]], ["text": "done"]],
            tools: [SessionTests.openGate])
        harness.engine.receive(#"{"jsonrpc":"2.0","id":1234567890123456,"method":"session/respond","params":{"session":"\#(session)","prompt":"go","stream":true}}"#)
        _ = try await harness.box.wait { $0["id"] == 1234567890123456 && $0["method"] == nil }
        let lines = harness.box.lines
        #expect(lines.contains { $0.contains(#""method":"session/event""#) && $0.contains(#""requestId":1234567890123456"#) })
        #expect(lines.contains { $0.contains(#""method":"tool/call""#) && $0.contains(#""requestId":1234567890123456"#) })
        #expect(lines.contains { $0.hasPrefix(#"{"jsonrpc":"2.0","id":1234567890123456,"result":"#) })
        #expect(!lines.contains { $0.contains("1.234567890123456e+15") })
    }

    // MARK: In-process calls

    @Test func inProcessCallsTagEventsWithTheCallersID() async throws {
        let harness = BridgeHarness()
        let created = try await harness.engine.call("session/create", ["model": ["type": "scripted", "steps": [["text": "hi there", "chunks": 2]]]])
        let session = try #require(created["session"])
        let reply = try await harness.engine.call("session/respond", ["session": session, "prompt": "x", "stream": true], id: JSONRPCID("mine-1"))
        #expect(reply["text"] == "hi there")
        await harness.engine.flush()
        #expect(!harness.notifications("session/event", requestID: "mine-1").isEmpty)
        #expect(harness.box.messages.allSatisfy { $0["params"]?["requestId"] == "mine-1" })
    }

    // MARK: Ordering

    @Test func toolChoiceSeesToolsFromAPipelinedSetTools() async throws {
        let harness = BridgeHarness()
        harness.box.setResponder { _, _ in ["output": "waved"] }
        let session = try await harness.createSession(steps: [["toolCalls": [["name": "wave"]]], ["template": "{toolOutput}"]])
        // Nothing awaited in between: the turn must see the new tool.
        let setTools = harness.send("session/setTools", ["session": .string(session), "tools": [["name": "wave", "description": "Wave."]]])
        let respond = harness.send("session/respond", ["session": .string(session), "prompt": "hi", "toolChoice": ["tool": "wave"]])
        #expect(try await harness.response(to: setTools)["error"] == nil)
        let reply = try await harness.response(to: respond)
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["text"] == "waved")

        let ghost = try await harness.call("session/respond", ["session": .string(session), "prompt": "hi", "toolChoice": ["tool": "ghost"]])
        #expect(ghost.errorCode == -32602)
        #expect(ghost["error"]?["message"]?.stringValue?.contains("ghost") == true)
    }

    // MARK: Cancellation

    /// Three turns, then a compaction whose summary takes a while.
    private func sessionReadyToCompact(_ harness: BridgeHarness) async throws -> String {
        let id = try await harness.createSession(steps: [
            ["text": "one"], ["text": "two"], ["text": "three"],
            ["text": "The player asked three things.", "delayMs": 400],
        ])
        for prompt in ["a", "b", "c"] {
            _ = try await harness.result("session/respond", ["session": .string(id), "prompt": .string(prompt)])
        }
        return id
    }

    @Test func cancelledCompactionLeavesTheHistoryAlone() async throws {
        let harness = BridgeHarness()
        let id = try await sessionReadyToCompact(harness)
        let compact = harness.send("session/compact", ["session": .string(id), "keepRecentTurns": 1])
        try await Task.sleep(for: .milliseconds(100))
        let cancel = try await harness.result("session/cancel", ["session": .string(id)])
        #expect(cancel["cancelled"] == 1)
        let response = try await harness.response(to: compact)
        #expect(response.errorCode == -32009)
        // Well past the summary's delay: the history was not rewritten.
        try await Task.sleep(for: .milliseconds(600))
        let list = try await harness.result("session/list")
        #expect(list["sessions"]?[0]?["entries"] == 6)
        #expect(list["sessions"]?[0]?["busy"] == false)
        let transcript = try await harness.result("session/transcript", ["session": .string(id)])
        #expect(!transcript.serialized().contains("The player asked three things."))
    }

    @Test func deletingASessionCancelsItsCompaction() async throws {
        let harness = BridgeHarness()
        let id = try await sessionReadyToCompact(harness)
        let compact = harness.send("session/compact", ["session": .string(id), "keepRecentTurns": 1])
        try await Task.sleep(for: .milliseconds(100))
        _ = try await harness.result("session/delete", ["session": .string(id)])
        #expect(try await harness.response(to: compact).errorCode == -32009)
    }

    @Test func compactionStillWorks() async throws {
        let harness = BridgeHarness()
        let id = try await sessionReadyToCompact(harness)
        let compacted = try await harness.result("session/compact", ["session": .string(id), "keepRecentTurns": 1])
        #expect(compacted["summary"] == "The player asked three things.")
        let list = try await harness.result("session/list")
        #expect(list["sessions"]?[0]?["entries"] == 2)
        let transcript = try await harness.result("session/transcript", ["session": .string(id)])
        #expect(transcript.serialized().contains("The player asked three things."))
    }

    // MARK: Shutdown

    @Test func shutdownWaitIsBoundedEvenForUncancellableWork() async throws {
        let harness = BridgeHarness { $0.extensions = [StuckExtension()] }
        harness.engine.register("test/stuck") { _ in
            .deferred {
                await uncancellableSleep(seconds: 8)
                return [:]
            }
        }
        _ = harness.send("test/stuck")
        await harness.engine.flush()
        let started = ContinuousClock.now
        await harness.engine.shutdown()
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(5), "shutdown took \(elapsed)")
        #expect(harness.engine.isShutDown)
    }

    // MARK: Errors

    @Test func bridgeErrorsHaveReadableLocalizedDescriptions() {
        let error: any Error = BridgeError.invalidParams("Parameter 'x' is wrong.")
        #expect(error.localizedDescription == "Parameter 'x' is wrong.")
    }
}

/// An extension whose shutdown ignores cancellation for a long time.
private struct StuckExtension: BridgeExtension {
    func register(in registry: inout BridgeMethodRegistry, engine: BridgeEngine) {}
    func shutdown() async { await uncancellableSleep(seconds: 8) }
}

/// Sleeps without observing task cancellation.
private func uncancellableSleep(seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}
