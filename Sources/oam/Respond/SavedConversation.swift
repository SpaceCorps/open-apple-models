import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsBridge

/// A tool output supplied for (or produced by) one call of a pending round.
struct RoundOutput: Sendable {
    /// The transcript id of the call it answers.
    var id: String
    var name: String
    var output: ToolOutput

    var json: JSONValue {
        [
            "id": .string(id),
            "name": .string(name),
            "output": BridgeCoding.json(output),
            "isError": .bool(output.isError),
        ]
    }

    init(id: String, name: String, output: ToolOutput) {
        self.id = id
        self.name = name
        self.output = output
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let name = json["name"]?.stringValue, let value = json["output"] else { return nil }
        self.id = id
        self.name = name
        if json["isError"]?.boolValue == true {
            output = .error(value.stringValue ?? value.serialized())
        } else if let text = value.stringValue {
            output = .text(text)
        } else {
            output = .json(value)
        }
    }
}

/// A turn stopped at a tool round that has external calls: the caller runs
/// them and resumes with `--tool-output`.
struct PendingRound: Sendable {
    /// External calls that need outputs, with the ids the caller must answer.
    var calls: [ToolCall]
    /// Outputs of local (command) tools that ran in the same round.
    var completed: [RoundOutput]
    /// Every call id of the round, in the order the model made the calls.
    var order: [String]
    /// Completed tool records of the whole turn so far (bridge JSON form).
    var records: [JSONValue]
    /// Tool rounds and calls the turn has used, subtracted from the budget on resume.
    var roundsUsed: Int
    var callsUsed: Int

    var json: JSONValue {
        [
            "calls": .array(calls.map(BridgeCoding.json)),
            "completed": .array(completed.map(\.json)),
            "order": .array(order.map(JSONValue.string)),
            "toolCalls": .array(records),
            "roundsUsed": .number(Double(roundsUsed)),
            "callsUsed": .number(Double(callsUsed)),
        ]
    }

    init(calls: [ToolCall], completed: [RoundOutput], order: [String], records: [JSONValue], roundsUsed: Int, callsUsed: Int) {
        self.calls = calls
        self.completed = completed
        self.order = order
        self.records = records
        self.roundsUsed = roundsUsed
        self.callsUsed = callsUsed
    }

    init(json: JSONValue) throws(CLIError) {
        guard let rawCalls = json["calls"]?.arrayValue else { throw .invalidInput("The saved pending tool round is malformed (no 'calls').") }
        var calls: [ToolCall] = []
        for raw in rawCalls {
            guard let id = raw["id"]?.stringValue, let name = raw["name"]?.stringValue else {
                throw .invalidInput("The saved pending tool round has a malformed call.")
            }
            calls.append(ToolCall(id: id, name: name, arguments: raw["arguments"] ?? [:]))
        }
        self.calls = calls
        completed = (json["completed"]?.arrayValue ?? []).compactMap(RoundOutput.init(json:))
        order = (json["order"]?.arrayValue ?? []).compactMap(\.stringValue)
        if order.isEmpty { order = calls.map(\.id) }
        records = json["toolCalls"]?.arrayValue ?? []
        roundsUsed = json["roundsUsed"]?.intValue ?? 1
        callsUsed = json["callsUsed"]?.intValue ?? calls.count
    }
}

/// The conversation file written by `--save-transcript` and read by
/// `--resume`:
///
/// ```json
/// {"transcript": <FoundationModels Transcript>, "modelName": "system",
///  "oam": {"version": 1, "tools": [...], "schema": {...}, "pending": {...}}}
/// ```
///
/// The `transcript` / `modelName` part is the same as `fm respond
/// --save-transcript`, so files from `fm` can be resumed too.
struct SavedConversation: Sendable {
    static let formatVersion = 1

    var transcript: Transcript
    var modelName: String
    /// Tool definitions (OpenAI format with resolved `x-oam` commands).
    var tools: JSONValue?
    /// The JSON Schema of a structured turn that is pending.
    var schema: JSONValue?
    /// The pending tool round, if the turn stopped for external tools.
    var pending: PendingRound?

    init(transcript: Transcript, modelName: String, tools: JSONValue?, schema: JSONValue?, pending: PendingRound?) {
        self.transcript = transcript
        self.modelName = modelName
        self.tools = tools
        self.schema = schema
        self.pending = pending
    }

    // MARK: File I/O

    static func load(_ path: String) throws(CLIError) -> SavedConversation {
        let value = try InputFiles.readJSON(path, what: "transcript")
        // oam and fm files wrap the transcript; bridge exports may be the bare
        // transcript or a session/transcript result.
        let transcript: Transcript
        if let inner = value["transcript"], inner.objectValue != nil,
           let wrapped = try? BridgeCoding.transcript(from: inner, path: path) {
            transcript = wrapped
        } else {
            do {
                transcript = try BridgeCoding.transcript(from: value, path: path)
            } catch {
                throw .invalidInput("\(path) is not a saved conversation: \(error.message)")
            }
        }
        let metadata = value["oam"]
        return SavedConversation(
            transcript: transcript,
            modelName: value["modelName"]?.stringValue ?? "system",
            tools: metadata?["tools"].flatMap { $0.isNull ? nil : $0 },
            schema: metadata?["schema"].flatMap { $0.isNull ? nil : $0 },
            pending: try metadata?["pending"].flatMap { value throws(CLIError) in
                value.isNull ? nil : try PendingRound(json: value)
            })
    }

    func save(to path: String) throws(CLIError) {
        var metadata: JSONObject = ["version": .number(Double(Self.formatVersion))]
        if let tools { metadata["tools"] = tools }
        if let schema { metadata["schema"] = schema }
        if let pending { metadata["pending"] = pending.json }
        let encoded: JSONValue
        do {
            encoded = try BridgeCoding.json(transcript)
        } catch {
            throw .io("Could not encode the transcript: \(error.message)")
        }
        let file: JSONValue = [
            "transcript": encoded,
            "modelName": .string(modelName),
            "oam": .object(metadata),
        ]
        try InputFiles.write(Data(file.serialized().utf8), to: path, what: "transcript")
    }

    /// A fresh path in the temporary directory for a pending conversation.
    static func temporaryPath() -> String {
        let name = "oam-" + UUID().uuidString.prefix(8).lowercased() + ".json"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name).path
    }

    // MARK: Resuming

    /// The instructions saved in the transcript's instructions entry.
    var savedInstructions: String? { BridgeCoding.savedSetup(of: transcript)?.instructions }

    /// The transcript with outputs for every call of the pending round
    /// appended (in call order), ready to continue with an empty prompt.
    func answering(_ outputs: [RoundOutput]) throws(CLIError) -> Transcript {
        guard let pending else { return transcript }
        var byID: [String: RoundOutput] = [:]
        for output in pending.completed + outputs { byID[output.id] = output }
        var entries = Array(transcript)
        for id in pending.order {
            guard let output = byID[id] else { throw .usage("Missing output for tool call '\(id)'.") }
            // The output id must equal the call id: on-device inference pairs them by id.
            entries.append(.toolOutput(Transcript.ToolOutput(
                id: id, toolName: output.name,
                segments: [.text(Transcript.TextSegment(content: output.output.modelText))])))
        }
        return Transcript(entries: entries)
    }
}
