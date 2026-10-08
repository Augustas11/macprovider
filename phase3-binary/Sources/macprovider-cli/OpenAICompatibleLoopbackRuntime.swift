import Foundation
import MacProviderCore

// SPEC-046-R002 / SPEC-010-R007(e) loopback serving adapter (issues #1569, #1690 M2).
//
// One `macprovider-cli serve` process can serve a GGUF hosted by a loopback
// OpenAI-compatible runtime by proxying inference to that runtime's
// `/v1/chat/completions` endpoint. Three runtimes are selectable by model-ref
// prefix, each with its own identity leg:
//   - `--model ollama:<tag>`    -> `ollama_loopback`   (Ollama blob store)
//   - `--model llamacpp:<stem>` -> `llamacpp_loopback` (operator-declared
//     GGUF root/pin, bound to the path llama-server reports in `/props`)
//   - `--model mlxlm:<name>`    -> `mlxlm_loopback`    (operator-declared MLX
//     snapshot, bound to the path mlx_lm.server lists in `/v1/models`;
//     SPEC-010-R009, #1690 M8)
//   - `--model lmstudio:<key>`  -> `lmstudio_loopback` (the GGUF the LM Studio
//     models root resolves for the key, bound to LM Studio's `/api/v1/models`
//     entry for it; SPEC-010-R007(i), #1690 M9)
//   - `--model omlx:<name>`     -> `omlx_loopback`     (operator-declared MLX
//     snapshot, bound to the oMLX `/v1/models/status` entry whose
//     `model_path` it is; SPEC-010-R009, #1690 M9)
// Other OpenAI-compatible runtimes (`openai:`) are deliberately not
// selectable here: they arrive with their identity leg, one at a time.
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
// upstream runtime; a cancelled stream's usage covers exactly the content
// received (SPEC-015 §N.12 item 7, #1690 E2E-F3 / M9).

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
    case mlxLM
    case lmStudio
    case oMLX

    static func select(_ ref: String?) -> LoopbackServeSelection? {
        if OllamaLoopbackServeModel.isOllamaLoopbackRef(ref) { return .ollama }
        if LlamaCppLoopbackServeModel.isLlamaCppLoopbackRef(ref) { return .llamaCpp }
        if MLXLMLoopbackServeModel.isMLXLMLoopbackRef(ref) { return .mlxLM }
        if LMStudioLoopbackServeModel.isLMStudioLoopbackRef(ref) { return .lmStudio }
        if OMLXLoopbackServeModel.isOMLXLoopbackRef(ref) { return .oMLX }
        return nil
    }

    var runtimeSource: String {
        switch self {
        case .ollama: return OllamaLoopbackServeModel.runtimeSource
        case .llamaCpp: return LlamaCppLoopbackServeModel.runtimeSource
        case .mlxLM: return MLXLMLoopbackServeModel.runtimeSource
        case .lmStudio: return LMStudioLoopbackServeModel.runtimeSource
        case .oMLX: return OMLXLoopbackServeModel.runtimeSource
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

/// The loopback startup throughput probe's result (SPEC-001 FR-20). A failure
/// carries a closed reason code and reports a 0 estimate.
enum LoopbackStartupThroughputOutcome: Equatable, Sendable {
    case ok(tps: Double)
    case failed(reason: String)

    var tps: Double {
        if case .ok(let tps) = self { return tps }
        return 0
    }

    /// The one structured log line for the probe; never carries text.
    func logLine(runtimeSource: String) -> String {
        switch self {
        case .ok(let tps):
            return "event=loopback_startup_throughput_probe outcome=ok tps=\(String(format: "%.2f", tps)) runtime_source=\(runtimeSource)"
        case .failed(let reason):
            return "event=loopback_startup_throughput_probe outcome=failed reason=\(reason) runtime_source=\(runtimeSource)"
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
///   POST /v1/chat/completions, /apply-template, /tokenize;
///   GET /props, /v1/models, /api/v1/models, /v1/models/status.
/// `/apply-template`, `/tokenize` and `/props` are llama-server only
/// (fingerprint, context window and the prompt-token preflight); `/v1/models`
/// binds mlx_lm.server, `/api/v1/models` binds LM Studio and
/// `/v1/models/status` binds oMLX (#1690 M9); the Ollama path only ever
/// posts chat completions.
final class LoopbackServeHTTPClient: BYOMLoopbackStreamingHTTPClient, @unchecked Sendable {
    static let allowedPOSTPaths: Set<String> = ["/v1/chat/completions", "/apply-template", "/tokenize"]
    static let allowedGETPaths: Set<String> = ["/props", "/v1/models", "/api/v1/models", "/v1/models/status"]
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
    /// #1690 E2E-F3: the upstream's per-token usage at each content chunk
    /// (content UTF-8 bytes -> completion tokens through them); nil once a
    /// content chunk arrives without it. llama-server `timings_per_token`
    /// also reports the prompt tokens; a per-chunk `logprobs` list (Ollama,
    /// LM Studio; #1690 M9) counts only the completion tokens.
    private var prefixCompletionTokens: [Int: Int]? = [0: 0]
    private var prefixPromptTokens: Int?
    private var prefixCountSource: PrefixCountSource?
    /// Completion tokens the upstream listed in `logprobs` so far, on any
    /// chunk (content, tool call, or none).
    private var logprobTokens = 0

    private enum PrefixCountSource {
        case timings
        case logprobs
    }
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
            let decoded = try OpenAICompatibleLoopbackRuntime.decodeUpstreamResponse(Data(trimmed.utf8))
            // #1690: a plain JSON body has no per-chunk counts, so no proper
            // prefix of its content has attested usage. The empty table makes
            // a cancelled partial delivery unattested (never signed) instead
            // of keeping the whole completion's usage.
            let result = CompletionResult(
                content: decoded.content,
                finishReason: decoded.finishReason,
                promptTokens: decoded.promptTokens,
                completionTokens: decoded.completionTokens,
                generatedCompletionTokens: decoded.generatedCompletionTokens,
                toolCalls: decoded.toolCalls,
                settlementDisposition: decoded.settlementDisposition,
                loopbackPrefixCompletionTokens: [:]
            )
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
            settlementDisposition: promptTokens != nil && completionTokens != nil ? .notEligible : .usageUnattested,
            loopbackPrefixCompletionTokens: prefixCompletionTokens ?? [:]
        )
        return (result, late)
    }

    /// The content received so far (#1690 M9: what a cancelled stream's
    /// usage is counted over).
    var receivedContent: String { content }

    /// The upstream's own `usage.completion_tokens`, never the delta-event
    /// count (SPEC-001 FR-20 startup probe).
    var upstreamCompletionTokens: Int? { completionTokens }

    /// Content-bearing deltas streamed so far (SPEC-001 FR-20 startup probe
    /// cap: an upstream count above it is never believed).
    var contentDeltaCount: Int { deltaEvents }

    /// True when the upstream attested the completion tokens through every
    /// content chunk so far (timings or `logprobs`).
    var hasPerChunkCompletionCounts: Bool { prefixCompletionTokens != nil && prefixCountSource != nil }

    /// True once a tool-call delta streamed; a content recount never covers it.
    var streamedToolCall: Bool { !toolCalls.isEmpty }

    /// The result of a stream the buyer cancelled: the content received so
    /// far, and its per-prefix usage only when the upstream attested it for
    /// every content chunk (else unattested, so never signed).
    ///
    /// #1690 M9: a runtime whose stream carries no prompt count passes the
    /// upstream's own prompt count for the same request
    /// (`upstreamPromptTokens`). `recountedCompletionTokens` is the
    /// `mlxlm_loopback` count of the whole received content with the served
    /// snapshot's tokenizer; it binds only that content (and the empty
    /// prefix). A streamed tool-call delta leaves the result unattested on
    /// every count path (timings, `logprobs`, recount): the relay has no
    /// delivered prefix for tool-call deltas (SPEC-015 item 7, R2 SECURITY).
    func cancelledResult(upstreamPromptTokens: Int? = nil, recountedCompletionTokens: Int? = nil) -> CompletionResult {
        let calls = toolCalls.map { ToolCall(id: $0.id, functionName: $0.name, arguments: $0.arguments) }
        var table = prefixCompletionTokens
        if let recountedCompletionTokens {
            table = [0: 0, content.utf8.count: recountedCompletionTokens]
        }
        if !calls.isEmpty {
            table = nil
        }
        let prompt = prefixPromptTokens ?? upstreamPromptTokens
        let attested = table != nil && prompt != nil
        let generated = table?[content.utf8.count] ?? deltaEvents
        return CompletionResult(
            content: content,
            finishReason: "",
            promptTokens: prompt ?? 0,
            completionTokens: generated,
            generatedCompletionTokens: generated,
            toolCalls: calls.isEmpty ? nil : calls,
            settlementDisposition: attested ? .notEligible : .usageUnattested,
            loopbackPrefixCompletionTokens: attested ? table : [:]
        )
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
        // llama-server `timings_per_token`: prompt tokens are the processed
        // plus the cached ones (its `usage.prompt_tokens`).
        var chunkTimings: (prompt: Int, completion: Int)?
        if case .object(let timings)? = root["timings"],
           let promptN = OpenAICompatibleLoopbackRuntime.intValue(timings["prompt_n"]),
           let cacheN = OpenAICompatibleLoopbackRuntime.intValue(timings["cache_n"]),
           let predictedN = OpenAICompatibleLoopbackRuntime.intValue(timings["predicted_n"]) {
            chunkTimings = (promptN + cacheN, predictedN)
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
        // #1690 M9: a per-chunk `logprobs.content` list names each token the
        // chunk carries, so its running length is the completion tokens
        // generated through the chunk.
        var chunkLogprobTokens: Int?
        if case .object(let logprobs)? = choice["logprobs"], case .array(let entries)? = logprobs["content"] {
            logprobTokens += entries.count
            chunkLogprobTokens = logprobTokens
        }
        guard case .object(let delta)? = choice["delta"] else { return [] }
        var chunks: [StreamChunk] = []
        if case .string(let text)? = delta["content"], !text.isEmpty {
            guard content.utf8.count + text.utf8.count <= maxBufferedBytes else {
                throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
            }
            content += text
            deltaEvents += 1
            // One source per stream: a chunk without it, or with the other
            // one, leaves every later prefix unattested.
            let source: PrefixCountSource? = chunkTimings != nil ? .timings : (chunkLogprobTokens != nil ? .logprobs : nil)
            if prefixCompletionTokens != nil, let source, prefixCountSource == nil || prefixCountSource == source {
                prefixCountSource = source
                if let chunkTimings {
                    prefixCompletionTokens?[content.utf8.count] = chunkTimings.completion
                    prefixPromptTokens = chunkTimings.prompt
                } else if let chunkLogprobTokens {
                    prefixCompletionTokens?[content.utf8.count] = chunkLogprobTokens
                }
            } else {
                prefixCompletionTokens = nil
            }
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

    /// The artifact identity bound at construction and re-validated before
    /// every identity-binding report: a GGUF file (SPEC-010-R007(a)) or, for
    /// `mlxlm_loopback` and `omlx_loopback`, an MLX snapshot
    /// (SPEC-010-R009(a)).
    private let identity: LoopbackServedIdentity
    /// `lmstudio_loopback`: the `/api/v1/models` entry the runtime must keep
    /// listing for the bound file (SPEC-046-R009, #1690 M9).
    private let lmStudioBinding: LMStudioLoopbackServeModel.Binding?
    /// #1690 M9: the pinned tokenizer a cancelled stream's delivered content
    /// is counted with when the upstream attests no per-chunk count. It is
    /// loaded when serving starts from a hash-verified snapshot: the served
    /// one (MLX runtimes) or, for a GGUF runtime, the catalog row's verified
    /// plain MLX artifact directory (`siblingSnapshotDirectories`, the
    /// durable-store copy then the macprovider-downloaded Hugging Face
    /// snapshot, as native serving verifies them) whose snapshot-manifest
    /// digest equals the signed row's (`siblingSnapshotSHA256`). A
    /// symlinked huggingface_hub cache is refused, as native serving refuses
    /// it. Nil when none is available.
    private let recountTokenizer: Task<PinnedSnapshotTokenizer?, Never>?
    /// Startup capacity is advisory, unlike cancellation receipt counting.
    /// An expected binding must never silently downgrade when unavailable.
    private let startupRecountRequired: Bool
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
        mlxSnapshot: MLXSnapshotIdentity? = nil,
        lmStudioBinding: LMStudioLoopbackServeModel.Binding? = nil,
        upstreamModelID: String? = nil,
        siblingSnapshotSHA256: String? = nil,
        siblingSnapshotDirectories: [URL] = [],
        pinRecountTokenizer: @escaping @Sendable (MLXSnapshotIdentity) async -> PinnedSnapshotTokenizer? = { snapshot in
            await PinnedSnapshotTokenizer.load(snapshot: snapshot)
        },
        deadline: Date? = nil
    ) throws {
        let trimmedRef = servedModelRef.trimmingCharacters(in: .whitespacesAndNewlines)
        self.servedModelRef = trimmedRef
        self.runtimeSource = runtimeSource
        switch runtimeSource {
        case LlamaCppLoopbackServeModel.runtimeSource:
            self.upstreamModelName = LlamaCppLoopbackServeModel.upstreamModelName(fromServedRef: trimmedRef)
        case MLXLMLoopbackServeModel.runtimeSource:
            self.upstreamModelName = MLXLMLoopbackServeModel.upstreamModelName
        case LMStudioLoopbackServeModel.runtimeSource:
            self.upstreamModelName = LMStudioLoopbackServeModel.modelKey(fromServedRef: trimmedRef)
        case OMLXLoopbackServeModel.runtimeSource:
            // The model id oMLX lists for the bound snapshot directory.
            guard let upstreamModelID, !upstreamModelID.isEmpty else {
                throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed("omlx_loopback requires the model id oMLX serves the snapshot under")
            }
            self.upstreamModelName = upstreamModelID
        default:
            self.upstreamModelName = OllamaLoopbackServeModel.upstreamModelName(fromServedRef: trimmedRef)
        }
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
        // An LM Studio runtime is always bound to its `/api/v1/models` entry;
        // no other runtime has one.
        guard (lmStudioBinding != nil) == (runtimeSource == LMStudioLoopbackServeModel.runtimeSource) else {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed("lmstudio_loopback requires its LM Studio model binding")
        }
        self.lmStudioBinding = lmStudioBinding
        if let mlxSnapshot {
            // SPEC-010-R009: an MLX snapshot is never a GGUF file, and only
            // mlxlm_loopback and omlx_loopback serve one.
            guard Self.servesMLXSnapshots(runtimeSource) else {
                throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed("an MLX snapshot is served only by mlxlm_loopback or omlx_loopback")
            }
            self.identity = .mlxSnapshot(mlxSnapshot)
            self.startupRecountRequired = true
            self.recountTokenizer = Task.detached(priority: .utility) { await pinRecountTokenizer(mlxSnapshot) }
        } else {
            let expected = siblingSnapshotSHA256.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            self.startupRecountRequired = expected?.isEmpty == false
            if let expected, !expected.isEmpty, !siblingSnapshotDirectories.isEmpty {
                self.recountTokenizer = Task.detached(priority: .utility) {
                    // The first candidate whose canonical snapshot-manifest
                    // digest (regular files only, as the catalog hash) equals
                    // the signed row's is pinned.
                    for directory in siblingSnapshotDirectories {
                        guard let sibling = try? MLXSnapshotIdentity.compute(directory: directory), sibling.digest == expected else { continue }
                        return await pinRecountTokenizer(sibling)
                    }
                    return nil
                }
            } else {
                self.recountTokenizer = nil
            }
            guard !Self.servesMLXSnapshots(runtimeSource) else {
                throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed("\(runtimeSource) requires an MLX snapshot identity")
            }
            let resolver = digestResolver ?? BYOMArtifactDigestResolver(
                store: BYOMOllamaModelStore(root: BYOMOllamaModelStore.defaultRoot()),
                cache: BYOMArtifactDigestCache(url: BYOMArtifactDigestCache.defaultURL())
            )
            do {
                let evidence = try resolver.computeEvidence(
                    runtimeSource: runtimeSource,
                    servedModelRef: trimmedRef,
                    runtimeArtifactPath: runtimeArtifactPath,
                    deadline: deadline
                )
                self.identity = .ggufFile(evidence, resolver)
            } catch {
                throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed(String(describing: error))
            }
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
        siblingSnapshotSHA256: String? = nil,
        siblingSnapshotDirectories: [URL] = [],
        httpClient: (any BYOMDiscoveryHTTPClient)? = nil,
        cache: BYOMArtifactDigestCache = BYOMArtifactDigestCache(url: BYOMArtifactDigestCache.defaultURL()),
        pinRecountTokenizer: @escaping @Sendable (MLXSnapshotIdentity) async -> PinnedSnapshotTokenizer? = { snapshot in
            await PinnedSnapshotTokenizer.load(snapshot: snapshot)
        },
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
            siblingSnapshotSHA256: siblingSnapshotSHA256,
            siblingSnapshotDirectories: siblingSnapshotDirectories,
            pinRecountTokenizer: pinRecountTokenizer,
            deadline: deadline
        )
    }

    /// `mlxlm:<name>` (SPEC-010-R009, #1690 M8): require mlx_lm.server to list
    /// the operator-declared snapshot directory, hash that directory with
    /// the native snapshot-manifest algorithm, and bind the runtime to it.
    /// No declared directory, or a runtime that does not list it, fails
    /// closed (no identity).
    static func mlxLM(
        servedModelRef: String,
        origin: String,
        snapshotDirectory: URL?,
        catalogModelIDAlias: String? = nil,
        httpClient: (any BYOMDiscoveryHTTPClient)? = nil,
        deadline: Date = MLXLMLoopbackServeModel.snapshotHashingDeadline()
    ) async throws -> OpenAICompatibleLoopbackRuntime {
        guard let validatedOrigin = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else {
            throw OpenAICompatibleLoopbackRuntimeError.invalidLoopbackOrigin(origin)
        }
        guard let snapshotDirectory else {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed("\(MLXLMLoopbackServeModel.snapshotPathEnvironmentKey) is not set to an absolute snapshot directory")
        }
        let client = httpClient ?? LoopbackServeHTTPClient()
        let listed: Bool
        do {
            listed = try await MLXLMLoopbackServeModel.listsSnapshot(client, origin: validatedOrigin, directory: snapshotDirectory)
        } catch {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(MLXLMLoopbackServeModel.runtimeSource)
        }
        guard listed else {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(MLXLMLoopbackServeModel.runtimeSource)
        }
        let snapshot: MLXSnapshotIdentity
        do {
            snapshot = try MLXSnapshotIdentity.compute(directory: snapshotDirectory, deadline: deadline)
        } catch AutotuneContextCalibrationError.deadlineExceeded {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed(
                "MLX snapshot hashing exceeded the \(Int(BYOMModelAdmissionRuntime.artifactHashBudgetSeconds)) s artifact hashing budget; refusing to serve without an identity (SPEC-010-R009(a))"
            )
        } catch {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed(String(describing: error))
        }
        return try OpenAICompatibleLoopbackRuntime(
            servedModelRef: servedModelRef,
            origin: origin,
            runtimeSource: MLXLMLoopbackServeModel.runtimeSource,
            runtimeArtifactPath: snapshot.directory.path,
            catalogModelIDAlias: catalogModelIDAlias,
            httpClient: client,
            mlxSnapshot: snapshot,
            deadline: deadline
        )
    }

    /// The runtimes whose identity is an MLX snapshot (SPEC-010-R009).
    static func servesMLXSnapshots(_ runtimeSource: String) -> Bool {
        runtimeSource == MLXLMLoopbackServeModel.runtimeSource || runtimeSource == OMLXLoopbackServeModel.runtimeSource
    }

    /// `omlx:<name>` (SPEC-010-R009, #1690 M9): require oMLX to list the
    /// operator-declared snapshot directory as the `model_path` of exactly one
    /// local `llm` entry, hash that directory with the native snapshot-manifest
    /// algorithm, and serve that entry's model id. No declared directory, or a
    /// runtime that does not list it, fails closed (no identity).
    static func oMLX(
        servedModelRef: String,
        origin: String,
        snapshotDirectory: URL?,
        catalogModelIDAlias: String? = nil,
        httpClient: (any BYOMDiscoveryHTTPClient)? = nil,
        deadline: Date = MLXLMLoopbackServeModel.snapshotHashingDeadline()
    ) async throws -> OpenAICompatibleLoopbackRuntime {
        guard let validatedOrigin = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else {
            throw OpenAICompatibleLoopbackRuntimeError.invalidLoopbackOrigin(origin)
        }
        guard let snapshotDirectory else {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed("\(OMLXLoopbackServeModel.snapshotPathEnvironmentKey) is not set to an absolute snapshot directory")
        }
        let client = httpClient ?? LoopbackServeHTTPClient()
        let modelID: String?
        do {
            modelID = try await OMLXLoopbackServeModel.servedModelID(client, origin: validatedOrigin, directory: snapshotDirectory)
        } catch {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(OMLXLoopbackServeModel.runtimeSource)
        }
        guard let modelID else {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(OMLXLoopbackServeModel.runtimeSource)
        }
        let snapshot: MLXSnapshotIdentity
        do {
            snapshot = try MLXSnapshotIdentity.compute(directory: snapshotDirectory, deadline: deadline)
        } catch AutotuneContextCalibrationError.deadlineExceeded {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed(
                "MLX snapshot hashing exceeded the \(Int(BYOMModelAdmissionRuntime.artifactHashBudgetSeconds)) s artifact hashing budget; refusing to serve without an identity (SPEC-010-R009(a))"
            )
        } catch {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed(String(describing: error))
        }
        return try OpenAICompatibleLoopbackRuntime(
            servedModelRef: servedModelRef,
            origin: origin,
            runtimeSource: OMLXLoopbackServeModel.runtimeSource,
            runtimeArtifactPath: snapshot.directory.path,
            catalogModelIDAlias: catalogModelIDAlias,
            httpClient: client,
            mlxSnapshot: snapshot,
            upstreamModelID: modelID,
            deadline: deadline
        )
    }

    /// `lmstudio:<key>` (SPEC-010-R007(i) / SPEC-046-R009, #1690 M9): hash
    /// the one GGUF file the LM Studio models root resolves for the key, and
    /// require LM Studio to list a loaded `gguf` model for that key with the
    /// file's publisher and exact size. No file, an ambiguous key, or an entry
    /// that does not match fails closed (no identity).
    static func lmStudio(
        servedModelRef: String,
        origin: String,
        modelsRoot: URL = BYOMLMStudioModelStore.defaultRoot(),
        catalogModelIDAlias: String? = nil,
        siblingSnapshotSHA256: String? = nil,
        siblingSnapshotDirectories: [URL] = [],
        httpClient: (any BYOMDiscoveryHTTPClient)? = nil,
        cache: BYOMArtifactDigestCache = BYOMArtifactDigestCache(url: BYOMArtifactDigestCache.defaultURL()),
        pinRecountTokenizer: @escaping @Sendable (MLXSnapshotIdentity) async -> PinnedSnapshotTokenizer? = { snapshot in
            await PinnedSnapshotTokenizer.load(snapshot: snapshot)
        },
        deadline: Date? = nil
    ) async throws -> OpenAICompatibleLoopbackRuntime {
        guard let validatedOrigin = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else {
            throw OpenAICompatibleLoopbackRuntimeError.invalidLoopbackOrigin(origin)
        }
        let client = httpClient ?? LoopbackServeHTTPClient()
        let resolver = BYOMArtifactDigestResolver(locators: [BYOMLMStudioModelStore(root: modelsRoot)], cache: cache)
        let evidence: BYOMArtifactEvidence
        do {
            evidence = try resolver.computeEvidence(
                runtimeSource: LMStudioLoopbackServeModel.runtimeSource,
                servedModelRef: servedModelRef,
                runtimeArtifactPath: nil,
                deadline: deadline
            )
        } catch {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed(String(describing: error))
        }
        guard let binding = LMStudioLoopbackServeModel.binding(
            modelKey: LMStudioLoopbackServeModel.modelKey(fromServedRef: servedModelRef),
            locator: evidence.locatorDigest,
            sizeBytes: evidence.file.sizeBytes
        ) else {
            throw OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed("the LM Studio model file has no publisher/repo/file locator")
        }
        let state: LMStudioLoopbackServeModel.BindingState
        do {
            state = try await LMStudioLoopbackServeModel.bindingState(client, origin: validatedOrigin, binding: binding)
        } catch {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(LMStudioLoopbackServeModel.runtimeSource)
        }
        guard case .bound = state else {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(LMStudioLoopbackServeModel.runtimeSource)
        }
        return try OpenAICompatibleLoopbackRuntime(
            servedModelRef: servedModelRef,
            origin: origin,
            runtimeSource: LMStudioLoopbackServeModel.runtimeSource,
            catalogModelIDAlias: catalogModelIDAlias,
            httpClient: client,
            digestResolver: resolver,
            lmStudioBinding: binding,
            siblingSnapshotSHA256: siblingSnapshotSHA256,
            siblingSnapshotDirectories: siblingSnapshotDirectories,
            pinRecountTokenizer: pinRecountTokenizer,
            deadline: deadline
        )
    }

    // MARK: ModelRuntimeServing identity surface

    var loadedModelHash: String? { identityIsValid() ? identity.digest : nil }
    var loadedModelHashAlgorithm: String? { identity.algorithm }
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

    // MARK: Startup throughput probe (SPEC-001 FR-20, #1690)

    /// Hard wall-clock bound on the whole startup probe: the identity checks
    /// before and after the generation, the connection and the generation
    /// itself. It covers an upstream that lazily loads the model on first
    /// request (Ollama); past it the probe fails and serve continues with 0.
    static let startupThroughputProbeTimeoutSeconds: TimeInterval = 60

    /// The serve-time startup probe behind `capacity.throughput_tps_estimate`
    /// for a loopback runtime: one fixed short generation (the native probe's
    /// prompt and token budget) through the runtime's own chat-completions
    /// leg. The rate is the native probe's quantity: completion tokens over
    /// the whole request, start to stream end, so prefill and any upstream
    /// model load count. The counted tokens are the minimum of the upstream's
    /// own count (`usage.completion_tokens`, else `timings.predicted_n` from
    /// llama-server only) and the trusted pinned-tokenizer recount of the
    /// returned assistant content when a trusted binding is expected. GGUF
    /// without a signed sibling uses bounded upstream count for this advisory
    /// startup estimate only; receipt/cancel counting is unchanged.
    /// Both expected counts must be positive and
    /// independently within `maxTokens`; tool calls and missing or changed
    /// tokenizer identity fail closed. The bound identity (llama-server's
    /// `/props` served file included) is checked immediately before and after
    /// the generation inside the same deadline. It never touches
    /// `ProviderStatus` (no usage, request log or billing), never logs prompt
    /// or completion text, and any failure is an outcome, never a thrown error,
    /// so serving is unaffected.
    func measureStartupThroughput(
        maxTokens: Int = ModelRuntime.startupThroughputProbeMaxTokens,
        timeoutSeconds: TimeInterval = OpenAICompatibleLoopbackRuntime.startupThroughputProbeTimeoutSeconds
    ) async -> LoopbackStartupThroughputOutcome {
        let payload: [String: Any] = [
            "model": upstreamModelName,
            "messages": [["role": "user", "content": ModelRuntime.startupThroughputProbePrompt]],
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": 0.0,
            "max_tokens": maxTokens,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else {
            return .failed(reason: "encode_failed")
        }
        let client = httpClient
        let url = chatCompletionsURL
        let acceptsPredictedN = isLlamaCpp
        let timeouts = LoopbackGenerationTimeouts(firstByte: timeoutSeconds, idle: timeoutSeconds, overall: timeoutSeconds)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let outcome = await Self.bounded(until: deadline, cancelWithCaller: true) { [self] () async -> LoopbackStartupThroughputOutcome? in
            guard await self.probeServesBoundIdentity() else { return .failed(reason: "identity_unbound") }
            let tokenizer = await self.recountTokenizer?.value
            guard !self.startupRecountRequired || tokenizer != nil else {
                return .failed(reason: "tokenizer_unavailable")
            }
            let measured = await Self.runStartupThroughputProbe(
                client,
                url: url,
                body: body,
                maxTokens: maxTokens,
                acceptsPredictedN: acceptsPredictedN,
                recountTokenizer: tokenizer,
                allowUpstreamOnly: !self.startupRecountRequired,
                timeouts: timeouts
            )
            guard case .ok = measured else { return measured }
            guard await self.probeServesBoundIdentity() else { return .failed(reason: "identity_unbound") }
            return measured
        }
        if let outcome { return outcome }
        return .failed(reason: Task.isCancelled ? "cancelled" : "timeout")
    }

    /// The request-path identity checks plus, for llama.cpp, the `/props`
    /// served-file check `upstreamContextGate` runs before every request.
    private func probeServesBoundIdentity() async -> Bool {
        guard await servesBoundIdentity() else { return false }
        guard isLlamaCpp else { return true }
        guard (try? await requireLlamaCppServesBoundFile()) != nil else { return false }
        return identityIsValid()
    }

    private static func runStartupThroughputProbe(
        _ client: any BYOMDiscoveryHTTPClient,
        url: URL,
        body: Data,
        maxTokens: Int,
        acceptsPredictedN: Bool,
        recountTokenizer: PinnedSnapshotTokenizer?,
        allowUpstreamOnly: Bool,
        timeouts: LoopbackGenerationTimeouts
    ) async -> LoopbackStartupThroughputOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let response: BYOMLoopbackLineResponse
        do {
            response = try await openLines(client, url: url, body: body, timeouts: timeouts)
        } catch let error as URLError where error.code == .timedOut {
            return .failed(reason: "timeout")
        } catch {
            return .failed(reason: "upstream_unavailable")
        }
        guard (200...299).contains(response.statusCode) else {
            await closeLines(response.lines)
            return .failed(reason: "upstream_status_\(response.statusCode)")
        }
        var accumulator = OpenAICompatibleStreamAccumulator()
        var predictedN: Int?
        do {
            for try await line in response.lines {
                if acceptsPredictedN, line.hasPrefix("data:"), line.contains("predicted_n"),
                   case .object(let root)? = try? StrictJSONParser.parse(String(line.dropFirst(5))),
                   case .object(let timings)? = root["timings"],
                   let value = intValue(timings["predicted_n"]) {
                    predictedN = value
                }
                _ = try accumulator.consume(line: line)
                if accumulator.isDone { break }
            }
            let (result, _) = try accumulator.finish()
            let endedAt = ProcessInfo.processInfo.systemUptime
            if result.toolCalls?.isEmpty == false {
                return .failed(reason: "tool_calls")
            }
            let contentPresent = !result.content.isEmpty
            let recounted = contentPresent ? recountTokenizer?.count(result.content) : nil
            if contentPresent && recounted == nil && !allowUpstreamOnly {
                return .failed(reason: "tokenizer_identity_changed")
            }
            let upstream = accumulator.decodedFromPlainBody
                ? result.completionTokens
                : accumulator.upstreamCompletionTokens ?? predictedN
            return startupThroughputOutcome(
                contentPresent: contentPresent,
                upstreamCompletionTokens: upstream,
                recountedCompletionTokens: recounted,
                allowUpstreamOnly: allowUpstreamOnly,
                maxTokens: maxTokens,
                elapsedSeconds: endedAt - startedAt
            )
        } catch is CancellationError {
            return .failed(reason: "timeout")
        } catch let error as URLError where error.code == .timedOut {
            return .failed(reason: "timeout")
        } catch {
            return .failed(reason: "malformed_response")
        }
    }

    /// The startup rate through `ModelRuntime.startupThroughputRate`, the
    /// native probe's formula. The claim is bounded: content must have
    /// streamed, the upstream count and any required trusted recount must be positive
    /// and at most `maxTokens`, and the elapsed time must be finite and
    /// positive; anything else fails closed.
    static func startupThroughputOutcome(
        contentPresent: Bool,
        upstreamCompletionTokens: Int?,
        recountedCompletionTokens: Int?,
        allowUpstreamOnly: Bool = false,
        maxTokens: Int,
        elapsedSeconds: TimeInterval
    ) -> LoopbackStartupThroughputOutcome {
        guard contentPresent else { return .failed(reason: "no_content") }
        guard let upstreamCompletionTokens, upstreamCompletionTokens > 0 else { return .failed(reason: "no_tokens") }
        guard upstreamCompletionTokens <= maxTokens else { return .failed(reason: "usage_exceeds_max_tokens") }
        let countedTokens: Int
        if let recountedCompletionTokens {
            guard recountedCompletionTokens > 0 else { return .failed(reason: "tokenizer_identity_changed") }
            guard recountedCompletionTokens <= maxTokens else { return .failed(reason: "recount_exceeds_max_tokens") }
            countedTokens = min(upstreamCompletionTokens, recountedCompletionTokens)
        } else {
            guard allowUpstreamOnly else { return .failed(reason: "tokenizer_identity_changed") }
            countedTokens = upstreamCompletionTokens
        }
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return .failed(reason: "no_elapsed_time") }
        return .ok(tps: ModelRuntime.startupThroughputRate(
            completionTokens: countedTokens,
            elapsedSeconds: elapsedSeconds
        ))
    }

    /// Ends a line stream that will not be read: iterating it from a
    /// cancelled task terminates it, which runs its `onTermination` (the
    /// streaming client cancels the upstream request there).
    private static func closeLines(_ lines: AsyncThrowingStream<String, Error>) async {
        let drain = Task {
            var iterator = lines.makeAsyncIterator()
            _ = try? await iterator.next()
        }
        drain.cancel()
        await drain.value
    }

    // MARK: Internals

    /// Re-resolve the served ref through the locator and confirm the file's
    /// (path, size, inode, mtime) still matches what was hashed. A re-pointed
    /// reference or an in-place rewrite fails closed rather than report a
    /// stale digest (SPEC-010-R007(a)).
    private func identityIsValid() -> Bool {
        switch identity {
        case .ggufFile(let evidence, let resolver):
            return (try? resolver.validateCurrent(
                evidence,
                runtimeSource: runtimeSource,
                servedModelRef: servedModelRef,
                runtimeArtifactPath: runtimeArtifactPath
            )) != nil
        case .mlxSnapshot(let snapshot):
            return snapshot.isCurrent()
        }
    }

    private func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: servedModelRef,
            modelHash: identityIsValid() ? identity.digest : nil,
            modelHashAlgorithm: identity.algorithm
        )
    }

    private var isLlamaCpp: Bool { runtimeSource == LlamaCppLoopbackServeModel.runtimeSource }

    /// mlxlm_loopback / omlx_loopback: before every request the runtime must
    /// still list the bound snapshot directory, and oMLX under the same model
    /// id (SPEC-010-R009(b)). Neither reports a context window here, so an
    /// over-context request fails upstream.
    private func requireMLXLMServesBoundSnapshot() async throws {
        guard case .mlxSnapshot(let snapshot) = identity else { return }
        let listed: Bool
        do {
            if runtimeSource == OMLXLoopbackServeModel.runtimeSource {
                listed = try await OMLXLoopbackServeModel.servedModelID(httpClient, origin: origin, directory: snapshot.directory) == upstreamModelName
            } else {
                listed = try await MLXLMLoopbackServeModel.listsSnapshot(httpClient, origin: origin, directory: snapshot.directory)
            }
        } catch {
            throw APIError(status: 502, message: "Upstream loopback error", type: "server_error", code: "upstream_unavailable")
        }
        guard listed else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
    }

    /// lmstudio_loopback: before every request LM Studio must still list the
    /// bound model loaded, with the bound file's publisher and size
    /// (SPEC-046-R009, #1690 M9). Returns its loaded context window; nil for
    /// every other runtime or when no instance reports one.
    private func requireLMStudioServesBoundFile() async throws -> Int? {
        guard let lmStudioBinding else { return nil }
        let state: LMStudioLoopbackServeModel.BindingState
        do {
            state = try await LMStudioLoopbackServeModel.bindingState(httpClient, origin: origin, binding: lmStudioBinding)
        } catch {
            throw APIError(status: 502, message: "Upstream loopback error", type: "server_error", code: "upstream_unavailable")
        }
        guard case .bound(let contextWindow) = state else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        return contextWindow
    }

    /// llama.cpp: re-read `/props`, require the bound file is still the one
    /// served, then gate prompt + max_tokens against `n_ctx`. LM Studio:
    /// require the bound entry, then gate max_tokens against its loaded
    /// context. Returns the context window used (nil when the runtime
    /// reports none).
    private func upstreamContextGate(_ request: ChatCompletionRequest) async throws -> Int? {
        try await requireMLXLMServesBoundSnapshot()
        if lmStudioBinding != nil {
            guard let contextWindow = try await requireLMStudioServesBoundFile() else { return nil }
            try Self.contextGate(promptTokens: nil, maxTokens: request.maxTokens, contextWindow: contextWindow)
            return contextWindow
        }
        guard isLlamaCpp else { return nil }
        let propsBody = try await requireLlamaCppServesBoundFile()
        guard let contextWindow = BYOMDiscoveryJSON.llamaCppContextWindow(from: propsBody) else {
            return nil
        }
        // max_tokens alone is checked before spending two loopback calls.
        try Self.contextGate(promptTokens: nil, maxTokens: request.maxTokens, contextWindow: contextWindow)
        let promptTokens = await countPromptTokens(request)
        try Self.contextGate(promptTokens: promptTokens, maxTokens: request.maxTokens, contextWindow: contextWindow)
        return contextWindow
    }

    /// llama.cpp: re-read `/props` and require llama-server still serves the
    /// bound file. Returns the `/props` body.
    private func requireLlamaCppServesBoundFile() async throws -> Data {
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
        return props.body
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
        // The last check before any byte goes upstream, for streaming and
        // non-streaming alike: the bound artifact identity is unchanged and,
        // for mlxlm_loopback, the runtime still lists the bound snapshot, and
        // for lmstudio_loopback the bound model entry (SPEC-010-R007(a) /
        // R009(a)(b), SPEC-046-R009).
        guard identityIsValid() else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        try await requireMLXLMServesBoundSnapshot()
        _ = try await requireLMStudioServesBoundFile()
        let body = try Self.encodeUpstreamRequest(
            request,
            upstreamModelName: upstreamModelName,
            timingsPerToken: runtimeSource == LlamaCppLoopbackServeModel.runtimeSource,
            logprobsPerToken: Self.streamsPerTokenLogprobs(runtimeSource, hasTools: ModelRuntime.hasEnabledTools(request.promptSource.tools))
        )
        let clock = LoopbackProgressClock()
        let timeouts = LoopbackGenerationTimeouts.forGeneration(maxTokens: request.maxTokens, contextWindow: contextWindow)
            .withByteProgress(clock)
        let client = httpClient
        let url = chatCompletionsURL
        let stream = LoopbackStreamState()

        do {
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
                    do {
                        for try await line in response.lines {
                            clock.touch()
                            // Like the native runtime, check per token: a
                            // chunk emitted after the cancel would be dropped
                            // by the relay and make the delivery unknown.
                            if shouldCancel() { throw LoopbackCancelRequested() }
                            for chunk in try stream.consume(line: line) {
                                onChunk?(chunk)
                            }
                            if stream.isDone { break }
                        }
                        let (result, late) = try stream.finish()
                        for chunk in late {
                            onChunk?(chunk)
                        }
                        return result
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as LoopbackCancelRequested {
                        throw error
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
                        if shouldCancel() { throw LoopbackCancelRequested() }
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
        } catch is LoopbackCancelRequested {
            // #1690 E2E-F3: like the native runtime, a cancelled stream
            // returns what it generated so the relay can end it with a
            // buyer_cancel receipt over the delivered prefix. The group has
            // finished, so the stream state is final.
            guard onChunk != nil else { throw CancellationError() }
            return await cancelledStreamResult(request, stream: stream)
        }
    }

    /// #1690 M9: the usage of a cancelled stream. llama-server's per-chunk
    /// timings carry the whole count. Every other runtime's stream carries no
    /// prompt count, so the upstream counts the same request's prompt once
    /// more (`countUpstreamPromptTokens`). The completion tokens are the
    /// upstream's per-chunk `logprobs` count (Ollama, LM Studio) when the
    /// stream carried one for every content chunk; otherwise (mlx_lm.server,
    /// oMLX, LM Studio with tools, an upstream that ignored `logprobs`) the
    /// delivered content is counted with the pinned `recountTokenizer`. Both run concurrently inside `cancelUsageBudgetSeconds`.
    /// Anything that fails or runs late leaves the usage unattested (relayed
    /// empty, never signed), so a slow engine makes the cancel free, never
    /// wrongly billed.
    private func cancelledStreamResult(_ request: ChatCompletionRequest, stream: LoopbackStreamState) async -> CompletionResult {
        let content = stream.receivedContent
        guard !isLlamaCpp, !content.isEmpty else { return stream.cancelledResult() }
        let deadline = Date().addingTimeInterval(Self.cancelUsageBudgetSeconds)
        let needsRecount = !stream.hasPerChunkCompletionCounts
        let pinned = needsRecount ? recountTokenizer : nil
        // A streamed tool call is never attested, whatever the count source
        // (SPEC-015 item 7; cancelledResult enforces it too).
        if stream.streamedToolCall || (needsRecount && pinned == nil) {
            return stream.cancelledResult()
        }
        async let prompt: Int? = Self.bounded(until: deadline) { [self] () async -> Int? in
            await self.boundPromptCount(request)
        }
        async let recount: Int? = Self.bounded(until: deadline) { () async -> Int? in
            // The pinned tokenizer re-checks that its snapshot is still the
            // verified one; a changed snapshot yields no count.
            guard let tokenizer = await pinned?.value else { return nil }
            return tokenizer.count(content)
        }
        let (promptTokens, recounted) = await (prompt, recount)
        guard let promptTokens else { return stream.cancelledResult() }
        if needsRecount {
            guard let recounted else { return stream.cancelledResult() }
            return stream.cancelledResult(upstreamPromptTokens: promptTokens, recountedCompletionTokens: recounted)
        }
        return stream.cancelledResult(upstreamPromptTokens: promptTokens)
    }

    /// The prompt count, only while the runtime is bound to the identity it
    /// served the request under both before the count request and after its
    /// response (review CODE MEDIUM, R2 TOCTOU): the file or snapshot is
    /// unchanged against the pinned stamps, mlx_lm.server / oMLX still list
    /// the snapshot, and LM Studio still lists the bound model. Nil
    /// otherwise, so a swap during the re-query never yields a count. The
    /// caller's deadline bounds both checks with the request.
    private func boundPromptCount(_ request: ChatCompletionRequest) async -> Int? {
        guard await servesBoundIdentity() else { return nil }
        guard let count = await countUpstreamPromptTokens(request) else { return nil }
        guard !Task.isCancelled, await servesBoundIdentity() else { return nil }
        return count
    }

    private func servesBoundIdentity() async -> Bool {
        guard identityIsValid() else { return false }
        do {
            try await requireMLXLMServesBoundSnapshot()
            _ = try await requireLMStudioServesBoundFile()
        } catch {
            return false
        }
        return identityIsValid()
    }

    /// The upstream's `usage.prompt_tokens` for this request, from a
    /// non-streamed one-token completion of the same body. The template and
    /// tokenizer are the runtime's own, so it is the prompt count the
    /// cancelled generation used. `tools` and `tool_choice` stay in the body
    /// because the chat template renders them into the prompt. A 4xx on a
    /// body with `response_format` is retried once without it: it constrains
    /// sampling, not the templated prompt, and some engines refuse a format
    /// with a one-token cap. Nil on any failure; the caller bounds the time
    /// and cancels this task at its deadline, which cancels the URLSession
    /// task; the socket's own timers are also short (`promptCountTimeoutSeconds`)
    /// so an abandoned call never lingers.
    private func countUpstreamPromptTokens(_ request: ChatCompletionRequest) async -> Int? {
        guard let body = try? Self.encodePromptCountRequest(request, upstreamModelName: upstreamModelName) else { return nil }
        let retryBody = request.promptSource.responseFormat.map { $0 != .null } == true
            ? try? Self.encodePromptCountRequest(request, upstreamModelName: upstreamModelName, dropResponseFormat: true)
            : nil
        let client: any BYOMDiscoveryHTTPClient = httpClient is LoopbackServeHTTPClient
            ? LoopbackServeHTTPClient(requestTimeout: Self.promptCountTimeoutSeconds, resourceTimeout: Self.promptCountTimeoutSeconds)
            : httpClient
        let url = chatCompletionsURL
        func count(_ body: Data) async -> (status: Int, tokens: Int?)? {
            guard let response = try? await client.post(
                url,
                jsonBody: body,
                maxHeaderBytes: Self.maxHeaderBytes,
                maxBodyBytes: Self.maxResponseBodyBytes
            ) else { return nil }
            return (response.statusCode, response.statusCode == 200 ? Self.decodeUsagePromptTokens(response.body) : nil)
        }
        guard let first = await count(body) else { return nil }
        if first.status == 200 { return first.tokens }
        guard (400..<500).contains(first.status), let retryBody else { return nil }
        return await count(retryBody)?.tokens
    }

    /// Budget for the post-cancel usage work (the prompt count call and the
    /// tokenizer recount, run concurrently). The coordinator waits
    /// `CancelTerminalWait` (2 s, phase4-coordinator/internal/ws/relay.go)
    /// for the cancelled frame after its cancel request; this budget plus the
    /// cancel detection (at most one 100 ms watchdog tick) and the receipt
    /// signing stays well inside it.
    static let cancelUsageBudgetSeconds: Double = 1.25

    /// URLSession request and resource timeouts for the post-cancel prompt
    /// count call, just above `cancelUsageBudgetSeconds`.
    static let promptCountTimeoutSeconds: TimeInterval = 2

    /// Runs `work` and returns its value, or nil at `deadline` without
    /// waiting for it: the work runs in an unstructured task, so a
    /// non-cancellable step (a tokenizer encode, a stuck socket) can never
    /// hold the caller past the deadline. With `cancelWithCaller`, cancelling
    /// the caller also cancels the work and returns nil at once (the startup
    /// probe). The post-cancel usage path leaves it off: it runs after a
    /// buyer cancel and must still finish its count.
    static func bounded<T: Sendable>(
        until deadline: Date,
        cancelWithCaller: Bool = false,
        _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        let gate = LoopbackResumeOnce()
        let callerCancel = LoopbackCancelAction()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                let worker = Task {
                    let value = await work()
                    if gate.claim() { continuation.resume(returning: value) }
                }
                let timer = Task {
                    let wait = max(0, deadline.timeIntervalSinceNow)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if gate.claim() {
                        worker.cancel()
                        continuation.resume(returning: nil)
                    }
                }
                if cancelWithCaller {
                    callerCancel.install {
                        if gate.claim() {
                            worker.cancel()
                            timer.cancel()
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
        } onCancel: {
            callerCancel.fire()
        }
    }

    /// Runtimes asked for a per-chunk `logprobs` list, whose entries count
    /// the completion tokens each chunk carries (#1690 M9). LM Studio refuses
    /// `logprobs` together with `tools` on a stream (its llama.cpp engine
    /// answers 400 "logprobs is not supported with tools + stream"), so a
    /// request with tools asks for none; a cancel of it stays unattested.
    static func streamsPerTokenLogprobs(_ runtimeSource: String, hasTools: Bool = false) -> Bool {
        switch runtimeSource {
        case OllamaLoopbackServeModel.runtimeSource:
            return true
        case LMStudioLoopbackServeModel.runtimeSource:
            return !hasTools
        default:
            return false
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
    static func encodeUpstreamRequest(
        _ request: ChatCompletionRequest,
        upstreamModelName: String,
        timingsPerToken: Bool = false,
        logprobsPerToken: Bool = false
    ) throws -> Data {
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
            // An empty or function-less `tools` is no tools (the enabled-tools
            // rule of ModelRuntime.hasEnabledTools); it is not forwarded, and
            // neither is a `tool_choice` that would name no tool.
            ("tools", ModelRuntime.hasEnabledTools(source.tools) ? source.tools : nil),
            ("tool_choice", ModelRuntime.hasEnabledTools(source.tools) ? source.toolChoice : nil),
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
        // #1690 E2E-F3: llama-server reports usage on every chunk, so a
        // cancelled stream can bind usage to its delivered prefix.
        if timingsPerToken {
            payload["timings_per_token"] = true
        }
        // #1690 M9: Ollama and LM Studio list each streamed token in the
        // chunk that carries it. The list is never relayed.
        if logprobsPerToken {
            payload["logprobs"] = true
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        guard data.count <= maxRequestBodyBytes else {
            throw APIError(status: 413, message: "Request body exceeds 4 MiB", code: "request_body_too_large")
        }
        return data
    }

    /// #1690 M9: the same request as `encodeUpstreamRequest`, non-streamed
    /// and capped at one completion token, so its usage reports the prompt
    /// tokens (`countUpstreamPromptTokens`).
    static func encodePromptCountRequest(
        _ request: ChatCompletionRequest,
        upstreamModelName: String,
        dropResponseFormat: Bool = false
    ) throws -> Data {
        let streamed = try encodeUpstreamRequest(request, upstreamModelName: upstreamModelName)
        guard var payload = try JSONSerialization.jsonObject(with: streamed) as? [String: Any] else {
            throw OpenAICompatibleLoopbackRuntimeError.malformedUpstreamResponse
        }
        payload["stream"] = false
        payload.removeValue(forKey: "stream_options")
        payload["max_tokens"] = 1
        if dropResponseFormat {
            payload.removeValue(forKey: "response_format")
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
    }

    /// `usage.prompt_tokens` of a non-streamed completion body.
    static func decodeUsagePromptTokens(_ data: Data) -> Int? {
        guard data.count <= maxResponseBodyBytes,
              let text = String(data: data, encoding: .utf8),
              case .object(let root)? = try? StrictJSONParser.parse(text),
              case .object(let usage)? = root["usage"] else { return nil }
        return intValue(usage["prompt_tokens"])
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

/// The artifact identity a loopback runtime reports: the complete-file GGUF
/// digest with the locator that re-validates it, or an MLX snapshot.
enum LoopbackServedIdentity {
    case ggufFile(BYOMArtifactEvidence, BYOMArtifactDigestResolver)
    case mlxSnapshot(MLXSnapshotIdentity)

    var digest: String {
        switch self {
        case .ggufFile(let evidence, _): return evidence.digest
        case .mlxSnapshot(let snapshot): return snapshot.digest
        }
    }

    var algorithm: String {
        switch self {
        case .ggufFile(let evidence, _): return evidence.algorithm
        case .mlxSnapshot(let snapshot): return snapshot.algorithm
        }
    }
}

/// The caller cancelled a loopback generation (buyer disconnect).
private struct LoopbackCancelRequested: Error {}

/// Resolves a race once: the first `claim()` wins.
final class LoopbackResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// A caller-cancellation action for `bounded`: runs once, immediately when
/// the caller was cancelled before it was installed.
final class LoopbackCancelAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var fired = false

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        guard !fired else {
            lock.unlock()
            action()
            return
        }
        self.action = action
        lock.unlock()
    }

    func fire() {
        lock.lock()
        fired = true
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

/// The stream accumulator shared by the reader and the cancel path.
private final class LoopbackStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = OpenAICompatibleStreamAccumulator()

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.isDone
    }

    func consume(line: String) throws -> [StreamChunk] {
        lock.lock()
        defer { lock.unlock() }
        return try accumulator.consume(line: line)
    }

    func finish() throws -> (result: CompletionResult, lateChunks: [StreamChunk]) {
        lock.lock()
        defer { lock.unlock() }
        return try accumulator.finish()
    }

    var receivedContent: String {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.receivedContent
    }

    var hasPerChunkCompletionCounts: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.hasPerChunkCompletionCounts
    }

    var streamedToolCall: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.streamedToolCall
    }

    func cancelledResult(upstreamPromptTokens: Int? = nil, recountedCompletionTokens: Int? = nil) -> CompletionResult {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.cancelledResult(
            upstreamPromptTokens: upstreamPromptTokens,
            recountedCompletionTokens: recountedCompletionTokens
        )
    }
}
