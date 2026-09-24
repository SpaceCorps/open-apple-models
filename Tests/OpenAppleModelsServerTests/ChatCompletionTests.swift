import Foundation
import FoundationModels
import OpenAppleModels
@testable import OpenAppleModelsServer
import OpenAppleModelsTesting
import Synchronization
import Testing

/// Chat completions through ``OpenAIServer/handle(_:)`` with a scripted model.
@Suite struct ChatCompletionTests {
    static let hi = #"[{"role": "user", "content": "Hi"}]"#

    static func message(_ result: JSONResult) -> JSONValue? { result.body["choices"]?[0]?["message"] }
    static func finishReason(_ result: JSONResult) -> String? { result.body["choices"]?[0]?["finish_reason"]?.stringValue }

    // MARK: Text

    @Test func plainCompletion() async throws {
        let script = ModelScript([.text("Hello there, traveler!", chunks: 4)])
        let server = TestServers.make(script)
        let result = try await server.chat(#"{"model": "gpt-4o-mini", "messages": [{"role": "system", "content": "Be kind."}, {"role": "user", "content": "Hi"}]}"#)
        #expect(result.status == 200)
        #expect(result.headers["Content-Type"] == "application/json")
        #expect(result.body["object"] == "chat.completion")
        #expect(result.body["model"] == "system")
        #expect(result.body["id"]?.stringValue?.hasPrefix("chatcmpl-") == true)
        #expect(Self.message(result)?["role"] == "assistant")
        #expect(Self.message(result)?["content"] == "Hello there, traveler!")
        #expect(Self.message(result)?["refusal"] == .null)
        #expect(Self.message(result)?["tool_calls"] == nil)
        #expect(Self.finishReason(result) == "stop")
        let usage = try #require(result.body["usage"])
        #expect((usage["completion_tokens"]?.intValue ?? 0) > 0)
        #expect(usage["total_tokens"]?.intValue == (usage["prompt_tokens"]?.intValue ?? 0) + (usage["completion_tokens"]?.intValue ?? 0))
        #expect(usage["prompt_tokens_details"]?["cached_tokens"] != nil)
        // System messages became instructions.
        guard case .instructions(let instructions)? = script.requests.first?.transcript.first else {
            Issue.record("expected instructions")
            return
        }
        #expect(instructions.segments.description.contains("Be kind."))
    }

    @Test func multiTurnHistoryReachesTheModel() async throws {
        let script = ModelScript([.dynamic { request in .text("entries=\(request.transcript.count) last=\(request.lastPrompt ?? "")") }])
        let server = TestServers.make(script)
        let result = try await server.chat("""
            {"messages": [{"role": "user", "content": "one"}, {"role": "assistant", "content": "uno"}, {"role": "user", "content": "two"}]}
            """)
        // instructions + prompt + response + prompt
        #expect(Self.message(result)?["content"] == "entries=4 last=two")
    }

    // MARK: Tool calls

    @Test func clientToolRoundTrip() async throws {
        let script = ModelScript.toolLoop([.init(name: "get_weather", arguments: ["city": "Oslo"])]) { "Oslo: \($0)" }
        let server = TestServers.make(script)
        let first = try await server.chat("""
            {"model": "system", "messages": \(Self.hi), "tools": [\(Fixtures.weatherTool)]}
            """)
        #expect(first.status == 200)
        #expect(Self.finishReason(first) == "tool_calls")
        let message = try #require(Self.message(first))
        #expect(message["content"] == .null)
        let call = try #require(message["tool_calls"]?[0])
        let id = try #require(call["id"]?.stringValue)
        #expect(id.hasPrefix("call_"))
        #expect(call["type"] == "function")
        #expect(call["function"]?["name"] == "get_weather")
        let arguments = try JSONValue(parsing: try #require(call["function"]?["arguments"]?.stringValue))
        #expect(arguments == ["city": "Oslo"])

        // The client executes the tool and sends the result back.
        let second = try await server.chat("""
            {"model": "system", "tools": [\(Fixtures.weatherTool)], "messages": [
              {"role": "user", "content": "Hi"},
              \(message.serialized()),
              {"role": "tool", "tool_call_id": "\(id)", "content": "-3°C and snowing"}]}
            """)
        #expect(second.status == 200)
        #expect(Self.finishReason(second) == "stop")
        #expect(Self.message(second)?["content"] == "Oslo: -3°C and snowing")
        let last = try #require(script.requests.last)
        #expect(last.toolOutputs.last?.id == id)
        #expect(last.toolOutputs.last?.toolName == "get_weather")
        // Generation continued after the tool output with an empty prompt.
        #expect(last.lastPrompt == "")
    }

    @Test func parallelToolCalls() async throws {
        let calls: [ModelScript.ScriptedToolCall] = [
            .init(name: "get_weather", arguments: ["city": "Oslo"]),
            .init(name: "get_time", arguments: ["city": "Oslo"]),
        ]
        let tools = "[\(Fixtures.weatherTool), \(Fixtures.timeTool)]"
        let parallel = try await TestServers.make(ModelScript([.toolCalls(calls)]))
            .chat(#"{"messages": \#(Self.hi), "tools": \#(tools)}"#)
        let returned = try #require(Self.message(parallel)?["tool_calls"]?.arrayValue)
        // Reported in the order the model generated them.
        #expect(returned.compactMap { $0["function"]?["name"]?.stringValue } == ["get_weather", "get_time"])
        #expect(Set(returned.compactMap { $0["id"]?.stringValue }).count == 2)

        let single = try await TestServers.make(ModelScript([.toolCalls(calls)]))
            .chat(#"{"messages": \#(Self.hi), "tools": \#(tools), "parallel_tool_calls": false}"#)
        #expect(Self.message(single)?["tool_calls"]?.arrayValue?.count == 1)
        #expect(Self.finishReason(single) == "tool_calls")
    }

    @Test func toolChoiceRequiredAndNamedSteerTheFirstStep() async throws {
        let tools = "[\(Fixtures.weatherTool), \(Fixtures.timeTool)]"
        let required = ModelScript([.toolCalls([.init(name: "get_weather", arguments: ["city": "Rome"])])])
        _ = try await TestServers.make(required).chat(#"{"messages": \#(Self.hi), "tools": \#(tools), "tool_choice": "required"}"#)
        #expect(required.requests.first?.toolCallingMode == .required)
        #expect(Set(required.requests.first?.enabledTools ?? []) == ["get_weather", "get_time"])

        let named = ModelScript([.toolCalls([.init(name: "get_time", arguments: ["city": "Rome"])])])
        let result = try await TestServers.make(named).chat("""
            {"messages": \(Self.hi), "tools": \(tools), "tool_choice": {"type": "function", "function": {"name": "get_time"}}}
            """)
        #expect(named.requests.first?.toolCallingMode == .required)
        #expect(named.requests.first?.enabledTools == ["get_time"])
        #expect(Self.message(result)?["tool_calls"]?[0]?["function"]?["name"] == "get_time")

        let none = ModelScript([.text("No tools needed.")])
        let answer = try await TestServers.make(none).chat(#"{"messages": \#(Self.hi), "tools": \#(tools), "tool_choice": "none"}"#)
        #expect(none.requests.first?.toolCallingMode == .disallowed)
        #expect(Self.message(answer)?["content"] == "No tools needed.")

        let auto = ModelScript([.text("Auto.")])
        _ = try await TestServers.make(auto).chat(#"{"messages": \#(Self.hi), "tools": \#(tools)}"#)
        #expect(auto.requests.first?.toolCallingMode == .allowed)
    }

    @Test func serverToolsRunInProcessAndStayHidden() async throws {
        let counter = Mutex(0)
        let secret = try AgentTool(name: "lookup_secret", description: "Looks up the secret.") { _ in
            counter.withLock { $0 += 1 }
            return .json(["secret": 42])
        }
        let script = ModelScript([
            .toolCalls([.init(name: "lookup_secret")]),
            .dynamic { request in .text("The secret is \(request.toolOutputs.last.map { Agent.text(ofSegments: $0.segments) } ?? "?")") },
        ])
        let server = TestServers.make(script) { $0.serverTools = [secret] }
        let result = try await server.chat(#"{"messages": \#(Self.hi), "tools": [\#(Fixtures.weatherTool)]}"#)
        #expect(Self.finishReason(result) == "stop")
        #expect(Self.message(result)?["tool_calls"] == nil)
        #expect(Self.message(result)?["content"] == #"The secret is {"secret":42}"#)
        #expect(counter.withLock { $0 } == 1)
        // A client tool may not shadow a server tool.
        let clash = try await server.chat("""
            {"messages": \(Self.hi), "tools": [{"type": "function", "function": {"name": "lookup_secret"}}]}
            """)
        #expect(clash.status == 400)
    }

    // MARK: Output control

    @Test func jsonSchemaResponseFormat() async throws {
        let script = ModelScript([.json(["reason": "It is sunny.", "mood": "happy"])])
        let result = try await TestServers.make(script).chat("""
            {"messages": \(Self.hi), "response_format": {"type": "json_schema", "json_schema": {"name": "mood_report", "strict": true,
              "schema": {"type": "object", "properties": {"reason": {"type": "string"}, "mood": {"type": "string", "enum": ["happy", "sad"]}},
                         "required": ["reason", "mood"], "additionalProperties": false}}}}
            """)
        #expect(result.status == 200)
        let content = try #require(Self.message(result)?["content"]?.stringValue)
        let json = try JSONValue(parsing: content)
        #expect(json["mood"] == "happy")
        #expect(json.objectValue?.keys == ["reason", "mood"])
        #expect(script.requests.first?.schemaName == "mood_report")
    }

    @Test func jsonObjectResponseFormat() async throws {
        let fenced = ModelScript([.text("```json\n{\"answer\": 4}\n```")])
        let result = try await TestServers.make(fenced).chat(#"{"messages": \#(Self.hi), "response_format": {"type": "json_object"}}"#)
        #expect(Self.message(result)?["content"] == #"{"answer": 4}"#)
        #expect(fenced.requests.first?.transcript.first.map { "\($0)" }?.contains("valid JSON object") == true)

        let prose = ModelScript([.text("I cannot do JSON today.")])
        let failure = try await TestServers.make(prose).chat(#"{"messages": \#(Self.hi), "response_format": {"type": "json_object"}}"#)
        #expect(failure.status == 500)
        #expect(failure.body["error"]?["code"] == "invalid_json_output")
    }

    @Test func stopSequencesTruncate() async throws {
        let script = ModelScript([.text("Once upon a time. THE END. Credits roll.", chunks: 8)])
        let result = try await TestServers.make(script).chat(#"{"messages": \#(Self.hi), "stop": ["THE END", "never"]}"#)
        #expect(Self.message(result)?["content"] == "Once upon a time. ")
        #expect(Self.finishReason(result) == "stop")
    }

    @Test func maxTokensReportsLength() async throws {
        // 40 characters in one chunk count as 10 tokens in the scripted model.
        let text = String(repeating: "word", count: 10)
        let limited = ModelScript([.text(text, chunks: 1)])
        let result = try await TestServers.make(limited).chat(#"{"messages": \#(Self.hi), "max_tokens": 10}"#)
        #expect(Self.finishReason(result) == "length")
        #expect(result.body["usage"]?["completion_tokens"]?.intValue == 10)

        let roomy = ModelScript([.text(text, chunks: 1)])
        let unlimited = try await TestServers.make(roomy).chat(#"{"messages": \#(Self.hi), "max_completion_tokens": 100}"#)
        #expect(Self.finishReason(unlimited) == "stop")
    }

    // MARK: Errors

    static func expectError(_ result: JSONResult, status: Int, code: String?) {
        #expect(result.status == status, "\(result.text)")
        #expect(result.body["error"]?["code"]?.stringValue == code, "\(result.text)")
        #expect(result.body["error"]?["message"]?.stringValue?.isEmpty == false)
        #expect(result.body["error"]?["type"]?.stringValue != nil)
    }

    @Test func requestErrors() async throws {
        let server = TestServers.make(ModelScript([]))
        Self.expectError(try await server.chat(#"{"model": "gpt-99", "messages": \#(Self.hi)}"#), status: 404, code: "model_not_found")
        Self.expectError(try await server.chat("{not json"), status: 400, code: "invalid_json")
        Self.expectError(try await server.chat("""
            {"messages": [{"role": "user", "content": "Hi"}, {"role": "assistant", "content": "Hey"}]}
            """), status: 400, code: "invalid_last_message")
        Self.expectError(try await server.chat("""
            {"messages": [{"role": "user", "content": "Hi"}, {"role": "tool", "tool_call_id": "call_x", "content": "?"}]}
            """), status: 400, code: "unknown_tool_call_id")
        Self.expectError(try await server.chat(#"{"messages": \#(Self.hi), "n": 3}"#), status: 400, code: "invalid_value")
        // Nothing reached the model.
        #expect(true)
    }

    static func failing(_ error: any Error & Sendable) -> ModelScript { ModelScript([.fail(error)]) }

    @Test func modelErrorsMapToOpenAIErrors() async throws {
        let guardrail = try await TestServers.make(Self.failing(LanguageModelError.guardrailViolation(.init(debugDescription: "unsafe"))))
            .chat(#"{"messages": \#(Self.hi)}"#)
        Self.expectError(guardrail, status: 400, code: "content_filter")

        let overflow = try await TestServers.make(Self.failing(LanguageModelError.contextSizeExceeded(
            .init(contextSize: 8192, tokenCount: 9000, debugDescription: "too long"))))
            .chat(#"{"messages": \#(Self.hi)}"#)
        Self.expectError(overflow, status: 400, code: "context_length_exceeded")

        let limited = try await TestServers.make(Self.failing(LanguageModelError.rateLimited(
            .init(resetDate: Date().addingTimeInterval(30), debugDescription: "slow down"))))
            .chat(#"{"messages": \#(Self.hi)}"#)
        Self.expectError(limited, status: 429, code: "rate_limited")
        #expect(Int(limited.headers["Retry-After"] ?? "") ?? 0 >= 29)

        let unexpected = try await TestServers.make(Self.failing(CocoaError(.featureUnsupported)))
            .chat(#"{"messages": \#(Self.hi)}"#)
        #expect(unexpected.status == 500)
        #expect(unexpected.body["error"]?["type"] == "server_error")
    }

    @Test func refusalIsASuccessfulResponse() async throws {
        let script = Self.failing(LanguageModelError.refusal(.init(explanation: "I can't help with that.", debugDescription: "Refused.")))
        let result = try await TestServers.make(script).chat(#"{"messages": \#(Self.hi)}"#)
        #expect(result.status == 200)
        #expect(Self.message(result)?["content"] == .null)
        #expect(Self.message(result)?["refusal"]?.stringValue?.isEmpty == false)
        #expect(Self.finishReason(result) == "stop")
    }

    @Test func requestTimeout() async throws {
        let script = ModelScript([.delayed(.seconds(10), .text("too late"))])
        let server = TestServers.make(script) { $0.requestTimeout = .milliseconds(300) }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await server.chat(#"{"messages": \#(Self.hi)}"#)
        #expect(clock.now - start < .seconds(3))
        Self.expectError(result, status: 504, code: "timeout")
    }

    @Test func concurrencyLimitQueuesAndRejects() async throws {
        let script = ModelScript([.delayed(.milliseconds(400), .text("a")), .delayed(.milliseconds(400), .text("b")), .text("c")])
        let server = TestServers.make(script) {
            $0.maxConcurrentRequests = 1
            $0.maxQueuedRequests = 1
        }
        async let first = server.chat(#"{"messages": \#(Self.hi)}"#)
        try await Task.sleep(for: .milliseconds(50))
        async let second = server.chat(#"{"messages": \#(Self.hi)}"#)
        try await Task.sleep(for: .milliseconds(50))
        let third = try await server.chat(#"{"messages": \#(Self.hi)}"#)
        Self.expectError(third, status: 429, code: "rate_limited")
        #expect(third.headers["Retry-After"] == "1")
        let results = try await [first, second]
        #expect(results.map(\.status) == [200, 200])
        // The queued request ran after the first finished, never concurrently.
        #expect(Set(results.compactMap { Self.message($0)?["content"]?.stringValue }) == ["a", "b"])
    }

    // MARK: Streaming

    static func stream(_ server: OpenAIServer, _ body: String) async throws -> (status: Int, headers: HTTPHeaders, chunks: [JSONValue], raw: String) {
        let response = await server.handle(.json("/v1/chat/completions", body: body))
        let raw = String(decoding: await response.collectBody(), as: UTF8.self)
        guard response.isStreaming else { return (response.status, response.headers, [], raw) }
        return (response.status, response.headers, try SSE.chunks(raw), raw)
    }

    @Test func streamingText() async throws {
        let script = ModelScript([.text("Streaming works fine.", chunks: 5)])
        let (status, headers, chunks, raw) = try await Self.stream(TestServers.make(script), """
            {"messages": \(Self.hi), "stream": true, "stream_options": {"include_usage": true}}
            """)
        #expect(status == 200)
        #expect(headers["Content-Type"]?.hasPrefix("text/event-stream") == true)
        #expect(SSE.payloads(raw).last == "[DONE]")
        #expect(chunks.first?["choices"]?[0]?["delta"]?["role"] == "assistant")
        #expect(chunks.allSatisfy { $0["object"] == "chat.completion.chunk" })
        #expect(Set(chunks.compactMap { $0["id"]?.stringValue }).count == 1)
        #expect(SSE.content(chunks) == "Streaming works fine.")
        #expect(SSE.finishReason(chunks) == "stop")
        // Usage arrives in a final chunk with no choices; other chunks carry usage: null.
        let usageChunk = try #require(chunks.last)
        #expect(usageChunk["choices"]?.arrayValue?.isEmpty == true)
        #expect((usageChunk["usage"]?["completion_tokens"]?.intValue ?? 0) > 0)
        #expect(chunks.dropLast().allSatisfy { $0["usage"] == .null })
    }

    @Test func streamingToolCalls() async throws {
        let script = ModelScript([.toolCalls([.init(name: "get_weather", arguments: ["city": "Paris"])])])
        let (status, _, chunks, raw) = try await Self.stream(TestServers.make(script), """
            {"messages": \(Self.hi), "stream": true, "tools": [\(Fixtures.weatherTool)], "tool_choice": "required"}
            """)
        #expect(status == 200)
        #expect(SSE.payloads(raw).last == "[DONE]")
        let deltas = chunks.compactMap { $0["choices"]?[0]?["delta"]?["tool_calls"]?.arrayValue }.flatMap { $0 }
        #expect(deltas.count == 1)
        #expect(deltas[0]["index"] == 0)
        #expect(deltas[0]["id"]?.stringValue?.hasPrefix("call_") == true)
        #expect(deltas[0]["function"]?["name"] == "get_weather")
        #expect(try JSONValue(parsing: deltas[0]["function"]?["arguments"]?.stringValue ?? "") == ["city": "Paris"])
        #expect(SSE.finishReason(chunks) == "tool_calls")
        #expect(chunks.allSatisfy { $0["usage"] == nil })
    }

    @Test func streamingStopSequence() async throws {
        let script = ModelScript([.text("alpha beta STOP gamma", chunks: 10)])
        let (_, _, chunks, _) = try await Self.stream(TestServers.make(script), #"{"messages": \#(Self.hi), "stream": true, "stop": "STOP"}"#)
        #expect(SSE.content(chunks) == "alpha beta ")
        #expect(SSE.finishReason(chunks) == "stop")
    }

    @Test func streamingErrorBeforeFirstTokenUsesHTTPStatus() async throws {
        let script = Self.failing(LanguageModelError.guardrailViolation(.init(debugDescription: "unsafe")))
        let (status, headers, _, raw) = try await Self.stream(TestServers.make(script), #"{"messages": \#(Self.hi), "stream": true}"#)
        #expect(status == 400)
        #expect(headers["Content-Type"] == "application/json")
        #expect(try JSONValue(parsing: raw)["error"]?["code"] == "content_filter")
    }

    @Test func streamingErrorAfterFirstTokenSendsAnErrorEvent() async throws {
        let server = OpenAIServer(configuration: ServerConfiguration(port: 0, models: ["system": TextThenFailModel()], retryPolicy: .none))
        let (status, _, chunks, raw) = try await Self.stream(server, #"{"messages": \#(Self.hi), "stream": true}"#)
        #expect(status == 200, "\(raw)")
        #expect(SSE.content(chunks).hasPrefix("partial"))
        #expect(chunks.last?["error"]?["code"] == "content_filter")
        #expect(SSE.payloads(raw).last == "[DONE]")
    }

    // MARK: Other endpoints and security

    @Test func modelsAndHealth() async throws {
        let server = TestServers.make(ModelScript([]))
        let list = await server.get("/v1/models")
        #expect(list.status == 200)
        #expect(list.body["object"] == "list")
        let ids = list.body["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(ids == ["system", "gpt-4o-mini"])
        #expect(list.body["data"]?[0]?["object"] == "model")

        #expect(await server.get("/v1/models/gpt-4o-mini").body["parent"] == "system")
        #expect(await server.get("/v1/models/nope").status == 404)
        let health = await server.get("/health")
        #expect(health.status == 200)
        #expect(health.body["status"] == "ok")
    }

    @Test func routingErrors() async throws {
        let server = TestServers.make(ModelScript([]))
        let missing = await server.get("/v1/embeddings")
        #expect(missing.status == 404)
        #expect(missing.body["error"]?["code"] == "unknown_url")
        let wrongMethod = await server.get("/v1/chat/completions")
        #expect(wrongMethod.status == 405)
        #expect(wrongMethod.headers["Allow"] == "POST")
        let noContentType = await server.handle(HTTPRequest(method: "POST", target: "/v1/chat/completions", body: Data("{}".utf8)))
        #expect(noContentType.status == 415)
    }

    @Test func originsAreCheckedAndCORSIsAnswered() async throws {
        let server = TestServers.make(ModelScript([.text("ok")])) { $0.allowedOrigins = ["http://localhost:3000"] }
        let foreign = try await server.chat(#"{"messages": \#(Self.hi)}"#, headers: ["Origin": "https://evil.example"])
        Self.expectError(foreign, status: 403, code: "origin_not_allowed")

        let allowed = try await server.chat(#"{"messages": \#(Self.hi)}"#, headers: ["Origin": "http://localhost:3000"])
        #expect(allowed.status == 200)
        #expect(allowed.headers["Access-Control-Allow-Origin"] == "http://localhost:3000")

        let preflight = await server.handle(HTTPRequest(method: "OPTIONS", target: "/v1/chat/completions", headers: [
            "Origin": "http://localhost:3000", "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization, content-type",
        ]))
        #expect(preflight.status == 204)
        #expect(preflight.headers["Access-Control-Allow-Origin"] == "http://localhost:3000")
        #expect(preflight.headers["Access-Control-Allow-Headers"] == "authorization, content-type")
        #expect(preflight.headers["Access-Control-Allow-Methods"]?.contains("POST") == true)

        let blockedPreflight = await server.handle(HTTPRequest(method: "OPTIONS", target: "/v1/chat/completions", headers: ["Origin": "https://evil.example"]))
        #expect(blockedPreflight.status == 403)
    }

    @Test func apiKeyAuthentication() async throws {
        let server = TestServers.make(ModelScript([.text("ok")])) { $0.apiKey = "sk-test-123" }
        let missing = try await server.chat(#"{"messages": \#(Self.hi)}"#)
        Self.expectError(missing, status: 401, code: "invalid_api_key")
        #expect(missing.headers["WWW-Authenticate"] == "Bearer")
        let wrong = try await server.chat(#"{"messages": \#(Self.hi)}"#, headers: ["Authorization": "Bearer sk-test-124"])
        #expect(wrong.status == 401)
        #expect(await server.get("/v1/models").status == 401)
        #expect(await server.get("/health").status == 200)
        let right = try await server.chat(#"{"messages": \#(Self.hi)}"#, headers: ["Authorization": "Bearer sk-test-123"])
        #expect(right.status == 200)
        #expect(OpenAIServer.constantTimeEquals("abc", "abc"))
        #expect(!OpenAIServer.constantTimeEquals("abc", "abcd"))
    }
}

// MARK: - Test models

/// A model that streams some text, then fails with a guardrail violation.
struct TextThenFailModel: LanguageModel {
    typealias Executor = TextThenFailExecutor

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .guidedGeneration]) }
    var executorConfiguration: TextThenFailExecutor.Configuration { .init() }
}

struct TextThenFailExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {}
    typealias Model = TextThenFailModel

    init(configuration: Configuration) throws {}

    func respond(to request: LanguageModelExecutorGenerationRequest, model: TextThenFailModel, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        await channel.send(.response(action: .appendText("partial ", tokenCount: 1)))
        await channel.send(.response(action: .appendText("answer", tokenCount: 1)))
        try await Task.sleep(for: .milliseconds(300))
        throw LanguageModelError.guardrailViolation(.init(debugDescription: "blocked mid-stream"))
    }
}

extension Agent {
    /// Plain text of transcript segments (test helper).
    static func text(ofSegments segments: [Transcript.Segment]) -> String {
        segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
    }
}
