import Foundation
import XCTest
@testable import macprovider_cli

final class NativePathProbeProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func request(_ profile: String) throws -> [String: Any] {
        var p: [String: Any] = ["probe_id": "fixture", "expires_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(60)),
            "model_id": "fixture-model", "target_model_hash": String(repeating: "a", count: 64), "target_generation": 7,
            "tokenizer_identity": String(repeating: "b", count: 64), "sampling_profile": ["temperature": 0, "top_p": 1],
            "corpus_version": "synthetic-native-preflight-v1", "threshold_version": "no-measurement", "native_mtp_runtime_tuple_sha256": String(repeating: "c", count: 64)]
        if profile == LosslessnessProbeProtocol.version {
            p.merge(["probe_version": profile, "probe_nonce": "nonce", "decode_path": "native_mtp",
                "prompts": [["prompt_id": "p", "prompt": "synthetic fixture", "coordinator_owned": true, "buyer_origin": false]],
                "measurement_positions": [0], "requested_k": 64, "support_selection": "support_selection_v1", "max_prompts": 1, "max_stochastic_positions": 1, "timeout_ms": 60_000]) { _, value in value }
        } else {
            p.merge(["schema_version": profile + ".request", "nonce": "nonce", "expected_decode_path": "native_mtp", "sampler_stage": "post_sampler_probabilities",
                "hardware_runtime_class": "fixture", "support_selection": "compute_integrity_support_selection_v1", "normalization_basis": "full_distribution", "k": 64,
                "positions": [["prompt_id": "p", "prompt_ref": "synthetic:native-path-binding-v1", "position_index": 0,
                    "token_prefix_digest": "sha256:" + String(repeating: "d", count: 64), "context_hash": "sha256:" + String(repeating: "e", count: 64)]]]) { _, value in value }
        }
        return try envelope(profile, p)
    }
    private func envelope(_ profile: String, _ p: [String: Any]) throws -> [String: Any] {
        var out: [String: Any] = ["type": profile + ".request", "payload": p, "probe_request_digest": try NativePathProbeProtocol.digest(profile: profile, kind: "request", payload: p)]
        if profile == NativePathProbeProtocol.compute { out["schema_version"] = profile + ".request" } else { out["probe_id"] = p["probe_id"] }
        return out
    }
    func testNativePreflightHasNoMeasurementAndDoesNotClaimCapabilityExecuted() throws {
        for profile in NativePathProbeProtocol.profiles {
            let req = try NativePathProbeProtocol.decode(request(profile), profile: profile, now: now)
            let result = try NativePathProbeProtocol.result(req, actual: ["model_id": "actual", "target_model_hash": String(repeating: "1", count: 64), "target_generation": 8,
                "tokenizer_identity": String(repeating: "2", count: 64), "native_mtp_runtime_tuple_sha256": String(repeating: "f", count: 64)])
            let p = try XCTUnwrap(result["payload"] as? [String: Any])
            XCTAssertEqual(p["provider_reason_code"] as? String, "inconclusive:native_path_untrusted")
            XCTAssertEqual(p["result_kind"] as? String, "provider_inconclusive")
            XCTAssertTrue(p["actual_decode_path"] is NSNull)
            XCTAssertNil(p["positions"]); XCTAssertNil(p["validation_metadata"])
            XCTAssertEqual(p["target_generation"] as? Int, 8)
            XCTAssertNotEqual(p["actual_native_mtp_runtime_tuple_sha256"] as? String, req.payload["native_mtp_runtime_tuple_sha256"] as? String)
            XCTAssertEqual(result["probe_result_digest"] as? String, try NativePathProbeProtocol.digest(profile: profile, kind: "result", payload: p))
            let unavailable = try XCTUnwrap(try NativePathProbeProtocol.result(req, actual: [:])["payload"] as? [String: Any])
            XCTAssertTrue(unavailable["target_generation"] is NSNull)
            XCTAssertTrue(unavailable["actual_native_mtp_runtime_tuple_sha256"] is NSNull)
        }
    }
    func testNativeRequestRejectsExternalDraftExpiredOrBooleanGeneration() throws {
        for profile in NativePathProbeProtocol.profiles {
            let original = try request(profile)
            XCTAssertNoThrow(try NativePathProbeProtocol.decode(original, profile: profile, now: now))
            for mutation in ["draft_model_id", "target_generation", "expires_at"] {
                var p = try XCTUnwrap(original["payload"] as? [String: Any])
                switch mutation {
                case "target_generation": p[mutation] = true
                case "expires_at": p[mutation] = "2000-01-01T00:00:00Z"
                default: p[mutation] = "must-not-mix"
                }
                XCTAssertThrowsError(try NativePathProbeProtocol.decode(envelope(profile, p), profile: profile, now: now))
            }
            var bad = original; bad["probe_request_digest"] = "sha256:" + String(repeating: "0", count: 64)
            XCTAssertThrowsError(try NativePathProbeProtocol.decode(bad, profile: profile, now: now))
        }
    }
    func testComputeAndLosslessnessDigestDomainsCannotBeConfused() throws {
        let p: [String: Any] = ["probe_id": "same"]
        let a = try NativePathProbeProtocol.digest(profile: LosslessnessProbeProtocol.version, kind: "request", payload: p)
        let b = try NativePathProbeProtocol.digest(profile: NativePathProbeProtocol.compute, kind: "request", payload: p)
        let c = try NativePathProbeProtocol.digest(profile: NativePathProbeProtocol.compute, kind: "result", payload: p)
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(a, c); XCTAssertNotEqual(b, c)
    }
    func testComputeTier2CarrierCannotBeConfusedWithLosslessness() throws {
        let session = try Tier2ProviderSession(providerID: "provider-test", assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite, keyID: "fixture",
            c2pKey: Data(repeating: 0x31, count: 32), p2cKey: Data(repeating: 0x42, count: 32),
            c2pNonceBase: Data([1, 2, 3, 4]), p2cNonceBase: Data([5, 6, 7, 8]))
        let profile = NativePathProbeProtocol.compute
        let outer = try request(profile)
        let frame = try Tier2ProviderSession.sealLosslessnessRequestForTest(session: session, requestID: "fixture", outerEnvelope: outer, profile: profile)
        XCTAssertEqual(frame["type"] as? String, profile + ".encrypted_request")
        XCTAssertThrowsError(try session.openLosslessnessProbeRequestPayload(message: frame, requestID: "fixture"))
        let opened = try session.openLosslessnessProbeRequestPayload(message: frame, requestID: "fixture", profile: profile).outerEnvelope
        let req = try NativePathProbeProtocol.decode(opened, profile: profile, now: now)
        let result = try NativePathProbeProtocol.result(req, actual: [:])
        let sealed = try session.sealLosslessnessProbeResult(requestID: "fixture", outerEnvelope: result, profile: profile)
        XCTAssertEqual(sealed["type"] as? String, profile + ".encrypted_result")
        XCTAssertThrowsError(try Tier2ProviderSession.openLosslessnessResultForTest(session: session, frame: sealed, requestID: "fixture"))
        let response = try Tier2ProviderSession.openLosslessnessResultForTest(session: session, frame: sealed, requestID: "fixture", profile: profile)
        XCTAssertEqual(response["type"] as? String, profile + ".result")
    }

    func testOrdinaryLosslessnessDecoderStillRejectsNativeProfile() throws {
        let p = try XCTUnwrap(request(LosslessnessProbeProtocol.version)["payload"] as? [String: Any])
        XCTAssertThrowsError(try LosslessnessProbeProtocol.decodeRequestPayload(p))
    }
}
