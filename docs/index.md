---
title: "OpenAppleModels | Real Tool Calling & Agent Loops for Apple Foundation Models"
description: "Open-source developer runtime unlocking reliable tool calling, autonomous agent loops, episodic NPC memory, and an OpenAI-compatible local server for Apple Foundation Models."
author: "SpaceCorps"
date: "2026-09-24"
canonical: "https://spacecorps.github.io/open-apple-models/index.md"
---

# OpenAppleModels: Real Tool Calling & Agent Loops for Apple Foundation Models

OpenAppleModels is an open-source Swift developer runtime and agent framework engineered by SpaceCorps. It unlocks reliable tool calling, autonomous agent loops, game NPC dialogue with episodic memory, and an OpenAI-compatible local server on Apple's on-device Foundation Models across iOS, iPadOS, macOS, and visionOS 27.

## Key Highlights

- **$0.00 Cloud Cost:** Runs on the device's built-in model by default. No API keys or cloud service.
- **100% On-Device Privacy:** Zero network telemetry, zero data egress.
- **333 Automated Tests:** 312 run in CI without Apple Intelligence (model-driven ones on the deterministic `ScriptedLanguageModel`); 21 live tests are opt-in (`OAM_LIVE_TESTS=1`).
- **10/10 Valid Enum Decisions:** Constrained decoding for game AI choices (about 1.2 s each, measured on macOS 27).

---

## Probing Benchmark: Apple `fm serve` vs. OpenAppleModels

Systematic testing on macOS 27 revealed critical limitations in Apple's built-in tools:

| Feature / Scenario | Apple Native (`fm serve` / SPM) | OpenAppleModels Runtime |
|---|---|---|
| **Tool Calls Emitted** | ✕ 0 / 54 Emitted (Model answered directly) | ✓ Returned as `tool_calls` |
| **`tool_choice: "required"`** | ✕ HTTP 500 Internal Server Error | ✓ Guaranteed Step-1 Tool Execution |
| **Multi-Turn Looping** | ✕ Infinite Tool-Calling Loop | ✓ Bounded Multi-Step Loop Control |
| **Direct Response Fallback** | ✕ Forces unnecessary tool calls | ✓ `.explicit` invisible `respond_directly` |
| **Game Engine Bridging** | ✕ Not Provided | ✓ JSON-RPC 2.0 (stdio) & C ABI (FFI) |
| **NPC Dialogue & Memory** | ✕ None | ✓ Personas, Secrets, & Fact Extraction |
| **CI/CD Offline Testing** | ✕ Hardware Required | ✓ `ScriptedLanguageModel` Offline Mock |

---

## Core Packages

1. **`OpenAppleModels` (Core Agent Loop):** Fine-grained per-step loop control, dynamic JSON Schema generation, and `.explicit` fallback.
2. **`OpenAppleModelsGame` (Dialogue Engine):** NPC personas, relationship meters (-100 to +100), private secret thresholds, world state subscriptions, and auto-guardrails.
3. **`OpenAppleModelsServer` (OpenAI Local Server):** Drop-in `127.0.0.1:1976/v1` server with genuine Server-Sent Events (SSE) streaming `tool_calls`.
4. **`OpenAppleModelsBridge` (JSON-RPC Protocol):** Bidirectional JSON-RPC 2.0 protocol over stdio for external runtimes.
5. **`OpenAppleModelsFFI` (C ABI):** C library with bindings for Unity (C#) and Python, plus integration notes for Godot and Unreal.
6. **`oam` (Command-Line Tool):** Developer CLI for querying models, running servers, testing tools, and running interactive RPG demos.
7. **`OpenAppleModelsTesting` (Scripted Model):** `ScriptedLanguageModel` for deterministic tests without Apple Intelligence.

---

## Developer Quickstart

### 1. Swift Agent with Tool Policy

```swift
import OpenAppleModels

let lookupInventory = try AgentTool(
    name: "lookup_inventory",
    description: "Look up quantities of items in the player's pack",
    parameters: .object(["item_name": .string()])
) { call in
    let item = try call.string("item_name")
    return .json(["item": .string(item), "count": .number(3), "rarity": .string("rare")])
}

let agent = try Agent(
    instructions: "You are a helpful game assistant. Always verify inventory before confirming.",
    tools: [lookupInventory]
)

let response = try await agent.respond(
    to: "Do I have any health potions?",
    policy: ToolPolicy(choice: .required) // Forces tool on step 1, text on step 2
)

print(response.text)   // answered from the tool's output
```

### 2. Game NPC with Episodic Memory

```swift
import OpenAppleModelsGame

let persona = Persona(
    name: "Gorm",
    role: "a grumpy dwarven blacksmith",
    personality: "Gruff and impatient, but honorable",
    secrets: ["Knows the bandit chief stole the clan's ancestral anvil"]
)

let npc = try NPC(
    persona: persona,
    tools: [forgeTool, inventoryTool],
    world: worldState,
    options: NPCOptions(memoryTools: .rememberFact, secretsUnlockAtRelationship: 75),
    memory: NPCMemory(relationship: 20)
)

let turn = try await npc.talk("Can you repair this battleaxe?")
print("\(turn.emotion): \(turn.line)")
```

### 3. OpenAI Python Client with `oam serve`

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:1976/v1", api_key="none")

response = client.chat.completions.create(
    model="system",
    messages=[{"role": "user", "content": "Am I dying?"}],
    tools=[{
        "type": "function",
        "function": {
            "name": "get_player_health",
            "description": "Check current player HP",
            "parameters": {"type": "object", "properties": {}}
        }
    }],
    tool_choice="required"
)

for tool_call in response.choices[0].message.tool_calls:
    print(f"Tool called: {tool_call.function.name}")
```

### 4. CLI Invocations

```bash
# Force a tool call. An inline tool without a command is external, so oam exits 10 with the pending call
oam respond "Look up goblin stats" \
  --tool-json '{"name":"lookup_monster","description":"Lookup monster HP","parameters":{"type":"object","properties":{"name":{"type":"string"}}}}' \
  --tool-choice required

# Run local OpenAI server (http://127.0.0.1:1976/v1)
oam serve

# Run live interactive Tavern RPG demo
oam demo tavern
```

---

## Technical Documentation Index

- [Architecture & Design (`ARCHITECTURE.md`)](https://spacecorps.github.io/open-apple-models/ARCHITECTURE.md)
- [Game Engine Integration Guide (`GAMES.md`)](https://spacecorps.github.io/open-apple-models/GAMES.md)
- [JSON-RPC 2.0 Wire Protocol (`PROTOCOL.md`)](https://spacecorps.github.io/open-apple-models/PROTOCOL.md)
- [CLI Reference Manual (`CLI.md`)](https://spacecorps.github.io/open-apple-models/CLI.md)
- [OpenAI Server Specification (`SERVER.md`)](https://spacecorps.github.io/open-apple-models/SERVER.md)
- [Research & Probing Benchmark Data (`RESEARCH.md`)](https://spacecorps.github.io/open-apple-models/RESEARCH.md)
- [Agent Hub Manifest (`llms.txt`)](https://spacecorps.github.io/open-apple-models/llms.txt)
- [Exhaustive Agent Manual (`llms-full.txt`)](https://spacecorps.github.io/open-apple-models/llms-full.txt)
- [Authentication & Requirements (`auth.md`)](https://spacecorps.github.io/open-apple-models/auth.md)
- [Pricing & Open Source License (`pricing.md`)](https://spacecorps.github.io/open-apple-models/pricing.md)
- [About SpaceCorps (`about.html`)](https://spacecorps.github.io/open-apple-models/about.html)
- [Contact & Support (`contact.html`)](https://spacecorps.github.io/open-apple-models/contact.html)
- [Privacy Policy (`privacy.html`)](https://spacecorps.github.io/open-apple-models/privacy.html)
