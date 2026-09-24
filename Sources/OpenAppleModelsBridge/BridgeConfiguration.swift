import Foundation
import FoundationModels
import OpenAppleModels
import OpenAppleModelsTesting

/// Version constants of the bridge protocol and library.
public enum BridgeVersion {
    /// The JSON-RPC protocol version reported by `initialize`.
    public static let protocolVersion = "1.0"
    /// The library version reported by `initialize` and `oam_version()`.
    public static let library = "0.1.0"
    /// The server name reported by `initialize`.
    public static let serverName = "open-apple-models"
}

/// Severity of a bridge log message.
public enum BridgeLogLevel: String, Sendable, Comparable, CaseIterable {
    case debug, info, warning, error

    public static func < (lhs: BridgeLogLevel, rhs: BridgeLogLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Which language model a session runs on, as requested by the client in
/// `session/create` (`model` parameter).
public enum BridgeModelSpec: Sendable {
    /// The on-device system model (`"system"`, the default).
    case system
    /// A deterministic scripted model (`{"type": "scripted", "steps": [...]}`),
    /// for engine development and CI without Apple Intelligence.
    case scripted(ModelScript)
    /// Any other `{"type": "<name>", ...}` object; resolved by
    /// ``BridgeConfiguration/modelFactory``. The payload is the whole object.
    case custom(type: String, options: JSONValue)

    /// A short name for listings (`"system"`, `"scripted"` or the custom type).
    public var kind: String {
        switch self {
        case .system: "system"
        case .scripted: "scripted"
        case .custom(let type, _): type
        }
    }
}

/// Availability and properties of the model, as reported by
/// `model/availability` and `initialize`.
public struct ModelAvailability: Sendable, Hashable {
    public var available: Bool
    /// Why the model is unavailable: `device_not_eligible`,
    /// `apple_intelligence_not_enabled`, `model_not_ready` or `unknown`.
    public var reason: String?
    /// Context window in tokens (input and output combined).
    public var contextSize: Int
    /// Model variant display name, if known.
    public var variant: String?
    /// BCP-47 language identifiers the model supports, sorted.
    public var supportedLanguages: [String]

    public init(available: Bool, reason: String? = nil, contextSize: Int, variant: String? = nil, supportedLanguages: [String] = []) {
        self.available = available
        self.reason = reason
        self.contextSize = contextSize
        self.variant = variant
        self.supportedLanguages = supportedLanguages
    }

    /// Reads the availability of a system model (default: `SystemLanguageModel.default`).
    public static func system(_ model: SystemLanguageModel = .default) -> ModelAvailability {
        var reason: String?
        switch model.availability {
        case .available: break
        case .unavailable(.deviceNotEligible): reason = "device_not_eligible"
        case .unavailable(.appleIntelligenceNotEnabled): reason = "apple_intelligence_not_enabled"
        case .unavailable(.modelNotReady): reason = "model_not_ready"
        case .unavailable: reason = "unknown"
        }
        return ModelAvailability(
            available: reason == nil,
            reason: reason,
            contextSize: model.contextSize,
            variant: model.variant.displayName,
            supportedLanguages: model.supportedLanguages.map(\.minimalIdentifier).sorted())
    }

    /// The `model/availability` result object.
    public var json: JSONValue {
        var object: JSONObject = ["available": .bool(available)]
        if let reason { object["reason"] = .string(reason) }
        object["contextSize"] = .number(Double(contextSize))
        if let variant { object["variant"] = .string(variant) }
        object["supportedLanguages"] = .array(supportedLanguages.map(JSONValue.string))
        return .object(object)
    }
}

/// Settings for a ``BridgeEngine``.
public struct BridgeConfiguration: Sendable {
    /// Creates the language model for a session. The default returns
    /// `SystemLanguageModel.default` for ``BridgeModelSpec/system``, a
    /// `ScriptedLanguageModel` for ``BridgeModelSpec/scripted(_:)`` and
    /// rejects custom types. Replace it to route sessions to other models
    /// (Private Cloud Compute, adapters, third-party providers).
    public var modelFactory: @Sendable (BridgeModelSpec) throws -> any LanguageModel

    /// Reports model availability for `initialize` and `model/availability`.
    public var modelAvailability: @Sendable () -> ModelAvailability

    /// Maximum number of live sessions; `session/create` fails beyond it.
    public var maxSessions: Int

    /// Whether clients may create scripted-model sessions. Enabled by default
    /// so engine developers can work without Apple Intelligence.
    public var allowsScriptedModels: Bool

    /// Time limit for client-executed tools (`tool/call` round trips) when a
    /// session or tool does not set its own. `nil` waits indefinitely.
    public var defaultToolTimeout: Duration?

    /// Receives diagnostic messages (unknown response ids, dropped messages…).
    public var logger: (@Sendable (BridgeLogLevel, String) -> Void)?

    /// Method sets registered at start-up, after the built-in methods.
    /// Defaults to ``standardExtensions()``; pass `[]` for the built-ins only.
    public var extensions: [any BridgeExtension]

    /// Called once after the response to `shutdown` has been delivered
    /// through `send` (e.g. to exit a stdio server).
    public var onShutdown: (@Sendable () -> Void)?

    public init(
        modelFactory: @escaping @Sendable (BridgeModelSpec) throws -> any LanguageModel = BridgeConfiguration.defaultModelFactory,
        modelAvailability: @escaping @Sendable () -> ModelAvailability = { ModelAvailability.system() },
        maxSessions: Int = 64,
        allowsScriptedModels: Bool = true,
        defaultToolTimeout: Duration? = .seconds(120),
        logger: (@Sendable (BridgeLogLevel, String) -> Void)? = nil,
        extensions: [any BridgeExtension] = BridgeConfiguration.standardExtensions(),
        onShutdown: (@Sendable () -> Void)? = nil
    ) {
        self.modelFactory = modelFactory
        self.modelAvailability = modelAvailability
        self.maxSessions = maxSessions
        self.allowsScriptedModels = allowsScriptedModels
        self.defaultToolTimeout = defaultToolTimeout
        self.logger = logger
        self.extensions = extensions
        self.onShutdown = onShutdown
    }

    /// The extensions every transport serves by default (the `oam stdio` CLI
    /// and the C ABI both use the default configuration). Returns fresh
    /// instances on each call, since each engine owns its extensions' state.
    ///
    /// Currently ``GameExtension`` (`npc/*`, `decision/*`, `world/*`,
    /// `content/generate`). To ship a new method set with every transport,
    /// implement it as a ``BridgeExtension`` in this module and add an
    /// instance here.
    public static func standardExtensions() -> [any BridgeExtension] {
        [GameExtension()]
    }

    /// The default ``modelFactory``.
    public static let defaultModelFactory: @Sendable (BridgeModelSpec) throws -> any LanguageModel = { spec in
        switch spec {
        case .system:
            return SystemLanguageModel.default
        case .scripted(let script):
            return ScriptedLanguageModel(script)
        case .custom(let type, _):
            throw BridgeError.invalidParams("Unknown model type '\(type)'. Supported: \"system\", \"scripted\".")
        }
    }
}
