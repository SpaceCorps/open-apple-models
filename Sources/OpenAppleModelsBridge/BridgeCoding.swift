import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsTesting

/// The JSON shapes shared by bridge methods: encoders for agent results and
/// events, and decoders for tool definitions, policies, schemas and
/// transcripts. Extensions use these so every method speaks the same dialect.
public enum BridgeCoding {
    // MARK: Encoding

    /// `{"id", "name", "arguments"}`.
    public static func json(_ call: ToolCall) -> JSONValue {
        ["id": .string(call.id), "name": .string(call.name), "arguments": call.arguments]
    }

    /// Text outputs and error messages become strings; JSON outputs stay JSON.
    public static func json(_ output: ToolOutput) -> JSONValue {
        switch output {
        case .text(let text): .string(text)
        case .json(let value): value
        case .error(let message): .string(message)
        }
    }

    /// `{"call", "output", "isError", "durationSeconds"}`.
    public static func json(_ record: ToolRecord) -> JSONValue {
        [
            "call": json(record.call),
            "output": json(record.output),
            "isError": .bool(record.output.isError),
            "durationSeconds": .number((record.duration * 1000).rounded() / 1000),
        ]
    }

    /// `{"inputTokens", "cachedInputTokens", "outputTokens", "totalTokens"}`.
    public static func json(_ usage: TokenUsage) -> JSONValue {
        [
            "inputTokens": .number(Double(usage.inputTokens)),
            "cachedInputTokens": .number(Double(usage.cachedInputTokens)),
            "outputTokens": .number(Double(usage.outputTokens)),
            "totalTokens": .number(Double(usage.totalTokens)),
        ]
    }

    /// `{"index", "completedToolRounds", "toolCallingMode", "enabledTools", "trimmedEntries"}`.
    public static func json(_ step: ModelStep) -> JSONValue {
        [
            "index": .number(Double(step.index)),
            "completedToolRounds": .number(Double(step.completedToolRounds)),
            "toolCallingMode": .string(name(of: step.toolCallingMode)),
            "enabledTools": .array(step.enabledTools.map(JSONValue.string)),
            "trimmedEntries": .number(Double(step.trimmedEntries)),
        ]
    }

    /// `{"text", "structured"?, "toolCalls", "usage", "steps"}` — the body of
    /// a turn result. Callers usually prepend their own id field.
    public static func json(_ response: AgentResponse) -> JSONObject {
        var object: JSONObject = ["text": .string(response.text)]
        if let structured = response.structured { object["structured"] = structured }
        object["toolCalls"] = .array(response.toolCalls.map(json))
        object["usage"] = json(response.usage)
        object["steps"] = .array(response.steps.map(json))
        return object
    }

    /// The `event` payload of a streaming notification, or `nil` for events
    /// that are not streamed (`completed` is delivered as the response).
    public static func json(_ event: AgentEvent) -> JSONValue? {
        switch event {
        case .modelStep(let step):
            ["type": "modelStep", "step": json(step)]
        case .text(let delta, let text, let isReset):
            ["type": "text", "delta": .string(delta), "text": .string(text), "isReset": .bool(isReset)]
        case .partial(let value):
            ["type": "partial", "value": value]
        case .toolCallStarted(let call):
            ["type": "toolCallStarted", "call": json(call), "execution": "local"]
        case .toolCallRequested(let call):
            ["type": "toolCallStarted", "call": json(call), "execution": "client"]
        case .toolCallCompleted(let record):
            ["type": "toolCallCompleted", "record": json(record)]
        case .completed:
            nil
        }
    }

    /// A transcript as a JSON object (FoundationModels' `Codable` form),
    /// suitable for saving and for `history` in `session/create`.
    public static func json(_ transcript: Transcript) throws(BridgeError) -> JSONValue {
        do {
            return try JSONValue(encoding: transcript)
        } catch {
            throw .internalError("Could not encode the transcript: \(error)")
        }
    }

    /// A `GenerationSchema` in FoundationModels' encoded (JSON Schema–like) form.
    public static func json(_ schema: GenerationSchema) -> JSONValue {
        (try? JSONValue(encoding: schema)) ?? .null
    }

    /// A tool as `{"name", "description", "parameters", "execution"}`.
    public static func json(_ tool: AgentTool) -> JSONValue {
        [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.parameters.json,
            "execution": tool.isExternal ? "client" : "local",
        ]
    }

    static func name(of mode: GenerationOptions.ToolCallingMode.Kind) -> String {
        switch mode {
        case .allowed: "allowed"
        case .required: "required"
        case .disallowed: "disallowed"
        @unknown default: "unknown"
        }
    }

    // MARK: Decoding

    /// Decodes a transcript saved from `session/transcript`. Accepts the
    /// transcript object itself or the whole `session/transcript` result.
    public static func transcript(from value: JSONValue, path: String = "history") throws(BridgeError) -> Transcript {
        guard case .object(let object) = value else {
            throw .invalidParams("'\(path)' must be a transcript object from session/transcript.")
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Transcript.self, from: Data(value.serialized().utf8))
        } catch {
            if let inner = object["transcript"], inner.objectValue != nil,
               let transcript = try? decoder.decode(Transcript.self, from: Data(inner.serialized().utf8)) {
                return transcript
            }
            throw .invalidParams("'\(path)' is not a valid transcript: \(error)")
        }
    }

    /// The instructions and tool definitions saved in a transcript's leading
    /// instructions entry.
    public struct SavedSetup: Sendable {
        /// The instruction text, or `nil` when the transcript had none.
        public var instructions: String?
        /// The tool definitions the model saw.
        public var tools: [Transcript.ToolDefinition]
    }

    /// Reads the instructions entry at the start of a saved transcript.
    /// Returns `nil` when the transcript does not start with one.
    public static func savedSetup(of transcript: Transcript) -> SavedSetup? {
        guard case .instructions(let entry)? = transcript.first else { return nil }
        let text = BridgeScript.text(of: entry.segments)
        return SavedSetup(instructions: text.isEmpty ? nil : text, tools: entry.toolDefinitions)
    }

    /// Recreates client-executed tools from definitions saved in a transcript
    /// (their argument schemas are converted back to JSON Schema). Definitions
    /// that cannot be restored are skipped with a warning.
    public static func clientTools(restoring definitions: [Transcript.ToolDefinition], defaultTimeout: Duration?) -> (tools: [AgentTool], warnings: [String]) {
        var tools: [AgentTool] = []
        var warnings: [String] = []
        var names: Set<String> = []
        for definition in definitions where names.insert(definition.name).inserted {
            do {
                let parameters = try JSONSchema(definition.parameters)
                tools.append(try AgentTool.external(
                    name: definition.name, description: definition.description, parameters: parameters, timeout: defaultTimeout))
            } catch {
                warnings.append("\(definition.name): could not be restored from 'history' (\(error)); send its definition in 'tools'.")
            }
        }
        return (tools, warnings)
    }

    /// `"auto" | "none" | "required" | {"tool": name}` (a bare tool name is
    /// not accepted, so typos are caught).
    public static func toolChoice(_ value: JSONValue, path: String = "toolChoice") throws(BridgeError) -> ToolChoice {
        switch value {
        case .string("auto"): return .auto
        case .string("none"): return .none
        case .string("required"): return .required
        case .object(let object):
            if let name = object["tool"]?.stringValue, !name.isEmpty { return .tool(name) }
            // OpenAI form: {"type": "function", "function": {"name": ...}}
            if let name = object["function"]?["name"]?.stringValue, !name.isEmpty { return .tool(name) }
            throw .invalidParams("'\(path)' object must be {\"tool\": \"<name>\"}.")
        default:
            throw .invalidParams("'\(path)' must be \"auto\", \"none\", \"required\" or {\"tool\": \"<name>\"}; got \(value).")
        }
    }

    /// Applies `toolChoice`, `maxToolRounds`, `maxToolCalls` and
    /// `enabledTools` from `params` on top of `base`.
    public static func toolPolicy(from params: BridgeParams, base: ToolPolicy) throws(BridgeError) -> ToolPolicy {
        var policy = base
        if let choice = params["toolChoice"] { policy.choice = try toolChoice(choice, path: params.path + "toolChoice") }
        if let rounds = try params.optionalInt("maxToolRounds", minimum: 0) { policy.maxToolRounds = rounds }
        if let calls = try params.optionalInt("maxToolCalls", minimum: 0) { policy.maxToolCalls = calls }
        if let enabled = try params.optionalStrings("enabledTools") { policy.enabledTools = Set(enabled) }
        return policy
    }

    /// A JSON Schema object (or the boolean `true`).
    public static func schema(_ value: JSONValue, path: String = "schema") throws(BridgeError) -> JSONSchema {
        switch value {
        case .object: return JSONSchema(value)
        case .string(let text):
            // Tolerate schemas sent as JSON text.
            guard let parsed = try? JSONValue(parsing: text), parsed.objectValue != nil else {
                throw .invalidParams("'\(path)' must be a JSON Schema object.")
            }
            return JSONSchema(parsed)
        default:
            throw .invalidParams("'\(path)' must be a JSON Schema object.")
        }
    }

    /// Converts a schema, mapping conversion errors to `invalid_schema`
    /// (with `data.path`). Returns the schema and its warnings.
    public static func convert(_ schema: JSONSchema, name: String, path: String) throws(BridgeError) -> SchemaConverter.Result {
        do {
            return try SchemaConverter.convert(schema, rootName: name)
        } catch {
            throw schemaError(error, path: path)
        }
    }

    static func schemaError(_ error: SchemaConversionError, path: String) -> BridgeError {
        BridgeError(code: BridgeError.Code.invalidSchema, name: AgentError.Code.invalidSchema.rawValue,
                    message: "\(path): \(error.message) (at \(error.path))",
                    extra: ["path": .string(path), "schemaPath": .string(error.path)])
    }

    /// Parses client tool definitions:
    /// `[{"name", "description", "parameters"?, "execution"?: "client", "timeoutSeconds"?}]`.
    /// OpenAI's `{"type": "function", "function": {...}}` wrapper is accepted.
    ///
    /// - Parameter defaultTimeout: Applied to tools without `timeoutSeconds`.
    /// - Returns: The tools and conversion warnings (prefixed with the tool name).
    public static func tools(from value: JSONValue, defaultTimeout: Duration?, path: String = "tools") throws(BridgeError) -> (tools: [AgentTool], warnings: [String]) {
        guard let array = value.arrayValue else { throw .invalidParams("'\(path)' must be an array of tool definitions.") }
        var tools: [AgentTool] = []
        var warnings: [String] = []
        var names: Set<String> = []
        for (index, element) in array.enumerated() {
            let elementPath = "\(path)[\(index)]"
            var definition = element
            if let function = element["function"], function.objectValue != nil { definition = function }
            guard let object = definition.objectValue else { throw .invalidParams("'\(elementPath)' must be an object.") }
            let params = BridgeParams(object, path: elementPath + ".")
            let name = try params.string("name")
            guard isValidToolName(name) else {
                throw .invalidParams("'\(elementPath).name' must be 1-64 characters of letters, digits, '_', '-' or '.'; got '\(name)'.")
            }
            guard names.insert(name).inserted else { throw .invalidParams("Duplicate tool name '\(name)'.") }
            let description = try params.optionalString("description") ?? ""
            if description.isEmpty { warnings.append("\(name): no description; the model may not know when to call it.") }
            let execution = try params.optionalString("execution") ?? "client"
            guard execution == "client" else {
                throw .invalidParams("'\(elementPath).execution' must be \"client\" (the engine executes the tool via tool/call); got '\(execution)'.")
            }
            let parameters = try params["parameters"].map { value throws(BridgeError) in
                try schema(value, path: elementPath + ".parameters")
            } ?? .empty
            var timeout = defaultTimeout
            if let seconds = try params.optionalDouble("timeoutSeconds", minimum: 0) {
                timeout = seconds == 0 ? nil : .milliseconds(Int((seconds * 1000).rounded()))
            }
            let tool: AgentTool
            do {
                tool = try AgentTool.external(name: name, description: description, parameters: parameters, timeout: timeout)
            } catch {
                throw schemaError(error, path: elementPath + ".parameters")
            }
            tools.append(tool)
            warnings.append(contentsOf: tool.schemaWarnings.map { "\(name): \($0)" })
        }
        return (tools, warnings)
    }

    static func isValidToolName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || "_-.".unicodeScalars.contains(scalar)
        }
    }

    /// Converts a peer's `tool/call` response into tool output:
    /// `{"output": "text"}` → text, `{"output": <JSON>}` → JSON,
    /// `"isError": true` → an error the model sees, and a JSON-RPC error
    /// response → an error output with its message.
    public static func toolOutput(from result: Result<JSONValue, BridgeError>) -> ToolOutput {
        switch result {
        case .failure(let error):
            return .error(error.message)
        case .success(let value):
            let isError = value["isError"]?.boolValue ?? false
            // Lenient: a result without "output" is itself the output.
            let output = value.objectValue?["output"] ?? value
            if isError { return .error(output.stringValue ?? output.serialized()) }
            if let text = output.stringValue { return .text(text) }
            return .json(output)
        }
    }

    /// `"greedy" | {"topK": n, "seed"?: n} | {"topP": p, "seed"?: n}`.
    public static func sampling(_ value: JSONValue, path: String = "sampling") throws(BridgeError) -> GenerationOptions.SamplingMode {
        if value == "greedy" { return .greedy }
        guard let object = value.objectValue else {
            throw .invalidParams("'\(path)' must be \"greedy\", {\"topK\": n} or {\"topP\": p}.")
        }
        let params = BridgeParams(object, path: path + ".")
        let seed = try params.optionalInt("seed", minimum: 0).map { UInt64($0) }
        if let k = try params.optionalInt("topK", minimum: 1) { return .random(top: k, seed: seed) }
        if let p = try params.optionalDouble("topP", minimum: 0) {
            guard p <= 1 else { throw .invalidParams("'\(path).topP' must be between 0 and 1.") }
            return .random(probabilityThreshold: p, seed: seed)
        }
        throw .invalidParams("'\(path)' must contain 'topK' or 'topP'.")
    }

    /// Parses a `model` parameter: absent/`"system"`, `"scripted"` (empty
    /// script), `{"type": "system"}`, `{"type": "scripted", "steps": [...]}`,
    /// or `{"type": "<custom>", ...}` for ``BridgeConfiguration/modelFactory``.
    public static func modelSpec(_ value: JSONValue?, path: String = "model") throws(BridgeError) -> BridgeModelSpec {
        guard let value, !value.isNull else { return .system }
        if let name = value.stringValue {
            switch name {
            case "system": return .system
            case "scripted": return .scripted(ModelScript([]))
            default: return .custom(type: name, options: ["type": .string(name)])
            }
        }
        guard let object = value.objectValue else {
            throw .invalidParams("'\(path)' must be \"system\" or an object with a 'type'.")
        }
        let type = try BridgeParams(object, path: path + ".").string("type")
        switch type {
        case "system": return .system
        case "scripted": return .scripted(try BridgeScript.parse(value, path: path))
        default: return .custom(type: type, options: value)
        }
    }
}
