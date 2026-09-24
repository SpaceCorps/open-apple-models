import Foundation
import FoundationModels
import Synchronization

/// Settings for an ``Agent``.
public struct AgentConfiguration: Sendable {
    /// Default tool policy for each turn (overridable per turn).
    public var toolPolicy: ToolPolicy
    /// How history is fitted into the context window.
    public var context: ContextPolicy
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var sampling: GenerationOptions.SamplingMode?
    /// Time limit for local tools without their own timeout.
    public var toolTimeout: Duration?

    public init(
        toolPolicy: ToolPolicy = .default,
        context: ContextPolicy = .default,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        sampling: GenerationOptions.SamplingMode? = nil,
        toolTimeout: Duration? = .seconds(60)
    ) {
        self.toolPolicy = toolPolicy
        self.context = context
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.sampling = sampling
        self.toolTimeout = toolTimeout
    }

    var generationOptions: GenerationOptions {
        GenerationOptions(samplingMode: sampling, temperature: temperature, maximumResponseTokens: maximumResponseTokens)
    }
}

/// A conversational agent over a FoundationModels language model with
/// runtime-defined tools, a controlled tool-calling loop, streaming events
/// and external (host-executed) tools.
///
/// ```swift
/// let agent = try Agent(
///     instructions: "You are Gorm, a grumpy blacksmith.",
///     tools: [inventoryTool])
/// let reply = try await agent.respond(to: "Got any iron swords?",
///                                     policy: ToolPolicy(choice: .required))
/// ```
///
/// Turns are serialized: starting a turn while another runs queues it.
/// Works with any `LanguageModel`: the on-device `SystemLanguageModel`
/// (default), `PrivateCloudComputeLanguageModel`, or third-party providers.
public final class Agent: Sendable {
    public let model: any LanguageModel

    private let controller = StepController()
    private let runtime = ToolRuntime()
    private let queue = TurnQueue()

    private struct State {
        var session: LanguageModelSession
        var instructions: String?
        var tools: [AgentTool]
        var configuration: AgentConfiguration
        var note: String?
        var usage = TokenUsage()
        var needsRebuild = false

        var effectiveInstructions: String? { Agent.compose(instructions, note) }
    }

    private let state: Mutex<State>

    /// Creates an agent.
    /// - Parameters:
    ///   - model: The language model. Defaults to the on-device system model.
    ///   - instructions: System instructions.
    ///   - tools: Tools available to the model.
    ///   - configuration: Loop, context and sampling settings.
    ///   - history: Prior conversation to resume (e.g. a decoded ``transcript``).
    ///     Any instructions entry in it is replaced by `instructions` and `tools`.
    public init(
        model: any LanguageModel = SystemLanguageModel.default,
        instructions: String? = nil,
        tools: [AgentTool] = [],
        configuration: AgentConfiguration = AgentConfiguration(),
        history: Transcript? = nil
    ) throws(AgentError) {
        try Self.validate(tools)
        self.model = model
        let session = Self.makeSession(
            model: model, controller: controller, runtime: runtime,
            instructions: instructions, tools: tools,
            history: history.map(Self.historyEntries) ?? [])
        state = Mutex(State(session: session, instructions: instructions, tools: tools, configuration: configuration))
    }

    // MARK: Turns

    /// Starts a turn and returns its event stream.
    public func run(_ prompt: String, policy: ToolPolicy? = nil) -> AgentRun {
        start(Prompt(prompt), format: .text, policy: policy)
    }

    /// Starts a turn with a rich prompt (e.g. text plus image attachments).
    public func run(_ prompt: Prompt, policy: ToolPolicy? = nil) -> AgentRun {
        start(prompt, format: .text, policy: policy)
    }

    /// Starts a turn whose final output must match `schema`. Tools may be
    /// called first; the answer is then generated under the schema.
    public func run(_ prompt: String, schema: JSONSchema, policy: ToolPolicy? = nil) -> AgentRun {
        do {
            let converted = try SchemaConverter.convert(schema, rootName: "Response")
            return start(Prompt(prompt), format: .schema(converted.schema), policy: policy)
        } catch {
            return failed(AgentError(error))
        }
    }

    /// Starts a structured turn with a FoundationModels `GenerationSchema`.
    public func run(_ prompt: Prompt, schema: GenerationSchema, policy: ToolPolicy? = nil) -> AgentRun {
        start(prompt, format: .schema(schema), policy: policy)
    }

    /// Runs a turn to completion.
    /// - Parameter externalTools: Executes external tools; see ``AgentRun/response(externalTools:)``.
    @discardableResult
    public func respond(
        to prompt: String,
        policy: ToolPolicy? = nil,
        externalTools: (@Sendable (ToolCall) async throws -> ToolOutput)? = nil
    ) async throws(AgentError) -> AgentResponse {
        try await run(prompt, policy: policy).response(externalTools: externalTools)
    }

    /// Runs a structured turn to completion; the result is in ``AgentResponse/structured``.
    public func respond(
        to prompt: String,
        schema: JSONSchema,
        policy: ToolPolicy? = nil,
        externalTools: (@Sendable (ToolCall) async throws -> ToolOutput)? = nil
    ) async throws(AgentError) -> AgentResponse {
        try await run(prompt, schema: schema, policy: policy).response(externalTools: externalTools)
    }

    /// Runs a turn that generates a `Generable` Swift type.
    public func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        policy: ToolPolicy? = nil,
        externalTools: (@Sendable (ToolCall) async throws -> ToolOutput)? = nil
    ) async throws(AgentError) -> (content: Content, response: AgentResponse) {
        let response = try await run(Prompt(prompt), schema: Content.generationSchema, policy: policy)
            .response(externalTools: externalTools)
        do {
            let content = try Content((response.structured ?? .null).generatedContent)
            return (content, response)
        } catch {
            throw AgentError(.generationFailed, "Could not decode \(Content.self): \(error)")
        }
    }

    // MARK: State

    /// The full conversation, including instructions and tool calls.
    /// `Transcript` is `Codable`: encode it to save a conversation and pass it
    /// back as `history` to resume.
    public var transcript: Transcript { state.withLock { $0.session.transcript } }

    /// Conversation entries after the instructions.
    public var history: [Transcript.Entry] { Self.historyEntries(transcript) }

    public var instructions: String? {
        get { state.withLock { $0.instructions } }
        set { state.withLock { $0.instructions = newValue; $0.needsRebuild = true } }
    }

    /// The agent's tools. Changes apply from the next turn. Apple recommends
    /// keeping to about three to five tools per request for the on-device model;
    /// use ``ToolPolicy/enabledTools`` to narrow per turn.
    public var tools: [AgentTool] {
        get { state.withLock { $0.tools } }
    }

    /// Replaces the tool set (applies from the next turn).
    public func setTools(_ tools: [AgentTool]) throws(AgentError) {
        try Self.validate(tools)
        state.withLock { $0.tools = tools; $0.needsRebuild = true }
    }

    public var configuration: AgentConfiguration {
        get { state.withLock { $0.configuration } }
        set { state.withLock { $0.configuration = newValue } }
    }

    /// Tokens used by all turns so far.
    public var totalUsage: TokenUsage { state.withLock { $0.usage } }

    public var isResponding: Bool { state.withLock { $0.session.isResponding } }

    /// Replaces the conversation history (e.g. after summarizing). Applies
    /// after any in-flight turn.
    public func replaceHistory(_ entries: [Transcript.Entry]) async {
        await queue.enqueue { [self] in
            state.withLock { state in
                state.session = Self.makeSession(
                    model: model, controller: controller, runtime: runtime,
                    instructions: state.effectiveInstructions, tools: state.tools,
                    history: entries.filter { if case .instructions = $0 { false } else { true } })
                state.needsRebuild = false
            }
        }.value
    }

    /// Clears the conversation and ``contextNote``, keeping instructions and tools.
    public func reset() async {
        state.withLock { $0.note = nil }
        await replaceHistory([])
    }

    /// Extra context appended to the instructions, such as a summary of
    /// earlier conversation written by ``compactHistory(keepingRecentTurns:summaryInstructions:userLabel:assistantLabel:)``
    /// or facts a game wants the model to keep in mind. Applies from the next turn.
    public var contextNote: String? {
        get { state.withLock { $0.note } }
        set { state.withLock { $0.note = newValue; $0.needsRebuild = true } }
    }

    /// Summarizes all but the most recent turns into ``contextNote`` and drops
    /// them from the history, so long conversations fit the context window
    /// while keeping their gist. Runs after any in-flight turn.
    ///
    /// - Returns: The new summary, or `nil` if there was nothing to compact.
    @discardableResult
    public func compactHistory(
        keepingRecentTurns: Int = 2,
        summaryInstructions: String? = nil,
        userLabel: String = "User",
        assistantLabel: String = "Assistant"
    ) async throws(AgentError) -> String? {
        let result: Result<String?, AgentError> = await withCheckedContinuation { continuation in
            queue.enqueue { [self] in
                let (entries, previous) = state.withLock { (Self.historyEntries($0.session.transcript), $0.note) }
                let starts = entries.indices.filter { if case .prompt = entries[$0] { true } else { false } }
                guard starts.count > keepingRecentTurns else {
                    continuation.resume(returning: .success(nil))
                    return
                }
                let cut = keepingRecentTurns <= 0 ? entries.endIndex : starts[starts.count - keepingRecentTurns]
                let older = Self.render(Array(entries[..<cut]), userLabel: userLabel, assistantLabel: assistantLabel)
                var prompt = ""
                if let previous { prompt += "Summary so far:\n\(previous)\n\n" }
                prompt += "Conversation to fold into the summary:\n\(older)"
                do {
                    let summarizer = LanguageModelSession(model: model, instructions: summaryInstructions ?? Self.summaryInstructions)
                    let summary = try await summarizer.respond(to: prompt).content
                    state.withLock { state in
                        state.note = summary
                        state.session = Self.makeSession(
                            model: model, controller: controller, runtime: runtime,
                            instructions: state.effectiveInstructions, tools: state.tools,
                            history: Array(entries[cut...]))
                        state.needsRebuild = false
                    }
                    continuation.resume(returning: .success(summary))
                } catch {
                    continuation.resume(returning: .failure(AgentError(error)))
                }
            }
        }
        return try result.get()
    }

    static let summaryInstructions = """
        You maintain a running summary of a conversation for a character who must remember it. \
        Merge the new conversation into the existing summary. Keep names, promises, facts learned, \
        items exchanged, decisions and the relationship's tone. Write at most 120 words in plain prose.
        """

    /// Renders entries as plain text (for summaries and logs).
    public static func render(_ entries: [Transcript.Entry], userLabel: String = "User", assistantLabel: String = "Assistant") -> String {
        entries.compactMap { entry -> String? in
            switch entry {
            case .prompt(let prompt): "\(userLabel): \(text(of: prompt.segments))"
            case .response(let response): "\(assistantLabel): \(text(of: response.segments))"
            case .toolCalls(let calls): calls.map { "[\(assistantLabel) used \($0.toolName) \($0.arguments.jsonString)]" }.joined(separator: "\n")
            case .toolOutput(let output): "[\(output.toolName) result: \(text(of: output.segments))]"
            default: nil
            }
        }.joined(separator: "\n")
    }

    static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: nil
            }
        }.joined()
    }

    static func compose(_ instructions: String?, _ note: String?) -> String? {
        switch (instructions, note) {
        case (nil, nil): nil
        case (let instructions?, nil): instructions
        case (nil, let note?): note
        case (let instructions?, let note?): instructions + "\n\n" + note
        }
    }

    /// Loads model resources ahead of the first turn to cut latency.
    public func prewarm(promptPrefix: String? = nil) {
        let session = state.withLock { $0.session }
        session.prewarm(promptPrefix: promptPrefix.map { Prompt($0) })
    }

    // MARK: Internals

    enum OutputFormat {
        case text
        case schema(GenerationSchema)
    }

    private func start(_ prompt: Prompt, format: OutputFormat, policy: ToolPolicy?) -> AgentRun {
        let configuration = state.withLock { $0.configuration }
        let run = AgentRun(policy: policy ?? configuration.toolPolicy, defaultToolTimeout: configuration.toolTimeout)
        let task = queue.enqueue { [self] in
            await perform(prompt: prompt, format: format, run: run)
        }
        run.attach(task)
        return run
    }

    private func failed(_ error: AgentError) -> AgentRun {
        let run = AgentRun(policy: .default, defaultToolTimeout: nil)
        run.context.finish(with: .failure(error))
        return run
    }

    private func perform(prompt: Prompt, format: OutputFormat, run: AgentRun) async {
        let turn = run.context
        guard !Task.isCancelled else {
            turn.finish(with: .failure(AgentError(.cancelled, "The turn was cancelled before it started.")))
            return
        }
        let (session, configuration) = state.withLock { state in
            if state.needsRebuild {
                state.session = Self.makeSession(
                    model: model, controller: controller, runtime: runtime,
                    instructions: state.effectiveInstructions, tools: state.tools,
                    history: Self.historyEntries(state.session.transcript))
                state.needsRebuild = false
            }
            return (state.session, state.configuration)
        }

        let entriesBefore = session.transcript.count
        runtime.begin(turn)
        controller.beginTurn(policy: turn.policy, context: configuration.context) { step in
            turn.emit(.modelStep(step))
        }
        defer {
            runtime.end()
            controller.endTurn()
        }

        do {
            let response: AgentResponse
            switch format {
            case .text:
                response = try await streamText(session: session, prompt: prompt, options: configuration.generationOptions, turn: turn)
            case .schema(let schema):
                response = try await streamStructured(session: session, prompt: prompt, schema: schema, options: configuration.generationOptions, turn: turn)
            }
            state.withLock { state in
                state.usage.inputTokens += response.usage.inputTokens
                state.usage.cachedInputTokens += response.usage.cachedInputTokens
                state.usage.outputTokens += response.usage.outputTokens
            }
            turn.finish(with: .success(response))
        } catch {
            await Self.rollBack(session, to: entriesBefore)
            turn.finish(with: .failure(AgentError(error)))
        }
    }

    /// Removes entries a failed or cancelled turn left behind, so the history
    /// only ever contains complete turns.
    private static func rollBack(_ session: LanguageModelSession, to count: Int) async {
        // The framework may still be unwinding; wait (without inheriting the
        // turn's cancellation) until the session is idle.
        await Task {
            for _ in 0..<100 where session.isResponding {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }.value
        guard !session.isResponding, session.transcript.count > count else { return }
        session.transcript = Transcript(entries: session.transcript.prefix(count))
    }

    private func streamText(session: LanguageModelSession, prompt: Prompt, options: GenerationOptions, turn: TurnContext) async throws -> AgentResponse {
        var text = ""
        var usage = TokenUsage()
        let stream = session.streamResponse(to: prompt, options: options)
        for try await snapshot in stream {
            let current = snapshot.content
            if current.hasPrefix(text) {
                let delta = String(current.dropFirst(text.count))
                if !delta.isEmpty { turn.emit(.text(delta: delta, text: current, isReset: false)) }
            } else {
                turn.emit(.text(delta: current, text: current, isReset: true))
            }
            text = current
            usage = TokenUsage(snapshot.usage)
        }
        // A cancelled stream ends quietly instead of throwing.
        try Task.checkCancellation()
        return AgentResponse(text: text, toolCalls: turn.records, usage: usage, steps: turn.steps)
    }

    private func streamStructured(session: LanguageModelSession, prompt: Prompt, schema: GenerationSchema, options: GenerationOptions, turn: TurnContext) async throws -> AgentResponse {
        var last: GeneratedContent?
        var usage = TokenUsage()
        let stream = session.streamResponse(to: prompt, schema: schema, options: options)
        for try await snapshot in stream {
            last = snapshot.rawContent
            usage = TokenUsage(snapshot.usage)
            turn.emit(.partial(JSONValue(snapshot.rawContent)))
        }
        try Task.checkCancellation()
        guard let last else { throw AgentError(.generationFailed, "The model produced no output.") }
        let json = JSONValue(last).ordered(by: schema)
        return AgentResponse(text: json.serialized(), structured: json, toolCalls: turn.records, usage: usage, steps: turn.steps)
    }

    static func historyEntries(_ transcript: Transcript) -> [Transcript.Entry] {
        transcript.filter { if case .instructions = $0 { false } else { true } }
    }

    private static func validate(_ tools: [AgentTool]) throws(AgentError) {
        var seen: Set<String> = []
        for tool in tools {
            guard !tool.name.isEmpty else { throw AgentError(.invalidRequest, "Tool names must not be empty.") }
            guard seen.insert(tool.name).inserted else { throw AgentError(.invalidRequest, "Duplicate tool name '\(tool.name)'.") }
        }
    }

    private static func makeSession(
        model: any LanguageModel,
        controller: StepController,
        runtime: ToolRuntime,
        instructions: String?,
        tools: [AgentTool],
        history: [Transcript.Entry]
    ) -> LanguageModelSession {
        func make<Base: LanguageModel>(_ base: Base) -> LanguageModelSession {
            let steered = SteeredLanguageModel(base: base, controller: controller)
            let adapters: [any Tool] = tools.map { ToolAdapter(tool: $0, runtime: runtime) }
            if history.isEmpty {
                return LanguageModelSession(model: steered, tools: adapters, instructions: instructions)
            }
            let header = Transcript.Entry.instructions(Transcript.Instructions(
                segments: instructions.map { [.text(Transcript.TextSegment(content: $0))] } ?? [],
                toolDefinitions: tools.map { ToolAdapter(tool: $0, runtime: runtime) }.map { Transcript.ToolDefinition(tool: $0) }))
            return LanguageModelSession(model: steered, tools: adapters, transcript: Transcript(entries: [header] + history))
        }
        return make(model)
    }
}

/// Serializes turns so a session never receives concurrent requests.
final class TurnQueue: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    @discardableResult
    func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        tail.withLock { tail in
            let previous = tail
            let task = Task {
                await previous?.value
                await work()
            }
            tail = task
            return task
        }
    }
}
