# Bindings

Use on-device Apple Foundation Models agents — with real tool calls your game executes — from C, C#/Unity,
Python, Godot, Unreal or anything else that can call C or spawn a process.

All bindings speak the same JSON-RPC protocol ([docs/PROTOCOL.md](../docs/PROTOCOL.md)) through the C ABI in
[`c/open_apple_models.h`](c/open_apple_models.h) (library: `OpenAppleModelsFFI`). Processes that prefer pipes can
run `oam stdio` instead and exchange the same messages over stdin/stdout.

| Folder | What |
|---|---|
| `c/` | the C header (memory and threading rules) and `example.c`, a minimal host |
| `python/` | `open_apple_models.py` (ctypes, asyncio-friendly), `example.py`, `test_bridge.py` |
| `unity/` | `OpenAppleModels.cs` — P/Invoke wrapper for Unity (macOS and iOS) and plain .NET |

Besides raw agent sessions, every binding wraps the **game methods** (protocol section 6): NPCs with personas,
memory and save states (`npc/*`), enum-constrained decisions (`decision/*`), a shared world-state blackboard with
change notifications (`world/*`) and schema-shaped content (`content/generate`).

Requirements: macOS / iOS / visionOS 27 with Apple Intelligence for the real model. Every binding also works with
the **scripted model** (`"model": {"type": "scripted", ...}`), so you can develop and run CI anywhere the library
loads, without Apple Intelligence.

> **Set the minimum OS to 27.** The library links FoundationModels 27 APIs strongly (not weakly), so it cannot load
> on older systems. Every app that embeds it — Unity, Xcode, Godot or Unreal projects for iOS, visionOS and macOS —
> must set its minimum OS / deployment target to **27.0** (Unity: *Player Settings → Other Settings → Target minimum
> iOS Version* / *Target minimum visionOS Version*; Xcode: *Minimum Deployments*; macOS apps: `LSMinimumSystemVersion`
> 27.0). With a lower minimum the app builds and installs on older OS versions and then **crashes at launch** with a
> missing-symbol error; it does not degrade gracefully. To support older systems, ship a separate build (or load the
> library only after an OS version check, e.g. `dlopen` from a plugin loaded on 27+).

## Building the library

### macOS (dylib)

Command Line Tools are enough:

```sh
swift build -c release --product OpenAppleModelsFFI
# -> .build/release/libOpenAppleModelsFFI.dylib
```

The dylib links only system libraries (`/usr/lib/swift`, Foundation, FoundationModels). For distribution, sign it
with your identity (`codesign --sign "Developer ID Application: …" --timestamp libOpenAppleModelsFFI.dylib`) or let
the host app's signing step do it.

Quick check with the C example:

```sh
clang -I bindings/c bindings/c/example.c -L .build/release -lOpenAppleModelsFFI \
      -Wl,-rpath,$PWD/.build/release -o /tmp/oam-example
/tmp/oam-example          # scripted model
/tmp/oam-example --live   # on-device model
```

### iOS / visionOS (XCFramework, requires Xcode)

SwiftPM cannot cross-compile for iOS with Command Line Tools alone; use Xcode 27 (not verified on the machine this
was written on, which has no Xcode). The framework's minimum OS is 27.0, and so must be the app's (see above):

```sh
# Device and simulator builds of the dynamic library product.
for destination in "generic/platform=iOS" "generic/platform=iOS Simulator"; do
  xcodebuild build \
    -scheme OpenAppleModelsFFI \
    -destination "$destination" \
    -configuration Release \
    -derivedDataPath .build/xcode \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
done

# Package both slices. SwiftPM dynamic products land in PackageFrameworks/.
xcodebuild -create-xcframework \
  -framework .build/xcode/Build/Products/Release-iphoneos/PackageFrameworks/OpenAppleModelsFFI.framework \
  -framework .build/xcode/Build/Products/Release-iphonesimulator/PackageFrameworks/OpenAppleModelsFFI.framework \
  -output build/OpenAppleModelsFFI.xcframework
```

The framework contains no public headers; copy `bindings/c/open_apple_models.h` next to your native code if you
call it from C/C++/Objective-C. For visionOS use `generic/platform=visionOS` (and `visionOS Simulator`).

## Unity

1. Copy `unity/OpenAppleModels.cs` into `Assets/`.
2. macOS (editor and standalone): copy `libOpenAppleModelsFFI.dylib` to `Assets/Plugins/macOS/` and enable it for
   Editor + Standalone (macOS, Apple Silicon) in the plugin inspector.
3. iOS / visionOS: copy `OpenAppleModelsFFI.xcframework` (or the device `.framework`) to `Assets/Plugins/iOS/`
   (or `Assets/Plugins/visionOS/`) and tick **Add to Embedded Binaries**. The C# code uses
   `[DllImport("__Internal")]` there automatically. **Set Player Settings → Other Settings → Target minimum iOS
   Version (or visionOS Version) to 27.0**: Unity's lower default builds fine but the app crashes at launch on
   older devices.
4. Create the bridge once and let the runner pump it on the main thread:

```csharp
using OpenAppleModels;

var bridge = OamBridgeRunner.Create().Bridge;          // DontDestroyOnLoad, pumps in Update, disposes on destroy

// A tool the MODEL decides to call and the GAME executes. Reply when the animation ends.
bridge.RegisterTool("open_gate", "Open a named gate. Returns whether it opened.",
    Json.Parse(@"{""type"":""object"",""properties"":{""gate"":{""type"":""string""}},""required"":[""gate""]}"),
    (call, reply) => StartCoroutine(OpenGate((string)call.Arguments["gate"], opened => reply.Ok(new Dictionary<string, object> { ["opened"] = opened }))));

var guard = await bridge.CreateSessionAsync(
    "You are a castle guard in a game. Use tools to act. Reply in one sentence.",
    new[] { "open_gate" },
    options: new Dictionary<string, object> { ["toolChoice"] = "required" });

var result = await guard.RespondAsync("Please open the north gate.", onText: delta => subtitle.text += delta);
```

Threading: the native callback copies each message into a queue; `Pump()` (called by `OamBridgeRunner.Update`)
completes tasks, raises events, invokes tool handlers and the callback-style `Request(method, params, onResult,
onError)` callbacks **on the main thread**, so Unity APIs are safe in them. (`await`ed tasks resume wherever your
`SynchronizationContext` puts them — Unity's main thread by default.) `ToolReply.Ok/Error` may be called from any
thread, any time later; `ToolReply.Cancelled` fires if the bridge gives up on the call (timeout or cancelled turn).
`SendMessage`, `CallBlocking` and `Dispose` are thread-safe: `Dispose` cancels an in-flight `CallBlocking`, waits
for native calls on other threads to return, and destroys the bridge exactly once. The static callback is marked
`[MonoPInvokeCallback]` for IL2CPP. Outside Unity the same file compiles for plain .NET (call `Pump()` yourself or
pass `dispatchOnCallbackThread: true`).

Guardrails can reject violent game content (`OamException.Name == "guardrail_violation"`); catch it and show a
fallback line. NPCs do this for you (`isFallback` in the turn).

NPCs, world state and decisions:

```csharp
bridge.RegisterTool("check_inventory", "Look up stock and price of an item.",
    Json.Parse(@"{""type"":""object"",""properties"":{""item"":{""type"":""string""}},""required"":[""item""]}"),
    call => shop.Lookup((string)call.Arguments["item"]));        // call.Npc tells which NPC asked

var world = await bridge.CreateWorldAsync(new Dictionary<string, object> {
    ["player"] = new Dictionary<string, object> { ["name"] = "Aria", ["gold"] = 60 } }, world: "village");
await world.SubscribeAsync(change => hud.Refresh((string)change["path"]), path: "quests");

var gorm = await bridge.CreateNpcAsync(
    new Dictionary<string, object> { ["name"] = "Gorm", ["role"] = "the village blacksmith", ["personality"] = "Gruff but fair." },
    tools: new[] { "check_inventory" }, world: world.Id, npc: "gorm",
    options: new Dictionary<string, object> { ["groundingTool"] = "check_inventory", ["worldContextPaths"] = new List<object> { "player" } });

var turn = await gorm.TalkAsync("Got any iron swords?", onLine: text => subtitle.text = text, onEmotion: portrait.Show);
ShowChoices((List<object>)turn["playerOptions"]);
var save = Json.Serialize(await gorm.StateAsync());               // store with the game save; RestoreNpcAsync(Json.Parse(save))

var decision = await bridge.DecideAsync("The goblin has 3 HP left.", new object[] { "attack", "flee", "beg" },
    actor: "gorm", fallbackOptionId: "flee");
```

## Python

```sh
swift build -c release --product OpenAppleModelsFFI
python3 bindings/python/example.py            # scripted model
python3 bindings/python/example.py --live     # on-device model
python3 -m unittest discover -s bindings/python -v
```

```python
import asyncio
from open_apple_models import Bridge

async def main():
    async with Bridge() as bridge:
        @bridge.tool("check_inventory", "Look up stock and price of an item.",
                     {"type": "object", "properties": {"item": {"type": "string"}}, "required": ["item"]})
        async def check_inventory(args):
            return {"item": args["item"], "stock": 3, "price_gold": 45}

        gorm = await bridge.create_session("You are Gorm, a grumpy blacksmith.", tools=["check_inventory"])
        reply = await gorm.respond("Got any iron swords?", toolChoice="required",
                                   on_text=lambda d: print(d, end="", flush=True))
        print("\n", reply["toolCalls"])

        # Game methods: an NPC with a persona, world state and a grounding tool.
        world = await bridge.create_world({"player": {"name": "Aria", "gold": 60}}, world="village")
        smith = await bridge.create_npc({"name": "Gorm", "role": "the village blacksmith"},
                                        tools=["check_inventory"], world=world.id,
                                        options={"groundingTool": "check_inventory"})
        turn = await smith.talk("Got any iron swords?", on_line=print, on_emotion=print)
        print(turn["emotion"], turn["line"], turn["playerOptions"])
        save = await smith.state()                       # restore with bridge.restore_npc(save)
        decision = await bridge.decide("A goblin sees the player.", ["attack", "flee"], actor=smith.id, fallback="flee")

asyncio.run(main())
```

The library is found through `Bridge(library=...)`, `OAM_LIBRARY`, `.build/release`, `.build/debug`, then the
system path. Messages arrive on a bridge thread and are handed to the asyncio loop; tool handlers (sync or async)
run on the loop and may raise `ToolError` to report a failure to the model. A bridge follows you to a new event loop
(e.g. a second `asyncio.run`) once the old loop has stopped and no request is pending; using it from two running
loops at once raises `RuntimeError`. Everything sent must be strict JSON: sets, `Decimal`, numpy values, dates and
enums are converted, NaN/infinity raise `ValueError` (from `request()`, before anything is sent), and a tool result
that cannot be encoded reaches the model as an error output. `bridge.call_blocking(method, params)` is a
synchronous, thread-safe helper for simple calls (not for sessions with tools); `close()` cancels an in-flight one.
Close bridges (or use `async with`); an unclosed bridge is kept alive, never garbage collected under the native
callback, and destroyed at interpreter exit.

## Godot

Two options:

* **GDExtension (in-process):** write a small C++ GDExtension that links `libOpenAppleModelsFFI` and includes
  `open_apple_models.h`. In the callback, copy the line into a mutex-protected queue; in `_process`, drain it and
  emit a signal (`message_received(line: String)`) that GDScript parses with `JSON.parse_string`. Expose
  `send(line: String)` which calls `oam_bridge_send`. Answer `tool/call` requests from GDScript with
  `{"jsonrpc":"2.0","id":<same id>,"result":{"output":...}}`. Call `oam_bridge_destroy` in the extension's
  destructor.
* **Process (no native code):** run `oam stdio` with `OS.execute_with_pipe()` (Godot 4.3+), write one JSON line per
  message to its stdin and read lines from its stdout on a thread.

## Unreal Engine

Add the dylib/XCFramework as a ThirdParty module in a plugin (`PublicAdditionalLibraries` /
`PublicAdditionalFrameworks`, `RuntimeDependencies` for the dylib on macOS) and include `open_apple_models.h` in an
`extern "C"` block (the header already has one). In the callback, copy the line into an `FString` and dispatch to
the game thread with `AsyncTask(ENamedThreads::GameThread, [Line] { ... })`; parse with `FJsonSerializer`. Keep one
bridge per game instance, and call `oam_bridge_destroy` in `ShutdownModule` or the subsystem's `Deinitialize`.

## Writing a new binding

1. Load the library, declare the six functions from the header.
2. Pass a callback that **copies** the line and queues it; never do heavy work or throw in it. Keep the callback
   (and whatever `user_data` points to) alive until `oam_bridge_destroy` returns — garbage-collected runtimes must
   pin it (static delegate + `GCHandle` in C#, a module-level registry in Python).
3. Keep a table `request id -> future/callback`; route responses by `id`, `session/event` and `npc/event` by
   `params.requestId`, and `world/changed` by `params.subscription`.
4. Answer `tool/call` requests (id `t-<n>`) with `{"output": …}` or `{"output": "...", "isError": true}`; stop work on
   `tool/cancel`.
5. On shutdown call `oam_bridge_destroy` (it waits for an in-flight callback; nothing arrives afterwards) and fail
   outstanding futures. If other threads may be inside `oam_bridge_send`/`oam_call_blocking`, mark the bridge
   closed, send `{"jsonrpc":"2.0","method":"shutdown"}` to cancel blocking calls, wait for those calls to return
   (an in-flight counter under a lock), and only then destroy — a freed handle must never reach the C ABI.
6. Send strict JSON (no NaN/Infinity). Prefer string request ids; numeric ids must stay within ±(2^53-1).
7. Test against the scripted model (see `python/test_bridge.py` for a checklist of behaviors).
