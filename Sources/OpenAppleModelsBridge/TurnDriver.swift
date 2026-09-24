import Foundation
import OpenAppleModels
import Synchronization

extension BridgeRequest {
    /// Runs an agent turn on behalf of this request and returns its response.
    ///
    /// - Client tools: each ``AgentEvent/toolCallRequested(_:)`` becomes a
    ///   `tool/call` request to the peer (`params` = `context` + `requestId` +
    ///   `call`); the peer's response is submitted to the run. If the call
    ///   times out or the turn ends first, a `tool/cancel` notification tells
    ///   the peer to stop (its late response is ignored).
    /// - Streaming: when `stream` is true, every event is sent as an
    ///   `eventMethod` notification (`params` = `context` + `requestId` + `event`).
    /// - Cancellation: cancelling the calling task cancels the run.
    ///
    /// All notifications and `tool/call` requests are queued before this
    /// returns, so they reach the peer before the request's response.
    ///
    /// - Parameters:
    ///   - context: Fields identifying the conversation, e.g. `["session": "s1"]` or `["npc": "gorm"]`.
    public func drive(
        _ run: AgentRun,
        stream: Bool,
        context: JSONObject,
        eventMethod: String = "session/event"
    ) async throws(BridgeError) -> AgentResponse {
        try await TurnDriver(engine: engine, requestID: id?.value ?? .null, context: context, stream: stream, eventMethod: eventMethod)
            .drive(run)
    }
}

/// Bridges one ``AgentRun`` to the peer.
final class TurnDriver: Sendable {
    let engine: BridgeEngine
    let requestID: JSONValue
    let context: JSONObject
    let stream: Bool
    let eventMethod: String

    /// Client tool calls awaiting the peer, by tool-call id.
    private let pending = Mutex<[String: ClientRequest]>([:])

    init(engine: BridgeEngine, requestID: JSONValue, context: JSONObject, stream: Bool, eventMethod: String) {
        self.engine = engine
        self.requestID = requestID
        self.context = context
        self.stream = stream
        self.eventMethod = eventMethod
    }

    private func params(_ extra: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var object = context
        object["requestId"] = requestID
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    func drive(_ run: AgentRun) async throws(BridgeError) -> AgentResponse {
        let outcome: Result<AgentResponse, BridgeError> = await withTaskCancellationHandler {
            do {
                for try await event in run {
                    if stream, let json = BridgeCoding.json(event) {
                        engine.notify(eventMethod, params(["event": json]))
                    }
                    switch event {
                    case .toolCallRequested(let call):
                        forward(call, to: run)
                    case .toolCallCompleted(let record):
                        // Still waiting on the peer means the call timed out.
                        if let request = pending.withLock({ $0.removeValue(forKey: record.call.id) }) {
                            cancel(request, callID: record.call.id, reason: record.output.modelText)
                        }
                    case .completed(let response):
                        return .success(response)
                    default:
                        break
                    }
                }
                // Iteration ends quietly (without throwing) when this task is cancelled.
                if Task.isCancelled { return .failure(.cancelled("The turn was cancelled.")) }
                return .failure(.internalError("The turn ended without a response."))
            } catch {
                return .failure(BridgeError(normalizing: error))
            }
        } onCancel: {
            run.cancel()
        }
        let leftover = pending.withLock { pending in
            defer { pending.removeAll() }
            return pending.sorted { $0.key < $1.key }
        }
        for (callID, request) in leftover {
            cancel(request, callID: callID, reason: "The turn ended before the tool finished.")
        }
        return try outcome.get()
    }

    private func forward(_ call: ToolCall, to run: AgentRun) {
        let request = engine.sendRequest("tool/call", params: params(["call": BridgeCoding.json(call)]))
        pending.withLock { $0[call.id] = request }
        Task { [self] in
            let result = await request.result()
            // Remove before submitting: the run records the output (and emits
            // toolCallCompleted) as soon as it is submitted.
            guard pending.withLock({ $0.removeValue(forKey: call.id) }) != nil else { return }
            run.submit(BridgeCoding.toolOutput(from: result), for: call.id)
        }
    }

    private func cancel(_ request: ClientRequest, callID: String, reason: String) {
        guard !request.isFinished else { return }
        request.cancel()
        engine.notify("tool/cancel", params(["id": .string(request.id), "callId": .string(callID), "reason": .string(reason)]))
    }
}
