import Foundation
import Network
import Synchronization

/// Errors starting the server's listeners.
public struct ServerStartError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// What went wrong, e.g. the address is already in use.
    public var message: String
    /// Creates an error with a message.
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Accepts connections on a TCP port or a Unix domain socket.
///
/// If the listener fails after it started (iOS reclaims the listening
/// sockets of suspended apps, TN2277; an interface can go away on macOS),
/// it is recreated on the same address — the same bound port, even when
/// port 0 was requested — a bounded number of times with exponential
/// backoff. Progress is reported through the `onEvent` callback.
final class HTTPListener: Sendable {
    /// What happened to a listener after it started.
    enum Event: Sendable {
        /// The listener failed (`reason`); restart `attempt` (from 1) follows after a delay.
        case failed(reason: String, attempt: Int)
        /// A restart succeeded; connections are accepted again.
        case restarted
        /// Every restart attempt failed; the listener is gone.
        case gaveUp(reason: String)
    }

    struct RestartPolicy: Sendable {
        var attempts: Int
        var initialDelay: Duration
    }

    private enum Endpoint: Sendable {
        case tcp(host: String, port: NWEndpoint.Port)
        case unix(path: String)
    }

    private struct State {
        /// The current listener: starting, or running.
        var listener: NWListener?
        /// The bound TCP port, reused when restarting.
        var boundPort: NWEndpoint.Port?
        var cancelled = false
        var restart: Task<Void, Never>?
        var queue: DispatchQueue?
        var onConnection: (@Sendable (NWConnection) -> Void)?
        var onEvent: (@Sendable (Event) -> Void)?
    }

    let transport: HTTPTransport
    private let endpoint: Endpoint
    private let restartPolicy: RestartPolicy
    private let state = Mutex(State())

    /// A TCP listener bound to `host` (an IP address or host name) and `port`
    /// (0 picks a free port).
    init(host: String, port: Int, restartPolicy: RestartPolicy) throws(ServerStartError) {
        guard (0...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ServerStartError("Invalid port \(port).")
        }
        endpoint = .tcp(host: host, port: nwPort)
        transport = .tcp
        self.restartPolicy = restartPolicy
    }

    /// A Unix domain socket listener at `path`. A stale socket file at the
    /// path is replaced; any other kind of file is left alone (and fails).
    init(unixSocketPath path: String, restartPolicy: RestartPolicy) {
        endpoint = .unix(path: path)
        transport = .unixSocket
        self.restartPolicy = restartPolicy
    }

    /// A description of the address, for log messages.
    var address: String {
        switch endpoint {
        case .tcp(let host, let port):
            let bound = state.withLock { $0.boundPort } ?? port
            return "\(host.contains(":") ? "[\(host)]" : host):\(bound.rawValue)"
        case .unix(let path):
            return "unix:\(path)"
        }
    }

    /// Starts accepting connections and returns once listening. Returns the
    /// bound TCP port (`nil` for Unix sockets). `onEvent` reports failures
    /// and restarts afterwards.
    func start(
        queue: DispatchQueue,
        onConnection: @escaping @Sendable (NWConnection) -> Void,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async throws(ServerStartError) -> Int? {
        state.withLock { state in
            state.queue = queue
            state.onConnection = onConnection
            state.onEvent = onEvent
        }
        return try await open()
    }

    /// Stops listening for good (also stops a restart in progress) and
    /// removes the Unix socket file.
    func cancel() {
        let (listener, restart) = state.withLock { state in
            state.cancelled = true
            defer {
                state.listener = nil
                state.restart = nil
                state.onConnection = nil
                state.onEvent = nil
            }
            return (state.listener, state.restart)
        }
        restart?.cancel()
        listener?.newConnectionHandler = nil
        // The state handler stays installed so that a listener still
        // starting resolves its start with "cancelled".
        listener?.cancel()
        if case .unix(let path) = endpoint { Self.removeSocketFile(at: path) }
    }

    /// Handles the current listener as if it had failed (for tests).
    func simulateFailure(_ reason: String) {
        guard let listener = state.withLock({ $0.listener }) else { return }
        listenerFailed(listener, reason: reason)
    }

    // MARK: Opening

    /// Creates and starts a listener, installs it as the current one and
    /// waits until it is ready.
    private func open() async throws(ServerStartError) -> Int? {
        let (queue, onConnection, boundPort, cancelled) = state.withLock { ($0.queue, $0.onConnection, $0.boundPort, $0.cancelled) }
        guard let queue, !cancelled else { throw ServerStartError("The listener was stopped.") }
        let listener = try makeListener(boundPort: boundPort)
        let installed = state.withLock { state in
            guard !state.cancelled else { return false }
            state.listener = listener
            return true
        }
        guard installed else { throw ServerStartError("The listener was stopped.") }

        let started = OneShot<Result<Int?, ServerStartError>>()
        listener.newConnectionHandler = onConnection
        listener.stateUpdateHandler = { [weak self] newState in
            self?.stateChanged(newState, of: listener, started: started)
        }
        listener.start(queue: queue)
        switch await started.value() {
        case .success(let port):
            return port
        case .failure(let error):
            state.withLock { state in
                if state.listener === listener { state.listener = nil }
            }
            throw error
        }
    }

    private func makeListener(boundPort: NWEndpoint.Port?) throws(ServerStartError) -> NWListener {
        switch endpoint {
        case .tcp(let host, let port):
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                // Stream tokens as soon as they are written.
                tcp.noDelay = true
            }
            let port = boundPort ?? port
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
            do {
                return try NWListener(using: parameters)
            } catch {
                throw ServerStartError("Cannot listen on \(host):\(port.rawValue): \(error)")
            }
        case .unix(let path):
            var info = stat()
            if lstat(path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                    throw ServerStartError("\(path) exists and is not a socket.")
                }
                unlink(path)
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: path)
            do {
                return try NWListener(using: parameters)
            } catch {
                throw ServerStartError("Cannot listen on unix socket \(path): \(error)")
            }
        }
    }

    private func stateChanged(_ newState: NWListener.State, of listener: NWListener, started: OneShot<Result<Int?, ServerStartError>>) {
        func fail(_ reason: String) {
            if started.fulfill(.failure(ServerStartError(reason))) {
                // Never became ready: the start fails.
                listener.stateUpdateHandler = nil
                listener.cancel()
            } else {
                listenerFailed(listener, reason: reason)
            }
        }
        switch newState {
        case .ready:
            let port: Int?
            switch endpoint {
            case .tcp:
                port = listener.port.map { Int($0.rawValue) }
                state.withLock { state in
                    if state.listener === listener, let bound = listener.port { state.boundPort = bound }
                }
            case .unix(let path):
                // Only the owner may connect by default.
                chmod(path, 0o600)
                port = nil
            }
            started.fulfill(.success(port))
        case .failed(let error):
            fail("Listener failed: \(error)")
        case .waiting(let error):
            fail("Listener cannot listen: \(error)")
        case .cancelled:
            fail("Listener was cancelled.")
        default:
            break
        }
    }

    // MARK: Restarting

    /// Replaces a failed running listener, unless it was already replaced
    /// or the listener was cancelled.
    private func listenerFailed(_ listener: NWListener, reason: String) {
        let current = state.withLock { state in
            guard !state.cancelled, state.listener === listener else { return false }
            state.listener = nil
            return true
        }
        guard current else { return }
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await restart(after: reason)
        }
        let cancelled = state.withLock { state in
            if !state.cancelled { state.restart = task }
            return state.cancelled
        }
        if cancelled { task.cancel() }
    }

    private func restart(after failure: String) async {
        var reason = failure
        var attempt = 1
        while attempt <= restartPolicy.attempts {
            emit(.failed(reason: reason, attempt: attempt))
            try? await Task.sleep(for: restartPolicy.initialDelay * (1 << min(attempt - 1, 16)))
            if Task.isCancelled || state.withLock({ $0.cancelled }) { return }
            do {
                _ = try await open()
                state.withLock { $0.restart = nil }
                emit(.restarted)
                return
            } catch {
                if state.withLock({ $0.cancelled }) { return }
                reason = error.message
            }
            attempt += 1
        }
        state.withLock { $0.restart = nil }
        emit(.gaveUp(reason: reason))
    }

    private func emit(_ event: Event) {
        state.withLock { $0.onEvent }?(event)
    }

    /// Removes the socket file at `path`, but never any other kind of file.
    private static func removeSocketFile(at path: String) {
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
    }
}
