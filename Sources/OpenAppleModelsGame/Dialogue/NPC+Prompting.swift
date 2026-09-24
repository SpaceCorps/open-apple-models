import Foundation
import FoundationModels
import OpenAppleModels

/// Prompt, schema and tool construction for ``NPC``. Everything here is a
/// pure function of the persona, options and memory, which keeps it easy to
/// test and to tune for the small on-device model.
extension NPC {
    // MARK: Tools

    static func composeTools(user: [AgentTool], world: WorldState?, options: NPCOptions, store: MemoryStore) -> [AgentTool] {
        var tools = user
        if let world {
            tools += world.tools(readable: options.worldReadable, writable: options.worldWritable)
        }
        tools += memoryTools(options: options, store: store)
        return tools
    }

    static func validate(_ options: NPCOptions, toolNames: [String]) throws(AgentError) {
        var seen: Set<String> = []
        for name in toolNames where !seen.insert(name).inserted {
            throw AgentError(.invalidRequest, "Duplicate tool name '\(name)' (built-in world and memory tools use read_world_state, update_world_state, remember_fact and change_relationship).")
        }
        if let grounding = options.groundingTool, !seen.contains(grounding) {
            throw AgentError(.invalidRequest, "groundingTool '\(grounding)' is not one of the NPC's tools: \(toolNames.joined(separator: ", ")).")
        }
        if case .tool(let name) = options.toolChoice, !seen.contains(name) {
            throw AgentError(.invalidRequest, "toolChoice names unknown tool '\(name)'.")
        }
    }

    static func memoryTools(options: NPCOptions, store: MemoryStore) -> [AgentTool] {
        var tools: [AgentTool] = []
        if options.memoryTools.contains(.rememberFact) {
            let parameters = JSONSchema.object([
                "fact": .string(description: "One short fact, e.g. 'The player's name is Aria.'"),
            ])
            tools.append(try! AgentTool(
                name: rememberFactToolName,
                description: "Remember an important fact about the player or the world for later conversations.",
                parameters: parameters
            ) { call in
                let fact = try call.string("fact")
                guard fact.trimmedOrNil != nil else { return .error("The fact is empty.") }
                return store.stageFact(fact) ? .text("Remembered.") : .text("You already know that.")
            })
        }
        if options.memoryTools.contains(.changeRelationship) {
            let limit = max(1, options.maxRelationshipChange)
            let parameters = JSONSchema.object([
                "reason": .string(description: "Why your feelings changed, in a few words."),
                "delta": .integer(description: "Negative if the player upset you, positive if they pleased you.", minimum: -limit, maximum: limit),
            ])
            tools.append(try! AgentTool(
                name: changeRelationshipToolName,
                description: "Change how much you like the player when they clearly please or offend you.",
                parameters: parameters
            ) { call in
                let delta = min(max(try call.int("delta"), -limit), limit)
                let value = store.stageRelationship(delta)
                return .text("You now feel \(NPCMemory.attitude(for: value)) toward the player (\(value)).")
            })
        }
        return tools
    }

    // MARK: Instructions

    static func instructions(persona: Persona, options: NPCOptions, tools: [AgentTool], memory: NPCMemory) -> String {
        let builtIn: Set<String> = [rememberFactToolName, changeRelationshipToolName]
        let factTools = tools.contains { !builtIn.contains($0.name) }
        var extra: [String] = []
        if let text = options.extraInstructions?.trimmedOrNil { extra.append(text) }
        if tools.contains(where: { $0.name == rememberFactToolName }) {
            extra.append("- When the player tells you something worth remembering, call \(rememberFactToolName).")
        }
        if tools.contains(where: { $0.name == changeRelationshipToolName }) {
            extra.append("- When the player clearly pleases or offends you, call \(changeRelationshipToolName).")
        }
        if options.replyFormat == .text {
            extra.append("- Begin every reply with your current emotion in square brackets, such as [happy] or [angry].")
        }
        let visibility: Persona.SecretVisibility
        if let threshold = options.secretsUnlockAtRelationship {
            visibility = memory.relationship >= threshold ? .shareable : .hidden
        } else {
            visibility = .guarded
        }
        return persona.instructions(extra: extra.isEmpty ? nil : extra.joined(separator: "\n"), usesTools: factTools, secrets: visibility)
    }

    static func memoryNote(_ memory: NPCMemory, options: NPCOptions) -> String? {
        memory.note(includeRelationship: options.memoryTools.contains(.changeRelationship))
    }

    static func summaryInstructions(for persona: Persona) -> String {
        """
        You keep \(persona.name)'s memory of talking with the player in a video game. \
        Merge the new conversation into the summary so far. If \(persona.name)'s turns are JSON, only their "line" was spoken. \
        Keep names, promises, deals, items, prices, facts learned and how \(persona.name) feels about the player. \
        Write at most 100 words of plain prose in the third person.
        """
    }

    static func configuration(_ options: NPCOptions) -> AgentConfiguration {
        AgentConfiguration(
            toolPolicy: ToolPolicy(choice: options.toolChoice, maxToolRounds: options.maxToolRounds, maxToolCalls: options.maxToolCalls),
            temperature: options.temperature,
            maximumResponseTokens: options.maximumResponseTokens)
    }

    // MARK: Prompt and schema

    /// The prompt for the plain-text retry of a turn whose structured reply
    /// was blocked: same situation, results of tools already called (so the
    /// retry stays grounded without re-running side effects), and the
    /// emotion-tag convention of ``NPCReplyFormat/text``.
    static func textRetryPrompt(_ prompt: String, toolRecords: [ToolRecord]) -> String {
        var lines = [prompt]
        let results = toolRecords.filter { !$0.output.isError }
        if !results.isEmpty {
            lines.append("Facts you just looked up:")
            for record in results.prefix(6) {
                lines.append("- \(record.call.name) \(record.call.arguments.serialized()) → \(record.output.modelText.prefix(400))")
            }
        }
        lines.append("Reply in character with a short spoken line. Begin with your emotion in square brackets, such as [happy] or [angry].")
        return lines.joined(separator: "\n")
    }

    /// The player's words are always framed as dialogue (`Player: …`):
    /// measured on device, this halved input-guardrail blocks for ordinary
    /// fantasy lines compared with passing the raw line.
    static func prompt(playerLine: String, context: String?, worldSummary: String?) -> String {
        var lines: [String] = []
        if let summary = worldSummary?.trimmedOrNil { lines.append("Game state:\n\(summary)") }
        if let context = context?.trimmedOrNil { lines.append("Situation: \(context)") }
        lines.append("Player: " + (playerLine.trimmedOrNil ?? "(The player says nothing.)"))
        return lines.joined(separator: "\n")
    }

    /// The reply schema. Property order matters: the model writes the
    /// emotion first (setting the tone), then the line, then suggestions.
    static func replySchema(persona: Persona, options: NPCOptions) -> JSONSchema {
        var emotions: [String] = []
        for emotion in options.emotions.isEmpty ? Emotion.allCases : options.emotions where !emotions.contains(emotion.rawValue) {
            emotions.append(emotion.rawValue)
        }
        let sentences = max(1, persona.maxSentences)
        var properties: [(String, JSONValue)] = [
            ("emotion", JSONSchema.string(description: "How \(persona.name) feels right now.", enum: emotions).json),
            ("line", JSONSchema.string(description: "What \(persona.name) says out loud, in character. At most \(sentences) short \(sentences == 1 ? "sentence" : "sentences"). If a tool was just used, name the specific facts it gave (items, prices, numbers).").json),
        ]
        let count = min(max(options.playerOptionCount, 0), 4)
        if count > 0 {
            properties.append(("player_options", JSONSchema.array(
                of: .string(),
                description: "\(count) short, different replies the player could say next.",
                minItems: count, maxItems: count).json))
        }
        if options.canEndConversation {
            properties.append(("ends_conversation", JSONSchema.boolean(description: "true only if \(persona.name) ends the conversation now.").json))
        }
        return JSONSchema(.object([
            "type": "object",
            "properties": .object(JSONObject(properties)),
            "required": .array(properties.map { .string($0.0) }),
            "additionalProperties": false,
        ]))
    }

    struct Reply: Equatable {
        var line: String
        var emotion: Emotion
        var playerOptions: [String]
        var endsConversation: Bool
    }

    /// Reads the model's structured reply defensively (any field may be
    /// missing or odd when a non-constraining model is used).
    static func parseReply(_ value: JSONValue?, persona: Persona, options: NPCOptions) -> Reply {
        let emotion = value?["emotion"]?.stringValue.flatMap(Emotion.init(matching:)) ?? persona.defaultEmotion
        let line = TextCleanup.spokenLine(value?["line"]?.stringValue ?? "", speaker: persona.name)
        var suggestions: [String] = []
        for item in value?["player_options"]?.arrayValue ?? [] {
            guard let text = item.stringValue else { continue }
            // Strip list markers ("1. ", "- ") and labels the model may add.
            let unmarked = text.replacing(/^\s*(?:[-*•]|\d{1,2}[.)])\s+/, with: "")
            let cleaned = TextCleanup.spokenLine(unmarked, speaker: "Player")
            guard !cleaned.isEmpty, !suggestions.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else { continue }
            suggestions.append(cleaned)
        }
        let count = min(max(options.playerOptionCount, 0), 4)
        return Reply(
            line: line,
            emotion: emotion,
            playerOptions: Array(suggestions.prefix(count)),
            endsConversation: options.canEndConversation && (value?["ends_conversation"]?.boolValue ?? false))
    }

    /// Splits a plain-text reply into its leading `[emotion]` tag and the
    /// spoken text. `pending` is true while an opening tag is still streaming.
    static func splitEmotionTag(_ text: String) -> (tag: String?, rest: String, pending: Bool) {
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.first == "[" else { return (nil, String(trimmed), false) }
        guard let close = trimmed.firstIndex(of: "]") else {
            // A tag longer than a word or two is not a tag.
            return trimmed.count > 24 ? (nil, String(trimmed), false) : (nil, "", true)
        }
        let tag = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        return (tag, String(trimmed[trimmed.index(after: close)...].drop { $0.isWhitespace }), false)
    }

    /// The partial reply of a streaming plain-text turn, in the same shape as
    /// structured output, or `nil` while an emotion tag is incomplete.
    static func partialTextReply(_ text: String) -> JSONValue? {
        let split = splitEmotionTag(text)
        guard !split.pending else { return nil }
        guard let tag = split.tag else { return ["line": .string(split.rest)] }
        return ["emotion": .string(tag), "line": .string(split.rest)]
    }

    static func parseTextReply(_ text: String, persona: Persona) -> Reply {
        let split = splitEmotionTag(text)
        return Reply(
            line: TextCleanup.spokenLine(split.rest, speaker: persona.name),
            emotion: split.tag.flatMap(Emotion.init(matching:)) ?? persona.defaultEmotion,
            playerOptions: [],
            endsConversation: false)
    }

    // MARK: History helpers

    static func turnCount(_ entries: [Transcript.Entry]) -> Int {
        entries.reduce(0) { count, entry in
            if case .prompt = entry { count + 1 } else { count }
        }
    }

    /// Drops a trailing turn that has no response yet.
    static func completeTurns(of transcript: Transcript) -> Transcript {
        let entries = Array(transcript)
        guard let lastPrompt = entries.lastIndex(where: { if case .prompt = $0 { true } else { false } }) else {
            return transcript
        }
        let answered = entries[(lastPrompt + 1)...].contains { if case .response = $0 { true } else { false } }
        return answered ? transcript : Transcript(entries: entries[..<lastPrompt])
    }
}
