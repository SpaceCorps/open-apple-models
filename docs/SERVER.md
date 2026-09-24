# OpenAppleModelsServer — an OpenAI-compatible server with real tool calls

`OpenAppleModelsServer` serves Apple's on-device Foundation Model (and any other
FoundationModels `LanguageModel`) over the OpenAI **Chat Completions** API, with
working `tool_calls`. It replaces `fm serve` (macOS 27's `/usr/bin/fm`) for agentic
clients: `fm serve` accepts `tools` but never returns `tool_calls`, and it answers
`tool_choice: "required"` or a named tool with HTTP 500.

It is a library target with no third-party dependencies (Network.framework and Foundation
only). Each request runs on its own `Agent` from the core library. The request's tools become
*external* agent tools. When the model calls one, the server replies with
`finish_reason: "tool_calls"`. The client runs the tool and sends the result back in a
`tool` message, which is the standard OpenAI tool loop.

## Quick start (Swift)

```swift
import OpenAppleModels
import OpenAppleModelsServer

var configuration = ServerConfiguration()          // 127.0.0.1:1976, model "system"
configuration.modelAliases = ["gpt-4o-mini": "system"]  // unmodified OpenAI clients work
configuration.logger = { print($0) }

let server = OpenAIServer(configuration: configuration)
try await server.start()                            // returns once listening
print("listening on", server.port!)                 // use port 0 for an ephemeral port
await server.waitUntilStopped()                     // or call server.stop()
```

Serve a Unix domain socket as well as TCP, or instead of it:

```swift
configuration.unixSocketPath = "/tmp/oam.sock"      // created with mode 0600
configuration.port = nil                            // nil disables TCP
```

Tools that run inside the server process are called **server tools**. The model can call
them next to the client's tools. Their calls and results are never sent to the client:

```swift
configuration.serverTools = [
    try AgentTool(name: "get_player_stats", description: "Current player stats.") { _ in
        .json(["hp": 42, "gold": 130])
    },
]
```

`OpenAIServer.handle(_:)` serves an `HTTPRequest` without sockets. It returns an
`HTTPResponse`, and streamed responses have a `.stream(HTTPBodyStream)` body. Use it for
tests or to embed the API in another transport.

## Using it from clients

```bash
curl -s http://127.0.0.1:1976/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "system",
  "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
  "tools": [{"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city.",
             "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}],
  "tool_choice": "required"
}'
```

```json
{
  "id": "chatcmpl-…", "object": "chat.completion", "created": 1790271229, "model": "system",
  "system_fingerprint": "fp_open_apple_models",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": null, "refusal": null, "annotations": [],
                "tool_calls": [{"id": "call_6IGCCzZI7Ew1rss83M90Ia1d", "type": "function",
                                "function": {"name": "get_weather", "arguments": "{\"city\":\"Paris\"}"}}]},
    "logprobs": null, "finish_reason": "tool_calls"}],
  "usage": {"prompt_tokens": 61, "completion_tokens": 7, "total_tokens": 68,
            "prompt_tokens_details": {"cached_tokens": 0}, "completion_tokens_details": {"reasoning_tokens": 0}}
}
```

To continue, send the whole conversation back with the tool result. The server is
stateless:

```json
{"model": "system", "tools": [...], "messages": [
  {"role": "user", "content": "What is the weather in Paris?"},
  {"role": "assistant", "content": null, "tool_calls": [{"id": "call_6IGC…", "type": "function",
    "function": {"name": "get_weather", "arguments": "{\"city\":\"Paris\"}"}}]},
  {"role": "tool", "tool_call_id": "call_6IGC…", "content": "{\"temp_c\": 14, \"conditions\": \"light rain\"}"}
]}
```

→ `"content": "The current weather in Paris is 14°C with light rain."`, `finish_reason: "stop"`.

The official `openai` Python package, LangChain and other OpenAI clients work unchanged
when you set `base_url="http://127.0.0.1:1976/v1"`. Any API key string works unless you
configure `apiKey`.

### Streaming

With `"stream": true` the server sends server-sent events over chunked transfer encoding:

```
data: {"id":"chatcmpl-…","object":"chat.completion.chunk",…,"choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
data: {…"delta":{"content":"The current"}…}
data: {…"delta":{"content":" weather in Paris"}…}
data: {…"delta":{},"finish_reason":"stop"}]}
data: {…"choices":[],"usage":{"prompt_tokens":177,…}}        ← only with stream_options.include_usage
data: [DONE]
```

A streamed tool call arrives as one delta that carries the full call:
`{"tool_calls":[{"index":0,"id":"call_…","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Tokyo\"}"}}]}`.
The final chunk then has `finish_reason: "tool_calls"`.

The server waits for the first token before it sends the `200` status. Failures before that
point, such as an unavailable model, context overflow or a guardrail block, get a normal
HTTP error status. A failure after streaming has started is sent as
`data: {"error": {...}}`, followed by `data: [DONE]`.

## Endpoints

| Method and path | Purpose |
|---|---|
| `POST /v1/chat/completions` (also `/chat/completions`) | Chat completions, streaming or not |
| `GET /v1/models`, `GET /v1/models/{id}` | Models in the OpenAI list format. Aliases are listed with `parent` |
| `GET /health` | `{"status":"ok","models":{…},"active_requests":…,"queued_requests":…}`. Returns 503 when the default model is unavailable |
| `OPTIONS *` | CORS preflight for allowed origins |

Unknown paths return `404` with `code: "unknown_url"`. A wrong method returns `405` with an
`Allow` header.

## How a request maps onto FoundationModels

| OpenAI | FoundationModels / core |
|---|---|
| `system` and `developer` messages | Joined into the agent's instructions. `developer` is treated as `system` |
| `user` content: a string or `text` and `image_url` parts | `Transcript.Prompt` segments. Images must be `data:` URLs and are decoded with ImageIO into image attachments (vision). Consecutive user messages are merged |
| `assistant` content | `Transcript.Response` |
| `assistant` `tool_calls` | `Transcript.ToolCalls` with the **client's ids**. `arguments` is parsed into `GeneratedContent` with key order kept |
| `tool` messages | `Transcript.ToolOutput(id: tool_call_id, toolName:)`, with the name taken from the matching call. Outputs are placed in the order of the calls, whatever order the client sent them in |
| Last message is `user` | That message becomes the prompt. Everything before it becomes history |
| Last message is `tool` | Generation continues after the tool output with an **empty prompt**, which works reliably on-device |
| `tools` | `AgentTool.external(...)` plus the configured server tools |
| `tool_choice` `auto` / `none` / `required` / `{"type":"function",…}` / `allowed_tools` | `ToolPolicy.choice` = `.auto` / `.none` / `.required` / `.tool(name)`, and `enabledTools`. `required` and named choices apply to the **first model step only** (the core's steering), so the model cannot loop |
| `parallel_tool_calls: false` | Only the first call is returned |
| `temperature` (0 = greedy), `top_p`, `seed` | `GenerationOptions` sampling: `.greedy` or `.random(probabilityThreshold:seed:)` |
| `max_completion_tokens` / `max_tokens` | `maximumResponseTokens`. `finish_reason: "length"` when the limit is reached |
| `stop` (a string or up to 4 strings) | Applied by the server. Text is held back until it cannot be the start of a stop sequence. Generation is cancelled at the first match |
| `response_format: json_schema` | Constrained generation through the core's JSON Schema → `GenerationSchema` converter. `strict` is accepted. Output keys follow schema order |
| `response_format: json_object` | Best effort: the model is instructed to answer with a JSON object, then the output is validated. Code fences and surrounding prose are stripped. On failure: 500 `invalid_json_output` |

Tool calls in the history are validated strictly, because on-device inference pairs each
tool output with its call by id: a `ToolOutput` whose id differs from its call's id makes
inference fail ("Unable to tokenize prompt"), and a call without an output makes `fm serve`
produce garbage. So every `tool_calls` id must be non-empty and unique in the conversation,
and every call must be answered by exactly one `tool` message placed directly after the
assistant message that made it. Anything else is rejected with 400 before the model runs
(`missing_tool_output`, `unknown_tool_call_id`, `duplicate_tool_call_id`,
`duplicate_tool_output`). Client-chosen ids of any shape (`c1`, `call_…`) work, and a
follow-up request may omit `tools` (verified live).

When the model calls a client tool, the server waits for a short debounce window (40 ms by
default) to collect parallel calls. It then cancels the turn and returns the calls in the
order the model generated them. Call ids use OpenAI's `call_` + 24 alphanumerics format.

Ignored without error: `user`, `metadata`, `store`, `logprobs`, `top_logprobs`,
`frequency_penalty`, `presence_penalty`, `logit_bias`, `service_tier`, `reasoning_effort`
(the model has no reasoning mode), `prediction`, `n: 1`.

## Compatibility with `fm serve`

| Behaviour | `fm serve` (macOS 27) | OpenAppleModelsServer |
|---|---|---|
| `tools` → `tool_calls` | Never (0/54 attempts). Tool syntax leaks into `content` about 30% of the time | **Yes**, with `finish_reason: "tool_calls"`. Parallel calls work (live: Paris and Tokyo in one response, 3/3) |
| `tool_choice: "required"` / named | 500 "An unsupported generation guide was used." | **Works**. Applies to the first step only, so the loop cannot run away |
| `tool_choice: "none"` / `allowed_tools` | — | Works (tools are hidden from the model) |
| `role: "tool"` round trips | Work | Work (continuation with an empty prompt) |
| Streaming | Always on, even without `"stream": true` | Only when requested. Standard chunks, `include_usage`, `[DONE]` |
| `max_tokens` | Ignored (only `max_completion_tokens` works). `finish_reason` is always `stop` | Both work. `finish_reason: "length"` is reported |
| `stop` | 400 | Supported (string or up to 4 strings) |
| `n > 1` | 400 | 400 (the on-device model makes one choice) |
| `reasoning_effort` | 400 | Ignored |
| Unknown model | 400 | 404 `model_not_found`. Aliases can map OpenAI model names |
| `response_format: json_object` | 400 | Best effort (instructed and validated) |
| `response_format: json_schema` | Works, but `anyOf` needs titles, and type arrays, `$ref` and `pattern` fail | Core converter: `anyOf`/`oneOf`, nullable type arrays, local `$ref`, `allOf`. Regex `pattern` is described to the model, not enforced |
| Concurrency | One request at a time | Up to `maxConcurrentRequests` (default 4), each on its own session. The rest queue |
| Context overflow | 500 | 400 `context_length_exceeded` (live: "8443 tokens exceeds … 8192") |
| Guardrail block | 500 | 400 `content_filter` |
| Refusal | — | 200 with `message.refusal` set |
| Rate limited | — | 429 `rate_limited` with `Retry-After` |
| Trailing `assistant` message (prefill) | 200 with empty content | 400 `invalid_last_message` |
| Images | — | `image_url` parts with `data:` URLs (live: identified a red PNG as "Red"). Remote URLs → 400 |
| POST without `Content-Type: application/json` | 403 | 415 `unsupported_media_type` |
| Foreign `Origin` | 403 | 403 `origin_not_allowed`. Allowed origins are configurable, with CORS preflight |
| Auth | None | Optional Bearer `apiKey` |
| Unix domain socket | No | Yes (`unixSocketPath`, mode 0600) |

## Errors

Every error uses OpenAI's envelope, `{"error": {"message", "type", "param", "code"}}`:

| Status | `code` | When |
|---|---|---|
| 400 | `invalid_json`, `invalid_value`, `invalid_type`, `missing_required_parameter`, `invalid_last_message`, `unknown_tool_call_id`, `missing_tool_output`, `duplicate_tool_call_id`, `duplicate_tool_output`, `unknown_tool`, `invalid_schema`, `unsupported_image_url`, `invalid_image`, `malformed_request` | Invalid requests. `param` names the field, for example `messages[2].tool_call_id` |
| 400 | `context_length_exceeded` | The conversation does not fit the 8192-token context |
| 400 | `content_filter` | The on-device safety guardrails blocked the input or output |
| 401 | `invalid_api_key` | `apiKey` is set and the Bearer token is missing or wrong |
| 403 | `origin_not_allowed` | A browser `Origin` that is not in `allowedOrigins` |
| 404 | `model_not_found` / `unknown_url` | |
| 405 / 415 | `method_not_allowed` / `unsupported_media_type` | |
| 413 / 431 | `malformed_request` | The body exceeds `maxRequestBodyBytes`, or the headers exceed `maxHeaderBytes` |
| 429 | `rate_limited` | The system rate-limited the model, or the request queue is full. Has `Retry-After` |
| 500 | `invalid_json_output`, `tool_failed`, … | Server or model failures |
| 503 | `model_unavailable` | Apple Intelligence is off, the device is not eligible, or the model is still downloading |
| 504 | `timeout` | The request (including time spent queued) exceeded `requestTimeout` |

## Configuration

| `ServerConfiguration` property | Default | Notes |
|---|---|---|
| `host` / `port` | `127.0.0.1` / `1976` | `port: 0` picks a free port (`server.port`). `nil` disables TCP |
| `unixSocketPath` | `nil` | Also listen on a Unix socket |
| `models` | `["system": SystemLanguageModel.default]` | Any FoundationModels `LanguageModel` |
| `modelAliases` / `defaultModel` | `[:]` / `"system"` | For example `["gpt-4o-mini": "system"]`. The default is used when `model` is omitted |
| `serverTools` / `serverInstructions` | `[]` / `nil` | In-process tools, and instructions prepended to every request |
| `apiKey` | `nil` | Requires `Authorization: Bearer …` on `/v1/*`. `/health` stays open |
| `allowedOrigins` | `[]` | Browser origins allowed to call the API. `"*"` allows all |
| `maxRequestBodyBytes` / `maxHeaderBytes` | 16 MiB / 64 KiB | |
| `maxConcurrentRequests` / `maxQueuedRequests` | 4 / 64 | Extra requests queue in FIFO order. When the queue is full: 429 |
| `requestTimeout` | 120 s | Covers queueing and generation |
| `idleTimeout` | 30 s | Time allowed to deliver a complete request, and keep-alive idle time. Protects against slowloris |
| `toolCallDebounce` | 40 ms | Window for collecting parallel tool calls |
| `toolPolicy` | `ToolPolicy()` | Round and call budgets for server tools. `choice` and `enabledTools` come from the request |
| `contextPolicy` | no trimming | An oversized conversation fails like OpenAI does. Enable trimming to drop the oldest turns instead |
| `retryPolicy` | `.default` | Retries transient model failures that happen before any tool ran |
| `logger` | `nil` | Receives `ServerLogEntry` (access log, errors) |

## HTTP implementation

The server implements HTTP/1.1 itself on Network.framework:

- Request line and headers with case-insensitive names. `Content-Length` and `chunked`
  request bodies are supported. `Expect: 100-continue` gets an interim response.
- Keep-alive and pipelining. `Connection: close` and HTTP/1.0 are handled.
- Strict parsing against request smuggling:
  - `Content-Length` together with `Transfer-Encoding`, or conflicting lengths → 400.
  - Whitespace before a colon or obsolete line folding → 400.
  - HTTP/1.1 without exactly one `Host` header → 400.
- Size limits: a head over the limit → 431, a body over the limit → 413 (checked against
  the declared length before the body is read). Malformed input → 400, then the connection
  closes.
- A connection must deliver a complete request within `idleTimeout`, or it is closed
  (slowloris protection).
- If the client disconnects while its request is being generated, the generation is
  cancelled and its concurrency slot is freed.

## Security notes

- The server binds to `127.0.0.1` by default. If you bind to another interface, set `apiKey`.
  Bearer tokens are compared in constant time.
- **Browsers:** any request with an `Origin` header outside `allowedOrigins` is rejected
  with 403. Browsers always send `Origin` on cross-site and same-site POSTs. This blocks:
  - CSRF from web pages,
  - DNS-rebinding attacks against the local server.

  A POST also needs `Content-Type: application/json`, which a plain HTML form cannot send.
- The server never fetches remote URLs. Images must be sent inline as `data:` URLs.
- The Unix socket is created with mode `0600` (owner only). A non-socket file at the path is
  never replaced.
- Server tools run in-process with the server's privileges. Validate their arguments like any
  other untrusted input, because the model chooses them.

## Performance (measured on this Mac, AFM 3 Core Advanced)

| Request | Latency |
|---|---|
| Tool-call response (`tool_choice: "required"`) | 0.6–1.0 s warm. The first request after launch took 4.5 s (model load) |
| Two parallel tool calls in one response | about 1.0 s |
| Answer after the tool result | 0.7–1.3 s (about 99% of the prompt served from the prefix cache: `cached_tokens: 193/194`) |
| `json_schema` structured reply | 1.0–1.2 s |
| Image (`data:` PNG) question | about 1.9 s |
| Streaming | first chunk at about 0.43 s |
| Three concurrent short requests | all finished within 0.55 s |

Latency depends on what else is using the on-device model at the time.

## Limitations

- **Server tools and client tools in one turn:** if the model calls a server tool and a
  client tool in the same turn, the server tool's result is not kept. Because the server
  is stateless, the next request re-runs from the client's messages.
- **Structured output does not stream:** `json_schema` and `json_object` content arrives
  as one final chunk.
- **Approximate `usage`** for responses that end on `tool_calls` or a stop sequence, and for
  refusals, is estimated at about 4 characters per token. Completed answers report the
  model's own counts.
- **`refusal` text** is the framework's refusal description, not a model-written
  explanation.
- The on-device context is 8192 tokens, and Apple recommends at most 3–5 tools per
  request.
- Not implemented: `logprobs`, audio in or out, `n > 1`, the Responses API, embeddings,
  and legacy `functions`/`function_call`.
