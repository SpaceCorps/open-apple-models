import Foundation
import FoundationModels
import OpenAppleModels

/// A validated `POST /v1/chat/completions` request body.
///
/// Parsed from ``JSONValue`` rather than `Codable` so JSON Schemas keep
/// their property order (the model generates properties in that order).
struct ChatCompletionRequest: Sendable {
    struct FunctionTool: Sendable {
        var name: String
        var description: String
        var parameters: JSONSchema
    }

    enum ToolChoiceSpec: Sendable, Equatable {
        case auto
        case none
        case required
        case function(String)
        /// OpenAI `allowed_tools`: restrict to `names`, optionally requiring a call.
        case allowed(Set<String>, required: Bool)
    }

    enum ResponseFormat: Sendable {
        case text
        case jsonObject
        case jsonSchema(name: String, schema: JSONSchema)
    }

    var model: String?
    var messages: [JSONValue]
    var stream: Bool
    var includeUsage: Bool
    var tools: [FunctionTool]
    var toolChoice: ToolChoiceSpec?
    var parallelToolCalls: Bool
    var temperature: Double?
    var topP: Double?
    var seed: Int?
    var maxTokens: Int?
    var stop: [String]
    var responseFormat: ResponseFormat

    init(body: Data) throws(OpenAIError) {
        let json: JSONValue
        do {
            json = try JSONValue(parsing: body)
        } catch {
            throw OpenAIError.invalidJSONBody
        }
        try self.init(json: json)
    }

    init(json: JSONValue) throws(OpenAIError) {
        let params = try JSONParams(json, path: "")

        model = try params.string("model")
        guard let messages = try params.array("messages") else { throw params.missing("messages") }
        guard !messages.isEmpty else {
            throw params.invalid("messages", "'messages' must contain at least one message.")
        }
        self.messages = messages

        stream = try params.bool("stream") ?? false
        includeUsage = try params.object("stream_options")?.bool("include_usage") ?? false

        if let n = try params.int("n"), n != 1 {
            throw params.invalid("n", "Only n=1 is supported by the on-device model.")
        }
        if let modalities = try params.array("modalities"), modalities.contains(where: { $0.stringValue == "audio" }) {
            throw params.invalid("modalities", "Audio output is not supported.")
        }
        if params.has("audio") { throw params.invalid("audio", "Audio output is not supported.") }
        if params.has("functions") || params.has("function_call") {
            throw params.invalid(params.has("functions") ? "functions" : "function_call",
                                 "The legacy 'functions' API is not supported; use 'tools' and 'tool_choice'.")
        }

        temperature = try params.double("temperature")
        if let temperature, !(0...2).contains(temperature) {
            throw params.invalid("temperature", "'temperature' must be between 0 and 2.")
        }
        topP = try params.double("top_p")
        if let topP, !(topP > 0 && topP <= 1) {
            throw params.invalid("top_p", "'top_p' must be greater than 0 and at most 1.")
        }
        seed = try params.int("seed")

        let maxCompletionTokens = try params.int("max_completion_tokens")
        let legacyMaxTokens = try params.int("max_tokens")
        maxTokens = maxCompletionTokens ?? legacyMaxTokens
        if let maxTokens, maxTokens < 1 {
            throw params.invalid(maxCompletionTokens != nil ? "max_completion_tokens" : "max_tokens", "The token limit must be at least 1.")
        }

        stop = try Self.parseStop(params)
        tools = try Self.parseTools(params)
        parallelToolCalls = try params.bool("parallel_tool_calls") ?? true
        toolChoice = try Self.parseToolChoice(params)
        responseFormat = try Self.parseResponseFormat(params)
    }

    // MARK: Parameters

    private static func parseStop(_ params: JSONParams) throws(OpenAIError) -> [String] {
        guard let value = params.value("stop") else { return [] }
        let values: [String]
        if let string = value.stringValue {
            values = [string]
        } else if let array = value.arrayValue {
            var strings: [String] = []
            for (index, element) in array.enumerated() {
                guard let string = element.stringValue else {
                    throw .invalidRequest("Invalid type for 'stop[\(index)]': expected a string.", param: "stop[\(index)]", code: "invalid_type")
                }
                strings.append(string)
            }
            values = strings
        } else {
            throw params.typeError("stop", "a string or an array of strings")
        }
        guard values.count <= 4 else { throw params.invalid("stop", "'stop' accepts at most 4 sequences.") }
        return values.filter { !$0.isEmpty }
    }

    private static func parseTools(_ params: JSONParams) throws(OpenAIError) -> [FunctionTool] {
        guard let tools = try params.array("tools") else { return [] }
        var result: [FunctionTool] = []
        var names: Set<String> = []
        for (index, value) in tools.enumerated() {
            let tool = try JSONParams(value, path: "tools[\(index)]")
            let type = try tool.string("type") ?? "function"
            guard type == "function" else {
                throw tool.invalid("type", "Unsupported tool type '\(type)'. Only 'function' tools are supported.")
            }
            let function = try tool.requiredObject("function")
            let name = try function.requiredString("name")
            guard Self.isValidToolName(name) else {
                throw function.invalid("name", "Invalid tool name '\(name)': use 1-64 letters, digits, underscores or dashes.")
            }
            guard names.insert(name).inserted else {
                throw function.invalid("name", "Duplicate tool name '\(name)'.")
            }
            let description = try function.string("description") ?? ""
            var parameters = JSONSchema.empty
            if let schema = function.value("parameters") {
                guard case .object = schema else { throw function.typeError("parameters", "a JSON Schema object") }
                parameters = JSONSchema(schema)
            }
            result.append(FunctionTool(name: name, description: description, parameters: parameters))
        }
        return result
    }

    static func isValidToolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    private static func parseToolChoice(_ params: JSONParams) throws(OpenAIError) -> ToolChoiceSpec? {
        guard let value = params.value("tool_choice") else { return nil }
        if let string = value.stringValue {
            switch string {
            case "auto": return .auto
            case "none": return ToolChoiceSpec.none
            case "required": return .required
            default: throw params.invalid("tool_choice", "Invalid 'tool_choice' '\(string)': expected 'auto', 'none', 'required' or an object.")
            }
        }
        let choice = try JSONParams(value, path: "tool_choice")
        let type = try choice.requiredString("type")
        switch type {
        case "function":
            let function = try choice.requiredObject("function")
            return .function(try function.requiredString("name"))
        case "allowed_tools":
            let allowed = try choice.requiredObject("allowed_tools")
            let mode = try allowed.string("mode") ?? "auto"
            guard mode == "auto" || mode == "required" else {
                throw allowed.invalid("mode", "Invalid mode '\(mode)': expected 'auto' or 'required'.")
            }
            var names: Set<String> = []
            for (index, tool) in (try allowed.array("tools") ?? []).enumerated() {
                let entry = try JSONParams(tool, path: allowed.param("tools[\(index)]"))
                if let function = try entry.object("function") {
                    names.insert(try function.requiredString("name"))
                } else {
                    names.insert(try entry.requiredString("name"))
                }
            }
            return .allowed(names, required: mode == "required")
        default:
            throw choice.invalid("type", "Unsupported tool_choice type '\(type)'.")
        }
    }

    private static func parseResponseFormat(_ params: JSONParams) throws(OpenAIError) -> ResponseFormat {
        guard let format = try params.object("response_format") else { return .text }
        let type = try format.requiredString("type")
        switch type {
        case "text":
            return .text
        case "json_object":
            return .jsonObject
        case "json_schema":
            let spec = try format.requiredObject("json_schema")
            let name = try spec.string("name") ?? "Response"
            guard let schema = spec.value("schema") else { throw spec.missing("schema") }
            guard case .object = schema else { throw spec.typeError("schema", "a JSON Schema object") }
            _ = try spec.bool("strict")  // Accepted; generation is always constrained.
            return .jsonSchema(name: name, schema: JSONSchema(schema))
        default:
            throw format.invalid("type", "Invalid response_format type '\(type)': expected 'text', 'json_object' or 'json_schema'.")
        }
    }
}
