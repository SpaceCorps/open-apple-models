import Foundation

/// How a request reached the server.
public enum HTTPTransport: String, Sendable, Hashable {
    /// A TCP connection.
    case tcp
    /// A Unix domain socket connection.
    case unixSocket
    /// Passed directly to ``OpenAIServer/handle(_:)`` (tests, embedding).
    case direct
}

/// An HTTP/1.x request.
public struct HTTPRequest: Sendable, Hashable {
    /// The request method, uppercased as received (`GET`, `POST`, …).
    public var method: String
    /// The raw request target (for example `/v1/models?limit=2`).
    public var target: String
    /// The target's path component, percent-decoded.
    public var path: String
    /// The target's query string (without `?`), if any.
    public var query: String?
    /// HTTP major and minor version (1.1 → `(1, 1)`).
    public var version: HTTPVersion
    /// Request header fields (case-insensitive names).
    public var headers: HTTPHeaders
    /// The request body, de-chunked if it was sent with chunked encoding.
    public var body: Data
    /// The listener the request arrived on.
    public var transport: HTTPTransport

    /// Creates a request, splitting `target` into path and query.
    public init(
        method: String,
        target: String,
        version: HTTPVersion = .http11,
        headers: HTTPHeaders = [:],
        body: Data = Data(),
        transport: HTTPTransport = .direct
    ) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
        self.transport = transport
        (path, query) = Self.split(target)
    }

    /// Creates a JSON `POST` request (for tests and in-process use).
    public static func json(_ path: String, body: String, headers: HTTPHeaders = [:]) -> HTTPRequest {
        var headers = headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        return HTTPRequest(method: "POST", target: path, headers: headers, body: Data(body.utf8))
    }

    /// Whether the connection should stay open after the response.
    public var keepAlive: Bool {
        if headers.containsToken("close", in: "Connection") { return false }
        if version >= .http11 { return true }
        return headers.containsToken("keep-alive", in: "Connection")
    }

    static func split(_ target: String) -> (path: String, query: String?) {
        var target = Substring(target)
        // Absolute form (`http://host/path`): keep the path.
        if let scheme = target.range(of: "://"), target[..<scheme.lowerBound].allSatisfy(\.isLetter) {
            let rest = target[scheme.upperBound...]
            target = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts.first ?? "")
        let path = rawPath.removingPercentEncoding ?? rawPath
        return (path.isEmpty ? "/" : path, parts.count > 1 ? String(parts[1]) : nil)
    }
}

/// An HTTP protocol version.
public struct HTTPVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Major version (always 1 for accepted requests).
    public var major: Int
    /// Minor version (0 or 1).
    public var minor: Int

    /// Creates a version.
    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// HTTP/1.0.
    public static let http10 = HTTPVersion(major: 1, minor: 0)
    /// HTTP/1.1.
    public static let http11 = HTTPVersion(major: 1, minor: 1)

    public var description: String { "HTTP/\(major).\(minor)" }

    public static func < (lhs: HTTPVersion, rhs: HTTPVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}
