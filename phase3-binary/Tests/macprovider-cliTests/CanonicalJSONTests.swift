import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class CanonicalJSONTests: XCTestCase {
    func testCapturedStartupThroughputValuesUseRFC8785NumberFormatting() throws {
        let cases: [(Double, String)] = [
            (0.09774012272370747, "0.09774012272370747"),
            (0.15710173308461284, "0.15710173308461284"),
        ]

        for (throughput, expected) in cases {
            let message: [String: Any] = [
                "throughput_tps_estimate": throughput,
            ]
            let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(message))

            XCTAssertEqual(
                String(decoding: canonical, as: UTF8.self),
                #"{"throughput_tps_estimate":\#(expected)}"#
            )
        }
    }

    func testTranscriptHashMatchesRFC8785ForCapturedRejectedValue() throws {
        let message: [String: Any] = [
            "provider_id": "provider-test",
            "throughput_tps_estimate": 0.15710173308461284,
            "type": "auth_request",
        ]
        let expectedCanonical =
            #"{"provider_id":"provider-test","throughput_tps_estimate":0.15710173308461284,"type":"auth_request"}"#
        let expectedHash = Data(SHA256.hash(data: Data(expectedCanonical.utf8))).base64EncodedString()

        XCTAssertEqual(
            try CoordinatorClient.initialAuthTranscriptHashBase64(message),
            expectedHash
        )
    }

    func testUnsignedIntegerNSNumberPreservesValuesWithinSignedJSONRange() throws {
        let message: [String: Any] = [
            "value": NSNumber(value: UInt64(Int64.max)),
        ]
        let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(message))

        XCTAssertEqual(
            String(decoding: canonical, as: UTF8.self),
            #"{"value":9223372036854775807}"#
        )
    }

    func testUnsignedIntegerAboveCoordinatorExactRangeIsRejected() {
        XCTAssertThrowsError(
            try CanonicalJSON.fromJSONLike(NSNumber(value: UInt64.max))
        ) { error in
            XCTAssertEqual(error as? CanonicalJSONError, .integerOutOfRange)
        }
    }

    func testNonFiniteNSNumberIsRejected() {
        XCTAssertThrowsError(
            try CanonicalJSON.fromJSONLike(NSNumber(value: Double.infinity))
        ) { error in
            XCTAssertTrue(error is CanonicalJSONError)
        }
    }

    func testNSNumberZeroAndOneRemainNumbersWhileCFBooleansRemainBooleans() throws {
        let value: [String: Any] = [
            "false": false,
            "one": NSNumber(value: 1),
            "true": true,
            "zero": NSNumber(value: 0),
        ]
        let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(value))

        XCTAssertEqual(
            String(decoding: canonical, as: UTF8.self),
            #"{"false":false,"one":1,"true":true,"zero":0}"#
        )
    }
}
