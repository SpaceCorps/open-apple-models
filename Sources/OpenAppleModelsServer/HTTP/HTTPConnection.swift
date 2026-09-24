import Foundation
import Network
import Synchronization

/// Serves HTTP/1.1 requests on one accepted connection: parses requests
/// (including pipelined ones), passes them to the handler, writes responses
/// (streamed bodies use chunked transfer encoding), honours keep-alive and
/// closes idle or slow connections.
final class HTTPConnection: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    struct Settings: Sendable {
        var limits: HTTPRequestParser.Limits
        /// Maximum time to wait for a complete request (covers keep-alive
        /// idling and clients that trickle bytes).
        var idleTimeout: Duration
    }

    let id: Int
    private let connection: NWConnection
    private let transport: HTTPTransport
    private let settings: Settings
    private let handler: Handler
    private let log: ServerLogger
    private let queue: DispatchQueue
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let timer = Mutex<Task<Void, Never>?>(nil)

    init(id: Int, connection: NWConnection, transport: HTTPTransport, settings: Settings, log: ServerLogger, handler: @escaping Handler) {
        self.id = id
        self.connection = connection
        self.transport = transport
        self.settings = settings
        self.handler = handler
        self.log = log
        self.queue = DispatchQueue(label: "open-apple-models.http.connection.\(id)")
    }

    /// Starts serving. `onClose` runs once when the connection ends.
    func start(onClose: @escaping @Sendable () -> Void) {
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
        let serving = Task { [self] in
            await serve()
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
        // A receive issued while a request is being handled, to notice the
        // client going away. Its bytes (a pipelined request) are used next.
        var pendingReceive: Task<(Data?, Bool)?, Never>?
        armTimer()
        while !Task.isCancelled {
            let event: HTTPRequestParser.Event?
            do {
                event = try parser.next()
            } catch {
                log.log(.info, "connection \(id): rejecting malformed request (\(error.status)): \(error.message)")
                let response = OpenAIError(status: error.status, message: error.message, type: "invalid_request_error", code: "malformed_request").response
                _ = await write(response, version: .http11, method: "GET", keepAlive: false)
                await closeGracefully()
                return
            }
            guard let event else {
                if peerClosed { return }
                let received: (Data?, Bool)?
                if let pending = pendingReceive {
                    pendingReceive = nil
                    received = await pending.value
                } else {
                    received = await receive()
                }
                guard let (data, isComplete) = received else { return }
                if let data { parser.append(data) }
                if isComplete { peerClosed = true }
                continue
            }
            switch event {
            case .expectContinue:
                guard await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) else { return }
            case .request(let request):
                disarmTimer()
                var watcher: Task<Void, Never>?
                if !peerClosed, pendingReceive == nil {
                    let pending = Task { await receive() }
                    pendingReceive = pending
                    watcher = Task { [connection, log, id] in
                        let result = await pending.value
                        guard !Task.isCancelled else { return }
                        // EOF or an error while the request is in flight: the
                        // client gave up. Closing cancels the generation.
                        if result.map({ $0.1 && ($0.0?.isEmpty ?? true) }) ?? true {
                            log.log(.info, "connection \(id): client disconnected; cancelling the request")
                            connection.cancel()
                        }
                    }
                }
                let response = await handler(request)
                if Task.isCancelled {
                    watcher?.cancel()
                    if case .stream(let stream) = response.body { stream.cancel() }
                    return
                }
                let keepAlive = request.keepAlive && !peerClosed
                let written = await write(response, version: request.version, method: request.method, keepAlive: keepAlive)
                watcher?.cancel()
                guard written, keepAlive else { return }
                armTimer()
            }
        }
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

    private func disarmTimer() {
        timer.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    // MARK: I/O

    /// Receives the next bytes. Returns `nil` on error or cancellation.
    private func receive() async -> (Data?, Bool)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, Bool)?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

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
        let chunked: Bool
        switch response.body {
        case .data(let data):
            headers["Content-Length"] = String(data.count)
            chunked = false
        case .stream:
            if version >= .http11 {
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
            if method != "HEAD" { bytes.append(data) }
            return await send(bytes)
        case .stream(let stream):
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

    /// Half-closes and briefly drains unread input so the peer receives the
    /// final response instead of a reset.
    private func closeGracefully() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
        let deadline = ContinuousClock.now + .seconds(1)
        armTimer(until: deadline)
        while ContinuousClock.now < deadline, let (_, isComplete) = await receive(), !isComplete {}
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
