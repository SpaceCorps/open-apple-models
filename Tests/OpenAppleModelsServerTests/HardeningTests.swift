import Foundation
import FoundationModels
import OpenAppleModels
@testable import OpenAppleModelsServer
import OpenAppleModelsTesting
import Testing

/// Listener recovery, resource limits, early request screening, Host
/// validation and log hygiene.
@Suite struct HardeningTests {
    static let chatBody = #"{"messages": [{"role": "user", "content": "Hi"}]}"#

    // MARK: Listener failures

    @Test func failedListenerIsRestartedOnTheSamePort() async throws {
        let states = Recorder<ServerState>()
        let logs = Recorder<ServerLogEntry>()
        let server = try await TestServers.started(ModelScript([])) {
            $0.listenerRestartDelay = .milliseconds(10)
            $0.onStateChange = { states.append($0) }
            $0.logger = { logs.append($0) }
        }
        defer { server.stop() }
        let port = try #require(server.port)
        #expect(states.all == [.running])
        try #require(server.listeners.count == 1)

        server.listeners[0].simulateFailure("simulated failure")
        #expect(await eventually { states.all.count >= 3 })
        #expect(states.all == [.running, .restarting(attempt: 1, reason: "simulated failure"), .running])
        #expect(logs.all.contains { $0.level == .error && $0.message.contains("simulated failure") })
        #expect(server.isRunning)
        #expect(server.port == port)

        let client = try RawClient(port: port)
        client.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(client.readResponse()?.status == 200)

        server.stop()
        #expect(states.all.last == .stopped(reason: nil))
    }

    @Test func listenerThatCannotBeRestartedStopsTheServer() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oam-\(UUID().uuidString.prefix(8)).sock").path
        let states = Recorder<ServerState>()
        let server = try await TestServers.started(ModelScript([])) {
            $0.port = nil
            $0.unixSocketPath = path
            $0.listenerRestartAttempts = 2
            $0.listenerRestartDelay = .milliseconds(10)
            $0.onStateChange = { states.append($0) }
        }
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: path)
        }
        let waiter = Task { await server.waitUntilStopped() }

        // Something else takes the path, so the socket cannot be recreated.
        unlink(path)
        #expect(FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8)))
        server.listeners.first?.simulateFailure("simulated failure")

        let stopped = await eventually { !server.isRunning }
        #expect(stopped)
        if !stopped { server.stop() }
        await waiter.value  // waitUntilStopped() returns.
        #expect(server.port == nil)
        #expect(states.all.filter { if case .restarting = $0 { true } else { false } }.count == 2)
        guard case .stopped(let reason?)? = states.all.last else {
            Issue.record("expected a stop with a reason, got \(states.all)")
            return
        }
        #expect(reason.contains("not a socket"))
        // The file that took the path is left alone.
        #expect(FileManager.default.contents(atPath: path) == Data("not a socket".utf8))
    }

    @Test func startErrorsAreLocalized() {
        let error: any Error = ServerStartError("Address already in use.")
        #expect(error.localizedDescription == "Address already in use.")
    }

    // MARK: Resource limits

    @Test func connectionsBeyondTheLimitAreRefused() async throws {
        let server = try await TestServers.started(ModelScript([])) { $0.maxConnections = 2 }
        defer { server.stop() }
        let port = try #require(server.port)
        let first = try RawClient(port: port)
        let second = try RawClient(port: port)
        #expect(await eventually { server.connectionCount == 2 })

        let third = try RawClient(port: port)
        let refused = try #require(third.readResponse())
        #expect(refused.status == 503)
        #expect(refused.headers["connection"] == "close")
        #expect(refused.headers["retry-after"] == "1")
        #expect(try JSONValue(parsing: refused.text)["error"]?["code"] == "too_many_connections")
        #expect(third.isClosedByPeer())
        #expect(server.connectionCount == 2)

        first.disconnect()
        #expect(await eventually { server.connectionCount == 1 })
        let fourth = try RawClient(port: port)
        fourth.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(fourth.readResponse()?.status == 200)
        second.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(second.readResponse()?.status == 200)
    }

    @Test func requestsFailingChecksAreRejectedBeforeTheBodyIsRead() async throws {
        let server = try await TestServers.started(ModelScript([])) { $0.apiKey = "secret" }
        defer { server.stop() }
        let port = try #require(server.port)
        let json = "Content-Type: application/json\r\n"
        let cases: [(head: String, status: Int)] = [
            ("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n\(json)Expect: 100-continue\r\nContent-Length: 1000000\r\n\r\n", 401),
            ("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer wrong\r\n\(json)Transfer-Encoding: chunked\r\n\r\n", 401),
            ("POST /v1/nowhere HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\n\r\n", 404),
            ("PUT /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret\r\nContent-Length: 1000000\r\n\r\n", 405),
            ("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nOrigin: https://evil.example\r\nAuthorization: Bearer secret\r\n\(json)Content-Length: 1000000\r\n\r\n", 403),
            ("POST /v1/chat/completions HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer secret\r\n\(json)Content-Length: 1000000\r\n\r\n", 421),
            ("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret\r\nContent-Type: text/plain\r\nContent-Length: 1000000\r\n\r\n", 415),
        ]
        for (head, status) in cases {
            let client = try RawClient(port: port)
            client.send(head)  // The body is never sent.
            let start = ContinuousClock.now
            let response = try #require(client.readResponse(), "no response; expected \(status)")
            #expect(response.status == status)
            #expect(response.headers["connection"] == "close")
            #expect(client.interimStatuses.isEmpty, "a rejected request must not get 100 Continue")
            #expect(ContinuousClock.now - start < .seconds(3))
            #expect(client.isClosedByPeer())
        }
        #expect(await eventually { server.bufferedRequestBytes == 0 })
    }

    @Test func totalBufferedRequestBytesAreCapped() async throws {
        let server = try await TestServers.started(ModelScript([.text("done")])) {
            $0.maxRequestBodyBytes = 300_000
            $0.maxHeaderBytes = 4096
            $0.maxBufferedRequestBytes = 0  // Raised to one maximal request plus read-ahead.
        }
        defer { server.stop() }
        let port = try #require(server.port)
        let body = Array(#"{"messages": [{"role": "user", "content": "\#(String(repeating: "a", count: 299_000))"}]}"#.utf8)
        let head = "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        let split = body.count - 1000

        let first = try RawClient(port: port)
        first.send(head)
        first.send(Data(body[..<split]))
        #expect(await eventually { server.bufferedRequestBytes >= split })

        let second = try RawClient(port: port)
        second.send(head)
        second.send(Data(body[..<split]))
        let refused = try #require(second.readResponse())
        #expect(refused.status == 503)
        #expect(try JSONValue(parsing: refused.text)["error"]?["code"] == "server_overloaded")

        // The first request is unaffected.
        first.send(Data(body[split...]))
        let response = try #require(first.readResponse())
        #expect(response.status != 503)
        #expect(await eventually { server.bufferedRequestBytes == 0 })
    }

    // MARK: Connection handling

    @Test func clientDisconnectIsNoticedBehindPipelinedBytes() async throws {
        let server = try await TestServers.started(ModelScript([.delayed(.seconds(10), .text("never read"))]))
        defer { server.stop() }
        let client = try RawClient(port: try #require(server.port))
        client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(Self.chatBody.utf8.count)\r\n\r\n\(Self.chatBody)")
        #expect(await eventually { await server.get("/health").body["active_requests"] == 1 })
        // Part of a pipelined request arrives while the first is generated;
        // then the client goes away.
        client.send("GET /health HTTP/1.1\r\nHo")
        try await Task.sleep(for: .milliseconds(100))
        client.disconnect()
        let start = ContinuousClock.now
        #expect(await eventually { await server.get("/health").body["active_requests"] == 0 })
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await eventually { server.connectionCount == 0 })
    }

    @Test func bodylessResponsesHaveNoContentLength() async throws {
        let server = try await TestServers.started(ModelScript([])) { $0.allowedOrigins = ["http://localhost:3000"] }
        defer { server.stop() }
        let client = try RawClient(port: try #require(server.port))
        client.send("OPTIONS /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nOrigin: http://localhost:3000\r\nAccess-Control-Request-Method: POST\r\n\r\n")
        let response = try #require(client.readResponse())
        #expect(response.status == 204)
        #expect(response.headers["content-length"] == nil)
        #expect(response.headers["transfer-encoding"] == nil)
        #expect(response.headers["access-control-allow-origin"] == "http://localhost:3000")
        // Nothing followed the head: the next response parses cleanly.
        client.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(client.readResponse()?.status == 200)
    }

    // MARK: Host validation

    static func hostStatus(_ server: OpenAIServer, host: String?, target: String = "/health", transport: HTTPTransport = .tcp) async -> (Int, JSONValue?) {
        var headers = HTTPHeaders()
        if let host { headers["Host"] = host }
        let response = await server.handle(HTTPRequest(method: "GET", target: target, headers: headers, transport: transport))
        let text = String(decoding: await response.collectBody(), as: UTF8.self)
        return (response.status, try? JSONValue(parsing: text))
    }

    @Test func hostIsValidatedOnLoopbackAndUnixSockets() async {
        let server = TestServers.make(ModelScript([]))
        for host in ["localhost", "localhost:1976", "LOCALHOST", "127.0.0.1", "127.0.0.1:80", "[::1]", "[::1]:1976"] {
            #expect(await Self.hostStatus(server, host: host).0 == 200, "\(host)")
        }
        for host in ["evil.example", "evil.example:1976", "127.0.0.1.nip.io", "localhost.evil.example", "", "[::2]"] {
            let (status, body) = await Self.hostStatus(server, host: host)
            #expect(status == 421, "\(host)")
            #expect(body?["error"]?["code"] == "invalid_host")
        }
        // HTTP/1.0 without Host is not a browser; in-process calls are not checked.
        #expect(await Self.hostStatus(server, host: nil).0 == 200)
        #expect(await Self.hostStatus(server, host: "evil.example", transport: .direct).0 == 200)
        #expect(await Self.hostStatus(server, host: "evil.example", transport: .unixSocket).0 == 421)
        // An absolute-form target's authority takes precedence over Host.
        #expect(await Self.hostStatus(server, host: "localhost", target: "http://evil.example/health").0 == 421)
        #expect(await Self.hostStatus(server, host: "evil.example", target: "http://localhost:1976/health").0 == 200)

        let allowed = TestServers.make(ModelScript([])) { $0.allowedHosts = ["oam.local"] }
        #expect(await Self.hostStatus(allowed, host: "oam.local:8080").0 == 200)
        #expect(await Self.hostStatus(allowed, host: "OAM.local").0 == 200)
        #expect(await Self.hostStatus(allowed, host: "evil.example").0 == 421)
        let wildcard = TestServers.make(ModelScript([])) { $0.allowedHosts = ["*"] }
        #expect(await Self.hostStatus(wildcard, host: "evil.example").0 == 200)

        // Not bound to loopback: only checked when allowedHosts is set (always on the Unix socket).
        let public_ = TestServers.make(ModelScript([])) { $0.host = "0.0.0.0" }
        #expect(await Self.hostStatus(public_, host: "evil.example").0 == 200)
        #expect(await Self.hostStatus(public_, host: "evil.example", transport: .unixSocket).0 == 421)
        let publicAllowed = TestServers.make(ModelScript([])) {
            $0.host = "0.0.0.0"
            $0.allowedHosts = ["oam.local"]
        }
        #expect(await Self.hostStatus(publicAllowed, host: "evil.example").0 == 421)
        #expect(await Self.hostStatus(publicAllowed, host: "localhost").0 == 200)
        #expect(await Self.hostStatus(publicAllowed, host: "oam.local").0 == 200)
    }

    @Test func loopbackAddressesAndHostNames() {
        for host in ["127.0.0.1", "127.1.2.3", "::1", "[::1]", "localhost", "LocalHost", "::ffff:127.0.0.1"] {
            #expect(OpenAIServer.isLoopback(host), "\(host)")
        }
        for host in ["0.0.0.0", "::", "192.168.1.10", "example.com", "::ffff:10.0.0.1", "128.0.0.1"] {
            #expect(!OpenAIServer.isLoopback(host), "\(host)")
        }
        #expect(OpenAIServer.hostName("[::1]:8080") == "[::1]")
        #expect(OpenAIServer.hostName("Example.COM:80") == "example.com")
        #expect(OpenAIServer.hostName("localhost") == "localhost")
    }

    // MARK: Logging and availability

    @Test func accessLogEscapesControlCharacters() async throws {
        let logs = Recorder<ServerLogEntry>()
        let server = TestServers.make(ModelScript([])) { $0.logger = { logs.append($0) } }
        let response = await server.handle(HTTPRequest(method: "GET", target: "/nope%0A[info]%20GET%20/v1/models%0D%1B[31m%E2%80%AE"))
        #expect(response.status == 404)
        let line = try #require(logs.all.last?.message)
        for forbidden in ["\n", "\r", "\u{1B}", "\u{202E}"] {
            #expect(!line.contains(forbidden))
        }
        #expect(line.hasPrefix("GET /nope%0A[info] GET /v1/models%0D%1B[31m%E2%80%AE → 404"))
        #expect(ServerLogger.escapingControlCharacters("tab\there") == "tab%09here")
        #expect(ServerLogger.escapingControlCharacters("plain → ünïcode") == "plain → ünïcode")
    }

    @Test func unavailableReasonsUseSnakeCaseCodes() {
        #expect(OpenAIServer.reasonCode(.deviceNotEligible) == "device_not_eligible")
        #expect(OpenAIServer.reasonCode(.appleIntelligenceNotEnabled) == "apple_intelligence_not_enabled")
        #expect(OpenAIServer.reasonCode(.modelNotReady) == "model_not_ready")
    }
}
