#!/usr/bin/env bash
# Smoke test for the `oam` CLI.
#
# Scripted section (always): runs every interface against the deterministic
# scripted model (OAM_SCRIPT), so it passes on any Mac with the toolchain.
# Live section: the same flows against the on-device model. Skipped with
# OAM_SKIP_LIVE=1, or automatically when the model is unavailable.
#
#   scripts/smoke-test.sh                 # build + scripted + live
#   OAM_SKIP_LIVE=1 scripts/smoke-test.sh # scripted only
#   OAM_BIN=/path/to/oam scripts/smoke-test.sh   # test an existing binary
#
# Needs: swift, curl, python3 (for JSON checks and the JSON-RPC client).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_PATH="${OAM_BUILD_PATH:-$ROOT/.build-cli}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/oam-smoke.XXXXXX")"
SERVER_PID=""
PASSED=0
FAILED=0
SKIPPED=0

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; RESET=""
fi

section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }
pass() { PASSED=$((PASSED + 1)); printf '  %sok%s    %s %s\n' "$GREEN" "$RESET" "$1" "$DIM${2:-}$RESET"; }
fail() { FAILED=$((FAILED + 1)); printf '  %sFAIL%s  %s\n        %s\n' "$RED" "$RESET" "$1" "${2:-}"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  %sskip%s  %s\n' "$DIM" "$RESET" "$1"; }

# Seconds since $1 (from `now`), one decimal.
now() { python3 -c 'import time; print(time.time())'; }
since() { python3 -c "import time; print('(%.1fs)' % (time.time() - $1))"; }

# json <file-or-string> <python expression over d>: prints the result.
json() {
    local source="$1" expr="$2"
    if [[ -f "$source" ]]; then
        python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($expr)" "$source"
    else
        python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($expr)" "$source"
    fi
}

# expect_exit <name> <expected-code> <actual-code> [detail]
expect_exit() {
    if [[ "$3" == "$2" ]]; then pass "$1" "${5:-}"; else fail "$1" "expected exit $2, got $3. ${4:-}"; fi
}

for tool in curl python3; do
    command -v "$tool" >/dev/null || { echo "smoke-test: '$tool' is required" >&2; exit 2; }
done

# --------------------------------------------------------------------------
section "Build"
if [[ -n "${OAM_BIN:-}" ]]; then
    OAM="$OAM_BIN"
    pass "using $OAM"
else
    start=$(now)
    if swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" --product oam >"$WORK/build.log" 2>&1; then
        OAM="$BUILD_PATH/debug/oam"
        warnings=$(grep -E "Sources/oam/.*warning:" "$WORK/build.log" | wc -l | tr -d ' ')
        if [[ "$warnings" == "0" ]]; then pass "swift build --product oam" "$(since "$start")"; else fail "oam builds without warnings" "$warnings warnings"; fi
    else
        tail -30 "$WORK/build.log"
        fail "swift build --product oam" "see output above"
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# Fixtures
cd "$WORK"
cat > weather.sh <<'EOF'
#!/bin/sh
# A command tool: arguments JSON on stdin, output on stdout.
city=$(sed -n 's/.*"city" *: *"\([^"]*\)".*/\1/p')
[ -n "$city" ] || { echo "missing city" >&2; exit 3; }
printf '{"city": "%s", "temperature_c": 14, "conditions": "light rain", "tool": "%s"}\n' "$city" "$OAM_TOOL_NAME"
EOF
chmod +x weather.sh
cat > tools.json <<'EOF'
{"tools": [
  {"type": "function",
   "function": {"name": "get_weather", "description": "Current weather for a city.",
                "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}},
   "x-oam": {"command": ["./weather.sh"], "timeout": 5}},
  {"type": "function",
   "function": {"name": "lookup_order", "description": "Look up an order by id in the shop database.",
                "parameters": {"type": "object", "properties": {"order_id": {"type": "string"}}, "required": ["order_id"]}}}
]}
EOF
# A schema in the shape `fm schema object` writes (x-order, $defs, $ref).
cat > person.json <<'EOF'
{"title": "Person", "type": "object", "x-order": ["name", "age", "address"],
 "$defs": {"Address": {"title": "Address", "type": "object", "additionalProperties": false,
                       "required": ["street"], "x-order": ["street"], "properties": {"street": {"type": "string"}}}},
 "properties": {"address": {"$ref": "#/$defs/Address"}, "age": {"type": "integer", "description": "Age in years"}, "name": {"type": "string"}},
 "additionalProperties": false, "required": ["name", "age", "address"]}
EOF
echo '[{"toolCalls": [{"name": "get_weather", "arguments": {"city": "Paris"}}]}, {"template": "Weather: {toolOutput}"}]' > weather-steps.json
echo '[{"toolCalls": [{"name": "lookup_order", "arguments": {"order_id": "A17"}}, {"name": "get_weather", "arguments": {"city": "Oslo"}}]}]' > external-steps.json
echo '[{"text": "Your order A17 has shipped."}]' > answer-steps.json
echo '[{"json": {"name": "Gorm", "age": 51, "address": {"street": "Forge Lane 1"}}}]' > json-steps.json
echo '[{"error": "guardrail_violation"}]' > guardrail-steps.json
echo '[{"error": "context_size_exceeded"}]' > context-steps.json
echo '[{"error": "rate_limited"}, {"error": "rate_limited"}]' > rate-steps.json
echo '[{"toolCalls": [{"name": "open_gate", "arguments": {"gate": "north"}}]}, {"template": "Gate: {toolOutput}"}]' > gate-steps.json
echo '[{"toolCalls": [{"name": "get_weather", "arguments": {"city": "Rome"}}]}, {"template": "Rome: {toolOutput}"}]' > chat-steps.json

cat > rpc_client.py <<'EOF'
# Minimal JSON-RPC client for `oam stdio`: one turn whose tool the client executes.
import json, subprocess, sys
proc = subprocess.Popen([sys.argv[1], "stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
def send(message):
    proc.stdin.write(json.dumps(message) + "\n"); proc.stdin.flush()
send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"client": {"name": "smoke", "version": "1"}}})
send({"jsonrpc": "2.0", "id": 2, "method": "session/create", "params": {
    "session": "guard", "instructions": "You are a castle guard in a game. Use your tools. Reply in one sentence.",
    "tools": [{"name": "open_gate", "description": "Ask the game to open a named gate.",
               "parameters": {"type": "object", "properties": {"gate": {"type": "string"}}, "required": ["gate"]}}],
    "options": {"toolChoice": "required"}}})
send({"jsonrpc": "2.0", "id": 3, "method": "session/respond", "params": {"session": "guard", "prompt": "Please open the north gate.", "stream": True}})
result, tool_calls, events = None, 0, 0
for line in proc.stdout:
    message = json.loads(line)
    if message.get("method") == "tool/call":
        tool_calls += 1
        gate = message["params"]["call"]["arguments"].get("gate", "?")
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"output": {"opened": True, "gate": gate}}})
    elif message.get("method") == "session/event":
        events += 1
    elif message.get("id") == 3:
        result = message
        break
send({"jsonrpc": "2.0", "id": 4, "method": "shutdown"})
for line in proc.stdout:
    if json.loads(line).get("id") == 4:
        break
proc.stdin.close()
code = proc.wait(timeout=15)
print(json.dumps({"text": (result or {}).get("result", {}).get("text"), "error": (result or {}).get("error"),
                  "toolCalls": tool_calls, "events": events, "exit": code}))
EOF

# --------------------------------------------------------------------------
section "respond (scripted model)"

out=$(OAM_SCRIPT=weather-steps.json "$OAM" respond --tools tools.json 'Weather in Paris?' 2>/dev/null); code=$?
if [[ $code == 0 && "$out" == *'"temperature_c":14'* && "$out" == *'"tool":"get_weather"'* ]]; then
    pass "command tool runs with arguments on stdin and OAM_TOOL_NAME"
else fail "command tool" "exit $code, output: $out"; fi

out=$(OAM_SCRIPT=weather-steps.json "$OAM" respond --tools tools.json --json 'Weather in Paris?'); code=$?
if [[ $code == 0 ]] && [[ "$(json "$out" 'd["status"], d["toolCalls"][0]["call"]["name"], d["toolCalls"][0]["output"]["city"], len(d["steps"])')" == "completed get_weather Paris 2" ]]; then
    pass "--json result has status, toolCalls, usage, steps"
else fail "--json result" "exit $code, output: $out"; fi

out=$(OAM_SCRIPT=weather-steps.json "$OAM" respond --tools tools.json --events 'Weather in Paris?'); code=$?
last=$(printf '%s\n' "$out" | tail -1)
if [[ $code == 0 ]] && [[ "$(json "$last" 'd["type"]')" == "completed" ]] && [[ "$out" == *'"type":"toolCallCompleted"'* ]]; then
    pass "--events streams JSON lines ending with completed" "($(printf '%s\n' "$out" | wc -l | tr -d ' ') events)"
else fail "--events" "exit $code, output: $out"; fi

out=$(echo 'Weather in Paris?' | OAM_SCRIPT=weather-steps.json "$OAM" respond --tools tools.json --no-stream 2>/dev/null); code=$?
if [[ $code == 0 && "$out" == Weather:* ]]; then pass "prompt from stdin"; else fail "prompt from stdin" "exit $code, output: $out"; fi

out=$(OAM_SCRIPT=json-steps.json "$OAM" respond --schema person.json --json 'Invent a blacksmith'); code=$?
if [[ $code == 0 ]] && [[ "$(json "$out" 'list(d["structured"].keys())')" == "['name', 'age', 'address']" ]]; then
    pass "--schema (fm-style file): structured output in x-order"
else fail "--schema" "exit $code, output: $out"; fi

# External tools: exit 10, then resume.
out=$(OAM_SCRIPT=external-steps.json "$OAM" respond --tools tools.json --tool-choice required --save-transcript pending.json 'Where is order A17, and the weather in Oslo?'); code=$?
expect_exit "external tool call exits 10" 10 $code "output: $out"
if [[ $code == 10 ]]; then
    calls=$(json "$out" '" ".join(c["id"] + ":" + c["name"] for c in d["calls"])')
    transcript=$(json "$out" 'd["transcript"]')
    if [[ "$(json "$out" 'd["status"]')" == "tool_calls" && "$calls" == *":lookup_order" && "$calls" != *get_weather* && -f "$transcript" ]]; then
        pass "status JSON lists only the external call; the command tool already ran"
    else fail "tool_calls status" "$out"; fi
    call_id=${calls%%:*}

    out=$(OAM_SCRIPT=answer-steps.json "$OAM" respond --resume pending.json --json 2>&1); code=$?
    if [[ $code == 2 && "$out" == *missing_tool_output* ]]; then pass "resume without outputs: exit 2 missing_tool_output"; else fail "missing output" "exit $code: $out"; fi

    echo '{"order_id": "A17", "status": "shipped"}' > order.json
    out=$(OAM_SCRIPT=answer-steps.json "$OAM" respond --resume pending.json --tool-output "$call_id=@order.json" --save-transcript done.json --json); code=$?
    if [[ $code == 0 ]] && [[ "$(json "$out" 'd["text"], len(d["toolCalls"])')" == "Your order A17 has shipped. 2" ]]; then
        pass "--resume --tool-output continues the turn" "(toolCalls include both calls)"
    else fail "resume" "exit $code: $out"; fi
    # The continued transcript answers every call of the round, with matching ids.
    check=$(python3 - "$call_id" <<'EOF'
import json, sys
entries = json.load(open("done.json"))["transcript"]["transcript"]["entries"]
calls = [c["id"] for e in entries for c in e.get("toolCalls", [])]
outputs = [e["id"] for e in entries if e.get("role") == "tool"]
print("ok" if calls == outputs and sys.argv[1] in outputs and len(outputs) == 2 else f"calls={calls} outputs={outputs}")
EOF
)
    if [[ "$check" == ok ]]; then pass "saved transcript: tool outputs paired with call ids"; else fail "transcript pairing" "$check"; fi

    out=$(OAM_SCRIPT=answer-steps.json "$OAM" respond --resume done.json --json 'And when does it arrive?'); code=$?
    expect_exit "a completed transcript resumes with a new prompt" 0 $code "$out"
fi

# A resumed turn may stop for tools again; budgets and records carry over.
echo '[{"toolCalls": [{"name": "lookup_order", "arguments": {"order_id": "B2"}}]}]' > second-round-steps.json
out=$(OAM_SCRIPT=external-steps.json "$OAM" respond --tools tools.json --save-transcript multi.json 'Orders A17 and B2?'); code=$?
if [[ $code == 10 ]]; then
    first_id=$(json "$out" 'd["calls"][0]["id"]')
    out=$(OAM_SCRIPT=second-round-steps.json "$OAM" respond --resume multi.json --tool-output "$first_id=shipped" --save-transcript multi.json); code=$?
    if [[ $code == 10 && "$(json multi.json 'd["oam"]["pending"]["roundsUsed"], d["oam"]["pending"]["callsUsed"]')" == "2 3" ]]; then
        second_id=$(json "$out" 'd["calls"][0]["id"]')
        out=$(OAM_SCRIPT=answer-steps.json "$OAM" respond --resume multi.json --tool-output "$second_id=delayed" --json); code=$?
        if [[ $code == 0 && "$(json "$out" 'len(d["toolCalls"])')" == 3 ]]; then
            pass "a resumed turn can stop for tools again (exit 10 → 10 → 0)"
        else fail "second resume" "exit $code: $out"; fi
    else fail "second tool round" "exit $code: $out"; fi
else fail "multi-round setup" "exit $code: $out"; fi

section "respond errors and exit codes"
OAM_SCRIPT=guardrail-steps.json "$OAM" respond --json hi >/dev/null 2>"$WORK/err"; code=$?
expect_exit "guardrail violation → 4" 4 $code "$(cat "$WORK/err")"
if [[ "$(json "$(cat "$WORK/err")" 'd["error"]["code"]')" == "guardrail_violation" ]]; then pass "--json error on stderr: {error:{code,message}}"; else fail "json error" "$(cat "$WORK/err")"; fi
OAM_SCRIPT=context-steps.json "$OAM" respond hi >/dev/null 2>&1; expect_exit "context exceeded → 5" 5 $?
OAM_SCRIPT=rate-steps.json "$OAM" respond hi >/dev/null 2>&1; expect_exit "rate limited (after one retry) → 6" 6 $?
OAM_SCRIPT=weather-steps.json "$OAM" respond --tool-choice nope --tools tools.json hi >/dev/null 2>&1; expect_exit "unknown --tool-choice → 2" 2 $?
OAM_SCRIPT=weather-steps.json "$OAM" respond --bogus-flag hi >/dev/null 2>&1; expect_exit "unknown flag → 2" 2 $?
OAM_SCRIPT=weather-steps.json "$OAM" respond --no-stdin </dev/null >/dev/null 2>&1; expect_exit "no prompt → 2" 2 $?
echo '[{"name": "x", "x-oam": {"command": ["./missing.sh"]}}]' > bad-tools.json
OAM_SCRIPT=weather-steps.json "$OAM" respond --tools bad-tools.json hi >/dev/null 2>&1; expect_exit "tools file with a missing command → 2" 2 $?
out=$(OAM_SCRIPT=weather-steps.json "$OAM" respond --events --tools bad-tools.json hi 2>/dev/null); code=$?
if [[ $code == 2 && "$(json "$out" 'd["type"]')" == "error" ]]; then pass "--events ends with an error event"; else fail "events error" "exit $code: $out"; fi

# --------------------------------------------------------------------------
section "schema, tools, available, agent-readme"
out=$("$OAM" schema convert person.json --json); code=$?
if [[ $code == 0 && "$(json "$out" 'd["generationSchema"]["x-order"]')" == "['name', 'age', 'address']" ]]; then pass "schema convert keeps fm's x-order"; else fail "schema convert" "exit $code: $out"; fi
echo '{"type": "object", "properties": {"code": {"type": "string", "pattern": "^[A-Z]{3}$"}}}' > pattern.json
out=$("$OAM" schema convert pattern.json --json); code=$?
if [[ $code == 0 && "$out" == *"not enforced"* ]]; then pass "schema convert reports unenforceable constraints"; else fail "schema warnings" "$out"; fi
echo '{"type": "strange"}' > broken.json
"$OAM" schema convert broken.json >/dev/null 2>&1; expect_exit "invalid schema → 2" 2 $?
out=$("$OAM" tools validate tools.json --json); code=$?
if [[ $code == 0 && "$(json "$out" '[t["execution"] for t in d["tools"]]')" == "['command', 'external']" ]]; then pass "tools validate"; else fail "tools validate" "exit $code: $out"; fi
"$OAM" tools validate bad-tools.json >/dev/null 2>&1; expect_exit "tools validate rejects a missing command → 2" 2 $?
out=$(OAM_SCRIPT=weather-steps.json "$OAM" available --compact); code=$?
if [[ $code == 0 && "$(json "$out" 'd["available"], d["model"]')" == "True scripted" ]]; then pass "available (scripted)"; else fail "available" "$out"; fi
out=$("$OAM" agent-readme --json); code=$?
if [[ $code == 0 && "$(json "$out" 'len(d["exitCodes"])')" == "8" ]]; then pass "agent-readme --json"; else fail "agent-readme" "$out"; fi

# --------------------------------------------------------------------------
section "chat (piped)"
out=$(printf 'Weather in Rome?\n/tools\n/save chat.json\n/exit\n' | OAM_SCRIPT=chat-steps.json "$OAM" chat --tools tools.json 2>&1); code=$?
if [[ $code == 0 && "$out" == *'Rome: {"city":"Rome"'* && "$out" == *"lookup_order"* && -f chat.json ]]; then pass "chat: streamed turn with a tool, /tools, /save"; else fail "chat" "exit $code: $out"; fi

# --------------------------------------------------------------------------
section "serve (scripted model)"
start_server() {  # start_server <log-prefix> [env...]
    local prefix="$1"; shift
    env "$@" "$OAM" serve --port 0 --log-level warning >"$prefix.out" 2>"$prefix.err" &
    SERVER_PID=$!
    for _ in $(seq 1 100); do
        grep -q "listening on http" "$prefix.out" 2>/dev/null && break
        sleep 0.1
    done
    BASE=$(grep -o 'http://[^ ]*/v1' "$prefix.out" | head -1)
}
stop_server() {
    kill -INT "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID"; local code=$?; SERVER_PID=""; return $code
}
TOOLS_JSON='[{"type":"function","function":{"name":"get_weather","description":"Current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'
server_loop() {  # server_loop <label>: tool_calls round trip against $BASE
    local label="$1" start first call_id second
    start=$(now)
    first=$(curl -s "$BASE/chat/completions" -H 'Content-Type: application/json' \
        -d "{\"model\":\"system\",\"tool_choice\":\"required\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Paris?\"}],\"tools\":$TOOLS_JSON}")
    if [[ "$(json "$first" 'd["choices"][0]["finish_reason"]')" != "tool_calls" ]]; then fail "$label: first request returns tool_calls" "$first"; return; fi
    call_id=$(json "$first" 'd["choices"][0]["message"]["tool_calls"][0]["id"]')
    local arguments
    arguments=$(json "$first" 'json.dumps(d["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"])')
    pass "$label: tool_choice required → finish_reason tool_calls" "$(since "$start")"
    start=$(now)
    second=$(curl -s "$BASE/chat/completions" -H 'Content-Type: application/json' -d "{\"model\":\"system\",\"messages\":[
        {\"role\":\"user\",\"content\":\"What is the weather in Paris?\"},
        {\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"$call_id\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":$arguments}}]},
        {\"role\":\"tool\",\"tool_call_id\":\"$call_id\",\"content\":\"{\\\"temperature_c\\\": 14, \\\"conditions\\\": \\\"light rain\\\"}\"}],
        \"tools\":$TOOLS_JSON}")
    if [[ "$(json "$second" 'd["choices"][0]["finish_reason"]')" == "stop" ]]; then
        pass "$label: tool result → answer" "$(since "$start") $(json "$second" 'repr(d["choices"][0]["message"]["content"][:80])')"
    else fail "$label: tool result → answer" "$second"; fi
}
echo '[{"toolCalls": [{"name": "get_weather", "arguments": {"city": "Paris"}}]}, {"text": "It is 14°C and raining in Paris."}]' > serve-steps.json
start_server "$WORK/serve" OAM_SCRIPT="$WORK/serve-steps.json"
if [[ -n "$BASE" ]]; then
    pass "serve --port 0 prints its URL" "($BASE)"
    health=$(curl -s -o /dev/null -w '%{http_code}' "${BASE%/v1}/health")
    [[ "$health" == 200 ]] && pass "GET /health → 200" || fail "health" "$health"
    server_loop "serve"
    stop_server; expect_exit "serve stops cleanly on SIGINT" 0 $?
else
    fail "serve starts" "$(cat "$WORK/serve.err")"; stop_server
fi

# --------------------------------------------------------------------------
section "stdio JSON-RPC (scripted model)"
out=$(OAM_SCRIPT=gate-steps.json python3 rpc_client.py "$OAM" 2>&1); code=$?
if [[ $code == 0 ]] && [[ "$(json "$out" 'd["toolCalls"], d["exit"], "opened" in (d["text"] or "")')" == "1 0 True" ]]; then
    pass "initialize → session/create → session/respond with a tool/call round trip → shutdown" "($(json "$out" 'd["events"]') events)"
else fail "stdio round trip" "$out"; fi
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping"}' '{"jsonrpc":"2.0","id":2,"method":"nope"}' | OAM_SCRIPT=gate-steps.json "$OAM" stdio 2>/dev/null); code=$?
if [[ $code == 0 && "$out" == *'"id":1,"result":{}'* && "$out" == *'-32601'* ]]; then pass "stdio answers piped requests, then exits at end of input"; else fail "stdio pipe" "exit $code: $out"; fi

# --------------------------------------------------------------------------
section "Live (on-device model)"
if [[ "${OAM_SKIP_LIVE:-}" == 1 ]]; then
    skip "OAM_SKIP_LIVE=1"
elif ! "$OAM" available --compact >"$WORK/available.json" 2>&1; then
    skip "model unavailable: $(cat "$WORK/available.json")"
else
    pass "model available" "($(json "$WORK/available.json" 'd.get("variant")'), context $(json "$WORK/available.json" 'd["contextSize"]'))"

    start=$(now)
    out=$("$OAM" respond --tools tools.json --tool-choice get_weather --json "What's the weather in Paris right now?"); code=$?
    if [[ $code == 0 ]] && [[ "$(json "$out" 'd["toolCalls"][0]["call"]["name"]')" == get_weather ]]; then
        pass "command tool (forced)" "$(since "$start") $(json "$out" 'repr(d["text"][:90])')"
    else fail "live command tool" "exit $code: $out"; fi

    start=$(now)
    out=$("$OAM" respond --tools tools.json --tool-choice lookup_order --save-transcript live.json 'Where is my order A17?'); code=$?
    if [[ $code == 10 ]]; then
        pass "external tool → exit 10" "$(since "$start") $(json "$out" 'd["calls"][0]["name"] + " " + json.dumps(d["calls"][0]["arguments"])')"
        call_id=$(json "$out" 'd["calls"][0]["id"]')
        start=$(now)
        out=$("$OAM" respond --resume live.json --tool-output "$call_id={\"order_id\":\"A17\",\"status\":\"shipped\",\"carrier\":\"DHL\",\"eta\":\"Friday\"}" --json); code=$?
        if [[ $code == 0 ]]; then pass "resume with the tool output" "$(since "$start") $(json "$out" 'repr(d["text"][:90])')"; else fail "live resume" "exit $code: $out"; fi
    else fail "live external tool" "exit $code: $out"; fi

    start=$(now)
    out=$("$OAM" respond --tools tools.json --tool-choice get_weather --schema person.json --json 'Invent a person who lives in Oslo; check the weather there first.'); code=$?
    if [[ $code == 0 ]] && [[ "$(json "$out" 'sorted(d["structured"].keys())')" == "['address', 'age', 'name']" ]]; then
        pass "tools + structured output" "$(since "$start") $(json "$out" 'json.dumps(d["structured"])')"
    else fail "live schema + tools" "exit $code: $out"; fi

    start_server "$WORK/live-serve"
    if [[ -n "$BASE" ]]; then server_loop "live serve"; stop_server; else fail "live serve starts" "$(cat "$WORK/live-serve.err")"; stop_server; fi

    start=$(now)
    out=$(python3 rpc_client.py "$OAM" 2>&1); code=$?
    if [[ $code == 0 ]] && [[ "$(json "$out" 'd["toolCalls"] >= 1 and d["exit"] == 0')" == True ]]; then
        pass "stdio session with a tool/call" "$(since "$start") $(json "$out" 'repr((d["text"] or "")[:90])')"
    else fail "live stdio" "$out"; fi
fi

# --------------------------------------------------------------------------
printf '\n%s%d passed%s, %s%d failed%s, %d skipped\n' "$GREEN" "$PASSED" "$RESET" "$([[ $FAILED -gt 0 ]] && echo "$RED")" "$FAILED" "$RESET" "$SKIPPED"
[[ $FAILED == 0 ]]
