import Foundation
import OpenAppleModels

/// Builds `chat.completion` objects and `chat.completion.chunk` server-sent events.
struct CompletionEncoder: Sendable {
    let id: String
    let created: Int
    let model: String

    static let systemFingerprint = "fp_open_apple_models"

    init(model: String, id: String = CompletionEncoder.makeID(), created: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id
        self.created = created
        self.model = model
    }

    static func makeID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "chatcmpl-" + String((0..<29).map { _ in alphabet.randomElement()! })
    }

    // MARK: Complete responses

    func completion(content: String?, refusal: String?, toolCalls: [ToolCall], finishReason: FinishReason, usage: CompletionUsage) -> JSONValue {
        var message: JSONObject = [
            "role": "assistant",
            "content": content.map(JSONValue.string) ?? .null,
            "refusal": refusal.map(JSONValue.string) ?? .null,
        ]
        if !toolCalls.isEmpty {
            message["tool_calls"] = .array(toolCalls.map(Self.toolCall))
        }
        message["annotations"] = []
        return [
            "id": .string(id),
            "object": "chat.completion",
            "created": .number(Double(created)),
            "model": .string(model),
            "system_fingerprint": .string(Self.systemFingerprint),
            "choices": [
                [
                    "index": 0,
                    "message": .object(message),
                    "logprobs": nil,
                    "finish_reason": .string(finishReason.rawValue),
                ],
            ],
            "usage": Self.usage(usage),
        ]
    }

    static func toolCall(_ call: ToolCall) -> JSONValue {
        [
            "id": .string(call.id),
            "type": "function",
            "function": ["name": .string(call.name), "arguments": .string(call.arguments.serialized())],
        ]
    }

    static func usage(_ usage: CompletionUsage) -> JSONValue {
        [
            "prompt_tokens": .number(Double(usage.promptTokens)),
            "completion_tokens": .number(Double(usage.completionTokens)),
            "total_tokens": .number(Double(usage.totalTokens)),
            "prompt_tokens_details": ["cached_tokens": .number(Double(usage.cachedTokens))],
            "completion_tokens_details": ["reasoning_tokens": 0],
        ]
    }

    // MARK: Streaming

    /// A `chat.completion.chunk` with one choice.
    func chunk(delta: JSONObject, finishReason: FinishReason? = nil, includeUsage: Bool) -> JSONValue {
        var object: JSONObject = [
            "id": .string(id),
            "object": "chat.completion.chunk",
            "created": .number(Double(created)),
            "model": .string(model),
            "system_fingerprint": .string(Self.systemFingerprint),
            "choices": [
                [
                    "index": 0,
                    "delta": .object(delta),
                    "logprobs": nil,
                    "finish_reason": finishReason.map { .string($0.rawValue) } ?? .null,
                ],
            ],
        ]
        if includeUsage { object["usage"] = JSONValue.null }
        return .object(object)
    }

    /// The final usage chunk sent when `stream_options.include_usage` is set.
    func usageChunk(_ usage: CompletionUsage) -> JSONValue {
        [
            "id": .string(id),
            "object": "chat.completion.chunk",
            "created": .number(Double(created)),
            "model": .string(model),
            "system_fingerprint": .string(Self.systemFingerprint),
            "choices": [],
            "usage": Self.usage(usage),
        ]
    }

    /// Streamed tool calls: one delta carrying every call with its full arguments.
    static func toolCallsDelta(_ calls: [ToolCall]) -> JSONObject {
        [
            "tool_calls": .array(calls.enumerated().map { index, call in
                [
                    "index": .number(Double(index)),
                    "id": .string(call.id),
                    "type": "function",
                    "function": ["name": .string(call.name), "arguments": .string(call.arguments.serialized())],
                ]
            }),
        ]
    }

    /// Frames a JSON value as a server-sent event.
    static func event(_ value: JSONValue) -> Data {
        Data(("data: " + value.serialized() + "\n\n").utf8)
    }

    static let done = Data("data: [DONE]\n\n".utf8)
}
