import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// #1689 slice 1a: operator-facing provenance for the advertised context cap
/// and the startup throughput probe. Additive and capability-gated; the
/// existing `capacity` keys and `throughput_tps_estimate` semantics are
/// unchanged.
final class CapacityProvenanceTests: XCTestCase {
    // MARK: - Max context source resolution

    func testMaxContextSourceIsNilWhenNothingOverridesTheRAMTierDefault() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in false },
            readFile: { _ in "" }
        )
        XCTAssertNil(config.maxContextOverride)
        XCTAssertNil(config.maxContextSource)
    }

    func testMaxContextSourceRecordsOperatorConfig() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "max_context_override: 4096\n" }
        )
        XCTAssertEqual(config.maxContextOverride, 4096)
        XCTAssertEqual(config.maxContextSource, .operatorConfig)
    }

    func testMaxContextSourceRecordsEnvironmentOverConfig() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_MAX_CONTEXT_OVERRIDE": "16384"],
            fileExists: { _ in true },
            readFile: { _ in "max_context_override: 4096\n" }
        )
        XCTAssertEqual(config.maxContextOverride, 16384)
        XCTAssertEqual(config.maxContextSource, .environment)
    }

    func testMaxContextSourceRecordsCLIFlagOverEnvironmentAndConfig() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(maxContext: 8192),
            environment: ["MACPROVIDER_MAX_CONTEXT_OVERRIDE": "16384"],
            fileExists: { _ in true },
            readFile: { _ in "max_context_override: 4096\n" }
        )
        XCTAssertEqual(config.maxContextOverride, 8192)
        XCTAssertEqual(config.maxContextSource, .cliFlag)
    }

    func testDraftClampRecordsDraftClampWhenItLowersTheImplicitDefault() throws {
        var config = AppConfig.defaults()
        config.draftModel = "/models/draft"

        try ServeCommand.runSpecDecodeCapacityPreflight(&config)

        XCTAssertEqual(config.maxContextOverride, ProviderCapacity.draftContextCapForCurrentHost())
        XCTAssertEqual(config.maxContextSource, .draftClamp)
    }

    func testDraftClampKeepsExplicitSourceWhenItDoesNotLowerTheValue() throws {
        var config = AppConfig.defaults()
        config.draftModel = "/models/draft"
        config.maxContextOverride = 1_000
        config.maxContextSource = .cliFlag

        try ServeCommand.runSpecDecodeCapacityPreflight(&config)

        XCTAssertEqual(config.maxContextOverride, 1_000)
        XCTAssertEqual(config.maxContextSource, .cliFlag)
    }

    func testProviderCapacityReportsRAMTierDefaultWithoutOverride() {
        let capacity = ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
        XCTAssertEqual(capacity.maxContextSource, .ramTierDefault)
        XCTAssertNil(capacity.throughputProbe)
    }

    func testThroughputEstimatePreservesContextSourceAndRecordsProbe() {
        let base = ProviderCapacity(
            maxContextOverride: 4096,
            maxConcurrencyOverride: 2,
            maxContextSource: .cliFlag
        )
        let probe = StartupThroughputProbe(maxTokens: 8, modelID: "model-a")
        let measured = base.withThroughputEstimate(12.5, probe: probe)

        XCTAssertEqual(measured.maxContextTokens, 4096)
        XCTAssertEqual(measured.maxConcurrency, 2)
        XCTAssertEqual(measured.maxContextSource, .cliFlag)
        XCTAssertEqual(measured.throughputTPSEstimate, 12.5)
        XCTAssertEqual(measured.throughputProbe, probe)
    }

    func testServeProbeUsesTheSharedProbeTokenBudget() {
        XCTAssertEqual(ModelRuntime.startupThroughputProbeMaxTokens, 8)
    }

    // MARK: - /v1/status wire

    func testStatusResponseEmitsAdditiveCapacityProvenanceAndCapability() async throws {
        let capacity = ProviderCapacity(
            maxContextOverride: 4096,
            maxConcurrencyOverride: 2,
            maxContextSource: .operatorConfig
        ).withThroughputEstimate(12.5, probe: StartupThroughputProbe(maxTokens: 8, modelID: "model-a"))
        let status = ProviderStatus(modelID: "model-a", modelLoaded: true, capacity: capacity)
        let body = RouterHandler.statusResponse(await status.snapshot(), providerID: "provider-a", coordinatorURL: nil)

        let contract = try XCTUnwrap(body["local_status_contract"] as? [String: Any])
        let capabilities = try XCTUnwrap(contract["capabilities"] as? [String])
        XCTAssertTrue(capabilities.contains("capacity_provenance_v1"))

        let wire = try XCTUnwrap(body["capacity"] as? [String: Any])
        XCTAssertEqual(
            Set(wire.keys),
            [
                "ram_gb", "ram_tier", "max_context_tokens", "max_concurrency", "throughput_tps_estimate",
                "max_context_source", "throughput_source", "throughput_probe_max_tokens", "throughput_probe_model",
            ]
        )
        XCTAssertEqual(wire["max_context_tokens"] as? Int, 4096)
        XCTAssertEqual(wire["max_concurrency"] as? Int, 2)
        XCTAssertEqual(wire["throughput_tps_estimate"] as? Double, 12.5)
        XCTAssertEqual(wire["max_context_source"] as? String, "operator_config")
        XCTAssertEqual(wire["throughput_source"] as? String, "startup_probe")
        XCTAssertEqual(wire["throughput_probe_max_tokens"] as? Int, 8)
        XCTAssertEqual(wire["throughput_probe_model"] as? String, "model-a")
    }

    func testStatusResponseReportsNoProbeWhenNoneRan() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
        )
        let body = RouterHandler.statusResponse(await status.snapshot(), providerID: "provider-a", coordinatorURL: nil)
        let wire = try XCTUnwrap(body["capacity"] as? [String: Any])

        XCTAssertEqual(wire["max_context_source"] as? String, "ram_tier_default")
        XCTAssertEqual(wire["throughput_source"] as? String, "none")
        XCTAssertTrue(wire["throughput_probe_max_tokens"] is NSNull)
        XCTAssertTrue(wire["throughput_probe_model"] is NSNull)
        XCTAssertEqual(wire["throughput_tps_estimate"] as? Double, 0)
    }

    func testWarmSwapKeepsProbeEvidenceOfThePreviousModel() async throws {
        let capacity = ProviderCapacity(maxContextOverride: 4096, maxConcurrencyOverride: 1, maxContextSource: .cliFlag)
            .withThroughputEstimate(20, probe: StartupThroughputProbe(maxTokens: 8, modelID: "model-a"))
        let status = ProviderStatus(modelID: "model-a", modelLoaded: true, capacity: capacity)

        await status.completeTargetSwap(modelID: "model-b", modelHash: nil)
        let body = RouterHandler.statusResponse(await status.snapshot(), providerID: "provider-a", coordinatorURL: nil)
        let wire = try XCTUnwrap(body["capacity"] as? [String: Any])

        XCTAssertEqual(body["model"] as? String, "model-b")
        XCTAssertEqual(wire["throughput_tps_estimate"] as? Double, 20)
        XCTAssertEqual(wire["throughput_probe_model"] as? String, "model-a")
        XCTAssertEqual(wire["max_context_source"] as? String, "cli_flag")
    }

    func testWarmSwapAdoptionContextRecordsRecommendationAdoption() async throws {
        let capacity = ProviderCapacity(maxContextOverride: 4096, maxConcurrencyOverride: 1, maxContextSource: .cliFlag)
            .withThroughputEstimate(20, probe: StartupThroughputProbe(maxTokens: 8, modelID: "model-a"))
        let status = ProviderStatus(modelID: "model-a", modelLoaded: true, capacity: capacity)

        await status.completeTargetSwap(modelID: "model-b", modelHash: nil, maxContextTokens: 2048, maxConcurrency: 2)
        let snapshot = await status.snapshot()

        XCTAssertEqual(snapshot.capacity.maxContextTokens, 2048)
        XCTAssertEqual(snapshot.capacity.maxContextSource, .recommendationAdoption)
        XCTAssertEqual(snapshot.capacity.throughputProbe?.modelID, "model-a")
    }

    // MARK: - status --advanced

    func testAdvancedStatusShowsReadinessLayersSeparately() {
        var payload = status()
        payload["network_state"] = "not_buyer_serving"
        payload["buyer_serving_hold"] = "tier2_hold"
        payload["catalog"] = ["state": "live_verified"]
        payload["lifecycle"] = ["state": "ready", "reason_code": "model_loaded"]

        let output = LocalStatusFormatter.format(payload, advanced: true)

        XCTAssertTrue(output.contains("Readiness:"), output)
        XCTAssertTrue(output.contains("Local inference: ready (model loaded; reason model_loaded)"), output)
        XCTAssertTrue(output.contains("Coordinator:     connected (tier 2, session provider-a)"), output)
        XCTAssertTrue(output.contains("Network:         not_buyer_serving (hold: tier2_hold)"), output)
        XCTAssertTrue(output.contains("Catalog trust:   live_verified"), output)
    }

    func testAdvancedStatusLabelsCatalogMaterialMissingHold() {
        var payload = status()
        payload["network_state"] = "not_buyer_serving"
        payload["buyer_serving_hold"] = "catalog_material_missing"

        let output = LocalStatusFormatter.format(payload, advanced: true)

        XCTAssertTrue(output.contains(
            "Network:         not_buyer_serving (hold: catalog_material_missing — catalog material missing for this model — buyers cannot be routed until the network catalog includes it)"
        ), output)
    }

    func testAdvancedStatusShowsUnloadedModelAndDisconnectedCoordinator() {
        var payload = status()
        payload["status"] = "unavailable"
        payload["model_loaded"] = false
        payload["coordinator"] = ["connected": false]

        let output = LocalStatusFormatter.format(payload, advanced: true)

        XCTAssertTrue(output.contains("Local inference: unavailable (model not loaded)"), output)
        XCTAssertTrue(output.contains("Coordinator:     not connected"), output)
        XCTAssertTrue(output.contains("Network:         <unknown>"), output)
        XCTAssertTrue(output.contains("Catalog trust:   <unknown>"), output)
    }

    func testAdvancedStatusShowsContextSourceLabel() {
        let output = LocalStatusFormatter.format(status(maxContextSource: "cli_flag"), advanced: true)
        XCTAssertTrue(output.contains("Context cap: 4096 tokens (source: --max-context flag)"), output)

        let fallback = LocalStatusFormatter.format(status(maxContextSource: nil), advanced: true)
        XCTAssertTrue(fallback.contains("Context cap: 4096 tokens\n"), fallback)
    }

    func testAdvancedStatusLabelsStartupProbeAndMatchingSustainedBenchmark() {
        let output = LocalStatusFormatter.format(
            status(probeTPS: 30, probeModel: "model-a"),
            advanced: true,
            sustainedBenchmarks: [benchmark(model: "model-a", tps: 40)]
        )

        XCTAssertTrue(output.contains("Startup probe: 30.0 tok/s (8-token probe on model-a; not a sustained benchmark)"), output)
        XCTAssertTrue(output.contains("Sustained benchmark: 40.0 tok/s (benchmark bench-1, 2026-09-20T00:00:00Z)"), output)
        XCTAssertFalse(output.contains("understates"), output)
        XCTAssertFalse(output.contains("stale"), output)
    }

    func testAdvancedStatusWarnsWhenStartupProbeUnderstatesSustainedBenchmark() {
        let output = LocalStatusFormatter.format(
            status(probeTPS: 9.2, probeModel: "model-a"),
            advanced: true,
            sustainedBenchmarks: [
                benchmark(model: "model-other", tps: 90),
                benchmark(model: "model-a", tps: 40),
            ]
        )

        XCTAssertTrue(output.contains("Sustained benchmark: 40.0 tok/s"), output)
        XCTAssertTrue(
            output.contains("Warning: the startup probe (9.2 tok/s) is under 50% of the sustained benchmark; it understates this Mac's capacity."),
            output
        )
    }

    func testAdvancedStatusMarksProbeFromPreviousModelAsStale() {
        let output = LocalStatusFormatter.format(
            status(probeTPS: 9.2, probeModel: "model-old"),
            advanced: true,
            sustainedBenchmarks: [benchmark(model: "model-a", tps: 40)]
        )

        XCTAssertTrue(output.contains("Startup probe: 9.2 tok/s (8-token probe on model-old; not a sustained benchmark)"), output)
        XCTAssertTrue(output.contains("Startup probe is stale: it ran on model-old, but model-a is served now."), output)
        XCTAssertFalse(output.contains("understates"), output)
    }

    func testAdvancedStatusOmitsSustainedLineWithoutRecommendationEvidence() {
        let output = LocalStatusFormatter.format(status(probeTPS: 9.2, probeModel: "model-a"), advanced: true)

        XCTAssertTrue(output.contains("Startup probe: 9.2 tok/s"), output)
        XCTAssertFalse(output.contains("Sustained benchmark"), output)
        XCTAssertFalse(output.contains("understates"), output)
    }

    func testAdvancedStatusReportsProbeNotRun() {
        var payload = status(probeTPS: 0, probeModel: nil)
        var capacity = payload["capacity"] as! [String: Any]
        capacity["throughput_source"] = "none"
        payload["capacity"] = capacity

        let output = LocalStatusFormatter.format(payload, advanced: true)
        XCTAssertTrue(output.contains("Startup probe: not run"), output)
    }

    func testAdvancedStatusUsesConfiguredCoordinatorURLWithoutSecrets() {
        let output = LocalStatusFormatter.format(
            status(),
            advanced: true,
            coordinatorURL: "wss://user:secret@coordinator.example/ws/provider?api_key=k#frag"
        )
        XCTAssertTrue(output.contains("URL:         wss://coordinator.example/ws/provider (from config)"), output)
        XCTAssertFalse(output.contains("secret"), output)
        XCTAssertFalse(output.contains("api_key"), output)

        let unset = LocalStatusFormatter.format(status(), advanced: true)
        XCTAssertTrue(unset.contains("URL:         (not configured)"), unset)
    }

    func testPublicStatusDoesNotShowProvenance() {
        let output = LocalStatusFormatter.format(
            status(probeTPS: 9.2, probeModel: "model-a"),
            coordinatorURL: "wss://coordinator.example/ws/provider",
            sustainedBenchmarks: [benchmark(model: "model-a", tps: 40)]
        )
        XCTAssertFalse(output.contains("Readiness"), output)
        XCTAssertFalse(output.contains("Startup probe"), output)
        XCTAssertFalse(output.contains("Sustained benchmark"), output)
        XCTAssertFalse(output.contains("coordinator.example"), output)
    }

    // MARK: - last-recommendation.json (best effort)

    func testSustainedBenchmarksAreEmptyForMissingOrCorruptState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capacity-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("last-recommendation.json")

        XCTAssertEqual(StatusCommand.sustainedBenchmarks(stateURL: stateURL), [])

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{not json".utf8).write(to: stateURL)
        XCTAssertEqual(chmod(stateURL.path, 0o600), 0)
        XCTAssertEqual(StatusCommand.sustainedBenchmarks(stateURL: stateURL), [])
    }

    func testSustainedBenchmarksReadStoredHardwareEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capacity-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("last-recommendation.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let json = """
        {
          "generated_at": "2026-09-20T00:00:00Z",
          "rate_card_version": "r1",
          "demand_rank_version": "d1",
          "candidate_catalog_version": "c1",
          "candidate_catalog_sha256": "\(String(repeating: "a", count: 64))",
          "binary_version": "1.8.170",
          "hardware_identity_hash": "hw",
          "hardware_evidence": {
            "generated_at": "2026-09-20T00:00:00Z",
            "hardware": {
              "chip": "Apple M3 Ultra",
              "memory_gb": 256,
              "bandwidth_tier": "ultra",
              "detected": true,
              "os_version": "26.0",
              "binary_version": "1.8.170",
              "hardware_identity_hash": "hw",
              "executable_sha256": "\(String(repeating: "b", count: 64))"
            },
            "candidate_catalog_sha256": "\(String(repeating: "a", count: 64))",
            "recommended_model": "model-a",
            "probe_protocol": "p1",
            "benchmarks": [{
              "model_key": "key-a",
              "model_id": "model-a",
              "sustained_tps": 40,
              "ttft_ms": 300,
              "swap_detected": false,
              "thermal_throttle_detected": false,
              "artifact_sha256": "\(String(repeating: "c", count: 64))",
              "candidate_catalog_sha256": "\(String(repeating: "a", count: 64))",
              "benchmark_id": "bench-1",
              "generated_at": "2026-09-20T00:00:00Z",
              "binary_version": "1.8.170",
              "hardware_identity_hash": "hw"
            }]
          }
        }
        """
        try Data(json.utf8).write(to: stateURL)
        XCTAssertEqual(chmod(stateURL.path, 0o600), 0)

        let benchmarks = StatusCommand.sustainedBenchmarks(stateURL: stateURL)
        XCTAssertEqual(benchmarks.count, 1)
        XCTAssertEqual(benchmarks.first?.modelID, "model-a")
        XCTAssertEqual(benchmarks.first?.sustainedTPS, 40)
    }

    // MARK: - Fixtures

    private func status(
        maxContextSource: String? = "operator_config",
        probeTPS: Double = 30,
        probeModel: String? = "model-a"
    ) -> [String: Any] {
        var capacity: [String: Any] = [
            "ram_gb": 16,
            "ram_tier": "16GB",
            "max_context_tokens": 4096,
            "max_concurrency": 1,
            "throughput_tps_estimate": probeTPS,
            "throughput_source": "startup_probe",
            "throughput_probe_max_tokens": 8,
            "throughput_probe_model": probeModel.map { $0 as Any } ?? NSNull(),
        ]
        if let maxContextSource {
            capacity["max_context_source"] = maxContextSource
        }
        return [
            "binary_version": "1.5.0",
            "local_status_contract": [
                "version": 1,
                "minimum_reader_version": 1,
                "capabilities": maxContextSource == nil ? [] : ["capacity_provenance_v1"],
            ],
            "provider_id": "provider-a",
            "model": "model-a",
            "model_loaded": true,
            "status": "ready",
            "uptime_s": 60,
            "requests_total": 1,
            "errors_total": 0,
            "active_request_id_count": 0,
            "capacity": capacity,
            "coordinator": [
                "connected": true,
                "session": "provider-a",
                "tier": 2,
                "recommended_binary_version": "1.5.0",
            ],
        ]
    }

    private func benchmark(model: String, tps: Double) -> BenchmarkPayload {
        BenchmarkPayload(
            modelKey: "key-\(model)",
            modelID: model,
            modelArtifactPath: nil,
            sustainedTPS: tps,
            ttftMS: 300,
            swapDetected: false,
            thermalThrottleDetected: false,
            artifactSHA256: String(repeating: "c", count: 64),
            candidateCatalogSHA256: String(repeating: "a", count: 64),
            candidateRowIdentity: nil,
            benchmarkID: "bench-1",
            generatedAt: "2026-09-20T00:00:00Z",
            binaryVersion: "1.8.170",
            hardwareIdentityHash: "hw"
        )
    }
}
