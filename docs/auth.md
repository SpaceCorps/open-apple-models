# Authentication & Hardware Requirements

OpenAppleModels requires **zero API keys, cloud tokens, or credentials**.

## System Requirements

1. **Operating System**:
   - iOS 27+
   - iPadOS 27+
   - macOS 27+
   - visionOS 27+

2. **Hardware**:
   - A device that supports Apple Intelligence, with the on-device model downloaded. Check with
     `SystemLanguageModel.default.availability` or `oam available` (exit code 3 and a `reason` when unavailable).
   - All measurements in this project come from macOS 27 on an Apple silicon Mac. Nothing has been measured on an
     iPhone, iPad or Vision Pro yet.

3. **System Settings**:
   - Apple Intelligence must be turned ON in **System Settings > Apple Intelligence & Siri**.

## Testing Without Apple Intelligence Hardware

For continuous integration (CI), engine integration work, or automated unit testing, OpenAppleModels provides `OpenAppleModelsTesting`:

```swift
import OpenAppleModels
import OpenAppleModelsTesting

// Script a deterministic test conversation with mock tool calls
let script = ModelScript([
    .toolCalls([.init(name: "check_inventory", arguments: ["item": "iron sword"])]),
    .text("I have 3 iron swords.")
])
let model = ScriptedLanguageModel(script)
let agent = try Agent(model: model, tools: [inventoryTool])
```

`ScriptedLanguageModel` plays back scripted steps, so tests do not need Apple Intelligence. They still need a macOS 27 host, because FoundationModels' 27 APIs must load; they do not run on Linux or older macOS.
