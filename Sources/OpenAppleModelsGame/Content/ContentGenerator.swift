import Foundation
import FoundationModels
import OpenAppleModels

/// Generates structured game content — items, quests, level text, loot
/// tables, rumors — that matches a JSON Schema.
///
/// ```swift
/// let generator = ContentGenerator()
/// let sword = try await generator.generate(
///     "A cursed sword found in a drowned temple.",
///     as: Item.self,
///     schema: .object([
///         "name": .string(description: "Two or three words"),
///         "description": .string(description: "One sentence of flavor text"),
///         "rarity": .string(enum: ["common", "rare", "legendary"]),
///         "damage": .integer(minimum: 1, maximum: 50),
///     ]))
/// ```
///
/// Tips for the small on-device model: keep schemas flat and short, put
/// guidance in property descriptions, order properties so earlier ones
/// inform later ones (name → description → stats), and generate lists with
/// `.array(of:minItems:maxItems:)` rather than one call per item. Regex
/// `pattern`s are described to the model but not enforced.
public struct ContentGenerator: Sendable {
    public var model: any LanguageModel
    /// Default instructions, used when a call passes none.
    public var instructions: String
    /// Sampling temperature (`nil` = model default). Raise it for variety.
    public var temperature: Double?

    public static let defaultInstructions = """
        You write content for a video game. Follow the requested format exactly. \
        Keep text short, vivid and consistent with the request.
        """

    public init(
        model: any LanguageModel = SystemLanguageModel.default,
        instructions: String = ContentGenerator.defaultInstructions,
        temperature: Double? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.temperature = temperature
    }

    /// Generates JSON matching `schema`, with object keys in schema order.
    ///
    /// - Parameters:
    ///   - prompt: What to generate.
    ///   - schema: The output shape (see ``JSONSchema``).
    ///   - instructions: Overrides ``instructions`` for this call.
    ///   - context: Extra facts as JSON (player level, biome, existing names…).
    ///   - tools: Tools the model may call first (e.g. to look up game data).
    public func generate(
        _ prompt: String,
        schema: JSONSchema,
        instructions: String? = nil,
        context: JSONValue? = nil,
        tools: [AgentTool] = []
    ) async throws(AgentError) -> JSONValue {
        let agent = try Agent(
            model: model,
            instructions: instructions?.trimmedOrNil ?? self.instructions,
            tools: tools,
            configuration: AgentConfiguration(temperature: temperature))
        var text = prompt
        if let context, context != .null { text += "\nFacts: \(context.serialized())" }
        let response = try await agent.respond(
            to: text, schema: schema,
            policy: ToolPolicy(choice: tools.isEmpty ? .none : .auto))
        guard let structured = response.structured else {
            throw AgentError(.generationFailed, "The model produced no structured content.")
        }
        return structured
    }

    /// Generates content and decodes it into `T`. Property names in
    /// `schema` must match `T`'s coding keys.
    public func generate<T: Decodable>(
        _ prompt: String,
        as type: T.Type,
        schema: JSONSchema,
        instructions: String? = nil,
        context: JSONValue? = nil,
        tools: [AgentTool] = []
    ) async throws(AgentError) -> T {
        let json = try await generate(prompt, schema: schema, instructions: instructions, context: context, tools: tools)
        do {
            return try json.decode(type)
        } catch {
            throw AgentError(.generationFailed, "Could not decode \(T.self) from generated content \(json.serialized()): \(error)")
        }
    }
}
