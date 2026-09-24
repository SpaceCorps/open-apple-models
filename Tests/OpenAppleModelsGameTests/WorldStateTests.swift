import Foundation
import OpenAppleModels
@testable import OpenAppleModelsGame
import Testing

@Suite struct WorldStateTests {
    static func world() -> WorldState {
        WorldState([
            "player": ["name": "Aria", "gold": 12, "hp": 30, "alive": true],
            "party": [["name": "Brom", "class": "cleric"], ["name": "Lysa", "class": "rogue"]],
            "npcs": ["gorm": ["mood": "grumpy"]],
            "quests": ["lost_ring": ["status": "active"]],
        ])
    }

    // MARK: Paths

    @Test func getNestedValuesAndIndices() {
        let world = Self.world()
        #expect(world.get("player.gold") == 12)
        #expect(world.get("party.1.name") == "Lysa")
        #expect(world.get("party[0].class") == "cleric")
        #expect(world.get("npcs/gorm/mood") == "grumpy")
        #expect(world.get("player.missing") == nil)
        #expect(world.get("party.9.name") == nil)
        #expect(world.get("player..gold") == nil)
        #expect(world.get("")?.objectValue?.keys == ["player", "party", "npcs", "quests"])
        #expect(world.get("player.gold", as: Int.self) == 12)
    }

    @Test func pathParsing() throws {
        #expect(try WorldPath("party[0].name").segments == ["party", "0", "name"])
        #expect(try WorldPath("$.player.gold").segments == ["player", "gold"])
        #expect(try WorldPath("/player/gold").segments == ["player", "gold"])
        #expect(try WorldPath("").isRoot)
        #expect(throws: WorldStateError.self) { try WorldPath("a..b") }
        #expect(throws: WorldStateError.self) { try WorldPath("player.") }
    }

    @Test func setCreatesIntermediatesAndAppends() throws {
        let world = Self.world()
        try world.set("npcs.mira.mood", "cheerful")
        #expect(world.get("npcs.mira.mood") == "cheerful")
        try world.set("party.2", ["name": "Kael"])
        #expect(world.get("party.2.name") == "Kael")
        try world.set("party.0.name", "Bromm")
        #expect(world.get("party.0.name") == "Bromm")
        #expect(world.get("party")?.arrayValue?.count == 3)
    }

    @Test func setRejectsInvalidTargets() {
        let world = Self.world()
        #expect(throws: WorldStateError.self) { try world.set("player.gold.amount", 3) }
        #expect(throws: WorldStateError.self) { try world.set("party.7.name", "x") }
        #expect(throws: WorldStateError.self) { try world.set("", 5) }
        #expect(throws: WorldStateError.self) { try world.replace(with: [1, 2]) }
        #expect(world.get("player.gold") == 12)
    }

    @Test func removeValuesAndListElements() throws {
        let world = Self.world()
        #expect(try world.remove("player.hp") == 30)
        #expect(world.get("player.hp") == nil)
        #expect(try world.remove("party.0")?["name"] == "Brom")
        #expect(world.get("party.0.name") == "Lysa")
        #expect(try world.remove("nothing.here") == nil)
    }

    @Test func mergePatchAddsReplacesAndDeletes() throws {
        let world = Self.world()
        let changes = Log<WorldStateChange>()
        let token = world.observe { changes.append($0) }
        try world.merge(["player": ["gold": 20, "hp": nil, "title": "Knight"]])
        #expect(world.get("player.gold") == 20)
        #expect(world.get("player.hp") == nil)
        #expect(world.get("player.title") == "Knight")
        #expect(world.get("player.name") == "Aria")
        #expect(Set(changes.all.map(\.path)) == ["player.gold", "player.hp", "player.title"])
        let gold = try #require(changes.all.first { $0.path == "player.gold" })
        #expect(gold.oldValue == 12 && gold.newValue == 20)
        token.cancel()
    }

    @Test func modifyIsAtomicUnderConcurrency() async throws {
        let world = WorldState(["counter": 0])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    try? world.modify("counter") { $0 = .number(($0?.doubleValue ?? 0) + 1) }
                }
            }
        }
        #expect(world.get("counter") == 200)
        #expect(world.version == 200)
    }

    @Test func unchangedWritesDoNotNotify() throws {
        let world = Self.world()
        let changes = Log<WorldStateChange>()
        let token = world.observe { changes.append($0) }
        try world.set("player.gold", 12)
        try world.merge(["player": ["gold": 12]])
        #expect(changes.all.isEmpty)
        #expect(world.version == 0)
        _ = token
    }

    // MARK: Observers

    @Test func observersFilterByPathAndStopWhenCancelled() throws {
        let world = Self.world()
        let player = Log<WorldStateChange>()
        let gold = Log<WorldStateChange>()
        let quests = Log<WorldStateChange>()
        let playerToken = world.observe("player") { player.append($0) }
        let goldToken = world.observe("player.gold") { gold.append($0) }
        let questToken = world.observe("quests") { quests.append($0) }

        try world.set("player.gold", 50)
        try world.set("player.name", "Aria the Bold")
        // Replacing an ancestor notifies descendants' observers too.
        try world.set("player", ["gold": 1])
        #expect(player.all.map(\.path) == ["player.gold", "player.name", "player"])
        #expect(gold.all.map(\.path) == ["player.gold", "player"])
        #expect(gold.all[0].oldValue == 12 && gold.all[0].newValue == 50)
        #expect(quests.all.isEmpty)

        goldToken.cancel()
        try world.set("player.gold", 2)
        #expect(gold.all.count == 2)
        #expect(player.all.count == 4)
        _ = (playerToken, questToken)
    }

    @Test func observationEndsWhenTokenIsReleased() throws {
        let world = Self.world()
        let log = Log<WorldStateChange>()
        do {
            let token = world.observe("player") { log.append($0) }
            try world.set("player.gold", 1)
            _ = token
        }
        try world.set("player.gold", 2)
        #expect(log.all.count == 1)
    }

    @Test func changesAsyncSequence() async throws {
        let world = Self.world()
        let stream = world.changes("quests")
        try world.set("player.gold", 99)
        try world.set("quests.lost_ring.status", "done")
        var iterator = stream.makeAsyncIterator()
        let change = await iterator.next()
        #expect(change?.path == "quests.lost_ring.status")
        #expect(change?.newValue == "done")
    }

    // MARK: Persistence

    @Test func codableRoundTrip() throws {
        let world = Self.world()
        let data = try JSONEncoder().encode(world)
        let restored = try JSONDecoder().decode(WorldState.self, from: data)
        #expect(restored.snapshot() == world.snapshot())
        // Text round trip keeps key order.
        let text = world.snapshot().serialized()
        let ordered = try WorldState(parsing: text)
        #expect(ordered.snapshot().objectValue?.keys == ["player", "party", "npcs", "quests"])
        #expect(throws: (any Error).self) { try WorldState(parsing: "[1]") }
    }

    // MARK: Summary

    @Test func summaryFlattensLeaves() {
        let world = Self.world()
        let summary = world.summary(of: ["player", "npcs.gorm.mood", "missing.path", "party"])
        #expect(summary == """
            player.name: Aria
            player.gold: 12
            player.hp: 30
            player.alive: true
            npcs.gorm.mood: grumpy
            party: [{"name":"Brom","class":"cleric"},{"name":"Lysa","class":"rogue"}]
            """)
        #expect(world.summary(of: ["player"], maxLines: 2).hasSuffix("(2 more not shown)"))
    }

    // MARK: Tools

    static func run(_ tool: AgentTool, _ arguments: JSONValue) async throws -> ToolOutput {
        guard case .local(let handler) = tool.execution else { throw TestFailure("expected a local tool") }
        return try await handler(ToolCall(name: tool.name, arguments: arguments))
    }

    @Test func toolsRespectReadAndWritePermissions() async throws {
        let world = Self.world()
        let readOnly = world.tools()
        #expect(readOnly.map(\.name) == ["read_world_state"])
        #expect(readOnly[0].description.contains("Top-level keys: player, party, npcs, quests"))

        let tools = world.tools(readable: ["player", "quests"], writable: ["quests"])
        #expect(tools.map(\.name) == ["read_world_state", "update_world_state"])
        let (read, update) = (tools[0], tools[1])

        #expect(try await Self.run(read, ["path": "player.gold"]) == .json(12))
        // Case-insensitive keys and bracket syntax.
        #expect(try await Self.run(read, ["path": "Player.Gold"]) == .json(12))
        // Ancestors show only the readable parts.
        let root = try await Self.run(read, ["path": ""])
        guard case .json(let visible) = root else { throw TestFailure("expected JSON") }
        #expect(visible.objectValue?.keys == ["player", "quests"])
        // Forbidden and missing paths produce helpful errors.
        let forbidden = try await Self.run(read, ["path": "npcs.gorm"])
        #expect(forbidden.isError && forbidden.modelText.contains("Readable paths: player, quests"))
        let missing = try await Self.run(read, ["path": "player.mana"])
        #expect(missing.isError && missing.modelText.contains("'player' has keys: name, gold, hp, alive"))

        let updated = try await Self.run(update, ["path": "quests.lost_ring.status", "value": "done"])
        #expect(!updated.isError)
        #expect(world.get("quests.lost_ring.status") == "done")
        let denied = try await Self.run(update, ["path": "player.gold", "value": "9999"])
        #expect(denied.isError && denied.modelText.contains("read-only"))
        #expect(world.get("player.gold") == 12)
    }

    @Test func updateToolKeepsStoredTypes() async throws {
        let world = Self.world()
        let update = world.tools(readable: [], writable: [""])[0]
        #expect(update.name == "update_world_state")

        _ = try await Self.run(update, ["path": "player.gold", "value": "45"])
        #expect(world.get("player.gold") == 45)
        _ = try await Self.run(update, ["path": "player.alive", "value": "false"])
        #expect(world.get("player.alive") == false)
        _ = try await Self.run(update, ["path": "player.name", "value": "\"Aria\""])
        #expect(world.get("player.name") == "Aria")
        _ = try await Self.run(update, ["path": "player.buffs", "value": "[\"haste\"]"])
        #expect(world.get("player.buffs") == ["haste"])
        _ = try await Self.run(update, ["path": "player.note", "value": "likes swords"])
        #expect(world.get("player.note") == "likes swords")

        let wrongType = try await Self.run(update, ["path": "player.gold", "value": "lots"])
        #expect(wrongType.isError && wrongType.modelText.contains("not a number"))
        #expect(world.get("player.gold") == 45)
    }

    @Test func largeValuesAreShortened() async throws {
        let items = (0..<200).map { JSONValue.string("item number \($0)") }
        let world = WorldState(["log": .array(items), "big": ["a": .array(items), "b": 1]])
        let read = world.tools(maxOutputCharacters: 300)[0]
        guard case .json(let list) = try await Self.run(read, ["path": "log"]) else { throw TestFailure("expected JSON") }
        #expect(list["_note"]?.stringValue?.hasPrefix("Showing") == true)
        #expect(list.serialized().count < 400)
        guard case .json(let object) = try await Self.run(read, ["path": "big"]) else { throw TestFailure("expected JSON") }
        #expect(object["a"] == "[list of 200 items]")
        #expect(object["b"] == 1)
    }
}
