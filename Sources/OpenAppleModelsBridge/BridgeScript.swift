import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsTesting

/// Parses the JSON form of a scripted model, which lets engine developers
/// and CI exercise the full protocol (streaming, client tools, structured
/// output, errors) without Apple Intelligence.
///
/// ```json
/// {"type": "scripted",
///  "steps": [
///    {"toolCalls": [{"name": "open_gate", "arguments": {"gate": "north"}}]},
///    {"template": "The gate says: {toolOutput}"}
///  ],
///  "fallback": {"text": "..."}}
/// ```
///
/// Each model inference plays the next step. Step forms:
/// - `{"text": "...", "chunks"?: n}` — answer text, streamed in about `n` pieces (default 3).
/// - `{"toolCalls": [{"name", "arguments"?, "id"?}]}` — call tools (one round).
/// - `{"json": <value>}` — structured output for schema turns.
/// - `{"template": "..."}` — text with `{prompt}`, `{toolOutput}` (latest
///   tool output of this turn) and `{toolOutputs}` (all of this turn's, one per line).
/// - `{"error": "<code>", "message"?}` — fail with an agent error code such
///   as `guardrail_violation`, `refusal`, `context_size_exceeded`, `rate_limited`.
/// - Any step may add `"delayMs": n` to wait first (for cancellation tests).
public enum BridgeScript {
    /// Parses `{"type": "scripted", "steps": [...], "fallback"?: step}`.
    public static func parse(_ value: JSONValue, path: String = "model") throws(BridgeError) -> ModelScript {
        guard let object = value.objectValue else { throw .invalidParams("'\(path)' must be an object.") }
        let params = BridgeParams(object, path: path + ".")
        let steps = try params.optionalArray("steps") ?? []
        var parsed: [ModelScript.Step] = []
        for (index, step) in steps.enumerated() {
            parsed.append(try self.step(step, path: "\(path).steps[\(index)]"))
        }
        // Bridge sessions are long-lived and nobody reads the request log.
        if let fallback = params["fallback"] {
            return ModelScript(parsed, fallback: try step(fallback, path: path + ".fallback"), recordsRequests: false)
        }
        return ModelScript(parsed, recordsRequests: false)
    }

    /// Parses one step.
    public static func step(_ value: JSONValue, path: String) throws(BridgeError) -> ModelScript.Step {
        guard let object = value.objectValue else { throw .invalidParams("'\(path)' must be an object.") }
        let params = BridgeParams(object, path: path + ".")
        let step: ModelScript.Step
        if let text = try params.optionalString("text") {
            step = .text(text, chunks: try params.optionalInt("chunks", minimum: 1) ?? 3)
        } else if let calls = try params.optionalArray("toolCalls") {
            var scripted: [ModelScript.ScriptedToolCall] = []
            for (index, call) in calls.enumerated() {
                guard let callObject = call.objectValue else { throw .invalidParams("'\(path).toolCalls[\(index)]' must be an object.") }
                let callParams = BridgeParams(callObject, path: "\(path).toolCalls[\(index)].")
                scripted.append(ModelScript.ScriptedToolCall(
                    id: try callParams.optionalString("id"),
                    name: try callParams.string("name"),
                    arguments: try callParams.optionalObject("arguments").map(JSONValue.object) ?? [:]))
            }
            guard !scripted.isEmpty else { throw .invalidParams("'\(path).toolCalls' must not be empty.") }
            step = .toolCalls(scripted)
        } else if let json = object["json"] {
            step = .json(json)
        } else if let template = try params.optionalString("template") {
            step = .dynamic { request in .text(render(template, request: request), chunks: 3) }
        } else if let code = try params.optionalString("error") {
            guard let agentCode = AgentError.Code(rawValue: code) else {
                let known = AgentError.Code.allCases.map(\.rawValue).joined(separator: ", ")
                throw .invalidParams("'\(path).error' must be one of: \(known); got '\(code)'.")
            }
            let message = try params.optionalString("message") ?? "Scripted \(code)."
            step = .fail(AgentError(agentCode, message))
        } else {
            throw .invalidParams("'\(path)' must contain one of 'text', 'toolCalls', 'json', 'template' or 'error'.")
        }
        if let delay = try params.optionalInt("delayMs", minimum: 0), delay > 0 {
            return .delayed(.milliseconds(delay), step)
        }
        return step
    }

    static func render(_ template: String, request: ModelScript.ModelRequest) -> String {
        let entries = Array(request.transcript)
        let turnStart = (entries.lastIndex { if case .prompt = $0 { true } else { false } } ?? -1) + 1
        let outputs = entries[turnStart...].compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry else { return nil }
            return text(of: output.segments)
        }
        return template
            .replacingOccurrences(of: "{prompt}", with: request.lastPrompt ?? "")
            .replacingOccurrences(of: "{toolOutputs}", with: outputs.joined(separator: "\n"))
            .replacingOccurrences(of: "{toolOutput}", with: outputs.last ?? "")
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
}
