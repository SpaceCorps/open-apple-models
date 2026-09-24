import Foundation
import FoundationModels
import OpenAppleModels

/// One choice offered to a ``DecisionEngine``.
public struct DecisionOption: Sendable, Hashable, Codable {
    /// Stable identifier returned in ``Decision/optionID`` (e.g. `"attack"`).
    /// Short, lowercase, snake_case ids work best with the small model.
    public var id: String
    /// What choosing it means, in a short sentence.
    public var description: String

    public init(id: String, description: String = "") {
        self.id = id
        self.description = description
    }

    private enum CodingKeys: String, CodingKey { case id, description }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id), description: try container.decode(.description, default: ""))
    }
}

/// The outcome of ``DecisionEngine/decide(situation:options:actor:context:tools:toolChoice:fallbackOptionID:)``.
public struct Decision: Sendable, Hashable, Codable {
    /// The chosen ``DecisionOption/id``.
    public var optionID: String
    /// The model's one-sentence justification (generated before the choice).
    public var reasoning: String
    /// Self-reported confidence, `0...100`. Useful as a tie-breaker or to
    /// fall back to scripted behavior when low; not a calibrated probability.
    public var confidence: Int
    /// Tools executed while deciding.
    public var toolCalls: [ToolRecord]
    public var usage: TokenUsage
    /// True when the model was blocked (guardrail or refusal) and the
    /// request's fallback option was returned instead.
    public var isFallback: Bool

    public init(optionID: String, reasoning: String, confidence: Int, toolCalls: [ToolRecord] = [], usage: TokenUsage = TokenUsage(), isFallback: Bool = false) {
        self.optionID = optionID
        self.reasoning = reasoning
        self.confidence = confidence
        self.toolCalls = toolCalls
        self.usage = usage
        self.isFallback = isFallback
    }

    private enum CodingKeys: String, CodingKey { case optionID, reasoning, confidence, toolCalls, usage, isFallback }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            optionID: try c.decode(String.self, forKey: .optionID),
            reasoning: try c.decode(.reasoning, default: ""),
            confidence: try c.decode(.confidence, default: 50),
            toolCalls: try c.decode(.toolCalls, default: []),
            usage: try c.decode(.usage, default: TokenUsage()),
            isFallback: try c.decode(.isFallback, default: false))
    }
}

/// A decision to make, for ``DecisionEngine/decideMany(_:maxConcurrency:)``.
public struct DecisionRequest: Sendable {
    public var situation: String
    public var options: [DecisionOption]
    public var actor: Persona?
    public var context: JSONValue?
    public var tools: [AgentTool]
    public var toolChoice: ToolChoice
    /// Option returned (with ``Decision/isFallback``) when guardrails block the decision.
    public var fallbackOptionID: String?

    public init(
        situation: String,
        options: [DecisionOption],
        actor: Persona? = nil,
        context: JSONValue? = nil,
        tools: [AgentTool] = [],
        toolChoice: ToolChoice = .auto,
        fallbackOptionID: String? = nil
    ) {
        self.situation = situation
        self.options = options
        self.actor = actor
        self.context = context
        self.tools = tools
        self.toolChoice = toolChoice
        self.fallbackOptionID = fallbackOptionID
    }
}

/// Picks one of a fixed set of options with the on-device model — enemy
/// tactics, companion reactions, shopkeeper haggling, crowd behavior.
///
/// The model answers with a schema whose `choice` is an enum of the option
/// ids, so it can only return a valid id. It writes a one-sentence
/// `reasoning` first (a tiny chain of thought that improves choices), then
/// the `choice`, then a `confidence`. On device this takes about 1–2 s
/// without tools.
///
/// ```swift
/// let engine = DecisionEngine()
/// let decision = try await engine.decide(
///     situation: "The goblin has 3 HP left and the player is at full health.",
///     options: [
///         DecisionOption(id: "attack", description: "Keep fighting"),
///         DecisionOption(id: "flee", description: "Run into the woods"),
///         DecisionOption(id: "beg", description: "Beg for mercy"),
///     ])
/// switch decision.optionID { case "flee": goblin.flee(); default: … }
/// ```
///
/// Every decision uses a fresh session (no history), so the engine is
/// stateless and safe to share across tasks.
public struct DecisionEngine: Sendable {
    public var model: any LanguageModel
    /// Replaces the default instructions (the actor's persona is still added).
    public var instructions: String?
    /// Sampling temperature (`nil` = model default). Use a low value for
    /// consistent behavior.
    public var temperature: Double?
    /// Maximum model steps that may call tools.
    public var maxToolRounds: Int

    public init(
        model: any LanguageModel = SystemLanguageModel.default,
        instructions: String? = nil,
        temperature: Double? = nil,
        maxToolRounds: Int = 2
    ) {
        self.model = model
        self.instructions = instructions
        self.temperature = temperature
        self.maxToolRounds = maxToolRounds
    }

    /// Chooses one of `options`.
    ///
    /// - Parameters:
    ///   - situation: What is happening, from the actor's point of view.
    ///   - options: The choices. Ids must be unique and non-empty.
    ///   - actor: The character deciding; its personality and goals shape the choice.
    ///   - context: Extra facts as JSON (health, distances, inventory…).
    ///   - tools: Tools the model may call before choosing.
    ///   - toolChoice: `.required` / `.tool(name)` to force a lookup first.
    ///   - fallbackOptionID: Returned (with ``Decision/isFallback`` set) when
    ///     guardrails block the request or the model refuses — combat
    ///     situations trip the on-device guardrails fairly often.
    /// - Returns: The decision. With a single option, it is returned
    ///   immediately without calling the model.
    /// - Throws: ``AgentError`` with `.invalidRequest` for invalid options,
    ///   or any model error (guardrails without a fallback, unavailable model, …).
    public func decide(
        situation: String,
        options: [DecisionOption],
        actor: Persona? = nil,
        context: JSONValue? = nil,
        tools: [AgentTool] = [],
        toolChoice: ToolChoice = .auto,
        fallbackOptionID: String? = nil
    ) async throws(AgentError) -> Decision {
        let ids = try Self.validate(options)
        let fallback = fallbackOptionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !ids.contains(fallback) {
            throw AgentError(.invalidRequest, "fallbackOptionID '\(fallback)' is not one of: \(ids.joined(separator: ", ")).")
        }
        if ids.count == 1 {
            return Decision(optionID: ids[0], reasoning: "It is the only option.", confidence: 100)
        }
        let agent = try Agent(
            model: model,
            instructions: instructions(for: actor),
            tools: tools,
            configuration: AgentConfiguration(temperature: temperature))
        let policy = ToolPolicy(choice: tools.isEmpty ? .none : toolChoice, maxToolRounds: maxToolRounds)
        do {
            let response = try await agent.respond(
                to: Self.prompt(situation: situation, options: options, context: context),
                schema: Self.schema(ids: ids),
                policy: policy)
            return try Self.decision(from: response, ids: ids)
        } catch {
            guard let fallback, error.code == .guardrailViolation || error.code == .refusal else { throw error }
            return Decision(optionID: fallback, reasoning: "", confidence: 0, isFallback: true)
        }
    }

    /// Makes one decision for a ``DecisionRequest``.
    public func decide(_ request: DecisionRequest) async throws(AgentError) -> Decision {
        try await decide(
            situation: request.situation, options: request.options, actor: request.actor,
            context: request.context, tools: request.tools, toolChoice: request.toolChoice,
            fallbackOptionID: request.fallbackOptionID)
    }

    /// Makes several independent decisions (e.g. for a crowd of NPCs) with
    /// at most `maxConcurrency` running at once. The on-device model
    /// processes requests largely one at a time, so higher concurrency mostly
    /// adds queueing; 2 keeps the model busy without starving other work.
    ///
    /// - Returns: One result per request, in request order. A failed decision
    ///   does not affect the others.
    public func decideMany(_ requests: [DecisionRequest], maxConcurrency: Int = 2) async -> [Result<Decision, AgentError>] {
        var results = [Result<Decision, AgentError>?](repeating: nil, count: requests.count)
        let limit = max(1, maxConcurrency)
        await withTaskGroup(of: (Int, Result<Decision, AgentError>).self) { group in
            var next = 0
            func startNext() {
                guard next < requests.count else { return }
                let index = next
                let request = requests[index]
                next += 1
                group.addTask {
                    do throws(AgentError) {
                        return (index, .success(try await decide(request)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(limit, requests.count) { startNext() }
            for await (index, result) in group {
                results[index] = result
                startNext()
            }
        }
        return results.map { $0 ?? .failure(AgentError(.cancelled, "The decision did not run.")) }
    }

    // MARK: Prompting

    static let defaultInstructions = """
        You make decisions for characters in a video game. \
        Pick the option that best fits the character and the situation. \
        Give one short reason, then the option id, then your confidence from 0 to 100.
        """

    func instructions(for actor: Persona?) -> String {
        var lines = [instructions?.trimmedOrNil ?? Self.defaultInstructions]
        if let actor {
            let who = actor.role.trimmedOrNil.map { "\(actor.name), \($0)" } ?? actor.name
            lines.append("You decide for \(who).")
            if let personality = actor.personality.trimmedOrNil { lines.append("Personality: \(Persona.sentence(personality))") }
            if let goals = Persona.list(actor.goals) { lines.append("Goals: \(goals)") }
        }
        return lines.joined(separator: "\n")
    }

    static func prompt(situation: String, options: [DecisionOption], context: JSONValue?) -> String {
        var lines = ["Situation: \(situation.trimmedOrNil ?? "(none given)")"]
        if let context, context != .null, context != .object(JSONObject()) {
            lines.append("Facts: \(context.serialized())")
        }
        lines.append("Options:")
        for option in options {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(option.description.trimmedOrNil.map { "- \(id): \($0)" } ?? "- \(id)")
        }
        return lines.joined(separator: "\n")
    }

    /// Reasoning first (one sentence), then the enum-constrained choice,
    /// then confidence.
    static func schema(ids: [String]) -> JSONSchema {
        .object([
            "reasoning": .string(description: "One short sentence explaining the choice."),
            "choice": .string(description: "The id of the chosen option.", enum: ids),
            "confidence": .integer(description: "How sure you are, from 0 to 100.", minimum: 0, maximum: 100),
        ])
    }

    /// Validates options and returns their trimmed ids.
    static func validate(_ options: [DecisionOption]) throws(AgentError) -> [String] {
        guard !options.isEmpty else { throw AgentError(.invalidRequest, "A decision needs at least one option.") }
        var ids: [String] = []
        for option in options {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw AgentError(.invalidRequest, "Decision option ids must not be empty.") }
            guard !ids.contains(id) else { throw AgentError(.invalidRequest, "Duplicate decision option id '\(id)'.") }
            ids.append(id)
        }
        return ids
    }

    static func decision(from response: AgentResponse, ids: [String]) throws(AgentError) -> Decision {
        let structured = response.structured
        let raw = structured?["choice"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The schema constrains the choice; match case-insensitively for
        // models that do not enforce it.
        guard let id = ids.first(where: { $0 == raw }) ?? ids.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) else {
            throw AgentError(.generationFailed, "The model chose '\(raw)', which is not one of: \(ids.joined(separator: ", ")).")
        }
        let confidence = structured?["confidence"]?.doubleValue.map { Int($0.rounded()) } ?? 50
        return Decision(
            optionID: id,
            reasoning: structured?["reasoning"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            confidence: min(max(confidence, 0), 100),
            toolCalls: response.toolCalls,
            usage: response.usage)
    }
}
