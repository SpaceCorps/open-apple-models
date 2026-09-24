import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import OpenAppleModels
@testable import OpenAppleModelsServer
import OpenAppleModelsTesting
import Testing

/// Builds servers backed by a scripted model.
enum TestServers {
    static func configuration(_ script: ModelScript, modify: (inout ServerConfiguration) -> Void = { _ in }) -> ServerConfiguration {
        var configuration = ServerConfiguration(
            port: 0,
            models: ["system": ScriptedLanguageModel(script)],
            modelAliases: ["gpt-4o-mini": "system"],
            toolCallDebounce: .milliseconds(40),
            retryPolicy: .none)
        modify(&configuration)
        return configuration
    }

    static func make(_ script: ModelScript, modify: (inout ServerConfiguration) -> Void = { _ in }) -> OpenAIServer {
        OpenAIServer(configuration: configuration(script, modify: modify))
    }

    static func started(_ script: ModelScript, modify: (inout ServerConfiguration) -> Void = { _ in }) async throws -> OpenAIServer {
        let server = make(script, modify: modify)
        try await server.start()
        return server
    }
}

extension ModelScript {
    /// A script for the stateless tool loop: it requests `calls` until the
    /// client has sent tool results, then replies using the latest result.
    ///
    /// Decided per request rather than by step order, because cancelling a
    /// turn that waits on client tools can let the framework start one more
    /// (immediately cancelled) model step, which would consume a scripted step.
    static func toolLoop(_ calls: [ScriptedToolCall], reply: @escaping @Sendable (String) -> String) -> ModelScript {
        ModelScript([], fallback: .dynamic { request in
            guard let output = request.toolOutputs.last.map({ Agent.text(ofSegments: $0.segments) }) else { return .toolCalls(calls) }
            // A cancelled turn's pending call resolves with an error output.
            return .text(output.hasPrefix("Error:") ? "(cancelled turn)" : reply(output))
        })
    }
}

/// A parsed JSON response from ``OpenAIServer/handle(_:)``.
struct JSONResult {
    var status: Int
    var headers: HTTPHeaders
    var body: JSONValue
    var text: String
}

extension OpenAIServer {
    /// Posts a chat completion body directly to the handler.
    func chat(_ body: String, headers: HTTPHeaders = [:]) async throws -> JSONResult {
        let response = await handle(.json("/v1/chat/completions", body: body, headers: headers))
        let data = await response.collectBody()
        let text = String(decoding: data, as: UTF8.self)
        return JSONResult(status: response.status, headers: response.headers, body: (try? JSONValue(parsing: text)) ?? .string(text), text: text)
    }

    func get(_ path: String, headers: HTTPHeaders = [:]) async -> JSONResult {
        let response = await handle(HTTPRequest(method: "GET", target: path, headers: headers))
        let data = await response.collectBody()
        let text = String(decoding: data, as: UTF8.self)
        return JSONResult(status: response.status, headers: response.headers, body: (try? JSONValue(parsing: text)) ?? .string(text), text: text)
    }
}

/// Server-sent events parsing.
enum SSE {
    /// The `data:` payloads of an event stream, in order.
    static func payloads(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").compactMap { event -> String? in
            let lines = event.split(separator: "\n").filter { $0.hasPrefix("data:") }
            guard !lines.isEmpty else { return nil }
            return lines.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        }
    }

    /// Parsed JSON chunks (everything except `[DONE]`).
    static func chunks(_ text: String) throws -> [JSONValue] {
        try payloads(text).filter { $0 != "[DONE]" }.map { try JSONValue(parsing: $0) }
    }

    /// The concatenated `delta.content` of all chunks.
    static func content(_ chunks: [JSONValue]) -> String {
        chunks.compactMap { $0["choices"]?[0]?["delta"]?["content"]?.stringValue }.joined()
    }

    static func finishReason(_ chunks: [JSONValue]) -> String? {
        chunks.compactMap { $0["choices"]?[0]?["finish_reason"]?.stringValue }.last
    }
}

/// A minimal HTTP client over POSIX sockets, for Unix sockets and
/// deliberately malformed requests.
final class RawClient {
    let fd: Int32
    private var buffer: [UInt8] = []

    struct Response {
        var status: Int
        var headers: [String: String]  // lowercased names
        var body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        setTimeout(seconds: 10)
    }

    init(unixPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in unixPath.utf8.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        setTimeout(seconds: 10)
    }

    deinit { close(fd) }

    private func setTimeout(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ text: String) { send(Data(text.utf8)) }

    func send(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    /// Reads more bytes; returns false at EOF, error or timeout.
    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<count])
        return true
    }

    /// True if the peer closed the connection (reads EOF).
    func isClosedByPeer() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { return true }
            if count < 0 { return false }
        }
    }

    /// Reads one response (Content-Length, chunked, or until close).
    func readResponse() -> Response? {
        var headEnd: Int?
        while headEnd == nil {
            if let range = findSequence([13, 10, 13, 10]) { headEnd = range } else if !fill() { return nil }
        }
        let head = String(decoding: buffer[0..<headEnd!], as: UTF8.self)
        buffer.removeFirst(headEnd! + 4)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let status = Int(statusLine.split(separator: " ")[1]) ?? 0
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if status == 100 { return readResponse() }
        var body = Data()
        if let length = headers["content-length"].flatMap(Int.init) {
            while buffer.count < length { if !fill() { break } }
            body = Data(buffer.prefix(length))
            buffer.removeFirst(min(length, buffer.count))
        } else if headers["transfer-encoding"]?.lowercased() == "chunked" {
            while true {
                var lineEnd = findSequence([13, 10])
                while lineEnd == nil { if !fill() { return Response(status: status, headers: headers, body: body) }; lineEnd = findSequence([13, 10]) }
                let size = Int(String(decoding: buffer[0..<lineEnd!], as: UTF8.self), radix: 16) ?? 0
                buffer.removeFirst(lineEnd! + 2)
                while buffer.count < size + 2 { if !fill() { break } }
                if size == 0 {
                    buffer.removeFirst(min(2, buffer.count))
                    break
                }
                body.append(contentsOf: buffer.prefix(size))
                buffer.removeFirst(min(size + 2, buffer.count))
            }
        } else {
            while fill() {}
            body = Data(buffer)
            buffer.removeAll()
        }
        return Response(status: status, headers: headers, body: body)
    }

    private func findSequence(_ sequence: [UInt8]) -> Int? {
        guard buffer.count >= sequence.count else { return nil }
        for index in 0...(buffer.count - sequence.count) where buffer[index] == sequence[0] {
            if Array(buffer[index..<index + sequence.count]) == sequence { return index }
        }
        return nil
    }
}

/// A small PNG (8×8 red pixels) as a base64 data URL, generated with ImageIO.
func samplePNGDataURL() -> String {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return "data:image/png;base64," + (data as Data).base64EncodedString()
}

/// Common tool definitions.
enum Fixtures {
    static let weatherTool = """
        {"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city.",
         "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}
        """
    static let timeTool = """
        {"type": "function", "function": {"name": "get_time", "description": "Current time in a city.",
         "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}
        """
}
