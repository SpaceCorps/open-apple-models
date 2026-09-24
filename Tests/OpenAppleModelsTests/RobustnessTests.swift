import Foundation
import FoundationModels
@testable import OpenAppleModels
import OpenAppleModelsTesting
import Testing

@Suite struct RobustnessTests {
    @Test func toolTimeoutHoldsEvenIfTheHandlerIgnoresCancellation() async throws {
        let stubborn = try AgentTool(name: "stubborn", description: "Blocks.", timeout: .milliseconds(100)) { _ in
            // A detached wait does not observe the caller's cancellation.
            await Task.detached { try? await Task.sleep(for: .milliseconds(1500)) }.value
            return "late"
        }
        let script = ModelScript([.toolCalls([.init(name: "stubborn")]), .text("ok")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [stubborn])
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await agent.respond(to: "go")
        #expect(clock.now - start < .milliseconds(1200))
        #expect(response.toolCalls.first?.output.isError == true)
    }

    @Test func cancellingTheCallerOfRespondCancelsTheTurn() async throws {
        let script = ModelScript([.delayed(.seconds(5), .text("too late"))])
        let agent = try Agent(model: ScriptedLanguageModel(script))
        let task = Task { try await agent.respond(to: "wait") }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as AgentError {
            #expect(error.code == .cancelled)
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func cancellingAQueuedTurnEndsItImmediately() async throws {
        let script = ModelScript([.delayed(.seconds(2), .text("first")), .text("never")])
        let agent = try Agent(model: ScriptedLanguageModel(script))
        let first = agent.run("one")
        let second = agent.run("two")
        let clock = ContinuousClock()
        let start = clock.now
        second.cancel()
        await #expect(throws: AgentError.self) { _ = try await second.response() }
        #expect(clock.now - start < .milliseconds(500))
        #expect(try await first.response().text == "first")
        #expect(script.requests.count == 1)
    }

    @Test func trimmingWithZeroMinimumRecentTurnsDoesNotCrash() async {
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [.text(.init(content: "x"))], toolDefinitions: []))]
        for index in 0..<6 {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: String(repeating: "word ", count: 400) + "\(index)"))])))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: String(repeating: "reply ", count: 400)))])))
        }
        entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: "latest"))])))
        var transcript = Transcript(entries: entries)
        let removed = await StepController.trim(
            &transcript, contextSize: 2000,
            policy: ContextPolicy(trimsHistory: true, reservedResponseTokens: 200, minimumRecentTurns: 0),
            countTokens: nil)
        #expect(removed > 0)
        guard case .prompt(let last)? = transcript.last else { Issue.record("last entry must be the current prompt"); return }
        #expect(last.segments.description.contains("latest"))
        guard case .instructions? = transcript.first else { Issue.record("instructions must be kept"); return }
    }

    @Test func hugeIntegerBoundsDoNotTrap() throws {
        let schema = try JSONSchema(parsing: #"{"type":"object","properties":{"n":{"type":"integer","minimum":-1e300,"maximum":1e300,"exclusiveMaximum":1e40}}}"#)
        _ = try SchemaConverter.convert(schema, rootName: "Big")
    }
}

@Suite struct SchemaSafetyTests {
    @Test(arguments: [
        ##"{"$defs":{"A":{"$ref":"#/$defs/A"}},"type":"object","properties":{"a":{"$ref":"#/$defs/A"}}}"##,
        ##"{"$defs":{"A":{"$ref":"#/$defs/B"},"B":{"$ref":"#/$defs/A"}},"type":"object","properties":{"a":{"$ref":"#/$defs/A"}}}"##,
        ##"{"$defs":{"A":{"allOf":[{"$ref":"#/$defs/A"}]}},"type":"object","properties":{"a":{"$ref":"#/$defs/A"}}}"##,
    ])
    func cyclicRefsThrowInsteadOfOverflowing(_ text: String) throws {
        #expect(throws: SchemaConversionError.self) { _ = try SchemaConverter.convert(try JSONSchema(parsing: text), rootName: "X") }
    }

    @Test func deepRefChainsAreBounded() throws {
        var defs: [String] = []
        for index in 0..<300 {
            defs.append("\"N\(index)\":{\"type\":\"object\",\"properties\":{\"next\":{\"$ref\":\"#/$defs/N\(index + 1)\"}}}")
        }
        defs.append("\"N300\":{\"type\":\"string\"}")
        let text = "{\"$defs\":{" + defs.joined(separator: ",") + "},\"type\":\"object\",\"properties\":{\"root\":{\"$ref\":\"#/$defs/N0\"}}}"
        #expect(throws: SchemaConversionError.self) { _ = try SchemaConverter.convert(try JSONSchema(parsing: text), rootName: "X") }
    }

    @Test func errorsAreLocalized() {
        let error: any Error = AgentError(.guardrailViolation, "Blocked by the guardrails.")
        #expect(error.localizedDescription == "Blocked by the guardrails.")
    }

    @Test func cancellingARunningTurnWithAStubbornToolReturnsPromptly() async throws {
        let stubborn = try AgentTool(name: "stubborn", description: "Blocks.") { _ in
            await Task.detached { try? await Task.sleep(for: .milliseconds(1500)) }.value
            return "late"
        }
        var configuration = AgentConfiguration()
        configuration.toolTimeout = nil
        let script = ModelScript([.toolCalls([.init(name: "stubborn")]), .text("never"), .text("second turn")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [stubborn], configuration: configuration)
        let run = agent.run("go")
        Task { try? await Task.sleep(for: .milliseconds(150)); run.cancel() }
        await #expect(throws: AgentError.self) { _ = try await run.response() }
        // The next turn completes and is not erased when the old handler finishes.
        let second = try await agent.respond(to: "again")
        #expect(second.text.isEmpty == false)
        try await Task.sleep(for: .milliseconds(1800))
        #expect(agent.history.count == 2)
    }
}
