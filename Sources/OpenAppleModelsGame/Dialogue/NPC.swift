import Foundation
import FoundationModels
import OpenAppleModels
import Synchronization

/// A conversational non-player character backed by the on-device model.
///
/// Each ``talk(_:context:toolChoice:externalTools:)`` call is one structured
/// turn: the model may call tools first (inventory, world state, memory,
/// or game-executed external tools), then produces an emotion, a spoken
/// line, suggested player replies and whether the conversation ends.
///
/// ```swift
/// let gorm = try NPC(
///     persona: Persona(name: "Gorm", role: "the village blacksmith",
///                      personality: "Gruff but fair."),
///     tools: [inventoryTool],
///     world: world,
///     options: NPCOptions(groundingTool: "check_inventory"))
/// let turn = try await gorm.talk("Got any iron swords?")
/// print(turn.emotion, turn.line, turn.playerOptions)
/// ```
///
/// An NPC keeps its conversation history and ``NPCMemory``; older turns are
/// summarized in the background (``NPCOptions/compactAfterTurns``). Turns
/// are serialized; different NPCs can talk concurrently. Save and restore
/// with ``saveState()`` and ``init(restoring:model:tools:world:options:)``.
public final class NPC: Sendable {
    /// Name of the built-in memory tool that stores a fact.
    public static let rememberFactToolName = "remember_fact"
    /// Name of the built-in memory tool that adjusts the relationship.
    public static let changeRelationshipToolName = "change_relationship"

    /// The language model (the on-device system model by default).
    public let model: any LanguageModel
    /// The shared world state, if any.
    public let world: WorldState?

    private let agent: Agent
    private let queue = SerialQueue()
    private let memoryStore: MemoryStore

    private struct State {
        var persona: Persona
        var options: NPCOptions
        var userTools: [AgentTool]
        var toolsNeedRebuild = false
        var fallbackCount = 0
    }

    private let state: Mutex<State>

    /// Creates an NPC.
    ///
    /// - Parameters:
    ///   - persona: Who the NPC is.
    ///   - model: The language model. Defaults to the on-device system model.
    ///   - tools: Game tools (local or external), e.g. an inventory lookup.
    ///     Keep the total, including world and memory tools, to about 3–5.
    ///   - world: Shared game state. Adds `read_world_state` (and
    ///     `update_world_state` if ``NPCOptions/worldWritable`` is set).
    ///   - options: Grounding, reply shape, memory, compaction and fallbacks.
    ///   - memory: Initial memory.
    ///   - history: A prior conversation (from ``saveState()``).
    /// - Throws: ``AgentError`` with `.invalidRequest` for an empty name,
    ///   duplicate tool names or an unknown ``NPCOptions/groundingTool``.
    public init(
        persona: Persona,
        model: any LanguageModel = SystemLanguageModel.default,
        tools: [AgentTool] = [],
        world: WorldState? = nil,
        options: NPCOptions = NPCOptions(),
        memory: NPCMemory = NPCMemory(),
        history: Transcript? = nil
    ) throws(AgentError) {
        guard persona.name.trimmedOrNil != nil else {
            throw AgentError(.invalidRequest, "A persona needs a name.")
        }
        let store = MemoryStore(memory)
        let composed = Self.composeTools(user: tools, world: world, options: options, store: store)
        try Self.validate(options, toolNames: composed.map(\.name))
        self.model = model
        self.world = world
        self.memoryStore = store
        self.agent = try Agent(
            model: model,
            instructions: Self.instructions(persona: persona, options: options, tools: composed, memory: memory),
            tools: composed,
            configuration: Self.configuration(options),
            history: history)
        self.state = Mutex(State(persona: persona, options: options, userTools: tools))
        agent.contextNote = Self.memoryNote(memory, options: options)
    }

    /// Restores an NPC saved with ``saveState()``. Tools and the world are
    /// not part of the save: pass them again.
    public convenience init(
        restoring saved: NPCSaveState,
        model: any LanguageModel = SystemLanguageModel.default,
        tools: [AgentTool] = [],
        world: WorldState? = nil,
        options: NPCOptions = NPCOptions()
    ) throws(AgentError) {
        try self.init(
            persona: saved.persona, model: model, tools: tools, world: world,
            options: options, memory: saved.memory, history: saved.transcript)
    }

    // MARK: Talking

    /// Runs one conversation turn and returns the NPC's reply.
    ///
    /// - Parameters:
    ///   - playerLine: What the player says (empty means the player says nothing).
    ///   - context: What is happening right now ("The player just paid 45
    ///     gold."). Shown to the model for this turn only.
    ///   - toolChoice: Overrides the grounding policy for this turn.
    ///   - externalTools: Runs external tool calls (see ``AgentTool/external(name:description:parameters:timeout:)``).
    /// - Returns: The reply. When guardrails block the turn and
    ///   ``NPCOptions/fallbackOnGuardrail`` is on, a fallback reply with
    ///   ``DialogueTurn/isFallback`` set.
    /// - Throws: ``AgentError`` (model unavailable, cancelled, context overflow, …).
    public func talk(
        _ playerLine: String,
        context: String? = nil,
        toolChoice: ToolChoice? = nil,
        externalTools: (@Sendable (ToolCall) async throws -> ToolOutput)? = nil
    ) async throws(AgentError) -> DialogueTurn {
        try await talkStream(playerLine, context: context, toolChoice: toolChoice).turn(externalTools: externalTools)
    }

    /// Starts a conversation turn and streams its events: the emotion, line
    /// text as it is generated (for a typewriter effect), tool activity, and
    /// finally the complete ``DialogueTurn``.
    public func talkStream(_ playerLine: String, context: String? = nil, toolChoice: ToolChoice? = nil) -> DialogueStream {
        let stream = DialogueStream()
        queue.enqueue { [self] in
            await perform(playerLine, context: context, toolChoice: toolChoice, stream: stream)
        }
        return stream
    }

    /// A short ambient line for the current situation ("Sun's up, lad —
    /// time to sharpen these blades."). Uses a separate one-off session: no
    /// history, memory or tools, and a small token limit, so it is fast
    /// (~0.7 s on device) and can run while a conversation is in progress.
    ///
    /// - Throws: ``AgentError``, including `.guardrailViolation` — barks are
    ///   flavor, so games typically skip the bark on error.
    public func bark(situation: String) async throws(AgentError) -> String {
        let (persona, options) = state.withLock { ($0.persona, $0.options) }
        var speaker = persona
        speaker.maxSentences = 1
        let instructions = speaker.instructions(extra: options.extraInstructions, usesTools: false, secrets: .hidden)
        // Framed as a silent dialogue turn, like `talk`. Measured on device,
        // directive prompts ("Say one line that Gorm says…") tripped the
        // input guardrail every time with persona instructions, while this
        // framing passed every time.
        let prompt = Self.prompt(
            playerLine: "",
            context: situation.trimmedOrNil ?? "An ordinary moment.",
            worldSummary: world?.summary(of: options.worldContextPaths))
        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let generation = GenerationOptions(samplingMode: nil, temperature: options.temperature, maximumResponseTokens: options.barkMaximumTokens)
            let response = try await session.respond(to: prompt, options: generation)
            let line = TextCleanup.singleLine(response.content, speaker: persona.name)
            guard !line.isEmpty else { throw AgentError(.generationFailed, "The model produced an empty bark.") }
            return line
        } catch {
            throw AgentError(error)
        }
    }

    // MARK: State

    /// The NPC's character sheet. Changes apply from the next turn.
    public var persona: Persona {
        get { state.withLock { $0.persona } }
        set { state.withLock { $0.persona = newValue } }
    }

    /// Current options; change them with ``setOptions(_:)``.
    public var options: NPCOptions { state.withLock { $0.options } }

    /// Replaces the options (applies from the next turn).
    /// - Throws: ``AgentError`` if ``NPCOptions/groundingTool`` names an unknown tool.
    public func setOptions(_ options: NPCOptions) throws(AgentError) {
        let tools = state.withLock { $0.userTools }
        let composed = Self.composeTools(user: tools, world: world, options: options, store: memoryStore)
        try Self.validate(options, toolNames: composed.map(\.name))
        state.withLock {
            $0.options = options
            $0.toolsNeedRebuild = true
        }
    }

    /// The game tools passed at creation (without built-in world and memory tools).
    public var tools: [AgentTool] { state.withLock { $0.userTools } }

    /// Replaces the game tools (applies from the next turn).
    public func setTools(_ tools: [AgentTool]) throws(AgentError) {
        let options = state.withLock { $0.options }
        let composed = Self.composeTools(user: tools, world: world, options: options, store: memoryStore)
        try Self.validate(options, toolNames: composed.map(\.name))
        state.withLock {
            $0.userTools = tools
            $0.toolsNeedRebuild = true
        }
    }

    /// What the NPC remembers. Setting it applies from the next turn.
    public var memory: NPCMemory {
        get { memoryStore.memory }
        set { memoryStore.memory = newValue }
    }

    /// The conversation, including instructions and tool calls.
    public var transcript: Transcript { agent.transcript }

    /// Conversation turns currently kept verbatim (older ones are summarized).
    public var turnCount: Int { Self.turnCount(agent.history) }

    /// A snapshot for saving. A turn in progress is left out. Background
    /// compaction may be finishing right after a turn; use
    /// ``settledState()`` when the save must reflect it.
    public func saveState() -> NPCSaveState {
        NPCSaveState(persona: persona, memory: memory, transcript: Self.completeTurns(of: agent.transcript))
    }

    /// Waits for queued turns and background compaction, then returns
    /// ``saveState()``. Prefer this for save files.
    public func settledState() async -> NPCSaveState {
        await queue.perform { [self] in saveState() }
    }

    /// Waits for queued turns and background work (such as compaction) to finish.
    public func waitUntilIdle() async {
        await queue.waitUntilIdle()
    }

    /// Summarizes all but the most recent turns into ``NPCMemory/summary``
    /// now (normally automatic; see ``NPCOptions/compactAfterTurns``).
    /// - Returns: The new summary, or `nil` if there was too little history.
    @discardableResult
    public func compact() async throws(AgentError) -> String? {
        let keep = options.keepRecentTurns
        return try await queue.perform { [self] in await runCompaction(keepingRecentTurns: keep) }.get()
    }

    /// Clears the conversation history (after any turn in progress).
    /// - Parameter clearingMemory: Also forget facts, relationship and summary.
    public func resetConversation(clearingMemory: Bool = false) async {
        await queue.perform { [self] in
            await agent.reset()
            if clearingMemory { memoryStore.memory = NPCMemory() }
        }
    }

    /// Loads model resources ahead of the first turn to cut its latency.
    public func prewarm() { agent.prewarm() }

    // MARK: Turn execution

    private struct TurnSetup {
        var prompt: String
        /// `nil` for plain-text replies.
        var schema: JSONSchema?
        var policy: ToolPolicy
        var persona: Persona
        var options: NPCOptions
    }

    private func perform(_ playerLine: String, context: String?, toolChoice: ToolChoice?, stream: DialogueStream) async {
        guard !stream.isCancelled else {
            stream.fail(AgentError(.cancelled, "The turn was cancelled before it started."))
            return
        }
        let setup: TurnSetup
        do {
            setup = try prepareTurn(playerLine, context: context, toolChoice: toolChoice)
        } catch {
            stream.fail(error)
            return
        }
        memoryStore.discardPending()

        var tracker = LineTracker(speaker: setup.persona.name)
        var records: [ToolRecord] = []
        var attempt = setup
        var retriedAsText = false
        while true {
            let run = attempt.schema.map { agent.run(attempt.prompt, schema: $0, policy: attempt.policy) }
                ?? agent.run(attempt.prompt, policy: attempt.policy)
            guard stream.attach(run) else {
                _ = try? await run.response()
                stream.fail(AgentError(.cancelled, "The turn was cancelled."))
                return
            }
            do {
                var response: AgentResponse?
                for try await event in run {
                    switch event {
                    case .partial(let json): tracker.consume(json, emit: stream.emit)
                    case .text(_, let text, _):
                        if let partial = Self.partialTextReply(text) { tracker.consume(partial, emit: stream.emit) }
                    case .toolCallStarted(let call): stream.emit(.toolCall(call))
                    case .toolCallRequested(let call): stream.emit(.externalToolCall(call))
                    case .toolCallCompleted(let record):
                        records.append(record)
                        stream.emit(.toolResult(record))
                    case .completed(let completed): response = completed
                    default: break
                    }
                }
                guard let response else { throw AgentError(.generationFailed, "The turn ended without a reply.") }
                let memory = memoryStore.commit(maxFacts: attempt.options.maxFacts)
                let reply = attempt.schema == nil
                    ? Self.parseTextReply(response.text, persona: attempt.persona)
                    : Self.parseReply(response.structured, persona: attempt.persona, options: attempt.options)
                var turn = DialogueTurn(
                    line: reply.line, emotion: reply.emotion, playerOptions: reply.playerOptions,
                    endsConversation: reply.endsConversation, toolCalls: records,
                    relationship: memory.relationship, isFallback: false, usage: response.usage)
                if turn.line.isEmpty {
                    turn.line = nextFallbackLine(attempt.options)
                    turn.isFallback = true
                }
                // Queue compaction before handing the turn over, so anything the
                // caller queues next (a turn, a save) runs after it.
                scheduleCompactionIfNeeded(attempt.options)
                tracker.finish(line: turn.line, emotion: turn.emotion, emit: stream.emit)
                stream.finish(turn)
                return
            } catch {
                let error = AgentError(error)
                let blocked = error.code == .guardrailViolation || error.code == .refusal
                if blocked, attempt.options.replyFormat == .automatic, attempt.schema != nil, !retriedAsText, !stream.isCancelled {
                    // Guided generation trips the guardrails far more often
                    // than plain text: retry once as text, tools off. Memory
                    // changes staged by tools that already ran stay staged and
                    // are committed if the retry succeeds.
                    retriedAsText = true
                    attempt.schema = nil
                    attempt.prompt = Self.textRetryPrompt(attempt.prompt, toolRecords: records)
                    attempt.policy = ToolPolicy(choice: .none)
                    continue
                }
                memoryStore.discardPending()
                guard attempt.options.fallbackOnGuardrail, blocked else {
                    stream.fail(error)
                    return
                }
                let turn = DialogueTurn(
                    line: nextFallbackLine(attempt.options), emotion: attempt.persona.defaultEmotion,
                    playerOptions: [], endsConversation: false, toolCalls: records,
                    relationship: memoryStore.memory.relationship, isFallback: true)
                tracker.finish(line: turn.line, emotion: turn.emotion, emit: stream.emit)
                stream.finish(turn)
                return
            }
        }
    }

    /// Brings the agent's tools, instructions and memory note up to date and
    /// builds the turn's prompt, schema and tool policy.
    private func prepareTurn(_ playerLine: String, context: String?, toolChoice: ToolChoice?) throws(AgentError) -> TurnSetup {
        let (persona, options, userTools, rebuild) = state.withLock { state in
            defer { state.toolsNeedRebuild = false }
            return (state.persona, state.options, state.userTools, state.toolsNeedRebuild)
        }
        if rebuild {
            try agent.setTools(Self.composeTools(user: userTools, world: world, options: options, store: memoryStore))
            agent.configuration = Self.configuration(options)
        }
        let tools = agent.tools
        let memory = memoryStore.memory
        let instructions = Self.instructions(persona: persona, options: options, tools: tools, memory: memory)
        if agent.instructions != instructions { agent.instructions = instructions }
        let note = Self.memoryNote(memory, options: options)
        if agent.contextNote != note { agent.contextNote = note }

        var choice = toolChoice ?? options.groundingTool.map(ToolChoice.tool) ?? options.toolChoice
        if tools.isEmpty { choice = .none }
        if case .tool(let name) = choice, !tools.contains(where: { $0.name == name }) {
            throw AgentError(.invalidRequest, "Tool '\(name)' is not available to \(persona.name).")
        }
        let worldSummary = world.map { $0.summary(of: options.worldContextPaths) }
        return TurnSetup(
            prompt: Self.prompt(playerLine: playerLine, context: context, worldSummary: worldSummary),
            schema: options.replyFormat == .text ? nil : Self.replySchema(persona: persona, options: options),
            policy: ToolPolicy(choice: choice, maxToolRounds: options.maxToolRounds, maxToolCalls: options.maxToolCalls),
            persona: persona,
            options: options)
    }

    private func nextFallbackLine(_ options: NPCOptions) -> String {
        let lines = options.fallbackLines.compactMap(\.trimmedOrNil)
        let pool = lines.isEmpty ? NPCOptions.defaultFallbackLines : lines
        let index = state.withLock { state in
            defer { state.fallbackCount += 1 }
            return state.fallbackCount
        }
        return pool[index % pool.count]
    }

    // MARK: Compaction

    private func scheduleCompactionIfNeeded(_ options: NPCOptions) {
        guard options.compactAfterTurns > 0 else { return }
        let keep = max(0, options.keepRecentTurns)
        guard turnCount >= max(options.compactAfterTurns, keep + 1) else { return }
        queue.enqueue { [self] in _ = await runCompaction(keepingRecentTurns: keep) }
    }

    private func runCompaction(keepingRecentTurns keep: Int) async -> Result<String?, AgentError> {
        let (persona, options) = state.withLock { ($0.persona, $0.options) }
        // Seed the summarizer with the previous summary only (not the whole
        // memory block), then restore the full memory note.
        agent.contextNote = memoryStore.memory.summary
        defer { agent.contextNote = Self.memoryNote(memoryStore.memory, options: options) }
        do {
            let summary = try await agent.compactHistory(
                keepingRecentTurns: keep,
                summaryInstructions: Self.summaryInstructions(for: persona),
                userLabel: "Player",
                assistantLabel: persona.name)
            if let summary = summary?.trimmedOrNil {
                memoryStore.update { $0.summary = summary }
            }
            return .success(summary)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Memory store

/// Holds an NPC's memory and the changes memory tools make during a turn.
/// Changes are staged and only committed when the turn succeeds, so a
/// blocked or cancelled turn leaves memory untouched.
final class MemoryStore: Sendable {
    private struct State {
        var memory: NPCMemory
        var pendingFacts: [String] = []
        var pendingDelta = 0
    }

    private let state: Mutex<State>

    init(_ memory: NPCMemory) { state = Mutex(State(memory: memory)) }

    var memory: NPCMemory {
        get { state.withLock { $0.memory } }
        set { state.withLock { $0.memory = newValue } }
    }

    func update(_ body: (inout NPCMemory) -> Void) {
        state.withLock { body(&$0.memory) }
    }

    /// Stages a fact. Returns false if it is already known or staged.
    func stageFact(_ fact: String) -> Bool {
        state.withLock { state in
            var probe = state.memory
            for staged in state.pendingFacts { probe.remember(staged) }
            guard probe.remember(fact) else { return false }
            state.pendingFacts.append(fact)
            return true
        }
    }

    /// Stages a relationship change and returns the resulting value.
    func stageRelationship(_ delta: Int) -> Int {
        state.withLock { state in
            state.pendingDelta += delta
            var probe = state.memory
            return probe.adjustRelationship(by: state.pendingDelta)
        }
    }

    /// Applies staged changes and returns the new memory.
    func commit(maxFacts: Int) -> NPCMemory {
        state.withLock { state in
            for fact in state.pendingFacts { state.memory.remember(fact, limit: maxFacts) }
            state.memory.adjustRelationship(by: state.pendingDelta)
            state.pendingFacts = []
            state.pendingDelta = 0
            return state.memory
        }
    }

    func discardPending() {
        state.withLock { state in
            state.pendingFacts = []
            state.pendingDelta = 0
        }
    }
}

// MARK: - Streaming line tracking

/// Turns partial structured output into emotion and line-delta events.
struct LineTracker {
    let speaker: String
    private(set) var shown = ""
    private(set) var sentEmotion: Emotion?

    init(speaker: String) { self.speaker = speaker }

    mutating func consume(_ partial: JSONValue, emit: (DialogueEvent) -> Void) {
        // The emotion is complete once the model has moved on to the line.
        if sentEmotion == nil, partial["line"] != nil,
           let raw = partial["emotion"]?.stringValue, let emotion = Emotion(matching: raw) {
            sentEmotion = emotion
            emit(.emotion(emotion))
        }
        guard let raw = partial["line"]?.stringValue,
              let visible = TextCleanup.streamingLine(raw, speaker: speaker) else { return }
        show(visible, emit: emit)
    }

    /// Emits whatever makes the displayed text equal the final line.
    mutating func finish(line: String, emotion: Emotion, emit: (DialogueEvent) -> Void) {
        if sentEmotion != emotion {
            sentEmotion = emotion
            emit(.emotion(emotion))
        }
        show(line, emit: emit)
    }

    private mutating func show(_ text: String, emit: (DialogueEvent) -> Void) {
        guard text != shown else { return }
        if text.hasPrefix(shown) {
            emit(.lineDelta(String(text.dropFirst(shown.count))))
        } else {
            emit(.lineReset(text))
        }
        shown = text
    }
}
