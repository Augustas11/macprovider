import XCTest
@testable import malibu_cli

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
        XCTAssertTrue(requestAADRaw.starts(with: Data("macprovider/spec008/pillar-b/aad/v1\0".utf8)))
        XCTAssertFalse(String(data: requestAADRaw, encoding: .utf8)?.contains(#""request_id""#) ?? true)

        XCTAssertEqual(try session.openRequestBody(message: request, requestID: "req-roundtrip", stream: true), "request-body")
        XCTAssertThrowsError(try session.openRequestBody(message: request, requestID: "req-roundtrip", stream: true))

        session.enableResponseChunkPlaintextEnvelope()
        let response = try session.sealResponseChunk(requestID: "req-roundtrip", stream: true, seq: 0, plaintext: "response-body")
        XCTAssertEqual(response["encrypted"] as? Bool, true)
        XCTAssertNil(response["data"])
        let responseEnc = try XCTUnwrap(response["enc"] as? [String: Any])
        let responseAAD = try XCTUnwrap(responseEnc["aad"] as? String)
        let responseAADRaw = try Data(base64URLUnpadded: responseAAD)
        XCTAssertTrue(responseAADRaw.starts(with: Data("macprovider/spec008/pillar-b/aad/v1\0".utf8)))
        XCTAssertFalse(String(data: responseAADRaw, encoding: .utf8)?.contains(#""request_id""#) ?? true)
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

    func testResponseChunkEnvelopeRequiresCoordinatorAcknowledgement() throws {
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

        let rawResponse = try session.sealResponseChunk(requestID: "req-raw", stream: false, seq: 7, plaintext: "raw-body")
        XCTAssertThrowsError(try Tier2ProviderSession.openResponseChunkForTest(
            session: session,
            frame: rawResponse,
            requestID: "req-raw",
            stream: false
        ))

        session.enableResponseChunkPlaintextEnvelope()
        let wrappedResponse = try session.sealResponseChunk(requestID: "req-wrapped", stream: false, seq: 7, plaintext: "wrapped-body")
        XCTAssertEqual(try Tier2ProviderSession.openResponseChunkForTest(
            session: session,
            frame: wrappedResponse,
            requestID: "req-wrapped",
            stream: false,
            seq: 1
        ), "wrapped-body")
    }

    func testAADEncodingIsVersionedBinary() throws {
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

        XCTAssertTrue(requestAADRaw.starts(with: Data("macprovider/spec008/pillar-b/aad/v1\0".utf8)))
        XCTAssertFalse(String(data: requestAADRaw, encoding: .utf8)?.contains(#"\u003c"#) ?? true)
        XCTAssertFalse(String(data: requestAADRaw, encoding: .utf8)?.contains(#""request_id""#) ?? true)
    }
}
