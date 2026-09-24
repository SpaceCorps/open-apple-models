import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsGame
import OpenAppleModelsTesting
import Synchronization
import Testing

/// Thread-safe append-only log for observer and tool callbacks.
final class Log<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])
    func append(_ item: Element) { items.withLock { $0.append(item) } }
    var all: [Element] { items.withLock { $0 } }
}

enum Fixtures {
    static let gorm = Persona(
        name: "Gorm",
        role: "the village blacksmith",
        personality: "Gruff and proud, but fair",
        speakingStyle: "Short, blunt sentences. Calls people 'lad'.",
        backstory: "Forged weapons for the king's army for twenty years.",
        goals: ["Sell his weapons at a fair price"],
        secrets: ["He forged the blade that killed the old king"],
        knowledge: ["The mine to the north is haunted"],
        defaultEmotion: .neutral,
        maxSentences: 2)

    static func inventory(calls: Log<ToolCall>? = nil) throws -> AgentTool {
        try AgentTool(
            name: "check_inventory",
            description: "Look up stock and price of an item.",
            parameters: .object(["item": .string(description: "Item name")])
        ) { call in
            calls?.append(call)
            return .json(["item": .string(try call.string("item")), "stock": 3, "price_gold": 45])
        }
    }

    static func reply(
        _ line: String,
        emotion: String = "neutral",
        options: [String] = ["Tell me more.", "What else?", "Goodbye."],
        ends: Bool = false
    ) -> ModelScript.Step {
        .json([
            "emotion": .string(emotion),
            "line": .string(line),
            "player_options": .array(options.map(JSONValue.string)),
            "ends_conversation": .bool(ends),
        ])
    }

    static let guardrail = ModelScript.Step.fail(LanguageModelError.guardrailViolation(.init(debugDescription: "blocked")))
}

extension ModelScript.ModelRequest {
    /// Enabled tools other than the built-in `respond_directly`.
    var userTools: [String] { enabledTools.filter { $0 != AgentTool.respondDirectlyName } }

    /// Text of the instructions entry the model saw.
    var instructionsText: String {
        for entry in transcript {
            if case .instructions(let instructions) = entry {
                return instructions.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
            }
        }
        return ""
    }

    /// The response schema of the most recent prompt, as encoded by
    /// FoundationModels (property order is in `x-order`).
    func responseSchema() throws -> JSONValue {
        for entry in transcript.reversed() {
            if case .prompt(let prompt) = entry, let format = prompt.responseFormat, case .schema(let schema) = format.kind {
                return try JSONValue(parsing: JSONEncoder().encode(schema))
            }
        }
        throw TestFailure("no response schema in the transcript")
    }

    /// Number of prompt entries (conversation turns) in the transcript.
    var promptCount: Int {
        transcript.reduce(0) { count, entry in if case .prompt = entry { count + 1 } else { count } }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

extension JSONValue {
    /// Property names of an encoded object schema, in generation order.
    var propertyOrder: [String] {
        self["x-order"]?.arrayValue?.compactMap(\.stringValue) ?? self["properties"]?.objectValue?.keys ?? []
    }

    /// All string values found anywhere under `"enum"` or `"const"` keys.
    var enumStrings: [String] {
        switch self {
        case .object(let object):
            var found: [String] = []
            for (key, value) in object {
                if key == "enum", let values = value.arrayValue {
                    found += values.compactMap(\.stringValue)
                } else if key == "const", let value = value.stringValue {
                    found.append(value)
                } else {
                    found += value.enumStrings
                }
            }
            return found
        case .array(let values):
            return values.flatMap(\.enumStrings)
        default:
            return []
        }
    }
}
