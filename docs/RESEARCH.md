# Research: tool calling with Apple Foundation Models (macOS 27)

This is what we measured before building this package, on macOS 27.0 (build 26A428), Swift 6.4, `fm` 2.0.68.1.402, and an Apple silicon Mac with Apple Intelligence enabled. Every number comes from probes run against the real on-device model unless marked otherwise. Probe code and logs were kept outside the repo, but the snippets below are enough to reproduce the results.

**Summary.** The on-device model can drive a tool loop well, but only through the Swift framework and only with per-step control. Neither Apple's `fm` CLI nor `fm serve` returns tool calls, and the obvious framework switch, `toolCallingMode: .required`, loops forever. This package adds per-step control, gives any host a way to execute tool calls, and puts an OpenAI-compatible server and an engine protocol on top.

## 1. What Apple ships

| Surface | Tool calling | Notes |
|---|---|---|
| `FoundationModels` (Swift, iOS/iPadOS/macOS/visionOS 26+, 27 APIs used here) | ✅ `Tool` protocol, parallel calls, dynamic schemas | The only surface that works. It runs on iOS and iPadOS, so games can use it directly. |
| `fm` CLI (preinstalled in macOS 27): `respond`, `chat`, `schema`, `count-tokens`, `serve` | ❌ built-in tools only (`--tool barcode\|ocr`, "not available in this build") | The binary warns that the transcript contains tool calls, which are not supported in fm. |
| `fm serve` (OpenAI Chat Completions over TCP or a Unix socket) | ❌ see §2 | macOS only. Requests are handled one at a time. |
| Python SDK (`apple-fm-sdk`) | ✅ in-process tools through a C bridge | The Swift session waits on a continuation until Python supplies the tool result. There is no tool-choice control, and it targets the macOS 26 SDK. |
| `apple/foundation-models-utilities` | n/a | Adds `ChatCompletionsLanguageModel` (FM → OpenAI servers), history modifiers and Skills. |

In the 27 release, Apple also added the `LanguageModel` / `LanguageModelExecutor` protocols, which let any model back a session. It added `PrivateCloudComputeLanguageModel` (32K context, reasoning), `GenerationOptions.toolCallingMode` (`allowed`/`required`/`disallowed`), dynamic profiles (`LanguageModelSession.DynamicProfile`) with `onToolCall`/`onToolOutput` hooks, and `LanguageModelSession.usage`.

## 2. `fm serve` cannot drive a tool loop

The test prompts clearly needed a tool (weather, inventory, dice rolls):

- **`tool_choice: "auto"`: 0 tool calls in 54 requests**, streaming and non-streaming. The tool definitions do reach the prompt: prompt tokens grow from 65 with no tools to 146, 201 and 261 with one, two and three tools. The model then either invents results ("The current weather in Paris is 20°C") or leaks native call syntax into `content` in 13 of 45 replies, for example `[default_api:roll_dice{count:3,sides:8}]` or `<tool_call>{…}</tool_call>`.
- **`tool_choice: "required"` or a named function always returns HTTP 500**, "An unsupported generation guide was used." (26 of 26).
- **The other half works.** When the client injects `assistant.tool_calls` plus `role: "tool"` results, the model uses them (8 of 8).
- **Other gaps:**
  - The server streams by default.
  - `max_tokens` is ignored.
  - `finish_reason` is never `length`.
  - `n>1`, `stop` and `json_object` are rejected.
  - `json_schema` with `anyOf` needs titles, and `$ref` and type arrays fail.
  - Context overflow and guardrail blocks come back as 500.
  - Requests are handled one at a time.
- Third-party reports say tool calling worked in fm 2.0.62 and regressed in 2.0.68 (fm-proxy, fm-teardown; not verified by us).

## 3. The framework's tool loop

| Behaviour | Result |
|---|---|
| Dynamic tool (`Arguments = GeneratedContent`, runtime `GenerationSchema`) | ✅ Works. The model calls it and uses the output. |
| `toolCallingMode: .required` | ❌ **Loops forever** (40+ calls in one `respond`, 3 of 3). Apple's docs say the app must provide the exit. |
| `.allowed` (auto) | The model often **skips tools and invents facts** ("20 gold each"), especially with several tools or short-reply instructions. |
| `.disallowed` with tool definitions still visible | The model often **stalls** ("Let me check for you, lad.", 3 of 3). |
| Parallel calls | 6 calls in one step, all started within about 1 ms; outputs are kept in call order. |
| A tool throws | `respond` throws `ToolCallError`, cancels sibling calls and reverts the transcript. |
| A tool returns an error string | The model recovers gracefully: it explains or suggests alternatives (6 of 6). |
| Dependent calls (location → weather) | Two rounds, correct answer (3 of 3). |
| A tool waits for an external host | 3 s, 20 s and 70 s all fine. No framework timeout was seen. |
| Structured output (schema) plus tools in one turn | The tool runs first, then valid JSON comes out (3 of 3). |
| Enum-constrained decision (`anyOf`) | 10 of 10 valid, about 1.2 s each. |
| Regex `pattern` guides | ❌ Most throw "unsupported generation guide". Only literals and simple alternations work. |
| Continuing after a trailing tool output with an **empty prompt** | ✅ `respond(to: "")` uses the injected output naturally (12 of 12 across four variants). |
| `ToolOutput.id` ≠ `ToolCall.id` | ❌ Inference fails ("Unable to tokenize prompt"). |
| `@Generable`, `@SessionPropertyEntry` macros | Unavailable with only the Command Line Tools installed (no `FoundationModelsMacros` plugin). |

**Per-step control is the fix.** A step is one model inference. A `LanguageModel` can wrap another model's executor and rewrite each step's `LanguageModelExecutorGenerationRequest` before forwarding it. That changes the tool-calling mode, the enabled tools and the visible history, while the framework keeps running its own tool loop. Measured with that wrapper:

- **Required on the first step, then answer:** exactly one call and a grounded answer (2 of 2, about 2.3 s). The same with a named tool.
- **After the budget:** disallowing tools and hiding their definitions gives real answers.

Apple's own route to the same result is a dynamic profile whose `.toolCallingMode` flips inside `onToolOutput` (15 of 15 in our probe). That needs `@Observable` state and profile types. The wrapper works with any session and model, and no macros are needed.

## 4. Context, latency and usage

- **Context:** 8,192 tokens on macOS 27 ("AFM 3 Core Advanced"); older OS versions report 4,096. Overflow throws `LanguageModelError.contextSizeExceeded` (8,193 > 8,192), including partway through a stream.
- **Token costs:** a one-tool definition is about 112 tokens, persona instructions about 77, and a small tool round trip transcript about 218.
- **Latency, warm:** time to first token 0.5 to 0.9 s, short replies 1 to 2 s. Cold start or `prewarm` adds 1 to 3 s, and under heavy load single steps took 10 to 50 s. `prewarm()` cuts the first-turn time to first token to about 0.6 s.
- **Usage:** `usage.input.cachedTokenCount` was 0 on the on-device model in every run.
- **Under load:** transient `ModelManagerError 1012` errors appeared.
- **Upstream crash:** `LanguageModelSession.streamResponse` with tool calls crashes rarely: "_ContiguousArrayStorage deallocated with non-zero retain count 2", inside FoundationModels frames. The reproduction was a 20-line custom model with no code from this package, and the crash hit 2 of 3 runs of 16,000 single-session turns. Non-streaming `respond` ran clean for 80,000 turns. `AgentConfiguration.streamsResponses = false` avoids it.
- **Cancellation:** after a cancel, `isResponding` turns false at once, while the framework's internal task can still be finishing a step or tool call. When it ends, it restores its pre-turn transcript snapshot. The agent waits for its in-flight steps and tool calls to drain before it releases the turn queue, so the late restore can't erase the next turn.

## 5. Guardrails and game content

The five prompts ran from a mild duel challenge to a graphic threat. Each ran with **default** vs **`.permissiveContentTransformations`** guardrails, plain vs "fictional, rated T" framing, and **text** vs **structured JSON** output. Pass counts are out of 5:

| Output | default | permissive |
|---|---|---|
| Text, plain | 4/5 (only the graphic taunt blocked) | **5/5** |
| Text, framed | 4/5 | **5/5** |
| JSON (schema), plain | 3/5 | 3/5 |
| JSON (schema), framed | 2/5 | 2/5 |

What this means for games:

- **Generate NPC lines as plain text.** Guided (JSON) generation trips the guardrails much more often: even "I challenge you to a duel, orc!" failed as JSON in every configuration. Apple documents that permissive guardrails don't apply to guided generation.
- **"Fictional game" framing doesn't help** and sometimes hurts.
- **Treat guardrail errors as normal game events.** Use a fallback line, rephrase, or retry as text. Never surface them as crashes.
- Apple's acceptable-use requirements for the framework still apply, whatever the guardrail setting.

## 6. Prior art

- No open-source project we found uses native `Tool` objects with host-supplied results.
- Community OpenAI bridges (apfel, afm-Server, apple-fm-serve, fm-proxy) prompt the model to write tool-call JSON and parse it back out. They report invented tool names, broken JSON and weak parallel calls.
- The native `Tool` path plus per-step control avoids all three, because the framework constrains tool names and arguments.

## 7. Design decisions this led to

1. **The core is a Swift package on `FoundationModels`, not a wrapper around `fm`.** iOS apps can't spawn processes, and the framework is the only surface with working tools.
2. **`SteeredLanguageModel`** controls tools per step: `required` and named choice apply to the first step only, the round and call budgets are enforced, disallowed steps hide the tools, and history is trimmed to fit the context.
3. **Tools are defined at runtime from JSON Schema**, converted through `DynamicGenerationSchema`, with guides only where the model supports them.
4. **External tools suspend on a continuation** until the host supplies the result. Waits of 70 s or more were fine.
5. **Tool errors become error outputs**, never thrown, so the model can recover.
6. **The OpenAI server is stateless.** Each request rebuilds the transcript, and a trailing tool result continues with an empty prompt.
7. **NPC dialogue is text-first**, with guardrail-aware fallbacks. The measurements are in §5.
