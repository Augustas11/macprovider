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

    func testShutdownRequestGraceRoundTrip() throws {
        let f = ControlFrame.shutdownRequest(graceSeconds: 30)
        XCTAssertEqual(try roundTrip(f), f)
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
}
