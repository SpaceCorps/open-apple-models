import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsTesting
import Testing

@Suite struct RetryTests {
    static let transient = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1012)
    static let fast = AgentConfiguration(retry: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1)))

    @Test func transientFailureIsRetried() async throws {
        let script = ModelScript([.fail(Self.transient), .text("recovered")])
        let agent = try Agent(model: ScriptedLanguageModel(script), configuration: Self.fast)
        let response = try await agent.respond(to: "hi")
        #expect(response.text == "recovered")
        #expect(script.requests.count == 2)
        #expect(agent.history.count == 2)
    }

    @Test func retryResetsStreamedText() async throws {
        let failing = ModelScript([.fail(Self.transient), .text("final answer")])
        let agent = try Agent(model: ScriptedLanguageModel(failing), configuration: Self.fast)
        var texts: [String] = []
        for try await event in agent.run("hi") {
            if case .text(_, let text, _) = event { texts.append(text) }
        }
        #expect(texts.last == "final answer")
    }

    @Test func noRetryAfterAToolRan() async throws {
        let counter = Counter()
        let tool = try AgentTool(name: "ring_bell", description: "Ring the bell.") { _ in
            counter.increment()
            return "rang"
        }
        let script = ModelScript([.toolCalls([.init(name: "ring_bell")]), .fail(Self.transient), .text("never")])
        let agent = try Agent(model: ScriptedLanguageModel(script), tools: [tool], configuration: Self.fast)
        await #expect(throws: AgentError.self) { _ = try await agent.respond(to: "ring") }
        #expect(counter.count == 1)
        #expect(agent.history.isEmpty)
    }

    @Test func guardrailsAreNotRetriedByDefault() async throws {
        let script = ModelScript([.fail(LanguageModelError.guardrailViolation(.init(debugDescription: "x"))), .text("never")])
        let agent = try Agent(model: ScriptedLanguageModel(script), configuration: Self.fast)
        do {
            _ = try await agent.respond(to: "x")
            Issue.record("expected a guardrail error")
        } catch {
            #expect(error.code == .guardrailViolation)
        }
        #expect(script.requests.count == 1)
    }

    @Test func guardrailRetryIsOptIn() async throws {
        let script = ModelScript([.fail(LanguageModelError.guardrailViolation(.init(debugDescription: "x"))), .text("ok")])
        var configuration = Self.fast
        configuration.retry.retriesGuardrailViolations = true
        let agent = try Agent(model: ScriptedLanguageModel(script), configuration: configuration)
        #expect(try await agent.respond(to: "x").text == "ok")
    }

    @Test func retriesCanBeDisabled() async throws {
        let script = ModelScript([.fail(Self.transient), .text("never")])
        let agent = try Agent(model: ScriptedLanguageModel(script), configuration: AgentConfiguration(retry: .none))
        await #expect(throws: AgentError.self) { _ = try await agent.respond(to: "x") }
        #expect(script.requests.count == 1)
    }
}
