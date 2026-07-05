import Foundation
import MacProviderCore

enum AutotuneHardwareEvidenceSubmission: Equatable {
    case submitted
    case skipped(String)
    case failed(String)
}

struct AutotuneHardwareEvidenceSubmitter {
    static let endpointPath = "/v1/providers/hardware-evidence"

    var config: AppConfig?
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }()

    func submit(result: AutotuneRecommendResult, benchmarks: [String: CandidateBenchmark]) async -> AutotuneHardwareEvidenceSubmission {
        guard let config else { return .skipped("config unavailable") }
        guard let providerID = trimmedNonEmpty(config.providerID) else { return .skipped("provider_id missing") }
        guard let providerToken = trimmedNonEmpty(config.providerToken) else { return .skipped("provider_token missing") }
        guard let coordinatorURL = trimmedNonEmpty(config.coordinatorURL),
              let endpoint = Self.hardwareEvidenceEndpoint(from: coordinatorURL)
        else {
            return .skipped("coordinator_url missing")
        }
        do {
            let payload = try Self.payloadData(providerID: providerID, result: result, benchmarks: benchmarks)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(providerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("non-HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .submitted
            }
            return .failed("HTTP \(http.statusCode)")
        } catch {
            return .failed("\(error)")
        }
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
        let payload = HardwareEvidencePayload(
            schemaVersion: "hardware_evidence.autotune.v1",
            providerID: providerID,
            generatedAt: ISO8601DateFormatter.autotuneInternet.string(from: result.generatedAt),
            hardware: HardwarePayload(
                chip: result.hardware.chip,
                memoryGB: result.hardware.memoryGB,
                bandwidthTier: result.hardware.bandwidthTier.rawValue,
                detected: result.hardware.detected,
                osVersion: result.hardware.osVersion,
                binaryVersion: result.hardware.binaryVersion,
                hardwareIdentityHash: result.hardware.hardwareIdentityHash
            ),
            candidateCatalogSHA256: result.candidateCatalogSHA256,
            recommendedModel: result.recommendedModel,
            benchmarks: benchmarks.keys.sorted().map { key in
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
                    benchmarkID: benchmark.benchmarkID,
                    generatedAt: ISO8601DateFormatter.autotuneInternet.string(from: benchmark.generatedAt),
                    binaryVersion: benchmark.binaryVersion,
                    hardwareIdentityHash: benchmark.hardwareIdentityHash
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct HardwareEvidencePayload: Encodable {
    var schemaVersion: String
    var providerID: String
    var generatedAt: String
    var hardware: HardwarePayload
    var candidateCatalogSHA256: String
    var recommendedModel: String?
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

private struct HardwarePayload: Encodable {
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

private struct BenchmarkPayload: Encodable {
    var modelKey: String
    var modelID: String
    var sustainedTPS: Double
    var ttftMS: Int
    var swapDetected: Bool
    var thermalThrottleDetected: Bool
    var artifactSHA256: String
    var candidateCatalogSHA256: String
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
        case benchmarkID = "benchmark_id"
        case generatedAt = "generated_at"
        case binaryVersion = "binary_version"
        case hardwareIdentityHash = "hardware_identity_hash"
    }
}
