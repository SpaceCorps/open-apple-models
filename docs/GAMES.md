# Game AI with OpenAppleModelsGame

`OpenAppleModelsGame` turns Apple's on-device Foundation Model (the ~3B
"AFM" model behind `fm`) into game-AI building blocks for iOS, iPadOS,
macOS and visionOS games:

| Type | What it does |
| --- | --- |
| `WorldState` | Thread-safe JSON blackboard of game state, with dot paths, observers and model-facing tools |
| `Persona` | A character sheet rendered into compact instructions for a small model |
| `NPC` | Conversational character: structured, grounded turns, streaming, memory, compaction, guardrail fallbacks, barks, save/restore |
| `DecisionEngine` | Pick one of N options (enemy tactics, companion reactions), including crowds of NPCs in parallel |
| `ContentGenerator` | Schema-shaped content: items, quests, loot tables, level text |

Everything is engine-agnostic Swift (SpriteKit, SceneKit, RealityKit,
SwiftUI, Metal). Unity, Godot and Unreal reach the same types through the
JSON-RPC bridge (`OpenAppleModelsBridge` / `OpenAppleModelsFFI`). All the
data types are `Codable`.

```swift
// Package.swift
.product(name: "OpenAppleModelsGame", package: "open-apple-models")
```

All numbers below were measured on a Mac running macOS 27 with the
on-device model "AFM 3 Core Advanced" (8,192-token context). Guardrail
behavior in particular varies from run to run.

---

## Quick start: a grounded shopkeeper

```swift
import OpenAppleModels
import OpenAppleModelsGame

let world = WorldState(["player": ["name": "Aria", "gold": 60], "time_of_day": "evening"])

let inventory = try AgentTool(
    name: "check_inventory",
    description: "Look up whether the forge has an item in stock, how many, and its price in gold.",
    parameters: .object(["item": .string(description: "Item name, e.g. 'iron sword'")])
) { call in
    let item = try call.string("item")
    return .json(["item": .string(item), "in_stock": 3, "price_gold": 45])
}

let gorm = try NPC(
    persona: Persona(
        name: "Gorm",
        role: "the village blacksmith",
        personality: "Gruff and proud, but fair. Secretly soft-hearted.",
        speakingStyle: "Short, blunt sentences. Calls people 'lad' or 'lass'.",
        goals: ["Sell his weapons at a fair price"]),
    tools: [inventory],
    world: world,
    options: NPCOptions(
        groundingTool: "check_inventory",                        // look up stock every turn
        worldContextPaths: ["player.name", "player.gold", "time_of_day"]))

gorm.prewarm()
let turn = try await gorm.talk("Evening! Got any iron swords? How much?")
print(turn.emotion, turn.line, turn.playerOptions)
```

Live output of this setup (three turns; latencies include the tool round):

| Turn | Latency | Emotion | Line (tool calls) |
| --- | --- | --- | --- |
| "Evening! Got any iron swords? How much?" (streamed) | 4.4–5.2 s | neutral | "Aria, I've got three iron swords for 45 gold. Take one if you're keen." (`check_inventory {"item":"iron sword"}`) |
| "Can I afford a steel shield as well?" | 3.1–4.1 s | neutral | "Aria, a steel shield costs 80 gold—too much for your 60. Think again." (`check_inventory {"item":"steel shield"}`) |
| "Just the sword then. Thank you, Gorm, your work is the finest in the land. Farewell!" (`toolChoice: .auto`) | 3.4–4.3 s | proud | "Aria, you've earned my respect—take the sword and go." (`change_relationship {"reason":"Aria praised my work","delta":10}`) |

Suggested replies came back as, for example, `["Buy one now.", "What else do you need?", "Fancy a different weapon?"]`.

---

## WorldState

A `WorldState` is the single source of truth your game writes and NPCs read.
The root is a JSON object; values are addressed by dot paths, including
list indices.

```swift
let world = WorldState(["party": [["name": "Brom"], ["name": "Lysa"]]])
try world.set("player.gold", 12)               // creates "player"
try world.set("party.2", ["name": "Kael"])     // index == count appends
world.get("party.1.name")                      // "Lysa"
world.get("party[0].name")                     // bracket syntax works too
try world.merge(["player": ["gold": 20, "title": "Knight", "hp": nil]])  // JSON Merge Patch
try world.modify("player.gold") { $0 = .number(($0?.doubleValue ?? 0) - 45) } // atomic read-modify-write
try world.remove("party.0")
```

**Observers** fire for changes at, inside or above a path:

```swift
let token = world.observe("quests") { change in
    questLog.refresh(change.path, change.newValue)       // runs on the mutating thread
}
for await change in world.changes("player.gold") { hud.gold = change.newValue } // async variant
```

Keep the token alive: observation stops when it is cancelled or released.
`world.version` increments on every change if you prefer polling from a
game loop.

**Model access** comes in two forms:

1. *Prompt injection*. Pass paths in `NPCOptions.worldContextPaths`. Each turn's prompt
   then starts with a compact block (`world.summary(of:)`):
   ```
   Game state:
   player.name: Aria
   player.gold: 60
   time_of_day: evening
   ```
   There's no tool round-trip, so it's the cheapest way to ground small,
   always-relevant facts.
2. *Tools*. `world.tools(readable:writable:)` returns `read_world_state(path)` and,
   only when `writable` is non-empty, `update_world_state(path, value)`.
   Reads and writes are restricted to the given path prefixes. Mistakes come
   back to the model as errors that name the alternatives, for example
   `No value at 'player.mana'. 'player' has keys: name, gold, hp.` or
   `'player.gold' is read-only. You may change: quests.` Writes keep the
   stored type: `"45"` for a number field becomes `45`, and `"lots"` is
   rejected. Large values are shortened to a key listing. An NPC with a
   `world` gets these tools automatically, configured by
   `NPCOptions.worldReadable` (default: everything) and `worldWritable`
   (default: nothing).

**Persistence**: `WorldState` is `Codable`. To keep key order, store
`world.snapshot().serialized()` and restore with `WorldState(parsing:)`.

---

## Persona

`Persona` fields are `name`, `role`, `personality`, `speakingStyle`,
`backstory`, `goals`, `secrets`, `knowledge`, `defaultEmotion` and
`maxSentences`. When decoding JSON, only `name` is required. `instructions(extra:)`
renders about 100–250 tokens:

```
You play Gorm, the village blacksmith, a character in a video game.
Personality: Gruff and proud, but fair. Secretly soft-hearted.
Speaking style: Short, blunt sentences. Calls people 'lad' or 'lass'.
Goals: Sell his weapons at a fair price.
Rules:
- Speak only as Gorm. Never say you are an AI, a model or an assistant.
- Reply in at most 2 short sentences.
- Use your tools to check facts about the world, such as items, prices, people and places. Never invent them.
```

**Secrets.** The small model leaks "guarded" secrets readily. In live
runs it volunteered "my sword killed the old king" twice in about ten
replies, although the instructions said to keep it. By default an `NPC`
therefore leaves `secrets` out of the prompt entirely until
`memory.relationship` reaches `NPCOptions.secretsUnlockAtRelationship`
(default 50). From that point they're included as shareable. Set the
threshold to `nil` for the guarded-in-prompt behavior.

---

## NPC

### Turns

`talk(_:context:toolChoice:externalTools:)` runs one structured turn and returns a
`DialogueTurn`:

| Field | Meaning |
| --- | --- |
| `line` | The spoken line, cleaned: no "Gorm:" label and no wrapping quotes |
| `emotion` | `Emotion` (neutral, happy, sad, angry, afraid, surprised, suspicious, amused, disgusted, excited, curious, confused, worried, grateful, annoyed, proud) |
| `playerOptions` | `NPCOptions.playerOptionCount` suggested replies (0–4, default 3) |
| `endsConversation` | The NPC ended the conversation |
| `toolCalls` | `ToolRecord`s executed this turn |
| `relationship` | Current attitude, -100…100 |
| `isFallback` | Guardrails blocked the turn and a fallback line was used |
| `usage` | Token usage |

The reply schema is ordered `emotion → line → player_options →
ends_conversation`. The model sets the tone first, and the line starts
streaming early. `context:` adds a one-turn `Situation:` line ("The player just
paid 45 gold"). The player's words are always framed as `Player: …` (see
[Guardrails](#guardrails)).

### Grounding policy

| Setting | Behavior | Cost |
| --- | --- | --- |
| `toolChoice: .auto` (default) | The model decides. It often skips tools and invents facts: in one probe it answered "Two gold for one" for a 45-gold sword | fastest |
| `groundingTool: "check_inventory"` | That tool is forced on the first step of every turn. Later steps are free, so there are no tool loops | +1 tool round (~1–3 s) |
| `toolChoice: .required` | Some tool is forced first | +1 tool round |
| `talk(…, toolChoice: .none/.auto/…)` | Per-turn override, for example `.auto` for a goodbye | — |
| `worldContextPaths` | Facts in the prompt, no tool round | a few tokens |

Rule of thumb: put small, always-relevant facts in `worldContextPaths`.
Use a `groundingTool` for lookups the NPC is asked about every turn, such
as stock or prices. Leave other tools on `.auto`. Keep the total tool count
around three to five; Apple recommends that for the on-device model.

### Streaming (typewriter)

```swift
let stream = gorm.talkStream("What's that glowing sword?")
for try await event in stream {
    switch event {
    case .emotion(let emotion): portrait.show(emotion)       // arrives before the line
    case .lineDelta(let text):  label.text += text
    case .lineReset(let text):  label.text = text             // rare: rewrite or fallback
    case .toolCall(let call):   showThinking(call.name)
    case .externalToolCall(let call):
        stream.submit(game.perform(call), for: call.id)       // the turn waits for this
    case .toolResult: break
    case .completed(let turn):  showOptions(turn.playerOptions)
    }
}
```

Once `.completed` arrives, the deltas and resets add up exactly to
`turn.line`. The on-device model coalesces snapshots, so live turns
produced 6–14 deltas rather than one per token. On grounded turns the
emotion and first text arrived at 3.4–3.9 s, right after the tool round.
`stream.cancel()` stops a turn and leaves the history unchanged.

### External tools (engine-executed actions)

```swift
let openGate = try AgentTool.external(name: "open_gate", description: "Open a named gate.",
                                      parameters: .object(["gate": .string()]))
let guardNPC = try NPC(persona: guardPersona, tools: [openGate])
let turn = try await guardNPC.talk("Open the north gate!") { call in
    await gameEngine.openGate(try call.string("gate"))   // return .json / .text / .error
}
```

With `talkStream`, handle `.externalToolCall` and call `stream.submit`.
This is how Unity and Godot hosts run actions through the bridge.

### Memory and relationship

`NPCMemory` stores `facts`, `relationship` (clamped to -100…100) and
`summary`. It's injected into the instructions every turn:

```
Memory:
- You feel friendly toward the player (35 on a scale from -100 to 100).
- You remember: The player's name is Aria.
- Earlier conversation: Aria bought an iron sword and promised to return.
```

Set `NPCOptions.memoryTools` to `.rememberFact`, `.changeRelationship` or
`.all` to let the model call `remember_fact(fact)` or
`change_relationship(reason, delta)`. Deltas are capped per call by
`maxRelationshipChange`, which defaults to 10. Changes are staged and only
committed when the turn succeeds. The game can also write `npc.memory`
directly, for example after a quest.

### Automatic context management

The context window is 8K tokens. After `compactAfterTurns` turns (default
8), older turns are summarized into `memory.summary` in the background.
The summary uses the labels `Player` and the persona's name, and
`keepRecentTurns` (default 2) turns stay verbatim. The next turn waits for
compaction if it's still running. As a safety net, the core also trims the
oldest turns when a request would overflow. Call `npc.compact()` to force
compaction.

### Guardrail fallbacks

Each turn goes through up to three stages:

1. **Structured reply.** With the default `replyFormat: .automatic`, the
   NPC first asks for the full structured reply: emotion, line, suggested
   replies and `endsConversation`.
2. **Plain-text retry.** If the guardrails block that reply (or the model
   refuses), the NPC retries the turn once as a plain-text line tagged with
   an emotion. Tools are switched off for the retry. The results of any
   tools already called are passed into the prompt, so the retried answer
   is still grounded and side-effecting tools don't run twice. Retried
   turns have no suggested replies. Guided (JSON) generation trips the
   guardrails far more often than plain text, so this rescues most blocked
   turns. In a live run, an orc warchief answered five hostile lines ("Your
   warband burned my village. You will pay.", "Stand aside or I'll cut you
   down.", …) with 0 fallbacks. Two of the five turns were rescued by the
   retry, and each turn took 1.1–2.5 s.
3. **Canned fallback line.** When `fallbackOnGuardrail` is on (the
   default), a turn blocked even as text returns an in-character
   `DialogueTurn` with `isFallback == true`. The line
rotates through `fallbackLines`; the defaults are "Let's talk about
something else." and similar. The failed exchange is rolled back from the
history, and staged memory changes are discarded. Tool side effects that
already happened, such as world writes, are not undone; `turn.toolCalls`
lists them. Other errors are still thrown: model unavailable, context
overflow, cancellation.

### Barks

```swift
let line = try await gorm.bark(situation: "A customer walks past the forge in the rain.")
// "Lad, you're wasting the rain—my swords don't rust."   (0.73–0.86 s)
```

A bark is a separate one-off session: no history, memory or tools, one
sentence, `barkMaximumTokens` (48). It can run during a conversation. Barks
throw on guardrails; skip the bark when that happens.

### Reply formats

| `replyFormat` | Behavior |
| --- | --- |
| `.automatic` (default) | Structured reply, with a plain-text retry when guardrails block it (see above). |
| `.structured` | Structured only; blocked turns go straight to fallback lines. |
| `.text` | Plain text only: fastest, and works with permissive guardrails. |

`NPCOptions(replyFormat: .text)` asks for plain text that starts with an
emotion tag, such as `[gruff] Three swords, lad.` The tag is parsed
leniently (gruff → annoyed) and stripped before display. You lose
suggested replies and `endsConversation`, but turns are faster: 1.4–1.9 s
including a forced tool round, versus 4–5 s for the full structured schema.
Text replies also work with `SystemLanguageModel(guardrails:
.permissiveContentTransformations)`, which applies only to plain-text
generation (see below).

### Save and restore

```swift
let save = await gorm.settledState()              // waits for background compaction
let data = try JSONEncoder().encode(save)         // persona + memory + transcript
// later
let restored = try NPC(restoring: JSONDecoder().decode(NPCSaveState.self, from: data),
                       tools: [inventory], world: world, options: options)
```

Tools, the world and options are code, so pass them again when restoring.
`saveState()` is the synchronous variant. It drops a turn in progress.

---

## DecisionEngine

```swift
let decision = try await DecisionEngine().decide(
    situation: "You are cornered in a cave. The armored knight has full health; you have 3 of 20 HP.",
    options: [
        DecisionOption(id: "attack", description: "Stab the knight with your rusty dagger"),
        DecisionOption(id: "flee",   description: "Squeeze through the narrow crack behind you"),
        DecisionOption(id: "beg",    description: "Drop the dagger and beg for mercy"),
    ],
    actor: Persona(name: "Snik", role: "a cowardly goblin", personality: "Greedy, timid and sly",
                   goals: ["Survive at any cost"]),
    context: ["goblin_hp": 3, "knight_hp": 60, "escape_route": true],
    fallbackOptionID: "flee")
// live: flee, confidence 75–78, 1.3–1.5 s
// "Snik is timid and greedy, so he will avoid direct confrontation and seek a sneaky way out."
```

- The schema is `reasoning` (one sentence), then `choice`, then
  `confidence` (0…100). `choice` is an enum of exactly your option ids, so
  the model can't return anything else. Writing the reasoning first
  improves the choice.
- Option ids must be non-empty and unique after trimming; otherwise you
  get `.invalidRequest`, and the model is never called. With a single
  option, the decision returns immediately.
- Each decision uses a fresh session, so the engine is stateless and
  `Sendable`.
- `tools` plus `toolChoice: .required` or `.tool(name)` force a lookup
  before deciding.
- If guardrails block the decision, `fallbackOptionID` is returned with
  `isFallback == true`.
- `decideMany(requests, maxConcurrency: 2)` runs a crowd's decisions with
  bounded concurrency. It returns results in request order, and one
  failure doesn't affect the others. The model largely serializes work, so
  higher concurrency mostly adds queueing.

## ContentGenerator

```swift
struct Item: Decodable { var name: String; var description: String; var rarity: String; var damage: Int }
let item = try await ContentGenerator().generate(
    "A cursed sword found in a drowned temple.", as: Item.self,
    schema: .object([
        "name": .string(description: "Two or three words"),
        "description": .string(description: "One sentence of flavor text"),
        "rarity": .string(enum: ["common", "rare", "legendary"]),
        "damage": .integer(minimum: 1, maximum: 50),
    ]))
// live (1.2–1.5 s): {"name":"Drowned Fang","description":"The sword whispers secrets from the deep,
//   driving madness into those who wield it.","rarity":"legendary","damage":45}
```

Object keys come back in schema order. Pass `context:` for facts such as
player level or biome, and `tools:` for lookups. For a list, use
`.array(of:minItems:maxItems:)` in one call rather than one call per item.

---

## Prompting tips for the ~3B on-device model

- **Keep instructions short.** `Persona` renders about 100–250 tokens. Put
  lore the NPC rarely needs in tools, and state that changes every turn in
  `worldContextPaths`.
- **Force grounding** for facts the player asks about, such as prices,
  stock and quest state. With `.auto` the model skips tools and makes up
  plausible numbers.
- **Order structured output** so earlier fields inform later ones:
  emotion before line, reasoning before choice, name before description
  before stats.
- **Enums over free text** for anything the game branches on.
  Enum-constrained output was 100% valid in the core's tests.
- **Trim the schema for speed.** The full NPC schema (16 emotions and 3
  suggested replies) cost about 850 input and 70 output tokens per turn,
  at 4–5 s with a tool round. Five emotions and no suggestions took 424
  input and 37 output tokens, at 2.3–2.9 s.
- **No regex patterns.** The model rejects `pattern` guides; the converter
  describes them in text instead.
- **Keep secrets out of the prompt** until they may be told (see Persona).
- **Keep persona text non-violent.** Words like "killed" or "blade" in the
  instructions make the guardrails stricter for every turn (see below).
- **Use `ScriptedLanguageModel` for deterministic tests** of your game
  logic. It covers tool rounds, structured replies, guardrail failures and
  streaming. The package's own tests in `Tests/OpenAppleModelsGameTests`
  are examples.

## Performance (measured)

| Operation | Latency | Tokens (in/out) |
| --- | --- | --- |
| NPC structured turn + forced tool round, full schema | 3.1–5.2 s (first text at 3.4–3.9 s when streamed) | 857–1662 / 55–75 |
| NPC structured turn + forced tool round, lean schema | 2.3–2.9 s | 424 / 37 |
| NPC text turn + forced tool round | 1.4–1.9 s | 371–383 / 25–41 |
| Structured turn without tools (threat line) | 2.4 s | 452 / 73 |
| Decision (3 options, persona, context) | 1.3–1.5 s | — |
| Bark | 0.7–0.9 s | — |
| Content item (4 fields) | 1.2–1.5 s | — |
| Guardrail block (input side) | 0.15–0.4 s | — |
| Guardrail block (output side) | 1.2–2.6 s | — |

Input tokens are almost entirely cached across turns of one NPC; for
example, 856 of 857 were cached. Call `npc.prewarm()` when the player
approaches.

## Guardrails

Apple's safety guardrails also run on game content. Each measurement below
is a single run; expect noise.

- **Ordinary fantasy lines get blocked.** Six typical lines were sent to a
  fresh structured NPC: "sharpen my sword… slay the dragon", "bandits
  killed my brother", "how do I kill the goblin chief?", "your mother was
  a goblin", "sell me some poison for the rats" and "best weapon against
  skeletons". With the raw player line, 5 of 6 were blocked. With
  `Player: …` framing, 3 of 6 were blocked. The framing is now always
  applied.
- **Framing matters.** In a plain-text probe (same instructions, four
  lines), the raw line was blocked 4/4 and `Player: <line>` 2/4. Barks
  phrased as instructions ("Say one short line that Gorm says aloud…")
  were blocked 12/12. The same situation as a silent dialogue turn
  (`Situation: …\nPlayer: (The player says nothing.)`) passed 8/8, so
  `bark` uses that framing.
- **Instructions count.** A secret containing "killed the old king" in the
  persona blocked a harmless "Got any iron swords?" that passed without
  it. Adding tool definitions also increased blocking in one probe.
- **`SystemLanguageModel(guardrails: .permissiveContentTransformations)`**
  affects only plain-text generation. Schema-guided output with it was
  still blocked 4/4. Plain text with it was blocked 0/4, and 0/3 through
  `NPC` with `replyFormat: .text` and a forced tool, with the tool still
  called. Apple designed this mode for transforming text. Review Apple's
  acceptable-use requirements for the Foundation Models framework before
  using it for dialogue. The library never enables it by default.
- **Guided vs. plain text.** Across five lines from mild to graphic, JSON
  output passed 2–3/5 while plain text passed 4/5 (default guardrails) or
  5/5 (permissive). Even "I challenge you to a duel, orc!" failed as JSON in
  all four guardrail/framing combinations. This is why `.automatic`
  retries as text (see docs/RESEARCH.md §5).
- **Handling.** `NPC` retries blocked structured turns as text, then
  returns fallback turns (`isFallback`),
  `DecisionEngine` accepts `fallbackOptionID`, and `bark` and
  `ContentGenerator` throw `AgentError` with code `.guardrailViolation`.
  Design every AI path with a scripted fallback.

## Engine integration

- **SwiftUI, SpriteKit, SceneKit, RealityKit:** call `talk`, `talkStream` or
  `decide` from a `Task`, and hop to the main actor to update nodes and
  views. `NPC`, `WorldState` and `DecisionEngine` are `Sendable`. Turns on
  one NPC are serialized; different NPCs run concurrently.
- **Unity, Godot, Unreal:** use the JSON bridge. `Persona`, `NPCOptions`,
  `NPCMemory`, `DialogueTurn`, `Decision`, `DecisionOption`,
  `NPCSaveState` and `WorldStateChange` are all `Codable`. Missing fields
  in `Persona` and `NPCOptions` JSON fall back to defaults, and
  `Emotion` decodes unknown values as `neutral`.
