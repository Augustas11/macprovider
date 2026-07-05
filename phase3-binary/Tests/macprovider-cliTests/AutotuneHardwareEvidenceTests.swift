import Foundation
@testable import macprovider_cli
import XCTest

final class AutotuneHardwareEvidenceTests: XCTestCase {
    func testEndpointConvertsCoordinatorWebSocketURL() {
        let url = AutotuneHardwareEvidenceSubmitter.hardwareEvidenceEndpoint(
            from: "wss://coordinator.streamvc.live/v2/provider?x=1"
        )
        XCTAssertEqual(url?.absoluteString, "https://coordinator.streamvc.live/v1/providers/hardware-evidence")
    }

    func testEndpointRejectsCleartextCoordinatorURL() {
        XCTAssertNil(AutotuneHardwareEvidenceSubmitter.hardwareEvidenceEndpoint(from: "http://coordinator.streamvc.live/v2/provider"))
        XCTAssertNil(AutotuneHardwareEvidenceSubmitter.hardwareEvidenceEndpoint(from: "ws://coordinator.streamvc.live/v2/provider"))
    }

    func testPayloadIncludesHardwareAndBenchmarks() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let result = AutotuneRecommendResult(
            generatedAt: generatedAt,
            hardware: AutotuneRecommendHardware(
                machine: nil,
                chip: "Apple M5",
                memoryGB: 32,
                bandwidthTier: .c,
                osVersion: "15.5",
                binaryVersion: "1.7.9",
                diversificationID: "div",
                hardwareIdentityHash: "hash"
            ),
            rateCardVersion: "rates.v1",
            demandRankVersion: "demand.v1",
            candidateCatalogVersion: "catalog.v1",
            candidateCatalogSHA256: String(repeating: "a", count: 64),
            benchmarkID: nil,
            benchmarkGeneratedAt: nil,
            recommendedModel: "model-a",
            selectedCandidate: nil,
            candidates: [],
            defaultModel: nil,
            donorFallbackModel: nil,
            donorFallbackCandidate: nil,
            donorFallbackNetUSDPerHour: nil,
            recommendedDeltaUSDPerHour: 0,
            recommendedDeltaPercent: 0,
            warnings: [],
            assumedUtilization: 1,
            availabilityHoursPerDay: 24,
            electricityUSDPerKWH: nil
        )
        let benchmark = CandidateBenchmark(
            modelKey: "model-a",
            sustainedTPS: 42.5,
            ttftMS: 1200,
            swapDetected: false,
            thermalThrottleDetected: false,
            artifactSHA256: String(repeating: "b", count: 64),
            modelArtifactPath: "/tmp/model",
            benchmarkID: "bench-1",
            generatedAt: generatedAt,
            candidateCatalogSHA256: String(repeating: "a", count: 64),
            binaryVersion: "1.7.9",
            modelID: "mlx-community/model-a",
            hardwareIdentityHash: "hash"
        )

        let data = try AutotuneHardwareEvidenceSubmitter.payloadData(
            providerID: "mac",
            result: result,
            benchmarks: ["model-a": benchmark]
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schema_version"] as? String, "hardware_evidence.autotune.v1")
        XCTAssertEqual(object?["provider_id"] as? String, "mac")
        let hardware = object?["hardware"] as? [String: Any]
        XCTAssertEqual(hardware?["chip"] as? String, "Apple M5")
        XCTAssertEqual(hardware?["memory_gb"] as? Int, 32)
        let benchmarks = object?["benchmarks"] as? [[String: Any]]
        XCTAssertEqual(benchmarks?.first?["model_key"] as? String, "model-a")
        XCTAssertEqual(benchmarks?.first?["sustained_tps"] as? Double, 42.5)
    }
}
