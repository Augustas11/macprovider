import XCTest
@testable import Malibu

// AUDIT R1 ARCHITECT A8: parity tests for the app-side ControlFrame codec.
// These lock the wire-format against silent drift from the CLI side. The
// duplicated definitions in phase3-binary/app/Sources/Malibu/Agent/
// ControlSocketFrame.swift and phase3-binary/Sources/macprovider-cli/
// ControlSocket.swift will be consolidated in a follow-up SPEC-025 §12
// conflict #9 PR; until then these tests catch divergence.

final class ControlFrameCodecTests: XCTestCase {
    private func roundTrip(_ frame: ControlFrame) throws -> ControlFrame {
        let encoded = try ControlCodec.encode(frame)
        return try ControlCodec.decode(encoded)
    }

    func testMetricsResponseRoundTrip() throws {
        let f = ControlFrame.metricsResponse(
            earningsUsdc: 1.25,
            malibuAccrued: 3.5,
            gpuC: 48.2,
            latencyP50Ms: 120,
            uptimeSec: 3600
        )
        XCTAssertEqual(try roundTrip(f), f)
    }

    func testMetricsResponseOmitsOptionalNils() throws {
        let f = ControlFrame.metricsResponse(
            earningsUsdc: 0, malibuAccrued: 0, gpuC: nil, latencyP50Ms: nil, uptimeSec: 0
        )
        let data = try ControlCodec.encode(f)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertNil(obj?["gpu_c"])
        XCTAssertNil(obj?["latency_p50_ms"])
    }

    func testPauseAckAcceptedFalseCarriesReason() throws {
        let f = ControlFrame.pauseAck(accepted: false, reason: "not_implemented")
        let decoded = try roundTrip(f)
        XCTAssertEqual(decoded, f)
    }

    func testShutdownRequestEncodesGraceField() throws {
        // The app is a control-socket CLIENT — it only encodes request
        // frames (never decodes them). Assert the wire shape rather than a
        // round-trip; attempting to decode a request type throws
        // unknownType, which is the correct asymmetry.
        let data = try ControlCodec.encode(.shutdownRequest(graceSeconds: 30))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "shutdown_request")
        XCTAssertEqual(obj?["grace_seconds"] as? Int, 30)
        XCTAssertThrowsError(try ControlCodec.decode(data))
    }

    func testUnknownTypeIsRejected() {
        let bogus = Data(#"{"type":"unknown_frame"}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(bogus))
    }

    func testStatusResponseWithEmptyStringsDoesNotCrash() throws {
        let obj: [String: Any] = ["type": "status_response"]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try ControlCodec.decode(data)
        if case .statusResponse(let model, let state) = decoded {
            XCTAssertEqual(model, "")
            XCTAssertEqual(state, "")
        } else {
            XCTFail("expected statusResponse")
        }
    }

    func testIdentitySignatureRequestRoundTrip() throws {
        let frame = ControlFrame.identitySignatureRequest(
            authAttemptID: "auth-1",
            providerID: "p_abc",
            binaryVersion: 2,
            providerECDHPublicKey: "ecdh",
            transcriptSHA256: "hash"
        )
        XCTAssertEqual(try roundTrip(frame), frame)
    }

    func testIdentitySignatureResponseOmitsSignatureOnRefusal() throws {
        let frame = ControlFrame.identitySignatureResponse(
            accepted: false,
            identitySignature: nil,
            transcriptSHA256: nil,
            reason: "provider_id_mismatch"
        )
        let data = try ControlCodec.encode(frame)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "identity_signature_response")
        XCTAssertEqual(obj?["accepted"] as? Bool, false)
        XCTAssertEqual(obj?["reason"] as? String, "provider_id_mismatch")
        XCTAssertNil(obj?["identity_signature"])
        XCTAssertEqual(try ControlCodec.decode(data), frame)
    }
}
