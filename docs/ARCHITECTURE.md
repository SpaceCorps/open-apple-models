# Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Hosts: iOS/macOS apps · Unity/Godot/Unreal · Python · shell · HTTP        │
├───────────────┬──────────────────┬──────────────────┬────────────────────┤
│ Swift API     │ oam CLI          │ OpenAI server    │ JSON-RPC bridge    │
│ (in-process)  │ respond/chat/... │ /v1/chat/...     │ stdio · C ABI      │
├───────────────┴──────────────────┴──────────────────┴────────────────────┤
│ OpenAppleModelsGame: NPC · Persona · WorldState · DecisionEngine · ...   │
├──────────────────────────────────────────────────────────────────────────┤
│ OpenAppleModels core                                                     │
│   Agent ── AgentRun (events, external tool channel)                      │
│   AgentTool ── ToolRuntime/ToolAdapter (budget, timeouts, continuations) │
│   SteeredLanguageModel ── StepController (per-step mode/tools/history)   │
│   JSONSchema ── SchemaConverter ── DynamicGenerationSchema               │
├──────────────────────────────────────────────────────────────────────────┤
│ Apple FoundationModels: LanguageModelSession · Tool · Transcript         │
│   SystemLanguageModel (on-device) · PrivateCloudComputeLanguageModel ·   │
│   any LanguageModel (ScriptedLanguageModel in tests)                      │
└──────────────────────────────────────────────────────────────────────────┘
```

## A turn, step by step

1. **`Agent.run(prompt, policy:)`** creates an `AgentRun`, an event stream plus a channel for tool outputs. The turn is added to the agent's `TurnQueue`, so turns never overlap. A `LanguageModelSession` rejects concurrent requests.
2. When the turn starts, the agent points the `ToolRuntime` at the turn's `TurnContext` (event sink, call budget, pending external calls). It then hands the turn's `ToolPolicy` and `ContextPolicy` to the `StepController`.
3. The agent calls `session.streamResponse(to:)`. From here, **Apple's framework runs the loop**: it asks the model for a step, runs any tool calls, appends them to the transcript, and repeats until the model answers.
4. **Every model step passes through `SteeredExecutor`**, because the session's model is `SteeredLanguageModel(base:)`. Before forwarding the request to the base model's executor, `StepController.prepare` does four things:
   - counts the tool rounds and calls since the last prompt
   - sets `generationOptions.toolCallingMode`:
     - `.none` or a spent budget → `disallowed`
     - `.required` or `.tool(name)` on step 0 → `required`, with the enabled tools narrowed for `.tool(name)`
     - otherwise → `allowed`
   - on disallowed steps, removes the tool definitions from both `enabledToolDefinitions` and the instructions entry. If the model can still see its tools, it tends to stall ("let me check…").
   - trims the oldest complete turns if the transcript would overflow the context window. The token count comes from `SystemLanguageModel.tokenCount(for:)`. The session's own transcript keeps every entry; only what the model sees is trimmed.
5. **Tool calls** arrive at `ToolAdapter.call(arguments:)`, a FoundationModels `Tool` with `Arguments = GeneratedContent`. The `ToolRuntime` then:
   - checks the call budget; calls over budget get an error output, not an exception
   - for a **local** tool, emits `toolCallStarted` and runs the handler with a timeout. Errors become `ToolOutput.error` so the model can recover, because a thrown error would abort the turn and cancel sibling calls.
   - for an **external** tool, emits `toolCallRequested` and waits on a `CheckedContinuation` until the host calls `AgentRun.submit(_:for:)`. Cancellation, a timeout or the end of the turn resolve the wait with an error.
   - finally emits `toolCallCompleted`
6. Snapshots from the response stream become `.text(delta:text:isReset:)`, or `.partial(JSON)` for schema turns. The turn ends with `.completed(AgentResponse)`, which carries the text or structured JSON reordered to the schema, the tool records, usage and steps.
7. **On failure**, whether an error or a cancellation, the agent waits until the session is idle, rolls the transcript back to where it was before the turn, and fails the stream with a normalized `AgentError`. History only ever contains complete turns.

## Why steering happens in the executor

FoundationModels exposes `GenerationOptions.toolCallingMode`, but it applies to **every** step of the internal loop. With `.required`, the model can never answer. Apple's own fix is a `DynamicProfile` whose `.toolCallingMode` depends on observable state that changes in `onToolOutput`. That works (15 of 15 in our probes), but it needs profile types, `@Observable` state, and macros for session properties.

A `LanguageModel` wrapper does the same job. `LanguageModelExecutorGenerationRequest` is a mutable value and the base model's executor is public, so the wrapper can edit each step's request and forward it. This works for any base model: on-device, Private Cloud Compute, or third-party providers. Tool calls stay native (constrained decoding of tool names and arguments), which is why this approach doesn't suffer from the invented names and broken JSON that prompt-parsing bridges report.

## External tools and statelessness

External tools let the *host* act: animate a door, roll dice with the game's RNG, query a database. The model's turn stays suspended inside Apple's loop while it waits, and we measured waits of 70 s or more with no framework timeout.

Hosts that can't keep a turn suspended, such as stateless HTTP clients or a CLI that exits, use **transcript reconstruction** instead. They rebuild `[instructions, …history, prompt, toolCalls, toolOutput]` and call `respond(to: "")`. The model continues naturally from the tool output (12 of 12 in probes). Each `Transcript.ToolOutput.id` must equal the `Transcript.ToolCall.id` it answers, or inference fails.

## JSON Schema → `GenerationSchema`

`SchemaConverter` builds `DynamicGenerationSchema` trees:

- Objects keep their property order. Property order matters because the model generates in order: put `reasoning` before `choice`.
- `enum` and string-literal unions become `anyOf` choices, so the model can only emit listed values.
- Numeric ranges and array counts become guides.
- `anyOf` of objects becomes a union.
- `$ref`/`$defs` become named references, and recursion works.

Constraints the model can't enforce (`pattern`, `format`, `minLength`, …) are written into the description and returned as warnings. Most regex guides make the on-device model throw "unsupported generation guide".

`JSONValue` is an order-preserving JSON type with its own parser. Foundation's JSON APIs lose key order.

## Errors

`AgentError` normalizes `LanguageModelError`, `LanguageModelSession.GenerationError`, `ToolCallError`, cancellation and schema errors into stable codes: `model_unavailable`, `guardrail_violation`, `refusal`, `context_size_exceeded`, `rate_limited`, `unsupported_language`, `invalid_schema`, `tool_failed`, `cancelled`, `busy`, `invalid_request`, `generation_failed`. The server, the bridge and the CLI map these codes to HTTP statuses, JSON-RPC error codes and exit codes.

## Concurrency

- Everything public is `Sendable` and checked under Swift 6 strict concurrency.
- An `Agent` serializes its own turns. Separate agents, and therefore separate NPCs, run concurrently, and the system model schedules them.
- Tool handlers may run concurrently with each other: the framework executes parallel calls at the same time.

## Testing

`ScriptedLanguageModel` implements `LanguageModel`/`LanguageModelExecutor` and plays back scripted steps: text, tool calls, JSON, errors, delays, or steps computed from the request. It records every request (tool-calling mode, enabled tools, schema, transcript), so tests can check the steering precisely without Apple Intelligence. Live tests against the real model are opt-in with `OAM_LIVE_TESTS=1`.
