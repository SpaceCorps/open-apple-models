import Foundation
import FoundationModels

/// Errors surfaced by ``Agent``, normalized from FoundationModels' error types
/// so hosts (games, servers, bridges) can react uniformly.
public struct AgentError: Error, Sendable, CustomStringConvertible, Hashable {
    public enum Code: String, Sendable, Codable, CaseIterable {
        /// The model is unavailable (device not eligible, Apple Intelligence off, model downloading).
        case modelUnavailable = "model_unavailable"
        /// Input or output tripped the safety guardrails.
        case guardrailViolation = "guardrail_violation"
        /// The model refused to produce the requested content.
        case refusal
        /// The conversation no longer fits the context window.
        case contextSizeExceeded = "context_size_exceeded"
        /// The system rate-limited the request (typically when running in the background).
        case rateLimited = "rate_limited"
        /// The prompt's language or locale is not supported.
        case unsupportedLanguage = "unsupported_language"
        /// A schema or tool definition could not be used.
        case invalidSchema = "invalid_schema"
        /// A tool threw an error that aborted the turn.
        case toolFailed = "tool_failed"
        /// The turn was cancelled.
        case cancelled
        /// The session is busy with another turn.
        case busy
        /// Invalid input from the caller.
        case invalidRequest = "invalid_request"
        /// Anything else.
        case generationFailed = "generation_failed"
    }

    public var code: Code
    public var message: String
    /// When rate limited, the time after which to retry.
    public var retryAfter: Date?

    public init(_ code: Code, _ message: String, retryAfter: Date? = nil) {
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }

    public var description: String { "\(code.rawValue): \(message)" }

    /// Maps any error thrown by FoundationModels (or this package) to an ``AgentError``.
    public init(_ error: any Error) {
        switch error {
        case let error as AgentError:
            self = error
        case is CancellationError:
            self.init(.cancelled, "The turn was cancelled.")
        case let error as SchemaConversionError:
            self.init(.invalidSchema, error.description)
        case let error as LanguageModelError:
            switch error {
            case .contextSizeExceeded(let info):
                self.init(.contextSizeExceeded, "The conversation (\(info.tokenCount) tokens) exceeds the model's context size of \(info.contextSize) tokens.")
            case .rateLimited(let info):
                self.init(.rateLimited, info.debugDescription, retryAfter: info.resetDate)
            case .guardrailViolation(let info):
                self.init(.guardrailViolation, info.debugDescription)
            case .refusal(let info):
                self.init(.refusal, info.debugDescription)
            case .unsupportedCapability(let info):
                self.init(.invalidRequest, info.debugDescription)
            case .unsupportedTranscriptContent(let info):
                self.init(.invalidRequest, info.debugDescription)
            case .unsupportedGenerationGuide(let info):
                self.init(.invalidSchema, info.debugDescription)
            case .unsupportedLanguageOrLocale(let info):
                self.init(.unsupportedLanguage, info.debugDescription)
            case .timeout(let info):
                self.init(.generationFailed, "Timed out: " + info.debugDescription)
            @unknown default:
                self.init(.generationFailed, String(describing: error))
            }
        case let error as LanguageModelSession.GenerationError:
            switch error {
            case .exceededContextWindowSize(let context):
                self.init(.contextSizeExceeded, context.debugDescription)
            case .assetsUnavailable(let context):
                self.init(.modelUnavailable, context.debugDescription)
            case .guardrailViolation(let context):
                self.init(.guardrailViolation, context.debugDescription)
            case .unsupportedGuide(let context):
                self.init(.invalidSchema, context.debugDescription)
            case .unsupportedLanguageOrLocale(let context):
                self.init(.unsupportedLanguage, context.debugDescription)
            case .decodingFailure(let context):
                self.init(.generationFailed, "Decoding failed: " + context.debugDescription)
            case .rateLimited(let context):
                self.init(.rateLimited, context.debugDescription)
            case .concurrentRequests(let context):
                self.init(.busy, context.debugDescription)
            case .refusal(_, let context):
                self.init(.refusal, context.debugDescription)
            @unknown default:
                self.init(.generationFailed, String(describing: error))
            }
        case let error as LanguageModelSession.ToolCallError:
            if let inner = error.underlyingError as? AgentError {
                self = inner
            } else if error.underlyingError is CancellationError {
                self.init(.cancelled, "The turn was cancelled while running tool '\(error.tool.name)'.")
            } else {
                self.init(.toolFailed, "Tool '\(error.tool.name)' failed: \(error.underlyingError.localizedDescription)")
            }
        case let error as LanguageModelSession.Error:
            switch error {
            case .concurrentRequests: self.init(.busy, "The session is already responding.")
            case .transcriptMutationWhileResponding: self.init(.busy, "The transcript cannot change while the session is responding.")
            @unknown default: self.init(.generationFailed, String(describing: error))
            }
        case let error as SystemLanguageModel.Error:
            self.init(.modelUnavailable, error.debugDescription)
        default:
            self.init(.generationFailed, String(describing: error))
        }
    }
}
