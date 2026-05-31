import XCTest
@testable import macprovider_cli

final class Tier2ProviderSessionTests: XCTestCase {
    func testAEADRoundTripTracksDirectionsAndRejectsReplaySequence() throws {
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

        let request = try Tier2ProviderSession.sealRequestForTest(
            session: session,
            requestID: "req-roundtrip",
            stream: true,
            plaintext: "request-body"
        )
        let requestEnc = try XCTUnwrap(request["enc"] as? [String: Any])
        let requestAAD = try XCTUnwrap(requestEnc["aad"] as? String)
        let requestAADRaw = try Data(base64URLUnpadded: requestAAD)
        XCTAssertEqual(
            String(data: requestAADRaw, encoding: .utf8),
            #"{"type":"inference_request","direction":"c2p","request_id":"req-roundtrip","stream":true,"provider_id":"provider-test","assigned_id":"assigned-test","seq":0}"#
        )

        XCTAssertEqual(try session.openRequestBody(message: request, requestID: "req-roundtrip", stream: true), "request-body")
        XCTAssertThrowsError(try session.openRequestBody(message: request, requestID: "req-roundtrip", stream: true))

        let response = try session.sealResponseChunk(requestID: "req-roundtrip", stream: true, plaintext: "response-body")
        XCTAssertEqual(response["encrypted"] as? Bool, true)
        XCTAssertNil(response["data"])
        let responseEnc = try XCTUnwrap(response["enc"] as? [String: Any])
        let responseAAD = try XCTUnwrap(responseEnc["aad"] as? String)
        let responseAADRaw = try Data(base64URLUnpadded: responseAAD)
        XCTAssertEqual(
            String(data: responseAADRaw, encoding: .utf8),
            #"{"type":"inference_response_chunk","direction":"p2c","request_id":"req-roundtrip","stream":true,"provider_id":"provider-test","assigned_id":"assigned-test","seq":0}"#
        )
        XCTAssertEqual(
            try Tier2ProviderSession.openResponseChunkForTest(
                session: session,
                frame: response,
                requestID: "req-roundtrip",
                stream: true
            ),
            "response-body"
        )
    }

    func testAADStringEscapingMatchesGoMarshalDefaults() throws {
        let session = try Tier2ProviderSession(
            providerID: "provider<&>",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x51, count: 32),
            p2cKey: Data(repeating: 0x62, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )

        let request = try Tier2ProviderSession.sealRequestForTest(
            session: session,
            requestID: "req-line\n",
            stream: false,
            plaintext: "body"
        )
        let requestEnc = try XCTUnwrap(request["enc"] as? [String: Any])
        let requestAAD = try XCTUnwrap(requestEnc["aad"] as? String)
        let requestAADRaw = try Data(base64URLUnpadded: requestAAD)

        XCTAssertEqual(
            String(data: requestAADRaw, encoding: .utf8),
            #"{"type":"inference_request","direction":"c2p","request_id":"req-line\n","stream":false,"provider_id":"provider\u003c\u0026\u003e","assigned_id":"assigned-test","seq":0}"#
        )
    }
}
