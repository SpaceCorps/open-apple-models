import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsGame

/// The JSON shapes of the game methods (`npc/*`, `decision/*`, `world/*`,
/// `content/generate`): encoders for dialogue turns, events, decisions and
/// save states, and lenient decoders for personas, NPC options and memory.
///
/// Tool calls, tool records and token usage use the shared
/// ``BridgeCoding`` shapes, so a client parses them the same way for
/// sessions and NPCs.
public enum GameCoding {
    // MARK: Encoding

    /// `{"line", "emotion", "playerOptions", "endsConversation", "toolCalls",
    /// "relationship", "isFallback", "usage"}`.
    public static func json(_ turn: DialogueTurn) -> JSONObject {
        [
            "line": .string(turn.line),
            "emotion": .string(turn.emotion.rawValue),
            "playerOptions": .array(turn.playerOptions.map(JSONValue.string)),
            "endsConversation": .bool(turn.endsConversation),
            "toolCalls": .array(turn.toolCalls.map(BridgeCoding.json)),
            "relationship": .number(Double(turn.relationship)),
            "isFallback": .bool(turn.isFallback),
            "usage": BridgeCoding.json(turn.usage),
        ]
    }

    /// The `event` payload of an `npc/event` notification, or `nil` for
    /// `completed` (delivered as the `npc/talk` response instead).
    ///
    /// - `{"type": "emotion", "emotion"}`
    /// - `{"type": "lineDelta", "delta"}` — append to the displayed line
    /// - `{"type": "lineReset", "line"}` — replace the displayed line
    /// - `{"type": "toolCallStarted", "call", "execution": "local" | "client"}`
    /// - `{"type": "toolCallCompleted", "record"}`
    public static func json(_ event: DialogueEvent) -> JSONValue? {
        switch event {
        case .emotion(let emotion):
            ["type": "emotion", "emotion": .string(emotion.rawValue)]
        case .lineDelta(let delta):
            ["type": "lineDelta", "delta": .string(delta)]
        case .lineReset(let line):
            ["type": "lineReset", "line": .string(line)]
        case .toolCall(let call):
            ["type": "toolCallStarted", "call": BridgeCoding.json(call), "execution": "local"]
        case .externalToolCall(let call):
            ["type": "toolCallStarted", "call": BridgeCoding.json(call), "execution": "client"]
        case .toolResult(let record):
            ["type": "toolCallCompleted", "record": BridgeCoding.json(record)]
        case .completed:
            nil
        }
    }

    /// `{"optionID", "reasoning", "confidence", "toolCalls", "usage", "isFallback"}`.
    public static func json(_ decision: Decision) -> JSONObject {
        [
            "optionID": .string(decision.optionID),
            "reasoning": .string(decision.reasoning),
            "confidence": .number(Double(decision.confidence)),
            "toolCalls": .array(decision.toolCalls.map(BridgeCoding.json)),
            "usage": BridgeCoding.json(decision.usage),
            "isFallback": .bool(decision.isFallback),
        ]
    }

    /// A persona in its `Codable` form (every field present).
    public static func json(_ persona: Persona) -> JSONValue {
        (try? JSONValue(encoding: persona)) ?? ["name": .string(persona.name)]
    }

    /// Memory as `{"facts", "relationship", "summary"?}`.
    public static func json(_ memory: NPCMemory) -> JSONValue {
        (try? JSONValue(encoding: memory)) ?? [:]
    }

    /// NPC options in the form ``npcOptions(from:path:)`` reads back:
    /// `memoryTools` as a list of names, and an unset
    /// `secretsUnlockAtRelationship` as an explicit `null` (absent would
    /// mean the default threshold).
    public static func json(_ options: NPCOptions) -> JSONValue {
        guard var object = (try? JSONValue(encoding: options))?.objectValue else { return [:] }
        object["memoryTools"] = .array(memoryToolNames(options.memoryTools).map(JSONValue.string))
        if options.secretsUnlockAtRelationship == nil { object["secretsUnlockAtRelationship"] = .null }
        return .object(object)
    }

    /// `{"path", "oldValue"?, "newValue"?}`; a missing value (created or
    /// removed) is omitted, while a JSON `null` value is sent as `null`.
    public static func json(_ change: WorldStateChange) -> JSONObject {
        var object: JSONObject = ["path": .string(change.path)]
        if let old = change.oldValue { object["oldValue"] = old }
        if let new = change.newValue { object["newValue"] = new }
        return object
    }

    /// A save state as `{"version", "persona", "memory", "transcript"}`
    /// (``NPCSaveState``'s `Codable` form).
    public static func json(_ state: NPCSaveState) throws(BridgeError) -> JSONObject {
        do {
            guard let object = try JSONValue(encoding: state).objectValue else {
                throw BridgeError.internalError("The NPC save state did not encode as an object.")
            }
            return object
        } catch let error as BridgeError {
            throw error
        } catch {
            throw .internalError("Could not encode the NPC save state: \(error)")
        }
    }

    // MARK: Decoding

    /// Keys a persona understands (for unknown-key warnings).
    static let personaKeys: Set<String> = Set(json(Persona(name: "x")).objectValue?.keys ?? [])

    /// Keys the bridge reads from `options` in addition to ``NPCOptions``'.
    static let bridgeOptionKeys: Set<String> = ["toolTimeoutSeconds"]

    /// Keys ``NPCOptions`` understands. Derived from its encoding (with every
    /// optional set) so new options are recognized without a bridge change.
    static let npcOptionKeys: Set<String> = {
        let full = NPCOptions(groundingTool: "x", extraInstructions: "x", temperature: 1, maximumResponseTokens: 1)
        return Set(json(full).objectValue?.keys ?? []).union(bridgeOptionKeys)
    }()

    /// Decodes a persona. Only `name` is required; unknown keys produce warnings.
    public static func persona(from value: JSONValue, path: String = "persona") throws(BridgeError) -> (persona: Persona, warnings: [String]) {
        guard let object = value.objectValue else { throw .invalidParams("'\(path)' must be an object with at least a 'name'.") }
        let persona = try GameJSON.decode(Persona.self, from: value, path: path)
        guard !persona.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidParams("'\(path).name' must not be empty.")
        }
        return (persona, unknownKeys(object, allowed: personaKeys, path: path))
    }

    /// Decodes ``NPCOptions`` (missing fields take their defaults).
    ///
    /// Accepts `memoryTools` as a list of names (`"rememberFact"`,
    /// `"changeRelationship"`), `"all"`/`"none"`, or the raw bit mask, and
    /// `toolChoice` as `"auto" | "none" | "required" | {"tool": name}`.
    /// Unknown keys produce warnings. The bridge-only `toolTimeoutSeconds`
    /// is returned separately (`nil` when absent).
    public static func npcOptions(from value: JSONValue?, path: String = "options") throws(BridgeError) -> (options: NPCOptions, toolTimeoutSeconds: Double?, warnings: [String]) {
        guard let value, !value.isNull else { return (NPCOptions(), nil, []) }
        guard var object = value.objectValue else { throw .invalidParams("'\(path)' must be an object.") }
        let warnings = unknownKeys(object, allowed: npcOptionKeys, path: path)
        let params = BridgeParams(object, path: path + ".")
        let timeout = try params.optionalDouble("toolTimeoutSeconds", minimum: 0)
        object["toolTimeoutSeconds"] = nil
        if let tools = object["memoryTools"], !tools.isNull, tools.intValue == nil {
            object["memoryTools"] = .number(Double(try memoryTools(tools, path: path + ".memoryTools").rawValue))
        }
        if let choice = object["toolChoice"], !choice.isNull {
            // Validate with the shared parser for a precise message, then
            // normalize (it also accepts the OpenAI function form).
            object["toolChoice"] = try JSONValue(encoding: BridgeCoding.toolChoice(choice, path: path + ".toolChoice"), orThrow: path)
        }
        if let format = object["replyFormat"]?.stringValue, NPCReplyFormat(rawValue: format) == nil {
            let known = NPCReplyFormat.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            throw .invalidParams("'\(path).replyFormat' must be one of \(known); got '\(format)'.")
        }
        let options = try GameJSON.decode(NPCOptions.self, from: .object(object), path: path)
        guard (0...4).contains(options.playerOptionCount) else {
            throw .invalidParams("'\(path).playerOptionCount' must be between 0 and 4.")
        }
        return (options, timeout, warnings)
    }

    /// Decodes memory `{"facts"?, "relationship"?, "summary"?}`.
    public static func memory(from value: JSONValue?, path: String = "memory") throws(BridgeError) -> NPCMemory {
        guard let value, !value.isNull else { return NPCMemory() }
        guard value.objectValue != nil else { throw .invalidParams("'\(path)' must be an object.") }
        return try GameJSON.decode(NPCMemory.self, from: value, path: path)
    }

    /// Decodes a save state from `npc/state` (`{"version", "persona",
    /// "memory", "transcript", …}`); the whole `npc/state` result is accepted too.
    public static func saveState(from value: JSONValue, path: String = "state") throws(BridgeError) -> NPCSaveState {
        guard let object = value.objectValue else { throw .invalidParams("'\(path)' must be a save state object from npc/state.") }
        if object["persona"] == nil, let inner = object["state"], inner.objectValue != nil {
            return try saveState(from: inner, path: path + ".state")
        }
        let state = try GameJSON.decode(NPCSaveState.self, from: value, path: path)
        guard !state.persona.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidParams("'\(path).persona.name' must not be empty.")
        }
        return state
    }

    /// Decision options: `[{"id", "description"?}]`, or plain id strings.
    /// Ids are trimmed and must be unique and non-empty.
    public static func decisionOptions(from value: JSONValue, path: String = "options") throws(BridgeError) -> [DecisionOption] {
        guard let array = value.arrayValue, !array.isEmpty else {
            throw .invalidParams("'\(path)' must be a non-empty array of {\"id\", \"description\"} objects.")
        }
        var options: [DecisionOption] = []
        var seen: Set<String> = []
        for (index, element) in array.enumerated() {
            let elementPath = "\(path)[\(index)]"
            var option: DecisionOption
            if let id = element.stringValue {
                option = DecisionOption(id: id)
            } else if let object = element.objectValue {
                let params = BridgeParams(object, path: elementPath + ".")
                option = DecisionOption(id: try params.string("id"), description: try params.optionalString("description") ?? "")
            } else {
                throw .invalidParams("'\(elementPath)' must be an object {\"id\", \"description\"} or an id string.")
            }
            option.id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !option.id.isEmpty else { throw .invalidParams("'\(elementPath).id' must not be empty.") }
            guard seen.insert(option.id).inserted else { throw .invalidParams("Duplicate option id '\(option.id)' in '\(path)'.") }
            options.append(option)
        }
        return options
    }

    // MARK: Memory tool names

    static let memoryToolNamesByFlag: [(name: String, flag: NPCMemoryTools)] = [
        ("rememberFact", .rememberFact),
        ("changeRelationship", .changeRelationship),
    ]

    static func memoryToolNames(_ tools: NPCMemoryTools) -> [String] {
        memoryToolNamesByFlag.filter { tools.contains($0.flag) }.map(\.name)
    }

    static func memoryTools(_ value: JSONValue, path: String) throws(BridgeError) -> NPCMemoryTools {
        let names: [JSONValue]
        if let name = value.stringValue {
            switch name {
            case "all": return .all
            case "none": return []
            default: names = [value]
            }
        } else if let array = value.arrayValue {
            names = array
        } else {
            throw .invalidParams("'\(path)' must be a list such as [\"rememberFact\", \"changeRelationship\"], \"all\" or \"none\".")
        }
        var tools: NPCMemoryTools = []
        for name in names {
            let text = name.stringValue ?? ""
            // Also accept the tool names the model sees (remember_fact…).
            let key = text.replacingOccurrences(of: "_", with: "").lowercased()
            guard let match = memoryToolNamesByFlag.first(where: { $0.name.lowercased() == key }) else {
                let known = memoryToolNamesByFlag.map { "\"\($0.name)\"" }.joined(separator: ", ")
                throw .invalidParams("'\(path)' contains unknown memory tool \(name.serialized()); known: \(known).")
            }
            tools.insert(match.flag)
        }
        return tools
    }

    static func unknownKeys(_ object: JSONObject, allowed: Set<String>, path: String) -> [String] {
        object.keys.filter { !allowed.contains($0) }.map { "Unknown parameter '\(path).\($0)' was ignored." }
    }
}

private extension JSONValue {
    /// `JSONValue(encoding:)` for values whose encoding cannot fail in practice.
    init(encoding value: some Encodable, orThrow path: String) throws(BridgeError) {
        do {
            self = try JSONValue(encoding: value)
        } catch {
            throw .invalidParams("'\(path)' could not be encoded: \(error)")
        }
    }
}
