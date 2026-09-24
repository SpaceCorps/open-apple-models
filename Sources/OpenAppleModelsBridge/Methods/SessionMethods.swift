import Foundation
import FoundationModels
import OpenAppleModels

/// `session/*` methods.
enum SessionMethods {
    static func register(in registry: inout BridgeMethodRegistry) {
        registry.register("session/create", create)
        registry.register("session/respond", respond)
        registry.register("session/cancel") { request in
            let session = try request.engine.session(request.params.string("session"))
            return .result(["session": .string(session.id), "cancelled": .number(Double(session.cancelAll()))])
        }
        registry.register("session/delete") { request in
            let id = try request.params.string("session")
            guard request.engine.removeSession(id) != nil else { throw BridgeError.sessionNotFound(id) }
            return .result(["session": .string(id), "deleted": true])
        }
        registry.register("session/list") { request in
            .result(["sessions": .array(request.engine.sessions.map(\.summary))])
        }
        registry.register("session/transcript") { request in
            let session = try request.engine.session(request.params.string("session"))
            return .result(["session": .string(session.id), "transcript": try BridgeCoding.json(session.agent.transcript)])
        }
        // Scheduled operations call `WorkQueue.commit()` right before they
        // change the session, so a cancelled operation never reports
        // `cancelled` and then applies anyway.
        registry.register("session/reset") { request in
            let session = try request.engine.session(request.params.string("session"))
            return session.schedule {
                try WorkQueue.commit()
                await session.agent.reset()
                return ["session": .string(session.id)]
            }
        }
        registry.register("session/setInstructions") { request in
            let session = try request.engine.session(request.params.string("session"))
            let instructions = try request.params.optionalString("instructions")
            return session.schedule {
                try WorkQueue.commit()
                session.agent.instructions = instructions
                return ["session": .string(session.id)]
            }
        }
        registry.register("session/setContextNote") { request in
            let session = try request.engine.session(request.params.string("session"))
            let note = try request.params.optionalString("note")
            return session.schedule {
                try WorkQueue.commit()
                session.agent.contextNote = note
                return ["session": .string(session.id)]
            }
        }
        registry.register("session/setTools") { request in
            let session = try request.engine.session(request.params.string("session"))
            let parsed = try BridgeCoding.tools(from: request.params.value("tools"), defaultTimeout: session.toolTimeout)
            let warnings = parsed.warnings + [toolCountWarning(parsed.tools.count)].compactMap { $0 }
            return session.schedule {
                try WorkQueue.commit()
                try session.agent.setTools(parsed.tools)
                return ["session": .string(session.id), "warnings": .array(warnings.map(JSONValue.string))]
            }
        }
        registry.register("session/compact") { request in
            let session = try request.engine.session(request.params.string("session"))
            let keep = try request.params.optionalInt("keepRecentTurns", minimum: 0) ?? 2
            let instructions = try request.params.optionalString("summaryInstructions")
            return session.schedule {
                let summary = try await compact(session.agent, keepingRecentTurns: keep, summaryInstructions: instructions)
                return ["session": .string(session.id), "summary": summary.map(JSONValue.string) ?? .null]
            }
        }
    }

    // MARK: session/compact

    /// ``Agent/compactHistory(keepingRecentTurns:summaryInstructions:userLabel:assistantLabel:)``,
    /// but cancellable: the summary is generated in the calling task (so
    /// cancelling it stops the model call) and the history is only replaced
    /// if the operation was not cancelled meanwhile. The core method runs on
    /// the agent's own queue and always finishes, so a cancelled
    /// `session/compact` would still rewrite the history.
    ///
    /// Must run inside the session's queue (``BridgeSession/schedule(_:)``),
    /// which keeps turns from running while the summary is written.
    static func compact(_ agent: Agent, keepingRecentTurns keep: Int, summaryInstructions: String?) async throws -> String? {
        let entries = agent.history
        let starts = entries.indices.filter { if case .prompt = entries[$0] { true } else { false } }
        guard starts.count > keep else { return nil }
        let cut = keep <= 0 ? entries.endIndex : starts[starts.count - keep]
        var prompt = ""
        if let previous = agent.contextNote { prompt += "Summary so far:\n\(previous)\n\n" }
        prompt += "Conversation to fold into the summary:\n\(Agent.render(Array(entries[..<cut])))"
        let summarizer = LanguageModelSession(model: agent.model, instructions: summaryInstructions ?? defaultSummaryInstructions)
        let summary = try await summarizer.respond(to: prompt).content
        try WorkQueue.commit()
        agent.contextNote = summary
        await agent.replaceHistory(Array(entries[cut...]))
        return summary
    }

    /// Same as the core's default for `compactHistory`.
    static let defaultSummaryInstructions = """
        You maintain a running summary of a conversation for a character who must remember it. \
        Merge the new conversation into the existing summary. Keep names, promises, facts learned, \
        items exchanged, decisions and the relationship's tone. Write at most 120 words in plain prose.
        """

    // MARK: session/create

    static let createKeys: Set<String> = ["session", "instructions", "tools", "options", "history", "model"]
    static let optionKeys: Set<String> = [
        "toolChoice", "maxToolRounds", "maxToolCalls", "enabledTools", "temperature", "maxResponseTokens",
        "sampling", "toolTimeoutSeconds", "trimHistory", "reservedResponseTokens", "maxAttempts",
    ]

    static func create(_ request: BridgeRequest) async throws -> BridgeReply {
        let engine = request.engine
        let params = request.params
        var warnings = unknownKeys(in: params, allowed: createKeys)

        let id: String
        if let requested = try params.optionalString("session") {
            guard isValidSessionID(requested) else {
                throw BridgeError.invalidParams("'session' must be 1-128 printable characters; got '\(requested)'.")
            }
            guard engine.isSessionIDAvailable(requested) else { throw BridgeError.sessionExists(requested) }
            id = requested
        } else {
            id = engine.makeSessionID()
        }

        let options = try params.optionalNested("options")
        if let options { warnings += unknownKeys(in: options, allowed: optionKeys) }
        let (configuration, toolTimeout) = try agentConfiguration(from: options, engine: engine)

        let history = try params["history"].map { value throws(BridgeError) in try BridgeCoding.transcript(from: value) }
        let saved = history.flatMap(BridgeCoding.savedSetup(of:))

        // Instructions and tools default to the ones saved in `history`, so
        // `{"history": …}` alone resumes a conversation. A key that is present
        // (even `null` or `[]`) always wins.
        var instructions = try params.optionalString("instructions")
        if params.object["instructions"] == nil, let saved { instructions = saved.instructions }

        var tools: [AgentTool] = []
        if let value = params["tools"] {
            let parsed = try BridgeCoding.tools(from: value, defaultTimeout: toolTimeout)
            tools = parsed.tools
            warnings += parsed.warnings
        } else if params.object["tools"] == nil, let saved {
            let restored = BridgeCoding.clientTools(restoring: saved.tools, defaultTimeout: toolTimeout)
            tools = restored.tools
            warnings += restored.warnings
        }
        if case .tool(let name) = configuration.toolPolicy.choice, !tools.contains(where: { $0.name == name }) {
            throw BridgeError.invalidParams("'options.toolChoice' names tool '\(name)', which is not in 'tools'.")
        }
        if let warning = toolCountWarning(tools.count) { warnings.append(warning) }

        let spec = try BridgeCoding.modelSpec(params["model"])
        let model = try engine.makeModel(spec)
        if case .system = spec {
            let availability = engine.configuration.modelAvailability()
            if !availability.available {
                warnings.append("The system model is unavailable (\(availability.reason ?? "unknown")); turns will fail with model_unavailable until it is ready.")
            }
        }

        let agent = try Agent(
            model: model,
            instructions: instructions,
            tools: tools,
            configuration: configuration,
            history: history)
        try engine.insert(BridgeSession(id: id, agent: agent, modelKind: spec.kind, toolTimeout: toolTimeout))
        return .result(["session": .string(id), "warnings": .array(warnings.map(JSONValue.string))])
    }

    static func agentConfiguration(from options: BridgeParams?, engine: BridgeEngine) throws(BridgeError) -> (AgentConfiguration, Duration?) {
        var configuration = AgentConfiguration()
        var toolTimeout = engine.configuration.defaultToolTimeout
        guard let options else { return (configuration, toolTimeout) }
        configuration.toolPolicy = try BridgeCoding.toolPolicy(from: options, base: .default)
        if let temperature = try options.optionalDouble("temperature", minimum: 0) { configuration.temperature = temperature }
        if let tokens = try options.optionalInt("maxResponseTokens", minimum: 1) { configuration.maximumResponseTokens = tokens }
        if let sampling = options["sampling"] {
            configuration.sampling = try BridgeCoding.sampling(sampling, path: "options.sampling")
        }
        if let seconds = try options.optionalSeconds("toolTimeoutSeconds") {
            toolTimeout = BridgeCoding.timeout(seconds: seconds)
        }
        if let trim = try options.optionalBool("trimHistory") { configuration.context.trimsHistory = trim }
        if let reserved = try options.optionalInt("reservedResponseTokens", minimum: 0) {
            configuration.context.reservedResponseTokens = reserved
        }
        if let attempts = try options.optionalInt("maxAttempts", minimum: 1) {
            configuration.retry.maxAttempts = attempts
        }
        return (configuration, toolTimeout)
    }

    // MARK: session/respond

    static let respondKeys: Set<String> = [
        "session", "prompt", "schema", "stream", "toolChoice", "maxToolRounds", "maxToolCalls", "enabledTools",
    ]

    static func respond(_ request: BridgeRequest) async throws -> BridgeReply {
        let params = request.params
        let session = try request.engine.session(params.string("session"))
        let prompt = try params.string("prompt")
        let stream = try params.optionalBool("stream") ?? false
        let policy = try BridgeCoding.toolPolicy(from: params, base: session.agent.configuration.toolPolicy)
        var warnings = unknownKeys(in: params, allowed: respondKeys)
        var schema: JSONSchema?
        if let value = params["schema"] {
            let parsed = try BridgeCoding.schema(value)
            warnings += try BridgeCoding.convert(parsed, name: "Response", path: "schema").warnings
            schema = parsed
        }
        let context: JSONObject = ["session": .string(session.id)]
        return session.schedule { [schema, warnings] in
            // Checked when the turn starts, against the tools in force then
            // (an earlier pipelined session/setTools may add the tool).
            if case .tool(let name) = policy.choice, !session.agent.tools.contains(where: { $0.name == name }) {
                throw BridgeError.invalidParams("'toolChoice' names tool '\(name)', which session '\(session.id)' does not have.")
            }
            let run = if let schema {
                session.agent.run(prompt, schema: schema, policy: policy)
            } else {
                session.agent.run(prompt, policy: policy)
            }
            let response = try await request.drive(run, stream: stream, context: context)
            var result: JSONObject = ["session": .string(session.id)]
            for (key, value) in BridgeCoding.json(response) { result[key] = value }
            if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }
            return .object(result)
        }
    }

    // MARK: Helpers

    static func unknownKeys(in params: BridgeParams, allowed: Set<String>) -> [String] {
        params.object.keys.filter { !allowed.contains($0) }.map { "Unknown parameter '\(params.path)\($0)' was ignored." }
    }

    /// Apple recommends about three to five tools per request for the on-device model.
    static let recommendedMaxTools = 5

    static func toolCountWarning(_ count: Int) -> String? {
        guard count > recommendedMaxTools else { return nil }
        return "\(count) tools: Apple recommends at most 3-5 tools per request on-device; narrow them per turn with 'enabledTools'."
    }

    static func isValidSessionID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
