import Foundation
import OpenAppleModels
import OpenAppleModelsGame
import Synchronization

// MARK: - Error codes

extension BridgeError.Code {
    /// No NPC has the given id (`npc_not_found`).
    public static let npcNotFound = -32050
    /// An NPC with the requested id already exists (`npc_exists`).
    public static let npcExists = -32051
    /// No world has the given id (`world_not_found`).
    public static let worldNotFound = -32052
    /// A world with the requested id already exists (`world_exists`).
    public static let worldExists = -32053
    /// A world path or value was rejected, e.g. writing through a number or
    /// replacing the root with a non-object (`world_error`, with `data.path`).
    public static let worldError = -32054
    /// Too many NPCs, worlds or subscriptions (`limit_reached`, with `data.limit`).
    public static let limitReached = -32055
    /// No world subscription has the given id (`subscription_not_found`).
    public static let subscriptionNotFound = -32056
}

extension BridgeError {
    public static func npcNotFound(_ id: String) -> BridgeError {
        BridgeError(code: Code.npcNotFound, name: "npc_not_found", message: "No NPC with id '\(id)'.",
                    extra: ["npc": .string(id)])
    }

    public static func npcExists(_ id: String) -> BridgeError {
        BridgeError(code: Code.npcExists, name: "npc_exists", message: "An NPC with id '\(id)' already exists.",
                    extra: ["npc": .string(id)])
    }

    public static func worldNotFound(_ id: String) -> BridgeError {
        BridgeError(code: Code.worldNotFound, name: "world_not_found", message: "No world with id '\(id)'.",
                    extra: ["world": .string(id)])
    }

    public static func worldExists(_ id: String) -> BridgeError {
        BridgeError(code: Code.worldExists, name: "world_exists", message: "A world with id '\(id)' already exists.",
                    extra: ["world": .string(id)])
    }

    /// Wraps a ``WorldStateError`` raised by an operation on world `world`.
    public static func worldError(_ error: WorldStateError, world: String) -> BridgeError {
        BridgeError(code: Code.worldError, name: "world_error", message: error.message,
                    extra: ["world": .string(world), "path": .string(error.path)])
    }

    /// `kind` is a plural noun such as `"NPCs"`.
    public static func limitReached(_ kind: String, limit: Int) -> BridgeError {
        BridgeError(code: Code.limitReached, name: "limit_reached",
                    message: "The limit of \(limit) \(kind) is reached; delete some first.",
                    extra: ["limit": .number(Double(limit))])
    }

    public static func subscriptionNotFound(_ id: String) -> BridgeError {
        BridgeError(code: Code.subscriptionNotFound, name: "subscription_not_found",
                    message: "No world subscription with id '\(id)'.", extra: ["subscription": .string(id)])
    }
}

// MARK: - Ordered work

/// Runs operations one after another in the order they were scheduled.
/// Each NPC has one, so pipelined `npc/talk`, `npc/update` and `npc/state`
/// requests apply in arrival order.
final class WorkQueue: Sendable {
    private struct State {
        var tail: Task<Void, Never>?
        var work: [Int: Task<Void, Never>] = [:]
        var nextToken = 0
    }

    private let state = Mutex(State())

    /// Queues `work` behind earlier work and returns a reply that completes
    /// with its result. Call from the (ordered) method handler.
    func schedule(_ work: @escaping @Sendable () async throws -> JSONValue) -> BridgeReply {
        let outcome = OneShot<Result<JSONValue, BridgeError>>()
        let token = state.withLock { state -> Int in
            let token = state.nextToken
            state.nextToken += 1
            let previous = state.tail
            let task = Task { [self] in
                await previous?.value
                let result: Result<JSONValue, BridgeError>
                if Task.isCancelled {
                    result = .failure(.cancelled("The request was cancelled before it started."))
                } else {
                    do {
                        result = .success(try await work())
                    } catch {
                        result = .failure(BridgeError(normalizing: error))
                    }
                }
                _ = self.state.withLock { $0.work.removeValue(forKey: token) }
                outcome.resolve(result)
            }
            state.tail = task
            state.work[token] = task
            return token
        }
        return .deferred { [self] in
            let result = await withTaskCancellationHandler {
                await outcome.value()
            } onCancel: {
                self.cancel(token: token)
            }
            return try result.get()
        }
    }

    /// Cancels running and queued work; returns how many operations were cancelled.
    @discardableResult
    func cancelAll() -> Int {
        let tasks = state.withLock { Array($0.work.values) }
        for task in tasks { task.cancel() }
        return tasks.count
    }

    /// Operations running or waiting.
    var pendingOperations: Int { state.withLock { $0.work.count } }

    private func cancel(token: Int) {
        state.withLock { $0.work[token] }?.cancel()
    }
}

// MARK: - JSON helpers

enum GameJSON {
    /// Decodes `value`, turning `DecodingError`s into `invalid_params`
    /// messages that name the offending parameter (`persona.goals[1]`).
    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue, path: String) throws(BridgeError) -> T {
        do {
            return try value.decode(type)
        } catch let error as DecodingError {
            throw .invalidParams(describe(error, path: path))
        } catch {
            throw .invalidParams("'\(path)' is invalid: \(error)")
        }
    }

    static func describe(_ error: DecodingError, path: String) -> String {
        func location(_ codingPath: [any CodingKey], _ last: (any CodingKey)? = nil) -> String {
            var text = path
            for key in codingPath + (last.map { [$0] } ?? []) {
                if let index = key.intValue {
                    text += "[\(index)]"
                } else {
                    text += text.isEmpty ? key.stringValue : "." + key.stringValue
                }
            }
            return text
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing required parameter '\(location(context.codingPath, key))'."
        case .typeMismatch(let type, let context), .valueNotFound(let type, let context):
            return "Parameter '\(location(context.codingPath))' must be \(kind(of: type))."
        case .dataCorrupted(let context):
            return "Parameter '\(location(context.codingPath))' is invalid: \(context.debugDescription)"
        @unknown default:
            return "'\(path)' is invalid: \(error)"
        }
    }

    private static func kind(of type: Any.Type) -> String {
        let name = String(describing: type)
        if name.hasPrefix("Array") { return "an array" }
        if name.hasPrefix("Dictionary") { return "an object" }
        switch name {
        case "String": return "a string"
        case "Int", "Int64", "Int32", "UInt64": return "an integer"
        case "Double", "Float": return "a number"
        case "Bool": return "a boolean"
        default: return "an object"
        }
    }

    /// Applies an RFC 7386 JSON Merge Patch: objects merge recursively,
    /// `null` members delete keys, anything else replaces.
    static func merged(_ patch: JSONValue, into target: JSONValue) -> JSONValue {
        guard case .object(let patchObject) = patch else { return patch }
        var result = target.objectValue ?? JSONObject()
        for (key, value) in patchObject {
            if value.isNull {
                result[key] = nil
            } else {
                result[key] = merged(value, into: result[key] ?? .null)
            }
        }
        return .object(result)
    }

    /// Text for a free-form `context`/`situation` parameter: strings as-is,
    /// other JSON (such as an object of facts) as compact JSON.
    static func text(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        return value.stringValue ?? value.serialized()
    }

    /// Validates a client-chosen id for NPCs and worlds (same rules as session ids).
    static func validateID(_ id: String, parameter: String) throws(BridgeError) {
        guard SessionMethods.isValidSessionID(id) else {
            throw .invalidParams("'\(parameter)' must be 1-128 printable characters; got '\(id)'.")
        }
    }

    /// Seconds → duration; 0 means no limit.
    static func timeout(seconds: Double) -> Duration? {
        seconds == 0 ? nil : .milliseconds(Int((seconds * 1000).rounded()))
    }

    static func seconds(_ duration: Duration?) -> Double {
        guard let duration else { return 0 }
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
