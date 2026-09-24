import Foundation
import FoundationModels
import OpenAppleModels
@testable import OpenAppleModelsServer
import Testing

/// Drives the server with the real on-device model. Opt in with
/// `OAM_LIVE_TESTS=1`. Set `OAM_SERVE_SECONDS=<n>` (and optionally
/// `OAM_SERVE_PORT`) to keep a live server running for manual testing.
@Suite(.serialized)
struct LiveServerTests {
    static let environment = ProcessInfo.processInfo.environment
    static let live = environment["OAM_LIVE_TESTS"] == "1"

    static func liveServer(port: Int = 0) async throws -> OpenAIServer {
        let server = OpenAIServer(configuration: ServerConfiguration(
            port: port,
            modelAliases: ["gpt-4o-mini": "system"],
            logger: { entry in print("[server]", entry.message) }))
        try await server.start()
        return server
    }

    /// Runs a Python script (stdlib only) against the server and returns its output.
    static func python(_ script: String, port: Int) throws -> (status: Int32, output: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oam-live-\(UUID().uuidString.prefix(8)).py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [url.path, String(port)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(.enabled(if: live))
    func pythonToolLoop() async throws {
        let server = try await Self.liveServer()
        defer { server.stop() }
        let result = try Self.python(Self.toolLoopScript, port: try #require(server.port))
        print(result.output)
        #expect(result.status == 0)
    }

    @Test(.enabled(if: live))
    func openAIPackageIfInstalled() async throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = ["-c", "import openai"]
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else {
            print("[live] the 'openai' Python package is not installed; skipping")
            return
        }
        let server = try await Self.liveServer()
        defer { server.stop() }
        let result = try Self.python(Self.openAIScript, port: try #require(server.port))
        print(result.output)
        #expect(result.status == 0)
    }

    @Test(.enabled(if: environment["OAM_SERVE_SECONDS"] != nil))
    func serveForManualTesting() async throws {
        let port = Int(Self.environment["OAM_SERVE_PORT"] ?? "") ?? 0
        let server = try await Self.liveServer(port: port)
        print("[live] serving on port \(server.port ?? -1)")
        try await Task.sleep(for: .seconds(Int(Self.environment["OAM_SERVE_SECONDS"] ?? "60") ?? 60))
        server.stop()
    }

    // MARK: Scripts

    static let toolLoopScript = #"""
        import json, sys, time, urllib.request, urllib.error

        BASE = f"http://127.0.0.1:{sys.argv[1]}/v1"

        def post(body):
            request = urllib.request.Request(BASE + "/chat/completions", data=json.dumps(body).encode(),
                                             headers={"Content-Type": "application/json"})
            start = time.time()
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    raw = response.read().decode()
                    status = response.status
                    content_type = response.headers.get("Content-Type", "")
            except urllib.error.HTTPError as error:
                raw, status, content_type = error.read().decode(), error.code, ""
            elapsed = time.time() - start
            if content_type.startswith("text/event-stream"):
                return status, [json.loads(line[6:]) for line in raw.split("\n") if line.startswith("data: {")], raw, elapsed
            return status, json.loads(raw), raw, elapsed

        tools = [{"type": "function", "function": {
            "name": "get_weather", "description": "Get the current weather for a city.",
            "parameters": {"type": "object", "properties": {"city": {"type": "string", "description": "City name"}}, "required": ["city"]}}}]
        weather = {"Paris": {"temp_c": 14, "conditions": "light rain"}, "Tokyo": {"temp_c": 22, "conditions": "clear"}}

        def run_tool(call):
            args = json.loads(call["function"]["arguments"] or "{}")
            return json.dumps(weather.get(args.get("city", ""), {"error": "unknown city"}))

        print("== 1. tool loop (non-streaming, tool_choice=required) ==")
        messages = [{"role": "system", "content": "You are a weather assistant. Answer in one sentence."},
                    {"role": "user", "content": "What's the weather in Paris right now?"}]
        status, body, _, elapsed = post({"model": "gpt-4o-mini", "messages": messages, "tools": tools, "tool_choice": "required"})
        print(f"HTTP {status} in {elapsed:.2f}s finish_reason={body['choices'][0]['finish_reason']}")
        message = body["choices"][0]["message"]
        print("assistant tool_calls:", json.dumps(message.get("tool_calls")))
        assert status == 200 and message.get("tool_calls"), body
        messages.append(message)
        for call in message["tool_calls"]:
            output = run_tool(call)
            print(f"tool {call['function']['name']}({call['function']['arguments']}) -> {output}")
            messages.append({"role": "tool", "tool_call_id": call["id"], "content": output})
        status, body, _, elapsed = post({"model": "gpt-4o-mini", "messages": messages, "tools": tools})
        print(f"HTTP {status} in {elapsed:.2f}s finish_reason={body['choices'][0]['finish_reason']} usage={body['usage']}")
        print("assistant:", body["choices"][0]["message"]["content"])
        assert status == 200 and body["choices"][0]["finish_reason"] == "stop", body

        print("\n== 2. tool loop (streaming, tool_choice auto → named) ==")
        messages = [{"role": "user", "content": "Is it sunny in Tokyo?"}]
        status, chunks, raw, elapsed = post({"messages": messages, "tools": tools, "stream": True,
                                             "tool_choice": {"type": "function", "function": {"name": "get_weather"}}})
        calls = [c for chunk in chunks for c in chunk["choices"][0]["delta"].get("tool_calls", [])] if chunks else []
        print(f"HTTP {status} in {elapsed:.2f}s, {len(chunks)} chunks, tool_calls={json.dumps(calls)}, ends with [DONE]={raw.strip().endswith('[DONE]')}")
        assert calls, raw
        messages.append({"role": "assistant", "content": None, "tool_calls": [
            {"id": c["id"], "type": "function", "function": c["function"]} for c in calls]})
        for c in calls:
            messages.append({"role": "tool", "tool_call_id": c["id"], "content": run_tool(c)})
        status, chunks, raw, elapsed = post({"messages": messages, "tools": tools, "stream": True, "stream_options": {"include_usage": True}})
        text = "".join(chunk["choices"][0]["delta"].get("content") or "" for chunk in chunks if chunk.get("choices"))
        print(f"HTTP {status} in {elapsed:.2f}s, {len(chunks)} chunks, usage={chunks[-1].get('usage')}")
        print("assistant:", text)

        print("\n== 3. structured output (json_schema) ==")
        schema = {"type": "object", "properties": {
            "mood": {"type": "string", "enum": ["happy", "neutral", "angry"]},
            "reply": {"type": "string"}}, "required": ["mood", "reply"], "additionalProperties": False}
        status, body, _, elapsed = post({"messages": [{"role": "system", "content": "You are Gorm, a grumpy blacksmith."},
                                                      {"role": "user", "content": "Your swords are rubbish!"}],
                                         "response_format": {"type": "json_schema", "json_schema": {"name": "npc_reply", "strict": True, "schema": schema}}})
        content = body["choices"][0]["message"]["content"]
        print(f"HTTP {status} in {elapsed:.2f}s:", content)
        assert json.loads(content)["mood"] in ["happy", "neutral", "angry"]

        print("\n== 4. stop sequence + max_tokens + errors ==")
        status, body, _, elapsed = post({"messages": [{"role": "user", "content": "Count from 1 to 10 separated by commas."}], "stop": ["5"]})
        print(f"stop='5': HTTP {status} {body['choices'][0]['finish_reason']!r} {body['choices'][0]['message']['content']!r}")
        status, body, _, elapsed = post({"messages": [{"role": "user", "content": "Write a long story about a dragon."}], "max_tokens": 16})
        print(f"max_tokens=16: HTTP {status} {body['choices'][0]['finish_reason']!r} completion_tokens={body['usage']['completion_tokens']} {body['choices'][0]['message']['content']!r}")
        status, body, _, _ = post({"model": "gpt-5", "messages": [{"role": "user", "content": "Hi"}]})
        print(f"unknown model: HTTP {status} {body['error']['code']}")
        status, body, _, _ = post({"messages": [{"role": "user", "content": "Hi"}, {"role": "assistant", "content": "Hello"}]})
        print(f"trailing assistant: HTTP {status} {body['error']['code']}")
        print("\nALL LIVE CHECKS PASSED")
        """#

    static let openAIScript = #"""
        import json, sys
        from openai import OpenAI

        client = OpenAI(base_url=f"http://127.0.0.1:{sys.argv[1]}/v1", api_key="unused")
        tools = [{"type": "function", "function": {"name": "roll_dice", "description": "Roll a die with the given number of sides.",
                  "parameters": {"type": "object", "properties": {"sides": {"type": "integer"}}, "required": ["sides"]}}}]
        messages = [{"role": "user", "content": "Roll a 20-sided die for my attack."}]
        first = client.chat.completions.create(model="gpt-4o-mini", messages=messages, tools=tools, tool_choice="required")
        call = first.choices[0].message.tool_calls[0]
        print("tool call:", call.function.name, call.function.arguments)
        messages.append(first.choices[0].message.model_dump(exclude_none=True))
        messages.append({"role": "tool", "tool_call_id": call.id, "content": json.dumps({"roll": 17})})
        final = client.chat.completions.create(model="gpt-4o-mini", messages=messages, tools=tools)
        print("assistant:", final.choices[0].message.content)
        """#
}
