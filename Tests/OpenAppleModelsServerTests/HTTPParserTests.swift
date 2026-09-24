import Foundation
@testable import OpenAppleModelsServer
import Testing

@Suite struct HTTPParserTests {
    static let limits = HTTPRequestParser.Limits(maxHeaderBytes: 1024, maxBodyBytes: 64)

    /// Feeds `input` in pieces of `step` bytes and collects every event.
    static func parse(_ input: String, step: Int = .max, limits: HTTPRequestParser.Limits = limits) throws(HTTPParseError) -> [HTTPRequestParser.Event] {
        var parser = HTTPRequestParser(limits: limits)
        var events: [HTTPRequestParser.Event] = []
        let bytes = Array(input.utf8)
        var index = 0
        repeat {
            let end = min(bytes.count, index + max(1, min(step, bytes.count)))
            parser.append(bytes[index..<end])
            index = end
            while let event = try parser.next() { events.append(event) }
        } while index < bytes.count
        return events
    }

    static func requests(_ events: [HTTPRequestParser.Event]) -> [HTTPRequest] {
        events.compactMap { if case .request(let request) = $0 { request } else { nil } }
    }

    @Test func simpleGet() throws {
        let events = try Self.parse("GET /v1/models?limit=2 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: test\r\n\r\n")
        let request = try #require(Self.requests(events).first)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/models")
        #expect(request.query == "limit=2")
        #expect(request.version == .http11)
        #expect(request.headers["user-agent"] == "test")
        #expect(request.headers["USER-AGENT"] == "test")
        #expect(request.body.isEmpty)
        #expect(request.keepAlive)
    }

    @Test(arguments: [1, 2, 3, 7, 50])
    func partialReadsProduceTheSameRequest(step: Int) throws {
        let input = "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":\"hello\"}"
        let request = try #require(Self.requests(try Self.parse(input, step: step)).first)
        #expect(String(decoding: request.body, as: UTF8.self) == "{\"a\":\"hello\"}")
        #expect(request.headers["content-length"] == "13")
    }

    @Test func pipelinedRequests() throws {
        let input = "GET /a HTTP/1.1\r\nHost: x\r\n\r\nPOST /b HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhiGET /c HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        for step in [1, 5, 1000] {
            let requests = Self.requests(try Self.parse(input, step: step))
            #expect(requests.map(\.path) == ["/a", "/b", "/c"])
            #expect(requests[1].body == Data("hi".utf8))
            #expect(requests[2].keepAlive == false)
        }
    }

    @Test func chunkedBody() throws {
        let input = "POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: t\r\n\r\n"
        for step in [1, 4, 1000] {
            let request = try #require(Self.requests(try Self.parse(input, step: step)).first)
            #expect(String(decoding: request.body, as: UTF8.self) == "hello world")
        }
    }

    @Test func http10KeepAliveSemantics() throws {
        let plain = try #require(Self.requests(try Self.parse("GET / HTTP/1.0\r\n\r\n")).first)
        #expect(!plain.keepAlive)
        let kept = try #require(Self.requests(try Self.parse("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n")).first)
        #expect(kept.keepAlive)
    }

    @Test func bareLineFeedsAndLeadingBlankLinesAreTolerated() throws {
        let request = try #require(Self.requests(try Self.parse("\r\n\nGET /lf HTTP/1.1\nHost: x\n\n")).first)
        #expect(request.path == "/lf")
    }

    @Test func expectContinueIsSignalledBeforeTheBody() throws {
        var parser = HTTPRequestParser(limits: Self.limits)
        parser.append(Array("POST /x HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n".utf8))
        #expect(try parser.next() == .expectContinue)
        #expect(try parser.next() == nil)
        parser.append(Array("body".utf8))
        guard case .request(let request)? = try parser.next() else {
            Issue.record("expected a request")
            return
        }
        #expect(request.body == Data("body".utf8))
    }

    @Test func percentDecodedPathAndAbsoluteForm() throws {
        let request = try #require(Self.requests(try Self.parse("GET http://localhost:1976/v1/models/gpt%2D4o HTTP/1.1\r\nHost: x\r\n\r\n")).first)
        #expect(request.path == "/v1/models/gpt-4o")
    }

    // MARK: Limits and malformed input

    static func expectError(_ input: String, status: Int, limits: HTTPRequestParser.Limits = limits) {
        do {
            _ = try parse(input, limits: limits)
            Issue.record("expected \(status) for \(input.debugDescription)")
        } catch {
            #expect(error.status == status, "\(error.message)")
        }
    }

    @Test func headersTooLarge() {
        Self.expectError("GET / HTTP/1.1\r\nHost: x\r\nX-Big: \(String(repeating: "a", count: 2000))\r\n\r\n", status: 431)
        // Also detected before the head is complete.
        Self.expectError("GET / HTTP/1.1\r\nX-Big: \(String(repeating: "a", count: 2000))", status: 431)
    }

    @Test func bodyTooLarge() {
        Self.expectError("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 65\r\n\r\n", status: 413)
        Self.expectError("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n41\r\n", status: 413)
    }

    @Test(arguments: [
        "GARBAGE\r\n\r\n",
        "GET /\r\nHost: x\r\n\r\n",
        "GET  / HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nBad Header: y\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nNoColon\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n folded\r\n\r\n",
        "GET / HTTP/1.1\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabX",
    ])
    func malformedRequestsAreRejected(input: String) {
        Self.expectError(input, status: 400)
    }

    @Test func unsupportedVersionAndEncoding() {
        Self.expectError("GET / HTTP/2.0\r\nHost: x\r\n\r\n", status: 505)
        Self.expectError("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n", status: 501)
    }

    @Test func parserStaysFailedAfterAnError() {
        var parser = HTTPRequestParser(limits: Self.limits)
        parser.append(Array("BROKEN\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        #expect(throws: HTTPParseError.self) { try parser.next() }
        #expect(throws: HTTPParseError.self) { try parser.next() }
    }

    @Test func headersAreCaseInsensitiveAndOrdered() {
        var headers = HTTPHeaders()
        headers.add(name: "Set-Thing", value: "1")
        headers.add(name: "set-thing", value: "2")
        headers["Content-Type"] = "a"
        #expect(headers.values(for: "SET-THING") == ["1", "2"])
        headers["SET-THING"] = "3"
        #expect(headers.values(for: "set-thing") == ["3"])
        #expect(headers.map(\.name) == ["SET-THING", "Content-Type"])
        headers["content-type"] = nil
        #expect(!headers.contains("Content-Type"))
        let connection: HTTPHeaders = ["Connection": "keep-alive, Upgrade"]
        #expect(connection.containsToken("upgrade", in: "connection"))
    }
}
