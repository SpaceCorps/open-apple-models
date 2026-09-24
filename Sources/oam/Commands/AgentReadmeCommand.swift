import ArgumentParser
import Foundation
import OpenAppleModels

/// `oam agent-readme`: an operating manual for AI agents driving the CLI.
struct AgentReadmeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-readme",
        abstract: "Print the operating manual for AI agents: commands, exit codes and JSON shapes.")

    @Flag(help: "Print the manual as JSON.")
    var json = false

    func run() async throws {
        if json {
            Console.outJSON(AgentManual.json, pretty: Console.stdoutIsTerminal)
        } else {
            Console.out(AgentManual.markdown)
        }
    }
}

/// The content of `oam agent-readme`, shared by the Markdown and JSON forms.
enum AgentManual {
    static let exitCodes: [(code: Int32, name: String, meaning: String)] = [
        (ExitStatus.success, "ok", "Success."),
        (ExitStatus.failure, "error", "Generation failed, I/O error, or another runtime failure."),
        (ExitStatus.usage, "usage", "Invalid flags or input files (tools, schema, transcript, image), or missing tool outputs."),
        (ExitStatus.modelUnavailable, "model_unavailable", "Apple Intelligence is off, the device is not eligible, or the model is downloading."),
        (ExitStatus.blocked, "guardrail_or_refusal", "The on-device guardrails blocked the input or output, or the model refused. Rephrase."),
        (ExitStatus.contextExceeded, "context_size_exceeded", "The conversation exceeds the 8192-token context window. Start a new transcript."),
        (ExitStatus.rateLimited, "rate_limited", "The system rate-limited the request. Retry later."),
        (ExitStatus.toolCallsPending, "tool_calls", "External tool calls are pending: run them, then resume with --tool-output."),
    ]

    static let commands: [(usage: String, summary: String)] = [
        ("oam respond [prompt] [--tools f] [--tool-choice c] [--schema f] [--json|--events]", "One turn with tools. Prompt from arguments and/or piped stdin."),
        ("oam respond --resume f --tool-output id=value ...", "Continue after exit code 10 with the outputs of the pending external calls."),
        ("oam chat [--tools f] [--resume f]", "Interactive REPL (humans; not for agents)."),
        ("oam serve [--port n] [--tools f]", "OpenAI-compatible HTTP server whose responses contain real tool_calls."),
        ("oam stdio", "JSON-RPC 2.0 bridge over stdin/stdout (newline-delimited), see docs/PROTOCOL.md."),
        ("oam schema convert f [--json]", "Check a JSON Schema: warnings and the GenerationSchema the model sees."),
        ("oam tools validate f [--json]", "Check a tools file."),
        ("oam available [--compact]", "Model availability JSON; exit 3 when unavailable."),
        ("oam demo tavern", "Interactive game-layer demo."),
    ]

    static var json: JSONValue {
        [
            "tool": "oam",
            "version": .string(OAM.version),
            "commands": .array(commands.map { ["usage": .string($0.usage), "summary": .string($0.summary)] }),
            "exitCodes": .array(exitCodes.map { ["code": .number(Double($0.code)), "name": .string($0.name), "meaning": .string($0.meaning)] }),
            "shapes": [
                "completed": #"{"status":"completed","text":string,"structured"?:any,"toolCalls":[{"call":{"id","name","arguments"},"output":any,"isError":bool,"durationSeconds":number}],"usage":{"inputTokens","cachedInputTokens","outputTokens","totalTokens"},"steps":[{"index","completedToolRounds","toolCallingMode","enabledTools","trimmedEntries"}],"transcript"?:path,"warnings"?:[string]}"#,
                "toolCallsPending": #"{"status":"tool_calls","calls":[{"id","name","arguments"}],"transcript":path}"#,
                "error": #"{"error":{"code":string,"message":string}} (stderr)"#,
                "events": #"JSON lines: {"type":"modelStep"|"text"|"partial"|"toolCallStarted"|"toolCallCompleted", ...}, then {"type":"completed","response":<completed>} | {"type":"tool_calls",...} | {"type":"error","error":{...}}"#,
                "toolsFile": #"[{"type":"function","function":{"name","description","parameters"},"x-oam"?:{"command":[argv]|"sh string","timeout"?:seconds,"cwd"?:dir,"env"?:{},"maxOutputChars"?:n}}] or {"tools":[...]}"#,
            ],
            "environment": [
                "OAM_SCRIPT": "Path to scripted model steps (JSON) to run without Apple Intelligence.",
                "OAM_API_KEY": "Default --api-key for oam serve.",
                "NO_COLOR": "Disable ANSI colors.",
            ],
            "limits": [
                "contextTokens": 8192,
                "recommendedToolsPerRequest": "3-5",
            ],
        ]
    }

    static var markdown: String {
        let codes = exitCodes.map { "| \($0.code) | `\($0.name)` | \($0.meaning) |" }.joined(separator: "\n")
        let commandList = commands.map { "- `\($0.usage)` — \($0.summary)" }.joined(separator: "\n")
        return """
            # oam — operating manual for AI agents

            `oam` runs Apple's on-device Foundation Model (~3B parameters, 8192-token context, no network)
            with real tool calls. Use it for short, private, free generations: classification, extraction,
            rewriting, structured JSON, and tool-using turns. Keep prompts and tool outputs small.

            ## Commands

            \(commandList)

            Machine-readable modes: `--json` (one result object on stdout) or `--events` (JSON lines).
            Errors in those modes go to **stderr** as `{"error":{"code","message"}}`. Always check the exit code.

            ## Exit codes

            | code | name | meaning |
            |---|---|---|
            \(codes)

            ## One turn

            ```sh
            oam respond --json -i 'Answer in one sentence.' 'What is a monad?'
            # {"status":"completed","text":"…","toolCalls":[],"usage":{…},"steps":[…]}
            ```

            Structured output (any JSON Schema; files from `fm schema object` work):

            ```sh
            oam respond --json --schema person.json 'Invent a fantasy blacksmith'
            # result.structured is schema-valid JSON; result.text is the same JSON as a string
            ```

            ## Tools

            A tools file holds OpenAI tool definitions (an array, or `{"tools": [...]}`).

            - **Command tools** carry `"x-oam": {"command": ["./script.sh", "arg"], "timeout": 10, "cwd": "."}`.
              oam runs the command with the arguments JSON on stdin and in `$OAM_TOOL_ARGUMENTS`
              (also `$OAM_TOOL_NAME`, `$OAM_TOOL_CALL_ID`). Stdout is the output (JSON if it parses);
              a non-zero exit is reported to the model as an error. `command` may be a string for `/bin/sh -c`.
              Relative paths resolve against the tools file's directory; the process runs in `cwd`
              (default: the current directory).
            - **External tools** have no command. When the model calls one, oam prints
              `{"status":"tool_calls","calls":[{"id","name","arguments"}],"transcript":"<file>"}` and exits **10**.
              Execute the calls, then continue:

            ```sh
            oam respond --tools tools.json --tool-choice required 'Where is order A17?'
            # exit 10: {"status":"tool_calls","calls":[{"id":"call_1","name":"lookup_order","arguments":{"order_id":"A17"}}],"transcript":"/tmp/oam-1a2b3c4d.json"}
            oam respond --resume /tmp/oam-1a2b3c4d.json --tool-output 'call_1={"status":"shipped"}' --json
            # --tool-output id=@result.json reads a file; id=@- reads stdin; --tool-error id=message reports a failure
            ```

            The resumed turn may call tools again (exit 10 again); loop until exit 0. Every pending call needs
            an output. Pass `--save-transcript f` on any turn to keep the conversation and `--resume f 'next prompt'`
            to continue it later.

            `--tool-choice required` (or a tool name) forces a tool call on the first step only — use it when the
            answer must come from a tool: in `auto` mode the small model often answers from memory instead.
            `--max-tool-rounds` / `--max-tool-calls` bound the loop. Prefer 3–5 tools per request.

            ## Other interfaces

            - HTTP: `oam serve --port 1976` then any OpenAI client with `base_url=http://127.0.0.1:1976/v1`,
              `model="system"`. Responses contain `tool_calls` (unlike `fm serve`).
            - JSON-RPC over stdio for long-lived sessions: `oam stdio` (see docs/PROTOCOL.md).

            ## Testing without the model

            `OAM_SCRIPT=steps.json oam respond …` replaces the model with a script, one step per model call:
            `[{"toolCalls":[{"name":"lookup_order","arguments":{"order_id":"A17"}}]}, {"text":"Shipped."}]`.
            Steps: `text`, `toolCalls`, `json`, `template` (`{prompt}`, `{toolOutput}`), `error` (an error code).

            ## Tips

            - Check `oam available` first; exit 3 means no model on this machine.
            - Exit 4 (guardrails) happens on violent or unsafe wording, including fiction; rephrase neutrally.
            - Tool outputs count against the 8192-token context; keep them short (default cap 8000 characters).

            """
    }
}
