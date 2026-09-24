import ArgumentParser
import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsGame

/// `oam demo …`.
struct DemoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demo",
        abstract: "Interactive demos of the game layer.",
        subcommands: [TavernDemo.self])
}

/// `oam demo tavern`: talk to an innkeeper NPC who uses real tools.
struct TavernDemo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tavern",
        abstract: "Talk to Mira the innkeeper: an NPC with a menu tool, a till that takes your gold, memory and a mood.",
        discussion: """
            Everything Mira says is generated on-device. She checks the menu and takes your gold \
            through real tool calls against a live world state, remembers how you treat her, and \
            finally makes a decision about you with the DecisionEngine. About a minute.

            Type what you say, or the number of a suggested reply. An empty line leaves the tavern.
            Without a terminal (or with --auto) a few canned lines are played.
            """)

    @Option(name: .customLong("line"), help: ArgumentHelp("Say this instead of typing (repeatable).", valueName: "text"))
    var lines: [String] = []

    @Flag(help: "Play canned player lines instead of reading the keyboard.")
    var auto = false

    @Option(name: .customLong("max-turns"), help: ArgumentHelp("Turns before closing time.", valueName: "n"))
    var maxTurns = 6

    func run() async throws {
        let model = try ModelProvider.makeModel()
        let tavern = Tavern()
        let npc: NPC
        do {
            npc = try NPC(
                persona: Tavern.mira,
                model: model,
                tools: try tavern.tools(),
                world: tavern.world,
                options: NPCOptions(
                    toolChoice: .explicit,
                    maxToolRounds: 2,
                    worldReadable: [],
                    worldContextPaths: ["player.name", "player.gold", "tavern.time_of_day", "tavern.weather"],
                    memoryTools: .changeRelationship,
                    maxRelationshipChange: 15,
                    playerOptionCount: 3))
        } catch {
            throw CLIError(normalizing: error)
        }
        npc.prewarm()

        let scripted: [String]? = !lines.isEmpty ? lines : (auto || !Console.stdinIsTerminal ? Tavern.cannedLines : nil)
        let screen = TavernScreen()
        screen.title()

        // An ambient line while the player walks in: a fast, tool-free call.
        let started = ContinuousClock.now
        if let bark = try? await npc.bark(situation: "A soaked traveler pushes open the door and shakes off the rain.") {
            screen.npcLine(bark, emotion: nil, elapsed: ContinuousClock.now - started)
        }

        var suggestions: [String] = []
        var turns = 0
        var toolCalls = 0
        var tokens = 0
        var queue = scripted ?? []
        while turns < maxTurns {
            let said: String
            if scripted != nil {
                guard !queue.isEmpty else { break }
                screen.suggestions(suggestions)
                said = queue.removeFirst()
                screen.playerLine(said)
            } else {
                guard let typed = await screen.ask(suggestions: suggestions) else { break }
                said = typed
            }
            turns += 1
            let goldBefore = tavern.gold
            let relationshipBefore = npc.memory.relationship
            let turnStart = ContinuousClock.now
            do {
                let turn = try await screen.play(npc.talkStream(said))
                toolCalls += turn.toolCalls.count
                tokens += turn.usage.totalTokens
                screen.aftermath(
                    turn: turn, elapsed: ContinuousClock.now - turnStart,
                    gold: (goldBefore, tavern.gold), relationship: (relationshipBefore, npc.memory.relationship))
                suggestions = turn.playerOptions
                // The small model occasionally flags a normal reply as the end of
                // the conversation; only close early when the player said goodbye.
                if turn.endsConversation, Tavern.isFarewell(said) { break }
            } catch {
                screen.problem(CLIError(normalizing: error))
                suggestions = []
            }
        }

        // A decision about the player, from what happened.
        let relationship = npc.memory.relationship
        screen.section("Closing time. Mira decides what to do about you…")
        let decisionStart = ContinuousClock.now
        do {
            let decision = try await DecisionEngine(model: model, temperature: 0.3).decide(
                situation: "It is late, the rain is getting worse and the traveler has nowhere to sleep. What do you do?",
                options: [
                    DecisionOption(id: "free_room", description: "Offer a room for the night, free of charge"),
                    DecisionOption(id: "room_on_credit", description: "Offer a room, to be paid for tomorrow"),
                    DecisionOption(id: "full_price", description: "Offer a room for the full 12 gold"),
                    DecisionOption(id: "turn_away", description: "Tell them the inn is full"),
                ],
                actor: Tavern.mira,
                context: [
                    "traveler_gold": .number(Double(tavern.gold)),
                    "your_feelings_toward_traveler": .string("\(NPCMemory(relationship: relationship).attitude) (\(relationship) of 100)"),
                    "rooms_free": 2,
                ],
                fallbackOptionID: "full_price")
            screen.decision(decision, elapsed: ContinuousClock.now - decisionStart)
        } catch {
            screen.problem(CLIError(normalizing: error))
        }
        screen.summary(turns: turns, toolCalls: toolCalls, tokens: tokens, elapsed: ContinuousClock.now - started)
    }
}

// MARK: - The tavern

/// The game side: a menu, a till and the world state the NPC sees.
final class Tavern: Sendable {
    static let mira = Persona(
        name: "Mira",
        role: "the innkeeper of the Sleeping Stag, a roadside tavern",
        personality: "Warm, quick-witted and shrewd about money. Loves news from the road.",
        speakingStyle: "Friendly and brisk. Calls people 'love'. Short sentences.",
        backstory: "Took over the inn from her father ten winters ago.",
        goals: ["Keep the tavern running", "Hear news from travelers"],
        secrets: ["She keeps smuggled elven wine in the cellar"],
        knowledge: ["The old mill road is flooded", "A bard named Tobin plays on Fridays"],
        defaultEmotion: .happy,
        maxSentences: 2)

    static let cannedLines = [
        "Evening! What have you got that's warm?",
        "I'll take the rabbit stew, please.",
        "Best stew I've had in years, thank you! Any news from the road?",
    ]

    struct Item: Sendable {
        var name: String
        var price: Int
        var stock: Int
    }

    private enum Order: Sendable {
        case taken(Item)
        case refused(String)
    }

    let world = WorldState([
        "player": ["name": "Traveler", "gold": 30],
        "tavern": ["name": "The Sleeping Stag", "time_of_day": "late evening", "weather": "cold rain"],
    ])

    private let menu = Locked<[Item]>([
        Item(name: "ale", price: 2, stock: 20),
        Item(name: "mulled wine", price: 4, stock: 6),
        Item(name: "rabbit stew", price: 5, stock: 3),
        Item(name: "honey bread", price: 1, stock: 8),
        Item(name: "room for the night", price: 12, stock: 2),
    ])

    var gold: Int { world.get("player.gold")?.intValue ?? 0 }

    static func isFarewell(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return ["bye", "goodnight", "good night", "farewell", "see you", "i'm off", "i must go", "leave"].contains { lowered.contains($0) }
    }

    /// `check_menu` (read) and `take_order` (changes the world).
    func tools() throws -> [AgentTool] {
        let itemArgument = JSONSchema.object(["item": .string(description: "Menu item, e.g. 'ale' or 'rabbit stew'. Empty for the whole menu.")])
        let check = try AgentTool(
            name: "check_menu",
            description: "Look up the tavern's menu: what is served, the price in gold and how many are left. Use it when the player asks what you sell or what something costs; leave item empty to list the whole menu.",
            parameters: itemArgument
        ) { [self] call in
            let query = (call.arguments["item"]?.stringValue ?? "").lowercased()
            let items = menu.value
            let matches = query.isEmpty ? items : items.filter { $0.name.contains(query) || query.contains($0.name) }
            guard !matches.isEmpty else {
                return .error("Not on the menu. The menu is: \(items.map(\.name).joined(separator: ", ")).")
            }
            return .json(.array(matches.map { ["item": .string($0.name), "price_gold": .number(Double($0.price)), "left": .number(Double($0.stock))] }))
        }
        let serve = try AgentTool(
            name: "take_order",
            description: "The player has just ordered a specific item (\"I'll have the stew\", \"one ale, please\"): serve it and charge them. Not for questions about the menu.",
            parameters: itemArgument
        ) { [self] call in
            let query = (call.arguments["item"]?.stringValue ?? "").lowercased()
            let order = menu.withLock { items -> Order in
                guard let index = items.firstIndex(where: { $0.name.contains(query) || query.contains($0.name) }), !query.isEmpty else {
                    return .refused("Not on the menu: '\(query)'.")
                }
                guard items[index].stock > 0 else { return .refused("\(items[index].name) is sold out.") }
                items[index].stock -= 1
                return .taken(items[index])
            }
            switch order {
            case .refused(let message):
                return .error(message)
            case .taken(let item):
                let gold = self.gold
                guard gold >= item.price else {
                    menu.withLock { items in
                        if let index = items.firstIndex(where: { $0.name == item.name }) { items[index].stock += 1 }
                    }
                    return .error("The player has only \(gold) gold; \(item.name) costs \(item.price).")
                }
                try world.set("player.gold", .number(Double(gold - item.price)))
                return .json(["served": .string(item.name), "paid_gold": .number(Double(item.price)), "player_gold_left": .number(Double(gold - item.price))])
            }
        }
        return [check, serve]
    }
}

// MARK: - Presentation

/// Terminal rendering for the tavern demo.
struct TavernScreen {
    private func style(_ style: Style, _ text: String) -> String { style.apply(text, on: .standardOutput) }

    func title() {
        Console.outLine()
        Console.outLine(style(.bold, "  The Sleeping Stag") + style(.dim, "  ·  an open-apple-models demo"))
        Console.outLine(style(.dim, "  Rain hammers the shutters. A fire crackles. Mira wipes down the bar."))
        Console.outLine(style(.dim, "  Everything she says is generated on this device. Watch her tools:"))
        Console.outLine(style(.dim, "  she checks the menu and takes your gold through real tool calls."))
        Console.outLine()
    }

    func section(_ text: String) {
        Console.outLine()
        Console.outLine(style(.dim, "  " + text))
    }

    func playerLine(_ text: String) {
        Console.outLine(style(.bold, "you") + style(.dim, " › ") + text)
    }

    func npcLine(_ text: String, emotion: Emotion?, elapsed: Duration) {
        Console.outLine(speaker(emotion) + text + "  " + style(.dim, seconds(elapsed)))
    }

    private func speaker(_ emotion: Emotion?) -> String {
        style(.magenta, "Mira") + (emotion.map { style(.dim, " (\($0.rawValue))") } ?? "") + style(.dim, " › ")
    }

    /// Lists the replies the model suggested for the player.
    func suggestions(_ suggestions: [String]) {
        guard !suggestions.isEmpty else { return }
        let listed = suggestions.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "   ")
        Console.outLine(style(.dim, "    " + listed))
    }

    /// Asks for the player's line. `nil` means the player leaves.
    func ask(suggestions: [String]) async -> String? {
        self.suggestions(suggestions)
        Console.out(style(.bold, "you") + style(.dim, " › "))
        guard let line = await LineReader.readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else {
            Console.outLine()
            return nil
        }
        if let number = Int(line), (1...suggestions.count).contains(number) {
            let chosen = suggestions[number - 1]
            Console.outLine(style(.dim, "    “\(chosen)”"))
            return chosen
        }
        if ["q", "quit", "exit", "bye"].contains(line.lowercased()) { return nil }
        return line
    }

    /// Streams one NPC turn: tool activity, then the line as it is written.
    func play(_ stream: DialogueStream) async throws -> DialogueTurn {
        var started = false
        var emotion: Emotion?
        for try await event in stream {
            switch event {
            case .emotion(let value):
                emotion = value
            case .toolCall(let call):
                Console.outLine(style(.cyan, "    ⚙ \(call.name)") + style(.dim, " \(call.arguments.serialized())"))
            case .externalToolCall:
                break
            case .toolResult(let record):
                var text = record.output.modelText
                if text.count > 110 { text = String(text.prefix(107)) + "…" }
                Console.outLine(style(record.output.isError ? .red : .green, "      ↳ ") + style(.dim, text))
            case .lineDelta(let delta):
                if !started {
                    Console.out(speaker(emotion))
                    started = true
                }
                Console.out(delta)
            case .lineReset(let text):
                if started { Console.outLine() }
                Console.out(speaker(emotion) + text)
                started = true
            case .completed(let turn):
                if !started { Console.out(speaker(turn.emotion) + turn.line) }
                return turn
            }
        }
        throw CLIError(AgentError(.generationFailed, "The turn ended without a reply."))
    }

    func aftermath(turn: DialogueTurn, elapsed: Duration, gold: (Int, Int), relationship: (Int, Int)) {
        var notes = [seconds(elapsed)]
        if turn.isFallback { notes.append("fallback line: the guardrails blocked this turn") }
        Console.outLine("  " + style(.dim, notes.joined(separator: " · ")))
        var changes: [String] = []
        if gold.0 != gold.1 { changes.append("gold \(gold.0) → \(gold.1)") }
        if relationship.0 != relationship.1 {
            let arrow = relationship.1 > relationship.0 ? "♥" : "♡"
            changes.append("\(arrow) Mira's opinion of you \(relationship.0) → \(relationship.1) (\(NPCMemory(relationship: relationship.1).attitude))")
        }
        if !changes.isEmpty { Console.outLine(style(.yellow, "    " + changes.joined(separator: " · "))) }
    }

    func decision(_ decision: Decision, elapsed: Duration) {
        let label = style(.bold, decision.optionID.replacingOccurrences(of: "_", with: " "))
        Console.outLine("  DecisionEngine → " + label + style(.dim, "  (confidence \(decision.confidence), \(seconds(elapsed)))"))
        if !decision.reasoning.isEmpty { Console.outLine(style(.dim, "  “\(decision.reasoning)”")) }
        if decision.isFallback { Console.outLine(style(.dim, "  (fallback option: the guardrails blocked the decision)")) }
    }

    func problem(_ error: CLIError) {
        Console.outLine()
        Console.outLine(style(.red, "  ✗ ") + error.message)
        if error.exitCode == ExitStatus.blocked {
            Console.outLine(style(.dim, "    The on-device guardrails blocked that line. Try saying it differently."))
        }
    }

    func summary(turns: Int, toolCalls: Int, tokens: Int, elapsed: Duration) {
        Console.outLine()
        Console.outLine(style(.dim, "  \(turns) turn\(turns == 1 ? "" : "s") · \(toolCalls) tool call\(toolCalls == 1 ? "" : "s") · \(tokens) tokens · \(seconds(elapsed)) total, all on-device"))
        Console.outLine(style(.dim, "  Build your own: docs/GAMES.md (NPC, WorldState, DecisionEngine) · oam agent-readme"))
        Console.outLine()
    }

    private func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1fs", value)
    }
}
