import Foundation
import MacProviderCore

// SPEC-046-R002 / SPEC-010-R007(e) loopback serving adapter (issue #1569).
//
// One `macprovider-cli serve` process can serve an Ollama-hosted GGUF
// (`--model ollama:<tag>`) by proxying inference to the validated loopback
// Ollama origin's OpenAI-compatible chat-completions endpoint. The adapter
// reports the `macprovider.gguf-file.v1` identity of the LOCAL GGUF blob
// (never an Ollama layer/manifest digest), keeps the loopback constraints of
// SPEC-046-R002 (only `POST <loopback-origin>/v1/chat/completions`, short
// timeouts, bounded bodies, no redirects, loopback-literal host only), and is
// NON-EARNING: relay-blind and signed receipts are disabled on this path (no
// local MLX tokenizer), so it never fabricates a `model_hash`-bound receipt.

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

    /// Operator-scoped loopback origin. `MACPROVIDER_OLLAMA_ORIGIN` overrides
    /// the default 127.0.0.1:11434; the value is still loopback-validated at
    /// runtime construction, so a non-loopback override fails closed there.
    static func resolveOrigin(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["MACPROVIDER_OLLAMA_ORIGIN"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return defaultOrigin
    }
}

enum OllamaLoopbackRuntimeError: Error, CustomStringConvertible, Equatable {
    case invalidLoopbackOrigin(String)
    case artifactResolutionFailed(String)
    case identityChanged
    case upstreamStatus(Int)
    case malformedUpstreamResponse
    case emptyUpstreamContent

    var description: String {
        switch self {
        case .invalidLoopbackOrigin(let origin):
            return "ollama origin \(origin) is not a valid loopback HTTP origin (SPEC-046-R002)"
        case .artifactResolutionFailed(let reason):
            return "could not resolve/hash the local GGUF blob for the served model: \(reason)"
        case .identityChanged:
            return "local GGUF file identity changed; refusing to report a stale hash (SPEC-010-R007(a))"
        case .upstreamStatus(let code):
            return "ollama loopback returned HTTP \(code)"
        case .malformedUpstreamResponse:
            return "ollama loopback response was malformed or exceeded bounds"
        case .emptyUpstreamContent:
            return "ollama loopback returned no assistant content"
        }
    }
}

/// SPEC-046-R002 loopback HTTP leg for the serve proxy. Mirrors the discovery
/// client's safety posture (loopback-literal host check, no redirects, bounded
/// header/body) but with serve-appropriate timeouts, because a real (even
/// 4-token) generation can take longer than a discovery probe. The only URL
/// this client is ever handed is `<loopback-origin>/v1/chat/completions`.
final class OllamaLoopbackServeHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    init(requestTimeout: TimeInterval = 60, resourceTimeout: TimeInterval = 120) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        // The serve adapter allowlist is POST-only; GET is never used.
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard BYOMLoopbackOriginValidator.isSafeLoopbackHTTPURL(url) else {
            throw BYOMDiscoveryAdapterError.rejectedNonLoopback
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = jsonBody

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
        let session = URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BYOMDiscoveryAdapterError.malformed
        }
        let headers = http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String else { return nil }
            return (key, String(describing: value))
        }
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
}

/// A `ModelRuntimeServing` actor that proxies inference to the validated
/// loopback Ollama origin. ONE process, ONE model — never a second serve
/// process beside an MLX runtime.
actor OllamaLoopbackRuntime: ModelRuntimeServing {
    static let maxRequestBodyBytes = 1 * 1024 * 1024
    static let maxResponseBodyBytes = 4 * 1024 * 1024
    static let maxHeaderBytes = BYOMDiscoveryHTTPBounds.maxHeaderBytes

    /// The served ref reported to the coordinator, e.g. `ollama:gemma3:270m`.
    let servedModelRef: String
    /// The name the upstream Ollama endpoint expects, e.g. `gemma3:270m`.
    private let upstreamModelName: String
    /// Validated, path-stripped loopback origin (scheme+host+port only).
    private let origin: URL
    private let chatCompletionsURL: URL
    private let catalogModelIDAlias: String?
    private let httpClient: any BYOMDiscoveryHTTPClient
    private let digestResolver: BYOMArtifactDigestResolver

    /// GGUF-file identity bound at construction and re-validated before every
    /// identity-binding report (SPEC-010-R007(a)).
    private let evidence: BYOMArtifactEvidence
    private var providerStatus: ProviderStatus?
    private var registrationCounter: Int = 0

    /// GGUF-file-path resolution method: the served ref (`ollama:<tag>`) is
    /// resolved to the local blob by `BYOMOllamaModelStore`, which reads the
    /// Ollama manifest at `manifests/registry.ollama.ai/<ns>/<repo>/<tag>`,
    /// finds its single `application/vnd.ollama.image.model` layer, and locates
    /// `blobs/sha256-<hex>`. `BYOMArtifactDigestResolver.computeEvidence` then
    /// hashes the COMPLETE blob bytes over an open descriptor, binding the
    /// `macprovider.gguf-file.v1` digest to the file's (path, size, inode,
    /// mtime) and failing closed if that identity changes while hashing. The
    /// manifest layer digest is only a LOCATOR and is never reported.
    init(
        servedModelRef: String,
        origin: String,
        catalogModelIDAlias: String? = nil,
        httpClient: (any BYOMDiscoveryHTTPClient)? = nil,
        digestResolver: BYOMArtifactDigestResolver? = nil,
        deadline: Date? = nil
    ) throws {
        let trimmedRef = servedModelRef.trimmingCharacters(in: .whitespacesAndNewlines)
        self.servedModelRef = trimmedRef
        self.upstreamModelName = OllamaLoopbackServeModel.upstreamModelName(fromServedRef: trimmedRef)
        guard let validatedOrigin = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else {
            throw OllamaLoopbackRuntimeError.invalidLoopbackOrigin(origin)
        }
        self.origin = validatedOrigin
        self.chatCompletionsURL = validatedOrigin.appendingPathComponent("v1/chat/completions")
        self.catalogModelIDAlias = catalogModelIDAlias.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.httpClient = httpClient ?? OllamaLoopbackServeHTTPClient()
        let resolver = digestResolver ?? BYOMArtifactDigestResolver(
            store: BYOMOllamaModelStore(root: BYOMOllamaModelStore.defaultRoot()),
            cache: BYOMArtifactDigestCache(url: BYOMArtifactDigestCache.defaultURL())
        )
        self.digestResolver = resolver
        do {
            self.evidence = try resolver.computeEvidence(
                runtimeSource: OllamaLoopbackServeModel.runtimeSource,
                servedModelRef: trimmedRef,
                deadline: deadline
            )
        } catch {
            throw OllamaLoopbackRuntimeError.artifactResolutionFailed(String(describing: error))
        }
    }

    // MARK: ModelRuntimeServing identity surface

    var loadedModelHash: String? { identityIsValid() ? evidence.digest : nil }
    var loadedModelHashAlgorithm: String? { evidence.algorithm }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }

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

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        // No local tokenizer/model on the loopback path: nothing to pre-tokenize
        // or gate. Model-match is enforced in acquireRequestHandle / the relay.
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> CompletionResult {
        guard identityIsValid() else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        try request.validateModelMatches(servedModelRef, aliases: modelIDAliasList(catalogModelIDAlias))
        return try await proxy(request)
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        // The loopback proxy runs the upstream call non-streaming, then surfaces
        // the whole generated content as one chunk so the coordinator warm-up
        // probe (`warmupChunkHasOutput`) observes visible output. Token-level
        // streaming fidelity is not required on this non-earning path.
        let result = try await proxy(request)
        if !result.content.isEmpty {
            onChunk(.content(result.content))
        }
        return result
    }

    // MARK: Internals

    /// Re-resolve the served ref through the locator and confirm the file's
    /// (path, size, inode, mtime) still matches what was hashed. A blob in the
    /// Ollama store is content-addressed and normally immutable, but a manifest
    /// re-point or in-place rewrite must fail closed rather than report a stale
    /// digest (SPEC-010-R007(a)).
    private func identityIsValid() -> Bool {
        (try? digestResolver.validateCurrent(
            evidence,
            runtimeSource: OllamaLoopbackServeModel.runtimeSource,
            servedModelRef: servedModelRef
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

    private func proxy(_ request: ChatCompletionRequest) async throws -> CompletionResult {
        let body = try encodeUpstreamRequest(request)
        let response: BYOMHTTPResponse
        do {
            response = try await httpClient.post(
                chatCompletionsURL,
                jsonBody: body,
                maxHeaderBytes: Self.maxHeaderBytes,
                maxBodyBytes: Self.maxResponseBodyBytes
            )
        } catch {
            throw APIError(status: 502, message: "Upstream loopback error", type: "server_error", code: "upstream_unavailable")
        }
        guard (200...299).contains(response.statusCode) else {
            throw APIError(status: 502, message: "Upstream loopback status \(response.statusCode)", type: "server_error", code: "upstream_error")
        }
        // A malformed/empty upstream body is an upstream fault, surfaced as 502
        // (consistent with the transport/status failures above) rather than a
        // generic 500 from an uncaught runtime error.
        do {
            return try Self.decodeUpstreamResponse(response.body)
        } catch {
            throw APIError(status: 502, message: "Upstream loopback response malformed", type: "server_error", code: "upstream_error")
        }
    }

    private func encodeUpstreamRequest(_ request: ChatCompletionRequest) throws -> Data {
        var payload: [String: Any] = [
            "model": upstreamModelName,
            "messages": request.messages.map { message -> [String: Any] in
                ["role": message.role.rawValue, "content": message.content ?? ""]
            },
            "stream": false,
            "temperature": request.temperature,
        ]
        if let maxTokens = request.maxTokens {
            payload["max_tokens"] = maxTokens
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard data.count <= Self.maxRequestBodyBytes else {
            throw APIError(status: 413, message: "Request too large", type: "invalid_request_error", code: "request_too_large")
        }
        return data
    }

    static func decodeUpstreamResponse(_ data: Data) throws -> CompletionResult {
        guard data.count <= maxResponseBodyBytes,
              let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .array(let choices)? = root["choices"],
              case .object(let firstChoice)? = choices.first,
              case .object(let message)? = firstChoice["message"],
              case .string(let content)? = message["content"] else {
            throw OllamaLoopbackRuntimeError.malformedUpstreamResponse
        }
        var finishReason = "stop"
        if case .string(let reason)? = firstChoice["finish_reason"] {
            finishReason = reason
        }
        var completionTokens = 0
        var promptTokens = 0
        if case .object(let usage)? = root["usage"] {
            completionTokens = intValue(usage["completion_tokens"]) ?? 0
            promptTokens = intValue(usage["prompt_tokens"]) ?? 0
        }
        return CompletionResult(
            content: content,
            finishReason: finishReason,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            generatedCompletionTokens: completionTokens
        )
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
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
