import Foundation
import OpenAppleModels
import OpenAppleModelsBridge
import OpenAppleModelsGame
import Testing

/// `world/*` methods.
@Suite(.timeLimit(.minutes(1)))
struct WorldMethodTests {
    @Test func createReadWriteAndDelete() async throws {
        let harness = BridgeHarness()
        let created = try await harness.result("world/create", ["world": "village", "state": ["player": ["name": "Aria", "gold": 60]]])
        #expect(created == ["world": "village", "version": 0])
        let generated = try await harness.result("world/create")
        #expect(generated["world"] == "w1")

        let gold = try await harness.result("world/get", ["world": "village", "path": "player.gold"])
        #expect(gold == ["world": "village", "path": "player.gold", "value": 60, "exists": true, "version": 0])
        let missing = try await harness.result("world/get", ["world": "village", "path": "player.horse"])
        #expect(missing["value"] == .null)
        #expect(missing["exists"] == false)

        let set = try await harness.result("world/set", ["world": "village", "path": "quests.ring.stage", "value": 1])
        #expect(set == ["world": "village", "path": "quests.ring.stage", "version": 1])
        // `null` is a value, not a deletion.
        _ = try await harness.result("world/set", ["world": "village", "path": "player.horse", "value": nil])
        let horse = try await harness.result("world/get", ["world": "village", "path": "player.horse"])
        #expect(horse["exists"] == true)
        #expect(horse["value"] == .null)

        let merged = try await harness.result("world/merge", ["world": "village", "path": "player", "patch": ["gold": 15, "horse": nil]])
        #expect(merged["version"] == 3)
        let removed = try await harness.result("world/remove", ["world": "village", "path": "quests.ring"])
        #expect(removed["removed"] == true)
        #expect(removed["oldValue"] == ["stage": 1])
        let removedAgain = try await harness.result("world/remove", ["world": "village", "path": "quests.ring"])
        #expect(removedAgain["removed"] == false)

        let snapshot = try await harness.result("world/snapshot", ["world": "village"])
        #expect(snapshot["state"] == ["player": ["name": "Aria", "gold": 15], "quests": [:]])
        #expect(snapshot["state"]?["player"]?.objectValue?.keys == ["name", "gold"])

        let list = try await harness.result("world/list")
        #expect(list["worlds"]?.arrayValue?.compactMap { $0["world"]?.stringValue } == ["village", "w1"])
        #expect(list["worlds"]?[0]?["version"] == 4)

        #expect(try await harness.result("world/delete", ["world": "village"]) == ["world": "village", "deleted": true, "endedSubscriptions": 0])
        let gone = try await harness.call("world/get", ["world": "village"])
        #expect(gone.errorCode == BridgeError.Code.worldNotFound)
        #expect(gone.errorName == "world_not_found")
        #expect(gone["error"]?["data"]?["world"] == "village")
    }

    @Test func errors() async throws {
        let harness = BridgeHarness()
        _ = try await harness.result("world/create", ["world": "village", "state": ["player": ["gold": 60]]])
        let duplicate = try await harness.call("world/create", ["world": "village"])
        #expect(duplicate.errorName == "world_exists")
        #expect(duplicate.errorCode == BridgeError.Code.worldExists)

        let notObject = try await harness.call("world/create", ["state": [1, 2]])
        #expect(notObject.errorCode == BridgeError.Code.invalidParams)

        let throughNumber = try await harness.call("world/set", ["world": "village", "path": "player.gold.copper", "value": 3])
        #expect(throughNumber.errorCode == BridgeError.Code.worldError)
        #expect(throughNumber.errorName == "world_error")
        #expect(throughNumber["error"]?["data"]?["world"] == "village")

        let rootValue = try await harness.call("world/set", ["world": "village", "value": 3])
        #expect(rootValue.errorName == "world_error")

        let badPath = try await harness.call("world/get", ["world": "village", "path": "player..gold"])
        #expect(badPath.errorName == "world_error")

        let noValue = try await harness.call("world/set", ["world": "village", "path": "x"])
        #expect(noValue.errorCode == BridgeError.Code.invalidParams)

        let noSubscription = try await harness.call("world/unsubscribe", ["subscription": "sub99"])
        #expect(noSubscription.errorName == "subscription_not_found")

        // Nothing above changed the world.
        #expect(try await harness.result("world/snapshot", ["world": "village"])["version"] == 0)
    }

    @Test func subscriptionsNotifyBeforeTheResponse() async throws {
        let harness = BridgeHarness()
        _ = try await harness.result("world/create", ["world": "village", "state": ["player": ["gold": 60], "time": "dawn"]])
        let subscription = try await harness.result("world/subscribe", ["world": "village", "path": "player"])
        #expect(subscription == ["subscription": "sub1", "world": "village", "path": "player"])
        let everything = try await harness.result("world/subscribe", ["world": "village"])

        let set = harness.send("world/set", ["world": "village", "path": "player.gold", "value": 45])
        _ = try await harness.response(to: set)
        let changes = harness.box.messages.filter { $0["method"] == "world/changed" }
        #expect(changes.count == 2)
        #expect(changes.map { $0["params"]?["subscription"] } == [subscription["subscription"], everything["subscription"]])
        #expect(changes[0]["params"] == ["world": "village", "subscription": "sub1", "path": "player.gold", "oldValue": 60, "newValue": 45])
        let changeIndex = try #require(harness.box.index { $0["method"] == "world/changed" })
        let responseIndex = try #require(harness.box.index { $0["id"] == .string(set) && $0["method"] == nil })
        #expect(changeIndex < responseIndex)

        // Changes outside the path only reach the catch-all subscription.
        _ = try await harness.result("world/set", ["world": "village", "path": "time", "value": "dusk"])
        #expect(harness.box.messages.filter { $0["method"] == "world/changed" }.count == 3)

        // Removal omits newValue.
        _ = try await harness.result("world/remove", ["world": "village", "path": "player.gold"])
        let removal = try #require(harness.box.messages.last { $0["method"] == "world/changed" })
        #expect(removal["params"]?["oldValue"] == 45)
        #expect(removal["params"]?["newValue"] == nil)

        let unsubscribed = try await harness.result("world/unsubscribe", ["subscription": "sub1"])
        #expect(unsubscribed["unsubscribed"] == true)
        let list = try await harness.result("world/list")
        #expect(list["worlds"]?[0]?["subscriptions"]?.arrayValue?.count == 1)
        let deleted = try await harness.result("world/delete", ["world": "village"])
        #expect(deleted["endedSubscriptions"] == 1)
        #expect(try await harness.call("world/unsubscribe", ["subscription": everything["subscription"]!]).errorName == "subscription_not_found")
    }

    @Test func hostWorldsAreShared() async throws {
        let game = GameExtension(maxWorlds: 2)
        let harness = BridgeHarness { $0.extensions = [game] }
        let world = WorldState(["time": "noon"])
        try game.addWorld(world, id: "main")
        #expect(try await harness.result("world/get", ["world": "main", "path": "time"])["value"] == "noon")
        _ = try await harness.result("world/set", ["world": "main", "path": "time", "value": "night"])
        #expect(world.get("time") == "night")
        #expect(game.world("main") === world)

        _ = try await harness.result("world/create")
        let third = try await harness.call("world/create")
        #expect(third.errorName == "limit_reached")
        #expect(throws: BridgeError.self) { try game.addWorld(WorldState(), id: "main") }
    }
}
