# open-apple-models

**Real tool calling for Apple's on-device Foundation Models.** Build games where NPCs talk, check the world, and make decisions on iPhone, iPad and Mac. There are no API keys or server costs, and nothing leaves the device.

macOS 27 ships Apple's `fm` CLI and an OpenAI-style `fm serve`, but neither returns tool calls. `fm serve` injects your tools and then never emits `tool_calls` (0 of 54 in our tests), and `tool_choice: "required"` returns HTTP 500. In Swift, the obvious switch, `toolCallingMode: .required`, makes the model call tools forever. This package makes the on-device model a reliable agent:

- **Per-step tool control.** Require a tool on the first step and answer afterwards, force a named tool, cap rounds and calls, and hide tools when they're disallowed. It works with any FoundationModels `LanguageModel`.
- **Runtime tools from JSON Schema.** A tool is either a local Swift closure or an **external** tool executed by your host: the game engine, a script, or an HTTP client.
- **Game AI.** NPC dialogue with memory, relationships, world-state tools and guardrail-aware fallbacks, plus enum-constrained decisions and content generation.
- **Every integration path.** A Swift package for iOS, iPadOS, macOS and visionOS; an `oam` CLI ("`fm` with tools"); an OpenAI-compatible server with working `tool_calls`; and a JSON-RPC protocol over stdio or a C ABI for Unity, Godot, Unreal and Python.

> Requires iOS/iPadOS/macOS/visionOS **27** on an Apple Intelligence–capable device with Apple Intelligence turned on. Everything also runs against a deterministic scripted model, so you can develop and test without it.

## Why this exists

We probed the platform before building. Full evidence is in [docs/RESEARCH.md](docs/RESEARCH.md).

| | Tool calls | Forced tool | Loop control | iOS |
|---|---|---|---|---|
| `fm respond` / `fm chat` | ❌ built-ins only | ❌ | ❌ | ❌ |
| `fm serve` (Chat Completions) | ❌ 0/54 | ❌ HTTP 500 | ❌ | ❌ |
| FoundationModels `Tool` | ✅ | ⚠️ `.required` loops forever | ⚠️ manual | ✅ |
| **open-apple-models** | ✅ | ✅ first step only | ✅ rounds, calls and per-step tool sets | ✅ |

Measured on the on-device model with this package:

- **Required tool on the first step:** grounded answers ("three iron swords for 45 gold") in about 2–3 s.
- **Enum decisions:** 10 of 10 valid, about 1.2 s each.
- **External tools:** can wait on the game engine for as long as needed.

## Install

```swift
// Package.swift
.package(url: "https://github.com/SpaceCorps/open-apple-models", branch: "main"),

.target(name: "MyGame", dependencies: [
    .product(name: "OpenAppleModels", package: "open-apple-models"),
    .product(name: "OpenAppleModelsGame", package: "open-apple-models"),
]),
```

| Product | What it is |
|---|---|
| `OpenAppleModels` | Core: `Agent`, `AgentTool`, `SteeredLanguageModel`, JSON Schema → `GenerationSchema`, `JSONValue` |
| `OpenAppleModelsGame` | `NPC`, `Persona`, `WorldState`, `DecisionEngine`, `ContentGenerator` |
| `OpenAppleModelsServer` | Embeddable OpenAI-compatible Chat Completions server with real tool calls |
| `OpenAppleModelsBridge` | JSON-RPC 2.0 engine (sessions, NPCs, decisions, external tools) |
| `OpenAppleModelsFFI` | C ABI dynamic library for game engines and other languages |
| `OpenAppleModelsTesting` | `ScriptedLanguageModel` for deterministic tests |
| `oam` | Command-line tool: `respond`, `chat`, `serve`, `stdio`, `demo`, … |

## Quick start (Swift)

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

// Ground the answer: the model must call a tool first, then it answers.
let reply = try await gorm.respond(to: "Got any iron swords? How much?",
                                   policy: ToolPolicy(choice: .required))
print(reply.text)   // "I've got three iron swords for 45 gold. Don't ask me to forge more."
```

### External tools: let your game engine act

```swift
let openGate = try AgentTool.external(
    name: "open_gate",
    description: "Ask the game to open a named gate. Returns whether it opened.",
    parameters: .object(["gate": .string()]))

let guardAgent = try Agent(instructions: "You are a castle guard. Use tools to act.", tools: [openGate])
let run = guardAgent.run("Please open the north gate.", policy: ToolPolicy(choice: .required))

for try await event in run {
    switch event {
    case .toolCallRequested(let call):             // the model decided to act
        let opened = await world.openGate(try call.string("gate"))  // animate, check state…
        run.submit(.json(["opened": .bool(opened)]), for: call.id)
    case .text(let delta, _, _):
        print(delta, terminator: "")               // stream the reply
    case .completed(let response):
        print("\n\(response.toolCalls.count) tool call(s)")
    default:
        break
    }
}
```

### Structured decisions

```swift
let decision = try await gorm.respond(
    to: "A customer offers 30 gold for an iron sword. Check stock, then decide.",
    schema: .object([
        "reasoning": .string(description: "One short sentence"),
        "choice": .string(enum: ["sell", "refuse", "haggle"]),
    ]),
    policy: ToolPolicy(choice: .tool("check_inventory")))
decision.structured?["choice"]   // "refuse" — always one of the enum values
```

## How it works

```
 your prompt ──▶ Agent ──▶ LanguageModelSession (Apple's tool loop)
                              │  each model step
                              ▼
                   SteeredLanguageModel ── rewrites the step request:
                     • toolCallingMode  (required → only on step 1)
                     • enabled tools    (named tool, per-turn subsets)
                     • budgets          (disallow + hide tools when spent)
                     • history          (trim to the 8K context)
                              │
                              ▼
                   SystemLanguageModel / PCC / any LanguageModel
                              │ tool call
                              ▼
                   AgentTool ── local closure ──▶ output
                             └─ external ──▶ AgentEvent.toolCallRequested ──▶ host submits output
```

FoundationModels runs the tool loop inside one `respond()` call, and its tool-calling mode applies to every step of that loop. `SteeredLanguageModel` wraps the model's executor, so each step gets its own mode, tool set and visible history. The framework's native, schema-constrained tool calls still do the work, which means no JSON parsing and no invented tool names. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Games

<!-- filled from the game layer -->
See [docs/GAMES.md](docs/GAMES.md).

## CLI: `oam`

<!-- filled from the CLI -->
See [docs/CLI.md](docs/CLI.md).

## OpenAI-compatible server

<!-- filled from the server -->
See [docs/SERVER.md](docs/SERVER.md).

## Game engines and other languages

<!-- filled from the bridge -->
See [docs/PROTOCOL.md](docs/PROTOCOL.md) and [bindings/](bindings/).

## Testing without Apple Intelligence

```swift
import OpenAppleModelsTesting

let script = ModelScript([
    .toolCalls([.init(name: "check_inventory", arguments: ["item": "iron sword"])]),
    .text("Three swords, 45 gold each."),
])
let agent = try Agent(model: ScriptedLanguageModel(script), tools: [inventory])
let response = try await agent.respond(to: "Swords?", policy: ToolPolicy(choice: .required))
#expect(script.requests.map(\.toolCallingMode) == [.required, .allowed])
```

The scripted model plugs into FoundationModels like a real model, so Apple's tool loop, transcript and streaming are all exercised. Live tests against the real model are opt-in:

```bash
OAM_LIVE_TESTS=1 swift test
```

## Requirements and notes

- **Platforms:** iOS, iPadOS, macOS and visionOS 27 (Mac Catalyst via iOS). The system model needs Apple Intelligence; check `SystemLanguageModel.default.availability`.
- **Context:** the on-device context is 8,192 tokens. Agents trim old turns automatically, and `compactHistory()` summarizes them.
- **Tools per request:** Apple recommends at most 3–5 on-device. Narrow them per turn with `ToolPolicy(enabledTools:)`.
- **Guardrails:** generating dialogue as JSON trips guardrails much more often than plain text. The game layer generates lines as text and handles guardrail errors in character. See [docs/RESEARCH.md](docs/RESEARCH.md#5-guardrails-and-game-content).
- **Toolchain:** building with only the Command Line Tools works, but Apple's `@Generable` macros need Xcode. This package never needs them.
- Use of the model is subject to Apple's [acceptable use requirements](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/).

## License

MIT © SpaceCorps. Not affiliated with Apple. "Apple Intelligence" and "Foundation Models" are Apple's names for its products.
