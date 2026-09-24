import Foundation
import OpenAppleModels

/// An error in OpenAI's envelope format:
/// `{"error": {"message", "type", "param", "code"}}`.
struct OpenAIError: Error, Sendable, Equatable, CustomStringConvertible {
    var status: Int
    var message: String
    var type: String
    var param: String?
    var code: String?
    /// Seconds after which the client may retry (sent as `Retry-After`).
    var retryAfter: Int?

    init(status: Int, message: String, type: String, param: String? = nil, code: String? = nil, retryAfter: Int? = nil) {
        self.status = status
        self.message = message
        self.type = type
        self.param = param
        self.code = code
        self.retryAfter = retryAfter
    }

    var description: String { "\(status) \(code ?? type): \(message)" }

    var json: JSONValue {
        [
            "error": [
                "message": .string(message),
                "type": .string(type),
                "param": param.map(JSONValue.string) ?? .null,
                "code": code.map(JSONValue.string) ?? .null,
            ],
        ]
    }

    var response: HTTPResponse {
        var headers = HTTPHeaders()
        if let retryAfter { headers["Retry-After"] = String(retryAfter) }
        return .json(json, status: status, headers: headers)
    }

    // MARK: Common errors

    static func invalidRequest(_ message: String, param: String? = nil, code: String? = nil) -> OpenAIError {
        OpenAIError(status: 400, message: message, type: "invalid_request_error", param: param, code: code)
    }

    static func server(_ message: String, code: String? = nil) -> OpenAIError {
        OpenAIError(status: 500, message: message, type: "server_error", code: code)
    }

    static func timeout(after duration: Duration) -> OpenAIError {
        OpenAIError(status: 504, message: "The request did not finish within \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .wide))).",
                    type: "server_error", code: "timeout")
    }

    static let invalidJSONBody = OpenAIError.invalidRequest(
        "We could not parse the JSON body of your request. The body must be a JSON object.", code: "invalid_json")

    /// Maps an agent error to the closest OpenAI error.
    init(_ error: AgentError) {
        switch error.code {
        case .modelUnavailable:
            self.init(status: 503, message: error.message, type: "server_error", code: "model_unavailable")
        case .guardrailViolation:
            self.init(status: 400, message: "The request was blocked by the on-device model's safety guardrails. \(error.message)",
                      type: "invalid_request_error", param: "messages", code: "content_filter")
        case .refusal:
            self.init(status: 400, message: error.message, type: "invalid_request_error", code: "refusal")
        case .contextSizeExceeded:
            self.init(status: 400, message: error.message, type: "invalid_request_error", param: "messages", code: "context_length_exceeded")
        case .rateLimited:
            let seconds = error.retryAfter.map { max(1, Int($0.timeIntervalSinceNow.rounded(.up))) } ?? 1
            self.init(status: 429, message: error.message, type: "rate_limit_error", code: "rate_limited", retryAfter: seconds)
        case .unsupportedLanguage:
            self.init(status: 400, message: error.message, type: "invalid_request_error", param: "messages", code: "unsupported_language")
        case .invalidSchema:
            self.init(status: 400, message: error.message, type: "invalid_request_error", code: "invalid_schema")
        case .invalidRequest:
            self.init(status: 400, message: error.message, type: "invalid_request_error")
        case .toolFailed:
            self.init(status: 500, message: error.message, type: "server_error", code: "tool_failed")
        case .busy:
            self.init(status: 503, message: error.message, type: "server_error", code: "busy", retryAfter: 1)
        case .cancelled:
            self.init(status: 500, message: error.message, type: "server_error", code: "cancelled")
        default:  // .generationFailed and any future codes
            if error.message.hasPrefix("Timed out") {
                self.init(status: 504, message: error.message, type: "server_error", code: "timeout")
            } else {
                self.init(status: 500, message: error.message, type: "server_error")
            }
        }
    }
}
