import Foundation
import OpenAppleModels
import OpenAppleModelsGame
import Synchronization

/// The game method set: NPC dialogue (`npc/*`), decisions (`decision/*`),
/// shared world state (`world/*`) and content generation
/// (`content/generate`), on top of `OpenAppleModelsGame`.
///
/// Part of ``BridgeConfiguration/standardExtensions()``, so the `oam stdio`
/// CLI and the C ABI serve these methods by default. See
/// `docs/PROTOCOL.md` for the message reference.
///
/// Swift hosts can share objects with bridge clients: add a ``WorldState``
/// the game already owns with ``addWorld(_:id:)``, or reach an NPC a client
/// created with ``npc(_:)``.
///
/// ```swift
/// let game = GameExtension()
/// try game.addWorld(worldState, id: "main")
/// var configuration = BridgeConfiguration()
/// configuration.extensions = [game]
/// let engine = BridgeEngine(configuration: configuration) { line in print(line) }
/// ```
///
/// An extension instance belongs to one engine: create a new one per engine.
public final class GameExtension: BridgeExtension {
    /// Most NPCs alive at once; `npc/create` fails with `limit_reached` beyond it.
    public let maxNPCs: Int
    /// Most worlds alive at once.
    public let maxWorlds: Int
    /// Most `world/subscribe` subscriptions alive at once.
    public let maxSubscriptions: Int

    struct State {
        var npcs: [String: NPCEntry] = [:]
        var npcOrder: [String] = []
        var worlds: [String: WorldEntry] = [:]
        var worldOrder: [String] = []
        var subscriptions: [String: WorldSubscription] = [:]
        var subscriptionOrder: [String] = []
        var nextNPC = 1
        var nextWorld = 1
        var nextSubscription = 1
    }

    let state = Mutex(State())

    public init(maxNPCs: Int = 128, maxWorlds: Int = 64, maxSubscriptions: Int = 256) {
        self.maxNPCs = max(1, maxNPCs)
        self.maxWorlds = max(1, maxWorlds)
        self.maxSubscriptions = max(1, maxSubscriptions)
    }

    // MARK: BridgeExtension

    public func register(in registry: inout BridgeMethodRegistry, engine: BridgeEngine) {
        NPCMethods.register(in: &registry, game: self)
        DecisionMethods.register(in: &registry, game: self)
        WorldMethods.register(in: &registry, game: self)
    }

    /// `npc/event` (streamed dialogue) and `world/changed` (subscriptions).
    public var notificationMethods: [String] { ["npc/event", "world/changed"] }

    /// Cancels every NPC turn and removes all NPCs, worlds and subscriptions.
    public func shutdown() async {
        let (npcs, subscriptions) = state.withLock { state in
            defer {
                state.npcs = [:]
                state.npcOrder = []
                state.worlds = [:]
                state.worldOrder = []
                state.subscriptions = [:]
                state.subscriptionOrder = []
            }
            return (Array(state.npcs.values), Array(state.subscriptions.values))
        }
        for entry in npcs { entry.queue.cancelAll() }
        for subscription in subscriptions { subscription.observation.cancel() }
    }

    // MARK: In-process access

    /// The NPC with id `id`, if any.
    public func npc(_ id: String) -> NPC? {
        state.withLock { $0.npcs[id]?.npc }
    }

    /// The world with id `id`, if any.
    public func world(_ id: String) -> WorldState? {
        state.withLock { $0.worlds[id]?.world }
    }

    /// Ids of live NPCs, in creation order.
    public var npcIDs: [String] { state.withLock { $0.npcOrder } }

    /// Ids of live worlds, in creation order.
    public var worldIDs: [String] { state.withLock { $0.worldOrder } }

    /// Makes a world the host already owns available to bridge clients
    /// under `id` (for `world/*` methods and `npc/create {"world": id}`).
    /// Changes either side makes are visible to the other.
    ///
    /// - Throws: ``BridgeError`` `world_exists`, `limit_reached` or `invalid_params`.
    public func addWorld(_ world: WorldState, id: String) throws(BridgeError) {
        try GameJSON.validateID(id, parameter: "world")
        try insertWorld(WorldEntry(id: id, world: world))
    }

    // MARK: NPC store

    func npcEntry(_ id: String) throws(BridgeError) -> NPCEntry {
        guard let entry = state.withLock({ $0.npcs[id] }) else { throw .npcNotFound(id) }
        return entry
    }

    var npcEntries: [NPCEntry] {
        state.withLock { state in state.npcOrder.compactMap { state.npcs[$0] } }
    }

    /// Validates a requested NPC id, or generates a free one (`npc1`, `npc2`, …).
    func npcID(requested: String?) throws(BridgeError) -> String {
        if let requested {
            try GameJSON.validateID(requested, parameter: "npc")
            guard state.withLock({ $0.npcs[requested] == nil }) else { throw .npcExists(requested) }
            return requested
        }
        return state.withLock { state in
            while true {
                let id = "npc\(state.nextNPC)"
                state.nextNPC += 1
                if state.npcs[id] == nil { return id }
            }
        }
    }

    func insertNPC(_ entry: NPCEntry) throws(BridgeError) {
        let limit = maxNPCs
        try state.withLock { state throws(BridgeError) in
            guard state.npcs[entry.id] == nil else { throw .npcExists(entry.id) }
            guard state.npcs.count < limit else { throw .limitReached("NPCs", limit: limit) }
            state.npcs[entry.id] = entry
            state.npcOrder.append(entry.id)
        }
    }

    func removeNPC(_ id: String) -> NPCEntry? {
        let entry = state.withLock { state -> NPCEntry? in
            guard let entry = state.npcs.removeValue(forKey: id) else { return nil }
            state.npcOrder.removeAll { $0 == id }
            return entry
        }
        entry?.queue.cancelAll()
        return entry
    }

    // MARK: World store

    func worldEntry(_ id: String) throws(BridgeError) -> WorldEntry {
        guard let entry = state.withLock({ $0.worlds[id] }) else { throw .worldNotFound(id) }
        return entry
    }

    var worldEntries: [WorldEntry] {
        state.withLock { state in state.worldOrder.compactMap { state.worlds[$0] } }
    }

    func worldID(requested: String?) throws(BridgeError) -> String {
        if let requested {
            try GameJSON.validateID(requested, parameter: "world")
            guard state.withLock({ $0.worlds[requested] == nil }) else { throw .worldExists(requested) }
            return requested
        }
        return state.withLock { state in
            while true {
                let id = "w\(state.nextWorld)"
                state.nextWorld += 1
                if state.worlds[id] == nil { return id }
            }
        }
    }

    func insertWorld(_ entry: WorldEntry) throws(BridgeError) {
        let limit = maxWorlds
        try state.withLock { state throws(BridgeError) in
            guard state.worlds[entry.id] == nil else { throw .worldExists(entry.id) }
            guard state.worlds.count < limit else { throw .limitReached("worlds", limit: limit) }
            state.worlds[entry.id] = entry
            state.worldOrder.append(entry.id)
        }
    }

    /// Removes a world and ends its subscriptions. NPCs created with it keep
    /// using it; it is only no longer reachable by id.
    func removeWorld(_ id: String) -> (entry: WorldEntry, subscriptions: Int)? {
        let removed = state.withLock { state -> (WorldEntry, [WorldSubscription])? in
            guard let entry = state.worlds.removeValue(forKey: id) else { return nil }
            state.worldOrder.removeAll { $0 == id }
            let ended = state.subscriptions.values.filter { $0.worldID == id }
            for subscription in ended { state.subscriptions[subscription.id] = nil }
            state.subscriptionOrder.removeAll { subscriptionID in ended.contains { $0.id == subscriptionID } }
            return (entry, ended)
        }
        guard let (entry, ended) = removed else { return nil }
        for subscription in ended { subscription.observation.cancel() }
        return (entry, ended.count)
    }

    /// Number of NPCs created with world `id`.
    func npcCount(inWorld id: String) -> Int {
        state.withLock { $0.npcs.values.filter { $0.worldID == id }.count }
    }

    // MARK: Subscriptions

    /// Observes `path` in world `worldID` and forwards each change as a
    /// `world/changed` notification. The engine is held weakly: it owns
    /// this extension.
    func subscribe(worldID: String, path: String, engine: BridgeEngine) throws(BridgeError) -> WorldSubscription {
        let entry = try worldEntry(worldID)
        do {
            _ = try WorldPath(path)
        } catch {
            throw .worldError(error, world: worldID)
        }
        let limit = maxSubscriptions
        let id = try state.withLock { state throws(BridgeError) -> String in
            guard state.subscriptions.count < limit else { throw .limitReached("world subscriptions", limit: limit) }
            defer { state.nextSubscription += 1 }
            return "sub\(state.nextSubscription)"
        }
        let observation = entry.world.observe(path) { [weak engine] change in
            var params: JSONObject = ["world": .string(worldID), "subscription": .string(id)]
            for (key, value) in GameCoding.json(change) { params[key] = value }
            engine?.notify("world/changed", .object(params))
        }
        let subscription = WorldSubscription(id: id, worldID: worldID, path: path, observation: observation)
        let inserted = state.withLock { state -> Bool in
            // The world may have been deleted meanwhile.
            guard state.worlds[worldID] === entry else { return false }
            state.subscriptions[id] = subscription
            state.subscriptionOrder.append(id)
            return true
        }
        guard inserted else {
            observation.cancel()
            throw .worldNotFound(worldID)
        }
        return subscription
    }

    func unsubscribe(_ id: String) throws(BridgeError) -> WorldSubscription {
        let subscription = state.withLock { state -> WorldSubscription? in
            guard let subscription = state.subscriptions.removeValue(forKey: id) else { return nil }
            state.subscriptionOrder.removeAll { $0 == id }
            return subscription
        }
        guard let subscription else { throw .subscriptionNotFound(id) }
        subscription.observation.cancel()
        return subscription
    }

    func subscriptions(ofWorld id: String) -> [WorldSubscription] {
        state.withLock { state in state.subscriptionOrder.compactMap { state.subscriptions[$0] }.filter { $0.worldID == id } }
    }
}

// MARK: - Entries

/// A live NPC and what the bridge needs to list, update and save it.
final class NPCEntry: Sendable {
    let id: String
    let npc: NPC
    let worldID: String?
    let modelKind: String
    let createdAt: Date
    /// Serializes this NPC's turn-affecting requests in arrival order.
    let queue = WorkQueue()

    struct Mutable {
        /// Client tool definitions as sent (echoed into save states).
        var toolDefinitions: [JSONValue]
        /// Time limit for this NPC's client tools.
        var toolTimeout: Duration?
    }

    let mutable: Mutex<Mutable>

    init(id: String, npc: NPC, worldID: String?, modelKind: String, toolDefinitions: [JSONValue], toolTimeout: Duration?, createdAt: Date = Date()) {
        self.id = id
        self.npc = npc
        self.worldID = worldID
        self.modelKind = modelKind
        self.createdAt = createdAt
        mutable = Mutex(Mutable(toolDefinitions: toolDefinitions, toolTimeout: toolTimeout))
    }

    var toolDefinitions: [JSONValue] { mutable.withLock { $0.toolDefinitions } }
    var toolTimeout: Duration? { mutable.withLock { $0.toolTimeout } }

    /// Tool names the model sees (client tools plus built-in world and memory tools).
    var modelToolNames: [String] {
        BridgeCoding.savedSetup(of: npc.transcript)?.tools.map(\.name) ?? []
    }

    /// The `npc/list` entry.
    var summary: JSONValue {
        let persona = npc.persona
        var object: JSONObject = [
            "npc": .string(id),
            "name": .string(persona.name),
            "role": .string(persona.role),
        ]
        object["world"] = worldID.map(JSONValue.string) ?? .null
        object["model"] = .string(modelKind)
        object["tools"] = .array(toolDefinitions.compactMap { $0["name"] ?? $0["function"]?["name"] })
        object["turnCount"] = .number(Double(npc.turnCount))
        object["relationship"] = .number(Double(npc.memory.relationship))
        object["busy"] = .bool(queue.pendingOperations > 0)
        object["pendingOperations"] = .number(Double(queue.pendingOperations))
        object["createdAt"] = .string(BridgeSession.timestamp(createdAt))
        return .object(object)
    }

    /// Bridge-level settings stored next to ``NPCSaveState`` in `npc/state`,
    /// so `npc/restore` can rebuild the NPC from the save alone.
    var saveExtras: JSONObject {
        var options = GameCoding.json(npc.options).objectValue ?? [:]
        options["toolTimeoutSeconds"] = .number(GameJSON.seconds(toolTimeout))
        return [
            "npc": .string(id),
            "options": .object(options),
            "tools": .array(toolDefinitions),
            "world": worldID.map(JSONValue.string) ?? .null,
        ]
    }
}

/// A world addressable by id.
final class WorldEntry: Sendable {
    let id: String
    let world: WorldState
    let createdAt: Date

    init(id: String, world: WorldState, createdAt: Date = Date()) {
        self.id = id
        self.world = world
        self.createdAt = createdAt
    }
}

/// A `world/subscribe` registration.
struct WorldSubscription: Sendable {
    let id: String
    let worldID: String
    let path: String
    let observation: WorldObservation

    var json: JSONValue {
        ["subscription": .string(id), "world": .string(worldID), "path": .string(path)]
    }
}
