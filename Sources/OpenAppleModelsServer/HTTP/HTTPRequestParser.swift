import Foundation

/// A request that cannot be parsed. `status` is the HTTP status to answer
/// with; the connection is closed afterwards.
struct HTTPParseError: Error, Sendable, Equatable, CustomStringConvertible {
    var status: Int
    var message: String

    var description: String { "\(status): \(message)" }

    static func bad(_ message: String) -> HTTPParseError { HTTPParseError(status: 400, message: message) }
}

/// An incremental HTTP/1.x request parser.
///
/// Feed bytes as they arrive with ``append(_:)`` and call ``next()`` until
/// it returns `nil` (more bytes needed). Handles partial reads, pipelined
/// requests, `Content-Length` and `chunked` bodies, and enforces header and
/// body size limits. It is strict where leniency enables request smuggling
/// (conflicting lengths, whitespace before colons, obsolete line folding).
struct HTTPRequestParser {
    struct Limits: Sendable {
        var maxHeaderBytes: Int
        var maxBodyBytes: Int
    }

    enum Event: Equatable {
        /// The client sent `Expect: 100-continue` and waits for an interim
        /// `100 Continue` before sending the body.
        case expectContinue
        case request(HTTPRequest)
    }

    private struct Head {
        var method: String
        var target: String
        var version: HTTPVersion
        var headers: HTTPHeaders
    }

    private enum ChunkPhase {
        case size
        case data(remaining: Int)
        case dataTerminator
        case trailers
    }

    private enum State {
        case head(scanned: Int)
        case fixedBody(Head, length: Int)
        case chunkedBody(Head, phase: ChunkPhase, body: [UInt8])
        case failed(HTTPParseError)
    }

    let limits: Limits
    private var buffer: [UInt8] = []
    private var offset = 0
    private var state: State = .head(scanned: 0)
    private var sentContinue = false
    var transport: HTTPTransport = .tcp

    init(limits: Limits) {
        self.limits = limits
    }

    mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    /// Bytes received but not yet consumed by a complete request.
    var bufferedByteCount: Int { buffer.count - offset }

    /// True between requests with nothing buffered.
    var isIdle: Bool {
        if case .head = state, bufferedByteCount == 0 { return true }
        return false
    }

    /// Returns the next event, or `nil` if more bytes are needed.
    mutating func next() throws(HTTPParseError) -> Event? {
        do {
            let event = try step()
            compact()
            return event
        } catch {
            state = .failed(error)
            throw error
        }
    }

    private mutating func step() throws(HTTPParseError) -> Event? {
        switch state {
        case .failed(let error):
            throw error
        case .head(let scanned):
            // Ignore empty lines before a request line (RFC 9112 §2.2).
            while offset < buffer.count, buffer[offset] == 0x0D || buffer[offset] == 0x0A {
                if buffer[offset] == 0x0D, offset + 1 >= buffer.count { return nil }
                offset += 1
            }
            guard let end = findHeadEnd(from: max(offset, scanned)) else {
                if bufferedByteCount > limits.maxHeaderBytes {
                    throw HTTPParseError(status: 431, message: "Request headers exceed \(limits.maxHeaderBytes) bytes.")
                }
                state = .head(scanned: max(offset, buffer.count - 3))
                return nil
            }
            guard end.headEnd - offset <= limits.maxHeaderBytes else {
                throw HTTPParseError(status: 431, message: "Request headers exceed \(limits.maxHeaderBytes) bytes.")
            }
            let head = try parseHead(buffer[offset..<end.headEnd])
            offset = end.bodyStart
            sentContinue = false
            return try beginBody(head)
        case .fixedBody(let head, let length):
            guard bufferedByteCount >= length else { return continueIfExpected(head) }
            let body = Data(buffer[offset..<offset + length])
            offset += length
            state = .head(scanned: offset)
            return .request(makeRequest(head, body: body))
        case .chunkedBody(let head, let phase, let body):
            return try stepChunked(head, phase: phase, body: body)
        }
    }

    private mutating func beginBody(_ head: Head) throws(HTTPParseError) -> Event? {
        let lengths = head.headers.values(for: "Content-Length")
        let encodings = head.headers.values(for: "Transfer-Encoding")
        if !encodings.isEmpty {
            guard lengths.isEmpty else { throw .bad("Content-Length and Transfer-Encoding must not both be present.") }
            let codings = encodings.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard codings == ["chunked"] else {
                throw HTTPParseError(status: 501, message: "Unsupported Transfer-Encoding '\(encodings.joined(separator: ", "))'.")
            }
            state = .chunkedBody(head, phase: .size, body: [])
            return try step()
        }
        var length = 0
        if !lengths.isEmpty {
            let values = Set(lengths.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
                .map { $0.trimmingCharacters(in: .whitespaces) })
            guard values.count == 1, let value = values.first, !value.isEmpty, value.count <= 18,
                  value.allSatisfy(\.isASCIIDigit), let parsed = Int(value)
            else { throw .bad("Invalid Content-Length.") }
            length = parsed
        }
        guard length <= limits.maxBodyBytes else {
            throw HTTPParseError(status: 413, message: "Request body of \(length) bytes exceeds the limit of \(limits.maxBodyBytes) bytes.")
        }
        state = .fixedBody(head, length: length)
        return try step()
    }

    private mutating func continueIfExpected(_ head: Head) -> Event? {
        guard !sentContinue, head.version >= .http11,
              head.headers.containsToken("100-continue", in: "Expect") else { return nil }
        sentContinue = true
        return .expectContinue
    }

    private mutating func stepChunked(_ head: Head, phase: ChunkPhase, body: [UInt8]) throws(HTTPParseError) -> Event? {
        var phase = phase
        var body = body
        defer {
            if case .chunkedBody = state { state = .chunkedBody(head, phase: phase, body: body) }
        }
        while true {
            switch phase {
            case .size:
                guard let lineEnd = findLineEnd(from: offset, limit: 1024) else {
                    if bufferedByteCount > 1024 { throw .bad("Chunk size line too long.") }
                    return continueIfExpected(head)
                }
                var line = buffer[offset..<lineEnd.contentEnd]
                if let semicolon = line.firstIndex(of: UInt8(ascii: ";")) { line = line[..<semicolon] }
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text.count <= 15, let size = Int(text, radix: 16), size >= 0 else {
                    throw .bad("Invalid chunk size.")
                }
                offset = lineEnd.next
                guard body.count + size <= limits.maxBodyBytes else {
                    throw HTTPParseError(status: 413, message: "Request body exceeds the limit of \(limits.maxBodyBytes) bytes.")
                }
                phase = size == 0 ? .trailers : .data(remaining: size)
            case .data(let remaining):
                let available = min(remaining, bufferedByteCount)
                guard available > 0 else { return nil }
                body.append(contentsOf: buffer[offset..<offset + available])
                offset += available
                phase = remaining == available ? .dataTerminator : .data(remaining: remaining - available)
            case .dataTerminator:
                guard bufferedByteCount >= 1 else { return nil }
                if buffer[offset] == 0x0A {
                    offset += 1
                } else if buffer[offset] == 0x0D {
                    guard bufferedByteCount >= 2 else { return nil }
                    guard buffer[offset + 1] == 0x0A else { throw .bad("Chunk data not followed by CRLF.") }
                    offset += 2
                } else {
                    throw .bad("Chunk data not followed by CRLF.")
                }
                phase = .size
            case .trailers:
                guard let lineEnd = findLineEnd(from: offset, limit: limits.maxHeaderBytes) else {
                    if bufferedByteCount > limits.maxHeaderBytes {
                        throw HTTPParseError(status: 431, message: "Chunked trailers too large.")
                    }
                    return nil
                }
                let isEmpty = lineEnd.contentEnd == offset
                offset = lineEnd.next
                if isEmpty {
                    state = .head(scanned: offset)
                    return .request(makeRequest(head, body: Data(body)))
                }
            }
        }
    }

    private func makeRequest(_ head: Head, body: Data) -> HTTPRequest {
        HTTPRequest(method: head.method, target: head.target, version: head.version, headers: head.headers, body: body, transport: transport)
    }

    // MARK: Head parsing

    /// Finds the blank line ending the head. Accepts CRLF or bare LF endings.
    private func findHeadEnd(from start: Int) -> (headEnd: Int, bodyStart: Int)? {
        var index = start
        while index < buffer.count {
            if buffer[index] == 0x0A {
                if index + 1 < buffer.count, buffer[index + 1] == 0x0A {
                    return (index + 1, index + 2)
                }
                if index + 2 < buffer.count, buffer[index + 1] == 0x0D, buffer[index + 2] == 0x0A {
                    return (index + 1, index + 3)
                }
            }
            index += 1
        }
        return nil
    }

    private func findLineEnd(from start: Int, limit: Int) -> (contentEnd: Int, next: Int)? {
        var index = start
        let end = min(buffer.count, start + limit + 2)
        while index < end {
            if buffer[index] == 0x0A {
                let contentEnd = index > start && buffer[index - 1] == 0x0D ? index - 1 : index
                return (contentEnd, index + 1)
            }
            index += 1
        }
        return nil
    }

    private func parseHead(_ bytes: ArraySlice<UInt8>) throws(HTTPParseError) -> Head {
        var lines: [ArraySlice<UInt8>] = []
        var lineStart = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            var line = bytes[lineStart..<index]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(line)
            lineStart = index + 1
        }
        guard let requestLine = lines.first else { throw .bad("Missing request line.") }

        let parts = requestLine.split(separator: 0x20, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { throw .bad("Malformed request line.") }
        let method = String(decoding: parts[0], as: UTF8.self)
        guard method.utf8.allSatisfy(Self.isTokenByte) else { throw .bad("Malformed request method.") }
        let target = String(decoding: parts[1], as: UTF8.self)
        guard parts[1].allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { throw .bad("Malformed request target.") }
        let version = try parseVersion(parts[2])

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard let first = line.first else { continue }
            if first == 0x20 || first == 0x09 { throw .bad("Obsolete header line folding is not supported.") }
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { throw .bad("Malformed header line.") }
            let name = line[line.startIndex..<colon]
            guard !name.isEmpty, name.allSatisfy(Self.isTokenByte) else { throw .bad("Malformed header name.") }
            let rawValue = line[(colon + 1)...]
            guard !rawValue.contains(where: { $0 == 0x00 || $0 == 0x0D || $0 == 0x0A }) else {
                throw .bad("Invalid character in header value.")
            }
            let value = String(decoding: rawValue, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.add(name: String(decoding: name, as: UTF8.self), value: value)
        }
        if version >= .http11, headers.values(for: "Host").count != 1 {
            throw .bad("HTTP/1.1 requests need exactly one Host header.")
        }
        return Head(method: method, target: target, version: version, headers: headers)
    }

    private func parseVersion(_ bytes: ArraySlice<UInt8>) throws(HTTPParseError) -> HTTPVersion {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.hasPrefix("HTTP/"), text.count == 8 else { throw .bad("Malformed HTTP version.") }
        let digits = Array(text.dropFirst(5))
        guard digits[1] == ".", let major = digits[0].wholeNumberValue, let minor = digits[2].wholeNumberValue else {
            throw .bad("Malformed HTTP version.")
        }
        guard major == 1 else { throw HTTPParseError(status: 505, message: "Only HTTP/1.x is supported.") }
        return HTTPVersion(major: major, minor: minor)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default:
            "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    private mutating func compact() {
        guard offset > 0 else { return }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count <= 1 << 20)
            shift(by: offset)
            offset = 0
        } else if offset > 64 * 1024, offset > buffer.count / 2 {
            buffer.removeFirst(offset)
            shift(by: offset)
            offset = 0
        }
    }

    /// Adjusts stored scan positions after dropping `count` leading bytes.
    private mutating func shift(by count: Int) {
        if case .head(let scanned) = state { state = .head(scanned: max(0, scanned - count)) }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
