import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import OpenAppleModels

/// A stateless conversation mapped onto FoundationModels: everything before
/// the final user message becomes transcript history, the final user
/// message becomes the prompt.
struct MappedConversation: Sendable {
    /// System and developer messages, joined.
    var instructions: String?
    /// Conversation entries before the prompt (no instructions entry).
    var history: [Transcript.Entry]
    /// The prompt to run. Empty when the conversation ends with tool results.
    var prompt: Prompt
    /// Plain text of the prompt (images omitted), for logging and estimates.
    var promptText: String
    /// True when the conversation ended with tool results and generation
    /// continues after them with an empty prompt.
    var continuesAfterToolOutput: Bool
}

/// Maps OpenAI chat `messages` to a FoundationModels transcript.
///
/// - `system` / `developer` → instructions, wherever they appear (a trailing
///   one does not end the conversation)
/// - `user` → prompts (text and inline images); consecutive user messages merge
/// - `assistant` content → responses; `tool_calls` → tool calls with the client's ids
/// - `tool` → tool outputs whose id is the `tool_call_id` they answer
enum MessageMapper {
    private enum UserPart {
        case text(String)
        case image(ImageDecoding.Decoded)
    }

    /// The tool calls of the latest assistant message, while their tool
    /// messages are being collected.
    private struct ToolBatch {
        /// Call ids in the order the assistant made the calls.
        var order: [String]
        var names: [String: String]
        var outputs: [String: Transcript.ToolOutput] = [:]

        var missing: [String] { order.filter { outputs[$0] == nil } }
        var isComplete: Bool { outputs.count == order.count }
        /// The outputs in call order (the order the calls were made in).
        var entries: [Transcript.Entry] { order.compactMap { outputs[$0].map(Transcript.Entry.toolOutput) } }
    }

    /// Maps `messages`, validating the conversation's shape.
    ///
    /// Tool calls are validated strictly, because on-device inference pairs
    /// each tool output with its call by id: every `tool_calls` id must be
    /// unique and answered by exactly one `tool` message, and those tool
    /// messages must directly follow the assistant message that made the
    /// calls. Outputs are placed in the transcript in call order.
    static func map(_ messages: [JSONValue]) throws(OpenAIError) -> MappedConversation {
        var instructions: [String] = []
        var entries: [Transcript.Entry] = []
        var pendingUser: [UserPart]?
        var knownCallIDs: Set<String> = []
        var batch: ToolBatch?
        var lastRole = ""

        func flushUser() {
            guard let parts = pendingUser else { return }
            entries.append(.prompt(Transcript.Prompt(segments: segments(parts))))
            pendingUser = nil
        }

        func missingOutputs(_ batch: ToolBatch, param: String) -> OpenAIError {
            .invalidRequest(
                "An assistant message with 'tool_calls' must be followed by tool messages responding to each 'tool_call_id'. "
                    + "Missing responses for: \(batch.missing.joined(separator: ", ")).",
                param: param, code: "missing_tool_output")
        }

        for (index, value) in messages.enumerated() {
            let path = "messages[\(index)]"
            let message = try JSONParams(value, path: path)
            let role = try message.requiredString("role")

            if role != "tool", let batch {
                throw missingOutputs(batch, param: path)
            }

            switch role {
            case "system", "developer":
                let text = try textContent(message, allowNull: false)
                if !text.isEmpty { instructions.append(text) }
            case "user":
                let parts = try userParts(message)
                if pendingUser == nil {
                    pendingUser = parts
                } else {
                    pendingUser! += [.text("\n\n")] + parts
                }
            case "assistant":
                flushUser()
                var text = try textContent(message, allowNull: true)
                if text.isEmpty, let refusal = try message.string("refusal") { text = refusal }
                let calls = try toolCalls(message, knownIDs: &knownCallIDs)
                if !text.isEmpty {
                    entries.append(.response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: text))])))
                }
                if !calls.isEmpty {
                    entries.append(.toolCalls(Transcript.ToolCalls(calls)))
                    batch = ToolBatch(order: calls.map(\.id), names: Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0.toolName) }))
                }
            case "tool":
                flushUser()
                let idParam = message.param("tool_call_id")
                let id = try message.requiredString("tool_call_id")
                guard var current = batch, let name = current.names[id] else {
                    if knownCallIDs.contains(id) {
                        throw .invalidRequest(
                            "Invalid 'tool_call_id' '\(id)': that tool call was already answered. Each tool call needs exactly one "
                                + "'tool' message, placed directly after the assistant message that made the call.",
                            param: idParam, code: "duplicate_tool_output")
                    }
                    throw .invalidRequest(
                        "Invalid 'tool_call_id' '\(id)': no earlier assistant message has a tool call with this id.",
                        param: idParam, code: "unknown_tool_call_id")
                }
                guard current.outputs[id] == nil else {
                    throw .invalidRequest(
                        "Invalid 'tool_call_id' '\(id)': more than one 'tool' message responds to this tool call.",
                        param: idParam, code: "duplicate_tool_output")
                }
                let text = try textContent(message, allowNull: false)
                // The output's id must equal its call's id: on-device inference
                // pairs them by id and fails to tokenize the prompt otherwise.
                current.outputs[id] = Transcript.ToolOutput(id: id, toolName: name, segments: [.text(Transcript.TextSegment(content: text))])
                if current.isComplete {
                    entries += current.entries
                    batch = nil
                } else {
                    batch = current
                }
            case "function":
                throw message.invalid("role", "The legacy 'function' role is not supported; use 'tool' messages.")
            default:
                throw message.invalid("role", "Invalid role '\(role)': expected 'system', 'developer', 'user', 'assistant' or 'tool'.")
            }
            // Instructions can appear anywhere (even last) without changing
            // the turn structure: only conversation turns decide the prompt.
            if role != "system", role != "developer" { lastRole = role }
        }
        if let batch { throw missingOutputs(batch, param: "messages") }

        let joinedInstructions = instructions.isEmpty ? nil : instructions.joined(separator: "\n\n")
        switch lastRole {
        case "user":
            let parts = pendingUser ?? []
            return MappedConversation(
                instructions: joinedInstructions, history: entries, prompt: prompt(parts),
                promptText: plainText(parts), continuesAfterToolOutput: false)
        case "tool":
            return MappedConversation(
                instructions: joinedInstructions, history: entries, prompt: Prompt(""),
                promptText: "", continuesAfterToolOutput: true)
        case "assistant":
            throw .invalidRequest(
                "The last message must be a 'user' or 'tool' message; a trailing 'assistant' message (response prefill) is not supported.",
                param: "messages", code: "invalid_last_message")
        default:
            throw .invalidRequest("The conversation needs at least one 'user' message.", param: "messages", code: "missing_user_message")
        }
    }

    // MARK: Content

    /// Text of a message whose content is a string or an array of text parts.
    private static func textContent(_ message: JSONParams, allowNull: Bool) throws(OpenAIError) -> String {
        guard let content = message.value("content") else {
            if allowNull { return "" }
            throw message.missing("content")
        }
        if let string = content.stringValue { return string }
        guard let parts = content.arrayValue else { throw message.typeError("content", "a string or an array of content parts") }
        var texts: [String] = []
        for (index, value) in parts.enumerated() {
            let part = try JSONParams(value, path: message.param("content[\(index)]"))
            let type = try part.requiredString("type")
            switch type {
            case "text": texts.append(try part.requiredString("text"))
            case "refusal": texts.append(try part.requiredString("refusal"))
            default: throw part.invalid("type", "Content parts of type '\(type)' are only supported in user messages.")
            }
        }
        return texts.joined(separator: "\n")
    }

    private static func userParts(_ message: JSONParams) throws(OpenAIError) -> [UserPart] {
        guard let content = message.value("content") else { throw message.missing("content") }
        if let string = content.stringValue { return [.text(string)] }
        guard let array = content.arrayValue else { throw message.typeError("content", "a string or an array of content parts") }
        var parts: [UserPart] = []
        for (index, value) in array.enumerated() {
            let part = try JSONParams(value, path: message.param("content[\(index)]"))
            let type = try part.requiredString("type")
            switch type {
            case "text":
                let text = try part.requiredString("text")
                if case .text(let previous)? = parts.last {
                    parts[parts.count - 1] = .text(previous + "\n" + text)
                } else {
                    parts.append(.text(text))
                }
            case "image_url":
                let image: JSONParams
                if let string = try? part.string("image_url") {
                    image = JSONParams(JSONObject([("url", .string(string))]), path: part.param("image_url"))
                } else {
                    image = try part.requiredObject("image_url")
                }
                let url = try image.requiredString("url")
                parts.append(.image(try ImageDecoding.decode(dataURL: url, param: image.param("url"))))
            case "input_audio":
                throw part.invalid("type", "Audio input is not supported by the on-device model.")
            case "file":
                throw part.invalid("type", "File inputs are not supported; send text or images.")
            default:
                throw part.invalid("type", "Unsupported content part type '\(type)'.")
            }
        }
        return parts
    }

    /// The `tool_calls` of an assistant message. Call ids must be non-empty
    /// and unique across the conversation; each is added to `knownIDs`.
    private static func toolCalls(_ message: JSONParams, knownIDs: inout Set<String>) throws(OpenAIError) -> [Transcript.ToolCall] {
        guard let calls = try message.array("tool_calls") else { return [] }
        var result: [Transcript.ToolCall] = []
        for (index, value) in calls.enumerated() {
            let call = try JSONParams(value, path: message.param("tool_calls[\(index)]"))
            let id = try call.requiredString("id")
            guard !id.isEmpty else { throw call.invalid("id", "A tool call 'id' must not be empty.") }
            guard knownIDs.insert(id).inserted else {
                throw .invalidRequest(
                    "Duplicate tool call id '\(id)': every tool call in the conversation needs a unique id.",
                    param: call.param("id"), code: "duplicate_tool_call_id")
            }
            let type = try call.string("type") ?? "function"
            guard type == "function" else { throw call.invalid("type", "Unsupported tool call type '\(type)'.") }
            let function = try call.requiredObject("function")
            let name = try function.requiredString("name")
            guard !name.isEmpty else { throw function.invalid("name", "A tool call's function 'name' must not be empty.") }
            let argumentsText = try function.string("arguments") ?? ""
            var arguments: JSONValue = [:]
            if !argumentsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    arguments = try JSONValue(parsing: argumentsText)
                } catch {
                    throw function.invalid("arguments", "'arguments' must be a JSON-encoded object: \(error)")
                }
                if arguments.isNull { arguments = [:] }
                guard case .object = arguments else {
                    throw function.invalid("arguments", "'arguments' must be a JSON-encoded object, got: \(argumentsText.prefix(80))")
                }
            }
            result.append(Transcript.ToolCall(id: id, toolName: name, arguments: arguments.generatedContent))
        }
        return result
    }

    // MARK: Rendering

    private static func segments(_ parts: [UserPart]) -> [Transcript.Segment] {
        parts.map { part in
            switch part {
            case .text(let text):
                .text(Transcript.TextSegment(content: text))
            case .image(let decoded):
                .attachment(Transcript.AttachmentSegment(content: .image(Transcript.ImageAttachment(decoded.image, orientation: decoded.orientation))))
            }
        }
    }

    private static func prompt(_ parts: [UserPart]) -> Prompt {
        guard parts.contains(where: { if case .image = $0 { true } else { false } }) else {
            return Prompt(plainText(parts))
        }
        let pieces: [Prompt] = parts.map { part in
            switch part {
            case .text(let text): Prompt(text)
            case .image(let decoded): Prompt(Attachment(decoded.image, orientation: decoded.orientation))
            }
        }
        return Prompt(pieces)
    }

    private static func plainText(_ parts: [UserPart]) -> String {
        parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }
}
