import Foundation
import FoundationModels
import Synchronization

/// How the model may use tools during one turn.
///
/// Encodes as JSON `"auto"`, `"none"`, `"required"` or `{"tool": "name"}`.
/// Decoding also accepts OpenAI's `{"type": "function", "function": {"name": …}}`.
public enum ToolChoice: Sendable, Hashable {
    /// The model decides at every step.
    case auto
    /// Tools are disabled for this turn.
    case none
    /// The model must call at least one tool first, then answers freely.
    case required
    /// The model must call the named tool first, then answers freely.
    case tool(String)
    /// The model must make an explicit decision on the first step: call one
    /// of the tools, or call a built-in `respond_directly` tool that says no
    /// lookup is needed. More reliable grounding than ``auto`` (on device, auto
    /// often skips tools and invents facts) at the cost of one short step;
    /// unlike ``required`` it never forces a pointless tool call for small talk.
    case explicit
}

extension ToolChoice: Codable {
    private enum Keys: String, CodingKey { case tool, type, function, name }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            switch text {
            case "auto": self = .auto
            case "none": self = .none
            case "required", "any": self = .required
            case "explicit": self = .explicit
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Expected \"auto\", \"none\", \"required\", \"explicit\" or {\"tool\": name}, got \"\(text)\"."))
            }
            return
        }
        let container = try decoder.container(keyedBy: Keys.self)
        if let name = try container.decodeIfPresent(String.self, forKey: .tool) {
            self = .tool(name)
        } else if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self = .tool(name)
        } else {
            let function = try container.nestedContainer(keyedBy: Keys.self, forKey: .function)
            self = .tool(try function.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .auto: var c = encoder.singleValueContainer(); try c.encode("auto")
        case .none: var c = encoder.singleValueContainer(); try c.encode("none")
        case .required: var c = encoder.singleValueContainer(); try c.encode("required")
        case .explicit: var c = encoder.singleValueContainer(); try c.encode("explicit")
        case .tool(let name):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(name, forKey: .tool)
        }
    }
}

/// Per-turn limits on the tool-calling loop.
public struct ToolPolicy: Sendable, Hashable {
    public var choice: ToolChoice
    /// Maximum model steps that may emit tool calls. Once reached, tools are
    /// disabled so the model has to answer.
    public var maxToolRounds: Int
    /// Maximum tool calls executed in one turn. Calls beyond this receive an
    /// error output telling the model to answer with what it has.
    public var maxToolCalls: Int
    /// Restricts which tools are enabled this turn (`nil` = all).
    public var enabledTools: Set<String>?

    public init(choice: ToolChoice = .auto, maxToolRounds: Int = 4, maxToolCalls: Int = 12, enabledTools: Set<String>? = nil) {
        self.choice = choice
        self.maxToolRounds = maxToolRounds
        self.maxToolCalls = maxToolCalls
        self.enabledTools = enabledTools
    }

    public static let `default` = ToolPolicy()
}

/// How conversation history is fitted into the model's context window.
public struct ContextPolicy: Sendable, Hashable {
    /// Drop the oldest turns from what the model sees when the transcript
    /// would overflow the context window. The session transcript itself keeps
    /// every entry, so nothing is lost for persistence.
    public var trimsHistory: Bool
    /// Tokens kept free for the model's response.
    public var reservedResponseTokens: Int
    /// Most recent turns always kept, even if the window overflows.
    public var minimumRecentTurns: Int

    public init(trimsHistory: Bool = true, reservedResponseTokens: Int = 1024, minimumRecentTurns: Int = 1) {
        self.trimsHistory = trimsHistory
        self.reservedResponseTokens = reservedResponseTokens
        self.minimumRecentTurns = max(0, minimumRecentTurns)
    }

    public static let `default` = ContextPolicy()
}

/// Information about one model step (one call into the underlying model).
public struct ModelStep: Sendable, Hashable {
    /// Zero-based step index within the turn.
    public var index: Int
    /// Tool rounds already completed in this turn.
    public var completedToolRounds: Int
    public var toolCallingMode: GenerationOptions.ToolCallingMode.Kind
    public var enabledTools: [String]
    /// History entries hidden from the model to fit the context window.
    public var trimmedEntries: Int

    public init(index: Int, completedToolRounds: Int, toolCallingMode: GenerationOptions.ToolCallingMode.Kind, enabledTools: [String], trimmedEntries: Int) {
        self.index = index
        self.completedToolRounds = completedToolRounds
        self.toolCallingMode = toolCallingMode
        self.enabledTools = enabledTools
        self.trimmedEntries = trimmedEntries
    }
}

/// Decides the tool-calling mode, enabled tools and visible history for
/// each model step. Shared by the agent (which sets the turn's policy) and
/// the ``SteeredLanguageModel`` executor (which applies it per step).
public final class StepController: Sendable {
    private struct State {
        var policy = ToolPolicy.default
        var context = ContextPolicy.default
        var stepIndex = 0
        var observer: (@Sendable (ModelStep) -> Void)?
    }

    private let state = Mutex(State())
    private let activeSteps = Mutex(0)

    public init() {}

    /// Model steps currently executing (the framework may still be running a
    /// step after the session reports it is no longer responding).
    var runningSteps: Int { activeSteps.withLock { $0 } }
    func stepStarted() { activeSteps.withLock { $0 += 1 } }
    func stepEnded() { activeSteps.withLock { $0 -= 1 } }

    /// Sets the policy for the next turn and resets step counting.
    public func beginTurn(policy: ToolPolicy, context: ContextPolicy, observer: (@Sendable (ModelStep) -> Void)? = nil) {
        state.withLock {
            $0.policy = policy
            $0.context = context
            $0.stepIndex = 0
            $0.observer = observer
        }
    }

    public func endTurn() {
        state.withLock { $0.observer = nil }
    }

    /// Adjusts a generation request before it reaches the model.
    func prepare(
        _ request: LanguageModelExecutorGenerationRequest,
        contextSize: Int?,
        countTokens: (@Sendable ([Transcript.Entry]) async throws -> Int)?
    ) async -> LanguageModelExecutorGenerationRequest {
        let (policy, context, index, observer) = state.withLock { state in
            defer { state.stepIndex += 1 }
            return (state.policy, state.context, state.stepIndex, state.observer)
        }
        var request = request
        let turn = Self.currentTurn(of: request.transcript)
        let rounds = turn.filter { if case .toolCalls = $0 { true } else { false } }.count
        // The model already said it can respond without a lookup.
        let choseToRespond = turn.contains { entry in
            if case .toolCalls(let calls) = entry { calls.allSatisfy { $0.toolName == AgentTool.respondDirectlyName } } else { false }
        }
        let calls = turn.reduce(0) { count, entry in
            if case .toolCalls(let calls) = entry { count + calls.count } else { count }
        }

        if let enabled = policy.enabledTools {
            request.enabledToolDefinitions.removeAll { !enabled.contains($0.name) }
        }
        let offersRespondDirectly = policy.choice == .explicit && rounds == 0
        if !offersRespondDirectly {
            request.enabledToolDefinitions.removeAll { $0.name == AgentTool.respondDirectlyName }
            request.transcript = Self.removingToolDefinition(named: AgentTool.respondDirectlyName, from: request.transcript)
        }
        var mode: GenerationOptions.ToolCallingMode
        switch policy.choice {
        case .none:
            mode = .disallowed
        case _ where choseToRespond:
            mode = .disallowed
        case _ where rounds >= policy.maxToolRounds || calls >= policy.maxToolCalls:
            mode = .disallowed
        case .required where rounds == 0, .explicit where rounds == 0:
            mode = .required
        case .tool(let name) where rounds == 0:
            request.enabledToolDefinitions.removeAll { $0.name != name }
            mode = .required
        default:
            mode = .allowed
        }
        if request.enabledToolDefinitions.isEmpty { mode = .disallowed }
        request.generationOptions.toolCallingMode = mode
        if mode.kind == .disallowed {
            // With tool definitions still visible, the on-device model tends to
            // answer "let me check…" instead of answering. Hide them entirely.
            request.enabledToolDefinitions = []
            request.transcript = Self.hidingToolDefinitions(request.transcript)
        }

        var trimmed = 0
        if context.trimsHistory, let contextSize {
            trimmed = await Self.trim(&request.transcript, contextSize: contextSize, policy: context, countTokens: countTokens)
        }

        observer?(ModelStep(
            index: index,
            completedToolRounds: rounds,
            toolCallingMode: mode.kind,
            enabledTools: request.enabledToolDefinitions.map(\.name).filter { $0 != AgentTool.respondDirectlyName },
            trimmedEntries: trimmed))
        return request
    }

    static func removingToolDefinition(named name: String, from transcript: Transcript) -> Transcript {
        guard case .instructions(var instructions)? = transcript.first,
              instructions.toolDefinitions.contains(where: { $0.name == name }) else { return transcript }
        instructions.toolDefinitions.removeAll { $0.name == name }
        var entries = Array(transcript)
        entries[0] = .instructions(instructions)
        return Transcript(entries: entries)
    }

    static func hidingToolDefinitions(_ transcript: Transcript) -> Transcript {
        guard case .instructions(var instructions)? = transcript.first, !instructions.toolDefinitions.isEmpty else {
            return transcript
        }
        instructions.toolDefinitions = []
        var entries = Array(transcript)
        entries[0] = .instructions(instructions)
        return Transcript(entries: entries)
    }

    /// Entries after the most recent prompt (the turn in progress).
    static func currentTurn(of transcript: Transcript) -> ArraySlice<Transcript.Entry> {
        let entries = Array(transcript)
        guard let last = entries.lastIndex(where: { if case .prompt = $0 { true } else { false } }) else {
            return entries[...]
        }
        return entries[(last + 1)...]
    }

    /// Removes the oldest complete turns until the transcript fits.
    /// Returns the number of entries removed.
    static func trim(
        _ transcript: inout Transcript,
        contextSize: Int,
        policy: ContextPolicy,
        countTokens: (@Sendable ([Transcript.Entry]) async throws -> Int)?
    ) async -> Int {
        let budget = contextSize - policy.reservedResponseTokens
        let entries = Array(transcript)
        // Cheap estimate first (~3 characters per token for English); only
        // ask the tokenizer when the estimate gets close to the budget.
        let estimate = entries.reduce(0) { $0 + $1.description.count } / 3
        guard estimate > budget * 6 / 10 else { return 0 }

        func tokens(_ entries: [Transcript.Entry]) async -> Int {
            if let countTokens, let count = try? await countTokens(entries) { return count }
            return entries.reduce(0) { $0 + $1.description.count } / 3
        }
        guard await tokens(entries) > budget else { return 0 }

        let head = entries.first.map { if case .instructions = $0 { 1 } else { 0 } } ?? 0
        let promptIndices = entries.indices.filter { if case .prompt = entries[$0] { true } else { false } }
        // Turn boundaries we may cut at, keeping the most recent turns.
        // Never cut into the turn in progress (the last prompt), and keep at
        // least `minimumRecentTurns` complete turns before it when possible.
        let keepTurns = max(1, policy.minimumRecentTurns)
        let keepFrom = promptIndices.count >= keepTurns
            ? promptIndices[promptIndices.count - keepTurns]
            : (promptIndices.first ?? head)
        let cutPoints = promptIndices.filter { $0 > head && $0 <= keepFrom }

        var best = entries
        for cut in cutPoints {
            let candidate = Array(entries[..<head]) + Array(entries[cut...])
            best = candidate
            if await tokens(candidate) <= budget { break }
        }
        let removed = entries.count - best.count
        if removed > 0 { transcript = Transcript(entries: best) }
        return removed
    }
}

/// Wraps any FoundationModels `LanguageModel` and applies a ``StepController``
/// to every model step.
///
/// FoundationModels runs the tool loop inside a single `respond` call, and
/// `GenerationOptions.toolCallingMode` applies to every step of that loop:
/// `.required` makes the on-device model call tools forever. Wrapping the
/// model gives per-step control instead — require a tool on the first step,
/// allow tools afterwards, disable them once the budget is spent — without
/// leaving the framework's own loop.
public struct SteeredLanguageModel<Base: LanguageModel>: LanguageModel {
    public typealias Executor = SteeredExecutor<Base>

    public let base: Base
    public let controller: StepController

    public init(base: Base, controller: StepController = StepController()) {
        self.base = base
        self.controller = controller
    }

    public var capabilities: LanguageModelCapabilities { base.capabilities }

    public var executorConfiguration: SteeredExecutor<Base>.Configuration {
        SteeredExecutor<Base>.Configuration(base: base.executorConfiguration)
    }
}

public struct SteeredExecutor<Base: LanguageModel>: LanguageModelExecutor {
    public struct Configuration: Hashable, Sendable {
        public var base: Base.Executor.Configuration
    }

    public typealias Model = SteeredLanguageModel<Base>

    private let inner: Base.Executor

    public init(configuration: Configuration) throws {
        inner = try Base.Executor(configuration: configuration.base)
    }

    public func prewarm(model: SteeredLanguageModel<Base>, transcript: Transcript) {
        inner.prewarm(model: model.base, transcript: transcript)
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: SteeredLanguageModel<Base>,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        model.controller.stepStarted()
        defer { model.controller.stepEnded() }
        var contextSize: Int?
        var countTokens: (@Sendable ([Transcript.Entry]) async throws -> Int)?
        if let system = model.base as? SystemLanguageModel {
            contextSize = system.contextSize
            countTokens = { entries in try await system.tokenCount(for: entries) }
        }
        let adjusted = await model.controller.prepare(request, contextSize: contextSize, countTokens: countTokens)
        try await inner.respond(to: adjusted, model: model.base, streamingInto: channel)
    }
}
