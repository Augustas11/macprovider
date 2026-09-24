import Foundation
import MacProviderCore

// SPEC-046-R002 / SPEC-010-R007(e) loopback serving adapter (issues #1569, #1690 M2).
//
// One `macprovider-cli serve` process can serve a GGUF hosted by a loopback
// OpenAI-compatible runtime by proxying inference to that runtime's
// `/v1/chat/completions` endpoint. Two runtimes are selectable by model-ref
// prefix, each with its own GGUF identity leg:
//   - `--model ollama:<tag>`    -> `ollama_loopback`   (Ollama blob store)
//   - `--model llamacpp:<stem>` -> `llamacpp_loopback` (operator-declared
//     GGUF root/pin, bound to the path llama-server reports in `/props`)
// Other OpenAI-compatible runtimes (`lmstudio:`, `openai:`) are deliberately
// not selectable here: they arrive with their identity leg, one at a time.
//
// The adapter reports the `macprovider.gguf-file.v1` identity of the LOCAL
// GGUF file (never a runtime-reported digest), keeps the loopback constraints
// of SPEC-046-R002 (a closed per-path allowlist on a loopback-literal origin,
// bounded bodies, no redirects), and is NON-EARNING: relay-blind and signed
// receipts are disabled on this path (no local MLX tokenizer), so it never
// fabricates a `model_hash`-bound receipt. Receipts stay off via
// `isSettlementReceiptEligible == false` and `.notEligible` completions
// (#1695), independent of coordinator buyer-serving state, except for one
// request whose settlement metadata carries a matching SPEC-015 §N.12
// `pool_runtime_authorization` (#1690 M5). Usage is copied from the
// upstream runtime.

/// Serve-time recognition and normalization of an `ollama_loopback` model ref.
enum OllamaLoopbackServeModel {
    static let servedRefPrefix = "ollama:"
    static let runtimeSource = "ollama_loopback"
    static let defaultOrigin = "http://127.0.0.1:11434"

    /// True when `--model ollama:<tag>` selects the Ollama loopback runtime.
    static func isOllamaLoopbackRef(_ ref: String?) -> Bool {
        guard let ref else { return false }
        return ref.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(servedRefPrefix)
    }

    /// The model name the upstream Ollama chat-completions endpoint expects
    /// (`gemma3:270m`), derived by stripping the `ollama:` served-ref prefix.
    static func upstreamModelName(fromServedRef ref: String) -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(servedRefPrefix) else { return trimmed }
        return String(trimmed.dropFirst(servedRefPrefix.count))
    }

    /// Operator-scoped loopback origin. `MACPROVIDER_OLLAMA_ORIGIN` wins (kept
    /// for existing installs), then the `loopback_origin` config key, then the
    /// default 127.0.0.1:11434. The value is still loopback-validated at
    /// runtime construction, so a non-loopback override fails closed there.
    static func resolveOrigin(
        configured: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = LoopbackServeSelection.nonEmpty(environment["MACPROVIDER_OLLAMA_ORIGIN"]) {
            return override
        }
        return LoopbackServeSelection.nonEmpty(configured) ?? defaultOrigin
    }
}

/// Serve-time recognition of an `llamacpp_loopback` model ref. The prefix,
/// runtime source and default origin are the BYOM discovery vocabulary
/// (`BYOMLlamaCppModelStore` / `BYOMLlamaCppDiscovery`), so a discovered
/// candidate's `served_model_ref` is exactly what `--model` takes.
enum LlamaCppLoopbackServeModel {
    static let servedRefPrefix = BYOMLlamaCppModelStore.servedModelRefPrefix
    static let runtimeSource = BYOMLlamaCppDiscovery.runtimeSource
    static let defaultOrigin = BYOMLlamaCppDiscovery.defaultOrigin

    static func isLlamaCppLoopbackRef(_ ref: String?) -> Bool {
        guard let ref else { return false }
        return ref.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(servedRefPrefix)
    }

    /// llama-server serves one model and ignores the name, so the file stem
    /// is sent (never a filesystem path).
    static func upstreamModelName(fromServedRef ref: String) -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(servedRefPrefix) else { return trimmed }
        return String(trimmed.dropFirst(servedRefPrefix.count))
    }

    /// `loopback_origin` config key (or `MACPROVIDER_LOOPBACK_ORIGIN`), else
    /// the discovery default. llama-server's default port 8080 is also the
    /// provider's own serve port; the `/props` fingerprint at construction
    /// refuses anything that is not llama-server.
    static func resolveOrigin(configured: String?) -> String {
        LoopbackServeSelection.nonEmpty(configured) ?? defaultOrigin
    }
}

/// Which loopback runtime (if any) a `--model` ref selects.
enum LoopbackServeSelection: Equatable {
    case ollama
    case llamaCpp

    static func select(_ ref: String?) -> LoopbackServeSelection? {
        if OllamaLoopbackServeModel.isOllamaLoopbackRef(ref) { return .ollama }
        if LlamaCppLoopbackServeModel.isLlamaCppLoopbackRef(ref) { return .llamaCpp }
        return nil
    }

    var runtimeSource: String {
        switch self {
        case .ollama: return OllamaLoopbackServeModel.runtimeSource
        case .llamaCpp: return LlamaCppLoopbackServeModel.runtimeSource
        }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum OpenAICompatibleLoopbackRuntimeError: Error, CustomStringConvertible, Equatable {
    case invalidLoopbackOrigin(String)
    case artifactResolutionFailed(String)
    case identityChanged
    case upstreamNotRecognized(String)
    case upstreamStatus(Int)
    case malformedUpstreamResponse
    case emptyUpstreamContent

    var description: String {
        switch self {
        case .invalidLoopbackOrigin(let origin):
            return "loopback origin \(origin) is not a valid loopback HTTP origin (SPEC-046-R002)"
        case .artifactResolutionFailed(let reason):
            return "could not resolve/hash the local GGUF file for the served model: \(reason)"
        case .identityChanged:
            return "local GGUF file identity changed; refusing to report a stale hash (SPEC-010-R007(a))"
        case .upstreamNotRecognized(let runtimeSource):
            return "loopback origin does not answer as \(runtimeSource) (fingerprint failed)"
        case .upstreamStatus(let code):
            return "loopback runtime returned HTTP \(code)"
        case .malformedUpstreamResponse:
            return "loopback runtime response was malformed or exceeded bounds"
        case .emptyUpstreamContent:
            return "loopback runtime returned no assistant content"
        }
    }
}

/// A streamed loopback response: status, then the body split into lines
/// (blank lines preserved, so SSE event boundaries survive).
struct BYOMLoopbackLineResponse: Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>
}

/// A loopback client that can hand back the chat-completions body
/// incrementally. Cancelling the consuming task cancels the upstream request.
protocol BYOMLoopbackStreamingHTTPClient: BYOMDiscoveryHTTPClient {
    func postLines(
        _ url: URL,
        jsonBody: Data,
        maxHeaderBytes: Int,
        maxLineBytes: Int,
        maxTotalBytes: Int,
        timeouts: LoopbackGenerationTimeouts
    ) async throws -> BYOMLoopbackLineResponse
}

/// Generation-length-aware deadlines for one upstream call. `firstByte`
/// covers prefill of a long prompt; `idle` bounds a stalled stream once bytes
/// flow; `overall` scales with the token budget so a long generation is not
/// killed by a fixed per-request cap.
struct LoopbackGenerationTimeouts: Equatable, Sendable {
    let firstByte: TimeInterval
    let idle: TimeInterval
    let overall: TimeInterval
    /// The watchdog clock the streaming reader touches as bytes arrive, so a
    /// large event still in flight (no newline yet) is progress. Not part of
    /// equality.
    var byteProgress: LoopbackProgressClock?

    static func == (lhs: LoopbackGenerationTimeouts, rhs: LoopbackGenerationTimeouts) -> Bool {
        lhs.firstByte == rhs.firstByte && lhs.idle == rhs.idle && lhs.overall == rhs.overall
    }

    func withByteProgress(_ clock: LoopbackProgressClock) -> LoopbackGenerationTimeouts {
        var copy = self
        copy.byteProgress = clock
        return copy
    }

    static let firstByteSeconds: TimeInterval = 600
    static let idleSeconds: TimeInterval = 120
    static let overallBaseSeconds: TimeInterval = 600
    /// Floor decode rate the overall budget assumes (tokens/second).
    static let minimumTokensPerSecond: Double = 2
    static let overallCapSeconds: TimeInterval = 4 * 3600
    static let defaultTokenBudget = 32_768

    static func forGeneration(maxTokens: Int?, contextWindow: Int?) -> LoopbackGenerationTimeouts {
        let budget = max(1, maxTokens ?? contextWindow ?? defaultTokenBudget)
        let overall = min(overallCapSeconds, overallBaseSeconds + Double(budget) / minimumTokensPerSecond)
        return LoopbackGenerationTimeouts(firstByte: min(firstByteSeconds, overall), idle: idleSeconds, overall: overall)
    }
}

/// SPEC-046-R002 loopback HTTP leg for the serve proxy. Mirrors the discovery
/// client's safety posture (loopback-literal host check, no redirects, bounded
/// header/body) with a closed per-method path allowlist:
///   POST /v1/chat/completions, /apply-template, /tokenize; GET /props.
/// The last three are llama-server only (fingerprint, context window and the
/// prompt-token preflight); the Ollama path only ever posts chat completions.
final class LoopbackServeHTTPClient: BYOMLoopbackStreamingHTTPClient, @unchecked Sendable {
    static let allowedPOSTPaths: Set<String> = ["/v1/chat/completions", "/apply-template", "/tokenize"]
    static let allowedGETPaths: Set<String> = ["/props"]
    /// How much later than the runtime watchdog the URLSession timers fire.
    static let backstopSlackSeconds: TimeInterval = 30

    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    /// Timeouts for the small auxiliary calls (`/props`, `/apply-template`,
    /// `/tokenize`). Chat completions use `postLines` with per-generation
    /// deadlines instead.
    init(requestTimeout: TimeInterval = 60, resourceTimeout: TimeInterval = 120) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    static func isAllowed(_ url: URL, method: String) -> Bool {
        guard BYOMLoopbackOriginValidator.isSafeLoopbackHTTPURL(url), url.query == nil, url.fragment == nil else {
            return false
        }
        switch method {
        case "POST": return allowedPOSTPaths.contains(url.path)
        case "GET": return allowedGETPaths.contains(url.path)
        default: return false
        }
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard Self.isAllowed(url, method: "GET") else {
            throw BYOMDiscoveryAdapterError.rejectedNonLoopback
        }
        var request = Self.baseRequest(url)
        request.httpMethod = "GET"
        return try await collect(request, maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes)
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard Self.isAllowed(url, method: "POST") else {
            throw BYOMDiscoveryAdapterError.rejectedNonLoopback
        }
        var request = Self.baseRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = jsonBody
        return try await collect(request, maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes)
    }

    func postLines(
        _ url: URL,
        jsonBody: Data,
        maxHeaderBytes: Int,
        maxLineBytes: Int,
        maxTotalBytes: Int,
        timeouts: LoopbackGenerationTimeouts
    ) async throws -> BYOMLoopbackLineResponse {
        guard Self.isAllowed(url, method: "POST") else {
            throw BYOMDiscoveryAdapterError.rejectedNonLoopback
        }
        var request = Self.baseRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "accept")
        request.httpBody = jsonBody
        // URLSession's request timeout is an inactivity timer; the runtime's
        // own watchdog enforces the first-byte/idle/overall deadlines and is
        // the only timeout mapper. These backstops fire strictly later.
        let session = Self.makeSession(
            requestTimeout: max(timeouts.firstByte, timeouts.idle) + Self.backstopSlackSeconds,
            resourceTimeout: timeouts.overall + Self.backstopSlackSeconds
        )
        let opened: (URLSession.AsyncBytes, URLResponse)
        do {
            opened = try await session.bytes(for: request)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        let (bytes, response) = opened
        guard let http = response as? HTTPURLResponse else {
            session.invalidateAndCancel()
            throw BYOMDiscoveryAdapterError.malformed
        }
        guard BYOMDiscoveryHTTPBounds.headerBytes(Self.headers(of: http)) <= maxHeaderBytes else {
            session.invalidateAndCancel()
            throw BYOMDiscoveryAdapterError.truncated
        }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let reader = Task {
                do {
                    var splitter = LoopbackLineSplitter(maxLineBytes: maxLineBytes, maxTotalBytes: maxTotalBytes)
                    var sinceTouch = 0
                    for try await byte in bytes {
                        sinceTouch += 1
                        if sinceTouch >= 512 {
                            timeouts.byteProgress?.touch()
                            sinceTouch = 0
                        }
                        if let line = try splitter.append(byte) {
                            continuation.yield(line)
                        }
                    }
                    if let tail = splitter.finish() {
                        continuation.yield(tail)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                session.invalidateAndCancel()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                session.invalidateAndCancel()
            }
        }
        return BYOMLoopbackLineResponse(statusCode: http.statusCode, lines: lines)
    }

    private func collect(_ request: URLRequest, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        let session = Self.makeSession(requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BYOMDiscoveryAdapterError.malformed
        }
        let headers = Self.headers(of: http)
        guard BYOMDiscoveryHTTPBounds.headerBytes(headers) <= maxHeaderBytes else {
            throw BYOMDiscoveryAdapterError.truncated
        }
        var body = Data()
        body.reserveCapacity(min(maxBodyBytes, 64 * 1024))
        for try await byte in bytes {
            guard body.count < maxBodyBytes else {
                throw BYOMDiscoveryAdapterError.truncated
            }
            body.append(byte)
        }
        return BYOMHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }

    private static func baseRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    private static func headers(of http: HTTPURLResponse) -> [(String, String)] {
        http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String else { return nil }
            return (key, String(describing: value))
        }
    }

    private static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }
}

/// Byte-to-line splitter for a streamed body: `\n`, `\r\n` and a lone `\r`
/// each terminate a line, blank lines are kept (SSE event boundaries), and
/// both a single line and the whole body are bounded.
struct LoopbackLineSplitter {
    let maxLineBytes: Int
    let maxTotalBytes: Int
    private var buffer: [UInt8] = []
    private var total = 0
    /// The previous byte was a CR, so an LF right after it closes nothing.
    private var afterCR = false

    init(maxLineBytes: Int, maxTotalBytes: Int) {
        self.maxLineBytes = maxLineBytes
        self.maxTotalBytes = maxTotalBytes
    }

    mutating func append(_ byte: UInt8) throws -> String? {
        total += 1
        guard total <= maxTotalBytes else { throw BYOMDiscoveryAdapterError.truncated }
        let followsCR = afterCR
        afterCR = byte == 0x0D
        if byte == 0x0A {
            return followsCR ? nil : takeLine()
        }
        if byte == 0x0D {
            return takeLine()
        }
        guard buffer.count < maxLineBytes else { throw BYOMDiscoveryAdapterError.truncated }
        buffer.append(byte)
        return nil
    }

    mutating func finish() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }

    /// The same split applied to an already-buffered body.
    static func lines(of data: Data) -> [String] {
        var splitter = LoopbackLineSplitter(maxLineBytes: Int.max, maxTotalBytes: Int.max)
        var lines: [String] = []
        for byte in data {
            if let line = try? splitter.append(byte) { lines.append(line) }
        }
        if let tail = splitter.finish() { lines.append(tail) }
        return lines
    }
}

/// Server-sent-events framing over lines (WHATWG EventSource rules, reduced
/// to what chat-completions streams use): `data:` lines accumulate until a
/// blank line dispatches them joined by `\n`; comments and other fields are
/// ignored. Lines that are not SSE at all are reported so a runtime that
/// answered a streaming request with one plain JSON body can still be read.
struct LoopbackSSEParser {
    enum Event: Equatable {
        case data(String)
        case nonSSELine(String)
    }

    private var pending: [String] = []

    mutating func consume(line: String) -> [Event] {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") {
            return []
        }
        if line == "data" || line.hasPrefix("data:") {
            var value = line.dropFirst(4)
            if value.hasPrefix(":") { value = value.dropFirst() }
            if value.hasPrefix(" ") { value = value.dropFirst() }
            pending.append(String(value))
            return []
        }
        for field in ["event", "id", "retry"] where line == field || line.hasPrefix(field + ":") {
            return []
        }
        return [.nonSSELine(line)]
    }

    mutating func flush() -> [Event] {
        guard !pending.isEmpty else { return [] }
        let joined = pending.joined(separator: "\n")
        pending.removeAll()
        return [.data(joined)]
    }
}

/// Folds an upstream chat-completions stream (or a single non-streamed JSON
/// body) into `StreamChunk`s and the final `CompletionResult`. Pure: no I/O.
struct OpenAICompatibleStreamAccumulator {
    let maxBufferedBytes: Int
    /// Tool-call ids synthesized when the upstream omits one.
    private let makeToolCallID: () -> String

    private var sse = LoopbackSSEParser()
    private var content = ""
    private var finishReason: String?
    private var promptTokens: Int?
    private var completionTokens: Int?
    private var deltaEvents = 0
    private var sawSSEData = false
    private var nonSSEBody = ""
    private(set) var isDone = false
    private(set) var decodedFromPlainBody = false

    private struct PendingToolCall {
        var id: String
        var name: String
        var arguments: String
    }
    /// Upstream index -> dense index (order of first appearance), so the
    /// emitted indices match `CompletionResult.toolCalls` positions.
    private var denseIndexByUpstream: [Int: Int] = [:]
    private var toolCalls: [PendingToolCall] = []

    init(
        maxBufferedBytes: Int = OpenAICompatibleLoopbackRuntime.maxResponseBodyBytes,
        makeToolCallID: @escaping () -> String = { "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    ) {
        self.maxBufferedBytes = maxBufferedBytes
        self.makeToolCallID = makeToolCallID
    }

    mutating func consume(line: String) throws -> [StreamChunk] {
        let events = sse.consume(line: line)
        return try handle(events)
    }

    /// End of body: flush any undispatched event and build the result.
    mutating func finish() throws -> (result: CompletionResult, lateChunks: [StreamChunk]) {
        let pendingEvents = sse.flush()
        var late = try handle(pendingEvents)
        if !sawSSEData {
            let trimmed = nonSSEBody.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
            }
            let result = try OpenAICompatibleLoopbackRuntime.decodeUpstreamResponse(Data(trimmed.utf8))
            decodedFromPlainBody = true
            if !result.content.isEmpty {
                late.append(.content(result.content))
            }
            return (result, late)
        }
        // A clean EOF before the terminal event is a truncated stream.
        guard isDone else {
            throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
        }
        let calls = toolCalls.map { ToolCall(id: $0.id, functionName: $0.name, arguments: $0.arguments) }
        // The delta-event fallback is display-only: it depends on chunking,
        // so a completion without complete upstream usage never settles.
        let generated = completionTokens ?? deltaEvents
        let result = CompletionResult(
            content: content,
            finishReason: finishReason ?? (calls.isEmpty ? "stop" : "tool_calls"),
            promptTokens: promptTokens ?? 0,
            completionTokens: generated,
            generatedCompletionTokens: generated,
            toolCalls: calls.isEmpty ? nil : calls,
            settlementDisposition: promptTokens != nil && completionTokens != nil ? .notEligible : .usageUnattested
        )
        return (result, late)
    }

    private mutating func handle(_ events: [LoopbackSSEParser.Event]) throws -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        for event in events {
            switch event {
            case .nonSSELine(let line):
                guard !sawSSEData else { continue }
                guard nonSSEBody.utf8.count + line.utf8.count < maxBufferedBytes else {
                    throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
                }
                nonSSEBody += line + "\n"
            case .data(let payload):
                sawSSEData = true
                if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                    isDone = true
                    continue
                }
                chunks += try decodeChunk(payload)
            }
        }
        return chunks
    }

    private mutating func decodeChunk(_ payload: String) throws -> [StreamChunk] {
        guard case .object(let root) = try? StrictJSONParser.parse(payload) else {
            throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
        }
        if let error = root["error"], error != .null {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamStatus(500)
        }
        var hasUsage = false
        if case .object(let usage)? = root["usage"] {
            hasUsage = true
            promptTokens = OpenAICompatibleLoopbackRuntime.intValue(usage["prompt_tokens"]) ?? promptTokens
            completionTokens = OpenAICompatibleLoopbackRuntime.intValue(usage["completion_tokens"]) ?? completionTokens
        }
        // Keep-alives are SSE comments, never data. A data object is a
        // choices chunk or a usage-only chunk (`choices: []` plus `usage`).
        guard case .array(let choices)? = root["choices"] else {
            throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
        }
        guard case .object(let choice)? = choices.first else {
            guard choices.isEmpty, hasUsage else {
                throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
            }
            return []
        }
        if case .string(let reason)? = choice["finish_reason"], !reason.isEmpty {
            finishReason = reason
        }
        guard case .object(let delta)? = choice["delta"] else { return [] }
        var chunks: [StreamChunk] = []
        if case .string(let text)? = delta["content"], !text.isEmpty {
            guard content.utf8.count + text.utf8.count <= maxBufferedBytes else {
                throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
            }
            content += text
            deltaEvents += 1
            chunks.append(.content(text))
        }
        if case .array(let calls)? = delta["tool_calls"] {
            for case .object(let call) in calls {
                if let toolDelta = try decodeToolCallDelta(call) {
                    chunks.append(.toolCallDelta(toolDelta))
                }
            }
            deltaEvents += 1
        }
        return chunks
    }

    private mutating func decodeToolCallDelta(_ call: [String: JSONValue]) throws -> StreamToolCallDelta? {
        let upstreamIndex = OpenAICompatibleLoopbackRuntime.intValue(call["index"]) ?? 0
        var function: [String: JSONValue] = [:]
        if case .object(let value)? = call["function"] { function = value }
        // An upstream id the ingest boundary would reject when the buyer
        // echoes it back (llama-server emits bare random ids) is replaced.
        var id: String?
        if case .string(let value)? = call["id"], ChatCompletionRequest.isAcceptedToolCallID(value) { id = value }
        var type: String?
        if case .string(let value)? = call["type"], !value.isEmpty { type = value }
        var name: String?
        if case .string(let value)? = function["name"], !value.isEmpty { name = value }
        var arguments: String?
        if case .string(let value)? = function["arguments"] { arguments = value }

        let dense: Int
        let isFirst: Bool
        if let existing = denseIndexByUpstream[upstreamIndex] {
            dense = existing
            isFirst = false
        } else {
            guard toolCalls.count < 128 else {
                throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
            }
            dense = toolCalls.count
            denseIndexByUpstream[upstreamIndex] = dense
            toolCalls.append(PendingToolCall(id: id ?? makeToolCallID(), name: name ?? "", arguments: ""))
            isFirst = true
        }
        if !isFirst, let name, toolCalls[dense].name.isEmpty {
            toolCalls[dense].name = name
        }
        if let arguments, !arguments.isEmpty {
            guard toolCalls[dense].arguments.utf8.count + arguments.utf8.count <= maxBufferedBytes else {
                throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
            }
            toolCalls[dense].arguments += arguments
        }
        if isFirst {
            // OpenAI wire shape: the opening delta carries id/type/name.
            return StreamToolCallDelta(
                index: dense,
                id: toolCalls[dense].id,
                type: type ?? "function",
                functionName: toolCalls[dense].name,
                arguments: arguments ?? ""
            )
        }
        guard (arguments?.isEmpty == false) || name != nil else { return nil }
        return StreamToolCallDelta(index: dense, id: nil, type: nil, functionName: nil, arguments: arguments)
    }
}

/// A `ModelRuntimeServing` actor that proxies inference to a validated
/// loopback OpenAI-compatible runtime. ONE process, ONE model -- never a
/// second serve process beside an MLX runtime.
actor OpenAICompatibleLoopbackRuntime: ModelRuntimeServing {
    /// The upstream body is rebuilt from a request the ingest boundary already
    /// capped (`ChatCompletionRequest.rawBodyByteCap`); the slack covers
    /// re-encoding and the few fields the proxy adds.
    static let maxRequestBodyBytes = ChatCompletionRequest.rawBodyByteCap + 64 * 1024
    /// Bound on buffered assistant content / tool arguments / a plain body.
    static let maxResponseBodyBytes = 4 * 1024 * 1024
    /// Bound on the whole streamed body (SSE framing is ~20x the text).
    static let maxStreamBodyBytes = 128 * 1024 * 1024
    static let maxHeaderBytes = BYOMDiscoveryHTTPBounds.maxHeaderBytes
    static let maxPropsBodyBytes = 1024 * 1024
    static let maxTokenizeBodyBytes = 32 * 1024 * 1024

    /// The served ref reported to the coordinator, e.g. `ollama:gemma3:270m`.
    let servedModelRef: String
    /// The SPEC-046 runtime source reported in the hello (`ollama_loopback`).
    let runtimeSource: String
    /// The name the upstream endpoint expects, e.g. `gemma3:270m`.
    private let upstreamModelName: String
    /// Validated, path-stripped loopback origin (scheme+host+port only).
    private let origin: URL
    private let chatCompletionsURL: URL
    /// Path the runtime reported serving at bind time (llama.cpp `/props`);
    /// the llama.cpp locator requires it as proof. Never emitted.
    private let runtimeArtifactPath: String?
    private let catalogModelIDAlias: String?
    private let httpClient: any BYOMDiscoveryHTTPClient
    private let digestResolver: BYOMArtifactDigestResolver

    /// GGUF-file identity bound at construction and re-validated before every
    /// identity-binding report (SPEC-010-R007(a)).
    private let evidence: BYOMArtifactEvidence
    private var providerStatus: ProviderStatus?
    private var registrationCounter: Int = 0

    /// GGUF-file-path resolution goes through the runtime's locator:
    /// `ollama:<tag>` via `BYOMOllamaModelStore` (manifest -> model layer ->
    /// `blobs/sha256-<hex>`, the layer digest being only a LOCATOR), and
    /// `llamacpp:<stem>` via `BYOMLlamaCppModelStore` (operator root or pinned
    /// file, bound to the path llama-server reports serving).
    /// `BYOMArtifactDigestResolver.computeEvidence` hashes the COMPLETE file
    /// bytes over an open descriptor, binding the `macprovider.gguf-file.v1`
    /// digest to the file's (path, size, inode, mtime) and failing closed if
    /// that identity changes while hashing.
    init(
        servedModelRef: String,
        origin: String,
        runtimeSource: String = OllamaLoopbackServeModel.runtimeSource,
        runtimeArtifactPath: String? = nil,
        catalogModelIDAlias: String? = nil,
        httpClient: (any BYOMDiscoveryHTTPClient)? = nil,
        digestResolver: BYOMArtifactDigestResolver? = nil,
        deadline: Date? = nil
    ) throws {
        let trimmedRef = servedModelRef.trimmingCharacters(in: .whitespacesAndNewlines)
        self.servedModelRef = trimmedRef
        self.runtimeSource = runtimeSource
        self.upstreamModelName = runtimeSource == LlamaCppLoopbackServeModel.runtimeSource
            ? LlamaCppLoopbackServeModel.upstreamModelName(fromServedRef: trimmedRef)
            : OllamaLoopbackServeModel.upstreamModelName(fromServedRef: trimmedRef)
        guard let validatedOrigin = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else {
            throw OpenAICompatibleLoopbackRuntimeError.invalidLoopbackOrigin(origin)
        }
        self.origin = validatedOrigin
        self.chatCompletionsURL = validatedOrigin.appendingPathComponent("v1/chat/completions")
        self.runtimeArtifactPath = runtimeArtifactPath
        self.catalogModelIDAlias = catalogModelIDAlias.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.httpClient = httpClient ?? LoopbackServeHTTPClient()
        let resolver = digestResolver ?? BYOMArtifactDigestResolver(
            store: BYOMOllamaModelStore(root: BYOMOllamaModelStore.defaultRoot()),
            cache: BYOMArtifactDigestCache(url: BYOMArtifactDigestCache.defaultURL())
        )
        self.digestResolver = resolver
        do {
            self.evidence = try resolver.computeEvidence(
                runtimeSource: runtimeSource,
                servedModelRef: trimmedRef,
                runtimeArtifactPath: runtimeArtifactPath,
                deadline: deadline
            )
        } catch {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed(String(describing: error))
        }
    }

    /// `llamacpp:<stem>`: fingerprint the origin as llama-server (`/props`),
    /// take the path it reports serving as binding proof, and hash the file
    /// the operator-declared selector resolves for that stem. No selector, a
    /// path outside it, or a stem mismatch fails closed (no identity).
    static func llamaCpp(
        servedModelRef: String,
        origin: String,
        selector: BYOMLlamaCppArtifactSelector,
        catalogModelIDAlias: String? = nil,
        httpClient: (any BYOMDiscoveryHTTPClient)? = nil,
        cache: BYOMArtifactDigestCache = BYOMArtifactDigestCache(url: BYOMArtifactDigestCache.defaultURL()),
        deadline: Date? = nil
    ) async throws -> OpenAICompatibleLoopbackRuntime {
        guard let validatedOrigin = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else {
            throw OpenAICompatibleLoopbackRuntimeError.invalidLoopbackOrigin(origin)
        }
        let client = httpClient ?? LoopbackServeHTTPClient()
        let props: BYOMHTTPResponse
        do {
            props = try await client.get(
                validatedOrigin.appendingPathComponent("props"),
                maxHeaderBytes: maxHeaderBytes,
                maxBodyBytes: maxPropsBodyBytes
            )
        } catch {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(LlamaCppLoopbackServeModel.runtimeSource)
        }
        guard props.statusCode == 200, BYOMDiscoveryJSON.isLlamaCppProps(props.body) else {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(LlamaCppLoopbackServeModel.runtimeSource)
        }
        let servedPath = BYOMDiscoveryJSON.llamaCppServedArtifactPath(from: props.body)
        let resolver = BYOMArtifactDigestResolver(
            locators: [BYOMLlamaCppModelStore(root: selector.root, pinnedFile: selector.pinnedFile)],
            cache: cache
        )
        return try OpenAICompatibleLoopbackRuntime(
            servedModelRef: servedModelRef,
            origin: origin,
            runtimeSource: LlamaCppLoopbackServeModel.runtimeSource,
            runtimeArtifactPath: servedPath,
            catalogModelIDAlias: catalogModelIDAlias,
            httpClient: client,
            digestResolver: resolver,
            deadline: deadline
        )
    }

    // MARK: ModelRuntimeServing identity surface

    var loadedModelHash: String? { identityIsValid() ? evidence.digest : nil }
    var loadedModelHashAlgorithm: String? { evidence.algorithm }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    /// Non-earning loopback path (#1695): never sign a SPEC-015 receipt on
    /// settlement metadata alone. The one exception (SPEC-015 §N.12, #1690
    /// M5) is a request whose metadata carries a `pool_runtime_authorization`
    /// naming this runtime's `runtime_source`.
    nonisolated var isSettlementReceiptEligible: Bool { false }
    nonisolated var settlementRuntimeSource: String? { runtimeSource }

    func setProviderStatus(_ providerStatus: ProviderStatus) {
        self.providerStatus = providerStatus
    }

    func currentSnapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: servedModelRef,
            modelHash: loadedModelHash,
            modelHashAlgorithm: loadedModelHashAlgorithm
        )
    }

    // MARK: ModelRuntimeServing inference surface

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        guard identityIsValid() else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        try request.validateModelMatches(servedModelRef, aliases: modelIDAliasList(catalogModelIDAlias))
        registrationCounter += 1
        return RequestHandle(
            snapshot: snapshot(),
            registrationID: registrationCounter,
            drainCancelled: DrainCancelToken()
        )
    }

    func unregisterInFlight(_ id: Int) {}

    /// Context / max_tokens gate before any response head is written. Only a
    /// runtime that reports its context window can be gated (llama-server
    /// `/props` `n_ctx`, per slot); Ollama's OpenAI surface reports none, so
    /// an over-context Ollama request fails upstream and maps to the same
    /// error vocabulary. Fails closed when the runtime is unreachable or now
    /// serves a different file than the one bound at startup.
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        try handle.drainCancelled.check()
        _ = try await upstreamContextGate(request)
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> CompletionResult {
        guard identityIsValid() else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        try request.validateModelMatches(servedModelRef, aliases: modelIDAliasList(catalogModelIDAlias))
        let contextWindow = try await upstreamContextGate(request)
        return try await proxy(request, contextWindow: contextWindow, shouldCancel: shouldCancel, onChunk: nil)
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        // Real pass-through: each upstream SSE delta becomes a StreamChunk as
        // it arrives (content and tool-call deltas). The context gate already
        // ran in preflight(); the relay and HTTP paths always call it first.
        try await proxy(request, contextWindow: nil, shouldCancel: shouldCancel, onChunk: onChunk)
    }

    // MARK: Internals

    /// Re-resolve the served ref through the locator and confirm the file's
    /// (path, size, inode, mtime) still matches what was hashed. A re-pointed
    /// reference or an in-place rewrite fails closed rather than report a
    /// stale digest (SPEC-010-R007(a)).
    private func identityIsValid() -> Bool {
        (try? digestResolver.validateCurrent(
            evidence,
            runtimeSource: runtimeSource,
            servedModelRef: servedModelRef,
            runtimeArtifactPath: runtimeArtifactPath
        )) != nil
    }

    private func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: servedModelRef,
            modelHash: identityIsValid() ? evidence.digest : nil,
            modelHashAlgorithm: evidence.algorithm
        )
    }

    private var isLlamaCpp: Bool { runtimeSource == LlamaCppLoopbackServeModel.runtimeSource }

    /// llama.cpp only: re-read `/props`, require the bound file is still the
    /// one served, then gate prompt + max_tokens against `n_ctx`. Returns the
    /// context window used (nil when the runtime reports none).
    private func upstreamContextGate(_ request: ChatCompletionRequest) async throws -> Int? {
        guard isLlamaCpp else { return nil }
        let props: BYOMHTTPResponse
        do {
            props = try await httpClient.get(
                origin.appendingPathComponent("props"),
                maxHeaderBytes: Self.maxHeaderBytes,
                maxBodyBytes: Self.maxPropsBodyBytes
            )
        } catch {
            throw APIError(status: 502, message: "Upstream loopback error", type: "server_error", code: "upstream_unavailable")
        }
        guard props.statusCode == 200, BYOMDiscoveryJSON.isLlamaCppProps(props.body) else {
            throw APIError(status: 502, message: "Upstream loopback status \(props.statusCode)", type: "server_error", code: "upstream_error")
        }
        guard BYOMDiscoveryJSON.llamaCppServedArtifactPath(from: props.body) == runtimeArtifactPath else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        guard let contextWindow = BYOMDiscoveryJSON.llamaCppContextWindow(from: props.body) else {
            return nil
        }
        // max_tokens alone is checked before spending two loopback calls.
        try Self.contextGate(promptTokens: nil, maxTokens: request.maxTokens, contextWindow: contextWindow)
        let promptTokens = await countPromptTokens(request)
        try Self.contextGate(promptTokens: promptTokens, maxTokens: request.maxTokens, contextWindow: contextWindow)
        return contextWindow
    }

    /// Exact prompt length as llama-server will see it: its own chat template
    /// (`/apply-template`, same messages and tools) then its own tokenizer
    /// (`/tokenize`). Best effort: nil when either call fails, in which case
    /// the upstream's own context check still rejects (mapped to 413).
    private func countPromptTokens(_ request: ChatCompletionRequest) async -> Int? {
        var templateBody: [String: Any] = ["messages": request.promptSource.messages.map(\.jsonObject)]
        if let tools = request.promptSource.tools, tools != .null {
            templateBody["tools"] = tools.jsonObject
        }
        guard let templateData = try? JSONSerialization.data(withJSONObject: templateBody, options: [.withoutEscapingSlashes]),
              templateData.count <= Self.maxRequestBodyBytes,
              let templated = try? await httpClient.post(
                  origin.appendingPathComponent("apply-template"),
                  jsonBody: templateData,
                  maxHeaderBytes: Self.maxHeaderBytes,
                  maxBodyBytes: Self.maxRequestBodyBytes * 2
              ),
              templated.statusCode == 200,
              let prompt = Self.decodeTemplatedPrompt(templated.body)
        else { return nil }
        let tokenizeBody: [String: Any] = ["content": prompt, "add_special": false, "parse_special": true]
        guard let tokenizeData = try? JSONSerialization.data(withJSONObject: tokenizeBody, options: [.withoutEscapingSlashes]),
              let tokenized = try? await httpClient.post(
                  origin.appendingPathComponent("tokenize"),
                  jsonBody: tokenizeData,
                  maxHeaderBytes: Self.maxHeaderBytes,
                  maxBodyBytes: Self.maxTokenizeBodyBytes
              ),
              tokenized.statusCode == 200
        else { return nil }
        return Self.decodeTokenCount(tokenized.body)
    }

    private func proxy(
        _ request: ChatCompletionRequest,
        contextWindow: Int?,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: (@Sendable (StreamChunk) -> Void)?
    ) async throws -> CompletionResult {
        if shouldCancel() { throw CancellationError() }
        let body = try Self.encodeUpstreamRequest(request, upstreamModelName: upstreamModelName)
        let clock = LoopbackProgressClock()
        let timeouts = LoopbackGenerationTimeouts.forGeneration(maxTokens: request.maxTokens, contextWindow: contextWindow)
            .withByteProgress(clock)
        let client = httpClient
        let url = chatCompletionsURL

        return try await withThrowingTaskGroup(of: CompletionResult?.self) { group in
            group.addTask {
                let response: BYOMLoopbackLineResponse
                do {
                    response = try await Self.openLines(client, url: url, body: body, timeouts: timeouts)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .timedOut {
                    throw Self.upstreamTimeoutError
                } catch {
                    throw APIError(status: 502, message: "Upstream loopback error", type: "server_error", code: "upstream_unavailable")
                }
                guard (200...299).contains(response.statusCode) else {
                    // The status decides the mapping; a failed or cut-off
                    // error body only loses detail.
                    var errorBody = Data()
                    do {
                        for try await line in response.lines {
                            guard errorBody.count < 64 * 1024 else { break }
                            errorBody.append(contentsOf: Array((line + "\n").utf8))
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {}
                    throw Self.mapUpstreamError(status: response.statusCode, body: errorBody)
                }
                var accumulator = OpenAICompatibleStreamAccumulator()
                do {
                    for try await line in response.lines {
                        clock.touch()
                        for chunk in try accumulator.consume(line: line) {
                            onChunk?(chunk)
                        }
                        if accumulator.isDone { break }
                    }
                    let (result, late) = try accumulator.finish()
                    for chunk in late {
                        onChunk?(chunk)
                    }
                    return result
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as APIError {
                    throw error
                } catch let error as URLError where error.code == .timedOut {
                    throw Self.upstreamTimeoutError
                } catch {
                    // A malformed/truncated upstream body is an upstream fault,
                    // surfaced as 502 rather than a generic 500.
                    throw APIError(status: 502, message: "Upstream loopback response malformed", type: "server_error", code: "upstream_error")
                }
            }
            group.addTask {
                // Watchdog: honour caller cancellation and the generation
                // deadlines. Throwing here cancels the reader task, which
                // cancels the upstream HTTP request (the runtime stops
                // generating when its client goes away).
                while true {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if shouldCancel() { throw CancellationError() }
                    if clock.hasExpired(timeouts) {
                        throw Self.upstreamTimeoutError
                    }
                }
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let result = next { return result }
            }
            throw APIError(status: 502, message: "Upstream loopback error", type: "server_error", code: "upstream_unavailable")
        }
    }

    /// The one mapping for every upstream deadline, whichever timer fires.
    static let upstreamTimeoutError = APIError(
        status: 504,
        message: "Upstream loopback timed out",
        type: "server_error",
        code: "provider_timeout"
    )

    private static func openLines(
        _ client: any BYOMDiscoveryHTTPClient,
        url: URL,
        body: Data,
        timeouts: LoopbackGenerationTimeouts
    ) async throws -> BYOMLoopbackLineResponse {
        if let streaming = client as? any BYOMLoopbackStreamingHTTPClient {
            return try await streaming.postLines(
                url,
                jsonBody: body,
                maxHeaderBytes: maxHeaderBytes,
                maxLineBytes: maxResponseBodyBytes,
                maxTotalBytes: maxStreamBodyBytes,
                timeouts: timeouts
            )
        }
        // A buffered-only client (tests, fixtures): same line pipeline over
        // the whole body.
        let response = try await client.post(url, jsonBody: body, maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxResponseBodyBytes)
        let lines = LoopbackLineSplitter.lines(of: response.body)
        return BYOMLoopbackLineResponse(
            statusCode: response.statusCode,
            lines: AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        )
    }

    // MARK: Pure mapping (unit-tested)

    /// The upstream request: the buyer's request as parsed at ingest, with the
    /// served ref replaced by the upstream model name and streaming always on
    /// (so cancellation and idle deadlines work for non-streamed buyers too).
    /// Messages are forwarded as received (content parts, `name`,
    /// `tool_calls`, `tool_call_id`), and every sampling / structured-output
    /// field the ingest boundary validated is carried through.
    static func encodeUpstreamRequest(_ request: ChatCompletionRequest, upstreamModelName: String) throws -> Data {
        let source = request.promptSource
        var payload: [String: Any] = [
            "model": upstreamModelName,
            "messages": source.messages.map(\.jsonObject),
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": request.temperature,
        ]
        if let maxTokens = request.maxTokens {
            payload["max_tokens"] = maxTokens
        }
        if !request.stop.isEmpty {
            payload["stop"] = request.stop
        }
        let passthrough: [(String, JSONValue?)] = [
            ("top_p", source.topP),
            ("seed", source.seed),
            ("presence_penalty", source.presencePenalty),
            ("frequency_penalty", source.frequencyPenalty),
            ("response_format", source.responseFormat),
            ("tools", source.tools),
            ("tool_choice", source.toolChoice),
            ("logit_bias", source.logitBias),
        ]
        for (key, value) in passthrough {
            if let value, value != .null {
                payload[key] = value.jsonObject
            }
        }
        if let parallelToolCalls = request.parallelToolCalls {
            payload["parallel_tool_calls"] = parallelToolCalls
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        guard data.count <= maxRequestBodyBytes else {
            throw APIError(status: 413, message: "Request body exceeds 4 MiB", code: "request_body_too_large")
        }
        return data
    }

    /// Context gate in the MLX runtime's vocabulary (413
    /// `context_length_exceeded`). `max_tokens` alone may not exceed the
    /// window; with a known prompt length, prompt + max_tokens (or + 1 when
    /// max_tokens is omitted) must fit.
    static func contextGate(promptTokens: Int?, maxTokens: Int?, contextWindow: Int) throws {
        if let maxTokens, maxTokens > contextWindow {
            throw APIError(
                status: 413,
                message: "max_tokens (\(maxTokens)) exceeds this provider's context window (\(contextWindow) tokens).",
                type: "context_length_exceeded",
                code: "context_length_exceeded",
                param: "max_tokens"
            )
        }
        guard let promptTokens else { return }
        let needed = promptTokens + (maxTokens ?? 1)
        guard needed <= contextWindow else {
            throw APIError(
                status: 413,
                message: "Prompt length (\(promptTokens) tokens) plus max_tokens (\(maxTokens ?? 1)) exceeds this provider's context window (\(contextWindow) tokens).",
                type: "context_length_exceeded",
                code: "context_length_exceeded",
                param: "messages"
            )
        }
    }

    /// Non-2xx upstream status -> buyer error. A request the runtime rejects
    /// as over-context is the buyer's 413 `context_length_exceeded`; any other
    /// 400/422 is the buyer's 400; everything else is an upstream fault (502).
    /// The upstream message is never echoed (it can carry local paths).
    static func mapUpstreamError(status: Int, body: Data) -> APIError {
        var errorType: String?
        var errorCode: String?
        if let text = String(data: body.prefix(64 * 1024), encoding: .utf8),
           case .object(let root)? = try? StrictJSONParser.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           case .object(let error)? = root["error"] {
            if case .string(let value)? = error["type"] { errorType = value }
            if case .string(let value)? = error["code"] { errorCode = value }
        }
        if errorType == "exceed_context_size_error" || errorCode == "context_length_exceeded" {
            return APIError(
                status: 413,
                message: "Prompt exceeds this provider's context window.",
                type: "context_length_exceeded",
                code: "context_length_exceeded",
                param: "messages"
            )
        }
        if status == 400 || status == 422 {
            return APIError(status: 400, message: "Upstream loopback rejected the request", code: "invalid_request")
        }
        return APIError(status: 502, message: "Upstream loopback status \(status)", type: "server_error", code: "upstream_error")
    }

    /// A non-streamed chat completion body. `message.content` may be null
    /// (a tool-call reply); tool calls are decoded with string or object
    /// arguments.
    static func decodeUpstreamResponse(_ data: Data) throws -> CompletionResult {
        guard data.count <= maxResponseBodyBytes,
              let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .array(let choices)? = root["choices"],
              case .object(let firstChoice)? = choices.first,
              case .object(let message)? = firstChoice["message"] else {
            throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
        }
        let content: String
        switch message["content"] {
        case .string(let value)?:
            content = value
        case .null?, nil:
            content = ""
        default:
            throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
        }
        var toolCalls: [ToolCall] = []
        if case .array(let calls)? = message["tool_calls"] {
            for case .object(let call) in calls {
                guard case .object(let function)? = call["function"],
                      case .string(let name)? = function["name"], !name.isEmpty else {
                    throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
                }
                let arguments: String
                switch function["arguments"] {
                case .string(let value)?:
                    arguments = value
                case .object?, .array?:
                    arguments = (try? function["arguments"]?.deterministicJSONString()) ?? "{}"
                default:
                    arguments = "{}"
                }
                var id = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                if case .string(let value)? = call["id"], ChatCompletionRequest.isAcceptedToolCallID(value) { id = value }
                toolCalls.append(ToolCall(id: id, functionName: name, arguments: arguments))
            }
        }
        var finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"
        if case .string(let reason)? = firstChoice["finish_reason"], !reason.isEmpty {
            finishReason = reason
        }
        var completionTokens: Int?
        var promptTokens: Int?
        if case .object(let usage)? = root["usage"] {
            completionTokens = intValue(usage["completion_tokens"])
            promptTokens = intValue(usage["prompt_tokens"])
        }
        return CompletionResult(
            content: content,
            finishReason: finishReason,
            promptTokens: promptTokens ?? 0,
            completionTokens: completionTokens ?? 0,
            generatedCompletionTokens: completionTokens ?? 0,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            settlementDisposition: promptTokens != nil && completionTokens != nil ? .notEligible : .usageUnattested
        )
    }

    /// `/apply-template` -> `{"prompt": "..."}`.
    static func decodeTemplatedPrompt(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root)? = try? StrictJSONParser.parse(text),
              case .string(let prompt)? = root["prompt"] else { return nil }
        return prompt
    }

    /// `/tokenize` -> `{"tokens": [...]}` -> count.
    static func decodeTokenCount(_ data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root)? = try? StrictJSONParser.parse(text),
              case .array(let tokens)? = root["tokens"] else { return nil }
        return tokens.count
    }

    static func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let tokens) where tokens >= 0:
            return tokens
        case .double(let tokens) where tokens.isFinite && tokens >= 0 && tokens.rounded(.towardZero) == tokens:
            return Int(exactly: tokens)
        default:
            return nil
        }
    }
}

/// Last-progress clock shared between the upstream reader and its watchdog.
final class LoopbackProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt: Date
    private var lastProgress: Date?

    init(now: Date = Date()) {
        self.startedAt = now
    }

    func touch(now: Date = Date()) {
        lock.lock()
        lastProgress = now
        lock.unlock()
    }

    func hasExpired(_ timeouts: LoopbackGenerationTimeouts, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if now.timeIntervalSince(startedAt) > timeouts.overall { return true }
        guard let lastProgress else {
            return now.timeIntervalSince(startedAt) > timeouts.firstByte
        }
        return now.timeIntervalSince(lastProgress) > timeouts.idle
    }
}
