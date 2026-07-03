import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import Security

enum AutotuneRecommendError: Error, Equatable, CustomStringConvertible {
    case invalidStaticJSON(String)
    case invalidRateCard(String)
    case invalidArtifact(String)
    case noHMACSecret

    var description: String {
        switch self {
        case .invalidStaticJSON(let message):
            return "invalid static JSON: \(message)"
        case .invalidRateCard(let message):
            return "invalid rate card: \(message)"
        case .invalidArtifact(let message):
            return "invalid model artifact: \(message)"
        case .noHMACSecret:
            return "HMAC secret unavailable"
        }
    }
}

enum AutotuneRecommendWarning: String, CaseIterable {
    case candidateCatalogFallbackUsed = "candidate_catalog_fallback_used"
    case candidateCatalogStale = "candidate_catalog_stale"
    case demandRankFallbackUsed = "demand_rank_fallback_used"
    case demandRankStale = "demand_rank_stale"
    case electricityNotIncluded = "electricity_not_included"
    case hardwareTierUnknown = "hardware_tier_unknown"
    case rateCardFallbackUsed = "rate_card_fallback_used"
    case recommendationBelowThreshold = "recommendation_below_threshold"
    case noEligiblePaidModel = "no_eligible_paid_model"
    /// v1.7.6 Track A1: at least one recommended candidate had no
    /// specific rate-card row and is being priced against the coord's
    /// "default" fallback tier. Coord's `RateFor` already falls through
    /// to this row for served inference, so credits still flow — the
    /// warning surfaces the discovery-tier pricing to the operator.
    case rateCardDefaultTierUsed = "rate_card_default_tier_used"
    /// v1.7.6 Track A2a: at least one recommended candidate observed
    /// swap pageouts during the Stage 1 probe. The candidate still
    /// cleared TPS/TTFT gates so eligibility passes, but the operator
    /// should be aware that heavy real-world context loads may push
    /// this Mac into swap.
    case swapObservedUnderLoad = "swap_observed_under_load"
    /// v1.7.9 Track A5 (Option B): the recommended candidate's measured
    /// sustained TPS was below the catalog's `min_sustained_tps` gate
    /// for its row. The gate is now a soft signal — the ACTUAL gate is
    /// `expected_net_usd_per_hour >= $0.005/hr`, since a provider with
    /// slower-than-nominal TPS still earns at the reduced measured rate.
    /// Buyers routing to this provider get slower inference than the
    /// catalog gate implied.
    case tpsBelowGate = "tps_below_gate"
    /// v1.7.9 Track A5 (Option B): the recommended candidate's measured
    /// 4K TTFT was above the catalog's `max_4k_ttft_ms` ceiling. Same
    /// soft-signal reasoning as `tpsBelowGate`.
    case ttftAboveGate = "ttft_above_gate"
}

enum BandwidthTier: String, Codable, CaseIterable, Comparable {
    case c = "C"
    case b = "B"
    case a = "A"
    case s = "S"
    case unknown = "unknown"

    private var order: Int {
        switch self {
        case .unknown, .c: return 0
        case .b: return 1
        case .a: return 2
        case .s: return 3
        }
    }

    static func < (lhs: BandwidthTier, rhs: BandwidthTier) -> Bool {
        lhs.order < rhs.order
    }

    func satisfies(minimum: BandwidthTier) -> Bool {
        self.order >= minimum.order
    }

    static func derive(chip: String) -> BandwidthTier {
        let normalized = chip.lowercased()
        if normalized.contains("ultra") {
            if let generation = appleSiliconGeneration(normalized) {
                return generation >= 3 ? .s : .a
            }
            if normalized.contains("m3") || normalized.contains("m4") {
                return .s
            }
            if normalized.contains("m1") || normalized.contains("m2") {
                return .a
            }
            return .s
        }
        if normalized.contains("max") {
            if let generation = appleSiliconGeneration(normalized) {
                return generation >= 3 ? .a : .b
            }
            return .a
        }
        if normalized.contains("pro") {
            return .b
        }
        return .c
    }

    private static func appleSiliconGeneration(_ normalizedChip: String) -> Int? {
        guard let match = normalizedChip.range(of: #"m[0-9]+"#, options: .regularExpression) else {
            return nil
        }
        return Int(normalizedChip[match].dropFirst())
    }
}

struct AutotuneRecommendHardware: Equatable {
    var machine: String?
    var chip: String
    var memoryGB: Int
    var bandwidthTier: BandwidthTier
    var detected: Bool
    var osVersion: String
    var binaryVersion: String
    var diversificationID: String
    var hardwareIdentityHash: String

    init(machine: String? = nil, fingerprint: MachineFingerprint, hmacIdentity: HMACIdentity) {
        self.machine = machine
        self.chip = fingerprint.chip
        self.memoryGB = max(1, fingerprint.ramGB)
        self.bandwidthTier = BandwidthTier.derive(chip: fingerprint.chip)
        self.detected = true
        self.osVersion = fingerprint.osVersion
        self.binaryVersion = fingerprint.binaryVersion
        self.diversificationID = hmacIdentity.diversificationID
        self.hardwareIdentityHash = hmacIdentity.cacheIdentityHash
    }

    init(
        machine: String?,
        chip: String,
        memoryGB: Int,
        bandwidthTier: BandwidthTier,
        detected: Bool = true,
        osVersion: String,
        binaryVersion: String,
        diversificationID: String,
        hardwareIdentityHash: String
    ) {
        self.machine = machine
        self.chip = chip
        self.memoryGB = max(1, memoryGB)
        self.bandwidthTier = bandwidthTier
        self.detected = detected
        self.osVersion = osVersion
        self.binaryVersion = binaryVersion
        self.diversificationID = diversificationID
        self.hardwareIdentityHash = hardwareIdentityHash
    }
}

struct HMACIdentity: Equatable {
    static let diversificationDomain = "macprovider-autotune-diversification-v1"
    static let cacheIdentityDomain = "macprovider-autotune-cache-identity-v1"

    var diversificationID: String
    var cacheIdentityHash: String

    static func derive(secret: Data, fingerprint: MachineFingerprint, providerID: String? = nil) -> HMACIdentity {
        let trimmedProviderID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableIdentity = trimmedProviderID?.isEmpty == false
            ? "provider:\(trimmedProviderID!)"
            : "local:\(sha256Hex(secret))"
        let material = "\(stableIdentity)|\(fingerprint.ramGB)|\(fingerprint.chip)"
        return HMACIdentity(
            diversificationID: hmacHex(secret: secret, domain: diversificationDomain, material: material),
            cacheIdentityHash: hmacHex(secret: secret, domain: cacheIdentityDomain, material: material)
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacHex(secret: Data, domain: String, material: String) -> String {
        let key = SymmetricKey(data: secret)
        let bytes = Data("\(domain)\n\(material)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: bytes, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

struct AutotuneHMACSecretStore {
    var path: URL
    var randomBytes: (Int) throws -> Data = Self.secureRandomBytes

    func loadOrCreate() throws -> Data {
        // Keychain path removed 2026-07-03: macOS binds the keychain-item ACL
        // to the specific creating binary's code-signature hash. Auto-update
        // replaces the binary with a new hash → ACL check fails → macOS
        // prompts every operator for the "login" keychain password on the
        // next interactive autotune run after each release. Under launchd
        // (non-interactive) the API returns errSecInteractionRequired and
        // the code silently falls through to file — so the keychain path
        // was already dead weight for the auto-updated background flow,
        // and pure UX drag for the interactive foreground flow.
        //
        // The file at ~/.config/macprovider/autotune-hmac-secret is created
        // at 0600 under a 0700 parent (see writeNewFileSecret + ensurePrivate
        // ParentDirectory). HMAC of autotune log integrity does not need
        // keychain-level protection — the threat model (someone with code
        // execution on this Mac forging autotune logs on the same Mac) is
        // already outside what keychain protects against.
        //
        // Existing operators: any legacy `live.streamvc.macprovider.autotune`
        // keychain item is now orphaned but harmless — it is never read.
        // They can remove it with:
        //   security delete-generic-password -s "live.streamvc.macprovider.autotune"
        // No automatic delete is attempted; SecItemDelete would also trip
        // the ACL prompt for the exact reason this fix exists.
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                return try loadExistingFileSecret()
            } catch {
                return try rotateRecoverableFileSecret()
            }
        }
        return try createFileSecret()
    }

    private func createFileSecret() throws -> Data {
        let secret = try randomBytes(32)
        guard secret.count == 32 else { throw AutotuneRecommendError.noHMACSecret }
        try ensurePrivateParentDirectory()
        if try writeNewFileSecret(secret) {
            return secret
        }
        if errno == EEXIST {
            return try loadExistingFileSecret()
        }
        throw AutotuneRecommendError.noHMACSecret
    }

    static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macprovider/autotune-hmac-secret", isDirectory: false)
    }

    private var usesDefaultPath: Bool {
        path.standardizedFileURL.path == Self.defaultPath.standardizedFileURL.path
    }

    private func ensurePrivateParentDirectory() throws {
        let parent = path.deletingLastPathComponent()
        var st = stat()
        if lstat(parent.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR,
                  st.st_uid == getuid()
            else {
                throw AutotuneRecommendError.noHMACSecret
            }
            return
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in parent.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if lstat(current.path, &st) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFDIR else {
                    throw AutotuneRecommendError.noHMACSecret
                }
                continue
            }
            guard mkdir(current.path, 0o700) == 0 || errno == EEXIST else {
                throw AutotuneRecommendError.noHMACSecret
            }
        }
        guard lstat(parent.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid()
        else {
            throw AutotuneRecommendError.noHMACSecret
        }
    }

    private func loadExistingFileSecret() throws -> Data {
        var st = stat()
        guard lstat(path.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o777) == 0o600
        else {
            throw AutotuneRecommendError.noHMACSecret
        }
        let data = try Data(contentsOf: path, options: [.mappedIfSafe])
        guard data.count == 32 else { throw AutotuneRecommendError.noHMACSecret }
        return data
    }

    private func rotateRecoverableFileSecret() throws -> Data {
        var st = stat()
        guard lstat(path.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid()
        else {
            throw AutotuneRecommendError.noHMACSecret
        }
        try ensurePrivateParentDirectory()
        let quarantine = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).invalid-\(UUID().uuidString)")
        guard rename(path.path, quarantine.path) == 0 else {
            throw AutotuneRecommendError.noHMACSecret
        }
        do {
            return try createFileSecret()
        } catch {
            _ = rename(quarantine.path, path.path)
            throw error
        }
    }

    private func writeNewFileSecret(_ secret: Data) throws -> Bool {
        let fd = path.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        try secret.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < secret.count {
                let n = write(fd, base.advanced(by: written), secret.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AutotuneRecommendError.noHMACSecret
                }
                written += n
            }
        }
        return true
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let rc = data.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        guard rc == errSecSuccess else { throw AutotuneRecommendError.noHMACSecret }
        return data
    }
}

struct DemandRank: Decodable, Equatable {
    struct Row: Decodable, Equatable {
        var demandWeight: Double
        var rank: Int?
        var recommendable: Bool
        var minProviderTarget: Int

        enum CodingKeys: String, CodingKey {
            case demandWeight = "demand_weight"
            case rank
            case recommendable
            case minProviderTarget = "min_provider_target"
        }
    }

    var version: String
    var generatedAt: Date
    var source: String
    var coldStartFloor: Double
    var diversificationBand: Double
    var rows: [String: Row]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case source
        case coldStartFloor = "cold_start_floor"
        case diversificationBand = "diversification_band"
        case rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        source = try c.decode(String.self, forKey: .source)
        coldStartFloor = try c.decode(Double.self, forKey: .coldStartFloor)
        diversificationBand = try c.decode(Double.self, forKey: .diversificationBand)
        rows = try c.decode([String: Row].self, forKey: .rows)
        let rawDate = try c.decode(String.self, forKey: .generatedAt)
        guard let date = ISO8601DateFormatter.autotuneInternet.date(from: rawDate) else {
            throw DecodingError.dataCorruptedError(forKey: .generatedAt, in: c, debugDescription: "generated_at must be RFC3339")
        }
        generatedAt = date
    }

    func validated() throws -> DemandRank {
        guard source == "openrouter_completion_token_rank_operator_curated" else {
            throw AutotuneRecommendError.invalidStaticJSON("demand-rank source")
        }
        guard coldStartFloor == 0.15, diversificationBand == 0.85 else {
            throw AutotuneRecommendError.invalidStaticJSON("demand-rank constants")
        }
        for (key, row) in rows {
            guard row.demandWeight.isFinite, (0.0...1.0).contains(row.demandWeight) else {
                throw AutotuneRecommendError.invalidStaticJSON("demand weight for \(key)")
            }
            if let rank = row.rank, rank <= 0 {
                throw AutotuneRecommendError.invalidStaticJSON("rank for \(key)")
            }
            guard row.minProviderTarget >= 0 else {
                throw AutotuneRecommendError.invalidStaticJSON("min_provider_target for \(key)")
            }
        }
        return self
    }
}

struct CandidateCatalog: Decodable, Equatable {
    struct BenchGate: Decodable, Equatable {
        var minSustainedTPS: Double
        var max4KTTFTMS: Int

        enum CodingKeys: String, CodingKey {
            case minSustainedTPS = "min_sustained_tps"
            case max4KTTFTMS = "max_4k_ttft_ms"
        }
    }

    struct Row: Decodable, Equatable {
        var modelID: String
        var modelRevision: String?
        var modelSHA256: String?
        var minRAMGB: Int
        var minBandwidthTier: BandwidthTier
        var benchGate: BenchGate
        var runtimeStatus: String
        var notes: String?

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case modelRevision = "model_revision"
            case modelSHA256 = "model_sha256"
            case minRAMGB = "min_ram_gb"
            case minBandwidthTier = "min_bandwidth_tier"
            case benchGate = "bench_gate"
            case runtimeStatus = "runtime_status"
            case notes
        }
    }

    var version: String
    var generatedAt: Date
    var source: String
    var rows: [String: Row]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case source
        case rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        source = try c.decode(String.self, forKey: .source)
        rows = try c.decode([String: Row].self, forKey: .rows)
        let rawDate = try c.decode(String.self, forKey: .generatedAt)
        guard let date = ISO8601DateFormatter.autotuneInternet.date(from: rawDate) else {
            throw DecodingError.dataCorruptedError(forKey: .generatedAt, in: c, debugDescription: "generated_at must be RFC3339")
        }
        generatedAt = date
    }

    func validated() throws -> CandidateCatalog {
        guard source == "operator_curated_autotune_candidate_catalog" else {
            throw AutotuneRecommendError.invalidStaticJSON("candidate catalog source")
        }
        let allowedStatuses = Set(["candidate", "listed", "recommendable", "blocked"])
        for (key, row) in rows {
            guard allowedStatuses.contains(row.runtimeStatus) else {
                throw AutotuneRecommendError.invalidStaticJSON("runtime_status for \(key)")
            }
            guard row.minRAMGB >= 0,
                  row.benchGate.minSustainedTPS >= 0,
                  row.benchGate.minSustainedTPS.isFinite,
                  row.benchGate.max4KTTFTMS >= 0
            else {
                throw AutotuneRecommendError.invalidStaticJSON("negative gate for \(key)")
            }
            if row.runtimeStatus != "blocked" {
                guard let revision = row.modelRevision, Self.isHex(revision, count: 40) else {
                    throw AutotuneRecommendError.invalidStaticJSON("model_revision for \(key)")
                }
                guard let sha = row.modelSHA256, Self.isHex(sha, count: 64) else {
                    throw AutotuneRecommendError.invalidStaticJSON("model_sha256 for \(key)")
                }
            }
        }
        return self
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

struct RateCardProjection: Decodable, Equatable {
    struct Row: Decodable, Equatable {
        var promptRatePerMtok: Int64
        var completionRatePerMtok: Int64
        var providerShareBPS: Int64
        var globalMultiplierPPM: Int64

        enum CodingKeys: String, CodingKey {
            case promptRatePerMtok = "prompt_rate_per_mtok"
            case completionRatePerMtok = "completion_rate_per_mtok"
            case providerShareBPS = "provider_share_bps"
            case globalMultiplierPPM = "global_multiplier_ppm"
        }
    }

    var version: String
    var generatedAt: Date
    var usdPerMillionCredits: Double
    var rows: [String: Row]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case usdPerMillionCredits = "usd_per_million_credits"
        case rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        usdPerMillionCredits = try c.decode(Double.self, forKey: .usdPerMillionCredits)
        rows = try c.decode([String: Row].self, forKey: .rows)
        let rawDate = try c.decode(String.self, forKey: .generatedAt)
        guard let date = ISO8601DateFormatter.autotuneInternet.date(from: rawDate) else {
            throw DecodingError.dataCorruptedError(forKey: .generatedAt, in: c, debugDescription: "generated_at must be RFC3339")
        }
        generatedAt = date
    }

    func validated() throws -> RateCardProjection {
        guard !version.isEmpty, usdPerMillionCredits.isFinite, usdPerMillionCredits >= 0 else {
            throw AutotuneRecommendError.invalidRateCard("version/usd_per_million_credits")
        }
        for (key, row) in rows {
            guard row.promptRatePerMtok >= 0,
                  row.completionRatePerMtok >= 0,
                  row.providerShareBPS >= 0,
                  row.globalMultiplierPPM >= 0
            else {
                throw AutotuneRecommendError.invalidRateCard("negative value for \(key)")
            }
        }
        return self
    }

    func rowForRecommendation(modelKey: String) -> (key: String, row: Row)? {
        if let row = rows[modelKey] {
            return (modelKey, row)
        }
        let normalized = AutotuneModelKeyNormalizer.normalize(modelKey)
        if normalized != modelKey, normalized != "default", let row = rows[normalized] {
            return (normalized, row)
        }
        // v1.7.6 Track A1: fall through to the "default" rate-card row when
        // no specific row exists for this model. Matches the coord's
        // `RateFor` fallback semantics (phase4-coordinator/internal/billing/
        // formula.go), which pays the default rate for served inference on
        // any model not explicitly listed. Prior behavior blocked probe-
        // feasible models from recommendation just because the rate-card
        // hadn't caught up — the classic "provider drops out after install"
        // cliff.
        if let row = rows["default"] {
            return ("default", row)
        }
        return nil
    }
}

enum AutotuneModelKeyNormalizer {
    static func normalize(_ model: String) -> String {
        var key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var namespace = ""
        if let slash = key.firstIndex(of: "/") {
            namespace = String(key[..<slash])
            if knownNamespace(namespace) {
                key = String(key[key.index(after: slash)...])
            }
        }
        for suffix in ["-mxfp4-q8", "-4bit", "-8bit"] where key.hasSuffix(suffix) {
            key.removeLast(suffix.count)
        }
        if namespace == "meta-llama", key.hasPrefix("llama-") {
            return "meta-llama/\(key)"
        }
        if key.hasPrefix("meta-llama-") {
            return "meta-llama/\(key.dropFirst("meta-".count))"
        }
        if key.hasPrefix("gpt-oss-") {
            return "openai/\(key)"
        }
        return key
    }

    private static func knownNamespace(_ namespace: String) -> Bool {
        ["mlx-community", "openai", "google", "meta-llama", "nvidia", "qwen"].contains(namespace)
    }
}

struct AutotuneStaticSelection<T> {
    var value: T
    var selectedBytes: Data
    var warnings: Set<AutotuneRecommendWarning>
    var usedFallback: Bool
}

struct AutotuneStaticInputs {
    // v3 keypair rotated 2026-07-03. Only the PUBLIC key is committed —
    // at phase3-binary/dist/static/keys/autotune-static-v3.public.base64
    // and baked below. The private key is held off-repo by the operator
    // (default path ~/.config/macprovider/keys/, chmod 0600); see the
    // README in the keys directory for the full trust model. Older
    // v1.7.9- clients that still bake the v2 pubkey `sidecarIsValid`
    // fail on the v3 sig, fall back to their baked catalog, and stay
    // online thanks to the SPEC-023 v0.2 soft-signal gates.
    static let keyID = "streamvc-autotune-static-v3"
    static let publicKeyName = "autotune_static_json_ed25519_v3"
    static let autotune_static_json_ed25519_v3 = "1qzXegR2OEu0TaQNWjUkN4PamQAHdpvBcYW/pJ4h6oE="
    static let publicKeyBase64 = autotune_static_json_ed25519_v3

    var fetch: (URL) async throws -> Data
    var verifySignature: (Data, Data) -> Bool
    var now: () -> Date

    init(
        fetch: @escaping (URL) async throws -> Data = { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw AutotuneRecommendError.invalidStaticJSON("HTTP \(http.statusCode)")
            }
            return data
        },
        verifySignature: @escaping (Data, Data) -> Bool = Self.defaultSignatureVerifier,
        now: @escaping () -> Date = Date.init
    ) {
        self.fetch = fetch
        self.verifySignature = verifySignature
        self.now = now
    }

    func loadDemandRank() async -> AutotuneStaticSelection<DemandRank> {
        await loadSignedStatic(
            name: "demand-rank",
            bakedBytes: Data(Self.bakedDemandRankJSON.utf8),
            fallbackWarning: .demandRankFallbackUsed,
            staleWarning: .demandRankStale
        ) { try Self.decodeDemandRank($0) }
    }

    func loadCandidateCatalog() async -> AutotuneStaticSelection<CandidateCatalog> {
        await loadSignedStatic(
            name: "autotune-candidates",
            bakedBytes: Data(Self.bakedCandidateCatalogJSON.utf8),
            fallbackWarning: .candidateCatalogFallbackUsed,
            staleWarning: .candidateCatalogStale
        ) { try Self.decodeCandidateCatalog($0) }
    }

    func loadRateCard() async -> AutotuneStaticSelection<RateCardProjection> {
        let baked = Data(Self.bakedRateCardJSON.utf8)
        let bakedValue = (try? Self.decodeRateCard(baked))!
        do {
            let bytes = try await fetch(URL(string: "https://coordinator.streamvc.live/v1/rate-card")!)
            let value = try Self.decodeRateCard(bytes)
            return AutotuneStaticSelection(value: value, selectedBytes: bytes, warnings: [], usedFallback: false)
        } catch {
            return AutotuneStaticSelection(value: bakedValue, selectedBytes: baked, warnings: [.rateCardFallbackUsed], usedFallback: true)
        }
    }

    private func loadSignedStatic<T>(
        name: String,
        bakedBytes: Data,
        fallbackWarning: AutotuneRecommendWarning,
        staleWarning: AutotuneRecommendWarning,
        decode: (Data) throws -> T
    ) async -> AutotuneStaticSelection<T> {
        let bakedValue = (try? decode(bakedBytes))!
        let bakedGeneratedAt = generatedAt(in: bakedBytes) ?? .distantFuture
        do {
            let jsonURL = URL(string: "https://coordinator.streamvc.live/static/\(name).json")!
            let sigURL = URL(string: "https://coordinator.streamvc.live/static/\(name).json.sig")!
            let jsonBytes = try await fetch(jsonURL)
            let sigBytes = try await fetch(sigURL)
            guard sidecarIsValid(sigBytes), verifySignature(jsonBytes, sigBytes) else {
                throw AutotuneRecommendError.invalidStaticJSON("signature \(name)")
            }
            let value = try decode(jsonBytes)
            guard let fetchedGeneratedAt = generatedAt(in: jsonBytes) else {
                throw AutotuneRecommendError.invalidStaticJSON("generated_at \(name)")
            }
            let current = now()
            guard fetchedGeneratedAt >= bakedGeneratedAt,
                  fetchedGeneratedAt <= current.addingTimeInterval(10 * 60),
                  current.timeIntervalSince(fetchedGeneratedAt) <= 30 * 24 * 3600
            else {
                throw AutotuneRecommendError.invalidStaticJSON("freshness \(name)")
            }
            var warnings = Set<AutotuneRecommendWarning>()
            if current.timeIntervalSince(fetchedGeneratedAt) >= 14 * 24 * 3600 {
                warnings.insert(staleWarning)
            }
            return AutotuneStaticSelection(value: value, selectedBytes: jsonBytes, warnings: warnings, usedFallback: false)
        } catch {
            return AutotuneStaticSelection(value: bakedValue, selectedBytes: bakedBytes, warnings: [fallbackWarning], usedFallback: true)
        }
    }

    private func sidecarIsValid(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["key_id", "alg", "signature"]),
              object["key_id"] as? String == Self.keyID,
              object["alg"] as? String == "ed25519",
              let signature = object["signature"] as? String,
              Data(base64Encoded: signature) != nil
        else {
            return false
        }
        return true
    }

    static func defaultSignatureVerifier(jsonBytes: Data, sidecarBytes: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: sidecarBytes) as? [String: Any],
              let signature = object["signature"] as? String,
              let signatureBytes = Data(base64Encoded: signature),
              let publicKeyBytes = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        else {
            return false
        }
        return publicKey.isValidSignature(signatureBytes, for: jsonBytes)
    }

    static func decodeDemandRank(_ data: Data) throws -> DemandRank {
        try JSONDecoder.autotune.decode(DemandRank.self, from: data).validated()
    }

    static func decodeCandidateCatalog(_ data: Data) throws -> CandidateCatalog {
        try JSONDecoder.autotune.decode(CandidateCatalog.self, from: data).validated()
    }

    static func decodeRateCard(_ data: Data) throws -> RateCardProjection {
        try JSONDecoder.autotune.decode(RateCardProjection.self, from: data).validated()
    }

    static func candidateCatalogSHA256(bytes: Data) -> String {
        Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func generatedAt(in data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["generated_at"] as? String
        else {
            return nil
        }
        return ISO8601DateFormatter.autotuneInternet.date(from: raw)
    }
}

struct CandidateBenchmark: Equatable {
    var modelKey: String
    var sustainedTPS: Double
    var ttftMS: Int
    var swapDetected: Bool
    var thermalThrottleDetected: Bool
    var artifactSHA256: String
    var modelArtifactPath: String
    var benchmarkID: String?
    var generatedAt: Date
    var candidateCatalogSHA256: String
    var binaryVersion: String
    var modelID: String
    var hardwareIdentityHash: String
}

struct AutotuneRecommendRequest {
    var hardware: AutotuneRecommendHardware
    var demandRank: DemandRank
    var candidateCatalog: CandidateCatalog
    var candidateCatalogSHA256: String
    var rateCard: RateCardProjection
    var benchmarks: [String: CandidateBenchmark]
    var warnings: Set<AutotuneRecommendWarning>
    var generatedAt: Date
    var electricityUSDPerKWH: Double?
    var assumedUtilization: Double
    var availabilityHoursPerDay: Int
    var donorMode: Bool
}

struct AutotuneCandidateScore: Equatable {
    var rank: Int
    var catalogKey: String
    var model: String
    var eligible: Bool
    var expectedGrossUSDPerHour: Double
    var expectedNetUSDPerHour: Double
    var electricityUSDPerHour: Double?
    var platformFeeUSDPerHour: Double
    var tokensPerSecond: Double
    var memoryHeadroomGB: Double
    var confidence: String
    var why: String
    var rawScore: Double
}

struct AutotuneRecommendResult: Equatable {
    var generatedAt: Date
    var hardware: AutotuneRecommendHardware
    var rateCardVersion: String
    var demandRankVersion: String
    var candidateCatalogVersion: String
    var candidateCatalogSHA256: String
    var benchmarkID: String?
    var benchmarkGeneratedAt: Date?
    var recommendedModel: String?
    var selectedCandidate: AutotuneCandidateScore?
    var candidates: [AutotuneCandidateScore]
    var defaultModel: String?
    var donorFallbackModel: String?
    var donorFallbackCandidate: AutotuneCandidateScore?
    var donorFallbackNetUSDPerHour: Double?
    var recommendedDeltaUSDPerHour: Double
    var recommendedDeltaPercent: Double
    var warnings: [AutotuneRecommendWarning]
    var assumedUtilization: Double
    var availabilityHoursPerDay: Int
    var electricityUSDPerKWH: Double?
    /// modelKey -> reason string for each candidate that did not produce a
    /// feasible probe. Populated by AutotuneRecommendationBenchmarker and
    /// attached by the CLI caller after engine.recommend() returns. Persisted
    /// into last-recommendation.json so post-hoc diagnosis explains WHY
    /// benchmark_id is null / no eligible paid model was found.
    var probeDiagnostics: [String: String] = [:]
}

struct AutotuneRecommendEngine {
    static let paidThreshold = 0.0050
    static let safetyMarginGB = 4
    static let maxBenchmarkAge: TimeInterval = 7 * 24 * 3600

    func recommend(_ request: AutotuneRecommendRequest) -> AutotuneRecommendResult {
        var warnings = request.warnings
        if request.electricityUSDPerKWH == nil {
            warnings.insert(.electricityNotIncluded)
        }
        if request.hardware.bandwidthTier == .unknown {
            warnings.insert(.hardwareTierUnknown)
        }

        let scored = request.candidateCatalog.rows.keys.sorted().compactMap { modelKey -> AutotuneCandidateScore? in
            guard let candidate = request.candidateCatalog.rows[modelKey],
                  let demand = request.demandRank.rows[modelKey]
            else {
                return nil
            }
            let rateMatch = request.rateCard.rowForRecommendation(modelKey: modelKey)
            let benchmark = request.benchmarks[modelKey]
            let eligible = isEligible(
                modelKey: modelKey,
                candidate: candidate,
                demand: demand,
                rateCardRow: rateMatch?.row,
                benchmark: benchmark,
                request: request
            )
            // Warning insertion deferred until final selection is known —
            // scoring EVERY eligible row here would falsely warn when a
            // lower-ranked default-tier or swap-detected candidate is not
            // the one actually recommended. See warning attach block below.
            let tps = benchmark?.sustainedTPS ?? 0
            let rateRow = rateMatch?.row
            let usdPerMillionCompletion = Double(rateRow?.completionRatePerMtok ?? 0)
                * (Double(rateRow?.globalMultiplierPPM ?? 0) / 1_000_000.0)
                * (request.rateCard.usdPerMillionCredits / 1_000_000.0)
            let gross = tps * 3600.0 * usdPerMillionCompletion / 1_000_000.0
            let providerShare = Double(rateRow?.providerShareBPS ?? 0) / 10_000.0
            let platformFee = gross * max(0, 1 - providerShare)
            let electricity = request.electricityUSDPerKWH.map {
                $0 * Self.estimatedWatts(for: request.hardware.bandwidthTier) / 1_000.0 * request.assumedUtilization
            }
            let net = (gross - platformFee) * request.assumedUtilization - (electricity ?? 0)
            let demandWeight = max(demand.demandWeight, request.demandRank.coldStartFloor)
            let raw = tps * 3600.0 * usdPerMillionCompletion * providerShare * demandWeight
            let headroom = Double(request.hardware.memoryGB - Self.safetyMarginGB - candidate.minRAMGB)
            let confidence = confidence(warnings: warnings, benchmark: benchmark)
            // v1.7.6 Track A1 correction: when the rate-card lookup resolves
            // via the "default" fallthrough (rate key == "default" but the
            // catalog model isn't literally "default"), the served-model
            // identity must remain the catalog model. Otherwise `--apply`
            // writes `config.model = "default"` at ConfigApplier — which is
            // the pricing key, not a real model runtime identity — and the
            // HTTP server would reject buyer requests for the real model.
            let servedModel: String
            if let match = rateMatch, match.key == "default", modelKey != "default" {
                servedModel = modelKey
            } else {
                servedModel = rateMatch?.key ?? modelKey
            }
            return AutotuneCandidateScore(
                rank: 0,
                catalogKey: modelKey,
                model: servedModel,
                eligible: eligible,
                expectedGrossUSDPerHour: gross.rounded6,
                expectedNetUSDPerHour: net.rounded6,
                electricityUSDPerHour: electricity?.rounded6,
                platformFeeUSDPerHour: platformFee.rounded6,
                tokensPerSecond: tps.rounded6,
                memoryHeadroomGB: headroom.rounded6,
                confidence: confidence,
                why: why(modelKey: modelKey, eligible: eligible, net: net),
                rawScore: raw
            )
        }
        .sorted {
            if $0.eligible != $1.eligible { return $0.eligible && !$1.eligible }
            if $0.rawScore != $1.rawScore { return $0.rawScore > $1.rawScore }
            return $0.model < $1.model
        }
        .enumerated()
        .map { offset, value in
            var next = value
            next.rank = offset + 1
            return next
        }

        let eligible = scored.filter(\.eligible)
        let bestRaw = eligible.map(\.rawScore).max() ?? 0
        let pool = eligible.filter { $0.rawScore >= request.demandRank.diversificationBand * bestRaw }
        let selected = pool.isEmpty ? nil : pool[stableHashIndex(request.hardware.diversificationID, count: pool.count)]
        var recommended = selected
        if let selected, selected.expectedNetUSDPerHour < Self.paidThreshold {
            recommended = nil
            warnings.insert(.recommendationBelowThreshold)
        }
        if eligible.isEmpty {
            warnings.insert(.noEligiblePaidModel)
        }

        let defaultModel = scored.first?.model
        let delta = (recommended?.expectedNetUSDPerHour ?? 0) - (scored.first(where: { $0.model == defaultModel })?.expectedNetUSDPerHour ?? 0)
        let denominator = abs(scored.first(where: { $0.model == defaultModel })?.expectedNetUSDPerHour ?? 0)
        let percent = denominator > 0 ? delta / denominator * 100.0 : 0.0
        let selectedBenchmark = recommended.flatMap { request.benchmarks[$0.catalogKey] } ?? eligible.compactMap { request.benchmarks[$0.catalogKey] }.first
        let donorFallback = scored.first { score in
            Self.donorModeCompatible(
                modelKey: score.catalogKey,
                candidate: request.candidateCatalog.rows[score.catalogKey],
                request: request
            )
        }
        // v1.7.6 Track A1/A2a: only surface default-tier and swap warnings when
        // they apply to the ACTUALLY-recommended candidate (or donor fallback
        // when no paid recommendation lands). Prior placement inside the score
        // loop would warn based on any lower-ranked eligible candidate — false
        // positive per codex CODE-LOW-1.
        let attachTargets: [(catalogKey: String, model: String)] = [
            recommended.map { ($0.catalogKey, $0.model) },
            recommended == nil ? donorFallback.map { ($0.catalogKey, $0.model) } : nil,
        ].compactMap { $0 }
        for target in attachTargets {
            let rateMatch = request.rateCard.rowForRecommendation(modelKey: target.catalogKey)
            if rateMatch?.key == "default", target.catalogKey != "default" {
                warnings.insert(.rateCardDefaultTierUsed)
            }
            if request.benchmarks[target.catalogKey]?.swapDetected == true {
                warnings.insert(.swapObservedUnderLoad)
            }
            // v1.7.9 Track A5: catalog TPS/TTFT gates are soft signals.
            // Surface the gap when the recommended candidate misses either
            // gate so the operator sees the QoS delta vs catalog expectation.
            if let benchmark = request.benchmarks[target.catalogKey],
               let candidateRow = request.candidateCatalog.rows[target.catalogKey] {
                if benchmark.sustainedTPS < Double(candidateRow.benchGate.minSustainedTPS) {
                    warnings.insert(.tpsBelowGate)
                }
                if benchmark.ttftMS > candidateRow.benchGate.max4KTTFTMS {
                    warnings.insert(.ttftAboveGate)
                }
            }
        }

        let resultCandidates = eligible.isEmpty ? Array(scored.prefix(5)) : Array(eligible.prefix(5))

        return AutotuneRecommendResult(
            generatedAt: request.generatedAt,
            hardware: request.hardware,
            rateCardVersion: request.rateCard.version,
            demandRankVersion: request.demandRank.version,
            candidateCatalogVersion: request.candidateCatalog.version,
            candidateCatalogSHA256: request.candidateCatalogSHA256,
            benchmarkID: selectedBenchmark?.benchmarkID,
            benchmarkGeneratedAt: selectedBenchmark?.generatedAt,
            recommendedModel: recommended?.model,
            selectedCandidate: recommended,
            candidates: resultCandidates,
            defaultModel: defaultModel,
            donorFallbackModel: donorFallback?.model,
            donorFallbackCandidate: donorFallback,
            donorFallbackNetUSDPerHour: donorFallback?.expectedNetUSDPerHour,
            recommendedDeltaUSDPerHour: delta.rounded6,
            recommendedDeltaPercent: percent.rounded6,
            warnings: warnings.map(\.rawValue).sorted().compactMap(AutotuneRecommendWarning.init(rawValue:)),
            assumedUtilization: request.assumedUtilization,
            availabilityHoursPerDay: request.availabilityHoursPerDay,
            electricityUSDPerKWH: request.electricityUSDPerKWH
        )
    }

    func isEligible(
        modelKey: String,
        candidate: CandidateCatalog.Row,
        demand: DemandRank.Row,
        rateCardRow: RateCardProjection.Row?,
        benchmark: CandidateBenchmark?,
        request: AutotuneRecommendRequest
    ) -> Bool {
        if !demand.recommendable { return false }
        if candidate.runtimeStatus != "recommendable" { return false }
        guard rateCardRow != nil else { return false }
        guard candidate.modelRevision != nil, candidate.modelSHA256 != nil else { return false }
        guard candidate.minRAMGB <= request.hardware.memoryGB - Self.safetyMarginGB else { return false }
        guard request.hardware.bandwidthTier.satisfies(minimum: candidate.minBandwidthTier) else { return false }
        guard let benchmark else { return false }
        // v1.7.6 Track A2a: swapDetected relaxed to soft-signal.
        // v1.7.9 Track A5 (Option B): sustainedTPS < min_sustained_tps
        // and ttftMS > max_4k_ttft_ms both relaxed to soft-signals too.
        // These catalog gates express warm-service QoS targets — a
        // provider that misses them still EARNS at the rate implied by
        // its measured TPS via `expected_net_usd_per_hour`. The real
        // financial gate that decides "paid vs donor" is
        // `expected_net_usd_per_hour >= $0.005/hr` (paidThreshold),
        // applied later in recommend().
        // thermalThrottleDetected stays a hard-block because throttled
        // TPS measurements are unreliable (may be optimistically low
        // and rebound in production, but also may mask real degradation).
        return !benchmark.thermalThrottleDetected
            && Self.cachedBenchmarkAdmitted(benchmark, request: request, modelKey: modelKey)
    }

    static func donorModeAdmitted(
        modelKey: String,
        candidate: CandidateCatalog.Row?,
        request: AutotuneRecommendRequest
    ) -> Bool {
        request.donorMode && donorModeCompatible(modelKey: modelKey, candidate: candidate, request: request)
    }

    private static func donorModeCompatible(
        modelKey: String,
        candidate: CandidateCatalog.Row?,
        request: AutotuneRecommendRequest
    ) -> Bool {
        // v1.7.6 Track A2a + v1.7.9 Track A5: donor mode inherits the
        // paid-tier relaxations. Only thermal throttle stays a hard-block.
        guard let candidate,
              ["candidate", "listed", "recommendable"].contains(candidate.runtimeStatus),
              candidate.modelRevision != nil,
              candidate.modelSHA256 != nil,
              candidate.minRAMGB <= request.hardware.memoryGB - safetyMarginGB,
              request.hardware.bandwidthTier.satisfies(minimum: candidate.minBandwidthTier),
              let benchmark = request.benchmarks[modelKey],
              !benchmark.thermalThrottleDetected
        else {
            return false
        }
        return cachedBenchmarkAdmitted(benchmark, request: request, modelKey: modelKey)
    }

    static func cachedBenchmarkAdmitted(_ benchmark: CandidateBenchmark, request: AutotuneRecommendRequest, modelKey: String) -> Bool {
        guard benchmark.candidateCatalogSHA256 == request.candidateCatalogSHA256,
              benchmark.binaryVersion == request.hardware.binaryVersion,
              benchmark.modelID == request.candidateCatalog.rows[modelKey]?.modelID,
              benchmark.artifactSHA256 == request.candidateCatalog.rows[modelKey]?.modelSHA256,
              benchmark.hardwareIdentityHash == request.hardware.hardwareIdentityHash,
              benchmark.modelArtifactPath.hasPrefix("/")
        else {
            return false
        }
        return request.generatedAt.timeIntervalSince(benchmark.generatedAt) <= maxBenchmarkAge
    }

    private static func estimatedWatts(for tier: BandwidthTier) -> Double {
        switch tier {
        case .s: return 120
        case .a: return 95
        case .b: return 65
        case .c: return 40
        case .unknown: return 50
        }
    }

    private func stableHashIndex(_ input: String, count: Int) -> Int {
        let digest = SHA256.hash(data: Data(input.utf8))
        let first8 = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(first8 % UInt64(count))
    }

    private func confidence(warnings: Set<AutotuneRecommendWarning>, benchmark: CandidateBenchmark?) -> String {
        if (warnings.contains(.rateCardFallbackUsed) && warnings.contains(.demandRankFallbackUsed))
            || warnings.contains(.hardwareTierUnknown)
            || warnings.contains(.electricityNotIncluded)
            || warnings.contains(.demandRankStale)
            || warnings.contains(.candidateCatalogStale) {
            return "low"
        }
        if warnings.contains(.rateCardFallbackUsed) || warnings.contains(.demandRankFallbackUsed) || warnings.contains(.candidateCatalogFallbackUsed) || benchmark == nil {
            return "medium"
        }
        return "high"
    }

    private func why(modelKey: String, eligible: Bool, net: Double) -> String {
        if eligible {
            return "\(modelKey) has the strongest demand-weighted expected net capacity for this Mac.".prefixString(140)
        }
        return "\(modelKey) did not clear one or more paid recommendation gates.".prefixString(140)
    }
}

extension AutotuneRecommendResult {
    func jsonString() -> String {
        let warningsJSON = warnings.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let candidatesJSON = candidates.map { candidate in
            """
            {"rank":\(candidate.rank),"model":\(candidate.model.jsonEscaped),"eligible":\(candidate.eligible),"expected_gross_usd_per_hour":\(candidate.expectedGrossUSDPerHour.jsonNumber),"expected_net_usd_per_hour":\(candidate.expectedNetUSDPerHour.jsonNumber),"electricity_usd_per_hour":\(candidate.electricityUSDPerHour?.jsonNumber ?? "null"),"platform_fee_usd_per_hour":\(candidate.platformFeeUSDPerHour.jsonNumber),"tokens_per_second":\(candidate.tokensPerSecond.jsonNumber),"memory_headroom_gb":\(candidate.memoryHeadroomGB.jsonNumber),"confidence":\(candidate.confidence.jsonEscaped),"why":\(candidate.why.jsonEscaped)}
            """
        }.joined(separator: ",")
        return """
        {"schema_version":"autotune_recommend.v1","generated_at":\(ISO8601DateFormatter.autotuneInternet.string(from: generatedAt).jsonEscaped),"hardware":{"machine":\(hardware.machine?.jsonEscaped ?? "null"),"chip":\(hardware.chip.jsonEscaped),"memory_gb":\(hardware.memoryGB),"bandwidth_tier":\(hardware.bandwidthTier.rawValue.jsonEscaped),"detected":\(hardware.detected),"os_version":\(hardware.osVersion.jsonEscaped),"binary_version":\(hardware.binaryVersion.jsonEscaped)},"inputs":{"rate_card_version":\(rateCardVersion.jsonEscaped),"demand_rank_version":\(demandRankVersion.jsonEscaped),"candidate_catalog_version":\(candidateCatalogVersion.jsonEscaped),"electricity_usd_per_kwh":\(electricityUSDPerKWH?.jsonNumber ?? "null"),"assumed_utilization":\(assumedUtilization.jsonNumber),"availability_hours_per_day":\(availabilityHoursPerDay)},"recommended_model":\(recommendedModel?.jsonEscaped ?? "null"),"candidates":[\(candidatesJSON)],"comparison":{"default_model":\(defaultModel?.jsonEscaped ?? "null"),"recommended_delta_usd_per_hour":\(recommendedDeltaUSDPerHour.jsonNumber),"recommended_delta_percent":\(recommendedDeltaPercent.jsonNumber)},"warnings":[\(warningsJSON)]}
        """
    }

    func storedStateJSON() -> String {
        let diagnosticsJSON = probeDiagnostics.keys.sorted().map { key in
            "\(key.jsonEscaped):\(probeDiagnostics[key]!.jsonEscaped)"
        }.joined(separator: ",")
        return """
        {"generated_at":\(ISO8601DateFormatter.autotuneInternet.string(from: generatedAt).jsonEscaped),"rate_card_version":\(rateCardVersion.jsonEscaped),"demand_rank_version":\(demandRankVersion.jsonEscaped),"candidate_catalog_version":\(candidateCatalogVersion.jsonEscaped),"candidate_catalog_sha256":\(candidateCatalogSHA256.jsonEscaped),"benchmark_id":\(benchmarkID?.jsonEscaped ?? "null"),"benchmark_generated_at":\(benchmarkGeneratedAt.map { ISO8601DateFormatter.autotuneInternet.string(from: $0).jsonEscaped } ?? "null"),"binary_version":\(hardware.binaryVersion.jsonEscaped),"hardware_identity_hash":\(hardware.hardwareIdentityHash.jsonEscaped),"recommended_model":\(recommendedModel?.jsonEscaped ?? "null"),"probe_diagnostics":{\(diagnosticsJSON)}}
        """
    }

    func humanTranscript() -> String {
        let machineOrChip = hardware.machine ?? hardware.chip
        if let recommendedModel,
           let candidate = selectedCandidate ?? candidates.first(where: { $0.model == recommendedModel }) {
            return """
            Detected \(machineOrChip), \(hardware.memoryGB) GB unified memory, Tier \(hardware.bandwidthTier.rawValue).
            Benchmarked \(candidates.filter(\.eligible).count) compatible models against rate card \(rateCardVersion) and demand rank \(demandRankVersion).

            Recommended: \(recommendedModel)
            Expected net capacity: \(formatUSD(candidate.expectedNetUSDPerHour))/hr at \(Int(assumedUtilization * 100))% utilization
            Why: \(formatUSD(recommendedDeltaUSDPerHour))/hr vs default \(defaultModel ?? "none"); \(String(format: "%.1f", candidate.memoryHeadroomGB)) GB memory headroom

            This is an estimate, not a guarantee. Actual earnings depend on buyer demand, uptime, thermal state, electricity, and rate-card changes.

            Start provider with \(recommendedModel)? [Y/n]
            """
        }
        let best = donorFallbackModel ?? "none"
        let value = donorFallbackNetUSDPerHour.map { formatUSD($0) } ?? "$0.0000"
        return """
        Detected \(machineOrChip), \(hardware.memoryGB) GB unified memory, Tier \(hardware.bandwidthTier.rawValue).
        No paid model currently clears the minimum net-yield threshold of $0.0050/hr.

        Best compatible option: \(best)
        Expected net capacity: \(value)/hr before demand risk
        Recommendation: donor mode only

        You can keep this Mac configured for donor-mode testing, but it is not expected to earn meaningful revenue on the current rate card.
        Enable donor mode? [y/N]
        """
    }

    private func formatUSD(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }
}

struct LastRecommendationState: Decodable, Equatable {
    var generatedAt: Date
    var rateCardVersion: String
    var demandRankVersion: String
    var candidateCatalogVersion: String
    var candidateCatalogSHA256: String
    var benchmarkID: String?
    var benchmarkGeneratedAt: Date?
    var binaryVersion: String
    var hardwareIdentityHash: String
    var recommendedModel: String?
    var probeDiagnostics: [String: String]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case rateCardVersion = "rate_card_version"
        case demandRankVersion = "demand_rank_version"
        case candidateCatalogVersion = "candidate_catalog_version"
        case candidateCatalogSHA256 = "candidate_catalog_sha256"
        case benchmarkID = "benchmark_id"
        case benchmarkGeneratedAt = "benchmark_generated_at"
        case binaryVersion = "binary_version"
        case hardwareIdentityHash = "hardware_identity_hash"
        case recommendedModel = "recommended_model"
        case probeDiagnostics = "probe_diagnostics"
    }

    init(
        generatedAt: Date,
        rateCardVersion: String,
        demandRankVersion: String,
        candidateCatalogVersion: String,
        candidateCatalogSHA256: String,
        benchmarkID: String?,
        benchmarkGeneratedAt: Date?,
        binaryVersion: String,
        hardwareIdentityHash: String,
        recommendedModel: String?,
        probeDiagnostics: [String: String] = [:]
    ) {
        self.generatedAt = generatedAt
        self.rateCardVersion = rateCardVersion
        self.demandRankVersion = demandRankVersion
        self.candidateCatalogVersion = candidateCatalogVersion
        self.candidateCatalogSHA256 = candidateCatalogSHA256
        self.benchmarkID = benchmarkID
        self.benchmarkGeneratedAt = benchmarkGeneratedAt
        self.binaryVersion = binaryVersion
        self.hardwareIdentityHash = hardwareIdentityHash
        self.recommendedModel = recommendedModel
        self.probeDiagnostics = probeDiagnostics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let generated = try c.decode(String.self, forKey: .generatedAt)
        generatedAt = ISO8601DateFormatter.autotuneInternet.date(from: generated) ?? .distantPast
        rateCardVersion = try c.decode(String.self, forKey: .rateCardVersion)
        demandRankVersion = try c.decode(String.self, forKey: .demandRankVersion)
        candidateCatalogVersion = try c.decode(String.self, forKey: .candidateCatalogVersion)
        candidateCatalogSHA256 = try c.decode(String.self, forKey: .candidateCatalogSHA256)
        benchmarkID = try c.decodeIfPresent(String.self, forKey: .benchmarkID)
        if let raw = try c.decodeIfPresent(String.self, forKey: .benchmarkGeneratedAt) {
            benchmarkGeneratedAt = ISO8601DateFormatter.autotuneInternet.date(from: raw)
        } else {
            benchmarkGeneratedAt = nil
        }
        binaryVersion = try c.decode(String.self, forKey: .binaryVersion)
        hardwareIdentityHash = try c.decode(String.self, forKey: .hardwareIdentityHash)
        recommendedModel = try c.decodeIfPresent(String.self, forKey: .recommendedModel)
        probeDiagnostics = try c.decodeIfPresent([String: String].self, forKey: .probeDiagnostics) ?? [:]
    }
}

enum RecommendationStateStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macprovider/last-recommendation.json")
    }

    static func write(_ result: AutotuneRecommendResult, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try result.storedStateJSON().data(using: .utf8)!.write(to: url, options: .atomic)
    }

    static func read(from url: URL = defaultURL) throws -> LastRecommendationState {
        try JSONDecoder.autotune.decode(LastRecommendationState.self, from: Data(contentsOf: url))
    }

    static func isStale(stored: LastRecommendationState, current: LastRecommendationState, now: Date) -> Bool {
        if stored.rateCardVersion != current.rateCardVersion { return true }
        if stored.demandRankVersion != current.demandRankVersion { return true }
        if stored.candidateCatalogVersion != current.candidateCatalogVersion { return true }
        if stored.candidateCatalogSHA256 != current.candidateCatalogSHA256 { return true }
        if stored.binaryVersion != current.binaryVersion { return true }
        if stored.hardwareIdentityHash != current.hardwareIdentityHash { return true }
        guard let benchmarkGeneratedAt = stored.benchmarkGeneratedAt else { return true }
        return now.timeIntervalSince(benchmarkGeneratedAt) > AutotuneRecommendEngine.maxBenchmarkAge
    }
}

struct RecommendationFreshnessChecker {
    var staticInputs: AutotuneStaticInputs = AutotuneStaticInputs()
    var fingerprint: MachineFingerprint = MachineFingerprinter().sample()
    var providerID: String?
    var hmacSecretURL: URL = AutotuneHMACSecretStore.defaultPath
    var stateURL: URL = RecommendationStateStore.defaultURL
    var now: Date = Date()

    enum Status: Equatable {
        case missing
        case fresh
        case stale(Date)
    }

    func status() async -> Status {
        guard let stored = try? RecommendationStateStore.read(from: stateURL) else {
            return .missing
        }
        let secret: Data
        do {
            secret = try AutotuneHMACSecretStore(path: hmacSecretURL).loadOrCreate()
        } catch {
            return .stale(stored.generatedAt)
        }

        let demand = await staticInputs.loadDemandRank()
        let catalog = await staticInputs.loadCandidateCatalog()
        let rateCard = await staticInputs.loadRateCard()
        let identity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint, providerID: providerID)
        let current = LastRecommendationState(
            generatedAt: now,
            rateCardVersion: rateCard.value.version,
            demandRankVersion: demand.value.version,
            candidateCatalogVersion: catalog.value.version,
            candidateCatalogSHA256: AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalog.selectedBytes),
            benchmarkID: stored.benchmarkID,
            benchmarkGeneratedAt: stored.benchmarkGeneratedAt,
            binaryVersion: fingerprint.binaryVersion,
            hardwareIdentityHash: identity.cacheIdentityHash,
            recommendedModel: stored.recommendedModel
        )
        return RecommendationStateStore.isStale(stored: stored, current: current, now: now)
            ? .stale(stored.generatedAt)
            : .fresh
    }

    func staleRecommendationSince() async -> Date? {
        if case let .stale(generatedAt) = await status() {
            return generatedAt
        }
        return nil
    }
}

struct VerifiedModelArtifact {
    var modelArgument: String
    var sha256: String
}

struct ProbeSafetySample: Equatable {
    var pageouts: UInt64?
    var thermalState: ProcessInfo.ThermalState?
}

protocol ProbeSafetySampling {
    func sample() -> ProbeSafetySample
}

struct ProbeSafetyAssessment: Equatable {
    var swapDetected: Bool
    var thermalThrottleDetected: Bool

    static func assess(before: ProbeSafetySample, after: ProbeSafetySample) -> ProbeSafetyAssessment {
        let swapDetected: Bool
        if let beforePageouts = before.pageouts, let afterPageouts = after.pageouts {
            swapDetected = afterPageouts > beforePageouts
        } else {
            swapDetected = true
        }
        let states = [before.thermalState, after.thermalState]
        let thermalKnown = states.allSatisfy { $0 != nil }
        let thermalThrottleDetected = !thermalKnown || states.compactMap { $0 }.contains { ThermalGate.shouldThrottle($0) }
        return ProbeSafetyAssessment(
            swapDetected: swapDetected,
            thermalThrottleDetected: thermalThrottleDetected
        )
    }
}

struct SystemProbeSafetySampler: ProbeSafetySampling {
    func sample() -> ProbeSafetySample {
        ProbeSafetySample(
            pageouts: Self.vmStatCounter(named: "Pageouts"),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    private static func vmStatCounter(named key: String) -> UInt64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let digits = trimmed.dropFirst(key.count + 1).filter(\.isNumber)
            return UInt64(digits)
        }
        return nil
    }
}

struct HuggingFaceSnapshotDownloader {
    struct ModelInfo: Decodable {
        var siblings: [Sibling]
    }

    struct Sibling: Decodable {
        var rfilename: String
    }

    private static let guardedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        return URLSession(configuration: config)
    }()

    // Retry-with-resume policy for the transient network errors that URLSession
    // serializes into NSURLSessionDownloadTaskResumeData on -1005 / -1001 /
    // -1009 / -1004 / -1006 (network connection lost, timeout, offline, host
    // routing failure, DNS lookup failure). Multi-GB HF safetensors shards
    // reliably trip these over ~10-30 min continuous transfers on residential
    // links; without resume, one drop wipes gigabytes of prior progress and
    // fails install with die 6.
    struct DownloadRetryPolicy {
        var maxAttempts: Int
        var baseDelaySeconds: Double
        var backoffMultiplier: Double
        var sleep: @Sendable (UInt64) async throws -> Void

        static let production = DownloadRetryPolicy(
            maxAttempts: 3,
            baseDelaySeconds: 5.0,
            backoffMultiplier: 4.0,
            sleep: { ns in try await Task.sleep(nanoseconds: ns) }
        )
    }

    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await HuggingFaceSnapshotDownloader.guardedSession.data(for: request, delegate: HFRedirectGuard())
    }
    var download: (URLRequest) async throws -> (URL, URLResponse) = { request in
        try await HuggingFaceSnapshotDownloader.downloadWithResume(
            request: request,
            policy: .production,
            initialDownload: { req in
                try await HuggingFaceSnapshotDownloader.guardedSession.download(
                    for: req, delegate: HFAssetRedirectGuard()
                )
            },
            resumeDownload: { data in
                try await HuggingFaceSnapshotDownloader.guardedSession.download(
                    resumeFrom: data, delegate: HFAssetRedirectGuard()
                )
            }
        )
    }

    // Retry-with-resume shell. Delegates the actual network operation to
    // injectable closures so unit tests can drive the retry state machine
    // without a live URLSession or real backoff delays.
    //
    // Loop invariants:
    //  - resumeData starts nil (first attempt is a fresh download).
    //  - On transient URLError, capture resume data from userInfo (may be nil
    //    if the failure was too early for URLSession to serialize state).
    //  - On next attempt, if resumeData is non-nil use resumeDownload; else
    //    fall back to initialDownload (fresh start).
    //  - Non-transient URLError or non-URLError bubbles up immediately.
    //  - After maxAttempts failures, throw the last recorded error.
    //  - Cancellation cooperates through policy.sleep (Task.sleep participates
    //    in Swift structured concurrency cancellation).
    static func downloadWithResume(
        request: URLRequest,
        policy: DownloadRetryPolicy,
        initialDownload: @Sendable (URLRequest) async throws -> (URL, URLResponse),
        resumeDownload: @Sendable (Data) async throws -> (URL, URLResponse)
    ) async throws -> (URL, URLResponse) {
        var lastError: Error?
        var resumeData: Data?
        for attempt in 0..<max(1, policy.maxAttempts) {
            do {
                if let data = resumeData {
                    return try await resumeDownload(data)
                }
                return try await initialDownload(request)
            } catch let error as URLError where isTransientDownloadError(error) {
                lastError = error
                if let extracted = extractResumeData(from: error) {
                    resumeData = extracted
                }
                if attempt + 1 < policy.maxAttempts {
                    let delaySeconds = policy.baseDelaySeconds
                        * pow(policy.backoffMultiplier, Double(attempt))
                    let delayNanoseconds = UInt64(max(0, delaySeconds) * 1_000_000_000)
                    try await policy.sleep(delayNanoseconds)
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    static func isTransientDownloadError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost,
             .timedOut,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    static func extractResumeData(from error: URLError) -> Data? {
        error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }

    func downloadSnapshot(modelID: String, revision: String, to snapshot: URL) async throws {
        let siblings = try await modelSiblings(modelID: modelID, revision: revision)
        guard !siblings.isEmpty else {
            throw AutotuneRecommendError.invalidArtifact("empty HuggingFace snapshot \(modelID)@\(revision)")
        }
        let staging = snapshot.deletingLastPathComponent()
            .appendingPathComponent(".download-\(revision)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for sibling in siblings {
                try validateRelativeHFPath(sibling.rfilename)
                let destination = staging.appendingPathComponent(sibling.rfilename, isDirectory: false)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                var request = URLRequest(url: resolveURL(modelID: modelID, revision: revision, filename: sibling.rfilename))
                addTokenHeader(&request)
                let (temporary, response) = try await download(request)
                guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                    throw AutotuneRecommendError.invalidArtifact("download failed \(sibling.rfilename)")
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                _ = chmod(destination.path, 0o600)
            }
            try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: snapshot)
            try FileManager.default.moveItem(at: staging, to: snapshot)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func modelSiblings(modelID: String, revision: String) async throws -> [Sibling] {
        var request = URLRequest(url: apiURL(modelID: modelID, revision: revision))
        addTokenHeader(&request)
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AutotuneRecommendError.invalidArtifact("HuggingFace API failed \(modelID)@\(revision)")
        }
        return try JSONDecoder.autotune.decode(ModelInfo.self, from: data).siblings
    }

    private func apiURL(modelID: String, revision: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(modelID)/revision/\(revision)"
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        return components.url!
    }

    private func resolveURL(modelID: String, revision: String, filename: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(modelID)/resolve/\(revision)/\(filename)"
        return components.url!
    }

    private func addTokenHeader(_ request: inout URLRequest) {
        guard let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func validateRelativeHFPath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..")
        else {
            throw AutotuneRecommendError.invalidArtifact("unsafe HuggingFace path \(path)")
        }
    }
}

final class HFAssetRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let newURL = request.url,
              originalURL.scheme == "https",
              newURL.scheme == "https",
              let originalHost = originalURL.host,
              let newHost = newURL.host
        else {
            completionHandler(nil)
            return
        }
        if originalHost == newHost {
            completionHandler(request)
            return
        }
        guard originalHost == "huggingface.co", Self.allowedAssetHost(newHost) else {
            completionHandler(nil)
            return
        }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(stripped)
    }

    private static func allowedAssetHost(_ host: String) -> Bool {
        host == "cdn-lfs.huggingface.co"
            || host == "cas-bridge.xethub.hf.co"
            || host == "transfer.xethub.hf.co"
            || host.hasSuffix(".aws.cdn.hf.co")
    }
}

struct CachedModelArtifactResolver {
    var hubRoot: URL = defaultHubRoot
    var downloader: HuggingFaceSnapshotDownloader = HuggingFaceSnapshotDownloader()

    static var defaultHubRoot: URL {
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome).appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    func verifiedArtifact(for row: CandidateCatalog.Row) async throws -> VerifiedModelArtifact {
        guard let revision = row.modelRevision, let expected = row.modelSHA256 else {
            throw AutotuneRecommendError.invalidArtifact("missing revision/hash")
        }
        let snapshot = snapshotURL(modelID: row.modelID, revision: revision)
        var st = stat()
        if lstat(snapshot.path, &st) != 0 || (st.st_mode & S_IFMT) != S_IFDIR {
            try await downloader.downloadSnapshot(modelID: row.modelID, revision: revision, to: snapshot)
        }
        let actual = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        guard actual == expected else {
            throw AutotuneRecommendError.invalidArtifact("hash mismatch \(row.modelID)@\(revision)")
        }
        return VerifiedModelArtifact(modelArgument: snapshot.path, sha256: actual)
    }

    func verifiedExistingArtifact(for row: CandidateCatalog.Row) throws -> VerifiedModelArtifact {
        guard let revision = row.modelRevision, let expected = row.modelSHA256 else {
            throw AutotuneRecommendError.invalidArtifact("missing revision/hash")
        }
        let snapshot = snapshotURL(modelID: row.modelID, revision: revision)
        var st = stat()
        guard lstat(snapshot.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR
        else {
            throw AutotuneRecommendError.invalidArtifact("missing pinned snapshot \(row.modelID)@\(revision)")
        }
        let actual = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        guard actual == expected else {
            throw AutotuneRecommendError.invalidArtifact("hash mismatch \(row.modelID)@\(revision)")
        }
        return VerifiedModelArtifact(modelArgument: snapshot.path, sha256: actual)
    }

    func snapshotURL(modelID: String, revision: String) -> URL {
        let repoDirectory = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        return hubRoot
            .appendingPathComponent(repoDirectory, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }
}

/// Outcome of running Stage 1 probes across every eligible candidate row.
///
/// `benchmarks` contains only feasible probes (rows admitted into eligibility);
/// `diagnostics` contains a modelKey -> reason string for every candidate that
/// returned .infeasible OR was skipped by runtime-status/RAM/tier gates. This is
/// what the SPEC-023 caller emits to stderr + persists into
/// last-recommendation.json so the user can see WHY no eligible paid model was
/// found. Prior to v1.7.5 the .infeasible(reason:nErr:) string was silently
/// dropped, leaving users with `benchmark_id: null` and no root-cause path.
struct BenchmarkOutcomes: Equatable {
    var benchmarks: [String: CandidateBenchmark]
    /// Ordered modelKey -> single-line diagnostic reason. Deterministic key
    /// ordering (see `benchmarks(request:...)` iteration) so persisted JSON is
    /// byte-stable across runs with identical inputs.
    var diagnostics: [String: String]
}

struct AutotuneRecommendationBenchmarker {
    var artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver()
    var runnerFactory: () throws -> CandidateProviderRunner = { try CandidateProviderRunner() }
    var prober: any Stage1Probing = Stage1Prober()
    var safetySampler: ProbeSafetySampling = SystemProbeSafetySampler()
    var clock: () -> Date = Date.init

    func benchmarks(
        request: AutotuneRecommendRequest,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int,
        port: Int
    ) async throws -> BenchmarkOutcomes {
        var results: [String: CandidateBenchmark] = [:]
        var diagnostics: [String: String] = [:]
        for modelKey in request.candidateCatalog.rows.keys.sorted() {
            guard let row = request.candidateCatalog.rows[modelKey] else {
                continue
            }
            if row.runtimeStatus == "blocked" {
                diagnostics[modelKey] = "catalog row blocked by upstream"
                continue
            }
            if row.minRAMGB > request.hardware.memoryGB - AutotuneRecommendEngine.safetyMarginGB {
                diagnostics[modelKey] = "min_ram \(row.minRAMGB)GB exceeds \(request.hardware.memoryGB)GB - \(AutotuneRecommendEngine.safetyMarginGB)GB safety margin"
                continue
            }
            if !request.hardware.bandwidthTier.satisfies(minimum: row.minBandwidthTier) {
                diagnostics[modelKey] = "bandwidth tier \(request.hardware.bandwidthTier.rawValue) below minimum \(row.minBandwidthTier.rawValue)"
                continue
            }
            do {
                let artifact = try await artifactResolver.verifiedArtifact(for: row)
                let runner = try runnerFactory()
                let before = safetySampler.sample()
                let probe = try await prober.probe(
                    model: artifact.modelArgument,
                    port: port,
                    runner: runner,
                    targetContext: targetContext,
                    gateTTFTMS: gateTTFTMS,
                    replicates: replicates
                )
                let after = safetySampler.sample()
                let safety = ProbeSafetyAssessment.assess(before: before, after: after)
                switch probe {
                case .feasible(let medianTPS, let p95TTFTMS):
                    let generatedAt = clock()
                    results[modelKey] = CandidateBenchmark(
                        modelKey: modelKey,
                        sustainedTPS: medianTPS,
                        ttftMS: Int(p95TTFTMS.rounded(.up)),
                        swapDetected: safety.swapDetected,
                        thermalThrottleDetected: safety.thermalThrottleDetected,
                        artifactSHA256: artifact.sha256,
                        modelArtifactPath: artifact.modelArgument,
                        benchmarkID: "spec-023-\(modelKey)-\(Int(generatedAt.timeIntervalSince1970))",
                        generatedAt: generatedAt,
                        candidateCatalogSHA256: request.candidateCatalogSHA256,
                        binaryVersion: request.hardware.binaryVersion,
                        modelID: row.modelID,
                        hardwareIdentityHash: request.hardware.hardwareIdentityHash
                    )
                    if safety.swapDetected || safety.thermalThrottleDetected {
                        var flags: [String] = []
                        if safety.swapDetected { flags.append("swap detected") }
                        if safety.thermalThrottleDetected { flags.append("thermal throttle detected") }
                        diagnostics[modelKey] = "feasible but " + flags.joined(separator: ", ")
                    }
                case .infeasible(let reason, let nErr):
                    diagnostics[modelKey] = "\(reason) (n_err=\(nErr))"
                }
            } catch {
                throw error
            }
        }
        return BenchmarkOutcomes(benchmarks: results, diagnostics: diagnostics)
    }
}

enum ModelArtifactVerifier {
    static func canonicalArtifactHash(directory: URL) throws -> String {
        let fm = FileManager.default
        var root = stat()
        guard lstat(directory.path, &root) == 0,
              (root.st_mode & S_IFMT) == S_IFDIR
        else {
            throw AutotuneRecommendError.invalidArtifact("root is not a directory")
        }
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []) else {
            throw AutotuneRecommendError.invalidArtifact("cannot enumerate")
        }
        let basePath = directory.resolvingSymlinksInPath().path
        var entries: [(path: String, size: UInt64, sha: String)] = []
        for case let url as URL in enumerator {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(basePath + "/") else {
                throw AutotuneRecommendError.invalidArtifact("path escape \(url.lastPathComponent)")
            }
            let rel = String(path.dropFirst(basePath.count + 1))
            guard !rel.hasPrefix("/"), !rel.split(separator: "/").contains("..") else {
                throw AutotuneRecommendError.invalidArtifact("unsafe path \(rel)")
            }
            var statbuf = stat()
            guard lstat(url.path, &statbuf) == 0 else {
                throw AutotuneRecommendError.invalidArtifact("lstat \(rel)")
            }
            if (statbuf.st_mode & S_IFMT) == S_IFLNK {
                throw AutotuneRecommendError.invalidArtifact("symlink \(rel)")
            }
            if (statbuf.st_mode & S_IFMT) == S_IFDIR {
                continue
            }
            guard (statbuf.st_mode & S_IFMT) == S_IFREG else {
                throw AutotuneRecommendError.invalidArtifact("non-regular \(rel)")
            }
            guard statbuf.st_nlink <= 1 else {
                throw AutotuneRecommendError.invalidArtifact("hardlink \(rel)")
            }
            let data = try Data(contentsOf: url)
            entries.append((rel, UInt64(data.count), Data(SHA256.hash(data: data)).hexLower))
        }
        let manifest = entries.sorted { $0.path < $1.path }
            .map { "\($0.path)\n\($0.size)\n\($0.sha)\n" }
            .joined()
        return Data(SHA256.hash(data: Data(manifest.utf8))).hexLower
    }
}

extension ISO8601DateFormatter {
    static var autotuneInternet: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }
}

private extension JSONDecoder {
    static let autotune: JSONDecoder = JSONDecoder()
}

private extension Data {
    var hexLower: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Double {
    var rounded6: Double {
        (self * 1_000_000).rounded() / 1_000_000
    }

    var jsonNumber: String {
        if isFinite {
            return String(format: "%.6f", self).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
        return "0"
    }
}

private extension String {
    var jsonEscaped: String {
        let data = try! JSONSerialization.data(withJSONObject: [self], options: [])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    func prefixString(_ count: Int) -> String {
        String(prefix(count))
    }
}

extension AutotuneStaticInputs {
    // baked-2026-07-03: v3 keypair rotation + M-Base-realistic
    // `min_sustained_tps` gates. Live signed feed at
    // coordinator.streamvc.live/static/autotune-candidates.json is
    // signed with the v3 private key (held off-repo by the operator;
    // only the PUBLIC key ships here and above). When runtime signature
    // verification fails (older signing infra, network partition, etc.)
    // the client falls back to this baked catalog.
    //
    // Baked is INTENTIONALLY not a byte-for-byte mirror of live. Two
    // deliberate drifts:
    //   1. Baked keeps `runtime_status="listed"` rows (qwen3-32b,
    //      qwen2.5-coder-32b) and `runtime_status="blocked"` rows
    //      (google-gemma, nvidia-nemotron) that the live feed omits.
    //      Baked serves as an offline / cold-start fallback superset;
    //      recommendable-only-in-live catalogs need the extra rows for
    //      correct "listed but not currently sold" and "blocked at
    //      client" semantics.
    //   2. Baked qwen3-32b keeps `min_sustained_tps=30` (M-Max floor)
    //      vs live's `15` (recommendable to M-Pro 48GB). Offline
    //      recommendation on a compiled-in fallback stays conservative.
    // The 4 rows we lowered for M-Base UX (qwen3-coder-30b-a3b,
    // openai/gpt-oss-20b, meta-llama/llama-3.1-8b, qwen2.5-coder-32b)
    // ARE mirrored in baked so fallback still unblocks M-Base.
    static let bakedDemandRankJSON = """
    {"version":"baked-2026-07-03","generated_at":"2026-07-03T00:00:00Z","source":"openrouter_completion_token_rank_operator_curated","cold_start_floor":0.15,"diversification_band":0.85,"rows":{"meta-llama/llama-3.1-8b-instruct":{"demand_weight":0.45,"rank":3,"recommendable":true,"min_provider_target":20},"openai/gpt-oss-20b":{"demand_weight":0.60,"rank":2,"recommendable":true,"min_provider_target":20},"qwen3-32b":{"demand_weight":0.35,"rank":8,"recommendable":false,"min_provider_target":10},"qwen3-coder-30b-a3b-instruct":{"demand_weight":0.80,"rank":1,"recommendable":true,"min_provider_target":20},"qwen2.5-coder-32b-instruct":{"demand_weight":0.40,"rank":7,"recommendable":false,"min_provider_target":10},"google-gemma-4-26b-a4b-it":{"demand_weight":0.20,"rank":null,"recommendable":false,"min_provider_target":0},"nvidia/nemotron-3-nano-30b-a3b":{"demand_weight":0.20,"rank":null,"recommendable":false,"min_provider_target":0}}}
    """

    static let bakedCandidateCatalogJSON = """
    {"version":"baked-2026-07-03","generated_at":"2026-07-03T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","rows":{"meta-llama/llama-3.1-8b-instruct":{"model_id":"mlx-community/Meta-Llama-3.1-8B-Instruct-4bit","model_revision":"241a666dad6cb93c8ff213d39a7f34a36bf26db4","model_sha256":"67b26d6b1c50dc8836ab3705b06276a43c74c8f66247f9b112e232b58abbd99f","min_ram_gb":16,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable","notes":"baked-2026-07-03: min_sustained_tps 20->15 for M-Base-lite eligibility."},"openai/gpt-oss-20b":{"model_id":"mlx-community/gpt-oss-20b-MXFP4-Q8","model_revision":"773a7da77e569019bb0fd17a554b263738d669a3","model_sha256":"f25592861e0b7f4eb8489d9103214f3f0dc4f798bb0e4e0cd817ff2f4191f1b1","min_ram_gb":24,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable","notes":"baked-2026-07-03: min_sustained_tps 30->15 to reflect M-Base cold-start (~16.7 tok/s measured on M5)."},"qwen3-32b":{"model_id":"mlx-community/Qwen3-32B-4bit","model_revision":"bcaaf7f538adf166c1080a2befdb4f6019f66639","model_sha256":"69169cceb643f108755f96dba26d8647862e38a7f82cb1b5b25aff8f204967aa","min_ram_gb":32,"min_bandwidth_tier":"A","bench_gate":{"min_sustained_tps":30,"max_4k_ttft_ms":3000},"runtime_status":"listed","notes":"baked"},"qwen3-coder-30b-a3b-instruct":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","model_revision":"6e302ea604ad9ab206367e2c501d1571023e7b6d","model_sha256":"10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0","min_ram_gb":28,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3000},"runtime_status":"recommendable","notes":"baked-2026-07-03: min_sustained_tps 25->20 for M5 cold-start (~23.4 tok/s measured) headroom."},"qwen2.5-coder-32b-instruct":{"model_id":"mlx-community/Qwen2.5-Coder-32B-Instruct-4bit","model_revision":"d1e3b690c8e225d7795bccddf971ca6be68b2012","model_sha256":"b7749cc57f37f7e9239d0f9b091bcffe6d7629e48af75e8cb84c1cdca1780973","min_ram_gb":64,"min_bandwidth_tier":"A","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3500},"runtime_status":"listed","notes":"baked-2026-07-03: min_sustained_tps 30->20 to broaden eligibility."},"google-gemma-4-26b-a4b-it":{"model_id":"mlx-community/gemma-4-26b-a4b-it-4bit","min_ram_gb":32,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":30,"max_4k_ttft_ms":3000},"runtime_status":"blocked","notes":"baked"},"nvidia/nemotron-3-nano-30b-a3b":{"model_id":"mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit","min_ram_gb":32,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":30,"max_4k_ttft_ms":3000},"runtime_status":"blocked","notes":"baked"}}}
    """

    static let bakedRateCardJSON = """
    {"version":"baked-2026-07-03","generated_at":"2026-07-03T00:00:00Z","usd_per_million_credits":1.0,"rows":{"default":{"prompt_rate_per_mtok":500000,"completion_rate_per_mtok":1000000,"provider_share_bps":9000,"global_multiplier_ppm":1000000},"qwen3-32b":{"prompt_rate_per_mtok":110000,"completion_rate_per_mtok":220000,"provider_share_bps":9000,"global_multiplier_ppm":1000000},"openai/gpt-oss-20b":{"prompt_rate_per_mtok":50000,"completion_rate_per_mtok":100000,"provider_share_bps":9000,"global_multiplier_ppm":1000000},"qwen3-coder-30b-a3b-instruct":{"prompt_rate_per_mtok":117500,"completion_rate_per_mtok":235000,"provider_share_bps":9000,"global_multiplier_ppm":1000000},"meta-llama/llama-3.1-8b-instruct":{"prompt_rate_per_mtok":13500,"completion_rate_per_mtok":27000,"provider_share_bps":9000,"global_multiplier_ppm":1000000},"qwen2.5-coder-32b-instruct":{"prompt_rate_per_mtok":425000,"completion_rate_per_mtok":850000,"provider_share_bps":9000,"global_multiplier_ppm":1000000}}}
    """
}
