import CryptoKit
import Foundation
import MacProviderCore

enum AutotuneHardwareEvidenceSubmission: Equatable {
    case submitted
    case skipped(String)
    case failed(String)
}

struct AutotuneHardwareEvidenceSubmitter {
    static let endpointPath = "/v1/providers/hardware-evidence"
    static let acceptedResponseStatuses: Set<String> = ["queued", "existing", "verified"]

    var config: AppConfig?
    var credentialStore: any ProviderCredentialStoring = KeychainProviderCredentialStore()
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }()

    func submit(result: AutotuneRecommendResult, benchmarks: [String: CandidateBenchmark]) async -> AutotuneHardwareEvidenceSubmission {
        // Refuse network submit when recommend used baked-catalog fallback or
        // other submission-blocking trust warnings (#582).
        if AutotuneRecommendEngine.networkSubmissionBlocks(Set(result.warnings)) {
            return .failed(AutotuneRecommendEngine.networkSubmissionBlockMessage(Set(result.warnings)))
        }
        return await submit(snapshot: AutotuneHardwareEvidenceSnapshot(result: result, benchmarks: benchmarks))
    }

    func submit(snapshot: AutotuneHardwareEvidenceSnapshot) async -> AutotuneHardwareEvidenceSubmission {
        guard var config else { return .skipped("config unavailable") }
        // First-install bootstrap deliberately leaves YAML tokenless. Resolve
        // CLI Keychain custody here so both initial and freshness submissions
        // use the same restart-safe credential boundary as `serve`.
        let credentialStatus: ProviderCredentialStatus
        do {
            credentialStatus = try ProviderCredentialResolver.resolve(
                config: &config,
                store: credentialStore
            )
        } catch {
            return .failed("provider credential resolution failed")
        }
        guard credentialStatus.source == .cliKeychain,
              credentialStatus.state == .ready,
              credentialStatus.restartSafe else {
            return .failed(Self.credentialUnavailableReason(credentialStatus))
        }
        guard let providerID = trimmedNonEmpty(config.providerID) else { return .skipped("provider_id missing") }
        guard let providerToken = trimmedNonEmpty(config.providerToken) else {
            return .failed("provider credential unavailable (condition=missing action=restore_or_reenroll)")
        }
        guard let coordinatorURL = trimmedNonEmpty(config.coordinatorURL),
              let endpoint = Self.hardwareEvidenceEndpoint(from: coordinatorURL)
        else {
            return .skipped("coordinator_url missing")
        }
        do {
            let payload = try Self.canonicalPayload(
                providerID: providerID,
                snapshot: snapshot
            )
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(providerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload.data
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("non-HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return Self.validateSuccessResponse(
                    responseData,
                    expectedProviderID: providerID,
                    expectedEvidenceSHA: payload.evidenceSHA
                )
            }
            return .failed("HTTP \(http.statusCode)")
        } catch {
            return .failed("\(error)")
        }
    }

    static func credentialUnavailableReason(_ status: ProviderCredentialStatus) -> String {
        "provider credential unavailable (condition=\(status.state.rawValue) action=\(status.recoveryAction.rawValue))"
    }

    static func hardwareEvidenceEndpoint(from raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss":
            components.scheme = "https"
        case "https":
            break
        default:
            return nil
        }
        components.path = endpointPath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func payloadData(providerID: String, result: AutotuneRecommendResult, benchmarks: [String: CandidateBenchmark]) throws -> Data {
        try payloadData(
            providerID: providerID,
            snapshot: AutotuneHardwareEvidenceSnapshot(result: result, benchmarks: benchmarks)
        )
    }

    static func payloadData(
        providerID: String,
        snapshot: AutotuneHardwareEvidenceSnapshot
    ) throws -> Data {
        try canonicalPayload(providerID: providerID, snapshot: snapshot).data
    }

    static func canonicalPayload(
        providerID: String,
        snapshot: AutotuneHardwareEvidenceSnapshot
    ) throws -> (data: Data, evidenceSHA: String) {
        let payload = HardwareEvidencePayload(
            schemaVersion: "hardware_evidence.autotune.v1",
            providerID: providerID,
            generatedAt: snapshot.generatedAt,
            hardware: snapshot.hardware,
            candidateCatalogSHA256: snapshot.candidateCatalogSHA256,
            recommendedModel: snapshot.recommendedModel ?? "",
            benchmarks: snapshot.benchmarks
        )
        let data = Data(try RFC8785JCS.canonicalString(payload.canonicalValue).utf8)
        let evidenceSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, evidenceSHA)
    }

    static func validateSuccessResponse(
        _ data: Data,
        expectedProviderID: String,
        expectedEvidenceSHA: String
    ) -> AutotuneHardwareEvidenceSubmission {
        let expectedKeys: Set<String> = ["status", "provider_id", "job_id", "evidence_sha"]
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == expectedKeys,
              let decoded = try? JSONDecoder().decode(HardwareEvidenceSubmissionResponse.self, from: data)
        else {
            return .failed("invalid success response")
        }
        guard acceptedResponseStatuses.contains(decoded.status) else {
            return .failed("unexpected success status")
        }
        guard decoded.providerID == expectedProviderID else {
            return .failed("success response provider_id mismatch")
        }
        guard decoded.jobID > 0 else {
            return .failed("success response job_id invalid")
        }
        guard decoded.evidenceSHA == expectedEvidenceSHA else {
            return .failed("success response evidence_sha mismatch")
        }
        return .submitted
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// The verifier-relevant output of an autotune run. Keeping this next to the
/// freshness state lets an update resubmit the exact same measurement without
/// downloading models or repeating benchmarks. `generatedAt` is immutable: a
/// transport retry must not make stale or rebound measurements appear current.
struct AutotuneHardwareEvidenceSnapshot: Codable, Equatable {
    var generatedAt: String
    var hardware: HardwarePayload
    var candidateCatalogSHA256: String
    var recommendedModel: String?
    var benchmarks: [BenchmarkPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case hardware
        case candidateCatalogSHA256 = "candidate_catalog_sha256"
        case recommendedModel = "recommended_model"
        case benchmarks
    }

    init(result: AutotuneRecommendResult, benchmarks: [String: CandidateBenchmark]) {
        generatedAt = ISO8601DateFormatter.autotuneInternet.string(from: result.generatedAt)
        hardware = HardwarePayload(
            chip: result.hardware.chip,
            memoryGB: result.hardware.memoryGB,
            bandwidthTier: result.hardware.bandwidthTier.rawValue,
            detected: result.hardware.detected,
            osVersion: result.hardware.osVersion,
            binaryVersion: result.hardware.binaryVersion,
            hardwareIdentityHash: result.hardware.hardwareIdentityHash
        )
        candidateCatalogSHA256 = result.candidateCatalogSHA256
        recommendedModel = result.recommendedModel
        self.benchmarks = benchmarks.keys.sorted().map { key in
            let benchmark = benchmarks[key]!
            return BenchmarkPayload(
                modelKey: benchmark.modelKey,
                modelID: benchmark.modelID,
                sustainedTPS: benchmark.sustainedTPS,
                ttftMS: benchmark.ttftMS,
                swapDetected: benchmark.swapDetected,
                thermalThrottleDetected: benchmark.thermalThrottleDetected,
                artifactSHA256: benchmark.artifactSHA256,
                candidateCatalogSHA256: benchmark.candidateCatalogSHA256,
                candidateRowIdentity: benchmark.candidateRowIdentity.isEmpty ? nil : benchmark.candidateRowIdentity,
                benchmarkID: benchmark.benchmarkID,
                generatedAt: ISO8601DateFormatter.autotuneInternet.string(from: benchmark.generatedAt),
                binaryVersion: benchmark.binaryVersion,
                hardwareIdentityHash: benchmark.hardwareIdentityHash
            )
        }
    }
}

private struct HardwareEvidencePayload: Encodable {
    var schemaVersion: String
    var providerID: String
    var generatedAt: String
    var hardware: HardwarePayload
    var candidateCatalogSHA256: String
    var recommendedModel: String
    var benchmarks: [BenchmarkPayload]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case providerID = "provider_id"
        case generatedAt = "generated_at"
        case hardware
        case candidateCatalogSHA256 = "candidate_catalog_sha256"
        case recommendedModel = "recommended_model"
        case benchmarks
    }
}

private struct HardwareEvidenceSubmissionResponse: Decodable {
    var status: String
    var providerID: String
    var jobID: Int64
    var evidenceSHA: String

    enum CodingKeys: String, CodingKey {
        case status
        case providerID = "provider_id"
        case jobID = "job_id"
        case evidenceSHA = "evidence_sha"
    }
}

private extension HardwareEvidencePayload {
    var canonicalValue: RFC8785JCS.Value {
        .object([
            "schema_version": .string(schemaVersion),
            "provider_id": .string(providerID),
            "generated_at": .string(generatedAt),
            "hardware": hardware.canonicalValue,
            "candidate_catalog_sha256": .string(candidateCatalogSHA256),
            "recommended_model": .string(recommendedModel),
            "benchmarks": .array(benchmarks.map(\.canonicalValue)),
        ])
    }
}

private extension HardwarePayload {
    var canonicalValue: RFC8785JCS.Value {
        .object([
            "chip": .string(chip),
            "memory_gb": .int(memoryGB),
            "bandwidth_tier": .string(bandwidthTier),
            "detected": .bool(detected),
            "os_version": .string(osVersion),
            "binary_version": .string(binaryVersion),
            "hardware_identity_hash": .string(hardwareIdentityHash),
        ])
    }
}

private extension BenchmarkPayload {
    var canonicalValue: RFC8785JCS.Value {
        var object: [String: RFC8785JCS.Value] = [
            "model_key": .string(modelKey),
            "model_id": .string(modelID),
            "sustained_tps": .double(sustainedTPS),
            "ttft_ms": .int(ttftMS),
            "swap_detected": .bool(swapDetected),
            "thermal_throttle_detected": .bool(thermalThrottleDetected),
            "artifact_sha256": .string(artifactSHA256),
            "candidate_catalog_sha256": .string(candidateCatalogSHA256),
            "generated_at": .string(generatedAt),
            "binary_version": .string(binaryVersion),
            "hardware_identity_hash": .string(hardwareIdentityHash),
        ]
        if let benchmarkID {
            object["benchmark_id"] = .string(benchmarkID)
        }
        if let candidateRowIdentity, !candidateRowIdentity.isEmpty {
            object["candidate_row_identity"] = .string(candidateRowIdentity)
        }
        return .object(object)
    }
}

struct HardwarePayload: Codable, Equatable {
    var chip: String
    var memoryGB: Int
    var bandwidthTier: String
    var detected: Bool
    var osVersion: String
    var binaryVersion: String
    var hardwareIdentityHash: String

    enum CodingKeys: String, CodingKey {
        case chip
        case memoryGB = "memory_gb"
        case bandwidthTier = "bandwidth_tier"
        case detected
        case osVersion = "os_version"
        case binaryVersion = "binary_version"
        case hardwareIdentityHash = "hardware_identity_hash"
    }
}

struct BenchmarkPayload: Codable, Equatable {
    var modelKey: String
    var modelID: String
    var sustainedTPS: Double
    var ttftMS: Int
    var swapDetected: Bool
    var thermalThrottleDetected: Bool
    var artifactSHA256: String
    var candidateCatalogSHA256: String
    var candidateRowIdentity: String?
    var benchmarkID: String?
    var generatedAt: String
    var binaryVersion: String
    var hardwareIdentityHash: String

    enum CodingKeys: String, CodingKey {
        case modelKey = "model_key"
        case modelID = "model_id"
        case sustainedTPS = "sustained_tps"
        case ttftMS = "ttft_ms"
        case swapDetected = "swap_detected"
        case thermalThrottleDetected = "thermal_throttle_detected"
        case artifactSHA256 = "artifact_sha256"
        case candidateCatalogSHA256 = "candidate_catalog_sha256"
        case candidateRowIdentity = "candidate_row_identity"
        case benchmarkID = "benchmark_id"
        case generatedAt = "generated_at"
        case binaryVersion = "binary_version"
        case hardwareIdentityHash = "hardware_identity_hash"
    }
}
