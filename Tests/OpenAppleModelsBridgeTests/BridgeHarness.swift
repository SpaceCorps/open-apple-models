import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import Synchronization
import Testing

struct HarnessTimeout: Error, CustomStringConvertible {
    var description: String
}

/// Collects everything a ``BridgeEngine`` sends and lets tests wait for
/// specific messages. Optionally answers `tool/call` requests.
final class MessageBox: Sendable {
    typealias ToolResponder = @Sendable (_ call: JSONValue, _ params: JSONValue) -> JSONValue?

    private struct State {
        var lines: [String] = []
        var messages: [JSONValue] = []
        var responder: ToolResponder?
        var engine: BridgeEngine?
    }

    private let state = Mutex(State())

    func append(_ line: String) {
        let message = (try? JSONValue(parsing: line)) ?? .string("<unparseable> " + line)
        let (responder, engine) = state.withLock { state in
            state.lines.append(line)
            state.messages.append(message)
            return (state.responder, state.engine)
        }
        // Auto-answer tool calls, like a game engine would.
        if let responder, let engine, message["method"] == "tool/call", let id = message["id"],
           let params = message["params"], let reply = responder(params["call"] ?? .null, params) {
            var response: JSONObject = ["jsonrpc": "2.0", "id": id]
            if let error = reply["error"], reply.objectValue?.count == 1 {
                response["error"] = error
            } else {
                response["result"] = reply
            }
            engine.receive(JSONValue.object(response).serialized())
        }
    }

    func attach(_ engine: BridgeEngine) { state.withLock { $0.engine = engine } }
    func setResponder(_ responder: ToolResponder?) { state.withLock { $0.responder = responder } }

    var lines: [String] { state.withLock { $0.lines } }
    var messages: [JSONValue] { state.withLock { $0.messages } }

    /// Waits until a message matching `predicate` has arrived and returns it.
    func wait(timeout: Duration = .seconds(5), _ description: String = "message",
              where predicate: @Sendable (JSONValue) -> Bool) async throws -> JSONValue {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = messages.first(where: predicate) { return match }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw HarnessTimeout(description: "Timed out waiting for \(description). Received:\n" + lines.joined(separator: "\n"))
    }

    func index(where predicate: (JSONValue) -> Bool) -> Int? {
        messages.firstIndex(where: predicate)
    }
}

/// A bridge engine plus a fake peer.
final class BridgeHarness: Sendable {
    let engine: BridgeEngine
    let box: MessageBox
    private let counter = Mutex(0)

    static let testAvailability = ModelAvailability(
        available: true, contextSize: 4096, variant: "Scripted", supportedLanguages: ["en"])

    init(configure: (inout BridgeConfiguration) -> Void = { _ in }) {
        var configuration = BridgeConfiguration(modelAvailability: { BridgeHarness.testAvailability })
        configure(&configuration)
        let box = MessageBox()
        self.box = box
        engine = BridgeEngine(configuration: configuration) { line in box.append(line) }
        box.attach(engine)
    }

    func nextID() -> String {
        counter.withLock { value in
            value += 1
            return "r\(value)"
        }
    }

    /// Sends a request without waiting; returns its id.
    @discardableResult
    func send(_ method: String, _ params: JSONValue? = nil, id: String? = nil) -> String {
        let id = id ?? nextID()
        var message: JSONObject = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method)]
        if let params { message["params"] = params }
        engine.receive(JSONValue.object(message).serialized())
        return id
    }

    func notify(_ method: String, _ params: JSONValue? = nil) {
        var message: JSONObject = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        engine.receive(JSONValue.object(message).serialized())
    }

    /// Waits for the response (full message) to request `id`.
    func response(to id: String, timeout: Duration = .seconds(5)) async throws -> JSONValue {
        try await box.wait(timeout: timeout, "response to \(id)") { message in
            message["id"] == .string(id) && message["method"] == nil
        }
    }

    /// Sends a request and waits for its full response message.
    func call(_ method: String, _ params: JSONValue? = nil, timeout: Duration = .seconds(5)) async throws -> JSONValue {
        try await response(to: send(method, params), timeout: timeout)
    }

    /// Sends a request and returns its result, failing the test on an error response.
    func result(_ method: String, _ params: JSONValue? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue {
        let response = try await call(method, params)
        if let error = response["error"] {
            Issue.record("\(method) failed: \(error)", sourceLocation: sourceLocation)
        }
        return response["result"] ?? .null
    }

    /// Creates a scripted session and returns its id.
    func createSession(_ id: String? = nil, steps: [JSONValue], tools: [JSONValue]? = nil, options: JSONValue? = nil,
                       instructions: String? = nil) async throws -> String {
        var params: JSONObject = ["model": ["type": "scripted", "steps": .array(steps)]]
        if let id { params["session"] = .string(id) }
        if let tools { params["tools"] = .array(tools) }
        if let options { params["options"] = options }
        if let instructions { params["instructions"] = .string(instructions) }
        let result = try await result("session/create", .object(params))
        return try #require(result["session"]?.stringValue)
    }

    func notifications(_ method: String, requestID: String) -> [JSONValue] {
        box.messages.filter { $0["method"] == .string(method) && $0["params"]?["requestId"] == .string(requestID) }
    }
}

extension JSONValue {
    var errorCode: Int? { self["error"]?["code"]?.intValue }
    var errorName: String? { self["error"]?["data"]?["code"]?.stringValue }
}
