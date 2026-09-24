import Foundation
import OpenAppleModels
import Synchronization

/// An HTTP response produced by ``OpenAIServer/handle(_:)``.
///
/// The body is either complete data or a stream of chunks (used for
/// server-sent events). Over a socket, streamed bodies are written with
/// `Transfer-Encoding: chunked` so the connection can be reused afterwards.
public struct HTTPResponse: Sendable {
    /// A response body.
    public enum Body: Sendable {
        /// A complete body, sent with `Content-Length`.
        case data(Data)
        /// A body produced incrementally (server-sent events).
        case stream(HTTPBodyStream)
    }

    /// The status code, e.g. 200.
    public var status: Int
    /// Response header fields. `Content-Length`, `Transfer-Encoding`, `Connection` and `Date` are set when written
    /// (1xx, 204 and 304 responses get neither `Content-Length` nor a body).
    public var headers: HTTPHeaders
    /// The body.
    public var body: Body

    /// Creates a response.
    public init(status: Int, headers: HTTPHeaders = [:], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A JSON response.
    public static func json(_ value: JSONValue, status: Int = 200, headers: HTTPHeaders = [:]) -> HTTPResponse {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: headers, body: .data(Data(value.serialized().utf8)))
    }

    /// The standard reason phrase for ``status``.
    public var reason: String { Self.reasonPhrase(for: status) }

    /// Whether the body is streamed.
    public var isStreaming: Bool { if case .stream = body { true } else { false } }

    /// The complete body. For a streamed body, collects every chunk first.
    public func collectBody() async -> Data {
        switch body {
        case .data(let data):
            return data
        case .stream(let stream):
            var data = Data()
            for await chunk in stream { data.append(chunk) }
            return data
        }
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 505: "HTTP Version Not Supported"
        default: "Status \(status)"
        }
    }
}

/// A streamed response body.
///
/// Iterate it to receive chunks. Call ``cancel()`` when the consumer goes away
/// (for example, when the client disconnects) so the producer stops work.
public struct HTTPBodyStream: AsyncSequence, Sendable {
    public typealias Element = Data
    public typealias AsyncIterator = AsyncStream<Data>.Iterator

    private let base: AsyncStream<Data>
    private let onCancel: Canceller

    /// Creates a stream and the continuation that feeds it. `onCancel` runs
    /// once if the consumer cancels (not when the producer finishes).
    public static func makeStream(onCancel: (@Sendable () -> Void)? = nil) -> (stream: HTTPBodyStream, continuation: AsyncStream<Data>.Continuation) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let canceller = Canceller(onCancel)
        continuation.onTermination = { termination in
            if case .cancelled = termination { canceller.fire() }
        }
        return (HTTPBodyStream(base: stream, onCancel: canceller), continuation)
    }

    public func makeAsyncIterator() -> AsyncStream<Data>.Iterator { base.makeAsyncIterator() }

    /// Tells the producer to stop.
    public func cancel() { onCancel.fire() }

    final class Canceller: Sendable {
        private let action: Mutex<(@Sendable () -> Void)?>
        init(_ action: (@Sendable () -> Void)?) { self.action = Mutex(action) }
        func fire() {
            let action = self.action.withLock { action in
                defer { action = nil }
                return action
            }
            action?()
        }
    }
}
