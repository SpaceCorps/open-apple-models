import Foundation
import FoundationModels
import Network
import OpenAppleModels
import Synchronization

/// An OpenAI-compatible Chat Completions server for Apple's on-device
/// Foundation Models, with real tool calling.
///
/// Apple's `fm serve` accepts `tools` but never returns `tool_calls`. This
/// server runs each request on an ``Agent`` whose request tools are
/// *external*: when the model calls one, the server answers with
/// `finish_reason: "tool_calls"`, and the client sends the results back in
/// `tool` messages on its next request — the standard OpenAI tool loop.
///
/// ```swift
/// let server = OpenAIServer(configuration: ServerConfiguration(port: 1976))
/// try await server.start()
/// // POST http://127.0.0.1:1976/v1/chat/completions
/// await server.waitUntilStopped()
/// ```
///
/// Endpoints: `POST /v1/chat/completions`, `GET /v1/models`,
/// `GET /v1/models/{id}`, `GET /health`, and CORS preflight (`OPTIONS`).
/// ``handle(_:)`` serves a request without sockets (tests, in-process use).
public final class OpenAIServer: Sendable {
    /// The settings the server was created with.
    public let configuration: ServerConfiguration

    private let logger: ServerLogger
    private let limiter: ConcurrencyLimiter
    private let createdAt = Int(Date().timeIntervalSince1970)
    private let queue = DispatchQueue(label: "open-apple-models.server")

    private struct State {
        var listeners: [HTTPListener] = []
        var connections: [Int: HTTPConnection] = [:]
        var nextConnectionID = 0
        var port: Int?
        var running = false
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Creates a server. Nothing listens until ``start()``; ``handle(_:)`` works right away.
    public init(configuration: ServerConfiguration = ServerConfiguration()) {
        self.configuration = configuration
        logger = ServerLogger(sink: configuration.logger)
        limiter = ConcurrencyLimiter(limit: configuration.maxConcurrentRequests, maxQueued: configuration.maxQueuedRequests)
    }

    // MARK: Lifecycle

    /// The bound TCP port once started (useful with port `0`), else `nil`.
    public var port: Int? { state.withLock { $0.port } }

    /// Whether ``start()`` succeeded and ``stop()`` has not been called.
    public var isRunning: Bool { state.withLock { $0.running } }

    /// Open client connections.
    public var connectionCount: Int { state.withLock { $0.connections.count } }

    /// Starts the listeners and returns once they accept connections.
    public func start() async throws(ServerStartError) {
        try validateConfiguration()
        let alreadyRunning = state.withLock { state in
            defer { state.running = true }
            return state.running
        }
        guard !alreadyRunning else { throw ServerStartError("The server is already running.") }

        var listeners: [HTTPListener] = []
        var boundPort: Int?
        do throws(ServerStartError) {
            if let port = configuration.port {
                let listener = try HTTPListener(host: configuration.host, port: port)
                listeners.append(listener)
                boundPort = try await listener.start(queue: queue) { [weak self] connection in
                    self?.accept(connection, transport: .tcp)
                }
            }
            if let path = configuration.unixSocketPath {
                let listener = try HTTPListener(unixSocketPath: path)
                listeners.append(listener)
                _ = try await listener.start(queue: queue) { [weak self] connection in
                    self?.accept(connection, transport: .unixSocket)
                }
            }
        } catch {
            listeners.forEach { $0.cancel() }
            state.withLock { $0.running = false }
            throw error
        }
        guard !listeners.isEmpty else {
            state.withLock { $0.running = false }
            throw ServerStartError("Nothing to listen on: set a port or a Unix socket path.")
        }

        state.withLock { state in
            state.listeners = listeners
            state.port = boundPort
        }
        var endpoints: [String] = []
        if let boundPort { endpoints.append("http://\(configuration.host.contains(":") ? "[\(configuration.host)]" : configuration.host):\(boundPort)") }
        if let path = configuration.unixSocketPath { endpoints.append("unix:\(path)") }
        logger.log(.info, "open-apple-models server listening on \(endpoints.joined(separator: " and ")) (models: \(CompletionPlan.availableModels(configuration)))")
    }

    /// Stops listening and closes every connection (cancelling in-flight requests).
    public func stop() {
        let (listeners, connections, waiters) = state.withLock { state in
            defer {
                state.listeners = []
                state.connections = [:]
                state.running = false
                state.port = nil
                state.stopWaiters = []
            }
            return (state.listeners, Array(state.connections.values), state.stopWaiters)
        }
        listeners.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
        waiters.forEach { $0.resume() }
        if !listeners.isEmpty { logger.log(.info, "open-apple-models server stopped") }
    }

    /// Suspends until ``stop()`` is called.
    public func waitUntilStopped() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let running = state.withLock { state in
                if state.running { state.stopWaiters.append(continuation) }
                return state.running
            }
            if !running { continuation.resume() }
        }
    }

    private func validateConfiguration() throws(ServerStartError) {
        guard !configuration.models.isEmpty else { throw ServerStartError("Configure at least one model.") }
        guard configuration.resolveModel(nil) != nil else {
            throw ServerStartError("The default model '\(configuration.defaultModel)' is not among the configured models.")
        }
        for (alias, target) in configuration.modelAliases where configuration.models[target] == nil {
            throw ServerStartError("Model alias '\(alias)' points to unknown model '\(target)'.")
        }
        for tool in configuration.serverTools where tool.isExternal {
            throw ServerStartError("Server tool '\(tool.name)' is external; server tools need a local handler.")
        }
    }

    private func accept(_ connection: NWConnection, transport: HTTPTransport) {
        let settings = HTTPConnection.Settings(
            limits: .init(maxHeaderBytes: configuration.maxHeaderBytes, maxBodyBytes: configuration.maxRequestBodyBytes),
            idleTimeout: configuration.idleTimeout)
        let accepted: HTTPConnection? = state.withLock { state in
            guard state.running else { return nil }
            let id = state.nextConnectionID
            state.nextConnectionID += 1
            let handler = HTTPConnection(id: id, connection: connection, transport: transport, settings: settings, log: logger) { [weak self] request in
                guard let self else { return OpenAIError.server("The server is shutting down.").response }
                return await self.handle(request)
            }
            state.connections[id] = handler
            return handler
        }
        guard let accepted else {
            connection.cancel()
            return
        }
        accepted.start { [weak self] in
            _ = self?.state.withLock { $0.connections.removeValue(forKey: accepted.id) }
        }
    }

    // MARK: Request handling

    /// Handles one HTTP request. Streaming responses have a
    /// ``HTTPResponse/Body/stream(_:)`` body of server-sent events.
    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let start = ContinuousClock.now
        var response = await route(request)
        applyCORS(to: &response, for: request)
        let elapsed = ContinuousClock.now - start
        logger.log(response.status >= 500 ? .warning : .info,
                   "\(request.method) \(request.path) → \(response.status)\(response.isStreaming ? " (stream)" : "") "
                       + elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
        return response
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        if let origin = request.headers["Origin"], !isAllowed(origin: origin) {
            return OpenAIError(status: 403, message: "Requests from origin '\(origin)' are not allowed. Add it to allowedOrigins to permit browser access.",
                               type: "invalid_request_error", code: "origin_not_allowed").response
        }
        var path = request.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if request.method == "OPTIONS" { return preflight(request) }

        switch path {
        case "/health", "/healthz", "/v1/health":
            guard request.method == "GET" || request.method == "HEAD" else { return methodNotAllowed(request, allow: "GET") }
            return health()
        case "/v1/models", "/models":
            guard request.method == "GET" || request.method == "HEAD" else { return methodNotAllowed(request, allow: "GET") }
            if let failure = authenticate(request) { return failure }
            return listModels()
        case "/v1/chat/completions", "/chat/completions":
            guard request.method == "POST" else { return methodNotAllowed(request, allow: "POST") }
            if let failure = authenticate(request) { return failure }
            guard Self.isJSON(request.headers["Content-Type"]) else {
                return OpenAIError(status: 415, message: "Content-Type must be application/json.",
                                   type: "invalid_request_error", code: "unsupported_media_type").response
            }
            return await chatCompletions(request)
        default:
            if path.hasPrefix("/v1/models/") || path.hasPrefix("/models/") {
                guard request.method == "GET" || request.method == "HEAD" else { return methodNotAllowed(request, allow: "GET") }
                if let failure = authenticate(request) { return failure }
                return retrieveModel(String(path.split(separator: "/", omittingEmptySubsequences: true).last ?? ""))
            }
            return OpenAIError(status: 404, message: "Unknown request URL: \(request.method) \(request.path). Supported: POST /v1/chat/completions, GET /v1/models, GET /health.",
                               type: "invalid_request_error", code: "unknown_url").response
        }
    }

    // MARK: Security

    private func isAllowed(origin: String) -> Bool {
        configuration.allowedOrigins.contains("*") || configuration.allowedOrigins.contains(origin)
    }

    private func authenticate(_ request: HTTPRequest) -> HTTPResponse? {
        guard let apiKey = configuration.apiKey, !apiKey.isEmpty else { return nil }
        let header = request.headers["Authorization"] ?? ""
        let parts = header.split(separator: " ", maxSplits: 1)
        let token = parts.count == 2 && parts[0].lowercased() == "bearer" ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        if Self.constantTimeEquals(token, apiKey) { return nil }
        var response = OpenAIError(
            status: 401,
            message: token.isEmpty ? "You didn't provide an API key. Send it as 'Authorization: Bearer <key>'." : "Incorrect API key provided.",
            type: "invalid_request_error", code: "invalid_api_key").response
        response.headers["WWW-Authenticate"] = "Bearer"
        return response
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    static func isJSON(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mediaType = contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return mediaType == "application/json"
    }

    private func preflight(_ request: HTTPRequest) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers["Allow"] = "GET, POST, OPTIONS"
        if request.headers["Origin"] != nil {
            headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
            headers["Access-Control-Allow-Headers"] = request.headers["Access-Control-Request-Headers"] ?? "Authorization, Content-Type"
            headers["Access-Control-Max-Age"] = "600"
        }
        return HTTPResponse(status: 204, headers: headers)
    }

    private func applyCORS(to response: inout HTTPResponse, for request: HTTPRequest) {
        guard let origin = request.headers["Origin"], isAllowed(origin: origin) else { return }
        response.headers["Access-Control-Allow-Origin"] = configuration.allowedOrigins.contains("*") ? "*" : origin
        response.headers["Vary"] = "Origin"
        response.headers["Access-Control-Expose-Headers"] = "Retry-After"
    }

    private func methodNotAllowed(_ request: HTTPRequest, allow: String) -> HTTPResponse {
        var response = OpenAIError(status: 405, message: "Method \(request.method) is not allowed for \(request.path); use \(allow).",
                                   type: "invalid_request_error", code: "method_not_allowed").response
        response.headers["Allow"] = allow
        return response
    }

    // MARK: Models and health

    private func availability(of model: any LanguageModel) -> (available: Bool, reason: String?) {
        guard let system = model as? SystemLanguageModel else { return (true, nil) }
        switch system.availability {
        case .available: return (true, nil)
        case .unavailable(let reason): return (false, String(describing: reason))
        }
    }

    private func health() -> HTTPResponse {
        var models = JSONObject()
        for name in configuration.models.keys.sorted() {
            let status = availability(of: configuration.models[name]!)
            models[name] = .string(status.available ? "available" : "unavailable: \(status.reason ?? "unknown")")
        }
        let defaultStatus = configuration.resolveModel(nil).map { availability(of: $0.model) } ?? (false, "no default model")
        let body: JSONValue = [
            "status": .string(defaultStatus.available ? "ok" : "unavailable"),
            "default_model": .string(configuration.defaultModel),
            "models": .object(models),
            "active_requests": .number(Double(limiter.activeCount)),
            "queued_requests": .number(Double(limiter.queuedCount)),
        ]
        return .json(body, status: defaultStatus.available ? 200 : 503)
    }

    private func modelObject(_ id: String, target: String? = nil) -> JSONValue {
        let model = configuration.models[target ?? id]
        var object: JSONObject = [
            "id": .string(id),
            "object": "model",
            "created": .number(Double(createdAt)),
            "owned_by": .string(model is SystemLanguageModel ? "apple" : "open-apple-models"),
        ]
        if let target { object["parent"] = .string(target) }
        return .object(object)
    }

    private func listModels() -> HTTPResponse {
        var data = configuration.models.keys.sorted().map { modelObject($0) }
        data += configuration.modelAliases.keys.sorted().compactMap { alias in
            configuration.models[alias] == nil ? modelObject(alias, target: configuration.modelAliases[alias]) : nil
        }
        return .json(["object": "list", "data": .array(data)])
    }

    private func retrieveModel(_ id: String) -> HTTPResponse {
        if configuration.models[id] != nil { return .json(modelObject(id)) }
        if let target = configuration.modelAliases[id], configuration.models[target] != nil { return .json(modelObject(id, target: target)) }
        return OpenAIError(status: 404, message: "The model '\(id)' does not exist.", type: "invalid_request_error",
                           param: "model", code: "model_not_found").response
    }

    // MARK: Chat completions

    private func chatCompletions(_ request: HTTPRequest) async -> HTTPResponse {
        let deadline = ContinuousClock.now + configuration.requestTimeout
        let plan: CompletionPlan
        do {
            let parsed = try ChatCompletionRequest(body: request.body)
            plan = try CompletionPlan(request: parsed, configuration: configuration, log: logger)
        } catch {
            return error.response
        }
        let status = availability(of: plan.model)
        guard status.available else {
            return OpenAIError(status: 503, message: "The model '\(plan.modelID)' is unavailable: \(status.reason ?? "unknown reason").",
                               type: "server_error", code: "model_unavailable", retryAfter: 30).response
        }

        switch await limiter.acquire(until: deadline) {
        case .acquired:
            break
        case .queueFull:
            return OpenAIError(status: 429, message: "Too many requests are waiting for the model. Retry shortly.",
                               type: "rate_limit_error", code: "rate_limited", retryAfter: 1).response
        case .timedOut:
            return OpenAIError.timeout(after: configuration.requestTimeout).response
        case .cancelled:
            return OpenAIError.server("The request was cancelled.", code: "cancelled").response
        }

        let settings = ChatCompletionRunner.Settings(
            deadline: deadline, timeout: configuration.requestTimeout, debounce: configuration.toolCallDebounce, log: logger)
        let events = ChatCompletionRunner.events(for: plan, settings: settings)
        let encoder = CompletionEncoder(model: plan.modelID)
        if plan.stream {
            return await streamingResponse(events, plan: plan, encoder: encoder)
        }
        defer { limiter.release() }
        return await collectedResponse(events, encoder: encoder)
    }

    private func collectedResponse(_ events: AsyncThrowingStream<CompletionEvent, any Error>, encoder: CompletionEncoder) async -> HTTPResponse {
        var content = ""
        var refusal: String?
        var toolCalls: [ToolCall] = []
        do {
            for try await event in events {
                switch event {
                case .content(let text): content += text
                case .refusal(let text): refusal = text
                case .toolCalls(let calls): toolCalls = calls
                case .finished(let reason, let usage):
                    let body = encoder.completion(
                        content: refusal != nil || (content.isEmpty && !toolCalls.isEmpty) ? nil : content,
                        refusal: refusal, toolCalls: toolCalls, finishReason: reason, usage: usage)
                    return .json(body)
                }
            }
            return OpenAIError.server("The request was cancelled.", code: "cancelled").response
        } catch {
            return Self.openAIError(error).response
        }
    }

    /// Streams server-sent events. Waits for the first event before
    /// committing to a 200 response, so early failures (unavailable model,
    /// context overflow, guardrails) get a proper HTTP error status.
    private func streamingResponse(_ events: AsyncThrowingStream<CompletionEvent, any Error>, plan: CompletionPlan, encoder: CompletionEncoder) async -> HTTPResponse {
        let head = OneShot<OpenAIError?>()
        let producerHandle = TaskHandle()
        let (body, output) = HTTPBodyStream.makeStream(onCancel: { producerHandle.cancel() })
        let limiter = self.limiter
        let producer = Task {
            defer {
                output.finish()
                limiter.release()
            }
            var started = false
            func start() {
                guard !started else { return }
                started = true
                head.fulfill(nil)
                output.yield(CompletionEncoder.event(encoder.chunk(delta: ["role": "assistant", "content": ""], includeUsage: plan.includeUsage)))
            }
            do {
                for try await event in events {
                    start()
                    switch event {
                    case .content(let text):
                        output.yield(CompletionEncoder.event(encoder.chunk(delta: ["content": .string(text)], includeUsage: plan.includeUsage)))
                    case .refusal(let text):
                        output.yield(CompletionEncoder.event(encoder.chunk(delta: ["refusal": .string(text)], includeUsage: plan.includeUsage)))
                    case .toolCalls(let calls):
                        output.yield(CompletionEncoder.event(encoder.chunk(delta: CompletionEncoder.toolCallsDelta(calls), includeUsage: plan.includeUsage)))
                    case .finished(let reason, let usage):
                        output.yield(CompletionEncoder.event(encoder.chunk(delta: [:], finishReason: reason, includeUsage: plan.includeUsage)))
                        if plan.includeUsage { output.yield(CompletionEncoder.event(encoder.usageChunk(usage))) }
                        output.yield(CompletionEncoder.done)
                        return
                    }
                }
                guard started else {
                    head.fulfill(.server("The request was cancelled.", code: "cancelled"))
                    return
                }
                output.yield(CompletionEncoder.event(OpenAIError.server("The stream ended unexpectedly.").json))
                output.yield(CompletionEncoder.done)
            } catch {
                let failure = Self.openAIError(error)
                guard started else {
                    head.fulfill(failure)
                    return
                }
                output.yield(CompletionEncoder.event(failure.json))
                output.yield(CompletionEncoder.done)
            }
        }
        producerHandle.set(producer)
        let failure = await withTaskCancellationHandler {
            await head.value()
        } onCancel: {
            producer.cancel()
        }
        if let failure {
            producer.cancel()
            return failure.response
        }
        var headers = HTTPHeaders()
        headers["Content-Type"] = "text/event-stream; charset=utf-8"
        headers["Cache-Control"] = "no-cache"
        headers["X-Accel-Buffering"] = "no"
        return HTTPResponse(status: 200, headers: headers, body: .stream(body))
    }

    static func openAIError(_ error: any Error) -> OpenAIError {
        if let error = error as? OpenAIError { return error }
        return OpenAIError(AgentError(error))
    }
}

/// A value delivered once; later deliveries are ignored.
final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var delivered = false
        var waiters: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Mutex(State())

    func fulfill(_ value: Value) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>] in
            guard !state.delivered else { return [] }
            state.delivered = true
            state.value = value
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: value) }
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let (delivered, value) = state.withLock { state -> (Bool, Value?) in
                if state.delivered { return (true, state.value) }
                state.waiters.append(continuation)
                return (false, nil)
            }
            if delivered, let value { continuation.resume(returning: value) }
        }
    }
}

/// Holds a task created after the closures that need to cancel it.
final class TaskHandle: Sendable {
    private let state = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))

    func set(_ task: Task<Void, Never>) {
        let cancelled = state.withLock { state in
            state.task = task
            return state.cancelled
        }
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}
