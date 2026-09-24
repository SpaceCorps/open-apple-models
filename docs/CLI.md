# `oam` — `fm` with tool calls

`oam` is the command-line face of open-apple-models. It works like Apple's `fm` CLI
(macOS 27) — `respond`, `chat`, `serve`, `schema`, `available` — and adds what `fm` cannot do:
**tools**. Shell commands become tools the on-device model can call, other tools are answered by
your own program, and the server returns real `tool_calls`.

```sh
swift build -c release --product oam        # .build/release/oam
cp .build/release/oam /usr/local/bin/       # optional

oam respond --tools tools.json --tool-choice required 'What is the weather in Paris?'
```

| Command | What it does |
|---|---|
| [`oam respond`](#oam-respond) | One turn: prompt → (tool calls) → answer. Text, JSON or JSON-lines output. |
| [`oam chat`](#oam-chat) | Interactive chat with streaming and live tool calls. |
| [`oam serve`](#oam-serve) | OpenAI-compatible HTTP server whose responses contain `tool_calls`. |
| [`oam stdio`](#oam-stdio) | JSON-RPC 2.0 bridge over stdin/stdout for game engines and other languages. |
| [`oam schema convert`](#oam-schema-convert-and-oam-tools-validate) | Check a JSON Schema and see the `GenerationSchema` the model gets. |
| [`oam tools validate`](#oam-schema-convert-and-oam-tools-validate) | Check a tools file. |
| [`oam available`](#oam-available) | Model availability as JSON. |
| [`oam demo tavern`](#oam-demo-tavern) | Talk to an NPC innkeeper who uses tools (the game layer in one minute). |
| [`oam agent-readme`](#oam-agent-readme) | Operating manual for AI agents that call `oam`. |

Every command has `--help`.

## Exit codes

Stable; scripts and agents should branch on them.

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Runtime failure (generation failed, I/O error, server could not start) |
| 2 | Usage: bad flags or input files (tools, schema, transcript, image), missing tool outputs |
| 3 | Model unavailable (Apple Intelligence off, device not eligible, model downloading) |
| 4 | Guardrail violation or refusal |
| 5 | Context window (8192 tokens) exceeded |
| 6 | Rate limited |
| 10 | External tool calls pending — answer them with `--resume … --tool-output …` |

With `--json` or `--events`, errors are printed to **stderr** as
`{"error": {"code": "guardrail_violation", "message": "…"}}`; otherwise as `Error: …`.
`code` is one of `model_unavailable`, `guardrail_violation`, `refusal`, `context_size_exceeded`,
`rate_limited`, `unsupported_language`, `invalid_schema`, `tool_failed`, `cancelled`,
`invalid_request`, `generation_failed` (from the model) or `usage`, `invalid_input`, `io_error`,
`missing_tool_output`, `server_start_failed` (from the CLI).

## Tools files

A tools file holds OpenAI tool definitions — an array, or an object with a `tools` array (so the
`tools` of an OpenAI request body works as-is). Add an `"x-oam"` block to make a tool run a
command; tools without one are **external**.

```json
{"tools": [
  {"type": "function",
   "function": {
     "name": "get_weather",
     "description": "Current weather for a city.",
     "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}},
   "x-oam": {"command": ["./weather.sh", "--metric"], "timeout": 10}},
  {"type": "function",
   "function": {
     "name": "lookup_order",
     "description": "Look up an order in the shop database by id.",
     "parameters": {"type": "object", "properties": {"order_id": {"type": "string"}}, "required": ["order_id"]}}}
]}
```

`x-oam` options:

| Key | Default | |
|---|---|---|
| `command` | — | `["program", "arg", …]`, or a string run with `/bin/sh -c` |
| `timeout` | 30 | seconds; the process gets SIGTERM, then SIGKILL, and the model sees a timeout error |
| `cwd` | current directory | working directory of the command |
| `env` | — | extra environment variables, `{"NAME": "value"}` |
| `maxOutputChars` | 8000 | longer output is cut (tool output counts against the 8192-token context) |

How a command tool runs:

- The call's arguments arrive as JSON on **stdin**, and also in `$OAM_TOOL_ARGUMENTS`, with
  `$OAM_TOOL_NAME` and `$OAM_TOOL_CALL_ID`.
- **stdout** is the output. If it is a JSON object or array it is passed on as JSON.
- A **non-zero exit** becomes an error output (with stderr) that the model sees and can recover
  from — it does not abort the turn.
- A relative program path (`./weather.sh`) or `cwd` is resolved against the **tools file's
  directory**, so a tools file and its scripts can live together and be used from anywhere. Bare
  program names (`jq`, `python3`) are looked up in `PATH`.

The on-device model does best with **3–5 tools** per request and short descriptions that say
when to use the tool. `oam tools validate tools.json` checks a file.

## `oam respond`

```
oam respond [<prompt> ...] [-i <text>] [--tools <file>] [--tool-choice <choice>]
            [--max-tool-rounds <n>] [--max-tool-calls <n>] [--schema <file>] [--image <path> ...]
            [--json | --events] [--[no-]stream] [--temperature <t>] [--max-tokens <n>] [-g]
            [--save-transcript <file>] [--resume <file>] [--tool-output <id>=<value> ...]
            [--tool-error <id>=<message> ...] [--ask-tools] [--no-stdin] [-v]
```

**Prompt.** The arguments, joined with spaces. Piped standard input is appended to them (or used
alone when there are no arguments): `cat notes.txt | oam respond 'Summarize:'`. `--no-stdin`
never reads it. `--image photo.jpg` (repeatable) attaches images.

**Tools.** `--tools <file>` (above), and/or `--tool-json '<definition>'` (repeatable) for one-off inline tools:

```sh
oam respond 'How many potions do I have?' --tool-choice required \
  --tool-json '{"name":"get_potions","description":"Count potions in the inventory","parameters":{"type":"object","properties":{}}}'
# exit 10: {"status":"tool_calls","calls":[{"id":"…","name":"get_potions","arguments":{}}],"transcript":"…"}
```

`--tool-choice`:

| Value | Effect |
|---|---|
| `auto` (default) | the model decides |
| `none` | tools disabled for this turn |
| `required` | the model must call a tool on its **first** step, then answers freely |
| `explicit` | the model must either call a tool or state it needs none (a built-in `respond_directly` tool), then answers; grounds lookups reliably without forcing pointless calls on small talk |
| `<tool name>` | the model must call that tool first, then answers freely |

The small model often answers from memory in `auto` mode. When the answer must come from a tool,
force the first step with `required` or a name — oam's steering applies it to the first step only,
so it never loops. `--max-tool-rounds` (default 4) and `--max-tool-calls` (default 12) bound the
loop; after the last round the model must answer.

**Structured output.** `--schema <file>` takes a JSON Schema — including files written by
`fm schema object`, whose `x-order` property order is kept. Tools may be called first; the answer is
then schema-valid JSON. Constraints the model cannot enforce (such as `pattern`) are described to
it instead; `-v` or `oam schema convert` lists them.

**Output.**

- Default: the answer as text, streamed (`--no-stream` prints it at the end); structured answers
  are printed as indented JSON. On a terminal, tool calls and results are shown on stderr;
  `-v` also shows model steps and token usage.
- `--json`: one object on stdout:

  ```json
  {"status": "completed",
   "text": "It is 14°C with light rain in Paris.",
   "structured": {"…": "only with --schema"},
   "toolCalls": [{"call": {"id": "call_…", "name": "get_weather", "arguments": {"city": "Paris"}},
                  "output": {"temperature_c": 14, "conditions": "light rain"},
                  "isError": false, "durationSeconds": 0.02}],
   "usage": {"inputTokens": 228, "cachedInputTokens": 227, "outputTokens": 25, "totalTokens": 253},
   "steps": [{"index": 0, "completedToolRounds": 0, "toolCallingMode": "required", "enabledTools": ["get_weather"], "trimmedEntries": 0},
             {"index": 1, "completedToolRounds": 1, "toolCallingMode": "allowed", "enabledTools": ["get_weather", "lookup_order"], "trimmedEntries": 0}],
   "transcript": "/path/when/--save-transcript/was/given.json"}
  ```

- `--events`: JSON lines as the turn runs — `{"type": "modelStep", "step"}`, `{"type": "text",
  "delta", "text", "isReset"}`, `{"type": "partial", "value"}`, `{"type": "toolCallStarted",
  "call", "execution": "local"|"client"}`, `{"type": "toolCallCompleted", "record"}` — ending with
  `{"type": "completed", "response": {…the --json object…}}`, a `tool_calls` line, or
  `{"type": "error", "error": {…}}`.

**Sampling.** `--temperature 0…2`, `--max-tokens <n>` (per model step), `-g/--greedy`.

### External tools: exit code 10

When the model calls an external tool, `oam` finishes the tool round (command tools called in
the same round still run), saves the conversation and prints:

```json
{"status": "tool_calls",
 "calls": [{"id": "B3A55176-35D9-430F-AF68-C94DF6213C21", "name": "lookup_order", "arguments": {"order_id": "A17"}}],
 "transcript": "/tmp/oam-1a2b3c4d.json"}
```

and exits with **10**. Run the calls, then continue the same turn:

```sh
oam respond --resume /tmp/oam-1a2b3c4d.json \
  --tool-output 'B3A55176-35D9-430F-AF68-C94DF6213C21={"status": "shipped", "eta": "Friday"}'
# → Your order A17 has shipped and should arrive on Friday.
```

- `--tool-output <id>=<text>`, `<id>=@<file>` or `<id>=@-` (stdin); JSON objects and arrays are
  passed on as JSON. `--tool-error <id>=<message>` reports a failure the model sees.
- Every pending call needs an output (exit 2, `missing_tool_output`, otherwise).
- The continued turn may call tools again and exit 10 again: loop until exit 0. It keeps the rest of
  the turn's tool budget, and `--json` lists every tool call of the turn.
- The transcript is saved to `--save-transcript` if given, else to a temporary file.
- With `--ask-tools` on a terminal, oam asks you for each output instead (type text, `@file`, or
  `!message` for an error).

### Conversations

`--save-transcript chat.json` saves the conversation after the turn; `--resume chat.json 'next
question'` continues it with the same instructions and tools (`-i` / `--tools` override them).
The file is `{"transcript": <FoundationModels Transcript>, "modelName", "oam": {…}}` — the same
format as `fm respond --save-transcript`, so `fm` transcripts can be resumed too.

## `oam chat`

```sh
oam chat --tools tools.json -i 'You are a helpful shop assistant.'
```

Streams answers and shows each tool call and result as it happens. Command tools run on their
own; for external tools you type the output. Ctrl-C stops the current answer, Ctrl-D exits.
Commands: `/tools`, `/reset`, `/save <file>`, `/usage`, `/exit`. `--resume <file>` continues a
saved conversation; `--save-transcript <file>` saves after every turn. Also works with piped input
(`printf 'hi\n/exit\n' | oam chat`).

## `oam serve`

```sh
oam serve                                   # http://127.0.0.1:1976/v1
oam serve --port 0                          # any free port (printed)
oam serve --socket /tmp/oam.sock            # Unix socket only
oam serve --tools server-tools.json         # command tools the server runs itself
OAM_API_KEY=secret oam serve --host 0.0.0.0 --allow-origin https://example.com
```

An OpenAI Chat Completions server (`POST /v1/chat/completions`, `GET /v1/models`,
`GET /health`) for any OpenAI client. Unlike `fm serve`, a request with `tools` gets
`finish_reason: "tool_calls"` with the calls; send results back as `tool` messages. `tool_choice`
`"required"` or a named function works, as do `json_schema` responses, streaming and images.
See [SERVER.md](SERVER.md) for the details.

| Flag | |
|---|---|
| `--host`, `--port` | TCP address (default `127.0.0.1:1976`; `--port 0` picks a free port) |
| `--socket <path>` | Unix domain socket; without `--port`, the only listener |
| `--tools <file>` | server-side command tools, callable in every request, never shown to clients |
| `-i <text>` | instructions prepended to every request's system message |
| `--api-key <key>` | require `Authorization: Bearer <key>` (default `$OAM_API_KEY`) |
| `--allow-origin <origin>` | browser origins allowed (repeatable, `*` for all) |
| `--model-alias a=system` | extra model ids, e.g. `gpt-4o-mini=system`, for unmodified clients |
| `--max-concurrent <n>` | completions generated at once (default 4); the rest queue |
| `--timeout <seconds>` | per completion, including queueing (default 120) |
| `--log-level` | `debug`, `info` (default), `warning`, `error` — to stderr |

## `oam stdio`

Newline-delimited JSON-RPC 2.0 over stdin/stdout: the same protocol as the C library, for game
engines and languages that can spawn a process. stdout carries only protocol messages; logs go to
stderr (`--log-level`). At end of input, requests already sent are finished before exiting. See
[PROTOCOL.md](PROTOCOL.md) for the methods.

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | oam stdio
```

Flags: `--max-sessions`, `--tool-timeout <seconds>` (how long `tool/call` answers may take),
`--no-scripted-models`.

## `oam schema convert` and `oam tools validate`

```sh
fm schema object --name Person --string name --integer age | oam schema convert -
oam schema convert person.json --json     # {"warnings": [...], "generationSchema": {...}}
oam tools validate tools.json             # each tool: command or external, arguments, warnings
```

Both exit 2 when the input cannot be used, naming the file and the JSON path.

## `oam available`

```sh
$ oam available
{"available": true, "model": "system", "contextSize": 8192, "variant": "AFM 3 Core Advanced",
 "supportedLanguages": ["da", "de", "en", …]}
```

Exit 3 when unavailable, with `reason`: `device_not_eligible`, `apple_intelligence_not_enabled`,
`model_not_ready` or `unknown`. `--compact` prints one line.

## `oam demo tavern`

A one-minute tour of the game layer (`OpenAppleModelsGame`): Mira, the innkeeper of the
Sleeping Stag, is an `NPC` with a menu tool, a till that takes your gold from a `WorldState`, and
a relationship she adjusts with a memory tool. Type what you say, or the number of a suggested
reply; an empty line leaves. At closing time a `DecisionEngine` decides what she does about you.
`--auto` (or no terminal) plays canned lines; `--line <text>` scripts your own.

## `oam agent-readme`

Prints a compact manual for AI agents (commands, exit codes, JSON shapes, the exit-10 loop);
`--json` for a structured version. Point your coding agent at it.

## Testing without Apple Intelligence: `OAM_SCRIPT`

Set `OAM_SCRIPT` to a JSON file of model steps and every command (`respond`, `chat`, `serve`,
`stdio`, `available`) runs on a deterministic scripted model instead — for CI and for developing
integrations on machines without the model. Each model inference plays the next step:

```json
[
  {"toolCalls": [{"name": "lookup_order", "arguments": {"order_id": "A17"}}]},
  {"text": "Your order A17 has shipped."}
]
```

Steps: `{"text"}`, `{"toolCalls": [{"name", "arguments"?, "id"?}]}`, `{"json"}` (structured
output), `{"template"}` (with `{prompt}`, `{toolOutput}`, `{toolOutputs}` from the current turn),
`{"error": "<code>"}` (e.g. `guardrail_violation`), each with optional `"delayMs"`. The object form
`{"steps": [...], "fallback": step}` sets the step used when the script runs out. It is the
bridge's scripted-model format (see [PROTOCOL.md](PROTOCOL.md)).

`scripts/smoke-test.sh` exercises every interface this way, then repeats the main flows against
the real model (skip that part with `OAM_SKIP_LIVE=1`).

---

# Recipes

## Shell commands as tools

```sh
#!/bin/sh
# weather.sh — arguments JSON on stdin, answer on stdout
city=$(jq -r .city)
curl -s "https://wttr.in/$(printf %s "$city" | jq -sRr @uri)?format=j1" \
  | jq '{city: "'"$city"'", temperature_c: .current_condition[0].temp_C, conditions: .current_condition[0].weatherDesc[0].value}'
```

A tool can be any program; a string `command` runs through the shell:

```json
[{"type": "function",
  "function": {"name": "disk_usage", "description": "Free disk space on this Mac.", "parameters": {"type": "object", "properties": {}}},
  "x-oam": {"command": "df -h / | tail -1"}},
 {"type": "function",
  "function": {"name": "list_files", "description": "List files in a folder of the project.",
               "parameters": {"type": "object", "properties": {"folder": {"type": "string"}}, "required": ["folder"]}},
  "x-oam": {"command": "ls -1 \"$(echo \"$OAM_TOOL_ARGUMENTS\" | jq -r .folder)\" | head -50", "cwd": "."}}]
```

Tool commands run with your permissions. Only give the model tools you would be happy for it to
call with any arguments.

## Piping

```sh
git diff | oam respond 'Write a one-line commit message for this diff:'
pbpaste | oam respond --schema contact.json --json 'Extract the contact details:' | jq .structured
oam respond --json 'Three names for a cat' | jq -r .text
for f in *.txt; do oam respond --no-stream --schema tags.json "Tag this: $(cat "$f")"; done
```

## Python: the exit-10 tool loop

No dependencies; your Python functions are the tools.

```python
import json
import subprocess

def lookup_order(order_id):
    return {"order_id": order_id, "status": "shipped", "eta": "Friday"}

TOOLS = {"lookup_order": lookup_order}

def ask(prompt, tools_file="tools.json"):
    command = ["oam", "respond", "--json", "--tools", tools_file, "--tool-choice", "required", prompt]
    while True:
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            return json.loads(result.stdout)
        if result.returncode != 10:
            raise RuntimeError(json.loads(result.stderr)["error"])
        pending = json.loads(result.stdout)            # {"status": "tool_calls", "calls": [...], "transcript": ...}
        command = ["oam", "respond", "--json", "--resume", pending["transcript"]]
        for call in pending["calls"]:
            try:
                output = json.dumps(TOOLS[call["name"]](**call["arguments"]))
                command += ["--tool-output", f"{call['id']}={output}"]
            except Exception as error:
                command += ["--tool-error", f"{call['id']}={error}"]

print(ask("Where is my order A17?")["text"])
```

For many requests, run `oam serve` once and use the `openai` package instead:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:1976/v1", api_key="unused")
response = client.chat.completions.create(
    model="system",
    messages=[{"role": "user", "content": "Where is my order A17?"}],
    tools=[{"type": "function", "function": {"name": "lookup_order", "description": "Look up an order by id.",
            "parameters": {"type": "object", "properties": {"order_id": {"type": "string"}}, "required": ["order_id"]}}}],
    tool_choice="required",
)
print(response.choices[0].message.tool_calls)   # a real tool call
```

## Node.js: a JSON-RPC session over stdio

```js
import { spawn } from "node:child_process";
import readline from "node:readline";

const oam = spawn("oam", ["stdio"], { stdio: ["pipe", "pipe", "inherit"] });
const waiting = new Map();
let nextId = 1;
const send = (message) => oam.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
const call = (method, params) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    waiting.set(id, { resolve, reject });
    send({ id, method, params });
  });

// Your game's tools. The bridge sends a tool/call request when the model uses one.
const tools = {
  open_gate: async ({ gate }) => ({ opened: gate === "north", gate }),
};

readline.createInterface({ input: oam.stdout }).on("line", async (line) => {
  const message = JSON.parse(line);
  if (message.method === "tool/call") {
    const { name, arguments: args } = message.params.call;
    try {
      send({ id: message.id, result: { output: await tools[name](args) } });
    } catch (error) {
      send({ id: message.id, result: { output: String(error), isError: true } });
    }
  } else if (message.method === "session/event") {
    const { event } = message.params;
    if (event.type === "text") process.stdout.write(event.delta);
  } else if (waiting.has(message.id)) {
    const { resolve, reject } = waiting.get(message.id);
    waiting.delete(message.id);
    message.error ? reject(new Error(message.error.message)) : resolve(message.result);
  }
});

await call("initialize", { client: { name: "node-example", version: "1.0" } });
await call("session/create", {
  session: "guard",
  instructions: "You are a castle guard in a game. Use your tools. Reply in one sentence.",
  tools: [{
    name: "open_gate",
    description: "Ask the game to open a named gate.",
    parameters: { type: "object", properties: { gate: { type: "string" } }, required: ["gate"] },
  }],
  options: { toolChoice: "required" },
});
const result = await call("session/respond", { session: "guard", prompt: "Open the north gate, please.", stream: true });
console.log(`\n(${result.toolCalls.length} tool call)`);
await call("shutdown");
```

## Game engines over stdio

`oam stdio` is the quickest way to prototype NPCs from any engine that can spawn a process
(Godot's `OS.execute_with_pipe`, Unreal's `FPlatformProcess::CreateProc` with pipes, a Unity
editor script, a Lua or Python game): one long-lived process, many sessions (one per NPC), and
the engine answers `tool/call` requests with game state. The messages are identical to the C
library's, so a prototype moves to the in-process library (`libOpenAppleModelsFFI`, see
[bindings/README.md](../bindings/README.md)) without protocol changes.

1. Spawn `oam stdio`; send `initialize`.
2. `session/create` per character, with instructions, tools (the engine executes them) and
   `options.toolChoice: "required"` for characters that must check game state before speaking.
3. `session/respond` with `"stream": true`; show `text` events as a typewriter effect.
4. Answer each `tool/call` with `{"output": …}` (or `"isError": true`). Calls of one round can
   arrive in parallel; answer each by its id.
5. Save with `session/transcript`, restore with `session/create {"history": …}`.

During development, `OAM_SCRIPT=npc-steps.json oam stdio` gives the engine deterministic replies
and tool calls without Apple Intelligence.
