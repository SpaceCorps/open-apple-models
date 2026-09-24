import Foundation
import FoundationModels
import OpenAppleModels

/// Everything needed to run one chat completion, derived from a validated
/// request and the server configuration.
struct CompletionPlan: Sendable {
    enum Format: Sendable {
        case text
        /// `response_format: json_object` — best effort: instructed, then validated.
        case jsonObject
        /// `response_format: json_schema` — constrained generation.
        case schema(GenerationSchema)
    }

    var modelID: String
    var model: any LanguageModel
    var conversation: MappedConversation
    var instructions: String?
    var tools: [AgentTool]
    /// Tools the client executes; calls to them end the request with `tool_calls`.
    var clientToolNames: Set<String>
    var policy: ToolPolicy
    var configuration: AgentConfiguration
    var format: Format
    var stop: [String]
    var maxTokens: Int?
    var parallelToolCalls: Bool
    var stream: Bool
    var includeUsage: Bool

    static let jsonObjectInstruction =
        "Respond with a single valid JSON object and nothing else: no prose, no Markdown, no code fences."

    /// Validates `request` against `configuration` and builds the plan.
    init(request: ChatCompletionRequest, configuration: ServerConfiguration, log: ServerLogger) throws(OpenAIError) {
        guard let (modelID, model) = configuration.resolveModel(request.model) else {
            let requested = request.model ?? configuration.defaultModel
            throw OpenAIError(
                status: 404,
                message: "The model '\(requested)' does not exist. Available models: \(Self.availableModels(configuration)).",
                type: "invalid_request_error", param: "model", code: "model_not_found")
        }
        self.modelID = modelID
        self.model = model
        conversation = try MessageMapper.map(request.messages)

        // Tools: the client's (external) plus the server's (local).
        var tools: [AgentTool] = []
        for (index, function) in request.tools.enumerated() {
            if configuration.serverTools.contains(where: { $0.name == function.name }) {
                throw .invalidRequest("Tool name '\(function.name)' is reserved by a server tool.",
                                      param: "tools[\(index)].function.name", code: "invalid_value")
            }
            do {
                let tool = try AgentTool.external(name: function.name, description: function.description, parameters: function.parameters)
                for warning in tool.schemaWarnings { log.log(.debug, "tool \(function.name): \(warning)") }
                tools.append(tool)
            } catch {
                throw .invalidRequest("Invalid parameters schema for tool '\(function.name)': \(error)",
                                      param: "tools[\(index)].function.parameters", code: "invalid_schema")
            }
        }
        clientToolNames = Set(request.tools.map(\.name))
        tools += configuration.serverTools.filter { !$0.isExternal }
        self.tools = tools
        let allNames = Set(tools.map(\.name))

        var policy = configuration.toolPolicy
        policy.enabledTools = nil
        switch request.toolChoice {
        case nil, .auto?:
            policy.choice = .auto
        case .none?:
            policy.choice = .none
        case .required?:
            guard !allNames.isEmpty else {
                throw .invalidRequest("tool_choice 'required' needs at least one tool in 'tools'.", param: "tool_choice", code: "invalid_value")
            }
            policy.choice = .required
        case .function(let name)?:
            guard allNames.contains(name) else {
                throw .invalidRequest("tool_choice names the function '\(name)', which is not in 'tools'.", param: "tool_choice", code: "unknown_tool")
            }
            policy.choice = .tool(name)
        case .allowed(let names, let required)?:
            if let unknown = names.subtracting(allNames).sorted().first {
                throw .invalidRequest("tool_choice.allowed_tools names the function '\(unknown)', which is not in 'tools'.",
                                      param: "tool_choice", code: "unknown_tool")
            }
            policy.enabledTools = names
            policy.choice = required && !names.isEmpty ? .required : .auto
        }
        self.policy = policy

        switch request.responseFormat {
        case .text:
            format = .text
        case .jsonObject:
            format = .jsonObject
        case .jsonSchema(let name, let schema):
            do {
                let converted = try SchemaConverter.convert(schema, rootName: Self.typeName(name))
                for warning in converted.warnings { log.log(.debug, "response_format: \(warning)") }
                format = .schema(converted.schema)
            } catch {
                throw .invalidRequest("Invalid JSON schema in response_format: \(error)",
                                      param: "response_format.json_schema.schema", code: "invalid_schema")
            }
        }

        var instructionParts = [configuration.serverInstructions, conversation.instructions].compactMap { $0 }
        if case .jsonObject = format { instructionParts.append(Self.jsonObjectInstruction) }
        instructions = instructionParts.isEmpty ? nil : instructionParts.joined(separator: "\n\n")

        var temperature = request.temperature
        var sampling: GenerationOptions.SamplingMode?
        let seed = request.seed.map { UInt64(bitPattern: Int64($0)) }
        if temperature == 0 {
            sampling = .greedy
            temperature = nil
        } else if let topP = request.topP {
            sampling = .random(probabilityThreshold: topP, seed: seed)
        } else if let seed {
            sampling = .random(probabilityThreshold: 1.0, seed: seed)
        }
        self.configuration = AgentConfiguration(
            toolPolicy: policy,
            context: configuration.contextPolicy,
            temperature: temperature,
            maximumResponseTokens: request.maxTokens,
            sampling: sampling,
            retry: configuration.retryPolicy)
        stop = request.stop
        maxTokens = request.maxTokens
        parallelToolCalls = request.parallelToolCalls
        stream = request.stream
        includeUsage = request.includeUsage
    }

    static func availableModels(_ configuration: ServerConfiguration) -> String {
        (configuration.models.keys.sorted() + configuration.modelAliases.keys.sorted()).joined(separator: ", ")
    }

    /// A schema type name derived from an OpenAI `json_schema.name`.
    static func typeName(_ name: String) -> String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return cleaned.isEmpty ? "Response" : cleaned
    }
}
