import Foundation
import OpenAppleModels
@testable import OpenAppleModelsServer
import OpenAppleModelsTesting
import Testing

/// End-to-end tests over real sockets (URLSession and raw POSIX clients).
@Suite struct SocketTests {
    static let session = URLSession(configuration: .ephemeral)

    static func post(_ port: Int, _ body: String, headers: [String: String] = [:]) async throws -> (status: Int, headers: [AnyHashable: Any], body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, http.allHeaderFields, String(decoding: data, as: UTF8.self))
    }

    @Test func toolLoopOverHTTP() async throws {
        let script = ModelScript.toolLoop([.init(name: "get_weather", arguments: ["city": "Lima"])]) { "Lima: \($0)" }
        let server = try await TestServers.started(script)
        defer { server.stop() }
        let port = try #require(server.port)
        #expect(port > 0)

        let first = try await Self.post(port, #"{"model": "system", "messages": [{"role": "user", "content": "Weather in Lima?"}], "tools": [\#(Fixtures.weatherTool)]}"#)
        #expect(first.status == 200)
        let body = try JSONValue(parsing: first.body)
        let message = try #require(body["choices"]?[0]?["message"])
        let id = try #require(message["tool_calls"]?[0]?["id"]?.stringValue)
        #expect(body["choices"]?[0]?["finish_reason"] == "tool_calls")

        let second = try await Self.post(port, """
            {"model": "system", "stream": true, "tools": [\(Fixtures.weatherTool)], "messages": [
              {"role": "user", "content": "Weather in Lima?"}, \(message.serialized()),
              {"role": "tool", "tool_call_id": "\(id)", "content": "18°C, cloudy"}]}
            """)
        #expect(second.status == 200)
        #expect((second.headers["Content-Type"] as? String)?.hasPrefix("text/event-stream") == true)
        let chunks = try SSE.chunks(second.body)
        #expect(SSE.content(chunks) == "Lima: 18°C, cloudy")
        #expect(SSE.finishReason(chunks) == "stop")
        #expect(SSE.payloads(second.body).last == "[DONE]")
    }

    @Test func streamingToolCallsOverHTTP() async throws {
        let script = ModelScript([.toolCalls([
            .init(name: "get_weather", arguments: ["city": "Oslo"]),
            .init(name: "get_time", arguments: ["city": "Oslo"]),
        ])])
        let server = try await TestServers.started(script)
        defer { server.stop() }
        let result = try await Self.post(try #require(server.port), """
            {"messages": [{"role": "user", "content": "Oslo?"}], "stream": true, "tools": [\(Fixtures.weatherTool), \(Fixtures.timeTool)]}
            """)
        let chunks = try SSE.chunks(result.body)
        let calls = chunks.compactMap { $0["choices"]?[0]?["delta"]?["tool_calls"]?.arrayValue }.flatMap { $0 }
        #expect(calls.compactMap { $0["index"]?.intValue } == [0, 1])
        #expect(calls.compactMap { $0["function"]?["name"]?.stringValue } == ["get_weather", "get_time"])
        #expect(SSE.finishReason(chunks) == "tool_calls")
    }

    @Test func errorsOverHTTP() async throws {
        let server = try await TestServers.started(ModelScript([])) { $0.apiKey = "secret" }
        defer { server.stop() }
        let port = try #require(server.port)
        let unauthorized = try await Self.post(port, #"{"messages": [{"role": "user", "content": "Hi"}]}"#)
        #expect(unauthorized.status == 401)
        let unknownModel = try await Self.post(port, #"{"model": "nope", "messages": [{"role": "user", "content": "Hi"}]}"#,
                                               headers: ["Authorization": "Bearer secret"])
        #expect(unknownModel.status == 404)
        #expect(try JSONValue(parsing: unknownModel.body)["error"]?["code"] == "model_not_found")
        let badJSON = try await Self.post(port, "{", headers: ["Authorization": "Bearer secret"])
        #expect(badJSON.status == 400)
    }

    @Test func keepAliveServesSeveralRequestsOnOneConnection() async throws {
        let server = try await TestServers.started(ModelScript([.text("one"), .text("two")]))
        defer { server.stop() }
        let client = try RawClient(port: try #require(server.port))
        let body = #"{"messages": [{"role": "user", "content": "Hi"}]}"#
        for expected in ["one", "two"] {
            client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            let response = try #require(client.readResponse())
            #expect(response.status == 200)
            #expect(response.headers["connection"] == "keep-alive")
            #expect(try JSONValue(parsing: response.text)["choices"]?[0]?["message"]?["content"]?.stringValue == expected)
        }
        // Pipelined GETs on the same connection, the last one closing it.
        client.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\nGET /v1/models HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(client.readResponse()?.status == 200)
        let last = try #require(client.readResponse())
        #expect(last.headers["connection"] == "close")
        #expect(client.isClosedByPeer())
    }

    @Test func streamedResponsesUseChunkedEncoding() async throws {
        let server = try await TestServers.started(ModelScript([.text("chunked stream", chunks: 3), .text("after")]))
        defer { server.stop() }
        let client = try RawClient(port: try #require(server.port))
        let body = #"{"messages": [{"role": "user", "content": "Hi"}], "stream": true}"#
        client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        let response = try #require(client.readResponse())
        #expect(response.headers["transfer-encoding"] == "chunked")
        #expect(SSE.content(try SSE.chunks(response.text)) == "chunked stream")
        // The connection is still usable afterwards.
        let plain = #"{"messages": [{"role": "user", "content": "Hi"}]}"#
        client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(plain.utf8.count)\r\n\r\n\(plain)")
        #expect(client.readResponse()?.status == 200)
    }

    @Test func expectContinueAndChunkedRequestBodies() async throws {
        let server = try await TestServers.started(ModelScript([.text("continued"), .text("chunked")]))
        defer { server.stop() }
        let client = try RawClient(port: try #require(server.port))
        let body = #"{"messages": [{"role": "user", "content": "Hi"}]}"#
        client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nExpect: 100-continue\r\nContent-Length: \(body.utf8.count)\r\n\r\n")
        try await Task.sleep(for: .milliseconds(100))
        client.send(body)
        #expect(client.readResponse()?.status == 200)  // readResponse skips the interim 100.

        let half = body.utf8.count / 2
        let first = String(body.prefix(half)), second = String(body.dropFirst(half))
        client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(first.utf8.count, radix: 16) + "\r\n" + first + "\r\n" + String(second.utf8.count, radix: 16) + "\r\n" + second + "\r\n0\r\n\r\n")
        let response = try #require(client.readResponse())
        #expect(try JSONValue(parsing: response.text)["choices"]?[0]?["message"]?["content"] == "chunked")
    }

    @Test func malformedAndOversizedRequestsAreRejected() async throws {
        let server = try await TestServers.started(ModelScript([])) {
            $0.maxRequestBodyBytes = 1024
            $0.maxHeaderBytes = 2048
        }
        defer { server.stop() }
        let port = try #require(server.port)

        let garbage = try RawClient(port: port)
        garbage.send("THIS IS NOT HTTP\r\n\r\n")
        let bad = try #require(garbage.readResponse())
        #expect(bad.status == 400)
        #expect(bad.headers["connection"] == "close")
        #expect(try JSONValue(parsing: bad.text)["error"]?["message"] != nil)

        let big = try RawClient(port: port)
        big.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 5000\r\n\r\n")
        #expect(big.readResponse()?.status == 413)

        let huge = try RawClient(port: port)
        huge.send("GET /health HTTP/1.1\r\nHost: localhost\r\nX-Filler: \(String(repeating: "z", count: 4000))\r\n\r\n")
        #expect(huge.readResponse()?.status == 431)

        let noHost = try RawClient(port: port)
        noHost.send("GET /health HTTP/1.1\r\n\r\n")
        #expect(noHost.readResponse()?.status == 400)
    }

    @Test func idleConnectionsAreClosed() async throws {
        let server = try await TestServers.started(ModelScript([])) { $0.idleTimeout = .milliseconds(300) }
        defer { server.stop() }
        let client = try RawClient(port: try #require(server.port))
        // Send half a request and stall (slowloris).
        client.send("GET /health HTTP/1.1\r\nHost: localhost\r\n")
        let clock = ContinuousClock()
        let start = clock.now
        #expect(client.isClosedByPeer())
        #expect(clock.now - start < .seconds(3))
    }

    @Test func unixDomainSocket() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oam-\(UUID().uuidString.prefix(8)).sock").path
        let server = try await TestServers.started(ModelScript([.text("over a unix socket")])) {
            $0.port = nil
            $0.unixSocketPath = path
        }
        defer { server.stop() }
        #expect(server.port == nil)
        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let client = try RawClient(unixPath: path)
        let body = #"{"messages": [{"role": "user", "content": "Hi"}]}"#
        client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        let response = try #require(client.readResponse())
        #expect(response.status == 200)
        #expect(try JSONValue(parsing: response.text)["choices"]?[0]?["message"]?["content"] == "over a unix socket")
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func startFailuresAreReported() async throws {
        let first = try await TestServers.started(ModelScript([]))
        defer { first.stop() }
        let clash = TestServers.make(ModelScript([])) { $0.port = first.port }
        await #expect(throws: ServerStartError.self) { try await clash.start() }
        #expect(!clash.isRunning)

        let badDefault = TestServers.make(ModelScript([])) { $0.defaultModel = "missing" }
        await #expect(throws: ServerStartError.self) { try await badDefault.start() }

        let external = try AgentTool.external(name: "x", description: "x")
        let badTool = TestServers.make(ModelScript([])) { $0.serverTools = [external] }
        await #expect(throws: ServerStartError.self) { try await badTool.start() }
    }

    @Test func clientDisconnectCancelsGeneration() async throws {
        let server = try await TestServers.started(ModelScript([.delayed(.seconds(10), .text("never read"))]))
        defer { server.stop() }
        let port = try #require(server.port)
        do {
            let client = try RawClient(port: port)
            let body = #"{"messages": [{"role": "user", "content": "Hi"}]}"#
            client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            try await Task.sleep(for: .milliseconds(200))
            #expect(await server.get("/health").body["active_requests"] == 1)
        }  // The client closes its socket here.
        let clock = ContinuousClock()
        let start = clock.now
        while await server.get("/health").body["active_requests"] != 0, clock.now - start < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(clock.now - start < .seconds(2))
        #expect(server.connectionCount == 0)
    }

    @Test func stopClosesConnectionsAndWakesWaiters() async throws {
        let server = try await TestServers.started(ModelScript([.delayed(.seconds(10), .text("never"))]))
        let port = try #require(server.port)
        let waiter = Task { await server.waitUntilStopped() }
        let client = try RawClient(port: port)
        let body = #"{"messages": [{"role": "user", "content": "Hi"}]}"#
        client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.connectionCount == 1)
        server.stop()
        await waiter.value
        #expect(client.readResponse() == nil)
        #expect(!server.isRunning)
    }
}
