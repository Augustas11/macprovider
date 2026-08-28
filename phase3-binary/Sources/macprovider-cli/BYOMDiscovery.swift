import CryptoKit
import Foundation
import MacProviderCore
import Security

enum BYOMDiscoveryWarning: String, Codable, Sendable {
    case candidateIDUnstable = "candidate_id_unstable"
    case adapterUnavailable = "adapter_unavailable"
    case adapterTimeout = "adapter_timeout"
    case adapterRejectedNonLoopback = "adapter_rejected_non_loopback"
    case adapterMalformedResponse = "adapter_malformed_response"
    case adapterResponseTruncated = "adapter_response_truncated"
    case catalogMatchUnverified = "catalog_match_unverified"
    case capabilityUnevaluated = "capability_unevaluated"
    case evaluationRequired = "evaluation_required"
    case requiresPreparation = "requires_preparation"
    case namespacePermissionInvalid = "namespace_permission_invalid"
}

struct BYOMDiscoveryWire: Codable, Equatable, Sendable {
    struct Adapter: Codable, Equatable, Sendable {
        let runtimeSource: String
        let status: String
        let originClass: String?
        let warningCodes: [String]

        enum CodingKeys: String, CodingKey {
            case runtimeSource = "runtime_source"
            case status
            case originClass = "origin_class"
            case warningCodes = "warning_codes"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(runtimeSource, forKey: .runtimeSource)
            try container.encode(status, forKey: .status)
            if let originClass {
                try container.encode(originClass, forKey: .originClass)
            } else {
                try container.encodeNil(forKey: .originClass)
            }
            try container.encode(warningCodes, forKey: .warningCodes)
        }
    }

    struct Capabilities: Codable, Equatable, Sendable {
        let chatCompletions: Bool?
        let streaming: Bool?
        let toolCallPassthrough: Bool?
        let structuredOutputPassthrough: Bool?
        let jsonMode: Bool?
        let usageReporting: Bool?
        let maxContextTokens: Int?
        let quantization: String?
        let family: String?
        let runtimeVersion: String?

        enum CodingKeys: String, CodingKey {
            case chatCompletions = "chat_completions"
            case streaming
            case toolCallPassthrough = "tool_call_passthrough"
            case structuredOutputPassthrough = "structured_output_passthrough"
            case jsonMode = "json_mode"
            case usageReporting = "usage_reporting"
            case maxContextTokens = "max_context_tokens"
            case quantization
            case family
            case runtimeVersion = "runtime_version"
        }

        static let unknown = Capabilities(
            chatCompletions: nil,
            streaming: nil,
            toolCallPassthrough: nil,
            structuredOutputPassthrough: nil,
            jsonMode: nil,
            usageReporting: nil,
            maxContextTokens: nil,
            quantization: nil,
            family: nil,
            runtimeVersion: nil
        )

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try encodeNullable(chatCompletions, forKey: .chatCompletions, into: &container)
            try encodeNullable(streaming, forKey: .streaming, into: &container)
            try encodeNullable(toolCallPassthrough, forKey: .toolCallPassthrough, into: &container)
            try encodeNullable(structuredOutputPassthrough, forKey: .structuredOutputPassthrough, into: &container)
            try encodeNullable(jsonMode, forKey: .jsonMode, into: &container)
            try encodeNullable(usageReporting, forKey: .usageReporting, into: &container)
            try encodeNullable(maxContextTokens, forKey: .maxContextTokens, into: &container)
            try encodeNullable(quantization, forKey: .quantization, into: &container)
            try encodeNullable(family, forKey: .family, into: &container)
            try encodeNullable(runtimeVersion, forKey: .runtimeVersion, into: &container)
        }

        private func encodeNullable<T: Encodable>(
            _ value: T?,
            forKey key: CodingKeys,
            into container: inout KeyedEncodingContainer<CodingKeys>
        ) throws {
            if let value {
                try container.encode(value, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }
    }

    struct Guidance: Codable, Equatable, Sendable {
        let stateLabelKey: String
        let stateMeaningKey: String
        let nextAction: String
        let transitionReasonCode: String?
        let earningPathClass: String

        enum CodingKeys: String, CodingKey {
            case stateLabelKey = "state_label_key"
            case stateMeaningKey = "state_meaning_key"
            case nextAction = "next_action"
            case transitionReasonCode = "transition_reason_code"
            case earningPathClass = "earning_path_class"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stateLabelKey, forKey: .stateLabelKey)
            try container.encode(stateMeaningKey, forKey: .stateMeaningKey)
            try container.encode(nextAction, forKey: .nextAction)
            if let transitionReasonCode {
                try container.encode(transitionReasonCode, forKey: .transitionReasonCode)
            } else {
                try container.encodeNil(forKey: .transitionReasonCode)
            }
            try container.encode(earningPathClass, forKey: .earningPathClass)
        }
    }

    struct Candidate: Codable, Equatable, Sendable {
        let candidateID: String
        let runtimeSource: String
        let displayName: String
        let servedModelRef: String
        let catalogModelKey: String?
        let identityState: String
        let locality: String
        let estimatedGB: Double?
        let contextWindowTokens: Int?
        let capabilities: Capabilities
        let readinessState: String
        let fitState: String
        let evaluationState: String
        let admissionState: String
        let admissionStateSource: String
        let providerGuidance: Guidance
        let warningCodes: [String]

        enum CodingKeys: String, CodingKey {
            case candidateID = "candidate_id"
            case runtimeSource = "runtime_source"
            case displayName = "display_name"
            case servedModelRef = "served_model_ref"
            case catalogModelKey = "catalog_model_key"
            case identityState = "identity_state"
            case locality
            case estimatedGB = "estimated_gb"
            case contextWindowTokens = "context_window_tokens"
            case capabilities
            case readinessState = "readiness_state"
            case fitState = "fit_state"
            case evaluationState = "evaluation_state"
            case admissionState = "admission_state"
            case admissionStateSource = "admission_state_source"
            case providerGuidance = "provider_guidance"
            case warningCodes = "warning_codes"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(candidateID, forKey: .candidateID)
            try container.encode(runtimeSource, forKey: .runtimeSource)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(servedModelRef, forKey: .servedModelRef)
            if let catalogModelKey {
                try container.encode(catalogModelKey, forKey: .catalogModelKey)
            } else {
                try container.encodeNil(forKey: .catalogModelKey)
            }
            try container.encode(identityState, forKey: .identityState)
            try container.encode(locality, forKey: .locality)
            if let estimatedGB {
                try container.encode(estimatedGB, forKey: .estimatedGB)
            } else {
                try container.encodeNil(forKey: .estimatedGB)
            }
            if let contextWindowTokens {
                try container.encode(contextWindowTokens, forKey: .contextWindowTokens)
            } else {
                try container.encodeNil(forKey: .contextWindowTokens)
            }
            try container.encode(capabilities, forKey: .capabilities)
            try container.encode(readinessState, forKey: .readinessState)
            try container.encode(fitState, forKey: .fitState)
            try container.encode(evaluationState, forKey: .evaluationState)
            try container.encode(admissionState, forKey: .admissionState)
            try container.encode(admissionStateSource, forKey: .admissionStateSource)
            try container.encode(providerGuidance, forKey: .providerGuidance)
            try container.encode(warningCodes, forKey: .warningCodes)
        }
    }

    let schema: String
    let generatedAt: String
    let cliVersion: String
    let projectionSequence: Int
    let adapters: [Adapter]
    let candidates: [Candidate]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case cliVersion = "cli_version"
        case projectionSequence = "projection_sequence"
        case adapters
        case candidates
        case warnings
    }

    init(
        generatedAt: String = ModelSwitchingWireCodec.timestamp(),
        cliVersion: String = CoordinatorClient.binaryVersion,
        projectionSequence: Int = 1,
        adapters: [Adapter],
        candidates: [Candidate],
        warnings: [String]
    ) {
        schema = "provider_byom_discovery.v1"
        self.generatedAt = generatedAt
        self.cliVersion = cliVersion
        self.projectionSequence = projectionSequence
        self.adapters = adapters
        self.candidates = candidates
        self.warnings = warnings
    }
}

struct BYOMDiscoveryEnvironment: Sendable {
    let namespaceURL: URL
    let mlxCacheRoot: URL
    let ollamaOrigin: String?

    static func production(
        namespacePath: String?,
        mlxCacheDir: String?,
        ollamaOrigin: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BYOMDiscoveryEnvironment {
        BYOMDiscoveryEnvironment(
            namespaceURL: namespacePath.map(URL.init(fileURLWithPath:)) ?? defaultNamespaceURL(homeDirectory: homeDirectory),
            mlxCacheRoot: mlxCacheDir.map(URL.init(fileURLWithPath:)) ?? defaultMLXCacheRoot(environment: environment, homeDirectory: homeDirectory),
            ollamaOrigin: ollamaOrigin
        )
    }

    static func defaultNamespaceURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".config/macprovider", isDirectory: true)
            .appendingPathComponent("local_discovery_namespace")
    }

    static func defaultMLXCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let cache = environment["HF_HUB_CACHE"], !cache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: cache)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: hfHome).appendingPathComponent("hub", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }
}

struct BYOMHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [(String, String)]
    let body: Data
}

protocol BYOMDiscoveryHTTPClient: Sendable {
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse
}

final class BYOMURLSessionHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = Self.directLoopbackSession()
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

    static func directLoopbackConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2.0
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        return configuration
    }

    private static func directLoopbackSession() -> URLSession {
        URLSession(configuration: directLoopbackConfiguration(), delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }
}

enum BYOMDiscoveryAdapterError: Error {
    case rejectedNonLoopback
    case malformed
    case truncated
}

struct BYOMDiscoveryRunner {
    private let environment: BYOMDiscoveryEnvironment
    private let fileManager: FileManager
    private let httpClient: any BYOMDiscoveryHTTPClient

    init(
        environment: BYOMDiscoveryEnvironment,
        fileManager: FileManager = .default,
        httpClient: any BYOMDiscoveryHTTPClient = BYOMURLSessionHTTPClient()
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.httpClient = httpClient
    }

    func discover() async -> BYOMDiscoveryWire {
        let namespace = BYOMDiscoveryNamespaceStore(fileManager: fileManager)
            .readOrCreateNamespace(at: environment.namespaceURL)
        let catalog = BYOMCatalogMatcher()
        var adapters: [BYOMDiscoveryWire.Adapter] = []
        var candidates: [BYOMDiscoveryWire.Candidate] = []
        var warnings = Set(namespace.warnings.map(\.rawValue))

        let mlx = BYOMMLXCacheDiscovery(
            cacheRoot: environment.mlxCacheRoot,
            namespace: namespace.bytes,
            namespaceWarnings: namespace.warnings,
            catalogMatcher: catalog,
            fileManager: fileManager
        ).discover()
        adapters.append(mlx.adapter)
        candidates.append(contentsOf: mlx.candidates)
        warnings.formUnion(mlx.adapter.warningCodes)
        for candidate in mlx.candidates {
            warnings.formUnion(candidate.warningCodes)
        }

        if let ollamaOrigin = environment.ollamaOrigin,
           !ollamaOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ollama = await BYOMOllamaDiscovery(
                origin: ollamaOrigin,
                namespace: namespace.bytes,
                namespaceWarnings: namespace.warnings,
                catalogMatcher: catalog,
                httpClient: httpClient
            ).discover()
            adapters.append(ollama.adapter)
            candidates.append(contentsOf: ollama.candidates)
            warnings.formUnion(ollama.adapter.warningCodes)
            for candidate in ollama.candidates {
                warnings.formUnion(candidate.warningCodes)
            }
        }

        candidates.sort {
            if $0.runtimeSource == $1.runtimeSource {
                return $0.servedModelRef < $1.servedModelRef
            }
            return $0.runtimeSource < $1.runtimeSource
        }
        adapters.sort { $0.runtimeSource < $1.runtimeSource }

        return BYOMDiscoveryWire(
            adapters: adapters,
            candidates: candidates,
            warnings: Array(warnings).sorted()
        )
    }
}

struct BYOMDiscoveryNamespaceStore {
    struct Result: Sendable {
        let bytes: Data?
        let warnings: [BYOMDiscoveryWarning]
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func readOrCreateNamespace(at url: URL) -> Result {
        do {
            let parent = url.deletingLastPathComponent()
            if fileManager.fileExists(atPath: url.path) {
                guard namespaceDirectoryPermissionsArePrivate(parent), namespaceFilePermissionsArePrivate(url) else {
                    return Result(bytes: nil, warnings: [.namespacePermissionInvalid, .candidateIDUnstable])
                }
                let data = try Data(contentsOf: url)
                guard data.count == 32 else {
                    return Result(bytes: nil, warnings: [.namespacePermissionInvalid, .candidateIDUnstable])
                }
                return Result(bytes: data, warnings: [])
            }

            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            let data = try secureRandomBytes(count: 32)
            guard fileManager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return Result(bytes: nil, warnings: [.candidateIDUnstable])
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return Result(bytes: data, warnings: [])
        } catch {
            return Result(bytes: nil, warnings: [.candidateIDUnstable])
        }
    }

    private func namespaceDirectoryPermissionsArePrivate(_ url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeDirectory,
              let permissions = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 == 0
    }

    private func namespaceFilePermissionsArePrivate(_ url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeRegular,
              let permissions = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 == 0
    }

    private func secureRandomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BYOMDiscoveryAdapterError.malformed
        }
        return Data(bytes)
    }
}

struct BYOMCandidateIdentity: Sendable {
    static func candidateID(namespace: Data?, runtimeSource: String, servedModelRef: String) -> (String, [BYOMDiscoveryWarning]) {
        let normalized = normalizedServedModelRef(servedModelRef)
        let framed = Data(runtimeSource.utf8) + Data([0]) + Data(normalized.utf8)
        guard let namespace, namespace.count == 32 else {
            let digest = SHA256.hash(data: framed)
            return ("byom_unstable_\(base32URLNoPadding(Data(digest)))", [.candidateIDUnstable])
        }
        let mac = HMAC<SHA256>.authenticationCode(for: framed, using: SymmetricKey(data: namespace))
        return ("byom_\(base32URLNoPadding(Data(mac)))", [])
    }

    static func normalizedServedModelRef(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: nil)
    }

    static func base32URLNoPadding(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var output = ""
        var buffer = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1f
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }
        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1f
            output.append(alphabet[index])
        }
        return output
    }
}

struct BYOMCatalogMatcher: Sendable {
    private let rows: [(key: String, modelID: String)]

    init() {
        let baked = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        if let catalog = try? AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(baked) {
            rows = catalog.rows.map { (key: $0.key, modelID: $0.value.modelID) }
        } else {
            rows = []
        }
    }

    func catalogKey(for servedModelRef: String) -> String? {
        let normalized = BYOMCandidateIdentity.normalizedServedModelRef(servedModelRef)
        return rows.first { row in
            BYOMCandidateIdentity.normalizedServedModelRef(row.key) == normalized
                || BYOMCandidateIdentity.normalizedServedModelRef(row.modelID) == normalized
        }?.key
    }
}

struct BYOMMLXCacheDiscovery {
    private let cacheRoot: URL
    private let namespace: Data?
    private let namespaceWarnings: [BYOMDiscoveryWarning]
    private let catalogMatcher: BYOMCatalogMatcher
    private let fileManager: FileManager

    init(
        cacheRoot: URL,
        namespace: Data?,
        namespaceWarnings: [BYOMDiscoveryWarning] = [],
        catalogMatcher: BYOMCatalogMatcher,
        fileManager: FileManager = .default
    ) {
        self.cacheRoot = cacheRoot
        self.namespace = namespace
        self.namespaceWarnings = namespaceWarnings
        self.catalogMatcher = catalogMatcher
        self.fileManager = fileManager
    }

    func discover() -> (adapter: BYOMDiscoveryWire.Adapter, candidates: [BYOMDiscoveryWire.Candidate]) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (
                BYOMDiscoveryWire.Adapter(
                    runtimeSource: "mlx_cache",
                    status: "unavailable",
                    originClass: nil,
                    warningCodes: [BYOMDiscoveryWarning.adapterUnavailable.rawValue]
                ),
                []
            )
        }

        var candidates: [BYOMDiscoveryWire.Candidate] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(200) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let modelID = modelID(fromHFCacheDirectoryName: entry.lastPathComponent) else {
                continue
            }
            let snapshotSummary = summarizeSnapshots(repoDirectory: entry)
            let candidate = buildCandidate(
                servedModelRef: modelID,
                readinessState: snapshotSummary.ready ? "ready" : "needs_weights",
                estimatedGB: estimatedGB(modelID: modelID, snapshotBytes: snapshotSummary.weightBytes),
                contextWindowTokens: snapshotSummary.contextWindowTokens,
                warningCodes: snapshotSummary.ready ? [] : [.requiresPreparation]
            )
            candidates.append(candidate)
        }

        return (
            BYOMDiscoveryWire.Adapter(
                runtimeSource: "mlx_cache",
                status: "ok",
                originClass: nil,
                warningCodes: []
            ),
            candidates
        )
    }

    private func modelID(fromHFCacheDirectoryName name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let modelID = String(name.dropFirst("models--".count))
            .replacingOccurrences(of: "--", with: "/")
        guard !modelID.isEmpty,
              BYOMDiscoveryPrivacy.isSafeModelReference(modelID),
              modelID.lowercased().contains("mlx") else {
            return nil
        }
        return modelID
    }

    private func summarizeSnapshots(repoDirectory: URL) -> (ready: Bool, weightBytes: UInt64, contextWindowTokens: Int?) {
        let snapshots = repoDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotDirs = try? fileManager.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (false, 0, nil)
        }
        var sawConfig = false
        var weightBytes: UInt64 = 0
        var context: Int?
        var inspected = 0
        for snapshot in snapshotDirs.prefix(20) {
            guard (try? snapshot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let config = try? Data(contentsOf: snapshot.appendingPathComponent("config.json")),
               config.count <= 128 * 1024 {
                sawConfig = true
                context = context ?? BYOMDiscoveryJSON.contextWindowTokens(from: config)
            }
            guard let enumerator = fileManager.enumerator(
                at: snapshot,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                inspected += 1
                if inspected > 2048 { break }
                guard BYOMMLXCacheDiscovery.isModelWeightFile(fileURL.lastPathComponent),
                      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else {
                    continue
                }
                weightBytes += UInt64(values.fileSize ?? 0)
            }
        }
        return (sawConfig && weightBytes > 0, weightBytes, context)
    }

    private static func isModelWeightFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".safetensors")
            || lower.hasSuffix(".bin")
            || lower.hasSuffix(".gguf")
            || lower.hasSuffix(".npz")
    }

    private func estimatedGB(modelID: String, snapshotBytes: UInt64) -> Double? {
        if let estimate = ModelFit.estimateWeightSizeGB(modelID: modelID) {
            return Double(estimate)
        }
        guard snapshotBytes > 0 else { return nil }
        let gb = Double(snapshotBytes) / 1_073_741_824.0
        return (gb * 100).rounded() / 100
    }

    private func buildCandidate(
        servedModelRef: String,
        readinessState: String,
        estimatedGB: Double?,
        contextWindowTokens: Int?,
        warningCodes localWarnings: [BYOMDiscoveryWarning]
    ) -> BYOMDiscoveryWire.Candidate {
        let (candidateID, idWarnings) = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "mlx_cache",
            servedModelRef: servedModelRef
        )
        let catalogKey = catalogMatcher.catalogKey(for: servedModelRef)
        var warnings = Set((namespaceWarnings + idWarnings + localWarnings + [.capabilityUnevaluated, .evaluationRequired]).map(\.rawValue))
        if catalogKey != nil {
            warnings.insert(BYOMDiscoveryWarning.catalogMatchUnverified.rawValue)
        }
        let fit = fitState(modelID: servedModelRef)
        let admission = localAdmissionState(
            stableID: idWarnings.isEmpty,
            readinessState: readinessState,
            fitState: fit,
            blockingWarnings: warnings
        )
        return BYOMDiscoveryWire.Candidate(
            candidateID: candidateID,
            runtimeSource: "mlx_cache",
            displayName: BYOMDiscoveryPrivacy.displayName(from: servedModelRef),
            servedModelRef: servedModelRef,
            catalogModelKey: catalogKey,
            identityState: catalogKey == nil ? "runtime_reported" : "catalog_matched",
            locality: "local_artifact",
            estimatedGB: estimatedGB,
            contextWindowTokens: contextWindowTokens,
            capabilities: BYOMDiscoveryWire.Capabilities(
                chatCompletions: nil,
                streaming: nil,
                toolCallPassthrough: nil,
                structuredOutputPassthrough: nil,
                jsonMode: nil,
                usageReporting: nil,
                maxContextTokens: contextWindowTokens,
                quantization: BYOMDiscoveryPrivacy.safeOptionalLabel(BYOMDiscoveryPrivacy.quantizationHint(from: servedModelRef)),
                family: nil,
                runtimeVersion: nil
            ),
            readinessState: readinessState,
            fitState: fit,
            evaluationState: "not_evaluated",
            admissionState: admission,
            admissionStateSource: "local_default",
            providerGuidance: BYOMDiscoveryGuidance.guidance(forAdmissionState: admission, warnings: warnings),
            warningCodes: Array(warnings).sorted()
        )
    }

    private func fitState(modelID: String) -> String {
        switch ModelFit.evaluate(modelID: modelID, ramGB: ModelFit.detectRAMGB()) {
        case .fits, .tight:
            return "fits"
        case .wontFit:
            return "does_not_fit"
        case .unknown:
            return "unknown"
        }
    }
}

struct BYOMOllamaDiscovery: Sendable {
    private let origin: String
    private let namespace: Data?
    private let namespaceWarnings: [BYOMDiscoveryWarning]
    private let catalogMatcher: BYOMCatalogMatcher
    private let httpClient: any BYOMDiscoveryHTTPClient

    init(
        origin: String,
        namespace: Data?,
        namespaceWarnings: [BYOMDiscoveryWarning] = [],
        catalogMatcher: BYOMCatalogMatcher,
        httpClient: any BYOMDiscoveryHTTPClient
    ) {
        self.origin = origin
        self.namespace = namespace
        self.namespaceWarnings = namespaceWarnings
        self.catalogMatcher = catalogMatcher
        self.httpClient = httpClient
    }

    func discover() async -> (adapter: BYOMDiscoveryWire.Adapter, candidates: [BYOMDiscoveryWire.Candidate]) {
        guard let baseURL = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else {
            return (
                BYOMDiscoveryWire.Adapter(
                    runtimeSource: "ollama_loopback",
                    status: "rejected",
                    originClass: "rejected",
                    warningCodes: [BYOMDiscoveryWarning.adapterRejectedNonLoopback.rawValue]
                ),
                []
            )
        }

        do {
            let response = try await httpClient.get(
                baseURL.appendingPathComponent("api/tags"),
                maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
                maxBodyBytes: BYOMDiscoveryHTTPBounds.maxBodyBytes
            )
            guard response.statusCode == 200 else {
                return adapterFailure(.adapterUnavailable, status: "unavailable")
            }
            guard BYOMDiscoveryHTTPBounds.headerBytes(response.headers) <= BYOMDiscoveryHTTPBounds.maxHeaderBytes else {
                return adapterFailure(.adapterResponseTruncated, status: "truncated")
            }
            guard response.body.count <= BYOMDiscoveryHTTPBounds.maxBodyBytes else {
                return adapterFailure(.adapterResponseTruncated, status: "truncated")
            }
            let models = try BYOMDiscoveryJSON.parseOllamaTags(response.body)
            return (
                BYOMDiscoveryWire.Adapter(
                    runtimeSource: "ollama_loopback",
                    status: "ok",
                    originClass: "loopback_http",
                    warningCodes: []
                ),
                models.map(buildCandidate)
            )
        } catch is CancellationError {
            return adapterFailure(.adapterTimeout, status: "timeout")
        } catch let error as URLError where error.code == .timedOut {
            return adapterFailure(.adapterTimeout, status: "timeout")
        } catch let error as BYOMDiscoveryAdapterError {
            switch error {
            case .malformed:
                return adapterFailure(.adapterMalformedResponse, status: "malformed")
            case .truncated:
                return adapterFailure(.adapterResponseTruncated, status: "truncated")
            case .rejectedNonLoopback:
                return adapterFailure(.adapterRejectedNonLoopback, status: "rejected")
            }
        } catch {
            return adapterFailure(.adapterUnavailable, status: "unavailable")
        }
    }

    private func adapterFailure(
        _ warning: BYOMDiscoveryWarning,
        status: String
    ) -> (adapter: BYOMDiscoveryWire.Adapter, candidates: [BYOMDiscoveryWire.Candidate]) {
        (
            BYOMDiscoveryWire.Adapter(
                runtimeSource: "ollama_loopback",
                status: status,
                originClass: "loopback_http",
                warningCodes: [warning.rawValue]
            ),
            []
        )
    }

    private func buildCandidate(_ model: BYOMDiscoveryJSON.OllamaModel) -> BYOMDiscoveryWire.Candidate {
        let servedModelRef = "ollama:\(model.name)"
        let (candidateID, idWarnings) = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "ollama_loopback",
            servedModelRef: servedModelRef
        )
        let catalogKey = catalogMatcher.catalogKey(for: model.name)
        var warnings = Set((namespaceWarnings + idWarnings + [.capabilityUnevaluated, .evaluationRequired]).map(\.rawValue))
        if catalogKey != nil {
            warnings.insert(BYOMDiscoveryWarning.catalogMatchUnverified.rawValue)
        }
        let fit = fitState(modelID: model.name)
        let admission = localAdmissionState(
            stableID: idWarnings.isEmpty,
            readinessState: "ready",
            fitState: fit,
            blockingWarnings: warnings
        )
        return BYOMDiscoveryWire.Candidate(
            candidateID: candidateID,
            runtimeSource: "ollama_loopback",
            displayName: BYOMDiscoveryPrivacy.displayName(from: model.name),
            servedModelRef: servedModelRef,
            catalogModelKey: catalogKey,
            identityState: catalogKey == nil ? "runtime_reported" : "catalog_matched",
            locality: "loopback_runtime",
            estimatedGB: ModelFit.estimateWeightSizeGB(modelID: model.name).map(Double.init),
            contextWindowTokens: nil,
            capabilities: BYOMDiscoveryWire.Capabilities(
                chatCompletions: true,
                streaming: nil,
                toolCallPassthrough: nil,
                structuredOutputPassthrough: nil,
                jsonMode: nil,
                usageReporting: nil,
                maxContextTokens: nil,
                quantization: BYOMDiscoveryPrivacy.safeOptionalLabel(model.quantization),
                family: BYOMDiscoveryPrivacy.safeOptionalLabel(model.family),
                runtimeVersion: nil
            ),
            readinessState: "ready",
            fitState: fit,
            evaluationState: "not_evaluated",
            admissionState: admission,
            admissionStateSource: "local_default",
            providerGuidance: BYOMDiscoveryGuidance.guidance(forAdmissionState: admission, warnings: warnings),
            warningCodes: Array(warnings).sorted()
        )
    }

    private func fitState(modelID: String) -> String {
        switch ModelFit.evaluate(modelID: modelID, ramGB: ModelFit.detectRAMGB()) {
        case .fits, .tight:
            return "fits"
        case .wontFit:
            return "does_not_fit"
        case .unknown:
            return "unknown"
        }
    }
}

enum BYOMLoopbackOriginValidator {
    static func validatedHTTPOrigin(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              isLoopbackLiteral(host),
              components.port.map({ (1...65535).contains($0) }) ?? false else {
            return nil
        }
        guard components.path.isEmpty || components.path == "/" else {
            return nil
        }
        components.path = ""
        return components.url
    }

    static func isLoopbackLiteral(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "::1" { return true }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4
            && UInt8(parts[0]) == 127
            && parts.dropFirst().allSatisfy { UInt8($0) != nil }
    }
}

enum BYOMDiscoveryHTTPBounds {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 256 * 1024

    static func headerBytes(_ headers: [(String, String)]) -> Int {
        headers.reduce(0) { total, header in
            total + header.0.utf8.count + header.1.utf8.count
        }
    }
}

enum BYOMDiscoveryJSON {
    struct OllamaModel: Equatable {
        let name: String
        let family: String?
        let quantization: String?
    }

    static func parseOllamaTags(_ data: Data) throws -> [OllamaModel] {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .array(let rawModels)? = root["models"] else {
            throw BYOMDiscoveryAdapterError.malformed
        }
        return rawModels.prefix(100).compactMap { value in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"],
                  BYOMDiscoveryPrivacy.isSafeRuntimeModelReference(name) else {
                return nil
            }
            let details: [String: JSONValue]
            if case .object(let detailObject)? = object["details"] {
                details = detailObject
            } else {
                details = [:]
            }
            return OllamaModel(
                name: name,
                family: stringField("family", in: details),
                quantization: stringField("quantization_level", in: details)
            )
        }
    }

    static func contextWindowTokens(from data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text) else {
            return nil
        }
        for key in ["max_position_embeddings", "model_max_length", "max_sequence_length", "n_ctx"] {
            if let value = intField(key, in: root), value > 0 {
                return value
            }
        }
        return nil
    }

    private static func stringField(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case .string(let value)? = object[key] else { return nil }
        return value
    }

    private static func intField(_ key: String, in object: [String: JSONValue]) -> Int? {
        switch object[key] {
        case .int(let value)?:
            return value
        case .double(let value)? where value.rounded(.towardZero) == value:
            return Int(value)
        default:
            return nil
        }
    }
}

enum BYOMDiscoveryPrivacy {
    static func isSafeModelReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else { return false }
        let lower = trimmed.lowercased()
        guard !trimmed.contains(".."),
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("@"),
              !trimmed.contains("="),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.contains("&"),
              !lower.contains("://"),
              !lower.hasPrefix("http:"),
              !lower.hasPrefix("https:"),
              !lower.hasPrefix("file:"),
              !lower.hasPrefix("unix:"),
              !lower.hasPrefix("ws:"),
              !lower.hasPrefix("wss:"),
              !lower.contains("token="),
              !lower.contains("api_key="),
              !lower.contains("apikey="),
              !lower.contains("secret="),
              !lower.contains("authorization="),
              !lower.contains("password="),
              !lower.contains("bearer ") else {
            return false
        }
        guard !looksLikeEndpoint(trimmed), !looksLikeCredential(trimmed) else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7e
                && scalar != "<"
                && scalar != ">"
                && scalar != "\""
                && scalar != "'"
                && scalar != ";"
        }
    }

    static func isSafeRuntimeModelReference(_ value: String) -> Bool {
        guard isSafeModelReference(value) else { return false }
        return !value.contains("/")
    }

    static func displayName(from value: String) -> String {
        let safe = value.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 0x20 && scalar.value <= 0x7e,
               scalar != "<",
               scalar != ">",
               scalar != "\"",
               scalar != "'" {
                return Character(scalar)
            }
            return "?"
        }
        let string = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(string.prefix(128))
    }

    static func safeOptionalLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 64,
              !looksSensitive(trimmed),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7e
                      && (scalar.properties.isAlphabetic
                          || scalar.properties.isMath
                          || CharacterSet.decimalDigits.contains(scalar)
                          || scalar == "_"
                          || scalar == "-"
                          || scalar == "."
                          || scalar == "+")
              }) else {
            return nil
        }
        return trimmed
    }

    private static func looksSensitive(_ value: String) -> Bool {
        let lower = value.lowercased()
        return value.contains("/")
            || value.contains("\\")
            || value.contains("=")
            || value.contains("?")
            || value.contains("#")
            || value.contains("&")
            || value.contains("@")
            || lower.contains("://")
            || lower.hasPrefix("http:")
            || lower.hasPrefix("https:")
            || lower.hasPrefix("file:")
            || lower.hasPrefix("unix:")
            || lower.contains("token")
            || lower.contains("api_key")
            || lower.contains("apikey")
            || lower.contains("secret")
            || lower.contains("authorization")
            || lower.contains("password")
            || lower.contains("bearer ")
            || looksLikeEndpoint(value)
            || looksLikeCredential(value)
    }

    private static func looksLikeEndpoint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "localhost" || lower == "[::1]" || lower == "::1" {
            return true
        }
        if trimmed.range(of: #"^[0-9]{1,3}(\.[0-9]{1,3}){3}$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^\[[0-9A-Fa-f:]+\]$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,}$"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.range(
            of: #"(^|[^A-Za-z0-9._-])(localhost|[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:]+\]):[0-9]{1,5}($|[^A-Za-z0-9._-])"#,
            options: .regularExpression
        ) != nil
    }

    private static func looksLikeCredential(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("sk-") || lower.hasPrefix("ghp_") || lower.hasPrefix("github_pat_") {
            return true
        }
        if lower.hasPrefix("xoxb-") || lower.hasPrefix("xoxp-") || lower.hasPrefix("xoxa-") || lower.hasPrefix("xoxr-") {
            return true
        }
        if trimmed.range(of: #"^eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.range(of: #"^[A-Za-z0-9_-]{40,}$"#, options: .regularExpression) != nil
    }

    static func quantizationHint(from value: String) -> String? {
        let lower = value.lowercased()
        if lower.contains("4bit") || lower.contains("-q4") || lower.contains("_q4") {
            return "q4"
        }
        if lower.contains("8bit") || lower.contains("-q8") || lower.contains("_q8") {
            return "q8"
        }
        if lower.contains("bf16") {
            return "bf16"
        }
        if lower.contains("fp16") || lower.contains("-f16") {
            return "fp16"
        }
        return nil
    }
}

enum BYOMDiscoveryGuidance {
    static func guidance(forAdmissionState state: String, warnings: Set<String>) -> BYOMDiscoveryWire.Guidance {
        switch state {
        case "offerable":
            return BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.local.offerable",
                stateMeaningKey: "byom.local.offerable_not_earning",
                nextAction: warnings.contains(BYOMDiscoveryWarning.evaluationRequired.rawValue) ? "evaluate" : "offer_dry_run",
                transitionReasonCode: nil,
                earningPathClass: "local_inventory_only"
            )
        default:
            return BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.local.local_only",
                stateMeaningKey: "byom.local.local_only_not_earning",
                nextAction: "fix_local_blocker",
                transitionReasonCode: warnings.sorted().first,
                earningPathClass: "local_inventory_only"
            )
        }
    }
}

private func localAdmissionState(
    stableID: Bool,
    readinessState: String,
    fitState: String,
    blockingWarnings: Set<String>
) -> String {
    let blockingWarningCodes = Set([
        BYOMDiscoveryWarning.candidateIDUnstable.rawValue,
        BYOMDiscoveryWarning.namespacePermissionInvalid.rawValue,
        BYOMDiscoveryWarning.adapterRejectedNonLoopback.rawValue,
        BYOMDiscoveryWarning.adapterMalformedResponse.rawValue,
        BYOMDiscoveryWarning.adapterResponseTruncated.rawValue,
        BYOMDiscoveryWarning.requiresPreparation.rawValue,
    ])
    guard stableID,
          readinessState == "ready",
          fitState != "does_not_fit",
          blockingWarnings.isDisjoint(with: blockingWarningCodes) else {
        return "local_only"
    }
    return "offerable"
}
