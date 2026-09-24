import Foundation
import FoundationModels
import OpenAppleModels
import Synchronization

/// A deterministic `LanguageModel` that plays back a script, for testing
/// agent logic (tool loops, NPC flows, servers) without the real model.
///
/// It plugs into FoundationModels exactly like a real model, so the
/// framework's own tool loop, transcript and streaming are exercised.
///
/// ```swift
/// let script = ModelScript([
///     .toolCalls([.init(name: "check_inventory", arguments: ["item": "sword"])]),
///     .text("I have 3 swords."),
/// ])
/// let agent = try Agent(model: ScriptedLanguageModel(script), tools: [inventory])
/// let response = try await agent.respond(to: "Swords?")
/// #expect(script.requests[0].toolCallingMode == .allowed)
/// ```
public struct ScriptedLanguageModel: LanguageModel {
    public typealias Executor = ScriptedExecutor

    public let script: ModelScript
    public let capabilities: LanguageModelCapabilities

    public init(_ script: ModelScript, capabilities: [LanguageModelCapabilities.Capability] = [.toolCalling, .guidedGeneration]) {
        self.script = script
        self.capabilities = LanguageModelCapabilities(capabilities)
    }

    public var executorConfiguration: ScriptedExecutor.Configuration {
        ScriptedExecutor.Configuration(scriptID: script.id)
    }
}

/// A sequence of model steps played back one per model request.
public final class ModelScript: Sendable {
    public struct ScriptedToolCall: Sendable {
        public var id: String?
        public var name: String
        public var arguments: JSONValue

        public init(id: String? = nil, name: String, arguments: JSONValue = [:]) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    public enum Step: Sendable {
        /// Respond with text, streamed in roughly `chunks` pieces.
        case text(String, chunks: Int = 3)
        /// Emit tool calls (one model step; several calls run in parallel).
        case toolCalls([ScriptedToolCall])
        /// Respond with structured content (for schema turns).
        case json(JSONValue)
        /// Throw an error from the model.
        case fail(any Error & Sendable)
        /// Wait before running the inner step (for cancellation tests).
        indirect case delayed(Duration, Step)
        /// Decide the step from the request.
        case dynamic(@Sendable (ModelRequest) -> Step)
    }

    /// What the model was asked, recorded for assertions.
    public struct ModelRequest: Sendable {
        public var toolCallingMode: GenerationOptions.ToolCallingMode.Kind?
        public var enabledTools: [String]
        public var schemaName: String?
        public var transcript: Transcript

        /// Tool outputs present in the transcript (all turns).
        public var toolOutputs: [Transcript.ToolOutput] {
            transcript.compactMap { if case .toolOutput(let output) = $0 { output } else { nil } }
        }

        /// The text of the most recent prompt.
        public var lastPrompt: String? {
            for entry in transcript.reversed() {
                if case .prompt(let prompt) = entry {
                    return prompt.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
                }
            }
            return nil
        }
    }

    public let id = UUID()
    private let state: Mutex<(steps: [Step], requests: [ModelRequest])>
    /// Step used when the script runs out.
    public let fallback: Step

    public init(_ steps: [Step], fallback: Step = .text("(script exhausted)")) {
        state = Mutex((steps, []))
        self.fallback = fallback
    }

    /// Requests received so far, in order.
    public var requests: [ModelRequest] { state.withLock { $0.requests } }

    /// Steps not yet played.
    public var remainingSteps: Int { state.withLock { $0.steps.count } }

    /// Appends steps.
    public func append(_ steps: [Step]) { state.withLock { $0.steps.append(contentsOf: steps) } }

    func next(for request: ModelRequest) -> Step {
        state.withLock { state in
            state.requests.append(request)
            return state.steps.isEmpty ? fallback : state.steps.removeFirst()
        }
    }
}

public struct ScriptedExecutor: LanguageModelExecutor {
    public struct Configuration: Hashable, Sendable {
        public var scriptID: UUID
    }

    public typealias Model = ScriptedLanguageModel

    public init(configuration: Configuration) throws {}

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ScriptedLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let recorded = ModelScript.ModelRequest(
            toolCallingMode: request.generationOptions.toolCallingMode?.kind,
            enabledTools: request.enabledToolDefinitions.map(\.name),
            schemaName: request.schema?.name,
            transcript: request.transcript)
        try await play(model.script.next(for: recorded), request: recorded, channel: channel)
    }

    private func play(_ step: ModelScript.Step, request: ModelScript.ModelRequest, channel: LanguageModelExecutorGenerationChannel) async throws {
        switch step {
        case .text(let text, let chunks):
            for piece in Self.split(text, into: max(1, chunks)) {
                await channel.send(.response(action: .appendText(piece, tokenCount: max(1, piece.count / 4))))
            }
        case .json(let value):
            await channel.send(.response(action: .appendText(value.serialized(), tokenCount: 8)))
        case .toolCalls(let calls):
            for (offset, call) in calls.enumerated() {
                await channel.send(.toolCalls(action: .toolCall(
                    id: call.id ?? "scripted_call_\(offset)_\(UUID().uuidString.prefix(8))",
                    name: call.name,
                    action: .appendArguments(call.arguments.serialized(), tokenCount: 4))))
            }
        case .fail(let error):
            throw error
        case .delayed(let duration, let inner):
            try await Task.sleep(for: duration)
            try await play(inner, request: request, channel: channel)
        case .dynamic(let decide):
            try await play(decide(request), request: request, channel: channel)
        }
    }

    private static func split(_ text: String, into chunks: Int) -> [String] {
        guard chunks > 1, text.count > chunks else { return [text] }
        let size = Int((Double(text.count) / Double(chunks)).rounded(.up))
        var pieces: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(String(text[index..<end]))
            index = end
        }
        return pieces
    }
}
