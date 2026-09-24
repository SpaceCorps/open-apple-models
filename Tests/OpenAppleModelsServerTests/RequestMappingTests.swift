import Foundation
import FoundationModels
import OpenAppleModels
@testable import OpenAppleModelsServer
import OpenAppleModelsTesting
import Testing

@Suite struct RequestMappingTests {
    static func map(_ messages: String) throws(OpenAIError) -> MappedConversation {
        try MessageMapper.map(try! JSONValue(parsing: messages).arrayValue!)
    }

    static func expectError(_ messages: String, code: String? = nil, param: String? = nil) {
        do {
            _ = try map(messages)
            Issue.record("expected an error for \(messages)")
        } catch {
            #expect(error.status == 400)
            if let code { #expect(error.code == code, "\(error.message)") }
            if let param { #expect(error.param == param, "\(error.message)") }
        }
    }

    static func kinds(_ entries: [Transcript.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .prompt: "prompt"
            case .response: "response"
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            case .instructions: "instructions"
            default: "other"
            }
        }
    }

    // MARK: Messages → transcript

    @Test func systemAndDeveloperBecomeInstructions() throws {
        let mapped = try Self.map("""
            [{"role": "system", "content": "Be brief."},
             {"role": "developer", "content": [{"type": "text", "text": "Speak like a pirate."}]},
             {"role": "user", "content": "Hi"}]
            """)
        #expect(mapped.instructions == "Be brief.\n\nSpeak like a pirate.")
        #expect(mapped.history.isEmpty)
        #expect(mapped.promptText == "Hi")
        #expect(!mapped.continuesAfterToolOutput)
    }

    @Test func trailingSystemMessagesDoNotEndTheConversation() throws {
        // A system message after the prompt still counts as instructions.
        let mapped = try Self.map("""
            [{"role": "system", "content": "Be brief."}, {"role": "user", "content": "Hi"},
             {"role": "developer", "content": "Answer in French."}]
            """)
        #expect(mapped.instructions == "Be brief.\n\nAnswer in French.")
        #expect(mapped.promptText == "Hi")
        #expect(mapped.history.isEmpty)
        #expect(!mapped.continuesAfterToolOutput)

        let afterTools = try Self.map("""
            [{"role": "user", "content": "Hi"},
             {"role": "assistant", "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "f", "arguments": "{}"}}]},
             {"role": "tool", "tool_call_id": "c1", "content": "x"}, {"role": "system", "content": "Be kind."}]
            """)
        #expect(afterTools.continuesAfterToolOutput)
        #expect(afterTools.instructions == "Be kind.")
        // Trailing instructions do not make a trailing assistant message valid.
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "assistant", "content": "Hello"}, {"role": "system", "content": "x"}]
            """, code: "invalid_last_message")
    }

    @Test func multiTurnHistory() throws {
        let mapped = try Self.map("""
            [{"role": "user", "content": "one"}, {"role": "assistant", "content": "uno"},
             {"role": "user", "content": "two"}, {"role": "user", "content": "three"}]
            """)
        #expect(Self.kinds(mapped.history) == ["prompt", "response"])
        // Consecutive user messages merge into one prompt.
        #expect(mapped.promptText == "two\n\nthree")
    }

    @Test func toolCallRoundTripKeepsIDsAndNames() throws {
        let mapped = try Self.map("""
            [{"role": "user", "content": "Weather in Oslo and Rome?"},
             {"role": "assistant", "content": null, "tool_calls": [
               {"id": "call_a", "type": "function", "function": {"name": "get_weather", "arguments": "{\\"city\\":\\"Oslo\\"}"}},
               {"id": "call_b", "type": "function", "function": {"name": "get_weather", "arguments": "{\\"city\\":\\"Rome\\"}"}}]},
             {"role": "tool", "tool_call_id": "call_b", "content": "sunny"},
             {"role": "tool", "tool_call_id": "call_a", "content": [{"type": "text", "text": "snow"}]}]
            """)
        #expect(mapped.continuesAfterToolOutput)
        #expect(mapped.promptText.isEmpty)
        #expect(Self.kinds(mapped.history) == ["prompt", "toolCalls", "toolOutput", "toolOutput"])
        guard case .toolCalls(let calls) = mapped.history[1] else { return }
        #expect(calls.map(\.id) == ["call_a", "call_b"])
        #expect(calls.map(\.toolName) == ["get_weather", "get_weather"])
        #expect(JSONValue(calls[0].arguments) == ["city": "Oslo"])
        // Outputs are placed in call order, each with its call's id.
        let outputs = mapped.history.compactMap { entry -> Transcript.ToolOutput? in
            if case .toolOutput(let output) = entry { output } else { nil }
        }
        #expect(outputs.map(\.id) == ["call_a", "call_b"])
        #expect(outputs.map(\.toolName) == ["get_weather", "get_weather"])
        #expect(outputs.map { Agent.text(ofSegments: $0.segments) } == ["snow", "sunny"])
    }

    @Test func toolCallIDsArePairedStrictly() {
        let call = { (id: String) in
            #"{"id": "\#(id)", "type": "function", "function": {"name": "f", "arguments": "{}"}}"#
        }
        // Duplicate ids in one assistant message, or across the conversation.
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "assistant", "tool_calls": [\(call("c1")), \(call("c1"))]},
             {"role": "tool", "tool_call_id": "c1", "content": "x"}]
            """, code: "duplicate_tool_call_id", param: "messages[1].tool_calls[1].id")
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "assistant", "tool_calls": [\(call("c1"))]},
             {"role": "tool", "tool_call_id": "c1", "content": "x"}, {"role": "user", "content": "again"},
             {"role": "assistant", "tool_calls": [\(call("c1"))]}, {"role": "tool", "tool_call_id": "c1", "content": "y"}]
            """, code: "duplicate_tool_call_id", param: "messages[4].tool_calls[0].id")
        // Two tool messages for one call.
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "assistant", "tool_calls": [\(call("c1")), \(call("c2"))]},
             {"role": "tool", "tool_call_id": "c1", "content": "x"}, {"role": "tool", "tool_call_id": "c1", "content": "y"}]
            """, code: "duplicate_tool_output", param: "messages[3].tool_call_id")
        // A late answer to a call that was already answered.
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "assistant", "tool_calls": [\(call("c1"))]},
             {"role": "tool", "tool_call_id": "c1", "content": "x"}, {"role": "user", "content": "more"},
             {"role": "tool", "tool_call_id": "c1", "content": "y"}]
            """, code: "duplicate_tool_output", param: "messages[4].tool_call_id")
        // Conversation ending before every call is answered.
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "assistant", "tool_calls": [\(call("c1")), \(call("c2"))]},
             {"role": "tool", "tool_call_id": "c2", "content": "x"}]
            """, code: "missing_tool_output")
        // Empty ids and non-object arguments.
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "assistant", "tool_calls": [\(call(""))]},
             {"role": "tool", "tool_call_id": "", "content": "x"}]
            """, param: "messages[1].tool_calls[0].id")
        Self.expectError("""
            [{"role": "user", "content": "Hi"},
             {"role": "assistant", "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "f", "arguments": "[1, 2]"}}]},
             {"role": "tool", "tool_call_id": "c1", "content": "x"}]
            """, param: "messages[1].tool_calls[0].function.arguments")
    }

    @Test func emptyArgumentsBecomeAnEmptyObject() throws {
        let mapped = try Self.map("""
            [{"role": "user", "content": "time?"},
             {"role": "assistant", "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "now", "arguments": ""}}]},
             {"role": "tool", "tool_call_id": "c1", "content": "noon"}, {"role": "user", "content": "thanks"}]
            """)
        guard case .toolCalls(let calls) = mapped.history[1] else { return }
        #expect(JSONValue(calls[0].arguments) == [:])
        #expect(mapped.promptText == "thanks")
    }

    @Test func imagesAreDecodedIntoAttachments() throws {
        let url = samplePNGDataURL()
        let mapped = try Self.map("""
            [{"role": "user", "content": [{"type": "text", "text": "What colour?"}, {"type": "image_url", "image_url": {"url": "\(url)"}}]},
             {"role": "assistant", "content": "Red."},
             {"role": "user", "content": [{"type": "image_url", "image_url": {"url": "\(url)", "detail": "low"}}, {"type": "text", "text": "And this?"}]}]
            """)
        guard case .prompt(let first) = mapped.history[0] else { Issue.record("expected a prompt"); return }
        let hasImage = first.segments.contains { if case .attachment = $0 { true } else { false } }
        #expect(hasImage)
        #expect(mapped.promptText == "And this?")
    }

    @Test func imageErrors() {
        Self.expectError("""
            [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "https://example.com/cat.png"}}]}]
            """, code: "unsupported_image_url", param: "messages[0].content[0].image_url.url")
        Self.expectError("""
            [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,bm90IGFuIGltYWdl"}}]}]
            """, code: "invalid_image")
        Self.expectError("""
            [{"role": "user", "content": [{"type": "input_audio", "input_audio": {"data": "", "format": "wav"}}]}]
            """, param: "messages[0].content[0].type")
    }

    @Test func conversationShapeErrors() {
        // Trailing assistant message (prefill) is rejected.
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "assistant", "content": "Hello"}]
            """, code: "invalid_last_message")
        // Tool output for an unknown call id.
        Self.expectError("""
            [{"role": "user", "content": "Hi"}, {"role": "tool", "tool_call_id": "nope", "content": "x"}]
            """, code: "unknown_tool_call_id", param: "messages[1].tool_call_id")
        // A tool call left unanswered before the next user message.
        Self.expectError("""
            [{"role": "user", "content": "Hi"},
             {"role": "assistant", "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "f", "arguments": "{}"}}]},
             {"role": "user", "content": "?"}]
            """, code: "missing_tool_output")
        // Invalid arguments JSON.
        Self.expectError("""
            [{"role": "user", "content": "Hi"},
             {"role": "assistant", "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "f", "arguments": "{oops"}}]},
             {"role": "tool", "tool_call_id": "c1", "content": "x"}]
            """, param: "messages[1].tool_calls[0].function.arguments")
        Self.expectError(#"[{"role": "wizard", "content": "Hi"}]"#, param: "messages[0].role")
        Self.expectError(#"[{"role": "system", "content": "Only instructions"}]"#, code: "missing_user_message")
        Self.expectError(#"[{"role": "user"}]"#, code: "missing_required_parameter")
        Self.expectError(#"[{"role": "user", "content": 42}]"#, code: "invalid_type")
    }

    // MARK: Request parameters

    static func plan(_ body: String, modify: (inout ServerConfiguration) -> Void = { _ in }) throws(OpenAIError) -> CompletionPlan {
        let configuration = TestServers.configuration(ModelScript([]), modify: modify)
        let request = try ChatCompletionRequest(body: Data(body.utf8))
        return try CompletionPlan(request: request, configuration: configuration, log: ServerLogger(sink: nil))
    }

    static func expectPlanError(_ body: String, status: Int = 400, param: String? = nil, code: String? = nil) {
        do {
            _ = try plan(body)
            Issue.record("expected an error for \(body)")
        } catch {
            #expect(error.status == status, "\(error.message)")
            if let param { #expect(error.param == param, "\(error.message)") }
            if let code { #expect(error.code == code, "\(error.message)") }
        }
    }

    static let hi = #""messages": [{"role": "user", "content": "Hi"}]"#

    @Test func toolChoiceMapping() throws {
        let tools = "\"tools\": [\(Fixtures.weatherTool), \(Fixtures.timeTool)]"
        #expect(try Self.plan("{\(Self.hi), \(tools)}").policy.choice == .auto)
        #expect(try Self.plan("{\(Self.hi), \(tools), \"tool_choice\": \"none\"}").policy.choice == ToolChoice.none)
        #expect(try Self.plan("{\(Self.hi), \(tools), \"tool_choice\": \"required\"}").policy.choice == .required)
        let named = try Self.plan("{\(Self.hi), \(tools), \"tool_choice\": {\"type\": \"function\", \"function\": {\"name\": \"get_time\"}}}")
        #expect(named.policy.choice == .tool("get_time"))
        let allowed = try Self.plan("""
            {\(Self.hi), \(tools), "tool_choice": {"type": "allowed_tools", "allowed_tools": {"mode": "required",
              "tools": [{"type": "function", "function": {"name": "get_weather"}}]}}}
            """)
        #expect(allowed.policy.enabledTools == ["get_weather"])
        #expect(allowed.policy.choice == .required)
        #expect(named.clientToolNames == ["get_weather", "get_time"])
        #expect(named.tools.allSatisfy { $0.isExternal })
    }

    @Test func toolChoiceErrors() {
        Self.expectPlanError("{\(Self.hi), \"tools\": [\(Fixtures.weatherTool)], \"tool_choice\": {\"type\": \"function\", \"function\": {\"name\": \"nope\"}}}",
                             param: "tool_choice", code: "unknown_tool")
        Self.expectPlanError("{\(Self.hi), \"tool_choice\": \"required\"}", param: "tool_choice")
        Self.expectPlanError("{\(Self.hi), \"tool_choice\": \"sometimes\"}", param: "tool_choice")
        Self.expectPlanError("{\(Self.hi), \"tools\": [\(Fixtures.weatherTool), \(Fixtures.weatherTool)]}", param: "tools[1].function.name")
        Self.expectPlanError("{\(Self.hi), \"tools\": [{\"type\": \"function\", \"function\": {\"name\": \"bad name!\"}}]}", param: "tools[0].function.name")
        Self.expectPlanError("{\(Self.hi), \"tools\": [{\"type\": \"web_search\"}]}", param: "tools[0].type")
    }

    @Test func samplingAndLimits() throws {
        let greedy = try Self.plan("{\(Self.hi), \"temperature\": 0, \"max_tokens\": 50}")
        #expect(greedy.configuration.sampling == .greedy)
        #expect(greedy.configuration.temperature == nil)
        #expect(greedy.configuration.maximumResponseTokens == 50)
        let nucleus = try Self.plan("{\(Self.hi), \"temperature\": 0.7, \"top_p\": 0.9, \"seed\": 42, \"max_tokens\": 50, \"max_completion_tokens\": 20}")
        #expect(nucleus.configuration.sampling == .random(probabilityThreshold: 0.9, seed: 42))
        #expect(nucleus.configuration.temperature == 0.7)
        #expect(nucleus.maxTokens == 20)
        let seeded = try Self.plan("{\(Self.hi), \"seed\": 7}")
        #expect(seeded.configuration.sampling == .random(probabilityThreshold: 1.0, seed: 7))
        let stops = try Self.plan("{\(Self.hi), \"stop\": [\"END\", \"\"]}")
        #expect(stops.stop == ["END"])
        #expect(try Self.plan("{\(Self.hi), \"stop\": \"X\"}").stop == ["X"])
    }

    @Test func parameterErrors() {
        Self.expectPlanError("{\(Self.hi), \"n\": 2}", param: "n")
        Self.expectPlanError("{\(Self.hi), \"stop\": [\"a\", \"b\", \"c\", \"d\", \"e\"]}", param: "stop")
        Self.expectPlanError("{\(Self.hi), \"temperature\": 3}", param: "temperature")
        Self.expectPlanError("{\(Self.hi), \"top_p\": 0}", param: "top_p")
        Self.expectPlanError("{\(Self.hi), \"max_tokens\": 0}", param: "max_tokens")
        Self.expectPlanError("{\(Self.hi), \"functions\": []}", param: "functions")
        Self.expectPlanError("{\(Self.hi), \"stream\": \"yes\"}", param: "stream", code: "invalid_type")
        Self.expectPlanError("{\"model\": \"system\"}", param: "messages", code: "missing_required_parameter")
        Self.expectPlanError("{\"model\": \"gpt-9\", \(Self.hi)}", status: 404, param: "model", code: "model_not_found")
        Self.expectPlanError("[1, 2]")
    }

    @Test func modelAliasesResolve() throws {
        #expect(try Self.plan("{\"model\": \"gpt-4o-mini\", \(Self.hi)}").modelID == "system")
        #expect(try Self.plan("{\(Self.hi)}").modelID == "system")
    }

    @Test func responseFormats() throws {
        let schema = try Self.plan("""
            {\(Self.hi), "response_format": {"type": "json_schema", "json_schema": {"name": "mood", "strict": true,
              "schema": {"type": "object", "properties": {"mood": {"type": "string", "enum": ["happy", "sad"]}}, "required": ["mood"]}}}}
            """)
        guard case .schema = schema.format else { Issue.record("expected a schema format"); return }
        let object = try Self.plan("{\(Self.hi), \"response_format\": {\"type\": \"json_object\"}}")
        guard case .jsonObject = object.format else { Issue.record("expected json_object"); return }
        #expect(object.instructions?.contains("JSON object") == true)
        Self.expectPlanError("{\(Self.hi), \"response_format\": {\"type\": \"xml\"}}", param: "response_format.type")
        Self.expectPlanError("{\(Self.hi), \"response_format\": {\"type\": \"json_schema\", \"json_schema\": {\"name\": \"x\"}}}",
                             param: "response_format.json_schema.schema")
    }

    @Test func jsonObjectExtraction() {
        #expect(ChatCompletionRunner.extractJSONObject(#"{"a": 1}"#) == #"{"a": 1}"#)
        #expect(ChatCompletionRunner.extractJSONObject("```json\n{\"a\": 1}\n```") == #"{"a": 1}"#)
        #expect(ChatCompletionRunner.extractJSONObject("Sure! {\"a\": {\"b\": 2}} Hope that helps.") == #"{"a": {"b": 2}}"#)
        #expect(ChatCompletionRunner.extractJSONObject("[1, 2]") == nil)
        #expect(ChatCompletionRunner.extractJSONObject("no json") == nil)
    }

    @Test func toolCallsAreOrderedAsGenerated() {
        let generated = Transcript.ToolCalls([
            Transcript.ToolCall(id: "m1", toolName: "b", arguments: (["x": 1] as JSONValue).generatedContent),
            Transcript.ToolCall(id: "m2", toolName: "a", arguments: (["x": 2] as JSONValue).generatedContent),
            Transcript.ToolCall(id: "m3", toolName: "a", arguments: (["x": 2] as JSONValue).generatedContent),
        ])
        let transcript = Transcript(entries: [.toolCalls(generated)])
        let arrived = [
            ToolCall(id: "c1", name: "a", arguments: ["x": 2]),
            ToolCall(id: "c2", name: "z", arguments: [:]),
            ToolCall(id: "c3", name: "b", arguments: ["x": 1]),
            ToolCall(id: "c4", name: "a", arguments: ["x": 2]),
        ]
        #expect(ChatCompletionRunner.order(arrived, as: transcript).map(\.id) == ["c3", "c1", "c4", "c2"])
        #expect(ChatCompletionRunner.order(arrived, as: Transcript(entries: [])).map(\.id) == ["c1", "c2", "c3", "c4"])
    }

    // MARK: Stop sequences

    @Test func stopFilterHoldsBackPartialMatches() {
        var filter = StopSequenceFilter(stops: ["END", "\n\n"])
        #expect(filter.update(fullText: "Hello E") == "Hello ")
        #expect(filter.update(fullText: "Hello EN") == "")
        #expect(filter.update(fullText: "Hello ENx") == "ENx")
        #expect(filter.update(fullText: "Hello ENx\n") == "")
        #expect(filter.update(fullText: "Hello ENx\nmore END tail") == "\nmore ")
        #expect(filter.stopped)
        #expect(filter.released == "Hello ENx\nmore ")
        #expect(filter.update(fullText: "anything") == "")
    }

    @Test func stopFilterFinishFlushesAndDetectsRewrites() {
        var filter = StopSequenceFilter(stops: ["STOP"])
        #expect(filter.update(fullText: "abc ST") == "abc ")
        #expect(filter.finish(fullText: "abc ST") == "ST")
        var rewritten = StopSequenceFilter(stops: [])
        #expect(rewritten.update(fullText: "first") == "first")
        #expect(rewritten.update(fullText: "second") == nil)
    }
}
