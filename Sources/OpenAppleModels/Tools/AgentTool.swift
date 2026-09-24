import Foundation
import FoundationModels

/// A tool invocation produced by the model.
public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String = ToolCall.makeID(), name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// OpenAI-style call identifier (`call_` + 24 alphanumerics).
    public static func makeID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "call_" + String((0..<24).map { _ in alphabet.randomElement()! })
    }
}

// MARK: Argument access

/// Thrown by ``ToolCall`` accessors when an argument is missing or mistyped.
/// Tool errors are reported back to the model, which usually retries with
/// corrected arguments.
public struct ToolArgumentError: LocalizedError, Sendable, CustomStringConvertible {
    public var message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

extension ToolCall {
    public func string(_ key: String) throws(ToolArgumentError) -> String {
        guard let value = arguments[key]?.stringValue else { throw missing(key, "a string") }
        return value
    }

    public func int(_ key: String) throws(ToolArgumentError) -> Int {
        guard let value = arguments[key]?.intValue else { throw missing(key, "an integer") }
        return value
    }

    public func double(_ key: String) throws(ToolArgumentError) -> Double {
        guard let value = arguments[key]?.doubleValue else { throw missing(key, "a number") }
        return value
    }

    public func bool(_ key: String) throws(ToolArgumentError) -> Bool {
        guard let value = arguments[key]?.boolValue else { throw missing(key, "a boolean") }
        return value
    }

    /// Decodes the whole argument object into a `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try arguments.decode(type)
    }

    private func missing(_ key: String, _ kind: String) -> ToolArgumentError {
        ToolArgumentError(message: "Argument '\(key)' of tool '\(name)' must be \(kind); got \(arguments[key]?.serialized() ?? "nothing").")
    }
}

// MARK: Output

/// What a tool returns to the model.
public enum ToolOutput: Sendable, Hashable, Codable {
    /// Plain text shown to the model.
    case text(String)
    /// Structured data, serialized as compact JSON for the model.
    case json(JSONValue)
    /// A failure the model should see and may recover from (e.g. by retrying
    /// with different arguments). Does not abort the turn.
    case error(String)

    /// The text the model receives.
    public var modelText: String {
        switch self {
        case .text(let text): text
        case .json(let value): value.serialized()
        case .error(let message): "Error: " + message
        }
    }

    public var isError: Bool { if case .error = self { true } else { false } }

    /// Encodes any `Encodable` as JSON output.
    public static func encoding(_ value: some Encodable) throws -> ToolOutput {
        .json(try JSONValue(encoding: value))
    }
}

extension ToolOutput: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
}

// MARK: Tool definition

/// A tool the model can call, defined at runtime.
///
/// Tools are either **local** (a Swift closure runs in-process) or
/// **external** (the call is surfaced as ``AgentEvent/toolCallRequested(_:)``
/// and the host — a game engine, an HTTP client, a script — supplies the
/// output through ``AgentRun/submit(_:for:)``).
public struct AgentTool: Sendable {
    public typealias Handler = @Sendable (ToolCall) async throws -> ToolOutput

    public enum Execution: Sendable {
        case local(Handler)
        case external
    }

    public let name: String
    public let description: String
    /// The argument schema as JSON Schema (what HTTP and bridge clients see).
    public let parameters: JSONSchema
    /// The argument schema as the model sees it.
    public let generationSchema: GenerationSchema
    public var execution: Execution
    /// Per-call time limit. On timeout the model receives an error output.
    public var timeout: Duration?
    /// Warnings from converting ``parameters`` (constraints the model cannot enforce).
    public let schemaWarnings: [String]

    /// Creates a local tool from a JSON Schema and a handler.
    public init(
        name: String,
        description: String,
        parameters: JSONSchema = .empty,
        timeout: Duration? = nil,
        handler: @escaping Handler
    ) throws(SchemaConversionError) {
        try self.init(name: name, description: description, parameters: parameters, timeout: timeout, execution: .local(handler))
    }

    /// Creates a tool with explicit execution mode.
    public init(
        name: String,
        description: String,
        parameters: JSONSchema = .empty,
        timeout: Duration? = nil,
        execution: Execution
    ) throws(SchemaConversionError) {
        let converted = try SchemaConverter.convert(parameters, rootName: Self.typeName(for: name))
        self.name = name
        self.description = description
        self.parameters = parameters
        self.generationSchema = converted.schema
        self.schemaWarnings = converted.warnings
        self.execution = execution
        self.timeout = timeout
    }

    /// Creates an external tool: the host executes it (see ``AgentRun``).
    public static func external(
        name: String,
        description: String,
        parameters: JSONSchema = .empty,
        timeout: Duration? = nil
    ) throws(SchemaConversionError) -> AgentTool {
        try AgentTool(name: name, description: description, parameters: parameters, timeout: timeout, execution: .external)
    }

    /// Wraps a FoundationModels `Tool` (e.g. one using `@Generable` arguments).
    public init<T: Tool>(_ tool: T, timeout: Duration? = nil) {
        self.name = tool.name
        self.description = tool.description
        self.generationSchema = tool.parameters
        self.parameters = (try? JSONSchema(tool.parameters)) ?? .empty
        self.schemaWarnings = []
        self.timeout = timeout
        self.execution = .local { call in
            let arguments = try T.Arguments(call.arguments.generatedContent)
            let output = try await tool.call(arguments: arguments)
            return .text(Self.render(output))
        }
    }

    /// A decodable-arguments convenience: `handler` receives `Arguments`
    /// decoded from the model's JSON.
    public static func typed<Arguments: Decodable & Sendable>(
        name: String,
        description: String,
        parameters: JSONSchema,
        arguments: Arguments.Type = Arguments.self,
        timeout: Duration? = nil,
        handler: @escaping @Sendable (Arguments) async throws -> ToolOutput
    ) throws(SchemaConversionError) -> AgentTool {
        try AgentTool(name: name, description: description, parameters: parameters, timeout: timeout) { call in
            try await handler(try call.decode(Arguments.self))
        }
    }

    public var isExternal: Bool { if case .external = execution { true } else { false } }

    /// Name of the built-in tool behind ``ToolChoice/explicit``. It is never
    /// reported in events or responses, and user tools may not use the name.
    public static let respondDirectlyName = "respond_directly"

    static let respondDirectly: AgentTool = try! AgentTool(
        name: respondDirectlyName,
        description: "Use when you can reply right away from the conversation alone, without looking anything up or taking an action.",
        parameters: .empty
    ) { _ in "Reply now." }

    static func typeName(for toolName: String) -> String {
        let parts = toolName.split { !$0.isLetter && !$0.isNumber }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() + "Arguments"
    }

    private static func render(_ output: some PromptRepresentable) -> String {
        if let string = output as? String { return string }
        if let convertible = output as? any ConvertibleToGeneratedContent { return convertible.generatedContent.jsonString }
        return String(describing: output)
    }
}

extension AgentTool {
    /// The JSON the model sees for this tool, in OpenAI function format.
    public var openAIDefinition: JSONValue {
        [
            "type": "function",
            "function": [
                "name": .string(name),
                "description": .string(description),
                "parameters": parameters.json,
            ],
        ]
    }
}
