import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsGame

/// `decision/decide`, `decision/decideMany` and `content/generate`.
///
/// These are one-shot requests (a fresh model session each, no history), so
/// they run concurrently with everything else. Client tools are forwarded
/// to the peer as `tool/call` requests, exactly as for sessions and NPCs.
enum DecisionMethods {
    static func register(in registry: inout BridgeMethodRegistry, game: GameExtension) {
        registry.register("decision/decide") { request in try decide(request, game: game) }
        registry.register("decision/decideMany") { request in try decideMany(request, game: game) }
        registry.register("content/generate") { request in try generate(request) }
    }

    // MARK: Engine settings

    static let engineKeys: Set<String> = ["model", "instructions", "temperature", "maxToolRounds", "toolTimeoutSeconds"]

    /// `model`, `instructions`, `temperature`, `maxToolRounds` and
    /// `toolTimeoutSeconds`, shared by `decide` and `decideMany`.
    struct EngineSettings {
        var engine: DecisionEngine
        var toolTimeout: Duration?

        init(_ params: BridgeParams, bridge: BridgeEngine) throws(BridgeError) {
            let model = try bridge.makeModel(BridgeCoding.modelSpec(params["model"]))
            engine = DecisionEngine(
                model: model,
                instructions: try params.optionalString("instructions"),
                temperature: try params.optionalDouble("temperature", minimum: 0),
                maxToolRounds: try params.optionalInt("maxToolRounds", minimum: 0) ?? 2)
            toolTimeout = try params.optionalSeconds("toolTimeoutSeconds").map(GameJSON.timeout(seconds:))
                ?? bridge.configuration.defaultToolTimeout
        }
    }

    // MARK: decision/decide

    static let decisionKeys: Set<String> = ["situation", "options", "actor", "context", "tools", "toolChoice", "fallbackOptionID"]

    static func decide(_ request: BridgeRequest, game: GameExtension) throws -> BridgeReply {
        let params = request.params
        let settings = try EngineSettings(params, bridge: request.engine)
        var warnings = SessionMethods.unknownKeys(in: params, allowed: decisionKeys.union(engineKeys))
        let parsed = try decisionRequest(params, request: request, game: game, toolTimeout: settings.toolTimeout, toolContext: [:])
        warnings += parsed.warnings
        let engine = settings.engine
        return .deferred { [warnings] in
            let decision = try await engine.decide(parsed.request)
            var result = GameCoding.json(decision)
            if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }
            return .object(result)
        }
    }

    // MARK: decision/decideMany

    static let manyKeys: Set<String> = ["requests", "maxConcurrency"]

    /// Several independent decisions (e.g. a crowd of NPCs). Results come
    /// back in request order; one failing decision does not fail the others
    /// (its slot holds `{"error": {...}}`).
    static func decideMany(_ request: BridgeRequest, game: GameExtension) throws -> BridgeReply {
        let params = request.params
        let settings = try EngineSettings(params, bridge: request.engine)
        var warnings = SessionMethods.unknownKeys(in: params, allowed: manyKeys.union(engineKeys))
        let maxConcurrency = try params.optionalInt("maxConcurrency", minimum: 1) ?? 2
        guard let elements = try params.optionalArray("requests"), !elements.isEmpty else {
            throw BridgeError.invalidParams("'requests' must be a non-empty array of decisions.")
        }
        var requests: [DecisionRequest] = []
        for (index, element) in elements.enumerated() {
            let path = "requests[\(index)]"
            guard let object = element.objectValue else { throw BridgeError.invalidParams("'\(path)' must be an object.") }
            let elementParams = BridgeParams(object, path: path + ".")
            warnings += SessionMethods.unknownKeys(in: elementParams, allowed: decisionKeys)
            let parsed = try decisionRequest(
                elementParams, request: request, game: game, toolTimeout: settings.toolTimeout,
                toolContext: ["index": .number(Double(index))])
            requests.append(parsed.request)
            warnings += parsed.warnings.map { "\(path): \($0)" }
        }
        let engine = settings.engine
        return .deferred { [requests, warnings] in
            let results = await engine.decideMany(requests, maxConcurrency: maxConcurrency)
            let encoded: [JSONValue] = results.map { result in
                switch result {
                case .success(let decision): .object(GameCoding.json(decision))
                case .failure(let error): ["error": BridgeError(error).json]
                }
            }
            var result: JSONObject = ["results": .array(encoded)]
            if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }
            return .object(result)
        }
    }

    // MARK: Parsing

    /// Parses one decision. Options, the fallback and a named tool choice
    /// are validated here, so mistakes fail with `invalid_params` before
    /// any model call.
    static func decisionRequest(
        _ params: BridgeParams,
        request: BridgeRequest,
        game: GameExtension,
        toolTimeout: Duration?,
        toolContext: JSONObject
    ) throws(BridgeError) -> (request: DecisionRequest, warnings: [String]) {
        var warnings: [String] = []
        let situation = try GameJSON.text(params.value("situation")) ?? ""
        let options = try GameCoding.decisionOptions(from: params.value("options"), path: params.path + "options")
        let ids = options.map(\.id)

        var actor: Persona?
        if let value = params["actor"] {
            if let npcID = value.stringValue {
                // An NPC id: decide as that character.
                actor = try game.npcEntry(npcID).npc.persona
            } else {
                let parsed = try GameCoding.persona(from: value, path: params.path + "actor")
                actor = parsed.persona
                warnings += parsed.warnings
            }
        }

        var tools: [AgentTool] = []
        if let value = params["tools"] {
            let parsed = try ForwardedTools.tools(
                from: value, path: params.path + "tools", request: request, context: toolContext, defaultTimeout: toolTimeout)
            tools = parsed.tools
            warnings += parsed.warnings
        }
        if let warning = SessionMethods.toolCountWarning(tools.count) { warnings.append(warning) }

        var toolChoice = ToolChoice.auto
        if let value = params["toolChoice"] {
            toolChoice = try BridgeCoding.toolChoice(value, path: params.path + "toolChoice")
            if case .tool(let name) = toolChoice, !tools.contains(where: { $0.name == name }) {
                throw .invalidParams("'\(params.path)toolChoice' names tool '\(name)', which is not in '\(params.path)tools'.")
            }
        }

        let fallback = try params.optionalString("fallbackOptionID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !ids.contains(fallback) {
            throw .invalidParams("'\(params.path)fallbackOptionID' must be one of the option ids (\(ids.joined(separator: ", "))); got '\(fallback)'.")
        }

        let decision = DecisionRequest(
            situation: situation, options: options, actor: actor, context: params["context"],
            tools: tools, toolChoice: toolChoice, fallbackOptionID: fallback)
        return (decision, warnings)
    }

    // MARK: content/generate

    static let generateKeys: Set<String> = [
        "prompt", "schema", "instructions", "context", "tools", "toolTimeoutSeconds", "model", "temperature",
    ]

    static func generate(_ request: BridgeRequest) throws -> BridgeReply {
        let params = request.params
        var warnings = SessionMethods.unknownKeys(in: params, allowed: generateKeys)
        let prompt = try params.string("prompt")
        let schema = try BridgeCoding.schema(params.value("schema"))
        warnings += try BridgeCoding.convert(schema, name: "Content", path: "schema").warnings
        let instructions = try params.optionalString("instructions")
        let model = try request.engine.makeModel(BridgeCoding.modelSpec(params["model"]))
        let generator = ContentGenerator(model: model, temperature: try params.optionalDouble("temperature", minimum: 0))
        var tools: [AgentTool] = []
        if let value = params["tools"] {
            let timeout = try params.optionalSeconds("toolTimeoutSeconds").map(GameJSON.timeout(seconds:))
                ?? request.engine.configuration.defaultToolTimeout
            let parsed = try ForwardedTools.tools(from: value, path: "tools", request: request, context: [:], defaultTimeout: timeout)
            tools = parsed.tools
            warnings += parsed.warnings
        }
        let context = params["context"]
        return .deferred { [tools, warnings] in
            let content = try await generator.generate(prompt, schema: schema, instructions: instructions, context: context, tools: tools)
            var result: JSONObject = ["content": content]
            if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }
            return .object(result)
        }
    }
}

// MARK: - Forwarded client tools

/// Client tools for APIs that take ready-made ``AgentTool``s (decisions,
/// content): each becomes a local tool whose handler sends `tool/call` to
/// the peer and returns its answer. If the call times out or the request is
/// cancelled first, the peer gets `tool/cancel`.
enum ForwardedTools {
    static func tools(
        from value: JSONValue,
        path: String,
        request: BridgeRequest,
        context: JSONObject,
        defaultTimeout: Duration?
    ) throws(BridgeError) -> (tools: [AgentTool], warnings: [String]) {
        let parsed = try BridgeCoding.tools(from: value, defaultTimeout: defaultTimeout, path: path)
        let engine = request.engine
        var base = context
        base["requestId"] = request.id?.value ?? .null
        let tools = parsed.tools.map { definition -> AgentTool in
            var tool = definition
            tool.execution = .local { [base] call in
                var params = base
                params["call"] = BridgeCoding.json(call)
                let pending = engine.sendRequest("tool/call", params: .object(params))
                let result = await pending.result()
                if Task.isCancelled, case .failure(let error) = result, error.name == AgentError.Code.cancelled.rawValue {
                    var cancel = base
                    cancel["id"] = .string(pending.id)
                    cancel["callId"] = .string(call.id)
                    cancel["reason"] = .string("The tool call timed out or its request was cancelled.")
                    engine.notify("tool/cancel", .object(cancel))
                }
                return BridgeCoding.toolOutput(from: result)
            }
            return tool
        }
        return (tools, parsed.warnings)
    }
}
