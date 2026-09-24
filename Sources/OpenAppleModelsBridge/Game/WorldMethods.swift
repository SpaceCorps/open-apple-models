import Foundation
import OpenAppleModels
import OpenAppleModelsGame

/// `world/*` methods. World operations are synchronous and atomic, so they
/// answer immediately (in arrival order). Change notifications caused by a
/// request are sent before its response.
enum WorldMethods {
    static func register(in registry: inout BridgeMethodRegistry, game: GameExtension) {
        registry.register("world/create") { request in
            let params = request.params
            let id = try game.worldID(requested: params.optionalString("world"))
            let world: WorldState
            if let state = params["state"] {
                guard case .object(let object) = state else {
                    throw BridgeError.invalidParams("'state' must be a JSON object (the world root).")
                }
                world = WorldState(object)
            } else {
                world = WorldState()
            }
            try game.insertWorld(WorldEntry(id: id, world: world))
            return .result(["world": .string(id), "version": .number(Double(world.version))])
        }
        registry.register("world/get") { request in
            let (id, world) = try lookup(request, game: game)
            let path = try request.params.optionalString("path") ?? ""
            try validate(path, world: id)
            let value = world.get(path)
            return .result([
                "world": .string(id),
                "path": .string(path),
                "value": value ?? .null,
                "exists": .bool(value != nil),
                "version": .number(Double(world.version)),
            ])
        }
        registry.register("world/set") { request in
            let (id, world) = try lookup(request, game: game)
            let path = try request.params.optionalString("path") ?? ""
            // `null` is a legitimate value here, so read the raw member.
            guard let value = request.params.object["value"] else {
                throw BridgeError.invalidParams("Missing required parameter 'value' (use world/remove to delete).")
            }
            do throws(WorldStateError) {
                try world.set(path, value)
            } catch {
                throw BridgeError.worldError(error, world: id)
            }
            return .result(["world": .string(id), "path": .string(path), "version": .number(Double(world.version))])
        }
        registry.register("world/merge") { request in
            let (id, world) = try lookup(request, game: game)
            let path = try request.params.optionalString("path") ?? ""
            guard let patch = request.params.object["patch"] else {
                throw BridgeError.invalidParams("Missing required parameter 'patch'.")
            }
            do throws(WorldStateError) {
                try world.merge(patch, at: path)
            } catch {
                throw BridgeError.worldError(error, world: id)
            }
            return .result(["world": .string(id), "path": .string(path), "version": .number(Double(world.version))])
        }
        registry.register("world/remove") { request in
            let (id, world) = try lookup(request, game: game)
            let path = try request.params.string("path")
            let removed: JSONValue?
            do throws(WorldStateError) {
                removed = try world.remove(path)
            } catch {
                throw BridgeError.worldError(error, world: id)
            }
            return .result([
                "world": .string(id),
                "path": .string(path),
                "removed": .bool(removed != nil),
                "oldValue": removed ?? .null,
                "version": .number(Double(world.version)),
            ])
        }
        registry.register("world/snapshot") { request in
            let (id, world) = try lookup(request, game: game)
            return .result(["world": .string(id), "state": world.snapshot(), "version": .number(Double(world.version))])
        }
        registry.register("world/delete") { request in
            let id = try request.params.string("world")
            guard let removed = game.removeWorld(id) else { throw BridgeError.worldNotFound(id) }
            return .result([
                "world": .string(id),
                "deleted": true,
                "endedSubscriptions": .number(Double(removed.subscriptions)),
            ])
        }
        registry.register("world/list") { _ in
            let worlds: [JSONValue] = game.worldEntries.map { entry in
                [
                    "world": .string(entry.id),
                    "version": .number(Double(entry.world.version)),
                    "npcs": .number(Double(game.npcCount(inWorld: entry.id))),
                    "subscriptions": .array(game.subscriptions(ofWorld: entry.id).map(\.json)),
                    "createdAt": .string(BridgeSession.timestamp(entry.createdAt)),
                ]
            }
            return .result(["worlds": .array(worlds)])
        }
        registry.register("world/subscribe") { request in
            let id = try request.params.string("world")
            let path = try request.params.optionalString("path") ?? ""
            let subscription = try game.subscribe(worldID: id, path: path, engine: request.engine)
            return .result(subscription.json)
        }
        registry.register("world/unsubscribe") { request in
            let subscription = try game.unsubscribe(request.params.string("subscription"))
            var result = subscription.json.objectValue ?? [:]
            result["unsubscribed"] = true
            return .result(.object(result))
        }
    }

    static func lookup(_ request: BridgeRequest, game: GameExtension) throws(BridgeError) -> (String, WorldState) {
        let id = try request.params.string("world")
        return (id, try game.worldEntry(id).world)
    }

    static func validate(_ path: String, world: String) throws(BridgeError) {
        do {
            _ = try WorldPath(path)
        } catch {
            throw .worldError(error, world: world)
        }
    }
}
