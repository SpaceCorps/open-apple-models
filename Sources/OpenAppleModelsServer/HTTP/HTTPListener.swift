import Foundation
import Network
import Synchronization

/// Errors starting the server's listeners.
public struct ServerStartError: Error, Sendable, CustomStringConvertible {
    /// What went wrong, e.g. the address is already in use.
    public var message: String
    /// Creates an error with a message.
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Accepts connections on a TCP port or a Unix domain socket.
final class HTTPListener: Sendable {
    let transport: HTTPTransport
    private let listener: NWListener
    private let unixPath: String?

    /// A TCP listener bound to `host` (an IP address or host name) and `port`
    /// (0 picks a free port).
    init(host: String, port: Int) throws(ServerStartError) {
        guard (0...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ServerStartError("Invalid port \(port).")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // Stream tokens as soon as they are written.
            tcp.noDelay = true
        }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerStartError("Cannot listen on \(host):\(port): \(error)")
        }
        transport = .tcp
        unixPath = nil
    }

    /// A Unix domain socket listener at `path`. A stale socket file at the
    /// path is replaced; any other kind of file is left alone (and fails).
    init(unixSocketPath path: String) throws(ServerStartError) {
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
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerStartError("Cannot listen on unix socket \(path): \(error)")
        }
        transport = .unixSocket
        unixPath = path
    }

    /// Starts accepting connections and returns once listening. Returns the
    /// bound TCP port (`nil` for Unix sockets).
    func start(queue: DispatchQueue, onConnection: @escaping @Sendable (NWConnection) -> Void) async throws(ServerStartError) -> Int? {
        listener.newConnectionHandler = onConnection
        let resumed = Mutex(false)
        let result: Result<Int?, ServerStartError> = await withCheckedContinuation { continuation in
            @Sendable func resume(_ result: Result<Int?, ServerStartError>) {
                let first = resumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if first { continuation.resume(returning: result) }
            }
            listener.stateUpdateHandler = { [listener, unixPath] state in
                switch state {
                case .ready:
                    if let unixPath {
                        // Only the owner may connect by default.
                        chmod(unixPath, 0o600)
                    }
                    resume(.success(unixPath == nil ? listener.port.map { Int($0.rawValue) } : nil))
                case .failed(let error):
                    resume(.failure(ServerStartError("Listener failed: \(error)")))
                    listener.cancel()
                case .waiting(let error):
                    resume(.failure(ServerStartError("Listener cannot start: \(error)")))
                    listener.cancel()
                case .cancelled:
                    resume(.failure(ServerStartError("Listener was cancelled.")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return try result.get()
    }

    func cancel() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        if let unixPath { unlink(unixPath) }
    }
}
