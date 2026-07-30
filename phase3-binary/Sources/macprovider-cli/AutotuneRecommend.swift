import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import Security

enum AutotuneRecommendError: Error, Equatable, CustomStringConvertible {
    case invalidStaticJSON(String)
    case invalidRateCard(String)
    case invalidArtifact(String)
    case candidateProbeFailed(modelKey: String, reason: String)
    case noHMACSecret

    var description: String {
        switch self {
        case .invalidStaticJSON(let message):
            return "invalid static JSON: \(message)"
        case .invalidRateCard(let message):
            return "invalid rate card: \(message)"
        case .invalidArtifact(let message):
            return "invalid model artifact: \(message)"
        case .candidateProbeFailed(let modelKey, let reason):
            return "candidate probe failed for \(modelKey): \(reason)"
        case .noHMACSecret:
            return "HMAC secret unavailable"
        }
    }
}

enum AutotuneRecommendWarning: String, CaseIterable {
    case candidateCatalogFallbackUsed = "candidate_catalog_fallback_used"
    case candidateCatalogIntegrityFailure = "candidate_catalog_integrity_failure"
    case candidateCatalogUpdateRequired = "candidate_catalog_update_required"
    case candidateCatalogStale = "candidate_catalog_stale"
    case demandRankFallbackUsed = "demand_rank_fallback_used"
    case demandRankIntegrityFailure = "demand_rank_integrity_failure"
    case demandRankUpdateRequired = "demand_rank_update_required"
    case demandRankStale = "demand_rank_stale"
    case hardwareTierUnknown = "hardware_tier_unknown"
    case rateCardFallbackUsed = "rate_card_fallback_used"
    case rateCardIntegrityFailure = "rate_card_integrity_failure"
    case rateCardUpdateRequired = "rate_card_update_required"
    case rateCardStale = "rate_card_stale"
    case noEligibleModel = "no_eligible_model"
    /// v1.7.6 Track A1: at least one recommended candidate had no
    /// specific rate-card row and is being priced against the coord's
    /// "default" fallback tier. Coord's `RateFor` already falls through
    /// to this row for served inference, so credits still flow — the
    /// warning surfaces the discovery-tier pricing to the operator.
    case rateCardDefaultTierUsed = "rate_card_default_tier_used"
    /// Observed swap pageouts during the Stage 1 probe. Paid recommendations
    /// treat this as a hard eligibility veto (#742 / SPEC-023 v0.7); the warning
    /// still surfaces so donor-mode transcripts can name the reason.
    case swapObservedUnderLoad = "swap_observed_under_load"
    /// Advisory QoS warning when measured TPS misses the signed catalog target.
    case tpsBelowGate = "tps_below_gate"
    /// Advisory QoS warning when measured TTFT exceeds the signed catalog target.
    case ttftAboveGate = "ttft_above_gate"
    /// Paid-path veto when measured TTFT exceeds the buyer-facing operator ceiling.
    case buyerTTFTCeilingExceeded = "buyer_ttft_ceiling_exceeded"
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

extension AutotuneRecommendHardware {
    var recommendedMaxBatch: Int {
        let normalizedChip = chip.lowercased()
        if normalizedChip.contains("ultra") {
            if memoryGB >= 128 {
                return 4
            }
            if memoryGB >= 96 {
                return 3
            }
            return 1
        }
        if normalizedChip.contains("max"), memoryGB >= 48 {
            return 2
        }
        return 1
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
        var readyProviderCount: Int?
        var supplyDeficitMultiplier: Double?
        var minDwellHours: Int?

        enum CodingKeys: String, CodingKey {
            case demandWeight = "demand_weight"
            case rank
            case recommendable
            case minProviderTarget = "min_provider_target"
            case readyProviderCount = "ready_provider_count"
            case supplyDeficitMultiplier = "supply_deficit_multiplier"
            case minDwellHours = "min_dwell_hours"
        }

        var effectiveSupplyDeficitMultiplier: Double {
            if let supplyDeficitMultiplier {
                return min(2.0, max(0.5, supplyDeficitMultiplier))
            }
            guard let readyProviderCount, minProviderTarget > 0 else {
                return 1.0
            }
            let ratio = Double(minProviderTarget) / Double(max(readyProviderCount, 1))
            return min(2.0, max(0.5, ratio))
        }
    }

    var version: String
    var generatedAt: Date
    var source: String
    var policyVersion: String
    var coldStartFloor: Double
    var diversificationBand: Double
    var rows: [String: Row]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case source
        case policyVersion = "policy_version"
        case coldStartFloor = "cold_start_floor"
        case diversificationBand = "diversification_band"
        case rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        source = try c.decode(String.self, forKey: .source)
        policyVersion = try c.decodeIfPresent(String.self, forKey: .policyVersion) ?? "legacy-spec-023"
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
        guard ["openrouter_completion_token_rank_operator_curated", "macprovider_buyer_supply_deficit_v1"].contains(source) else {
            throw AutotuneRecommendError.invalidStaticJSON("demand-rank source")
        }
        guard policyVersion == "autotune-policy-v1" else {
            throw AutotuneRecommendError.invalidStaticJSON("demand-rank policy_version")
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
            if let ready = row.readyProviderCount, ready < 0 {
                throw AutotuneRecommendError.invalidStaticJSON("ready_provider_count for \(key)")
            }
            if let multiplier = row.supplyDeficitMultiplier,
               !multiplier.isFinite || !(0.5 ... 2.0).contains(multiplier) {
                throw AutotuneRecommendError.invalidStaticJSON("supply_deficit_multiplier for \(key)")
            }
            if let dwell = row.minDwellHours, !(0 ... 720).contains(dwell) {
                throw AutotuneRecommendError.invalidStaticJSON("min_dwell_hours for \(key)")
            }
        }
        return self
    }
}

struct CandidateCatalog: Decodable, Equatable {
    struct BenchGate: Decodable, Equatable {
        struct Provenance: Decodable, Equatable {
            var source: String
            var hardware: String?
            var measuredAt: String?
            var notes: String?

            init(source: String, hardware: String? = nil, measuredAt: String? = nil, notes: String? = nil) {
                self.source = source
                self.hardware = hardware
                self.measuredAt = measuredAt
                self.notes = notes
            }

            enum CodingKeys: String, CodingKey {
                case source
                case hardware
                case measuredAt = "measured_at"
                case notes
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                source = try c.decode(String.self, forKey: .source)
                hardware = try Self.decodeOptionalNonNullString(c, forKey: .hardware)
                measuredAt = try Self.decodeOptionalNonNullString(c, forKey: .measuredAt)
                notes = try Self.decodeOptionalNonNullString(c, forKey: .notes)
            }

            private static func decodeOptionalNonNullString(
                _ container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) throws -> String? {
                guard container.contains(key) else { return nil }
                return try container.decode(String.self, forKey: key)
            }
        }

        var minSustainedTPS: Double
        var max4KTTFTMS: Int
        var provenance: Provenance

        init(
            minSustainedTPS: Double,
            max4KTTFTMS: Int,
            provenance: Provenance = Provenance(source: "legacy_unverified")
        ) {
            self.minSustainedTPS = minSustainedTPS
            self.max4KTTFTMS = max4KTTFTMS
            self.provenance = provenance
        }

        enum CodingKeys: String, CodingKey {
            case minSustainedTPS = "min_sustained_tps"
            case max4KTTFTMS = "max_4k_ttft_ms"
            case provenance
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            minSustainedTPS = try c.decode(Double.self, forKey: .minSustainedTPS)
            max4KTTFTMS = try c.decode(Int.self, forKey: .max4KTTFTMS)
            provenance = try c.decode(Provenance.self, forKey: .provenance)
        }
    }

    struct WorkloadRecommended: Decodable, Equatable {
        var kvBits: Int
        var maxContextOverride: Int
        var maxConcurrencyOverride: Int
        var draftModel: String?
        var draftModelArtifactSHA256: String?
        var numDraftTokens: Int?

        enum CodingKeys: String, CodingKey {
            case kvBits = "kv_bits"
            case maxContextOverride = "max_context_override"
            case maxConcurrencyOverride = "max_concurrency_override"
            case draftModel = "draft_model"
            case draftModelArtifactSHA256 = "draft_model_artifact_sha256"
            case numDraftTokens = "num_draft_tokens"
        }
    }

    struct WorkloadGatePolicy: Decodable, Equatable {
        var minSamples: Int
        var maxP95TTFTMS: Int
        var maxStopTokenLeakRate: Double
        var minMedianTPS: Double?

        enum CodingKeys: String, CodingKey {
            case minSamples = "min_samples"
            case maxP95TTFTMS = "max_p95_ttft_ms"
            case maxStopTokenLeakRate = "max_stop_token_leak_rate"
            case minMedianTPS = "min_median_tps"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            for key in [CodingKeys.minSamples, .maxP95TTFTMS, .maxStopTokenLeakRate, .minMedianTPS] {
                guard c.contains(key) else {
                    throw AutotuneRecommendError.invalidStaticJSON("workload gate_policy \(key.stringValue)")
                }
            }
            minSamples = try c.decode(Int.self, forKey: .minSamples)
            maxP95TTFTMS = try c.decode(Int.self, forKey: .maxP95TTFTMS)
            maxStopTokenLeakRate = try c.decode(Double.self, forKey: .maxStopTokenLeakRate)
            minMedianTPS = try c.decodeIfPresent(Double.self, forKey: .minMedianTPS)
        }
    }

    struct WorkloadProfileMetrics: Decodable, Equatable {
        var medianTPS: Double?
        var p95TTFTMS: Double?
        var stopTokenLeakRate: Double?
        var specDecodeAcceptanceRate: Double?
        var sampleCount: Int

        enum CodingKeys: String, CodingKey {
            case medianTPS = "median_tps"
            case p95TTFTMS = "p95_ttft_ms"
            case stopTokenLeakRate = "stop_token_leak_rate"
            case specDecodeAcceptanceRate = "spec_decode_acceptance_rate"
            case sampleCount = "sample_count"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            for key in [CodingKeys.medianTPS, .p95TTFTMS, .stopTokenLeakRate, .specDecodeAcceptanceRate, .sampleCount] {
                guard c.contains(key) else {
                    throw AutotuneRecommendError.invalidStaticJSON("workload profile metric \(key.stringValue)")
                }
            }
            medianTPS = try c.decodeIfPresent(Double.self, forKey: .medianTPS)
            p95TTFTMS = try c.decodeIfPresent(Double.self, forKey: .p95TTFTMS)
            stopTokenLeakRate = try c.decodeIfPresent(Double.self, forKey: .stopTokenLeakRate)
            specDecodeAcceptanceRate = try c.decodeIfPresent(Double.self, forKey: .specDecodeAcceptanceRate)
            sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        }
    }

    struct WorkloadProfile: Decodable, Equatable {
        var status: String?
        var noWinnerReason: String?
        var recommended: WorkloadRecommended?
        var gatePolicy: WorkloadGatePolicy
        var profileMetrics: WorkloadProfileMetrics
        var source: String
        var candidateSource: String?

        enum CodingKeys: String, CodingKey {
            case status
            case noWinnerReason = "no_winner_reason"
            case recommended
            case gatePolicy = "gate_policy"
            case profileMetrics = "profile_metrics"
            case source
            case candidateSource = "candidate_source"
        }
    }

    struct DraftCandidate: Decodable, Equatable {
        var draftModel: String
        var draftModelArtifactSHA256: String

        enum CodingKeys: String, CodingKey {
            case draftModel = "draft_model"
            case draftModelArtifactSHA256 = "draft_model_artifact_sha256"
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
        var draftCandidates: [DraftCandidate]?
        var workloadProfiles: [String: [String: WorkloadProfile]]?

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case modelRevision = "model_revision"
            case modelSHA256 = "model_sha256"
            case minRAMGB = "min_ram_gb"
            case minBandwidthTier = "min_bandwidth_tier"
            case benchGate = "bench_gate"
            case runtimeStatus = "runtime_status"
            case notes
            case draftCandidates = "draft_candidates"
            case workloadProfiles = "workload_profiles"
            case perClass = "per_class"
        }

        init(
            modelID: String,
            modelRevision: String?,
            modelSHA256: String?,
            minRAMGB: Int,
            minBandwidthTier: BandwidthTier,
            benchGate: BenchGate,
            runtimeStatus: String,
            notes: String?,
            draftCandidates: [DraftCandidate]? = nil,
            workloadProfiles: [String: [String: WorkloadProfile]]? = nil
        ) {
            self.modelID = modelID
            self.modelRevision = modelRevision
            self.modelSHA256 = modelSHA256
            self.minRAMGB = minRAMGB
            self.minBandwidthTier = minBandwidthTier
            self.benchGate = benchGate
            self.runtimeStatus = runtimeStatus
            self.notes = notes
            self.draftCandidates = draftCandidates
            self.workloadProfiles = workloadProfiles
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.perClass) {
                throw AutotuneRecommendError.invalidStaticJSON("per_class alias is forbidden")
            }
            modelID = try c.decode(String.self, forKey: .modelID)
            modelRevision = try c.decodeIfPresent(String.self, forKey: .modelRevision)
            modelSHA256 = try c.decodeIfPresent(String.self, forKey: .modelSHA256)
            minRAMGB = try c.decode(Int.self, forKey: .minRAMGB)
            minBandwidthTier = try c.decode(BandwidthTier.self, forKey: .minBandwidthTier)
            benchGate = try c.decode(BenchGate.self, forKey: .benchGate)
            runtimeStatus = try c.decode(String.self, forKey: .runtimeStatus)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
            draftCandidates = try c.decodeIfPresent([DraftCandidate].self, forKey: .draftCandidates)
            workloadProfiles = try c.decodeIfPresent([String: [String: WorkloadProfile]].self, forKey: .workloadProfiles)
        }
    }

    var version: String
    var generatedAt: Date
    var source: String
    var policyVersion: String
    var rows: [String: Row]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case source
        case policyVersion = "policy_version"
        case rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        source = try c.decode(String.self, forKey: .source)
        policyVersion = try c.decodeIfPresent(String.self, forKey: .policyVersion) ?? "legacy-spec-023"
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
        guard policyVersion == "autotune-policy-v1" else {
            throw AutotuneRecommendError.invalidStaticJSON("candidate catalog policy_version")
        }
        let allowedStatuses = Set(["candidate", "listed", "recommendable", "blocked"])
        let catalog = self
        for (key, originalRow) in catalog.rows {
            let row = originalRow
            guard allowedStatuses.contains(row.runtimeStatus) else {
                throw AutotuneRecommendError.invalidStaticJSON("runtime_status for \(key)")
            }
            guard row.minRAMGB >= 0,
                  row.benchGate.minSustainedTPS >= 0,
                  row.benchGate.minSustainedTPS.isFinite,
                  row.benchGate.max4KTTFTMS >= 0,
                  Self.allowedBenchGateProvenanceSources.contains(row.benchGate.provenance.source),
                  !row.benchGate.provenance.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.nonEmptyIfPresent(row.benchGate.provenance.hardware),
                  Self.nonEmptyIfPresent(row.benchGate.provenance.measuredAt),
                  Self.nonEmptyIfPresent(row.benchGate.provenance.notes)
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
            try Self.validateWorkloadProfiles(row.workloadProfiles, rowKey: key, draftCandidates: row.draftCandidates)
        }
        return catalog
    }

    static let allowedBenchGateProvenanceSources = Set([
        "measured_single_host",
        "runtime_validated_only",
        "policy",
        "no_throughput_bench",
        "never_benched",
        "legacy_unverified",
    ])

    static func nonEmptyIfPresent(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func rowIdentity(for key: String) -> String? {
        guard let row = rows[key] else { return nil }
        var fields = [
            policyVersion,
            key,
            row.modelID,
            row.modelRevision ?? "",
            row.modelSHA256 ?? "",
            String(row.minRAMGB),
            row.minBandwidthTier.rawValue,
            String(format: "%.6f", row.benchGate.minSustainedTPS),
            String(row.benchGate.max4KTTFTMS),
            row.runtimeStatus,
        ]
        let policyDigest: String?
        do {
            policyDigest = try Self.policyDigest(for: row)
        } catch {
            return nil
        }
        if let policyDigest {
            fields.append("policy:\(policyDigest)")
        }
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return Data(SHA256.hash(data: Data(framed.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    /// Bind cached benchmark evidence to runtime-selection policy while
    /// retaining historical identities for rows that predate these fields.
    /// The coordinator computes the same digest over RFC 8785 canonical JSON.
    private static func policyDigest(for row: Row) throws -> String? {
        var policy: [String: RFC8785JCS.Value] = [:]
        if let draftCandidates = row.draftCandidates {
            policy["draft_candidates"] = .array(draftCandidates.map { candidate in
                .object([
                    "draft_model": .string(candidate.draftModel),
                    "draft_model_artifact_sha256": .string(candidate.draftModelArtifactSHA256),
                ])
            })
        }
        if let workloadProfiles = row.workloadProfiles {
            policy["workload_profiles"] = .object(workloadProfiles.mapValues { tiers in
                .object(tiers.mapValues(workloadProfileCanonicalValue))
            })
        }
        guard !policy.isEmpty else { return nil }
        return try RFC8785JCS.sha256Hex(of: .object(policy))
    }

    private static func workloadProfileCanonicalValue(_ profile: WorkloadProfile) -> RFC8785JCS.Value {
        var value: [String: RFC8785JCS.Value] = [
            "gate_policy": .object([
                "min_samples": .int(profile.gatePolicy.minSamples),
                "max_p95_ttft_ms": .int(profile.gatePolicy.maxP95TTFTMS),
                "max_stop_token_leak_rate": .double(profile.gatePolicy.maxStopTokenLeakRate),
                "min_median_tps": profile.gatePolicy.minMedianTPS.map(RFC8785JCS.Value.double) ?? .null,
            ]),
            "profile_metrics": .object([
                "median_tps": profile.profileMetrics.medianTPS.map(RFC8785JCS.Value.double) ?? .null,
                "p95_ttft_ms": profile.profileMetrics.p95TTFTMS.map(RFC8785JCS.Value.double) ?? .null,
                "stop_token_leak_rate": profile.profileMetrics.stopTokenLeakRate.map(RFC8785JCS.Value.double) ?? .null,
                "spec_decode_acceptance_rate": profile.profileMetrics.specDecodeAcceptanceRate.map(RFC8785JCS.Value.double) ?? .null,
                "sample_count": .int(profile.profileMetrics.sampleCount),
            ]),
            "source": .string(profile.source),
        ]
        if let status = profile.status { value["status"] = .string(status) }
        if let reason = profile.noWinnerReason { value["no_winner_reason"] = .string(reason) }
        if let source = profile.candidateSource { value["candidate_source"] = .string(source) }
        if let recommended = profile.recommended {
            var recommendation: [String: RFC8785JCS.Value] = [
                "kv_bits": .int(recommended.kvBits),
                "max_context_override": .int(recommended.maxContextOverride),
                "max_concurrency_override": .int(recommended.maxConcurrencyOverride),
            ]
            if let model = recommended.draftModel { recommendation["draft_model"] = .string(model) }
            if let digest = recommended.draftModelArtifactSHA256 {
                recommendation["draft_model_artifact_sha256"] = .string(digest)
            }
            if let count = recommended.numDraftTokens { recommendation["num_draft_tokens"] = .int(count) }
            value["recommended"] = .object(recommendation)
        }
        return .object(value)
    }

    private static func validateWorkloadProfiles(
        _ workloadProfiles: [String: [String: WorkloadProfile]]?,
        rowKey: String,
        draftCandidates: [DraftCandidate]?
    ) throws {
        guard let workloadProfiles else { return }
        let allowedWorkloads = Set(["short_chat", "medium_with_system", "long_context", "code_completion", "agent_style"])
        let allowedTiers = Set(["8gb", "16gb", "32gb", "64gb_plus"])
        let allowedNoWinnerReasons = Set(["insufficient_samples", "gate_unmet", "hard_failure", "no_cells_evaluated"])
        let draftContextCaps = ["8gb": 8_192, "16gb": 20_000, "32gb": 50_000, "64gb_plus": 120_000]

        for (workload, tiers) in workloadProfiles {
            guard allowedWorkloads.contains(workload) else {
                throw AutotuneRecommendError.invalidStaticJSON("workload_profiles workload for \(rowKey)")
            }
            guard !tiers.isEmpty else {
                throw AutotuneRecommendError.invalidStaticJSON("workload_profiles tiers for \(rowKey)")
            }
            for (tier, profile) in tiers {
                guard allowedTiers.contains(tier) else {
                    throw AutotuneRecommendError.invalidStaticJSON("workload_profiles tier for \(rowKey)")
                }
                try validateWorkloadProfile(
                    profile,
                    workload: workload,
                    tier: tier,
                    rowKey: rowKey,
                    allowedNoWinnerReasons: allowedNoWinnerReasons,
                    draftContextCaps: draftContextCaps,
                    draftCandidates: draftCandidates
                )
            }
        }
    }

    private static func validateWorkloadProfile(
        _ profile: WorkloadProfile,
        workload: String,
        tier: String,
        rowKey: String,
        allowedNoWinnerReasons: Set<String>,
        draftContextCaps: [String: Int],
        draftCandidates: [DraftCandidate]?
    ) throws {
        guard !profile.source.isEmpty else {
            throw AutotuneRecommendError.invalidStaticJSON("workload profile source for \(rowKey)")
        }
        guard let expectedTTFT = spec029DefaultMaxP95TTFTMS[workload],
              profile.gatePolicy.minSamples == 20,
              profile.gatePolicy.maxP95TTFTMS == expectedTTFT,
              profile.gatePolicy.maxStopTokenLeakRate == 0,
              profile.gatePolicy.minMedianTPS == nil
        else {
            throw AutotuneRecommendError.invalidStaticJSON("workload gate_policy for \(rowKey)")
        }
        if let median = profile.profileMetrics.medianTPS, (!median.isFinite || median < 0) {
            throw AutotuneRecommendError.invalidStaticJSON("workload median_tps for \(rowKey)")
        }
        if let ttft = profile.profileMetrics.p95TTFTMS, (!ttft.isFinite || ttft < 0) {
            throw AutotuneRecommendError.invalidStaticJSON("workload p95_ttft_ms for \(rowKey)")
        }
        if let leak = profile.profileMetrics.stopTokenLeakRate, (!leak.isFinite || leak < 0 || leak > 1) {
            throw AutotuneRecommendError.invalidStaticJSON("workload stop_token_leak_rate for \(rowKey)")
        }
        if let acceptance = profile.profileMetrics.specDecodeAcceptanceRate, (!acceptance.isFinite || acceptance < 0 || acceptance > 1) {
            throw AutotuneRecommendError.invalidStaticJSON("workload spec_decode_acceptance_rate for \(rowKey)")
        }
        guard profile.profileMetrics.sampleCount >= 0 else {
            throw AutotuneRecommendError.invalidStaticJSON("workload sample_count for \(rowKey)")
        }

        if profile.status == "no_winner" {
            guard let reason = profile.noWinnerReason, allowedNoWinnerReasons.contains(reason) else {
                throw AutotuneRecommendError.invalidStaticJSON("workload no_winner_reason for \(rowKey)")
            }
            guard profile.recommended == nil,
                  profile.profileMetrics.medianTPS == nil,
                  profile.profileMetrics.p95TTFTMS == nil,
                  profile.profileMetrics.stopTokenLeakRate == nil,
                  profile.profileMetrics.specDecodeAcceptanceRate == nil
            else {
                throw AutotuneRecommendError.invalidStaticJSON("workload no_winner profile_metrics for \(rowKey)")
            }
            switch reason {
            case "no_cells_evaluated", "hard_failure":
                guard profile.profileMetrics.sampleCount == 0 else {
                    throw AutotuneRecommendError.invalidStaticJSON("workload no_winner sample_count for \(rowKey)")
                }
            case "insufficient_samples":
                guard profile.profileMetrics.sampleCount > 0,
                      profile.profileMetrics.sampleCount < profile.gatePolicy.minSamples
                else {
                    throw AutotuneRecommendError.invalidStaticJSON("workload no_winner sample_count for \(rowKey)")
                }
            case "gate_unmet":
                guard profile.profileMetrics.sampleCount >= profile.gatePolicy.minSamples else {
                    throw AutotuneRecommendError.invalidStaticJSON("workload no_winner sample_count for \(rowKey)")
                }
            default:
                throw AutotuneRecommendError.invalidStaticJSON("workload no_winner_reason for \(rowKey)")
            }
            return
        }

        guard profile.status == nil || profile.status == "winner" else {
            throw AutotuneRecommendError.invalidStaticJSON("workload status for \(rowKey)")
        }
        guard profile.noWinnerReason == nil, let recommended = profile.recommended else {
            throw AutotuneRecommendError.invalidStaticJSON("workload winner recommended for \(rowKey)")
        }
        guard recommended.kvBits >= 0,
              recommended.maxContextOverride > 0,
              recommended.maxConcurrencyOverride > 0,
              let p95TTFTMS = profile.profileMetrics.p95TTFTMS,
              p95TTFTMS <= Double(profile.gatePolicy.maxP95TTFTMS),
              let stopTokenLeakRate = profile.profileMetrics.stopTokenLeakRate,
              stopTokenLeakRate <= profile.gatePolicy.maxStopTokenLeakRate,
              profile.profileMetrics.sampleCount >= profile.gatePolicy.minSamples
        else {
            throw AutotuneRecommendError.invalidStaticJSON("workload winner metrics for \(rowKey)")
        }

        let hasAnyDraftField = recommended.draftModel != nil || recommended.draftModelArtifactSHA256 != nil || recommended.numDraftTokens != nil
        guard hasAnyDraftField else { return }
        guard recommended.draftModel != nil,
              let draftSHA = recommended.draftModelArtifactSHA256,
              isHex(draftSHA, count: 64),
              let numDraftTokens = recommended.numDraftTokens,
              (1 ... 16).contains(numDraftTokens),
              recommended.maxConcurrencyOverride <= 1,
              let cap = draftContextCaps[tier],
              recommended.maxContextOverride <= cap,
              let candidateSource = profile.candidateSource,
              isApprovedSpec029DraftSource(candidateSource),
              staticDraftCandidateBindingIsValid(
                  source: candidateSource,
                  recommended: recommended,
                  draftCandidates: draftCandidates
              )
        else {
            throw AutotuneRecommendError.invalidStaticJSON("workload speculative recommended for \(rowKey)")
        }
    }

    private static func staticDraftCandidateBindingIsValid(
        source: String,
        recommended: WorkloadRecommended,
        draftCandidates: [DraftCandidate]?
    ) -> Bool {
        guard source.hasPrefix("static_draft_candidates:") else { return true }
        guard let draftModel = recommended.draftModel,
              let draftSHA = recommended.draftModelArtifactSHA256,
              let draftCandidates
        else {
            return false
        }
        return draftCandidates.contains {
            $0.draftModel == draftModel && $0.draftModelArtifactSHA256 == draftSHA
        }
    }

    private static func isApprovedSpec029DraftSource(_ source: String) -> Bool {
        source.hasPrefix("static_draft_candidates:")
            || source.hasPrefix("research_fixture:")
            || source.hasPrefix("local_operator_override:")
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static let spec029DefaultMaxP95TTFTMS = [
        "short_chat": 8_000,
        "medium_with_system": 12_000,
        "long_context": 60_000,
        "code_completion": 12_000,
        "agent_style": 20_000,
    ]
}

struct RateCardProjection: Decodable, Equatable {
    struct Row: Decodable, Equatable {
        var promptRatePerMtok: Int64
        var promptCacheHitRatePerMtok: Int64
        var completionRatePerMtok: Int64
        var providerShareBPS: Int64
        var globalMultiplierPPM: Int64

        enum CodingKeys: String, CodingKey {
            case promptRatePerMtok = "prompt_rate_per_mtok"
            case promptCacheHitRatePerMtok = "prompt_cache_hit_rate_per_mtok"
            case completionRatePerMtok = "completion_rate_per_mtok"
            case providerShareBPS = "provider_share_bps"
            case globalMultiplierPPM = "global_multiplier_ppm"
        }

        init(
            promptRatePerMtok: Int64,
            promptCacheHitRatePerMtok: Int64? = nil,
            completionRatePerMtok: Int64,
            providerShareBPS: Int64,
            globalMultiplierPPM: Int64
        ) {
            self.promptRatePerMtok = promptRatePerMtok
            self.promptCacheHitRatePerMtok = promptCacheHitRatePerMtok ?? promptRatePerMtok
            self.completionRatePerMtok = completionRatePerMtok
            self.providerShareBPS = providerShareBPS
            self.globalMultiplierPPM = globalMultiplierPPM
        }
    }

    var version: String
    var policyVersion: String
    var generatedAt: Date
    var usdPerMillionCredits: Double
    var rows: [String: Row]

    enum CodingKeys: String, CodingKey {
        case version
        case policyVersion = "policy_version"
        case generatedAt = "generated_at"
        case usdPerMillionCredits = "usd_per_million_credits"
        case rows
    }

    init(
        version: String,
        policyVersion: String,
        generatedAt: Date,
        usdPerMillionCredits: Double,
        rows: [String: Row]
    ) {
        self.version = version
        self.policyVersion = policyVersion
        self.generatedAt = generatedAt
        self.usdPerMillionCredits = usdPerMillionCredits
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        policyVersion = try c.decode(String.self, forKey: .policyVersion)
        usdPerMillionCredits = try c.decode(Double.self, forKey: .usdPerMillionCredits)
        rows = try c.decode([String: Row].self, forKey: .rows)
        let rawDate = try c.decode(String.self, forKey: .generatedAt)
        guard let date = ISO8601DateFormatter.autotuneInternet.date(from: rawDate) else {
            throw DecodingError.dataCorruptedError(forKey: .generatedAt, in: c, debugDescription: "generated_at must be RFC3339")
        }
        generatedAt = date
    }

    func validated() throws -> RateCardProjection {
        guard !version.isEmpty, !policyVersion.isEmpty, !rows.isEmpty, rows["default"] != nil, usdPerMillionCredits.isFinite, usdPerMillionCredits >= 0 else {
            throw AutotuneRecommendError.invalidRateCard("version/usd_per_million_credits")
        }
        for (key, row) in rows {
            guard row.promptRatePerMtok >= 0,
                  row.promptCacheHitRatePerMtok >= 0,
                  row.completionRatePerMtok >= 0,
                  row.providerShareBPS >= 0,
                  row.providerShareBPS <= 10_000,
                  row.globalMultiplierPPM >= 0
            else {
                throw AutotuneRecommendError.invalidRateCard("negative value for \(key)")
            }
        }
        guard version == projectionHash else {
            throw AutotuneRecommendError.invalidRateCard("version must equal projection hash")
        }
        return self
    }

    var projectionHash: String {
        let defaultRow = rows["default"]
        let globalMultiplier = defaultRow?.globalMultiplierPPM ?? 0
        let providerShare = defaultRow?.providerShareBPS ?? 0
        var fields: [String] = [
            "\"global_multiplier_ppm\":\(globalMultiplier)",
            "\"provider_share_bps\":\(providerShare)",
        ]
        let rowsJSON = rows.keys.sorted().map { key -> String in
            let row = rows[key]!
            let encodedKey = key.jsonEscaped.replacingOccurrences(of: "\\/", with: "/")
            return "\(encodedKey):{\"completion_rate_per_mtok\":\(row.completionRatePerMtok),\"global_multiplier_ppm\":\(row.globalMultiplierPPM),\"prompt_cache_hit_rate_per_mtok\":\(row.promptCacheHitRatePerMtok),\"prompt_rate_per_mtok\":\(row.promptRatePerMtok),\"provider_share_bps\":\(row.providerShareBPS)}"
        }.joined(separator: ",")
        fields.append("\"rows\":{\(rowsJSON)}")
        fields.append("\"usd_per_million_credits\":\(usdPerMillionCredits.canonicalProjectionJSONNumber)")
        let body = "{\(fields.joined(separator: ","))}"
        return Data(SHA256.hash(data: Data(body.utf8))).hexLower
    }

    func rowForRecommendation(modelKey: String) -> (key: String, row: Row)? {
        if let row = rows[modelKey] {
            return (modelKey, row)
        }
        let normalized = AutotuneModelKeyNormalizer.normalize(modelKey)
        if normalized != modelKey, normalized != "default", let row = rows[normalized] {
            return (normalized, row)
        }
        // Match coordinator RateFor fallback semantics so a probe-feasible
        // fresh install does not drop to donor-only while the rate card catches
        // up to a newly recommendable catalog row.
        if let row = rows["default"] {
            return ("default", row)
        }
        return nil
    }

    func servedModelKey(modelKey: String, rateCardKey: String) -> String {
        if rateCardKey == "default", modelKey != "default" {
            return modelKey
        }
        if rateCardKey == AutotuneModelKeyNormalizer.normalize(modelKey),
           modelKey.contains("/"),
           !modelKey.lowercased().hasPrefix("mlx-community/") {
            return modelKey
        }
        return rateCardKey
    }
}

extension RateCardProjection.Row {
    func usdPerMillionPromptTokens(creditsPerMillion: Double) -> Double {
        usdPerMillionTokens(credits: promptRatePerMtok, creditsPerMillion: creditsPerMillion)
    }

    func usdPerMillionCompletionTokens(creditsPerMillion: Double) -> Double {
        usdPerMillionTokens(credits: completionRatePerMtok, creditsPerMillion: creditsPerMillion)
    }

    private func usdPerMillionTokens(credits: Int64, creditsPerMillion: Double) -> Double {
        Double(credits)
            * (Double(globalMultiplierPPM) / 1_000_000.0)
            * (creditsPerMillion / 1_000_000.0)
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
        if key.hasPrefix("nvidia-nemotron-") {
            return String(key.dropFirst("nvidia-".count))
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
    var signerKeyID: String? = nil
}

struct AutotuneStaticInputs {
    // Static feed public keys are committed under phase3-binary/dist/static/keys.
    // Private keys stay off-repo at ~/.config/macprovider/keys/ with mode 0600.
    static let keyID = bakedCatalogSignerKeyID ?? "streamvc-autotune-static-v5"
    static let publicKeyName = keyID == "streamvc-autotune-static-v4"
        ? "autotune_static_json_ed25519_v4"
        : "autotune_static_json_ed25519_v5"
    static let autotune_static_json_ed25519_v4 = "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU="
    static let autotune_static_json_ed25519_v5 = "vpTgWfvvrnbc1QhdTAxULFisoDU7jQ4mB1yZIHIGjBA="
    static let publicKeyBase64 = generatedTrustedPublicKeys[keyID] ?? autotune_static_json_ed25519_v5
    static let defaultTrustedPublicKeys = generatedTrustedPublicKeys
    static let transitionMissingProvenanceCandidateRelease = "published-2026-07-10-catalog-recovery-v1"
    static let transitionMissingProvenanceCandidateSHA256 = "776182f6230eff098345b188322dba0c7fce47a6da46447432991ffdc37eabda"
    static let transitionDemandRankSHA256 = "27cdfc12a43b78db32710926ee16699aadce0c4ddd9d8282baca2532f780c5e2"

    var fetch: (URL) async throws -> Data
    var trustedPublicKeys: [String: String]
    var verifySignature: ((Data, Data) -> Bool)?
    var now: () -> Date

    init(
        fetch: @escaping (URL) async throws -> Data = { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw AutotuneRecommendError.invalidStaticJSON("HTTP \(http.statusCode)")
            }
            return data
        },
        trustedPublicKeys: [String: String] = Self.defaultTrustedPublicKeys,
        verifySignature: ((Data, Data) -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.fetch = fetch
        self.trustedPublicKeys = trustedPublicKeys
        self.verifySignature = verifySignature
        self.now = now
    }

    func loadDemandRank() async -> AutotuneStaticSelection<DemandRank> {
        await loadSignedStatic(
            name: "demand-rank",
            bakedBytes: Data(Self.bakedDemandRankJSON.utf8),
            fallbackWarning: .demandRankFallbackUsed,
            integrityWarning: .demandRankIntegrityFailure,
            updateWarning: .demandRankUpdateRequired,
            staleWarning: .demandRankStale,
            allowOlderFetchedBytes: Self.isPinnedTransitionDemandRank
        ) { try Self.decodeDemandRank($0) }
    }

    func loadCandidateCatalog() async -> AutotuneStaticSelection<CandidateCatalog> {
        await loadSignedStatic(
            name: "autotune-candidates",
            bakedBytes: Data(Self.bakedCandidateCatalogJSON.utf8),
            fallbackWarning: .candidateCatalogFallbackUsed,
            integrityWarning: .candidateCatalogIntegrityFailure,
            updateWarning: .candidateCatalogUpdateRequired,
            staleWarning: .candidateCatalogStale,
            allowOlderFetchedBytes: Self.isPinnedTransitionCandidateCatalog
        ) { try Self.decodeSignedStaticCandidateCatalog($0) }
    }

    func loadCatalogRelease() async -> (
        demand: AutotuneStaticSelection<DemandRank>,
        candidate: AutotuneStaticSelection<CandidateCatalog>
    ) {
        var demand = await loadDemandRank()
        var candidate = await loadCandidateCatalog()
        let paired = demand.value.version == candidate.value.version
            && demand.value.generatedAt == candidate.value.generatedAt
            && demand.value.policyVersion == candidate.value.policyVersion
        if !paired {
            demand.warnings.insert(.demandRankIntegrityFailure)
            candidate.warnings.insert(.candidateCatalogIntegrityFailure)
        }
        return (demand, candidate)
    }

    func loadRecommendationInputs() async -> (
        demand: AutotuneStaticSelection<DemandRank>,
        candidate: AutotuneStaticSelection<CandidateCatalog>,
        rateCard: AutotuneStaticSelection<RateCardProjection>
    ) {
        var release = await loadCatalogRelease()
        var rateCard = await loadRateCard()
        let rateCardPaired = rateCard.value.generatedAt == release.candidate.value.generatedAt
            && rateCard.value.policyVersion == release.candidate.value.policyVersion
        if !rateCardPaired {
            rateCard.warnings.insert(.rateCardIntegrityFailure)
            release.demand.warnings.insert(.demandRankIntegrityFailure)
            release.candidate.warnings.insert(.candidateCatalogIntegrityFailure)
        }
        return (release.demand, release.candidate, rateCard)
    }

    func loadRateCard() async -> AutotuneStaticSelection<RateCardProjection> {
        await loadSignedStatic(
            name: "rate-card",
            bakedBytes: Data(Self.bakedRateCardJSON.utf8),
            fallbackWarning: .rateCardFallbackUsed,
            integrityWarning: .rateCardIntegrityFailure,
            updateWarning: .rateCardUpdateRequired,
            staleWarning: .rateCardStale
        ) { try Self.decodeRateCard($0) }
    }

    private func loadSignedStatic<T>(
        name: String,
        bakedBytes: Data,
        fallbackWarning: AutotuneRecommendWarning,
        integrityWarning: AutotuneRecommendWarning,
        updateWarning: AutotuneRecommendWarning,
        staleWarning: AutotuneRecommendWarning,
        allowOlderFetchedBytes: (Data, String) -> Bool = { _, _ in false },
        decode: (Data) throws -> T
    ) async -> AutotuneStaticSelection<T> {
        let bakedValue = (try? decode(bakedBytes))!
        let bakedGeneratedAt = generatedAt(in: bakedBytes) ?? .distantFuture
        let jsonBytes: Data
        do {
            let jsonURL = URL(string: "https://coordinator.streamvc.live/v1/\(name)")!
            jsonBytes = try await fetch(jsonURL)
        } catch {
            return AutotuneStaticSelection(
                value: bakedValue,
                selectedBytes: bakedBytes,
                warnings: [fallbackWarning],
                usedFallback: true,
                signerKeyID: Self.bakedCatalogSignerKeyID
            )
        }

        let sigBytes: Data
        do {
            let sigURL = URL(string: "https://coordinator.streamvc.live/v1/\(name).sig")!
            sigBytes = try await fetch(sigURL)
        } catch {
            return AutotuneStaticSelection(
                value: bakedValue,
                selectedBytes: bakedBytes,
                warnings: [fallbackWarning, integrityWarning],
                usedFallback: true,
                signerKeyID: Self.bakedCatalogSignerKeyID
            )
        }

        guard let sidecar = parsedSidecar(sigBytes), signatureIsValid(jsonBytes: jsonBytes, sidecarBytes: sigBytes, sidecar: sidecar)
        else {
            return AutotuneStaticSelection(
                value: bakedValue,
                selectedBytes: bakedBytes,
                warnings: [fallbackWarning, integrityWarning],
                usedFallback: true,
                signerKeyID: Self.bakedCatalogSignerKeyID
            )
        }
        guard policyVersion(in: jsonBytes) == policyVersion(in: bakedBytes) else {
            return AutotuneStaticSelection(
                value: bakedValue,
                selectedBytes: bakedBytes,
                warnings: [fallbackWarning, updateWarning],
                usedFallback: true,
                signerKeyID: Self.bakedCatalogSignerKeyID
            )
        }
        guard let value = try? decode(jsonBytes),
              let fetchedGeneratedAt = generatedAt(in: jsonBytes)
        else {
            return AutotuneStaticSelection(
                value: bakedValue,
                selectedBytes: bakedBytes,
                warnings: [fallbackWarning, integrityWarning],
                usedFallback: true,
                signerKeyID: Self.bakedCatalogSignerKeyID
            )
        }
        let current = now()
        guard (fetchedGeneratedAt >= bakedGeneratedAt || allowOlderFetchedBytes(jsonBytes, sidecar.keyID)),
              fetchedGeneratedAt <= current.addingTimeInterval(10 * 60),
              current.timeIntervalSince(fetchedGeneratedAt) <= 30 * 24 * 3600
        else {
            return AutotuneStaticSelection(
                value: bakedValue,
                selectedBytes: bakedBytes,
                warnings: [fallbackWarning, updateWarning],
                usedFallback: true,
                signerKeyID: Self.bakedCatalogSignerKeyID
            )
        }
        var warnings = Set<AutotuneRecommendWarning>()
        if current.timeIntervalSince(fetchedGeneratedAt) >= 14 * 24 * 3600 {
            warnings.insert(staleWarning)
        }
        return AutotuneStaticSelection(value: value, selectedBytes: jsonBytes, warnings: warnings, usedFallback: false, signerKeyID: sidecar.keyID)
    }

    private struct SignatureSidecar {
        var keyID: String
        var signature: Data
    }

    private func parsedSidecar(_ data: Data) -> SignatureSidecar? {
        guard (try? AutotuneStrictJSON.rejectDuplicateKeys(data)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["key_id", "alg", "signature"]),
              let keyID = object["key_id"] as? String,
              keyID == keyID.trimmingCharacters(in: .whitespacesAndNewlines),
              !keyID.isEmpty,
              trustedPublicKeys[keyID] != nil,
              object["alg"] as? String == "ed25519",
              let encodedSignature = object["signature"] as? String,
              let signature = Data(base64Encoded: encodedSignature),
              signature.count == 64,
              signature.base64EncodedString() == encodedSignature
        else {
            return nil
        }
        return SignatureSidecar(keyID: keyID, signature: signature)
    }

    private func signatureIsValid(jsonBytes: Data, sidecarBytes: Data, sidecar: SignatureSidecar) -> Bool {
        if let verifySignature {
            return verifySignature(jsonBytes, sidecarBytes)
        }
        guard let encodedPublicKey = trustedPublicKeys[sidecar.keyID],
              let publicKeyBytes = Data(base64Encoded: encodedPublicKey),
              publicKeyBytes.count == 32,
              publicKeyBytes.base64EncodedString() == encodedPublicKey,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        else {
            return false
        }
        return publicKey.isValidSignature(sidecar.signature, for: jsonBytes)
    }

    static func defaultSignatureVerifier(jsonBytes: Data, sidecarBytes: Data) -> Bool {
        guard (try? AutotuneStrictJSON.rejectDuplicateKeys(sidecarBytes)) != nil,
              let object = try? JSONSerialization.jsonObject(with: sidecarBytes) as? [String: Any],
              Set(object.keys) == Set(["key_id", "alg", "signature"]),
              let keyID = object["key_id"] as? String,
              object["alg"] as? String == "ed25519",
              let signature = object["signature"] as? String,
              let signatureBytes = Data(base64Encoded: signature),
              signatureBytes.count == 64,
              signatureBytes.base64EncodedString() == signature,
              let encodedPublicKey = defaultTrustedPublicKeys[keyID],
              let publicKeyBytes = Data(base64Encoded: encodedPublicKey),
              publicKeyBytes.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        else {
            return false
        }
        return publicKey.isValidSignature(signatureBytes, for: jsonBytes)
    }

    static func decodeDemandRank(_ data: Data) throws -> DemandRank {
        try AutotuneStrictJSON.validate(data, kind: .demandRank)
        return try JSONDecoder.autotune.decode(DemandRank.self, from: data).validated()
    }

    static func decodeCandidateCatalog(_ data: Data) throws -> CandidateCatalog {
        try AutotuneStrictJSON.validate(data, kind: .candidateCatalog)
        return try JSONDecoder.autotune.decode(CandidateCatalog.self, from: data)
            .validated()
    }

    static func decodeSignedStaticCandidateCatalog(_ data: Data) throws -> CandidateCatalog {
        do {
            return try decodeCandidateCatalog(data)
        } catch {
            guard let transitionBytes = candidateCatalogWithPinnedTransitionProvenance(data) else {
                throw error
            }
            return try decodeCandidateCatalog(transitionBytes)
        }
    }

    static func decodeRateCard(_ data: Data) throws -> RateCardProjection {
        try AutotuneStrictJSON.validate(data, kind: .rateCard)
        return try JSONDecoder.autotune.decode(RateCardProjection.self, from: data).validated()
    }

    static func candidateCatalogSHA256(bytes: Data) -> String {
        sha256(bytes: bytes)
    }

    private static func sha256(bytes: Data) -> String {
        Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPinnedTransitionDemandRank(_ data: Data, signerKeyID: String) -> Bool {
        guard signerKeyID == "streamvc-autotune-static-v4",
              sha256(bytes: data) == transitionDemandRankSHA256,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return object["version"] as? String == transitionMissingProvenanceCandidateRelease
    }

    private static func isPinnedTransitionCandidateCatalog(_ data: Data, signerKeyID: String) -> Bool {
        guard signerKeyID == "streamvc-autotune-static-v4",
              sha256(bytes: data) == transitionMissingProvenanceCandidateSHA256,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return object["version"] as? String == transitionMissingProvenanceCandidateRelease
    }

    private static func candidateCatalogWithPinnedTransitionProvenance(_ data: Data) -> Data? {
        guard sha256(bytes: data) == transitionMissingProvenanceCandidateSHA256,
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? String == transitionMissingProvenanceCandidateRelease,
              var rows = root["rows"] as? [String: Any],
              let currentRoot = try? JSONSerialization.jsonObject(with: Data(bakedCandidateCatalogJSON.utf8)) as? [String: Any],
              let currentRows = currentRoot["rows"] as? [String: Any]
        else {
            return nil
        }
        for key in rows.keys {
            guard var row = rows[key] as? [String: Any],
                  var benchGate = row["bench_gate"] as? [String: Any],
                  benchGate["provenance"] == nil,
                  let currentRow = currentRows[key] as? [String: Any],
                  let currentBenchGate = currentRow["bench_gate"] as? [String: Any],
                  let provenance = currentBenchGate["provenance"] as? [String: Any]
            else {
                return nil
            }
            benchGate["provenance"] = provenance
            row["bench_gate"] = benchGate
            rows[key] = row
        }
        root["rows"] = rows
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func generatedAt(in data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["generated_at"] as? String
        else {
            return nil
        }
        return ISO8601DateFormatter.autotuneInternet.date(from: raw)
    }

    private func policyVersion(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["policy_version"] as? String
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
    var candidateRowIdentity: String = ""
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
    var donorMode: Bool
    var buyerTTFTCeilingMS: Int
}

struct AutotuneCandidateScore: Equatable {
    var rank: Int
    var catalogKey: String
    var model: String
    var eligible: Bool
    var promptRateUSDPerMillionTokens: Double
    var completionRateUSDPerMillionTokens: Double
    var tokensPerSecond: Double
    var memoryHeadroomGB: Double
    var confidence: String
    var why: String
    var rawScore: Double
    var benchGateProvenance: CandidateCatalog.BenchGate.Provenance
    var benchGateDrift: [String]
    var buyerTTFTCeilingExceeded: Bool
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
    var promptRatePerMillionTokens: Double?
    var completionRatePerMillionTokens: Double?
    var selectedCandidate: AutotuneCandidateScore?
    var candidates: [AutotuneCandidateScore]
    var allCandidates: [AutotuneCandidateScore]
    var benchmarkedCount: Int = 0
    var defaultModel: String?
    var donorFallbackModel: String?
    var donorFallbackCandidate: AutotuneCandidateScore?
    var warnings: [AutotuneRecommendWarning]
    /// modelKey -> reason string for each candidate that did not produce a
    /// feasible probe. Populated by AutotuneRecommendationBenchmarker and
    /// attached by the CLI caller after engine.recommend() returns. Persisted
    /// into last-recommendation.json so post-hoc diagnosis explains WHY
    /// benchmark_id is null / no eligible model was found.
    var probeDiagnostics: [String: String] = [:]
}

struct AutotuneRecommendEngine {
    static let safetyMarginGB = 4
    static let maxBenchmarkAge: TimeInterval = 7 * 24 * 3600
    /// Integrity / update-required warnings that fail closed before paid
    /// recommend / prefetch. Baked-catalog transport fallback stays out of this
    /// set so SPEC-023 local diagnostics remain available offline (#582).
    static let paidTrustBlockingWarnings: Set<AutotuneRecommendWarning> = [
        .candidateCatalogIntegrityFailure,
        .candidateCatalogUpdateRequired,
        .demandRankIntegrityFailure,
        .demandRankUpdateRequired,
        .rateCardIntegrityFailure,
        .rateCardUpdateRequired,
    ]

    /// Warnings that must fail closed before network apply / evidence submit /
    /// freshness resubmit. Includes baked candidate-catalog fallback: Pearl's
    /// hello gate rejects that SHA class as `autotune_evidence_invalid` (#582).
    static let networkSubmissionBlockingWarnings: Set<AutotuneRecommendWarning> = paidTrustBlockingWarnings.union([
        .candidateCatalogFallbackUsed,
    ])

    static func paidTrustBlocks(_ warnings: Set<AutotuneRecommendWarning>) -> Bool {
        !warnings.isDisjoint(with: paidTrustBlockingWarnings)
    }

    static func networkSubmissionBlocks(_ warnings: Set<AutotuneRecommendWarning>) -> Bool {
        !warnings.isDisjoint(with: networkSubmissionBlockingWarnings)
    }

    /// True when recommend must abort before Stage-1 benchmarks because the
    /// caller enabled apply/submit and catalog evidence would be rejected.
    static func shouldFailClosedBeforeBenchmarks(
        _ warnings: Set<AutotuneRecommendWarning>,
        apply: Bool,
        submitHardwareEvidence: Bool,
        requireHardwareEvidence: Bool
    ) -> Bool {
        networkSubmissionBlocks(warnings)
            && (apply || submitHardwareEvidence || requireHardwareEvidence)
    }

    /// Operator-facing copy when network onboarding is blocked. Fallback uses
    /// stronger guidance because Pearl rejects that evidence class (#582).
    static func networkSubmissionBlockMessage(_ warnings: Set<AutotuneRecommendWarning>) -> String {
        let failures = warnings
            .intersection(networkSubmissionBlockingWarnings)
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        if warnings.contains(.candidateCatalogFallbackUsed) {
            return "signed live catalog unavailable (\(failures)); reconnect and retry when the coordinator candidate catalog is reachable — baked-catalog evidence cannot be submitted"
        }
        return "autotune trust verification failed (\(failures)); upgrade macprovider or retry when the signed static inputs are available"
    }

    static func paidTrustBlockMessage(_ warnings: Set<AutotuneRecommendWarning>) -> String {
        networkSubmissionBlockMessage(warnings)
    }

    func recommend(_ request: AutotuneRecommendRequest) -> AutotuneRecommendResult {
        var warnings = request.warnings
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
            let measuredTPS = benchmark?.sustainedTPS ?? 0
            let tps = measuredTPS.isFinite ? measuredTPS : 0
            let benchGateDrift = benchmark.map {
                Self.advisoryBenchmarkWarnings($0, candidate: candidate)
                    .map(\.rawValue)
                    .sorted()
            } ?? []
            let buyerTTFTCeilingExceeded = Self.buyerTTFTCeilingExceeded(
                benchmark,
                request: request
            )
            let rateRow = rateMatch?.row
            let promptUSD = rateRow?.usdPerMillionPromptTokens(creditsPerMillion: request.rateCard.usdPerMillionCredits) ?? 0
            let completionUSD = rateRow?.usdPerMillionCompletionTokens(creditsPerMillion: request.rateCard.usdPerMillionCredits) ?? 0
            let providerShare = Double(rateRow?.providerShareBPS ?? 0) / 10_000.0
            let payoutScore = Double(rateRow?.completionRatePerMtok ?? 0) * providerShare
            let demandScore = max(demand.demandWeight, request.demandRank.coldStartFloor)
            let shortageScore = demand.effectiveSupplyDeficitMultiplier
            let expectedEarningsScore = payoutScore * max(tps, 0) * demandScore * shortageScore
            let headroom = Double(request.hardware.memoryGB - Self.safetyMarginGB - candidate.minRAMGB)
            let servedModel = rateMatch.map {
                request.rateCard.servedModelKey(modelKey: modelKey, rateCardKey: $0.key)
            } ?? modelKey
            var candidateWarnings = warnings
            if rateMatch?.key == "default", modelKey != "default" {
                candidateWarnings.insert(.rateCardDefaultTierUsed)
            }
            let confidence = confidence(warnings: candidateWarnings, benchmark: benchmark, benchGateDrift: benchGateDrift)
            return AutotuneCandidateScore(
                rank: 0,
                catalogKey: modelKey,
                model: servedModel,
                eligible: eligible,
                promptRateUSDPerMillionTokens: promptUSD.rounded6,
                completionRateUSDPerMillionTokens: completionUSD.rounded6,
                tokensPerSecond: tps.rounded6,
                memoryHeadroomGB: headroom.rounded6,
                confidence: confidence,
                why: why(
                    modelKey: modelKey,
                    candidate: candidate,
                    benchmark: benchmark,
                    eligible: eligible,
                    buyerTTFTCeilingMS: request.buyerTTFTCeilingMS
                ),
                rawScore: expectedEarningsScore.rounded6,
                benchGateProvenance: candidate.benchGate.provenance,
                benchGateDrift: benchGateDrift,
                buyerTTFTCeilingExceeded: buyerTTFTCeilingExceeded
            )
        }
        .sorted { a, b in
            if a.eligible != b.eligible { return a.eligible && !b.eligible }
            if a.rawScore != b.rawScore { return a.rawScore > b.rawScore }
            if a.tokensPerSecond != b.tokensPerSecond { return a.tokensPerSecond > b.tokensPerSecond }
            let demandA = max(request.demandRank.rows[a.catalogKey]?.demandWeight ?? 0, request.demandRank.coldStartFloor)
            let demandB = max(request.demandRank.rows[b.catalogKey]?.demandWeight ?? 0, request.demandRank.coldStartFloor)
            if demandA != demandB { return demandA > demandB }
            return a.model < b.model
        }
        .enumerated()
        .map { offset, value in
            var next = value
            next.rank = offset + 1
            return next
        }

        let eligible = scored.filter(\.eligible)
        let recommended = eligible.first
        let donorFallback = recommended == nil ? scored.first { score in
            Self.donorModeCompatible(
                modelKey: score.catalogKey,
                candidate: request.candidateCatalog.rows[score.catalogKey],
                request: request
            )
        } : nil
        if eligible.isEmpty {
            warnings.insert(.noEligibleModel)
            if scored.contains(where: \.buyerTTFTCeilingExceeded) {
                warnings.insert(.buyerTTFTCeilingExceeded)
            }
        }

        let defaultModel = scored.first?.model
        let selectedBenchmark = recommended.flatMap { request.benchmarks[$0.catalogKey] } ?? eligible.compactMap { request.benchmarks[$0.catalogKey] }.first
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
            if let benchmark = request.benchmarks[target.catalogKey],
               let candidate = request.candidateCatalog.rows[target.catalogKey] {
                warnings.formUnion(Self.advisoryBenchmarkWarnings(benchmark, candidate: candidate))
            }
        }
        // #742: paid path hard-vetoes swap. Surface the warning when swap is why
        // no paid row landed (donor fallthrough / no-eligible), including the case
        // where no donor candidate exists. Do not warn on a clean paid pick just
        // because a lower-ranked ineligible row swapped.
        if recommended == nil,
           request.benchmarks.values.contains(where: \.swapDetected) {
            warnings.insert(.swapObservedUnderLoad)
        }

        let resultCandidates = eligible.isEmpty ? Array(scored.prefix(5)) : Array(eligible.prefix(5))
        let benchmarkedCount = scored.reduce(0) { count, score in
            request.benchmarks[score.catalogKey] == nil ? count : count + 1
        }

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
            promptRatePerMillionTokens: recommended?.promptRateUSDPerMillionTokens,
            completionRatePerMillionTokens: recommended?.completionRateUSDPerMillionTokens,
            selectedCandidate: recommended,
            candidates: resultCandidates,
            allCandidates: scored,
            benchmarkedCount: benchmarkedCount,
            defaultModel: defaultModel,
            donorFallbackModel: donorFallback?.model,
            donorFallbackCandidate: donorFallback,
            warnings: warnings.map(\.rawValue).sorted().compactMap(AutotuneRecommendWarning.init(rawValue:))
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
        if !Self.paidTrustBlockingWarnings.isDisjoint(with: request.warnings) { return false }
        if !demand.recommendable { return false }
        if candidate.runtimeStatus != "recommendable" { return false }
        guard rateCardRow != nil else { return false }
        guard candidate.modelRevision != nil, candidate.modelSHA256 != nil else { return false }
        guard candidate.minRAMGB <= request.hardware.memoryGB - Self.safetyMarginGB else { return false }
        guard request.hardware.bandwidthTier.satisfies(minimum: candidate.minBandwidthTier) else { return false }
        guard let benchmark else { return false }
        // SPEC-023 v0.7 (#742): swap is a paid-path hard veto — a locally
        // measured fact that needs no catalog threshold. Signed TPS/TTFT gates
        // remain advisory QoS warnings. The buyer TTFT ceiling is separate
        // operator policy and vetoes paid recommendations only. Thermal
        // throttling stays a hard block. Donor-mode keeps swap advisory (see
        // donorModeCompatible).
        return !benchmark.thermalThrottleDetected
            && !benchmark.swapDetected
            && !Self.buyerTTFTCeilingExceeded(benchmark, request: request)
            && Self.cachedBenchmarkAdmitted(benchmark, request: request, modelKey: modelKey)
    }

    static func buyerTTFTCeilingExceeded(
        _ benchmark: CandidateBenchmark?,
        request: AutotuneRecommendRequest
    ) -> Bool {
        guard request.buyerTTFTCeilingMS > 0, let benchmark else { return false }
        return benchmark.ttftMS > request.buyerTTFTCeilingMS
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

    static func advisoryBenchmarkWarnings(
        _ benchmark: CandidateBenchmark,
        candidate: CandidateCatalog.Row
    ) -> Set<AutotuneRecommendWarning> {
        var warnings = Set<AutotuneRecommendWarning>()
        if !benchmark.sustainedTPS.isFinite || benchmark.sustainedTPS < candidate.benchGate.minSustainedTPS {
            warnings.insert(.tpsBelowGate)
        }
        if benchmark.ttftMS > candidate.benchGate.max4KTTFTMS {
            warnings.insert(.ttftAboveGate)
        }
        return warnings
    }

    private static func advisoryBenchmarkWarningReasons(
        _ benchmark: CandidateBenchmark,
        candidate: CandidateCatalog.Row
    ) -> [String] {
        var reasons: [String] = []
        if !benchmark.sustainedTPS.isFinite {
            reasons.append("TPS evidence is non-finite")
        } else if benchmark.sustainedTPS < candidate.benchGate.minSustainedTPS {
            reasons.append(
                String(
                    format: "TPS %.3f is below advisory catalog target %.3f",
                    benchmark.sustainedTPS,
                    candidate.benchGate.minSustainedTPS
                )
            )
        }
        if benchmark.ttftMS > candidate.benchGate.max4KTTFTMS {
            reasons.append(
                "TTFT \(benchmark.ttftMS)ms exceeds advisory catalog target \(candidate.benchGate.max4KTTFTMS)ms"
            )
        }
        return reasons
    }

    static func cachedBenchmarkAdmitted(_ benchmark: CandidateBenchmark, request: AutotuneRecommendRequest, modelKey: String) -> Bool {
        let catalogEvidenceMatches: Bool
        if benchmark.candidateRowIdentity.isEmpty {
            catalogEvidenceMatches = benchmark.candidateCatalogSHA256 == request.candidateCatalogSHA256
        } else {
            catalogEvidenceMatches = benchmark.candidateRowIdentity == request.candidateCatalog.rowIdentity(for: modelKey)
        }
        // Evidence freshness binds to compatibility inputs (catalog row identity,
        // model artifact, hardware identity) and an explicit evidence lifetime —
        // never to the independently-versioned CLI marketing release number.
        // A CLI version-only bump must not discard a known-good cached benchmark.
        guard catalogEvidenceMatches,
              benchmark.modelID == request.candidateCatalog.rows[modelKey]?.modelID,
              benchmark.artifactSHA256 == request.candidateCatalog.rows[modelKey]?.modelSHA256,
              benchmark.hardwareIdentityHash == request.hardware.hardwareIdentityHash,
              benchmark.modelArtifactPath.hasPrefix("/")
        else {
            return false
        }
        return request.generatedAt.timeIntervalSince(benchmark.generatedAt) <= maxBenchmarkAge
    }

    private func confidence(
        warnings: Set<AutotuneRecommendWarning>,
        benchmark: CandidateBenchmark?,
        benchGateDrift: [String]
    ) -> String {
        if !Self.paidTrustBlockingWarnings.isDisjoint(with: warnings)
            || (warnings.contains(.rateCardFallbackUsed) && warnings.contains(.demandRankFallbackUsed))
            || warnings.contains(.hardwareTierUnknown)
            || warnings.contains(.demandRankStale)
            || warnings.contains(.candidateCatalogStale)
            || warnings.contains(.rateCardDefaultTierUsed)
            || !benchGateDrift.isEmpty {
            return "low"
        }
        if warnings.contains(.rateCardFallbackUsed) || warnings.contains(.demandRankFallbackUsed) || warnings.contains(.candidateCatalogFallbackUsed) || benchmark == nil {
            return "medium"
        }
        return "high"
    }

    private func why(
        modelKey: String,
        candidate: CandidateCatalog.Row,
        benchmark: CandidateBenchmark?,
        eligible: Bool,
        buyerTTFTCeilingMS: Int
    ) -> String {
        if eligible {
            if let benchmark {
                let advisoryReasons = Self.advisoryBenchmarkWarningReasons(benchmark, candidate: candidate)
                if !advisoryReasons.isEmpty {
                    return ("\(modelKey) eligible with advisory QoS warning: " + advisoryReasons.joined(separator: "; ")).prefixString(140)
                }
            }
            return "\(modelKey) has the best expected provider earnings after measured throughput, buyer demand, and supply deficit.".prefixString(140)
        }
        if benchmark?.thermalThrottleDetected == true {
            return "\(modelKey) did not clear the thermal throttle recommendation gate.".prefixString(140)
        }
        if benchmark?.swapDetected == true {
            return "\(modelKey) did not clear the swap recommendation gate (swap detected under probe load).".prefixString(140)
        }
        if buyerTTFTCeilingMS > 0, let benchmark, benchmark.ttftMS > buyerTTFTCeilingMS {
            return "\(modelKey) did not clear the buyer TTFT ceiling (\(benchmark.ttftMS)ms > \(buyerTTFTCeilingMS)ms).".prefixString(140)
        }
        return "\(modelKey) did not clear one or more recommendation gates.".prefixString(140)
    }
}

extension AutotuneRecommendResult {
    func jsonString(serveConfig: RecommendationCore? = nil, donorMode: Bool = false) -> String {
        let warningsJSON = warnings.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let candidatesJSON = candidates.map(Self.candidateJSON).joined(separator: ",")
        let serveConfigJSON = serveConfig.map { Self.serveConfigJSON($0, donorMode: donorMode) } ?? "null"
        return """
        {"schema_version":"autotune_recommend.v1","generated_at":\(ISO8601DateFormatter.autotuneInternet.string(from: generatedAt).jsonEscaped),"hardware":{"machine":\(hardware.machine?.jsonEscaped ?? "null"),"chip":\(hardware.chip.jsonEscaped),"memory_gb":\(hardware.memoryGB),"bandwidth_tier":\(hardware.bandwidthTier.rawValue.jsonEscaped),"detected":\(hardware.detected),"os_version":\(hardware.osVersion.jsonEscaped),"binary_version":\(hardware.binaryVersion.jsonEscaped)},"inputs":{"rate_card_version":\(rateCardVersion.jsonEscaped),"demand_rank_version":\(demandRankVersion.jsonEscaped),"candidate_catalog_version":\(candidateCatalogVersion.jsonEscaped)},"recommended_model":\(recommendedModel?.jsonEscaped ?? "null"),"prompt_rate_usd_per_million_tokens":\(promptRatePerMillionTokens?.jsonNumber ?? "null"),"completion_rate_usd_per_million_tokens":\(completionRatePerMillionTokens?.jsonNumber ?? "null"),"serve_config":\(serveConfigJSON),"candidates":[\(candidatesJSON)],"warnings":[\(warningsJSON)]}
        """
    }

    func simulatorJSON() -> String {
        let base = jsonString()
        let allCandidatesJSON = allCandidates.map(Self.candidateJSON).joined(separator: ",")
        return String(base.dropLast()) + ",\"all_candidates\":[\(allCandidatesJSON)]}"
    }

    private static func candidateJSON(_ candidate: AutotuneCandidateScore) -> String {
        let driftJSON = candidate.benchGateDrift.map(\.jsonEscaped).joined(separator: ",")
        return """
        {"rank":\(candidate.rank),"model":\(candidate.model.jsonEscaped),"eligible":\(candidate.eligible),"prompt_rate_usd_per_million_tokens":\(candidate.promptRateUSDPerMillionTokens.jsonNumber),"completion_rate_usd_per_million_tokens":\(candidate.completionRateUSDPerMillionTokens.jsonNumber),"tokens_per_second":\(candidate.tokensPerSecond.jsonNumber),"memory_headroom_gb":\(candidate.memoryHeadroomGB.jsonNumber),"confidence":\(candidate.confidence.jsonEscaped),"why":\(candidate.why.jsonEscaped),"raw_score":\(candidate.rawScore.jsonNumber),"bench_gate_provenance":\(benchGateProvenanceJSON(candidate.benchGateProvenance)),"bench_gate_drift":[\(driftJSON)],"buyer_ttft_ceiling_exceeded":\(candidate.buyerTTFTCeilingExceeded)}
        """
    }

    private static func benchGateProvenanceJSON(_ provenance: CandidateCatalog.BenchGate.Provenance) -> String {
        var fields = ["\"source\":\(provenance.source.jsonEscaped)"]
        if let hardware = provenance.hardware {
            fields.append("\"hardware\":\(hardware.jsonEscaped)")
        }
        if let measuredAt = provenance.measuredAt {
            fields.append("\"measured_at\":\(measuredAt.jsonEscaped)")
        }
        if let notes = provenance.notes {
            fields.append("\"notes\":\(notes.jsonEscaped)")
        }
        return "{\(fields.joined(separator: ","))}"
    }

    private static func humanBenchGateProvenance(_ provenance: CandidateCatalog.BenchGate.Provenance) -> String {
        var fields = ["source=\(humanSingleLine(provenance.source))"]
        if let hardware = provenance.hardware {
            fields.append("hardware=\(humanSingleLine(hardware))")
        }
        if let measuredAt = provenance.measuredAt {
            fields.append("measured_at=\(humanSingleLine(measuredAt))")
        }
        if let notes = provenance.notes {
            fields.append("notes=\(humanSingleLine(notes))")
        }
        return fields.joined(separator: ", ")
    }

    private static func humanSingleLine(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = scalars
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        return String(collapsed.prefix(200))
    }

    private static func humanBenchGateDrift(_ drift: [String]) -> String {
        drift.isEmpty ? "none" : drift.joined(separator: ", ")
    }

    private static func serveConfigJSON(_ core: RecommendationCore, donorMode: Bool) -> String {
        let kvBits = core.knobs.kvBits.map(String.init) ?? "null"
        return """
        {"model":\(core.model.jsonEscaped),"model_artifact_path":\((core.modelArtifactPath ?? "").jsonEscaped),"model_artifact_sha256":\((core.modelArtifactSHA256 ?? "").jsonEscaped),"model_catalog_key":\((core.modelCatalogKey ?? "").jsonEscaped),"model_catalog_model_id":\((core.modelCatalogModelID ?? "").jsonEscaped),"model_catalog_revision":\((core.modelCatalogRevision ?? "").jsonEscaped),"model_catalog_sha256":\((core.modelCatalogSHA256 ?? "").jsonEscaped),"model_catalog_version":\((core.modelCatalogVersion ?? "").jsonEscaped),"model_catalog_hash":\((core.modelCatalogHash ?? "").jsonEscaped),"kv_bits":\(kvBits),"max_context_override":\(core.knobs.maxContext),"max_concurrency_override":\(core.knobs.maxBatch),"donor_mode":\(donorMode)}
        """
    }

    func storedStateJSON(hardwareEvidence: AutotuneHardwareEvidenceSnapshot? = nil) -> String {
        let diagnosticsJSON = probeDiagnostics.keys.sorted().map { key in
            "\(key.jsonEscaped):\(probeDiagnostics[key]!.jsonEscaped)"
        }.joined(separator: ",")
        let evidenceJSON: String
        if let hardwareEvidence {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(hardwareEvidence),
               let encoded = String(data: data, encoding: .utf8) {
                evidenceJSON = encoded
            } else {
                evidenceJSON = "null"
            }
        } else {
            evidenceJSON = "null"
        }
        return """
        {"generated_at":\(ISO8601DateFormatter.autotuneInternet.string(from: generatedAt).jsonEscaped),"rate_card_version":\(rateCardVersion.jsonEscaped),"demand_rank_version":\(demandRankVersion.jsonEscaped),"candidate_catalog_version":\(candidateCatalogVersion.jsonEscaped),"candidate_catalog_sha256":\(candidateCatalogSHA256.jsonEscaped),"benchmark_id":\(benchmarkID?.jsonEscaped ?? "null"),"benchmark_generated_at":\(benchmarkGeneratedAt.map { ISO8601DateFormatter.autotuneInternet.string(from: $0).jsonEscaped } ?? "null"),"binary_version":\(hardware.binaryVersion.jsonEscaped),"hardware_identity_hash":\(hardware.hardwareIdentityHash.jsonEscaped),"recommended_model":\(recommendedModel?.jsonEscaped ?? "null"),"probe_diagnostics":{\(diagnosticsJSON)},"hardware_evidence":\(evidenceJSON)}
        """
    }

    func humanTranscript(configurationApplied: Bool = false) -> String {
        let machineOrChip = hardware.machine ?? hardware.chip
        if let recommendedModel,
           let candidate = selectedCandidate ?? candidates.first(where: { $0.model == recommendedModel }) {
            let nextStep = configurationApplied
                ? "Configuration applied. Start the provider with:\n              macprovider-cli serve"
                : "To apply this recommendation, rerun with --apply. Then start the provider with:\n              macprovider-cli serve"
            return """
            Detected \(machineOrChip), \(hardware.memoryGB) GB unified memory, Tier \(hardware.bandwidthTier.rawValue).
            Benchmarked \(benchmarkedCount) local benchmark results against rate card \(rateCardVersion) and demand rank \(demandRankVersion).

            Recommended: \(recommendedModel)
            Rate: \(formatPerTokenRate(candidate.promptRateUSDPerMillionTokens)) per million prompt tokens
                  \(formatPerTokenRate(candidate.completionRateUSDPerMillionTokens)) per million completion tokens
            Confidence: \(candidate.confidence)
            Bench gate provenance: \(Self.humanBenchGateProvenance(candidate.benchGateProvenance))
            Bench gate drift: \(Self.humanBenchGateDrift(candidate.benchGateDrift))
            Real earnings scale with buyer demand and your uptime.

            \(nextStep)
            """
        }
        let best = donorFallbackModel ?? "none"
        let swapReason: String
        if warnings.contains(.swapObservedUnderLoad) {
            swapReason = "\nAt least one candidate was disqualified because swap was detected under probe load.\n"
        } else {
            swapReason = ""
        }
        return """
        Detected \(machineOrChip), \(hardware.memoryGB) GB unified memory, Tier \(hardware.bandwidthTier.rawValue).
        No catalog model currently fits this Mac for network serving.
        \(swapReason)
        Best compatible option: \(best)
        Recommendation: donor mode only

        You can keep this Mac configured for donor-mode testing, but it is not expected to earn meaningful revenue on the current rate card.
        Enable donor mode? [y/N]
        """
    }

    private func formatPerTokenRate(_ value: Double) -> String {
        String(format: "$%.3f", value)
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
    var hardwareEvidence: AutotuneHardwareEvidenceSnapshot?

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
        case hardwareEvidence = "hardware_evidence"
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
        probeDiagnostics: [String: String] = [:],
        hardwareEvidence: AutotuneHardwareEvidenceSnapshot? = nil
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
        self.hardwareEvidence = hardwareEvidence
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
        hardwareEvidence = try c.decodeIfPresent(AutotuneHardwareEvidenceSnapshot.self, forKey: .hardwareEvidence)
    }
}

enum RecommendationStateStore {
    private enum StoreError: Error {
        case unsafePath
        case ioFailure
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macprovider/last-recommendation.json")
    }

    static func write(
        _ result: AutotuneRecommendResult,
        benchmarks: [String: CandidateBenchmark],
        to url: URL = defaultURL
    ) throws {
        try ensurePrivateParentDirectory(for: url, create: true)
        let evidence = AutotuneHardwareEvidenceSnapshot(result: result, benchmarks: benchmarks)
        guard let data = result.storedStateJSON(hardwareEvidence: evidence).data(using: .utf8) else {
            throw StoreError.ioFailure
        }
        try writePrivateFile(data, to: url)
    }

    static func read(from url: URL = defaultURL) throws -> LastRecommendationState {
        try ensurePrivateParentDirectory(for: url, create: false)
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw StoreError.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o022) == 0
        else {
            try? handle.close()
            throw StoreError.unsafePath
        }
        // Migrate the legacy atomic-write mode (typically 0644) only after an
        // O_NOFOLLOW open and owner/regular-file check. Group/world-writable
        // state is rejected rather than trusted or repaired.
        guard fchmod(fd, 0o600) == 0 else {
            try? handle.close()
            throw StoreError.ioFailure
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        return try JSONDecoder.autotune.decode(LastRecommendationState.self, from: data)
    }

    private static func ensurePrivateParentDirectory(for url: URL, create: Bool) throws {
        let parent = url.deletingLastPathComponent()
        var st = stat()
        if lstat(parent.path, &st) != 0 {
            guard create else { throw StoreError.unsafePath }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            guard lstat(parent.path, &st) == 0 else { throw StoreError.ioFailure }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw StoreError.unsafePath
        }
        guard chmod(parent.path, 0o700) == 0 else { throw StoreError.ioFailure }
    }

    private static func writePrivateFile(_ data: Data, to url: URL) throws {
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == getuid() else {
                throw StoreError.unsafePath
            }
        } else if errno != ENOENT {
            throw StoreError.ioFailure
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw StoreError.ioFailure }
        var closed = false
        defer {
            if !closed { close(fd) }
            _ = unlink(temporary.path)
        }
        guard fchmod(fd, 0o600) == 0 else { throw StoreError.ioFailure }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.ioFailure
                }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw StoreError.ioFailure }
        guard close(fd) == 0 else { throw StoreError.ioFailure }
        closed = true
        guard rename(temporary.path, url.path) == 0 else { throw StoreError.ioFailure }
    }

    static func isStale(stored: LastRecommendationState, current: LastRecommendationState, now: Date) -> Bool {
        // Staleness binds to compatibility inputs — rate card, demand rank, and
        // candidate catalog identity/digest, plus hardware identity and evidence
        // age. `binaryVersion` is the independently-versioned CLI marketing
        // release number and intentionally does not participate here: a
        // software-only version bump with unchanged compat inputs must not
        // invalidate an otherwise-healthy recommendation.
        if stored.rateCardVersion != current.rateCardVersion { return true }
        if stored.demandRankVersion != current.demandRankVersion { return true }
        if stored.candidateCatalogVersion != current.candidateCatalogVersion { return true }
        if stored.candidateCatalogSHA256 != current.candidateCatalogSHA256 { return true }
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
        case trustBlocked(Date?, Set<AutotuneRecommendWarning>)
    }

    func status() async -> Status {
        let stored = try? RecommendationStateStore.read(from: stateURL)
        let inputs = await staticInputs.loadRecommendationInputs()
        let demand = inputs.demand
        let catalog = inputs.candidate
        let rateCard = inputs.rateCard
        let trustWarnings = demand.warnings.union(catalog.warnings).union(rateCard.warnings)
        // Freshness gates network evidence resubmit, so include catalog fallback
        // even though offline recommend diagnostics remain allowed (#582).
        let blockingWarnings = trustWarnings.intersection(AutotuneRecommendEngine.networkSubmissionBlockingWarnings)
        if !blockingWarnings.isEmpty {
            return .trustBlocked(stored?.generatedAt, blockingWarnings)
        }
        guard let stored else { return .missing }
        let secret: Data
        do {
            secret = try AutotuneHMACSecretStore(path: hmacSecretURL).loadOrCreate()
        } catch {
            return .stale(stored.generatedAt)
        }

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
        switch await status() {
        case let .stale(generatedAt):
            return generatedAt
        case let .trustBlocked(generatedAt, _):
            return generatedAt
        case .missing, .fresh:
            return nil
        }
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
        guard let revision = row.modelRevision, row.modelSHA256 != nil else {
            throw AutotuneRecommendError.invalidArtifact("missing revision/hash")
        }
        let snapshot = snapshotURL(modelID: row.modelID, revision: revision)
        var st = stat()
        if lstat(snapshot.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
            do {
                return try verifiedExistingArtifact(for: row)
            } catch let error as AutotuneRecommendError {
                guard case .invalidArtifact(let message) = error else { throw error }

                // A snapshot directory can survive a catalog republish with
                // an old manifest, or be left corrupted by an interrupted
                // external cache operation. Do not keep rejecting it forever:
                // invalidate only this pinned revision and rebuild it through
                // the downloader's staging-directory/atomic-move path.
                do {
                    try FileManager.default.removeItem(at: snapshot)
                } catch {
                    throw AutotuneRecommendError.invalidArtifact(
                        message + "; automatic repair could not remove cached snapshot: " + String(describing: error)
                    )
                }

                do {
                    try await downloader.downloadSnapshot(modelID: row.modelID, revision: revision, to: snapshot)
                } catch {
                    throw AutotuneRecommendError.invalidArtifact(
                        message + "; automatic repair failed: " + String(describing: error)
                    )
                }

                return try verifiedExistingArtifact(for: row)
            }
        }

        try await downloader.downloadSnapshot(modelID: row.modelID, revision: revision, to: snapshot)
        return try verifiedExistingArtifact(for: row)
    }

    /// Acquire a signed artifact without deleting or replacing the incumbent
    /// snapshot. If the canonical revision no longer matches the active
    /// catalog, download into a hash-qualified sibling and leave the prior
    /// provider's restart/rollback path untouched.
    func prefetchedArtifactPreservingExisting(for row: CandidateCatalog.Row) async throws -> VerifiedModelArtifact {
        do {
            return try verifiedExistingArtifact(for: row)
        } catch let error as AutotuneRecommendError {
            guard case .invalidArtifact = error else { throw error }
        }

        guard let revision = row.modelRevision, let expectedSHA256 = row.modelSHA256 else {
            throw AutotuneRecommendError.invalidArtifact("missing revision/hash")
        }
        let prefetched = prefetchSnapshotURL(
            modelID: row.modelID,
            revision: revision,
            sha256: expectedSHA256
        )
        var info = stat()
        if lstat(prefetched.path, &info) == 0 {
            do {
                return try verifiedExistingArtifact(for: row, at: prefetched)
            } catch let error as AutotuneRecommendError {
                guard case .invalidArtifact(let message) = error else { throw error }
                do {
                    try FileManager.default.removeItem(at: prefetched)
                } catch {
                    throw AutotuneRecommendError.invalidArtifact(
                        message + "; automatic prefetch repair could not remove its isolated staging snapshot: "
                            + String(describing: error)
                    )
                }
            }
        }

        do {
            try await downloader.downloadSnapshot(modelID: row.modelID, revision: revision, to: prefetched)
        } catch {
            throw AutotuneRecommendError.invalidArtifact(
                "isolated artifact prefetch failed: " + String(describing: error)
            )
        }
        return try verifiedExistingArtifact(for: row, at: prefetched)
    }

    func verifiedExistingArtifact(for row: CandidateCatalog.Row) throws -> VerifiedModelArtifact {
        guard let revision = row.modelRevision else {
            throw AutotuneRecommendError.invalidArtifact("missing revision/hash")
        }
        return try verifiedExistingArtifact(
            for: row,
            at: snapshotURL(modelID: row.modelID, revision: revision)
        )
    }

    func verifiedExistingArtifact(
        for row: CandidateCatalog.Row,
        at snapshot: URL
    ) throws -> VerifiedModelArtifact {
        guard let revision = row.modelRevision, let expected = row.modelSHA256 else {
            throw AutotuneRecommendError.invalidArtifact("missing revision/hash")
        }
        var st = stat()
        guard lstat(snapshot.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR
        else {
            throw AutotuneRecommendError.invalidArtifact("missing pinned snapshot \(row.modelID)@\(revision)")
        }
        let actual = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        guard actual == expected else {
            throw AutotuneRecommendError.invalidArtifact(
                "hash mismatch \(row.modelID)@\(revision) expected=\(expected) actual=\(actual)"
            )
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

    func prefetchSnapshotURL(modelID: String, revision: String, sha256: String) -> URL {
        snapshotURL(modelID: modelID, revision: revision)
            .deletingLastPathComponent()
            .appendingPathComponent("\(revision).macprovider-prefetch.\(sha256)", isDirectory: true)
    }
}

/// Outcome of running Stage 1 probes across every eligible candidate row.
///
/// `benchmarks` contains only feasible probes (rows admitted into eligibility);
/// `diagnostics` contains a modelKey -> reason string for every candidate that
/// returned .infeasible OR was skipped by runtime-status/RAM/tier gates OR failed
/// artifact verification before Stage 1. This is
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

struct PrefetchedModelArtifact: Codable, Equatable {
    let modelKey: String
    let modelID: String
    let modelRevision: String
    let candidateRowIdentity: String
    let path: String
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case modelKey = "model_key"
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case candidateRowIdentity = "candidate_row_identity"
        case path
        case sha256
    }
}

struct AutotuneArtifactPrefetchReceipt: Codable, Equatable {
    static let currentSchemaVersion = "macprovider.autotune-prefetch-receipt.v1"

    let schemaVersion: String
    let candidateCatalogSHA256: String
    let candidateCatalogVersion: String
    let candidateCatalogPolicyVersion: String
    let artifacts: [PrefetchedModelArtifact]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case candidateCatalogSHA256 = "candidate_catalog_sha256"
        case candidateCatalogVersion = "candidate_catalog_version"
        case candidateCatalogPolicyVersion = "candidate_catalog_policy_version"
        case artifacts
    }

    func write(to url: URL) throws {
        var data = try JSONEncoder.autotunePrefetch.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else {
            throw AutotuneRecommendError.invalidArtifact("could not secure prefetch receipt")
        }
    }

    static func load(from url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_size > 0,
              info.st_size <= 65_536
        else {
            throw AutotuneRecommendError.invalidArtifact("prefetch receipt is not a private owned regular file")
        }
        return try JSONDecoder.autotune.decode(Self.self, from: Data(contentsOf: url))
    }

    func validatedArtifacts(
        candidateCatalog: CandidateCatalog,
        candidateCatalogSHA256: String
    ) throws -> [String: PrefetchedModelArtifact] {
        guard schemaVersion == Self.currentSchemaVersion,
              self.candidateCatalogSHA256 == candidateCatalogSHA256,
              candidateCatalogVersion == candidateCatalog.version,
              candidateCatalogPolicyVersion == candidateCatalog.policyVersion,
              !artifacts.isEmpty,
              artifacts.count <= 64
        else {
            throw AutotuneRecommendError.invalidArtifact("prefetch receipt does not match the active signed catalog")
        }
        var validated: [String: PrefetchedModelArtifact] = [:]
        for artifact in artifacts {
            guard validated[artifact.modelKey] == nil,
                  let row = candidateCatalog.rows[artifact.modelKey],
                  row.modelID == artifact.modelID,
                  row.modelRevision == artifact.modelRevision,
                  row.modelSHA256 == artifact.sha256,
                  candidateCatalog.rowIdentity(for: artifact.modelKey) == artifact.candidateRowIdentity,
                  artifact.path.hasPrefix("/"),
                  URL(fileURLWithPath: artifact.path).standardizedFileURL.path == artifact.path
            else {
                throw AutotuneRecommendError.invalidArtifact(
                    "prefetch receipt row no longer matches the active signed catalog"
                )
            }
            validated[artifact.modelKey] = artifact
        }
        return validated
    }
}

struct PrefetchDiagnostic: Equatable {
    let modelID: String
    let reason: String
}

struct ArtifactPrefetchOutcomes: Equatable {
    var artifacts: [PrefetchedModelArtifact]
    var diagnostics: [PrefetchDiagnostic]
    var matchedModelIDs: Set<String>

    var prefetchedModelIDs: Set<String> {
        Set(artifacts.map(\.modelID))
    }
}

struct AutotuneRecommendationBenchmarker {
    var artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver()
    var runnerFactory: () throws -> CandidateProviderRunner = { try CandidateProviderRunner() }
    var prober: any Stage1Probing = Stage1Prober()
    var safetySampler: ProbeSafetySampling = SystemProbeSafetySampler()
    var clock: () -> Date = Date.init

    func prefetchArtifacts(
        candidateCatalog: CandidateCatalog,
        hardware: AutotuneRecommendHardware,
        candidateModelIDs: Set<String>
    ) async throws -> ArtifactPrefetchOutcomes {
        var matchedModelKeysByID: [String: [String]] = [:]
        for modelKey in candidateCatalog.rows.keys.sorted() {
            guard let row = candidateCatalog.rows[modelKey], candidateModelIDs.contains(row.modelID) else {
                continue
            }
            matchedModelKeysByID[row.modelID, default: []].append(modelKey)
        }
        let ambiguousMatches = matchedModelKeysByID
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { modelID, modelKeys in
                "\(modelID) [\(modelKeys.joined(separator: ", "))]"
            }
        guard ambiguousMatches.isEmpty else {
            throw AutotuneRecommendError.invalidArtifact(
                "each prefetch model must match exactly one signed catalog row; duplicate matches: "
                    + ambiguousMatches.joined(separator: "; ")
            )
        }

        var artifacts: [PrefetchedModelArtifact] = []
        var diagnostics: [PrefetchDiagnostic] = []
        var matchedModelIDs = Set<String>()
        for modelKey in candidateCatalog.rows.keys.sorted() {
            guard let row = candidateCatalog.rows[modelKey], candidateModelIDs.contains(row.modelID) else {
                continue
            }
            matchedModelIDs.insert(row.modelID)
            if let reason = Self.ineligibilityReason(row: row, hardware: hardware) {
                diagnostics.append(PrefetchDiagnostic(modelID: row.modelID, reason: reason))
                continue
            }
            do {
                guard let revision = row.modelRevision,
                      let rowIdentity = candidateCatalog.rowIdentity(for: modelKey)
                else {
                    diagnostics.append(PrefetchDiagnostic(modelID: row.modelID, reason: "missing signed artifact identity"))
                    continue
                }
                let artifact = try await artifactResolver.prefetchedArtifactPreservingExisting(for: row)
                artifacts.append(PrefetchedModelArtifact(
                    modelKey: modelKey,
                    modelID: row.modelID,
                    modelRevision: revision,
                    candidateRowIdentity: rowIdentity,
                    path: artifact.modelArgument,
                    sha256: artifact.sha256
                ))
            } catch let error as AutotuneRecommendError {
                guard case .invalidArtifact(let message) = error else { throw error }
                diagnostics.append(PrefetchDiagnostic(modelID: row.modelID, reason: message))
            }
        }
        return ArtifactPrefetchOutcomes(
            artifacts: artifacts,
            diagnostics: diagnostics,
            matchedModelIDs: matchedModelIDs
        )
    }

    func benchmarks(
        request: AutotuneRecommendRequest,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int,
        port: Int,
        interruptFlag: AutotuneInterruptFlag? = nil,
        candidateModelIDs: Set<String>? = nil,
        prefetchedArtifacts: [String: PrefetchedModelArtifact]? = nil
    ) async throws -> BenchmarkOutcomes {
        var results: [String: CandidateBenchmark] = [:]
        var diagnostics: [String: String] = [:]
        for modelKey in request.candidateCatalog.rows.keys.sorted() {
            // ARCH-M-1: Between candidates, honor SIGTERM/SIGINT so we don't
            // race into a fresh subprocess spawn after the App has torn the
            // group down. The cascading signal handler will already have sent
            // SIGTERM to any currently-running `serve --no-join` child.
            if interruptFlag?.isSet() == true {
                diagnostics[modelKey] = "interrupted before probe"
                break
            }
            guard let row = request.candidateCatalog.rows[modelKey] else {
                continue
            }
            if let candidateModelIDs, !candidateModelIDs.contains(row.modelID) {
                continue
            }
            if let reason = Self.ineligibilityReason(row: row, hardware: request.hardware) {
                diagnostics[modelKey] = reason
                continue
            }
            do {
                let artifact: VerifiedModelArtifact
                if let prefetchedArtifacts {
                    guard let prefetched = prefetchedArtifacts[modelKey] else {
                        throw AutotuneRecommendError.invalidArtifact(
                            "prefetch receipt is missing the selected catalog row \(modelKey)"
                        )
                    }
                    artifact = try artifactResolver.verifiedExistingArtifact(
                        for: row,
                        at: URL(fileURLWithPath: prefetched.path)
                    )
                    guard artifact.sha256 == prefetched.sha256,
                          artifact.modelArgument == prefetched.path
                    else {
                        throw AutotuneRecommendError.invalidArtifact(
                            "prefetched artifact binding changed for \(modelKey)"
                        )
                    }
                } else {
                    artifact = try await artifactResolver.verifiedArtifact(for: row)
                }
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
                    if let invalidDiagnostic = Self.invalidFeasibleDiagnostic(
                        medianTPS: medianTPS,
                        p95TTFTMS: p95TTFTMS
                    ) {
                        if prefetchedArtifacts != nil {
                            throw AutotuneRecommendError.candidateProbeFailed(
                                modelKey: modelKey,
                                reason: invalidDiagnostic
                            )
                        }
                        diagnostics[modelKey] = invalidDiagnostic
                        continue
                    }
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
                        hardwareIdentityHash: request.hardware.hardwareIdentityHash,
                        candidateRowIdentity: request.candidateCatalog.rowIdentity(for: modelKey) ?? ""
                    )
                    if safety.swapDetected || safety.thermalThrottleDetected {
                        var flags: [String] = []
                        if safety.swapDetected { flags.append("swap detected") }
                        if safety.thermalThrottleDetected { flags.append("thermal throttle detected") }
                        diagnostics[modelKey] = "feasible but " + flags.joined(separator: ", ")
                    }
                case .infeasible(let reason, let nErr):
                    let diagnostic = "\(reason) (n_err=\(nErr))"
                    if prefetchedArtifacts != nil {
                        throw AutotuneRecommendError.candidateProbeFailed(
                            modelKey: modelKey,
                            reason: diagnostic
                        )
                    }
                    diagnostics[modelKey] = diagnostic
                }
            } catch let error as AutotuneRecommendError {
                if prefetchedArtifacts != nil {
                    throw error
                }
                if case .invalidArtifact(let message) = error {
                    diagnostics[modelKey] = message
                    continue
                }
                throw error
            }
        }
        return BenchmarkOutcomes(benchmarks: results, diagnostics: diagnostics)
    }

    private static func ineligibilityReason(
        row: CandidateCatalog.Row,
        hardware: AutotuneRecommendHardware
    ) -> String? {
        if row.runtimeStatus == "blocked" {
            return "catalog row blocked pending migration validation/rate-card rollout"
        }
        if row.minRAMGB > hardware.memoryGB - AutotuneRecommendEngine.safetyMarginGB {
            return "min_ram \(row.minRAMGB)GB exceeds \(hardware.memoryGB)GB - \(AutotuneRecommendEngine.safetyMarginGB)GB safety margin"
        }
        if !hardware.bandwidthTier.satisfies(minimum: row.minBandwidthTier) {
            return "bandwidth tier \(hardware.bandwidthTier.rawValue) below minimum \(row.minBandwidthTier.rawValue)"
        }
        return nil
    }

    private static func invalidFeasibleDiagnostic(
        medianTPS: Double,
        p95TTFTMS: Double
    ) -> String? {
        guard medianTPS.isFinite, medianTPS > 0 else {
            return "Stage 1 probe produced invalid feasible throughput \(diagnosticNumber(medianTPS))"
        }
        guard p95TTFTMS.isFinite, p95TTFTMS >= 0, p95TTFTMS <= Double(Int32.max) else {
            return "Stage 1 probe produced invalid feasible TTFT \(diagnosticNumber(p95TTFTMS))ms"
        }
        return nil
    }

    private static func diagnosticNumber(_ value: Double) -> String {
        if value.isNaN {
            return "nan"
        }
        if value == .infinity {
            return "infinity"
        }
        if value == -.infinity {
            return "-infinity"
        }
        return value.jsonNumber
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

private extension JSONEncoder {
    static var autotunePrefetch: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
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

    var canonicalProjectionJSONNumber: String {
        if isFinite {
            if rounded() == self, self >= Double(Int64.min), self <= Double(Int64.max) {
                return String(Int64(self))
            }
            return String(format: "%.15f", self).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
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
