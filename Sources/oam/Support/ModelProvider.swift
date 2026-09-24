import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsBridge
import OpenAppleModelsTesting

/// Chooses the language model: the on-device system model, or — when the
/// `OAM_SCRIPT` environment variable names a steps file — a deterministic
/// ``ScriptedLanguageModel``, so every command can be tested without Apple
/// Intelligence.
///
/// The steps file uses the bridge's scripted-model format: an array of steps,
/// or `{"steps": [...], "fallback"?: step}`. Step forms: `{"text"}`,
/// `{"toolCalls": [{"name", "arguments"?, "id"?}]}`, `{"json"}`,
/// `{"template"}` (with `{prompt}`, `{toolOutput}`, `{toolOutputs}`),
/// `{"error": "<agent error code>"}`, each optionally with `"delayMs"`.
enum ModelProvider {
    static let scriptVariable = "OAM_SCRIPT"

    /// The steps file named by `OAM_SCRIPT`, if set.
    static var scriptPath: String? {
        guard let path = ProcessInfo.processInfo.environment[scriptVariable], !path.isEmpty else { return nil }
        return path
    }

    /// Whether commands run on the scripted model.
    static var isScripted: Bool { scriptPath != nil }

    /// Short name of the active model (`system` or `scripted`).
    static var modelName: String { isScripted ? "scripted" : "system" }

    /// Parses the `OAM_SCRIPT` steps file into a fresh script.
    static func loadScript() throws(CLIError) -> ModelScript? {
        guard let path = scriptPath else { return nil }
        let value = try InputFiles.readJSON(path, what: "\(scriptVariable) steps file")
        return try parseScript(value, source: path)
    }

    /// Parses a steps value (array or object) into a script.
    static func parseScript(_ value: JSONValue, source: String) throws(CLIError) -> ModelScript {
        var object: JSONObject
        switch value {
        case .array(let steps):
            object = ["steps": .array(steps)]
        case .object(let given):
            object = given
        default:
            throw .invalidInput("\(source): expected an array of steps or {\"steps\": [...]}.")
        }
        object["type"] = "scripted"
        do {
            return try BridgeScript.parse(.object(object), path: scriptVariable)
        } catch {
            throw .invalidInput("\(source): \(error.message)")
        }
    }

    /// Creates the model for one command run. Fails with exit code 3 when
    /// the system model is unavailable.
    static func makeModel() throws(CLIError) -> any LanguageModel {
        if let script = try loadScript() {
            return ScriptedLanguageModel(script)
        }
        try requireAvailability()
        return SystemLanguageModel.default
    }

    /// Throws `model_unavailable` (exit 3) if the system model cannot be used.
    static func requireAvailability() throws(CLIError) {
        guard !isScripted else { return }
        let availability = ModelAvailability.system()
        guard availability.available else {
            throw CLIError(
                code: AgentError.Code.modelUnavailable.rawValue,
                message: "The on-device model is unavailable (\(availability.reason ?? "unknown")). "
                    + unavailableAdvice(availability.reason),
                exitCode: ExitStatus.modelUnavailable)
        }
    }

    /// Availability of the active model.
    static func availability() -> ModelAvailability {
        if isScripted {
            return ModelAvailability(available: true, contextSize: 8192, variant: "scripted (\(scriptVariable))", supportedLanguages: [])
        }
        return ModelAvailability.system()
    }

    private static func unavailableAdvice(_ reason: String?) -> String {
        switch reason {
        case "apple_intelligence_not_enabled": "Turn on Apple Intelligence in System Settings."
        case "model_not_ready": "The model is still downloading; try again later."
        case "device_not_eligible": "This device does not support Apple Intelligence."
        default: "Set \(scriptVariable)=<steps.json> to use a scripted model instead."
        }
    }
}

/// Reading input files with errors that name the file.
enum InputFiles {
    /// Reads a file, or standard input for `-`.
    static func read(_ path: String, what: String) throws(CLIError) -> Data {
        if path == "-" {
            return FileHandle.standardInput.readDataToEndOfFile()
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw .invalidInput("Cannot read \(what) '\(path)': \((error as NSError).localizedDescription)")
        }
    }

    /// Reads and parses a JSON file (or `-` for standard input).
    static func readJSON(_ path: String, what: String) throws(CLIError) -> JSONValue {
        let data = try read(path, what: what)
        do {
            return try JSONValue(parsing: data)
        } catch {
            throw .invalidInput("\(what) '\(path)' is not valid JSON: \(error.description)")
        }
    }

    /// Writes data atomically, creating parent directories.
    static func write(_ data: Data, to path: String, what: String) throws(CLIError) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw .io("Cannot write \(what) '\(path)': \((error as NSError).localizedDescription)")
        }
    }

    /// The absolute, standardized form of a path.
    static func absolute(_ path: String, relativeTo base: URL? = nil) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        let base = base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }
}
