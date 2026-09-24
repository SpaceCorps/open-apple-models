# Authentication & Hardware Requirements

OpenAppleModels requires **zero API keys, cloud tokens, or credentials**.

## System Requirements

1. **Operating System**:
   - iOS 27+
   - iPadOS 27+
   - macOS 27+
   - visionOS 27+

2. **Hardware**:
   - Apple Silicon Mac (M1/M2/M3/M4 or newer)
   - iPhone with Apple Intelligence support (iPhone 15 Pro / iPhone 16 series or newer)
   - iPad with M-series chip or A17 Pro
   - Apple Vision Pro

3. **System Settings**:
   - Apple Intelligence must be turned ON in **System Settings > Apple Intelligence & Siri**.

## Testing Without Apple Intelligence Hardware

For continuous integration (CI), non-Apple Silicon devices, or automated unit testing, OpenAppleModels provides `OpenAppleModelsTesting`:

```swift
import OpenAppleModels
import OpenAppleModelsTesting

// Script a deterministic test conversation with mock tool calls
let script = ModelScript([
    .toolCalls([.init(name: "check_inventory")]),
    .text("I have 3 iron swords.")
])
let model = ScriptedLanguageModel(script)
let agent = try Agent(model: model, tools: [inventoryTool])
```

The deterministic `ScriptedLanguageModel` allows 100% test coverage across Linux, Intel Macs, and GitHub Actions CI runners without requiring local Apple Neural Engine silicon.
