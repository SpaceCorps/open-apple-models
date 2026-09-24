import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsGame
import Synchronization

/// `npc/*` methods.
enum NPCMethods {
    static func register(in registry: inout BridgeMethodRegistry, game: GameExtension) {
        registry.register("npc/create") { request in try create(request, game: game) }
        registry.register("npc/restore") { request in try restore(request, game: game) }
        registry.register("npc/talk") { request in try talk(request, game: game) }
        registry.register("npc/bark") { request in try bark(request, game: game) }
        registry.register("npc/state") { request in try state(request, game: game) }
        registry.register("npc/update") { request in try update(request, game: game) }
        registry.register("npc/reset") { request in
            let entry = try game.npcEntry(request.params.string("npc"))
            let clearMemory = try request.params.optionalBool("clearMemory") ?? false
            return entry.queue.schedule {
                try WorkQueue.commit()
                await entry.npc.resetConversation(clearingMemory: clearMemory)
                return ["npc": .string(entry.id)]
            }
        }
        registry.register("npc/cancel") { request in
            let entry = try game.npcEntry(request.params.string("npc"))
            return .result(["npc": .string(entry.id), "cancelled": .number(Double(entry.queue.cancelAll()))])
        }
        registry.register("npc/delete") { request in
            let id = try request.params.string("npc")
            guard game.removeNPC(id) != nil else { throw BridgeError.npcNotFound(id) }
            return .result(["npc": .string(id), "deleted": true])
        }
        registry.register("npc/list") { _ in
            .result(["npcs": .array(game.npcEntries.map(\.summary))])
        }
    }

    // MARK: npc/create and npc/restore

    /// What an NPC is built from; shared by `npc/create` and `npc/restore`.
    struct Blueprint {
        var id: String
        var persona: Persona
        var memory = NPCMemory()
        var history: Transcript?
        var toolDefinitions: [JSONValue] = []
        var toolsPath = "tools"
        var options = NPCOptions()
        var toolTimeoutSeconds: Double?
        var worldID: String?
        var model = BridgeModelSpec.system
    }

    static let createKeys: Set<String> = ["npc", "persona", "tools", "world", "options", "memory", "model"]

    static func create(_ request: BridgeRequest, game: GameExtension) throws -> BridgeReply {
        let params = request.params
        var warnings = SessionMethods.unknownKeys(in: params, allowed: createKeys)
        let id = try game.npcID(requested: params.optionalString("npc"))
        let (persona, personaWarnings) = try GameCoding.persona(from: params.value("persona"))
        warnings += personaWarnings
        var blueprint = Blueprint(id: id, persona: persona)
        blueprint.memory = try GameCoding.memory(from: params["memory"])
        blueprint.toolDefinitions = try toolDefinitions(params["tools"], path: "tools")
        let options = try GameCoding.npcOptions(from: params["options"])
        blueprint.options = options.options
        blueprint.toolTimeoutSeconds = options.toolTimeoutSeconds
        warnings += options.warnings
        blueprint.worldID = try params.optionalString("world")
        blueprint.model = try BridgeCoding.modelSpec(params["model"])
        return try build(blueprint, request: request, game: game, warnings: warnings)
    }

    static let restoreKeys: Set<String> = ["npc", "state", "tools", "world", "options", "model"]

    /// Rebuilds an NPC from an `npc/state` save. Tools, options and world
    /// default to the ones stored in the save; a key that is present (even
    /// `null` or `[]`) wins.
    static func restore(_ request: BridgeRequest, game: GameExtension) throws -> BridgeReply {
        let params = request.params
        var warnings = SessionMethods.unknownKeys(in: params, allowed: restoreKeys)
        let stateValue = try params.value("state")
        let saved = try GameCoding.saveState(from: stateValue)
        // Accept the whole npc/state result as well as its `state` member.
        let extras = stateValue["persona"] == nil ? (stateValue["state"]?.objectValue ?? [:]) : (stateValue.objectValue ?? [:])

        let requestedID = try params.optionalString("npc") ?? extras["npc"]?.stringValue
        var blueprint = Blueprint(id: try game.npcID(requested: requestedID), persona: saved.persona)
        blueprint.memory = saved.memory
        blueprint.history = saved.transcript

        if params.object["tools"] != nil {
            blueprint.toolDefinitions = try toolDefinitions(params["tools"], path: "tools")
        } else {
            blueprint.toolDefinitions = try toolDefinitions(extras["tools"], path: "state.tools")
            blueprint.toolsPath = "state.tools"
        }

        let optionsValue = params.object["options"] != nil ? params["options"] : extras["options"]
        let optionsPath = params.object["options"] != nil ? "options" : "state.options"
        let options = try GameCoding.npcOptions(from: optionsValue, path: optionsPath)
        blueprint.options = options.options
        blueprint.toolTimeoutSeconds = options.toolTimeoutSeconds
        warnings += options.warnings

        if params.object["world"] != nil {
            blueprint.worldID = try params.optionalString("world")
        } else if let savedWorld = extras["world"]?.stringValue {
            if game.world(savedWorld) != nil {
                blueprint.worldID = savedWorld
            } else {
                warnings.append("The saved world '\(savedWorld)' does not exist; the NPC was restored without a world. Pass 'world' to attach one.")
            }
        }
        blueprint.model = try BridgeCoding.modelSpec(params["model"])
        return try build(blueprint, request: request, game: game, warnings: warnings)
    }

    static func toolDefinitions(_ value: JSONValue?, path: String) throws(BridgeError) -> [JSONValue] {
        guard let value, !value.isNull else { return [] }
        guard let array = value.arrayValue else { throw .invalidParams("'\(path)' must be an array of tool definitions.") }
        return array
    }

    static func build(_ blueprint: Blueprint, request: BridgeRequest, game: GameExtension, warnings initial: [String]) throws -> BridgeReply {
        let engine = request.engine
        var warnings = initial
        let toolTimeout = blueprint.toolTimeoutSeconds.map(GameJSON.timeout(seconds:)) ?? engine.configuration.defaultToolTimeout
        let parsed = try BridgeCoding.tools(from: .array(blueprint.toolDefinitions), defaultTimeout: toolTimeout, path: blueprint.toolsPath)
        warnings += parsed.warnings

        var world: WorldState?
        if let worldID = blueprint.worldID { world = try game.worldEntry(worldID).world }

        let model = try engine.makeModel(blueprint.model)
        if case .system = blueprint.model {
            let availability = engine.configuration.modelAvailability()
            if !availability.available {
                warnings.append("The system model is unavailable (\(availability.reason ?? "unknown")); turns will fail with model_unavailable until it is ready.")
            }
        }

        let npc: NPC
        do {
            npc = try NPC(
                persona: blueprint.persona, model: model, tools: parsed.tools, world: world,
                options: blueprint.options, memory: blueprint.memory, history: blueprint.history)
        } catch {
            throw invalidParams(error)
        }
        let entry = NPCEntry(
            id: blueprint.id, npc: npc, worldID: blueprint.worldID, modelKind: blueprint.model.kind,
            toolDefinitions: blueprint.toolDefinitions, toolTimeout: toolTimeout)
        let toolNames = entry.modelToolNames
        if let warning = SessionMethods.toolCountWarning(toolNames.count) { warnings.append(warning) }
        try game.insertNPC(entry)
        return .result([
            "npc": .string(entry.id),
            "tools": .array(toolNames.map(JSONValue.string)),
            "warnings": .array(warnings.map(JSONValue.string)),
        ])
    }

    /// NPC configuration errors (`invalid_request`) are parameter errors here.
    static func invalidParams(_ error: AgentError) -> BridgeError {
        error.code == .invalidRequest ? .invalidParams(error.message) : BridgeError(error)
    }

    // MARK: npc/talk

    static let talkKeys: Set<String> = ["npc", "line", "context", "stream", "toolChoice"]

    static func talk(_ request: BridgeRequest, game: GameExtension) throws -> BridgeReply {
        let params = request.params
        let entry = try game.npcEntry(params.string("npc"))
        let line = try params.string("line")
        let context = GameJSON.text(params["context"])
        let stream = try params.optionalBool("stream") ?? false
        // A tool named here is checked when the turn starts (an earlier
        // queued npc/update may add it), failing with invalid_request.
        let toolChoice = try params["toolChoice"].map { value throws(BridgeError) in try BridgeCoding.toolChoice(value) }
        let warnings = SessionMethods.unknownKeys(in: params, allowed: talkKeys)
        let driver = DialogueDriver(
            engine: request.engine, requestID: request.id?.value ?? .null,
            context: ["npc": .string(entry.id)], stream: stream)
        return entry.queue.schedule {
            let dialogue = entry.npc.talkStream(line, context: context, toolChoice: toolChoice)
            let turn = try await driver.drive(dialogue)
            var result: JSONObject = ["npc": .string(entry.id)]
            for (key, value) in GameCoding.json(turn) { result[key] = value }
            if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }
            return .object(result)
        }
    }

    // MARK: npc/bark

    static func bark(_ request: BridgeRequest, game: GameExtension) throws -> BridgeReply {
        let entry = try game.npcEntry(request.params.string("npc"))
        let situation = GameJSON.text(request.params["situation"]) ?? ""
        // Barks use a separate one-off session, so they do not wait for turns.
        return .deferred {
            let line = try await entry.npc.bark(situation: situation)
            return ["npc": .string(entry.id), "line": .string(line)]
        }
    }

    // MARK: npc/state

    static func state(_ request: BridgeRequest, game: GameExtension) throws -> BridgeReply {
        let entry = try game.npcEntry(request.params.string("npc"))
        let settle = try request.params.optionalBool("settle") ?? true
        @Sendable func result(_ saved: NPCSaveState) throws(BridgeError) -> JSONValue {
            var state = try GameCoding.json(saved)
            for (key, value) in entry.saveExtras { state[key] = value }
            return ["npc": .string(entry.id), "state": .object(state)]
        }
        guard settle else { return .result(try result(entry.npc.saveState())) }
        // After this NPC's earlier requests, and after background compaction.
        return entry.queue.schedule {
            try result(await entry.npc.settledState())
        }
    }

    // MARK: npc/update

    static let updateKeys: Set<String> = ["npc", "persona", "options", "memory", "tools"]

    /// Merge-patches the persona, options and memory (RFC 7386: `null`
    /// resets a field) and replaces the client tools. Applied in order with
    /// the NPC's other requests; takes effect from the next turn.
    static func update(_ request: BridgeRequest, game: GameExtension) throws -> BridgeReply {
        let params = request.params
        let entry = try game.npcEntry(params.string("npc"))
        let personaPatch = try params.optionalObject("persona").map(JSONValue.object)
        let optionsPatch = try params.optionalObject("options").map(JSONValue.object)
        let memoryPatch = try params.optionalObject("memory").map(JSONValue.object)
        let newDefinitions = params.object["tools"] != nil ? try toolDefinitions(params["tools"], path: "tools") : nil
        let defaultTimeout = request.engine.configuration.defaultToolTimeout
        let unknown = SessionMethods.unknownKeys(in: params, allowed: updateKeys)

        return entry.queue.schedule {
            var warnings = unknown
            let npc = entry.npc
            var persona: Persona?
            if let personaPatch {
                let parsed = try GameCoding.persona(from: GameJSON.merged(personaPatch, into: GameCoding.json(npc.persona)))
                persona = parsed.persona
                warnings += parsed.warnings
            }
            var memory: NPCMemory?
            if let memoryPatch {
                memory = try GameCoding.memory(from: GameJSON.merged(memoryPatch, into: GameCoding.json(npc.memory)))
            }
            var options: NPCOptions?
            var toolTimeout = entry.toolTimeout
            if let optionsPatch {
                var current = GameCoding.json(npc.options).objectValue ?? [:]
                current["toolTimeoutSeconds"] = .number(GameJSON.seconds(toolTimeout))
                let parsed = try GameCoding.npcOptions(from: GameJSON.merged(optionsPatch, into: .object(current)))
                options = parsed.options
                if optionsPatch.objectValue?["toolTimeoutSeconds"] != nil {
                    toolTimeout = parsed.toolTimeoutSeconds.map(GameJSON.timeout(seconds:)) ?? defaultTimeout
                }
                warnings += parsed.warnings
            }
            // Tools are rebuilt when replaced or when their time limit changed.
            var tools: [AgentTool]?
            let definitions = newDefinitions ?? entry.toolDefinitions
            if newDefinitions != nil || toolTimeout != entry.toolTimeout {
                let parsed = try BridgeCoding.tools(from: .array(definitions), defaultTimeout: toolTimeout)
                tools = parsed.tools
                warnings += parsed.warnings
            }

            try WorkQueue.commit()
            do throws(AgentError) {
                try apply(tools: tools, options: options, to: npc)
            } catch {
                throw invalidParams(error)
            }
            if let persona { npc.persona = persona }
            if let memory { npc.memory = memory }
            entry.mutable.withLock { state in
                state.toolDefinitions = definitions
                state.toolTimeout = toolTimeout
            }
            return ["npc": .string(entry.id), "warnings": .array(warnings.map(JSONValue.string))]
        }
    }

    /// Replaces tools and options together. Each setter validates the
    /// grounding tool against the other half, so when both change, the
    /// grounding is cleared first; on failure the previous configuration is
    /// restored.
    static func apply(tools: [AgentTool]?, options: NPCOptions?, to npc: NPC) throws(AgentError) {
        switch (tools, options) {
        case (nil, nil):
            return
        case (let tools?, nil):
            try npc.setTools(tools)
        case (nil, let options?):
            try npc.setOptions(options)
        case (let tools?, let options?):
            let previousTools = npc.tools
            let previousOptions = npc.options
            do {
                try npc.setOptions(ungrounded(previousOptions))
                try npc.setTools(tools)
                try npc.setOptions(options)
            } catch {
                try? npc.setOptions(ungrounded(previousOptions))
                try? npc.setTools(previousTools)
                try? npc.setOptions(previousOptions)
                throw error
            }
        }
    }

    static func ungrounded(_ options: NPCOptions) -> NPCOptions {
        var options = options
        options.groundingTool = nil
        if case .tool = options.toolChoice { options.toolChoice = .auto }
        return options
    }
}

// MARK: - Dialogue driver

/// Bridges one NPC turn (``DialogueStream``) to the peer, like the session
/// turn driver: external tool calls become `tool/call` requests, streamed
/// events become `npc/event` notifications, and cancelling the calling task
/// cancels the turn.
final class DialogueDriver: Sendable {
    let engine: BridgeEngine
    let requestID: JSONValue
    let context: JSONObject
    let stream: Bool

    /// Client tool calls awaiting the peer, by tool-call id.
    private let pending = Mutex<[String: ClientRequest]>([:])

    init(engine: BridgeEngine, requestID: JSONValue, context: JSONObject, stream: Bool) {
        self.engine = engine
        self.requestID = requestID
        self.context = context
        self.stream = stream
    }

    private func params(_ extra: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var object = context
        object["requestId"] = requestID
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    func drive(_ dialogue: DialogueStream) async throws(BridgeError) -> DialogueTurn {
        let outcome: Result<DialogueTurn, BridgeError> = await withTaskCancellationHandler {
            do {
                for try await event in dialogue {
                    if stream, let json = GameCoding.json(event) {
                        engine.notify("npc/event", params(["event": json]))
                    }
                    switch event {
                    case .externalToolCall(let call):
                        forward(call, to: dialogue)
                    case .toolResult(let record):
                        // Still waiting on the peer means the call timed out.
                        if let request = pending.withLock({ $0.removeValue(forKey: record.call.id) }) {
                            cancel(request, callID: record.call.id, reason: record.output.modelText)
                        }
                    case .completed(let turn):
                        // The turn is in the NPC's history now: report it
                        // even if a cancellation arrives before the response.
                        WorkQueue.markCommitted()
                        return .success(turn)
                    default:
                        break
                    }
                }
                if Task.isCancelled { return .failure(.cancelled("The turn was cancelled.")) }
                return .failure(.internalError("The dialogue turn ended without a reply."))
            } catch {
                return .failure(BridgeError(normalizing: error))
            }
        } onCancel: {
            dialogue.cancel()
        }
        let leftover = pending.withLock { pending in
            defer { pending.removeAll() }
            return pending.sorted { $0.key < $1.key }
        }
        for (callID, request) in leftover {
            cancel(request, callID: callID, reason: "The turn ended before the tool finished.")
        }
        return try outcome.get()
    }

    private func forward(_ call: ToolCall, to dialogue: DialogueStream) {
        let request = engine.sendRequest("tool/call", params: params(["call": BridgeCoding.json(call)]))
        pending.withLock { $0[call.id] = request }
        Task { [self] in
            let result = await request.result()
            // Remove before submitting: the output is recorded (and
            // `toolResult` emitted) as soon as it is submitted.
            guard pending.withLock({ $0.removeValue(forKey: call.id) }) != nil else { return }
            dialogue.submit(BridgeCoding.toolOutput(from: result), for: call.id)
        }
    }

    private func cancel(_ request: ClientRequest, callID: String, reason: String) {
        guard !request.isFinished else { return }
        request.cancel()
        engine.notify("tool/cancel", params(["id": .string(request.id), "callId": .string(callID), "reason": .string(reason)]))
    }
}
