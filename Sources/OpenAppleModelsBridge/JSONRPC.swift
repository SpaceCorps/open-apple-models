import Foundation
import OpenAppleModels

/// A JSON-RPC request identifier: a string or a number, echoed back exactly
/// as the peer sent it.
public struct JSONRPCID: Sendable, Hashable, CustomStringConvertible {
    /// The raw id (`.string` or `.number`).
    public let value: JSONValue

    /// Wraps a JSON id; returns `nil` for anything but a string or a number.
    public init?(_ value: JSONValue) {
        switch value {
        case .string, .number: self.value = value
        default: return nil
        }
    }

    public init(_ string: String) { value = .string(string) }
    public init(_ number: Int) { value = .number(Double(number)) }

    public var description: String { value.stringValue ?? value.serialized() }
}

/// A JSON-RPC error object, thrown by method handlers and returned to peers.
///
/// Every error carries `data.code`, a stable snake_case string (for
/// application errors, the ``AgentError/Code`` raw value) so clients can
/// branch without memorizing numeric codes.
public struct BridgeError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var message: String
    /// Extra information; always an object containing at least `code`.
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// Creates an error with `data.code` set to `name`, merged with `extra`.
    public init(code: Int, name: String, message: String, extra: JSONObject = [:]) {
        var data: JSONObject = ["code": .string(name)]
        for (key, value) in extra { data[key] = value }
        self.init(code: code, message: message, data: .object(data))
    }

    public var description: String { "\(code) \(name ?? "error"): \(message)" }

    /// The string code in `data.code`, if any.
    public var name: String? { data?["code"]?.stringValue }

    /// The JSON-RPC `error` member.
    public var json: JSONValue {
        var object: JSONObject = ["code": .number(Double(code)), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }

    /// Parses a JSON-RPC `error` member received from a peer.
    public init(json: JSONValue) {
        let code = json["code"]?.intValue ?? Code.internalError
        let message = json["message"]?.stringValue ?? "Unknown error"
        self.init(code: code, message: message, data: json["data"])
    }
}

// MARK: - Codes

extension BridgeError {
    /// Numeric error codes. Standard JSON-RPC codes are in -32700…-32600;
    /// application codes are in -32001…-32099.
    public enum Code {
        // JSON-RPC 2.0
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603

        // Mapped from AgentError.Code
        public static let modelUnavailable = -32001
        public static let guardrailViolation = -32002
        public static let refusal = -32003
        public static let contextSizeExceeded = -32004
        public static let rateLimited = -32005
        public static let unsupportedLanguage = -32006
        public static let invalidSchema = -32007
        public static let toolFailed = -32008
        public static let cancelled = -32009
        public static let busy = -32010
        public static let agentInvalidRequest = -32011
        public static let generationFailed = -32012

        // Bridge
        public static let sessionNotFound = -32020
        public static let sessionExists = -32021
        public static let sessionLimitReached = -32022
        public static let shutDown = -32023
        public static let timeout = -32024
    }

    /// The numeric code for an ``AgentError/Code``.
    public static func code(for agentCode: AgentError.Code) -> Int {
        switch agentCode {
        case .modelUnavailable: Code.modelUnavailable
        case .guardrailViolation: Code.guardrailViolation
        case .refusal: Code.refusal
        case .contextSizeExceeded: Code.contextSizeExceeded
        case .rateLimited: Code.rateLimited
        case .unsupportedLanguage: Code.unsupportedLanguage
        case .invalidSchema: Code.invalidSchema
        case .toolFailed: Code.toolFailed
        case .cancelled: Code.cancelled
        case .busy: Code.busy
        case .invalidRequest: Code.agentInvalidRequest
        case .generationFailed: Code.generationFailed
        }
    }

    public static func parseError(_ message: String) -> BridgeError {
        BridgeError(code: Code.parseError, name: "parse_error", message: message)
    }

    public static func invalidRequest(_ message: String) -> BridgeError {
        BridgeError(code: Code.invalidRequest, name: "invalid_message", message: message)
    }

    public static func methodNotFound(_ method: String) -> BridgeError {
        BridgeError(code: Code.methodNotFound, name: "method_not_found", message: "Unknown method '\(method)'.",
                    extra: ["method": .string(method)])
    }

    public static func invalidParams(_ message: String) -> BridgeError {
        BridgeError(code: Code.invalidParams, name: "invalid_params", message: message)
    }

    public static func internalError(_ message: String) -> BridgeError {
        BridgeError(code: Code.internalError, name: "internal_error", message: message)
    }

    public static func sessionNotFound(_ id: String) -> BridgeError {
        BridgeError(code: Code.sessionNotFound, name: "session_not_found", message: "No session with id '\(id)'.",
                    extra: ["session": .string(id)])
    }

    public static func sessionExists(_ id: String) -> BridgeError {
        BridgeError(code: Code.sessionExists, name: "session_exists", message: "A session with id '\(id)' already exists.",
                    extra: ["session": .string(id)])
    }

    public static func sessionLimitReached(_ limit: Int) -> BridgeError {
        BridgeError(code: Code.sessionLimitReached, name: "session_limit",
                    message: "The session limit (\(limit)) is reached; delete a session first.",
                    extra: ["limit": .number(Double(limit))])
    }

    public static var shutDown: BridgeError {
        BridgeError(code: Code.shutDown, name: "shut_down", message: "The bridge has shut down.")
    }

    public static func timeout(_ message: String) -> BridgeError {
        BridgeError(code: Code.timeout, name: "timeout", message: message)
    }

    public static func cancelled(_ message: String) -> BridgeError {
        BridgeError(AgentError(.cancelled, message))
    }

    /// Maps an ``AgentError`` to its application error code.
    public init(_ error: AgentError) {
        var extra: JSONObject = [:]
        if let retryAfter = error.retryAfter {
            extra["retryAfter"] = .string(ISO8601DateFormatter().string(from: retryAfter))
            extra["retryAfterSeconds"] = .number(max(0, retryAfter.timeIntervalSinceNow.rounded(.up)))
        }
        self.init(code: Self.code(for: error.code), name: error.code.rawValue, message: error.message, extra: extra)
    }

    /// Normalizes any error thrown by a handler.
    public init(normalizing error: any Error) {
        switch error {
        case let error as BridgeError: self = error
        case let error as AgentError: self.init(error)
        case let error as SchemaConversionError:
            self.init(code: Code.invalidSchema, name: AgentError.Code.invalidSchema.rawValue, message: error.description,
                      extra: ["path": .string(error.path)])
        case let error as JSONParseError: self = .invalidParams(error.description)
        case is CancellationError: self.init(AgentError(.cancelled, "The request was cancelled."))
        default: self.init(AgentError(error))
        }
    }
}

// MARK: - Messages

/// Builders for single-line JSON-RPC 2.0 messages.
public enum JSONRPCMessage {
    public static func result(id: JSONRPCID, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id.value, "result": result]).serialized()
    }

    public static func error(id: JSONRPCID?, _ error: BridgeError) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id?.value ?? .null, "error": error.json]).serialized()
    }

    public static func notification(method: String, params: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).serialized()
    }

    public static func request(id: JSONRPCID, method: String, params: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id.value, "method": .string(method), "params": params]).serialized()
    }
}
