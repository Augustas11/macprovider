import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class LosslessnessProbeProtocolTests: XCTestCase {
    func testDigestFixturesMatchSwiftJCS() throws {
        for fixture in try Self.loadFixtures() {
            let digest = try LosslessnessProbeProtocol.digest(payload: fixture.payload)
            XCTAssertEqual(digest, fixture.expectedSHA256, fixture.id)
        }
    }

    func testEnvelopeDigestUsesInnerPayloadOnly() throws {
        let request = try XCTUnwrap(try Self.loadFixtures().first { $0.id == "request_payload" })
        let outer: [String: Any] = [
            "type": LosslessnessProbeProtocol.requestType,
            "probe_id": "probe-fixture-001",
            "probe_request_digest": request.expectedSHA256,
            "payload": request.payload,
            "outer_debug_field": "not part of digest",
        ]
        let decoded = try LosslessnessProbeProtocol.decodeEnvelope(outer, expectedType: LosslessnessProbeProtocol.requestType)
        XCTAssertEqual(decoded.probeID, "probe-fixture-001")
        XCTAssertNotEqual(try LosslessnessProbeProtocol.digest(payload: outer), request.expectedSHA256)

        var mismatchedOuter = outer
        mismatchedOuter["probe_id"] = "outer-mismatch"
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeEnvelope(mismatchedOuter, expectedType: LosslessnessProbeProtocol.requestType)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidEnvelope)
        }
    }

    func testRejectsProviderInconclusiveUnknownReason() throws {
        var payload = try XCTUnwrap(try Self.loadFixtures().first { $0.id == "provider_inconclusive_payload" }).payload
        XCTAssertEqual(try LosslessnessProbeProtocol.decodeProviderInconclusive(payload).reasonCode, "inconclusive:unsupported_sampler")
        payload["provider_reason_code"] = "inconclusive:invented_prose"
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeProviderInconclusive(payload)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .unsupportedProviderReason("inconclusive:invented_prose"))
        }
        payload["provider_reason_code"] = "inconclusive:identity_mismatch"
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeProviderInconclusive(payload)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .unsupportedProviderReason("inconclusive:identity_mismatch"))
        }
        payload["provider_reason_code"] = "inconclusive:unsupported_sampler"
        payload.removeValue(forKey: "target_model_hash")
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeProviderInconclusive(payload)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
        payload["target_model_hash"] = NSNull()
        payload["target_generation"] = 1
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeProviderInconclusive(payload)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
        payload["provider_reason_code"] = "inconclusive:unsupported_sampler"
        payload["target_model_hash"] = "sha256:target"
        payload["target_generation"] = 1
        payload["draft_artifact_binding"] = [
            "draft_model_id": "draft-a",
            "draft_artifact_sha256": "sha256:draft",
            "tokenizer_identity": "tok-v1",
            "compatibility_check_digest": "sha256:compat",
        ]
        payload["draft_generation"] = 1
        payload.removeValue(forKey: "identity_unavailable_reason")
        XCTAssertNoThrow(try LosslessnessProbeProtocol.decodeProviderInconclusive(payload))
    }

    func testRequestPayloadRequiresSpec029Shape() throws {
        let request = try XCTUnwrap(try Self.loadFixtures().first { $0.id == "request_payload" }).payload
        XCTAssertNoThrow(try LosslessnessProbeProtocol.decodeRequestPayload(request))
        var missingExpiry = request
        missingExpiry.removeValue(forKey: "expires_at")
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeRequestPayload(missingExpiry)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
        var buyerPrompt = request
        var prompts = try XCTUnwrap(buyerPrompt["prompts"] as? [[String: Any]])
        prompts[0]["buyer_origin"] = true
        buyerPrompt["prompts"] = prompts
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeRequestPayload(buyerPrompt)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
        var booleanGeneration = request
        booleanGeneration["target_generation"] = true
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeRequestPayload(booleanGeneration)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
        var fractionalGeneration = request
        fractionalGeneration["target_generation"] = 1.5
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeRequestPayload(fractionalGeneration)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
        var fractionalPosition = request
        fractionalPosition["measurement_positions"] = [1.5]
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeRequestPayload(fractionalPosition)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
        var booleanSamplingProfile = request
        var samplingProfile = try XCTUnwrap(booleanSamplingProfile["sampling_profile"] as? [String: Any])
        samplingProfile["temperature"] = true
        booleanSamplingProfile["sampling_profile"] = samplingProfile
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeRequestPayload(booleanSamplingProfile)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
        var tooManyForDeclaredMax = request
        tooManyForDeclaredMax["max_prompts"] = 1
        tooManyForDeclaredMax["prompts"] = [
            ["prompt_id": "p1", "prompt": "one", "coordinator_owned": true, "buyer_origin": false],
            ["prompt_id": "p2", "prompt": "two", "coordinator_owned": true, "buyer_origin": false],
        ]
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeRequestPayload(tooManyForDeclaredMax)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .invalidPayload)
        }
    }

    func testMeasurementPositionRequiresNormativeSamplerStage() throws {
        let valid: [String: Any] = [
            "support_selection": LosslessnessProbeProtocol.supportSelection,
            "normalization_basis": LosslessnessProbeProtocol.normalizationBasis,
            "sampler_stage": LosslessnessProbeProtocol.samplerStage,
        ]
        XCTAssertNoThrow(try LosslessnessProbeProtocol.validateMeasurementPosition(valid))
        var invalid = valid
        invalid["sampler_stage"] = "sampled_token_histogram"
        XCTAssertThrowsError(try LosslessnessProbeProtocol.validateMeasurementPosition(invalid)) { error in
            XCTAssertEqual(error as? LosslessnessProbeError, .malformedDistribution)
        }
    }

    func testTier2CarrierUsesDedicatedLosslessnessTypes() throws {
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x31, count: 32),
            p2cKey: Data(repeating: 0x42, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )
        let request = try XCTUnwrap(try Self.loadFixtures().first { $0.id == "request_payload" })
        let outer: [String: Any] = [
            "type": LosslessnessProbeProtocol.requestType,
            "probe_id": "probe-fixture-001",
            "probe_request_digest": request.expectedSHA256,
            "payload": request.payload,
        ]
        let encrypted = try Tier2ProviderSession.sealLosslessnessRequestForTest(
            session: session,
            requestID: "probe-fixture-001",
            outerEnvelope: outer
        )
        XCTAssertEqual(encrypted["type"] as? String, LosslessnessProbeProtocol.encryptedRequestType)
        XCTAssertEqual(encrypted["stream"] as? Bool, false)
        XCTAssertEqual(try session.openLosslessnessProbeRequestPayload(message: encrypted, requestID: "probe-fixture-001").outerEnvelope["type"] as? String, LosslessnessProbeProtocol.requestType)

        let resultOuter: [String: Any] = [
            "type": LosslessnessProbeProtocol.resultType,
            "probe_id": "probe-fixture-001",
            "probe_request_digest": request.expectedSHA256,
            "probe_result_digest": "sha256:result",
            "payload": ["probe_id": "probe-fixture-001"],
        ]
        let sealedResult = try session.sealLosslessnessProbeResult(requestID: "probe-fixture-001", outerEnvelope: resultOuter)
        XCTAssertEqual(sealedResult["type"] as? String, LosslessnessProbeProtocol.encryptedResultType)
        let openedResult = try Tier2ProviderSession.openLosslessnessResultForTest(
            session: session,
            frame: sealedResult,
            requestID: "probe-fixture-001"
        )
        XCTAssertEqual(openedResult["type"] as? String, LosslessnessProbeProtocol.resultType)
    }

    func testTier2ProbeRejectsInferenceRequestCarrier() throws {
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x31, count: 32),
            p2cKey: Data(repeating: 0x42, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )
        let inferenceCarrier = try Tier2ProviderSession.sealRequestForTest(
            session: session,
            requestID: "probe-fixture-001",
            stream: false,
            plaintext: #"{"type":"losslessness_probe_v1.request"}"#
        )
        XCTAssertThrowsError(try session.openLosslessnessProbeRequestPayload(message: inferenceCarrier, requestID: "probe-fixture-001"))
    }

    func testConfigLoaderDefaultsProbeCapabilityOffAndReadsYAMLEnv() throws {
        XCTAssertFalse(AppConfig.defaults().losslessnessProbeEnabled)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configURL = dir.appendingPathComponent("config.yaml")
        try "losslessness_probe_enabled: true\n".write(to: configURL, atomically: true, encoding: .utf8)
        let fromYAML = try ConfigLoader.load(cli: CLIOverrides(configPath: configURL.path), environment: [:])
        XCTAssertTrue(fromYAML.losslessnessProbeEnabled)

        let fromEnv = try ConfigLoader.load(
            cli: CLIOverrides(configPath: configURL.path),
            environment: ["MACPROVIDER_LOSSLESSNESS_PROBE_ENABLED": "true"]
        )
        XCTAssertTrue(fromEnv.losslessnessProbeEnabled)
    }

    func testUnavailableSamplerBuildsProviderInconclusiveWithoutReceiptFields() throws {
        let payload = LosslessnessProbeRuntime.providerInconclusiveForUnavailableSampler(
            probeID: "probe-no-hook",
            probeNonce: "00112233445566778899aabbccddeeff",
            requestDigest: "sha256:req"
        )
        XCTAssertEqual(payload["result_kind"] as? String, "provider_inconclusive")
        XCTAssertEqual(payload["probe_nonce"] as? String, "00112233445566778899aabbccddeeff")
        XCTAssertEqual(payload["provider_reason_code"] as? String, "inconclusive:unsupported_sampler")
        XCTAssertTrue(payload["target_model_hash"] is NSNull)
        XCTAssertTrue(payload["draft_artifact_binding"] is NSNull)
        XCTAssertNil(payload["usage"])
        XCTAssertNil(payload["receipt"])
        XCTAssertNil(payload["choices"])
        XCTAssertNoThrow(try LosslessnessProbeProtocol.decodeProviderInconclusive(payload))
    }

    private struct Fixture {
        let id: String
        let expectedSHA256: String
        let payload: [String: Any]
    }

    private static func loadFixtures() throws -> [Fixture] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot
            .appendingPathComponent("phase4-coordinator")
            .appendingPathComponent("test")
            .appendingPathComponent("jcs_fixtures")
            .appendingPathComponent("spec029")
            .appendingPathComponent("losslessness_probe_v1.json")
        let raw = try Data(contentsOf: url)
        guard let entries = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else {
            throw LosslessnessProbeError.invalidPayload
        }
        return try entries.map { entry in
            guard let id = entry["id"] as? String,
                  let expected = entry["expected_sha256"] as? String,
                  let payload = entry["payload"] as? [String: Any] else {
                throw LosslessnessProbeError.invalidPayload
            }
            return Fixture(id: id, expectedSHA256: expected, payload: payload)
        }
    }
}
