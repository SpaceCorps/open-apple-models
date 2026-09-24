import Foundation
import OpenAppleModels
import Synchronization

/// A change to a ``WorldState``, delivered to observers.
public struct WorldStateChange: Sendable, Hashable, Codable {
    /// The canonical dot path that changed (`""` for the root).
    public var path: String
    /// The value before the change (`nil` if there was none).
    public var oldValue: JSONValue?
    /// The value after the change (`nil` if it was removed).
    public var newValue: JSONValue?

    public init(path: String, oldValue: JSONValue?, newValue: JSONValue?) {
        self.path = path
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

/// A thread-safe JSON blackboard holding the game state that AI characters
/// can see and change.
///
/// Values are addressed by dot paths (`"player.gold"`, `"npcs.gorm.mood"`,
/// `"party.0.name"`). The game writes state as it changes; NPCs read it
/// through ``tools(readable:writable:maxOutputCharacters:)`` or get it
/// injected into their prompt with ``summary(of:maxLines:)``.
///
/// ```swift
/// let world = WorldState(["player": ["name": "Aria", "gold": 12]])
/// try world.set("npcs.gorm.mood", "grumpy")
/// world.get("player.gold")              // 12
/// let token = world.observe("player") { change in print(change.path) }
/// ```
///
/// The root is always a JSON object. All operations are atomic; observers
/// run synchronously on the mutating thread, after the change is applied and
/// outside the internal lock.
public final class WorldState: Sendable {
    typealias Handler = @Sendable (WorldStateChange) -> Void

    private struct Observer {
        var path: WorldPath?
        var handler: Handler
    }

    private struct State {
        var root: JSONValue
        var version = 0
        var observers: [UInt64: Observer] = [:]
        var nextObserverID: UInt64 = 0
    }

    private let state: Mutex<State>

    /// Creates a world from an object (empty by default).
    public init(_ root: JSONObject = JSONObject()) {
        state = Mutex(State(root: .object(root)))
    }

    /// Creates a world from a JSON value, which must be an object.
    public convenience init(json: JSONValue) throws(WorldStateError) {
        guard case .object(let object) = json else {
            throw WorldStateError(path: "", message: "The world state root must be a JSON object, not \(WorldDocument.typeName(of: json)).")
        }
        self.init(object)
    }

    /// Creates a world from JSON text (key order is preserved).
    public convenience init(parsing text: String) throws {
        try self.init(json: JSONValue(parsing: text))
    }

    // MARK: Reading

    /// The value at `path`, or `nil` if there is none (or the path is invalid).
    /// Keys match exactly; see ``tools(readable:writable:maxOutputCharacters:)``
    /// for the lenient matching offered to the model.
    public func get(_ path: String) -> JSONValue? {
        guard let parsed = try? WorldPath(path) else { return nil }
        return state.withLock { WorldDocument.value(at: parsed, in: $0.root) }
    }

    /// Decodes the value at `path` into a `Decodable` type.
    public func get<T: Decodable>(_ path: String, as type: T.Type) -> T? {
        guard let value = get(path) else { return nil }
        return try? value.decode(type)
    }

    /// Whether a value (possibly `null`) exists at `path`.
    public func contains(_ path: String) -> Bool { get(path) != nil }

    /// A copy of the whole document. `JSONValue` is `Codable`; use
    /// `snapshot().serialized()` and ``init(parsing:)`` to keep key order.
    public func snapshot() -> JSONValue { state.withLock { $0.root } }

    /// Increments on every change. Cheap to poll from a game loop.
    public var version: Int { state.withLock { $0.version } }

    // MARK: Writing

    /// Writes `value` at `path`, creating intermediate objects as needed.
    /// Writing index `n` of an `n`-element list appends.
    ///
    /// - Throws: ``WorldStateError`` if the path is invalid, crosses a
    ///   non-container value, or tries to replace the root with a non-object.
    public func set(_ path: String, _ value: JSONValue) throws(WorldStateError) {
        let parsed = try WorldPath(path)
        try apply(at: parsed) { old throws(WorldStateError) in value }
    }

    /// Writes any `Encodable` value at `path`.
    public func set(_ path: String, encoding value: some Encodable) throws {
        try set(path, try JSONValue(encoding: value))
    }

    /// Removes the value at `path` and returns it (`nil` if there was none).
    /// Removing from a list shifts the following elements.
    @discardableResult
    public func remove(_ path: String) throws(WorldStateError) -> JSONValue? {
        let parsed = try WorldPath(path)
        guard !parsed.isRoot else {
            let old = snapshot()
            try replace(with: [:])
            return old
        }
        let (removed, deliveries) = state.withLock { state -> (JSONValue?, [Delivery]) in
            let (updated, removed) = WorldDocument.removing(at: parsed.segments[...], in: state.root)
            guard let removed else { return (nil, []) }
            state.root = updated
            state.version += 1
            let change = WorldStateChange(path: parsed.description, oldValue: removed, newValue: nil)
            return (removed, Self.deliveries(for: [change], in: state))
        }
        Self.deliver(deliveries)
        return removed
    }

    /// Atomically reads and rewrites the value at `path`; `body` receives the
    /// current value (`nil` if absent) and sets it to the new value (`nil`
    /// removes it). Useful for counters touched by both the game loop and
    /// tools:
    ///
    /// ```swift
    /// try world.modify("player.gold") { $0 = .number(($0?.doubleValue ?? 0) - 45) }
    /// ```
    ///
    /// `body` runs while the world is locked: it must not access this world.
    public func modify(_ path: String, _ body: (inout JSONValue?) throws -> Void) throws {
        let parsed = try WorldPath(path)
        var failure: (any Error)?
        try apply(at: parsed) { old throws(WorldStateError) -> JSONValue? in
            var value = old
            do { try body(&value) } catch { failure = error; return old }
            return value
        }
        if let failure { throw failure }
    }

    /// Replaces the whole document. `root` must be an object.
    public func replace(with root: JSONValue) throws(WorldStateError) {
        try apply(at: .root) { _ throws(WorldStateError) in root }
    }

    /// Applies an RFC 7386 JSON Merge Patch at `path`: objects merge
    /// recursively, `null` members delete keys, anything else replaces.
    /// Observers receive one change per modified leaf.
    public func merge(_ patch: JSONValue, at path: String = "") throws(WorldStateError) {
        let parsed = try WorldPath(path)
        let deliveries = try state.withLock { state throws(WorldStateError) -> [Delivery] in
            var changes: [WorldStateChange] = []
            let current = WorldDocument.value(at: parsed, in: state.root)
            let merged = WorldDocument.merging(patch, into: current, path: parsed, changes: &changes)
            guard !changes.isEmpty else { return [] }
            let root = try WorldDocument.setting(merged, at: parsed.segments[...], in: state.root, path: parsed)
            guard case .object = root else {
                throw WorldStateError(path: path, message: "The world state root must be a JSON object.")
            }
            state.root = root
            state.version += 1
            return Self.deliveries(for: changes, in: state)
        }
        Self.deliver(deliveries)
    }

    private func apply(at path: WorldPath, _ transform: (JSONValue?) throws(WorldStateError) -> JSONValue?) throws(WorldStateError) {
        let deliveries = try state.withLock { state throws(WorldStateError) -> [Delivery] in
            let old = WorldDocument.value(at: path, in: state.root)
            let new = try transform(old)
            guard new != old else { return [] }
            if path.isRoot {
                guard case .object? = new else {
                    throw WorldStateError(path: "", message: "The world state root must be a JSON object.")
                }
                state.root = new!
            } else if let new {
                state.root = try WorldDocument.setting(new, at: path.segments[...], in: state.root, path: path)
            } else {
                state.root = WorldDocument.removing(at: path.segments[...], in: state.root).0
            }
            state.version += 1
            let change = WorldStateChange(path: path.description, oldValue: old, newValue: new)
            return Self.deliveries(for: [change], in: state)
        }
        Self.deliver(deliveries)
    }

    // MARK: Observing

    /// Calls `handler` for every change at, inside or above `path` (`""`
    /// observes everything). A change above the path (e.g. replacing
    /// `player` while observing `player.gold`) reports the old and new values
    /// of the changed ancestor.
    ///
    /// Observation stops when the returned token is cancelled or deallocated,
    /// so keep it alive.
    public func observe(_ path: String = "", _ handler: @escaping @Sendable (WorldStateChange) -> Void) -> WorldObservation {
        let id = addObserver(path, handler)
        return WorldObservation { [weak self] in self?.removeObserver(id) }
    }

    /// Changes at, inside or above `path` as an async sequence. The stream
    /// ends observation when its consumer stops iterating.
    public func changes(_ path: String = "") -> AsyncStream<WorldStateChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: WorldStateChange.self)
        let id = addObserver(path) { continuation.yield($0) }
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        return stream
    }

    private func addObserver(_ path: String, _ handler: @escaping Handler) -> UInt64 {
        let parsed = try? WorldPath(path)
        return state.withLock { state in
            state.nextObserverID += 1
            state.observers[state.nextObserverID] = Observer(path: parsed, handler: handler)
            return state.nextObserverID
        }
    }

    private func removeObserver(_ id: UInt64) {
        _ = state.withLock { $0.observers.removeValue(forKey: id) }
    }

    private typealias Delivery = (change: WorldStateChange, handlers: [Handler])

    /// Pairs each change with the observers interested in it (in registration order).
    private static func deliveries(for changes: [WorldStateChange], in state: State) -> [Delivery] {
        guard !state.observers.isEmpty else { return [] }
        let observers = state.observers.sorted { $0.key < $1.key }.map(\.value)
        return changes.compactMap { change in
            let changed = WorldPath(segments: change.path.isEmpty ? [] : change.path.split(separator: ".", omittingEmptySubsequences: false).map(String.init))
            let handlers = observers.compactMap { observer in
                observer.path.map { changed.overlaps($0) } == true ? observer.handler : nil
            }
            return handlers.isEmpty ? nil : (change, handlers)
        }
    }

    private static func deliver(_ deliveries: [Delivery]) {
        for delivery in deliveries {
            for handler in delivery.handlers { handler(delivery.change) }
        }
    }
}

extension WorldState: Codable {
    /// Decodes a world from a JSON object. `Decoder` cannot preserve key
    /// order; prefer ``init(parsing:)`` when order matters.
    public convenience init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        try self.init(json: value)
    }

    public func encode(to encoder: any Encoder) throws {
        try snapshot().encode(to: encoder)
    }
}

/// Keeps a ``WorldState`` observation alive. Cancels on deinit.
public final class WorldObservation: Sendable, Hashable {
    private let action: Mutex<(@Sendable () -> Void)?>

    init(_ cancel: @escaping @Sendable () -> Void) {
        action = Mutex(cancel)
    }

    /// Stops the observation. Safe to call more than once.
    public func cancel() {
        let cancel = action.withLock { action in
            defer { action = nil }
            return action
        }
        cancel?()
    }

    deinit { cancel() }

    public static func == (lhs: WorldObservation, rhs: WorldObservation) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
