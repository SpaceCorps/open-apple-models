import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import Synchronization

// C ABI over ``BridgeEngine``. The authoritative declarations, with the
// memory and threading rules, are in `bindings/c/open_apple_models.h`.
//
// Every entry point is non-throwing and tolerates NULL arguments.

/// `typedef void (*oam_message_callback)(const char *json_line, void *user_data);`
public typealias OAMMessageCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

/// Return codes of `oam_bridge_send`.
enum OAMStatus {
    static let ok: Int32 = 0
    static let invalidArgument: Int32 = -1
    static let invalidUTF8: Int32 = -2
}

/// The object behind an `oam_bridge *` handle.
final class FFIBridge: Sendable {
    let engine: BridgeEngine

    init(engine: BridgeEngine) {
        self.engine = engine
    }

    static func from(_ handle: OpaquePointer) -> FFIBridge {
        Unmanaged<FFIBridge>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
    }
}

/// The C callback and its opaque context. The host guarantees both stay
/// valid until `oam_bridge_destroy` returns; the engine never calls the
/// callback after that.
private struct CallbackTarget: @unchecked Sendable {
    let callback: OAMMessageCallback
    let userData: UnsafeMutableRawPointer?

    func deliver(_ line: String) {
        line.withCString { callback($0, userData) }
    }
}

/// Bridge settings for C hosts. `OAM_BRIDGE_LOG=debug|info|warning|error`
/// prints bridge diagnostics to stderr.
private func ffiConfiguration() -> BridgeConfiguration {
    var configuration = BridgeConfiguration()
    if let name = ProcessInfo.processInfo.environment["OAM_BRIDGE_LOG"], let threshold = BridgeLogLevel(rawValue: name.lowercased()) {
        configuration.logger = { level, message in
            guard level >= threshold else { return }
            FileHandle.standardError.write(Data("[open-apple-models] \(level.rawValue): \(message)\n".utf8))
        }
    }
    return configuration
}

/// `oam_bridge *oam_bridge_create(oam_message_callback callback, void *user_data);`
@_cdecl("oam_bridge_create")
public func oam_bridge_create(_ callback: OAMMessageCallback?, _ userData: UnsafeMutableRawPointer?) -> OpaquePointer? {
    guard let callback else { return nil }
    let target = CallbackTarget(callback: callback, userData: userData)
    let engine = BridgeEngine(configuration: ffiConfiguration()) { line in target.deliver(line) }
    return OpaquePointer(Unmanaged.passRetained(FFIBridge(engine: engine)).toOpaque())
}

/// `int oam_bridge_send(oam_bridge *bridge, const char *json_line);`
@_cdecl("oam_bridge_send")
public func oam_bridge_send(_ bridge: OpaquePointer?, _ jsonLine: UnsafePointer<CChar>?) -> Int32 {
    guard let bridge, let jsonLine else { return OAMStatus.invalidArgument }
    guard let line = String(validatingCString: jsonLine) else { return OAMStatus.invalidUTF8 }
    FFIBridge.from(bridge).engine.receive(line)
    return OAMStatus.ok
}

/// `void oam_bridge_destroy(oam_bridge *bridge);`
@_cdecl("oam_bridge_destroy")
public func oam_bridge_destroy(_ bridge: OpaquePointer?) {
    guard let bridge else { return }
    let unmanaged = Unmanaged<FFIBridge>.fromOpaque(UnsafeRawPointer(bridge))
    unmanaged.takeUnretainedValue().engine.close()
    unmanaged.release()
}

nonisolated(unsafe) private let versionString: UnsafeMutablePointer<CChar> = strdup(BridgeVersion.library)!

/// `const char *oam_version(void);`
@_cdecl("oam_version")
public func oam_version() -> UnsafePointer<CChar> {
    UnsafePointer(versionString)
}

/// `char *oam_call_blocking(oam_bridge *bridge, const char *request_json, int timeout_ms);`
///
/// Runs one request to completion on the calling thread and returns the
/// JSON-RPC response line (free it with `oam_string_free`). Returns NULL
/// only for NULL arguments.
@_cdecl("oam_call_blocking")
public func oam_call_blocking(_ bridge: OpaquePointer?, _ requestJSON: UnsafePointer<CChar>?, _ timeoutMilliseconds: Int32) -> UnsafeMutablePointer<CChar>? {
    guard let bridge, let requestJSON else { return nil }
    let engine = FFIBridge.from(bridge).engine
    let line = BlockingCall.run(engine: engine, request: String(cString: requestJSON), timeoutMilliseconds: Int(timeoutMilliseconds))
    return strdup(line)
}

/// `void oam_string_free(char *string);`
@_cdecl("oam_string_free")
public func oam_string_free(_ string: UnsafeMutablePointer<CChar>?) {
    free(string)
}

/// Implements `oam_call_blocking`.
enum BlockingCall {
    static func run(engine: BridgeEngine, request text: String, timeoutMilliseconds: Int) -> String {
        let request: JSONValue
        do {
            request = try JSONValue(parsing: text)
        } catch {
            return JSONRPCMessage.error(id: nil, .parseError(error.description))
        }
        let id = request["id"].flatMap(JSONRPCID.init)
        guard let method = request["method"]?.stringValue, !method.isEmpty else {
            return JSONRPCMessage.error(id: id, .invalidRequest("'method' must be a non-empty string."))
        }
        let params = request["params"]

        let outcome = Mutex<Result<JSONValue, BridgeError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = Task {
            let result: Result<JSONValue, BridgeError>
            do {
                result = .success(try await engine.call(method, params))
            } catch {
                result = .failure(BridgeError(normalizing: error))
            }
            outcome.withLock { $0 = result }
            done.signal()
        }
        let deadline: DispatchTime = timeoutMilliseconds > 0 ? .now() + .milliseconds(timeoutMilliseconds) : .distantFuture
        if done.wait(timeout: deadline) == .timedOut {
            task.cancel()
            return JSONRPCMessage.error(id: id, .timeout("'\(method)' did not finish within \(timeoutMilliseconds) ms; it was cancelled."))
        }
        switch outcome.withLock({ $0 }) ?? .failure(.internalError("No result.")) {
        case .success(let value):
            return JSONValue.object(["jsonrpc": "2.0", "id": id?.value ?? .null, "result": value]).serialized()
        case .failure(let error):
            return JSONRPCMessage.error(id: id, error)
        }
    }
}
