import Foundation
import FoundationModels
import OpenAppleModels

/// Settings for ``OpenAIServer``.
///
/// The defaults are safe for a local development server: loopback only,
/// browsers from other origins rejected, one on-device model named `system`.
///
/// ```swift
/// var configuration = ServerConfiguration()
/// configuration.modelAliases = ["gpt-4o-mini": "system"]
/// configuration.apiKey = "sk-local-secret"
/// let server = OpenAIServer(configuration: configuration)
/// try await server.start()
/// print("Listening on port", server.port!)
/// ```
public struct ServerConfiguration: Sendable {
    /// Address the TCP listener binds to. Keep `127.0.0.1` (or `::1`) unless
    /// the server must be reachable from other machines — and then set ``apiKey``.
    public var host: String
    /// TCP port. `0` picks a free port (read it from ``OpenAIServer/port``);
    /// `nil` disables the TCP listener (Unix socket only).
    public var port: Int?
    /// Also listen on this Unix domain socket path (created with mode 0600).
    public var unixSocketPath: String?

    /// Models clients may request, by id. Listed by `GET /v1/models`.
    public var models: [String: any LanguageModel]
    /// Extra model ids mapped to entries of ``models`` (for example
    /// `["gpt-4o-mini": "system"]`, so unmodified OpenAI clients work).
    public var modelAliases: [String: String]
    /// Model used when a request omits `model`.
    public var defaultModel: String

    /// Tools executed in-process by the server. The model can call them in
    /// addition to the request's tools; their calls and results are never
    /// returned to the client. They must be local tools (with a handler).
    public var serverTools: [AgentTool]
    /// Instructions prepended to every request's system message, if any.
    public var serverInstructions: String?

    /// When set, `/v1/*` requests must send `Authorization: Bearer <apiKey>`.
    public var apiKey: String?
    /// Browser origins allowed to call the server (for example
    /// `"http://localhost:3000"`). Requests carrying any other `Origin`
    /// header are rejected with 403. `"*"` allows every origin.
    public var allowedOrigins: Set<String>

    /// Largest accepted request body.
    public var maxRequestBodyBytes: Int
    /// Largest accepted request head (request line plus headers).
    public var maxHeaderBytes: Int
    /// Chat completions generated at the same time; further requests queue.
    public var maxConcurrentRequests: Int
    /// Requests allowed to wait in the queue; beyond this, 429 is returned.
    public var maxQueuedRequests: Int
    /// Maximum time for one chat completion, including time spent queued.
    public var requestTimeout: Duration
    /// Maximum time a connection may take to deliver a complete request
    /// (and to stay idle between keep-alive requests).
    public var idleTimeout: Duration
    /// After the model requests a client tool, how long to wait for further
    /// parallel calls before answering with `tool_calls`.
    public var toolCallDebounce: Duration

    /// Tool-loop limits for each request (`choice` and `enabledTools` are
    /// set from the request).
    public var toolPolicy: ToolPolicy
    /// How history is fitted into the context window. The default does not
    /// trim, so an oversized conversation fails with `context_length_exceeded`
    /// like OpenAI; enable trimming to drop the oldest turns instead.
    public var contextPolicy: ContextPolicy
    /// Retries for transient model failures.
    public var retryPolicy: RetryPolicy

    /// Receives diagnostic messages (access log, errors).
    public var logger: (@Sendable (ServerLogEntry) -> Void)?

    /// Creates a configuration; every parameter matches the property of the same name.
    public init(
        host: String = "127.0.0.1",
        port: Int? = 1976,
        unixSocketPath: String? = nil,
        models: [String: any LanguageModel] = ["system": SystemLanguageModel.default],
        modelAliases: [String: String] = [:],
        defaultModel: String = "system",
        serverTools: [AgentTool] = [],
        serverInstructions: String? = nil,
        apiKey: String? = nil,
        allowedOrigins: Set<String> = [],
        maxRequestBodyBytes: Int = 16 << 20,
        maxHeaderBytes: Int = 64 << 10,
        maxConcurrentRequests: Int = 4,
        maxQueuedRequests: Int = 64,
        requestTimeout: Duration = .seconds(120),
        idleTimeout: Duration = .seconds(30),
        toolCallDebounce: Duration = .milliseconds(40),
        toolPolicy: ToolPolicy = ToolPolicy(),
        contextPolicy: ContextPolicy = ContextPolicy(trimsHistory: false),
        retryPolicy: RetryPolicy = .default,
        logger: (@Sendable (ServerLogEntry) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.unixSocketPath = unixSocketPath
        self.models = models
        self.modelAliases = modelAliases
        self.defaultModel = defaultModel
        self.serverTools = serverTools
        self.serverInstructions = serverInstructions
        self.apiKey = apiKey
        self.allowedOrigins = allowedOrigins
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxHeaderBytes = maxHeaderBytes
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxQueuedRequests = maxQueuedRequests
        self.requestTimeout = requestTimeout
        self.idleTimeout = idleTimeout
        self.toolCallDebounce = toolCallDebounce
        self.toolPolicy = toolPolicy
        self.contextPolicy = contextPolicy
        self.retryPolicy = retryPolicy
        self.logger = logger
    }

    /// Resolves a requested model id (or alias) to its canonical id and model.
    func resolveModel(_ requested: String?) -> (id: String, model: any LanguageModel)? {
        let name = requested ?? defaultModel
        if let model = models[name] { return (name, model) }
        if let target = modelAliases[name], let model = models[target] { return (target, model) }
        return nil
    }
}
