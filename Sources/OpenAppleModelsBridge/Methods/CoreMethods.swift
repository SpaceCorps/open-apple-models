import Foundation
import FoundationModels
import OpenAppleModels

/// Registers the built-in method set.
enum BuiltinMethods {
    static func register(in registry: inout BridgeMethodRegistry) {
        CoreMethods.register(in: &registry)
        SessionMethods.register(in: &registry)
        ValidationMethods.register(in: &registry)
    }
}

/// `initialize`, `ping`, `model/availability`, `shutdown`.
enum CoreMethods {
    static func register(in registry: inout BridgeMethodRegistry) {
        registry.register("initialize", initialize)
        registry.register("ping") { _ in .result([:]) }
        registry.register("model/availability") { request in
            .result(request.engine.configuration.modelAvailability().json)
        }
        registry.register("shutdown") { request in
            await request.engine.shutdown()
            request.engine.markShutdownHookPending()
            return .result([:])
        }
    }

    /// `initialize {client?: {name, version}, protocolVersion?}`.
    static func initialize(_ request: BridgeRequest) async throws -> BridgeReply {
        let engine = request.engine
        if let client = try request.params.optionalObject("client") {
            engine.recordClient(.object(client))
        }
        if let requested = try request.params.optionalString("protocolVersion"),
           requested.split(separator: ".").first != BridgeVersion.protocolVersion.split(separator: ".").first {
            throw BridgeError.invalidParams(
                "Unsupported protocol version '\(requested)'; this bridge speaks \(BridgeVersion.protocolVersion).")
        }
        let configuration = engine.configuration
        let models: [JSONValue] = configuration.allowsScriptedModels ? ["system", "scripted"] : ["system"]
        return .result([
            "protocolVersion": .string(BridgeVersion.protocolVersion),
            "server": ["name": .string(BridgeVersion.serverName), "version": .string(BridgeVersion.library)],
            "capabilities": [
                "methods": .array(engine.methods.map(JSONValue.string)),
                "notifications": ["session/event", "tool/cancel"],
                "clientRequests": ["tool/call"],
                "streaming": true,
                "clientTools": true,
                "structuredOutput": true,
                "models": .array(models),
                "maxSessions": .number(Double(configuration.maxSessions)),
                "batch": false,
            ],
            "model": configuration.modelAvailability().json,
        ])
    }
}

/// `schema/validate`, `tools/validate`.
enum ValidationMethods {
    static func register(in registry: inout BridgeMethodRegistry) {
        registry.register("schema/validate") { request in
            let params = request.params
            let schema = try BridgeCoding.schema(params.value("schema"))
            let name = try params.optionalString("name") ?? "Response"
            let converted = try BridgeCoding.convert(schema, name: name, path: "schema")
            return .result([
                "warnings": .array(converted.warnings.map(JSONValue.string)),
                "generationSchema": BridgeCoding.json(converted.schema),
            ])
        }
        registry.register("tools/validate") { request in
            let parsed = try BridgeCoding.tools(from: request.params.value("tools"), defaultTimeout: nil)
            let tools: [JSONValue] = parsed.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "warnings": .array(tool.schemaWarnings.map(JSONValue.string)),
                    "generationSchema": BridgeCoding.json(tool.generationSchema),
                ]
            }
            return .result([
                "tools": .array(tools),
                "warnings": .array(parsed.warnings.map(JSONValue.string)),
            ])
        }
    }
}
