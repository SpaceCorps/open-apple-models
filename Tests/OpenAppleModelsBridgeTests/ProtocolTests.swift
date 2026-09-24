import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import Synchronization
import Testing

/// Framing, error handling and core methods.
@Suite(.timeLimit(.minutes(1)))
struct ProtocolTests {
    @Test func initializeReportsProtocolAndCapabilities() async throws {
        let harness = BridgeHarness()
        let result = try await harness.result("initialize", ["client": ["name": "unit-test", "version": "1"], "protocolVersion": "1.0"])
        #expect(result["protocolVersion"] == "1.0")
        #expect(result["server"]?["name"] == "open-apple-models")
        #expect(result["server"]?["version"] == .string(BridgeVersion.library))
        let methods = result["capabilities"]?["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for method in ["initialize", "model/availability", "session/create", "session/respond", "session/cancel",
                       "session/reset", "session/delete", "session/list", "session/transcript", "session/setInstructions",
                       "session/setTools", "session/compact", "schema/validate", "tools/validate", "shutdown"] {
            #expect(methods.contains(method), "missing \(method)")
        }
        #expect(result["capabilities"]?["clientRequests"] == ["tool/call"])
        #expect(result["model"]?["available"] == true)
        #expect(result["model"]?["contextSize"] == 4096)
        #expect(harness.engine.clientInfo?["name"] == "unit-test")
    }

    @Test func initializeRejectsIncompatibleProtocolVersion() async throws {
        let harness = BridgeHarness()
        let response = try await harness.call("initialize", ["protocolVersion": "2.0"])
        #expect(response.errorCode == -32602)
    }

    @Test func pingAndAvailability() async throws {
        let harness = BridgeHarness {
            $0.modelAvailability = { ModelAvailability(available: false, reason: "model_not_ready", contextSize: 8192) }
        }
        #expect(try await harness.result("ping") == [:])
        let availability = try await harness.result("model/availability")
        #expect(availability == ["available": false, "reason": "model_not_ready", "contextSize": 8192, "supportedLanguages": []])
    }

    @Test func parseErrorHasNullID() async throws {
        let harness = BridgeHarness()
        harness.engine.receive("{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": ")
        let response = try await harness.box.wait { $0["error"] != nil }
        #expect(response["id"] == .null)
        #expect(response.errorCode == -32700)
        #expect(response.errorName == "parse_error")
    }

    @Test func invalidMessagesAreRejected() async throws {
        let harness = BridgeHarness()
        let cases: [(String, JSONValue)] = [
            (#"{"id": 1, "method": "ping"}"#, 1),  // missing jsonrpc
            (#"[{"jsonrpc": "2.0", "id": 2, "method": "ping"}]"#, .null),  // batch
            (#"{"jsonrpc": "2.0", "id": {"x": 1}, "method": "ping"}"#, .null),  // bad id
            (#"{"jsonrpc": "2.0", "id": 4, "method": 7}"#, 4),  // bad method
            (#"{"jsonrpc": "2.0", "id": 5}"#, 5),  // neither request nor response
            ("42", .null),
        ]
        for (line, _) in cases { harness.engine.receive(line) }
        await harness.engine.flush()
        let errors = harness.box.messages.filter { $0.errorCode == -32600 }
        #expect(errors.count == cases.count)
        #expect(Set(errors.map { $0["id"] ?? .null }) == Set(cases.map(\.1)))
    }

    @Test func blankLinesAreIgnored() async throws {
        let harness = BridgeHarness()
        harness.engine.receive("")
        harness.engine.receive("   \t")
        await harness.engine.flush()
        #expect(harness.box.messages.isEmpty)
    }

    @Test func unknownMethod() async throws {
        let harness = BridgeHarness()
        let response = try await harness.call("npc/dance", ["style": "jig"])
        #expect(response.errorCode == -32601)
        #expect(response.errorName == "method_not_found")
        #expect(response["error"]?["data"]?["method"] == "npc/dance")
    }

    @Test func numericIDsAreEchoed() async throws {
        let harness = BridgeHarness()
        harness.engine.receive(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        let response = try await harness.box.wait { $0["id"] == 7 }
        #expect(response["result"] == [:])
    }

    @Test func notificationsGetNoResponse() async throws {
        let harness = BridgeHarness()
        harness.notify("ping")
        harness.notify("does/not/exist")
        harness.notify("session/respond", ["session": "missing", "prompt": "hi"])
        // A request after the notifications is answered; nothing else is.
        _ = try await harness.result("ping")
        await harness.engine.flush()
        #expect(harness.box.messages.count == 1)
    }

    @Test func invalidParams() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [])
        let missingPrompt = try await harness.call("session/respond", ["session": .string(id)])
        #expect(missingPrompt.errorCode == -32602)
        #expect(missingPrompt["error"]?["message"]?.stringValue?.contains("'prompt'") == true)

        let wrongType = try await harness.call("session/respond", ["session": .string(id), "prompt": 5])
        #expect(wrongType.errorCode == -32602)

        let positional = try await harness.call("session/list", [1, 2])
        #expect(positional.errorCode == -32602)

        let badChoice = try await harness.call("session/create", ["options": ["toolChoice": "sometimes"]])
        #expect(badChoice.errorCode == -32602)

        let unknownTool = try await harness.call("session/create", ["options": ["toolChoice": ["tool": "ghost"]]])
        #expect(unknownTool.errorCode == -32602)

        let badStep = try await harness.call("session/create", ["model": ["type": "scripted", "steps": [["dance": true]]]])
        #expect(badStep.errorCode == -32602)
        #expect(badStep["error"]?["message"]?.stringValue?.contains("model.steps[0]") == true)

        let badModel = try await harness.call("session/create", ["model": ["type": "quantum"]])
        #expect(badModel.errorCode == -32602)

        let badToolName = try await harness.call("session/create", ["tools": [["name": "open gate", "description": "x"]]])
        #expect(badToolName.errorCode == -32602)

        let badExecution = try await harness.call("session/create", ["tools": [["name": "a", "description": "x", "execution": "server"]]])
        #expect(badExecution.errorCode == -32602)
    }

    @Test func schemaValidation() async throws {
        let harness = BridgeHarness()
        let result = try await harness.result("schema/validate", [
            "schema": [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "pattern": "^[A-Z]{3}$"],
                    "mood": ["type": "string", "enum": ["calm", "angry"]],
                ],
                "required": ["code", "mood"],
            ],
        ])
        let warnings = result["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings.contains { $0.contains("pattern") })
        #expect(result["generationSchema"]?.objectValue != nil)

        let invalid = try await harness.call("schema/validate", ["schema": ["type": "quaternion"]])
        #expect(invalid.errorCode == -32007)
        #expect(invalid.errorName == "invalid_schema")
    }

    @Test func toolValidation() async throws {
        let harness = BridgeHarness()
        let result = try await harness.result("tools/validate", [
            "tools": [
                ["name": "open_gate", "description": "Open a gate.",
                 "parameters": ["type": "object", "properties": ["gate": ["type": "string", "format": "uuid"]]]],
                ["type": "function", "function": ["name": "wave", "parameters": ["type": "object", "properties": [:]]]],
            ],
        ])
        #expect(result["tools"]?[0]?["name"] == "open_gate")
        #expect(result["tools"]?[1]?["name"] == "wave")
        let warnings = result["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings.contains { $0.hasPrefix("wave:") && $0.contains("description") })

        let duplicate = try await harness.call("tools/validate", ["tools": [["name": "a"], ["name": "a"]]])
        #expect(duplicate.errorCode == -32602)
        let badSchema = try await harness.call("tools/validate", ["tools": [["name": "a", "parameters": ["type": "wat"]]]])
        #expect(badSchema.errorCode == -32007)
        #expect(badSchema["error"]?["data"]?["path"] == "tools[0].parameters")
    }

    @Test func outgoingMessagesAreSingleLineJSONRPC() async throws {
        let harness = BridgeHarness()
        let id = try await harness.createSession(steps: [["text": "Line one\nLine two", "chunks": 2]])
        _ = try await harness.result("session/respond", ["session": .string(id), "prompt": "Say two lines", "stream": true])
        await harness.engine.flush()
        for line in harness.box.lines {
            #expect(!line.contains("\n"))
            #expect((try? JSONValue(parsing: line))?["jsonrpc"] == "2.0")
        }
    }

    @Test func responsesToUnknownRequestsAreIgnored() async throws {
        let logs = LogCollector()
        let harness = BridgeHarness { $0.logger = logs.log }
        harness.engine.receive(#"{"jsonrpc":"2.0","id":"t-99","result":{"output":"stray"}}"#)
        _ = try await harness.result("ping")
        #expect(harness.box.messages.count == 1)
        #expect(logs.messages.contains { $0.contains("t-99") })
    }

    @Test func inProcessCall() async throws {
        let harness = BridgeHarness()
        #expect(try await harness.engine.call("ping") == [:])
        do {
            _ = try await harness.engine.call("nope/nope")
            Issue.record("expected an error")
        } catch {
            #expect(error.code == -32601)
        }
        let created = try await harness.engine.call("session/create", ["model": ["type": "scripted", "steps": [["text": "hi"]]]])
        let session = try #require(created["session"])
        let response = try await harness.engine.call("session/respond", ["session": session, "prompt": "hello"])
        #expect(response["text"] == "hi")
        // In-process calls are answered directly, not through `send`.
        #expect(harness.box.messages.isEmpty)
    }

    @Test func scriptedModelsCanBeDisabled() async throws {
        let harness = BridgeHarness { $0.allowsScriptedModels = false }
        let response = try await harness.call("session/create", ["model": ["type": "scripted", "steps": []]])
        #expect(response.errorCode == -32602)
        let initialize = try await harness.result("initialize")
        #expect(initialize["capabilities"]?["models"] == ["system"])
    }

    @Test func shutdownCancelsWorkAndRejectsLaterRequests() async throws {
        let fired = Mutex(false)
        let harness = BridgeHarness { $0.onShutdown = { fired.withLock { $0 = true } } }
        let id = try await harness.createSession(steps: [["text": "late", "delayMs": 5000]])
        let respond = harness.send("session/respond", ["session": .string(id), "prompt": "wait"])
        try await Task.sleep(for: .milliseconds(50))
        let shutdown = try await harness.result("shutdown")
        #expect(shutdown == [:])
        let cancelled = try await harness.response(to: respond)
        #expect(cancelled.errorCode == -32009)
        let later = try await harness.call("ping")
        #expect(later.errorCode == -32023)
        #expect(later.errorName == "shut_down")
        await harness.engine.flush()
        #expect(fired.withLock { $0 })
        #expect(harness.engine.isShutDown)
    }

    @Test func closeStopsDelivery() async throws {
        let harness = BridgeHarness()
        _ = try await harness.result("ping")
        harness.engine.close()
        let count = harness.box.messages.count
        harness.send("ping")
        harness.engine.receive("not json")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.box.messages.count == count)
        await #expect(throws: BridgeError.self) { _ = try await harness.engine.call("ping") }
    }
}

final class LogCollector: Sendable {
    private let entries = Mutex<[String]>([])
    var messages: [String] { entries.withLock { $0 } }
    var log: @Sendable (BridgeLogLevel, String) -> Void {
        { [self] level, message in entries.withLock { $0.append("\(level.rawValue): \(message)") } }
    }
}
