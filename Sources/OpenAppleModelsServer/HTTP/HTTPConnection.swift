import Foundation
import Network
import Synchronization

/// Serves HTTP/1.1 requests on one accepted connection: parses requests
/// (including pipelined ones), screens each request head before its body is
/// read, passes complete requests to the handler, writes responses
/// (streamed bodies use chunked transfer encoding), honours keep-alive and
/// closes idle or slow connections.
final class HTTPConnection: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    /// Inspects a request head (empty body) before the body is read. A
    /// response rejects the request: it is sent and the connection closed.
    typealias Screen = @Sendable (HTTPRequest) -> HTTPResponse?

    struct Settings: Sendable {
        var limits: HTTPRequestParser.Limits
        /// Maximum time to wait for a complete request (covers keep-alive
        /// idling and clients that trickle bytes).
        var idleTimeout: Duration
        /// Memory for buffered requests, shared by all connections.
        var budget: ByteBudget
    }

    let id: Int
    private let connection: NWConnection
    private let transport: HTTPTransport
    private let settings: Settings
    private let screen: Screen
    private let handler: Handler
    private let log: ServerLogger
    private let queue: DispatchQueue
    private let reader: ConnectionReader
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let timer = Mutex<Task<Void, Never>?>(nil)

    init(id: Int, connection: NWConnection, transport: HTTPTransport, settings: Settings, log: ServerLogger,
         screen: @escaping Screen, handler: @escaping Handler) {
        self.id = id
        self.connection = connection
        self.transport = transport
        self.settings = settings
        self.screen = screen
        self.handler = handler
        self.log = log
        self.queue = DispatchQueue(label: "open-apple-models.http.connection.\(id)")
        self.reader = ConnectionReader(connection: connection)
    }

    /// Starts serving; with `rejection`, only sends that response and
    /// closes. `onClose` runs once when the connection ends.
    func start(rejecting rejection: HTTPResponse? = nil, onClose: @escaping @Sendable () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                // The peer went away: stop any in-flight generation.
                self?.task.withLock { $0?.cancel() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        reader.start()
        let serving = Task { [self] in
            if let rejection {
                armTimer(until: .now + .seconds(2))
                if await write(rejection, version: .http11, method: "GET", keepAlive: false) { await closeGracefully() }
            } else {
                await serve()
            }
            disarmTimer()
            connection.cancel()
            onClose()
        }
        task.withLock { $0 = serving }
    }

    /// Closes the connection immediately.
    func cancel() {
        task.withLock { $0?.cancel() }
        connection.cancel()
    }

    // MARK: Serving

    private func serve() async {
        var parser = HTTPRequestParser(limits: settings.limits)
        parser.transport = transport
        var peerClosed = false
        // Bytes this connection holds in the shared budget.
        var reserved = 0
        let budget = settings.budget
        defer { budget.release(reserved) }

        /// Brings the reservation in line with the parser's buffers plus the
        /// body of a request being handled. False if the budget is exhausted.
        func account(inFlight: Int = 0) -> Bool {
            let needed = parser.retainedByteCount + inFlight
            if needed <= reserved {
                budget.release(reserved - needed)
            } else if !budget.reserve(needed - reserved) {
                return false
            }
            reserved = needed
            return true
        }

        armTimer()
        while !Task.isCancelled {
            let event: HTTPRequestParser.Event?
            do {
                event = try parser.next()
            } catch {
                log.log(.info, "connection \(id): rejecting malformed request (\(error.status)): \(error.message)")
                let response = OpenAIError(status: error.status, message: error.message, type: "invalid_request_error", code: "malformed_request").response
                await reject(response, version: .http11, method: "GET")
                return
            }
            guard let event else {
                if peerClosed { return }
                let (data, ended) = await reader.read()
                parser.append(data)
                if ended { peerClosed = true }
                guard account() else {
                    await rejectOverloaded()
                    return
                }
                continue
            }
            switch event {
            case .head(let head):
                if let rejection = screen(head) {
                    await reject(rejection, version: head.version, method: head.method)
                    return
                }
            case .expectContinue:
                guard await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) else { return }
            case .request(let request):
                disarmTimer()
                guard account(inFlight: request.body.count) else {
                    await rejectOverloaded()
                    return
                }
                // Keep reading while the request is handled: the end of the
                // stream means the client gave up, and closing the
                // connection cancels the generation.
                var watching = false
                if !peerClosed {
                    switch reader.watchForEnd({ [connection, log, id] in
                        log.log(.info, "connection \(id): client disconnected; cancelling the request")
                        connection.cancel()
                    }) {
                    case .watching: watching = true
                    case .alreadyEnded(failed: false): peerClosed = true  // Half-closed before the request was handled.
                    case .alreadyEnded(failed: true): return
                    }
                }
                let response = await handler(request)
                if Task.isCancelled {
                    if watching { reader.unwatch() }
                    if case .stream(let stream) = response.body { stream.cancel() }
                    return
                }
                let keepAlive = request.keepAlive && !peerClosed
                let written = await write(response, version: request.version, method: request.method, keepAlive: keepAlive)
                if watching { reader.unwatch() }
                _ = account()
                guard written, keepAlive else { return }
                armTimer()
            }
        }
    }

    /// Sends a final error response and closes the connection without
    /// reading (or buffering) the rest of the request.
    private func reject(_ response: HTTPResponse, version: HTTPVersion, method: String) async {
        if await write(response, version: version, method: method, keepAlive: false) { await closeGracefully() }
    }

    private func rejectOverloaded() async {
        log.log(.warning, "connection \(id): buffered request bytes exceed maxBufferedRequestBytes; rejecting the request")
        let response = OpenAIError(status: 503, message: "The server is buffering too many request bytes. Retry shortly.",
                                   type: "server_error", code: "server_overloaded", retryAfter: 1).response
        await reject(response, version: .http11, method: "GET")
    }

    // MARK: Timeouts

    private func armTimer() {
        let timeout = settings.idleTimeout
        let fresh = Task { [connection, id, log] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            log.log(.debug, "connection \(id): closing after \(timeout) without a complete request")
            connection.cancel()
        }
        timer.withLock { current in
            current?.cancel()
            current = fresh
        }
    }

    private func armTimer(until deadline: ContinuousClock.Instant) {
        let fresh = Task { [connection] in
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        timer.withLock { current in
            current?.cancel()
            current = fresh
        }
    }

    private func disarmTimer() {
        timer.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    // MARK: Output

    private func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    /// Writes a response. Returns false if the connection failed.
    private func write(_ response: HTTPResponse, version: HTTPVersion, method: String, keepAlive: Bool) async -> Bool {
        var keepAlive = keepAlive
        var headers = response.headers
        if headers["Server"] == nil { headers["Server"] = "open-apple-models" }
        headers["Date"] = Self.httpDate()
        headers["Content-Length"] = nil
        headers["Transfer-Encoding"] = nil
        // 1xx, 204 and 304 responses never have a body or body framing (RFC 9110 §8.6, RFC 9112 §6.3).
        let bodyless = (100..<200).contains(response.status) || response.status == 204 || response.status == 304
        let chunked: Bool
        switch response.body {
        case .data(let data):
            if !bodyless { headers["Content-Length"] = String(data.count) }
            chunked = false
        case .stream:
            if bodyless {
                chunked = false
            } else if version >= .http11 {
                headers["Transfer-Encoding"] = "chunked"
                chunked = true
            } else {
                // HTTP/1.0 has no chunked encoding: the close delimits the body.
                keepAlive = false
                chunked = false
            }
        }
        headers["Connection"] = keepAlive ? "keep-alive" : "close"

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"

        switch response.body {
        case .data(let data):
            var bytes = Data(head.utf8)
            if method != "HEAD", !bodyless { bytes.append(data) }
            return await send(bytes)
        case .stream(let stream):
            guard !bodyless, method != "HEAD" else {
                stream.cancel()
                return await send(Data(head.utf8))
            }
            guard await send(Data(head.utf8)) else {
                stream.cancel()
                return false
            }
            for await chunk in stream where !chunk.isEmpty {
                var frame = Data()
                if chunked { frame.append(contentsOf: Array((String(chunk.count, radix: 16) + "\r\n").utf8)) }
                frame.append(chunk)
                if chunked { frame.append(contentsOf: [0x0D, 0x0A]) }
                guard await send(frame) else {
                    stream.cancel()
                    return false
                }
            }
            if Task.isCancelled {
                stream.cancel()
                return false
            }
            return chunked ? await send(Data("0\r\n\r\n".utf8)) : false
        }
    }

    /// Half-closes and briefly drains (and discards) unread input so the
    /// peer receives the final response instead of a reset.
    private func closeGracefully() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
        let deadline = ContinuousClock.now + .seconds(1)
        armTimer(until: deadline)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if await reader.read().ended { break }
        }
    }

    static func httpDate(_ date: Date = Date()) -> String {
        var time = time_t(date.timeIntervalSince1970)
        var parts = tm()
        gmtime_r(&time, &parts)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        func two(_ value: Int32) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return "\(days[Int(parts.tm_wday)]), \(two(parts.tm_mday)) \(months[Int(parts.tm_mon)]) \(parts.tm_year + 1900) "
            + "\(two(parts.tm_hour)):\(two(parts.tm_min)):\(two(parts.tm_sec)) GMT"
    }
}

/// Receives from a connection in the background, ahead of the parser (up
/// to a small high-water mark), so the end of the stream is noticed even
/// while a request is being handled — including when pipelined bytes
/// arrived first.
final class ConnectionReader: Sendable {
    enum Watch: Equatable {
        case watching
        /// The stream had already ended (`failed`: with an error rather than EOF).
        case alreadyEnded(failed: Bool)
    }

    private enum End {
        case closed
        case failed
    }

    private struct State {
        var chunks: [Data] = []
        var bufferedBytes = 0
        var end: End?
        var receiving = false
        var waiter: CheckedContinuation<Void, Never>?
        var onEnd: (@Sendable () -> Void)?
    }

    /// Largest single read, and the most read ahead of the parser.
    static let readSize = 64 * 1024

    private let connection: NWConnection
    private let state = Mutex(State())

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() { pump() }

    /// Returns the bytes received so far, waiting until there are some or
    /// the stream ends. `ended` is true once nothing more will arrive.
    func read() async -> (data: Data, ended: Bool) {
        while true {
            let taken: (Data, Bool)? = state.withLock { state in
                guard !state.chunks.isEmpty || state.end != nil else { return nil }
                var data = Data()
                data.reserveCapacity(state.bufferedBytes)
                for chunk in state.chunks { data.append(chunk) }
                state.chunks = []
                state.bufferedBytes = 0
                return (data, state.end != nil)
            }
            if let taken {
                pump()
                return taken
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if !state.chunks.isEmpty || state.end != nil { return true }
                    state.waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    /// Calls `action` once if the stream ends before ``unwatch()``.
    func watchForEnd(_ action: @escaping @Sendable () -> Void) -> Watch {
        state.withLock { state in
            switch state.end {
            case .closed?: return .alreadyEnded(failed: false)
            case .failed?: return .alreadyEnded(failed: true)
            case nil:
                state.onEnd = action
                return .watching
            }
        }
    }

    func unwatch() {
        state.withLock { $0.onEnd = nil }
    }

    /// Issues a receive unless one is outstanding, the stream ended, or
    /// enough is buffered already.
    private func pump() {
        let proceed = state.withLock { state in
            guard !state.receiving, state.end == nil, state.bufferedBytes < Self.readSize else { return false }
            state.receiving = true
            return true
        }
        guard proceed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { [self] data, _, isComplete, error in
            let (waiter, onEnd, more) = state.withLock { state in
                state.receiving = false
                if let data, !data.isEmpty {
                    state.chunks.append(data)
                    state.bufferedBytes += data.count
                }
                if error != nil {
                    state.end = .failed
                } else if isComplete {
                    state.end = .closed
                }
                let waiter = state.waiter
                state.waiter = nil
                var onEnd: (@Sendable () -> Void)?
                if state.end != nil {
                    onEnd = state.onEnd
                    state.onEnd = nil
                }
                return (waiter, onEnd, state.end == nil)
            }
            waiter?.resume()
            onEnd?()
            if more { pump() }
        }
    }
}

/// A byte budget shared by all connections, capping the memory held by
/// buffered requests.
final class ByteBudget: Sendable {
    let limit: Int
    private let used = Mutex(0)

    init(limit: Int) {
        self.limit = limit
    }

    /// Bytes currently reserved.
    var usedBytes: Int { used.withLock { $0 } }

    /// Reserves `count` bytes; false (reserving nothing) if that would exceed the limit.
    func reserve(_ count: Int) -> Bool {
        used.withLock { used in
            guard used + count <= limit else { return false }
            used += count
            return true
        }
    }

    func release(_ count: Int) {
        guard count > 0 else { return }
        used.withLock { $0 = max(0, $0 - count) }
    }
}
