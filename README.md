# open-apple-models

[![CI](https://github.com/SpaceCorps/open-apple-models/actions/workflows/ci.yml/badge.svg)](https://github.com/SpaceCorps/open-apple-models/actions/workflows/ci.yml)
![Platforms: iOS, iPadOS, macOS, visionOS 27](https://img.shields.io/badge/platforms-iOS%20%7C%20iPadOS%20%7C%20macOS%20%7C%20visionOS%2027-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**Tool calling, agent loops and game AI for Apple's on-device Foundation Models.**

open-apple-models is a Swift package on Apple's FoundationModels framework (OS 27). It makes the on-device model usable as an agent: it calls tools when it should, stops when it should, and can hand each tool call to your own code, whether that is a Swift closure, a game engine, a shell script or an HTTP client. On top of that it has a game layer (NPC dialogue, decisions, content generation), the `oam` command-line tool, an OpenAI-compatible server that returns real `tool_calls`, and a JSON-RPC protocol that game engines reach over stdio or a C ABI. By default everything runs on the device's own model, with no API key or cloud service.

It is for game developers who want on-device NPCs and AI decisions on Apple platforms, and for anyone who needs real tool calls from Apple's model in Swift, from the command line or over an OpenAI-style HTTP API.

> **Status: pre-release.** There are no tagged releases yet, so depend on `main`. The library reports version `0.1.0` and the protocol is v1.0. All measurements in this repository come from macOS 27 on an Apple silicon Mac. iOS, iPadOS and visionOS are supported targets: CI builds the four Swift libraries for iOS, and visionOS builds with Xcode 27 but is not built in CI. Nothing has been measured on an iPhone, iPad or Vision Pro yet.

## Why this exists

macOS 27 ships Apple's `fm` CLI and an OpenAI-style `fm serve`, but neither gives tool calls back to you. We measured the platform before building anything; the evidence is in [docs/RESEARCH.md](docs/RESEARCH.md).

| | Tool calls returned | Force a tool call | Loop control | Usable from iOS apps |
|---|---|---|---|---|
| `fm respond` / `fm chat` | No (built-in tools only) | No | No | No (macOS CLI) |
| `fm serve` (Chat Completions) | No: 0 of 54 requests | HTTP 500 | No | No |
| FoundationModels `Tool` (Swift) | Yes | `.required` loops forever | Manual | Yes |
| open-apple-models | Yes | Yes, first step only | Round, call and per-step tool limits | Yes |

In Swift, `toolCallingMode: .required` applies to every step of the framework's internal tool loop, so the model can never answer (40+ calls in one `respond`, 3 of 3 runs). With `.allowed`, the small model often skips tools and invents facts. This package steers each model step separately instead ([How it works](#how-it-works)).

## Requirements

| | |
|---|---|
| OS | iOS, iPadOS, macOS or visionOS 27.0 or later (the minimum in `Package.swift`). |
| Device | A device that supports Apple Intelligence, with Apple Intelligence turned on and the model downloaded. Check with `SystemLanguageModel.default.availability`, or `oam available` (exit code 3 and a `reason` when unavailable). Without it, you can still build, test and develop integrations against the [scripted model](#testing-without-apple-intelligence). |
| Toolchain | A Swift 6 toolchain with the OS 27 SDKs (developed with Swift 6.4; the manifest's tools version is 6.2). macOS builds and tests work with only the Command Line Tools. iOS and visionOS builds need Xcode 27. |
| Macros | FoundationModels' `@Generable` and `@Guide` macros need Xcode. This package doesn't use them. |
| Apps embedding the C library | Set the minimum OS to 27.0. The library links FoundationModels 27 strongly, so on an older OS the app crashes at launch ([bindings/README.md](bindings/README.md)). |

Use of the model is subject to Apple's [acceptable use requirements](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/).

## Try it

On a Mac with macOS 27 and Apple Intelligence turned on:

```sh
git clone https://github.com/SpaceCorps/open-apple-models
cd open-apple-models
swift run oam available        # {"available": true, "model": "system", "contextSize": 8192, ...}
swift run oam demo tavern      # talk to Mira, an NPC innkeeper who checks a menu and takes your gold through tool calls
```

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/SpaceCorps/open-apple-models", branch: "main"),
],
targets: [
    .target(name: "MyGame", dependencies: [
        .product(name: "OpenAppleModels", package: "open-apple-models"),
        .product(name: "OpenAppleModelsGame", package: "open-apple-models"),
    ]),
]
```

| Product | Kind | Contents |
|---|---|---|
| `OpenAppleModels` | library | `Agent`, `AgentTool`, `ToolPolicy` / `ToolChoice`, `SteeredLanguageModel`, JSON Schema to `GenerationSchema` conversion, order-preserving `JSONValue` |
| `OpenAppleModelsGame` | library | `NPC`, `Persona`, `WorldState`, `DecisionEngine`, `ContentGenerator` |
| `OpenAppleModelsServer` | library | `OpenAIServer`, an embeddable OpenAI-compatible Chat Completions server (Network.framework) |
| `OpenAppleModelsBridge` | library | `BridgeEngine`, the JSON-RPC 2.0 engine behind `oam stdio` and the C ABI |
| `OpenAppleModelsFFI` | dynamic library | C ABI, `libOpenAppleModelsFFI` ([header](bindings/c/open_apple_models.h)) |
| `OpenAppleModelsTesting` | library | `ScriptedLanguageModel`, a deterministic model for tests |
| `oam` | executable | CLI: `respond`, `chat`, `serve`, `stdio`, `schema convert`, `tools validate`, `available`, `demo tavern`, `agent-readme` |

The only third-party dependency is [swift-argument-parser](https://github.com/apple/swift-argument-parser), used by `oam`.

## Quick start

### An agent with a tool

```swift
import OpenAppleModels

let inventory = try AgentTool(
    name: "check_inventory",
    description: "Look up how many of an item the blacksmith has and its price in gold.",
    parameters: .object(["item": .string(description: "Item name")])
) { call in
    let item = try call.string("item")
    return .json(["item": .string(item), "stock": 3, "price_gold": 45])
}

let gorm = try Agent(
    instructions: "You are Gorm, a grumpy blacksmith in a fantasy game. Reply in at most two sentences.",
    tools: [inventory])

// .required: the model must call a tool on the first step, then answers from its output.
let reply = try await gorm.respond(to: "Got any iron swords? How much?",
                                   policy: ToolPolicy(choice: .required))
print(reply.text, reply.toolCalls.count)
```

Structured output uses the same agent. The answer is constrained to the schema, so `choice` can only be one of the listed values:

```swift
let decision = try await gorm.respond(
    to: "A customer offers 30 gold for an iron sword. Check stock, then decide.",
    schema: .object([
        "reasoning": .string(description: "One short sentence"),
        "choice": .string(enum: ["sell", "refuse", "haggle"]),
    ]),
    policy: ToolPolicy(choice: .tool("check_inventory")))
print(decision.structured?["choice"]?.stringValue ?? "none")
```

### Tools your game executes

An **external** tool has no Swift handler. The turn pauses until the host submits the result, so the game can animate a door or check its own state first. There is no time limit unless you set the tool's `timeout`.

```swift
let openGate = try AgentTool.external(
    name: "open_gate",
    description: "Ask the game to open a named gate. Returns whether it opened.",
    parameters: .object(["gate": .string()]))

let guardAgent = try Agent(instructions: "You are a castle guard. Use tools to act.", tools: [openGate])
let run = guardAgent.run("Please open the north gate.", policy: ToolPolicy(choice: .required))

for try await event in run {
    switch event {
    case .toolCallRequested(let call):                        // the model decided to act
        let opened = await game.openGate(try call.string("gate"))   // your engine code
        run.submit(.json(["opened": .bool(opened)]), for: call.id)
    case .text(let delta, _, _):
        print(delta, terminator: "")                          // stream the reply
    case .completed(let response):
        print("\n\(response.toolCalls.count) tool call(s)")
    default:
        break
    }
}
```

### NPC dialogue

```swift
import OpenAppleModelsGame

let world = WorldState(["player": ["name": "Aria", "gold": 60], "time_of_day": "evening"])

let smith = try NPC(
    persona: Persona(
        name: "Gorm", role: "the village blacksmith",
        personality: "Gruff and proud, but fair", speakingStyle: "Short, blunt sentences. Calls people 'lad'."),
    tools: [inventory],                                     // any AgentTool, local or external
    world: world,                                           // adds a read_world_state tool
    options: NPCOptions(
        groundingTool: "check_inventory",                   // look up stock on every turn
        worldContextPaths: ["player.name", "player.gold", "time_of_day"]))

let turn = try await smith.talk("Evening! Got any iron swords? How much?")
print(turn.emotion, turn.line, turn.playerOptions)

for try await event in smith.talkStream("Can I afford a shield too?") {  // typewriter effect
    if case .lineDelta(let text) = event { print(text, terminator: "") }
}
```

In the live run of a similar setup in [docs/GAMES.md](docs/GAMES.md#quick-start-a-grounded-shopkeeper), the first turn called `check_inventory {"item":"iron sword"}` and answered "Aria, I've got three iron swords for 45 gold. Take one if you're keen." in 4.4–5.2 s.

NPCs also have memory (facts and a relationship score the model can change through opt-in tools, `NPCOptions(memoryTools: .all)`), background history compaction, secrets that unlock as the relationship grows, barks, guardrail fallbacks and `Codable` save/restore. `ContentGenerator` produces schema-shaped items, quests and loot.

### Decisions

`DecisionEngine` picks one of your option ids. The id is an enum in the output schema, so the model can't return anything else.

```swift
let choice = try await DecisionEngine().decide(
    situation: "You are cornered in a cave. The armored knight has full health; you have 3 of 20 HP.",
    options: [
        DecisionOption(id: "attack", description: "Stab the knight with your rusty dagger"),
        DecisionOption(id: "flee", description: "Squeeze through the narrow crack behind you"),
        DecisionOption(id: "beg", description: "Drop the dagger and beg for mercy"),
    ],
    actor: Persona(name: "Snik", role: "a cowardly goblin", personality: "Greedy, timid and sly",
                   goals: ["Survive at any cost"]),
    context: ["goblin_hp": 3, "knight_hp": 60, "escape_route": true],
    fallbackOptionID: "flee")                               // returned if guardrails block the request
print(choice.optionID, choice.confidence, choice.reasoning)
```

The live run in docs/GAMES.md chose `flee` with confidence 75–78 in 1.3–1.5 s. `decideMany(_:maxConcurrency:)` runs a crowd's decisions with bounded concurrency.

### Command line: `oam`

`oam` works like Apple's `fm` and adds tools: shell commands become tools the model can call, and tools without a command are answered by your own program. A tools file holds OpenAI tool definitions ([format](docs/CLI.md#tools-files)).

```sh
swift build -c release --product oam       # then copy .build/release/oam onto your PATH

# Command tools (an "x-oam" block in the tools file) run locally: arguments JSON on stdin, output on stdout.
oam respond --tools tools.json --tool-choice required 'What is the weather in Paris?'

# A tool without a command is external: oam exits with code 10 and prints the pending calls
# {"status":"tool_calls","calls":[{"id":…,"name":"lookup_order","arguments":{…}}],"transcript":"<path>"}
oam respond --tools shop.json 'Where is my order A17?' > pending.json
# Run the call yourself, then continue the same turn with its result.
oam respond --resume "$(jq -r .transcript pending.json)" \
  --tool-output "$(jq -r '.calls[0].id' pending.json)"='{"status":"shipped","eta":"Friday"}'

oam chat --tools tools.json    # interactive, streaming, live tool calls
oam serve                      # OpenAI-compatible server on 127.0.0.1:1976
oam stdio                      # JSON-RPC bridge over stdin/stdout
oam demo tavern                # talk to Mira, an NPC innkeeper with a menu tool and a till
```

Exit codes are stable (0 success, 1 failure, 2 usage, 3 model unavailable, 4 guardrail or refusal, 5 context exceeded, 6 rate limited, 10 tool calls pending, 130 interrupted). `--json` and `--events` give machine-readable output, `--tool-json` adds inline tools, and `oam agent-readme` prints a manual for AI agents. It reads `fm schema object` files and resumes `fm respond --save-transcript` files. See [docs/CLI.md](docs/CLI.md).

### OpenAI-compatible server

A replacement for `fm serve` whose `tool_calls` work. It supports `tool_choice` (`auto`, `none`, `required`, named functions, `allowed_tools`), parallel calls, streaming, `json_schema` responses, stop sequences and `data:` URL images. It is stateless: send tool results back as `role: "tool"` messages, as with OpenAI. Point an OpenAI client's `base_url` at `http://127.0.0.1:1976/v1`; [docs/SERVER.md](docs/SERVER.md) covers endpoints, errors, security and a feature-by-feature comparison with `fm serve`.

```swift
import OpenAppleModelsServer

let server = OpenAIServer(configuration: ServerConfiguration())   // 127.0.0.1:1976, model "system"
try await server.start()                                          // returns once listening
await server.waitUntilStopped()
```

```sh
curl -s http://127.0.0.1:1976/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "system",
  "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
  "tools": [{"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city.",
             "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}],
  "tool_choice": "required"}'
# → finish_reason "tool_calls", tool_calls: [{"function": {"name": "get_weather", "arguments": "{\"city\":\"Paris\"}"}}]
```

### Game engines and other languages

One JSON-RPC 2.0 protocol, v1.0 ([docs/PROTOCOL.md](docs/PROTOCOL.md)), over three transports:

| Transport | Entry point | For |
|---|---|---|
| stdio | `oam stdio`, one JSON message per line | any language or engine that can spawn a process |
| C ABI | `libOpenAppleModelsFFI`: `oam_bridge_create`, `oam_bridge_send`, `oam_bridge_destroy`, `oam_call_blocking` | in-process hosts |
| Swift | `BridgeEngine` | Swift hosts and tests |

The model decides to call a tool, the bridge sends your engine a `tool/call` request, and the engine replies with the result. This exchange follows `initialize` (id 1); some `session/event` notifications are left out:

```text
→ {"jsonrpc":"2.0","id":2,"method":"session/create","params":{"session":"guard","instructions":"You are a castle guard. Use tools to act.","tools":[{"name":"open_gate","description":"Open a named gate.","parameters":{"type":"object","properties":{"gate":{"type":"string"}}}}],"options":{"toolChoice":"required"}}}
→ {"jsonrpc":"2.0","id":3,"method":"session/respond","params":{"session":"guard","prompt":"Please open the north gate.","stream":true}}
← {"jsonrpc":"2.0","id":"t-1","method":"tool/call","params":{"session":"guard","requestId":3,"call":{"id":"call_NYH7…","name":"open_gate","arguments":{"gate":"north"}}}}
→ {"jsonrpc":"2.0","id":"t-1","result":{"output":{"opened":false,"reason":"the portcullis chain is jammed"}}}
← {"jsonrpc":"2.0","method":"session/event","params":{"session":"guard","requestId":3,"event":{"type":"text","delta":"The north gate",…}}}
← {"jsonrpc":"2.0","id":3,"result":{"session":"guard","text":"The north gate remains shut because the portcullis chain is jammed.",…}}
```

```c
oam_bridge *bridge = oam_bridge_create(on_message, game);   // on_message receives each JSON line
oam_bridge_send(bridge, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
```

Besides raw sessions, the protocol serves the game layer: `npc/*`, `decision/*`, `world/*` and `content/generate`. Every method that runs the model also accepts a scripted model (`"model": {"type": "scripted", …}`), so engine integrations can be developed and tested without Apple Intelligence.

| Binding | What it is |
|---|---|
| [`bindings/c`](bindings/c) | The C header (memory and threading rules) and `example.c`, a minimal host |
| [`bindings/python`](bindings/python) | `open_apple_models.py` (ctypes, asyncio), `example.py`, `test_bridge.py` |
| [`bindings/unity`](bindings/unity) | `OpenAppleModels.cs`, a P/Invoke wrapper for Unity (macOS, and iOS through `__Internal`) and plain .NET |
| Godot, Unreal | Integration notes in [bindings/README.md](bindings/README.md); no binding code yet |

The protocol is the seam for engine integration: an engine implements it once and injects a backend per platform, this library on Apple platforms or [open-android-models](#android) on Android. The libraries are designed so that an engine such as SpaceCorps' Space3d can work this way.

## Choosing a tool mode

`ToolChoice` controls the **first** model step of a turn. After it, the model may call tools freely until a budget runs out (except with `.none`, or once it chose `respond_directly`), so a forced call can't loop.

| `ToolChoice` | First step | Use it when |
|---|---|---|
| `.auto` (default for `Agent`) | The model decides | Facts don't matter, or speed matters most |
| `.explicit` (default for `NPC`) | The model must call a tool or a built-in `respond_directly` tool ("no lookup needed") | Mixed conversation: grounds lookups without forcing a pointless call on small talk |
| `.required` | The model must call some tool | Every answer must come from a tool |
| `.tool("name")` | The model must call that tool | You know which lookup is needed |
| `.none` | Tools off and hidden | The turn must not act |

Measured on eight tavern lines, each with a known right action (menu lookup, order, or small talk; [docs/RESEARCH.md](docs/RESEARCH.md#3-the-frameworks-tool-loop)):

| First-step policy | Right action | Average latency |
|---|---|---|
| `.auto` | 7/8 (skipped the menu for "What can I buy from you?") | 1.2 s |
| `.explicit` | 8/8 | 1.5 s |
| A separate routing decision, then a forced tool | 8/8 | 1.6 s |

It is a small sample, and tool wording mattered as much as policy: a tool named `serve_item` was called for "What can I buy?", while the same tool renamed `take_order` ("the player has just ordered…") was chosen correctly 3 of 3 times.

`ToolPolicy` also sets budgets: `maxToolRounds` (default 4) and `maxToolCalls` (default 12). Once a budget is spent, tools are disallowed and their definitions hidden, so the model answers instead of stalling. `enabledTools` narrows the tool set for one turn. The CLI takes the same choices with `--tool-choice auto|none|required|explicit|<name>`.

## Game AI guidance

- **Generate dialogue as text first.** On-device guardrails block guided (JSON) output much more often than plain text: across five lines from mild to graphic, JSON passed 2–3 of 5 and plain text 4 of 5 with default guardrails ([RESEARCH §5](docs/RESEARCH.md#5-guardrails-and-game-content)). NPCs therefore ask for a structured reply and, if it is blocked, retry once as plain text before using a canned fallback line (`replyFormat: .automatic`, the default). `NPCOptions(replyFormat: .text)` always uses plain text.
- **Treat guardrail blocks as game events.** `NPC` returns a turn with `isFallback == true`, `DecisionEngine` returns your `fallbackOptionID`, and `bark` and `ContentGenerator` throw `AgentError` with code `.guardrailViolation`. Give every AI path a scripted fallback.
- **Expect ordinary fantasy to trip guardrails.** A structured NPC had five of six typical player lines ("bandits killed my brother", …) blocked when sent raw, and three of six with the `Player: …` framing that NPCs now always apply. Violent words in a persona make every turn stricter.
- **Ground facts.** Put small, always-relevant facts in `worldContextPaths` (no tool round), use a `groundingTool` for lookups the player asks about every turn, and keep `.explicit` otherwise. With `.auto` the model makes up plausible prices.
- **Keep secrets out of the prompt.** The ~3B model leaked a "guarded" secret twice in about ten replies, so `Persona.secrets` stay out of the instructions until the relationship reaches `secretsUnlockAtRelationship` (default 50).
- **Use enums for anything the game branches on**, and put `reasoning` before `choice`: the model generates properties in schema order.
- **Stay small.** Keep about 3–5 tools per request (Apple's recommendation) and short personas. Instructions, tool definitions and the conversation all share one 8,192-token context window.

Measured latencies on macOS 27 ([docs/GAMES.md](docs/GAMES.md#performance-measured)):

| Operation | Latency |
|---|---|
| NPC structured turn with a forced tool round | 3.1–5.2 s |
| NPC plain-text turn with a forced tool round | 1.4–1.9 s |
| Decision (3 options) | 1.3–1.5 s |
| Bark (one ambient line) | 0.7–0.9 s |
| Content item (4 fields) | 1.2–1.5 s |

## How it works

```
 your prompt ──▶ Agent ──▶ LanguageModelSession (Apple's tool loop)
                              │  each model step
                              ▼
                   SteeredLanguageModel ── rewrites the step request:
                     • toolCallingMode  (required → first step only)
                     • enabled tools    (named tool, per-turn subsets)
                     • budgets          (disallow and hide tools when spent)
                     • history          (trim to the context window)
                              │
                              ▼
                   SystemLanguageModel or any other LanguageModel
                              │ tool call
                              ▼
                   AgentTool ── local closure ──▶ output
                             └─ external ──▶ AgentEvent.toolCallRequested ──▶ host submits output
```

FoundationModels runs the tool loop inside one `respond()` call, and its tool-calling mode applies to every step of that loop. `SteeredLanguageModel` wraps a model's executor so that each step gets its own mode, tool set and visible history. The framework's native, schema-constrained tool calls still do the work, so there is no parsing of tool-call JSON out of text and no invented tool names. Tool errors become error outputs the model can recover from, and a failed or cancelled turn is rolled back so history only holds complete turns. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Testing without Apple Intelligence

`ScriptedLanguageModel` plays back scripted steps and plugs into FoundationModels like a real model, so Apple's tool loop, transcript and streaming are all exercised. It records every request, so tests can check the steering:

```swift
import OpenAppleModelsTesting

let script = ModelScript([
    .toolCalls([.init(name: "check_inventory", arguments: ["item": "iron sword"])]),
    .text("Three swords, 45 gold each."),
])
let agent = try Agent(model: ScriptedLanguageModel(script), tools: [inventory])
_ = try await agent.respond(to: "Swords?", policy: ToolPolicy(choice: .required))
#expect(script.requests.map(\.toolCallingMode) == [.required, .allowed])
```

The same scripted model is available to `oam` (`OAM_SCRIPT=steps.json`) and to every bridge method (`"model": {"type": "scripted", "steps": [...]}`).

## Documentation

| Document | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, a turn step by step, steering, errors, concurrency |
| [docs/GAMES.md](docs/GAMES.md) | `WorldState`, `Persona`, `NPC`, `DecisionEngine`, `ContentGenerator`, prompting tips, guardrails, measured performance |
| [docs/CLI.md](docs/CLI.md) | Every `oam` command, tools files, exit codes, the exit-10 loop, recipes |
| [docs/SERVER.md](docs/SERVER.md) | The OpenAI-compatible server: request mapping, errors, configuration, security |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | The JSON-RPC protocol v1.0: framing, ordering, every method, scripted model, extensions |
| [docs/RESEARCH.md](docs/RESEARCH.md) | Measurements of `fm`, `fm serve` and the framework that shaped the design |
| [bindings/README.md](bindings/README.md) | Building the C library, Unity, Python, Godot and Unreal integration |

The `docs` folder is also published as a site at [spacecorps.github.io/open-apple-models](https://spacecorps.github.io/open-apple-models/).

## Android

[open-android-models](https://github.com/SpaceCorps/open-android-models) is the Android sibling, built on Gemini Nano through the ML Kit GenAI Prompt API. It uses the same concepts and names and the same JSON-RPC protocol v1.0, carried over JNI instead of stdio or a C ABI, so an engine can use this library on Apple platforms and that one on Android. Gemini Nano has no native tool calling, so tool use there is prompted and validated rather than constrained by the framework. It is earlier in development and has not yet run on a Gemini Nano device.

## Limitations and known issues

- **Upstream streaming crash.** In FoundationModels 27.0, `LanguageModelSession.streamResponse` with tool calls crashes rarely ("_ContiguousArrayStorage deallocated with non-zero retain count 2"). A 20-line reproduction with no code from this package crashed in 2 of 3 runs of 16,000 single-session turns, while non-streaming `respond` ran 80,000 turns clean. Long-running hosts that don't need token streaming can set `AgentConfiguration(streamsResponses: false)`; the reply then arrives as one text event.
- **8,192-token context** on macOS 27. Agents hide the oldest turns from the model when a request would overflow (`ContextPolicy`), `compactHistory()` summarizes them, and NPCs compact in the background after 8 turns. The server does not trim by default and returns 400 `context_length_exceeded`, as OpenAI does.
- **Guardrails** block some ordinary game content, especially in structured output (see [Game AI guidance](#game-ai-guidance)). `permissiveContentTransformations` affects only plain-text generation, and the library never enables it for you.
- **Schema limits.** Regex `pattern`, `format`, `minLength` and similar constraints can't be enforced by the model. They are described to it in text and reported as warnings.
- **Latency and load.** Each tool round adds a model step. Under heavy load single steps took 10–50 s, and transient `ModelManagerError 1012` errors appeared. By default an agent retries a failed turn once if the failure looks transient and no tool has run yet (`RetryPolicy`).
- **Other models.** `SteeredLanguageModel` wraps any `LanguageModel`, including Private Cloud Compute, but the tests and measurements use only the on-device model and the scripted model.
- **Server specifics** (structured output doesn't stream, estimated usage for tool-call responses, no `n > 1`) are listed under [SERVER.md limitations](docs/SERVER.md#limitations).

## Contributing

Issues and pull requests are welcome. Running the tests needs a macOS 27 host, because FoundationModels' 27 APIs must load; Apple Intelligence is not required.

```sh
swift build
swift test --no-parallel          # socket tests use blocking reads, so CI runs them serially
# With only the Command Line Tools, point the compiler at the Swift Testing macros:
swift test --no-parallel \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

The suite has 333 Swift Testing tests in four targets. 20 of them run against the real model and are skipped unless you set `OAM_LIVE_TESTS=1` on a machine with Apple Intelligence; one more only keeps a live server up for manual testing (`OAM_SERVE_SECONDS`). Other checks:

- `scripts/smoke-test.sh` exercises every `oam` interface on the scripted model, then against the real model (`OAM_SKIP_LIVE=1` skips that part).
- `swift build -c release --product OpenAppleModelsFFI && python3 -m unittest discover -s bindings/python -v` tests the Python binding through the C ABI.
- CI ([ci.yml](.github/workflows/ci.yml)) builds everything for macOS, builds the four Swift libraries for iOS and runs the tests on an Xcode 27 runner.

New protocol methods go in as a `BridgeExtension`; [PROTOCOL.md §11](docs/PROTOCOL.md#11-extending-the-protocol-adding-methods) shows the pattern and the scripted-model tests to add.

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 SpaceCorps Technology OÜ. Not affiliated with Apple; Apple Intelligence and Foundation Models are Apple's names for its products.
