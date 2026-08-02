import XCTest
@testable import Malibu

final class PayoutWalletFlowTests: XCTestCase {
    func testNonceIs0xPrefixed32Bytes() {
        let nonce = PayoutWalletFlow.randomNonceHex()
        XCTAssertTrue(nonce.hasPrefix("0x"))
        XCTAssertEqual(nonce.count, 2 + 64)
        let hex = nonce.dropFirst(2)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
    }

    func testValidateCallbackAcceptsWellFormedPayload() {
        let address = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
        let nonce = "0x" + String(repeating: "ab", count: 32)
        let sig = "0x" + String(repeating: "cd", count: 65)
        let payload = PayoutSignedPayload(
            address: address,
            nonce: nonce,
            tsUtc: 1_719_234_896,
            signature: sig,
            state: "deadbeef"
        )
        XCTAssertTrue(
            PayoutWalletFlow.validateCallback(
                payload: payload,
                expectedState: "deadbeef",
                expectedNonce: nonce,
                expectedTsUtc: 1_719_234_896
            )
        )
    }

    func testValidateCallbackRejectsStateMismatchAndBadLengths() {
        let nonce = "0x" + String(repeating: "11", count: 32)
        let good = PayoutSignedPayload(
            address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            nonce: nonce,
            tsUtc: 10,
            signature: "0x" + String(repeating: "22", count: 65),
            state: "aaa"
        )
        XCTAssertFalse(
            PayoutWalletFlow.validateCallback(
                payload: good,
                expectedState: "bbb",
                expectedNonce: nonce,
                expectedTsUtc: 10
            )
        )
        let shortSig = PayoutSignedPayload(
            address: good.address,
            nonce: nonce,
            tsUtc: 10,
            signature: "0xdead",
            state: "aaa"
        )
        XCTAssertFalse(
            PayoutWalletFlow.validateCallback(
                payload: shortSig,
                expectedState: "aaa",
                expectedNonce: nonce,
                expectedTsUtc: 10
            )
        )
    }

    func testTsUtcPrefersServerWithinSkew() {
        let server: Int64 = 1_700_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(server + 30))
        XCTAssertEqual(PayoutWalletFlow.tsUtc(serverTsUTC: server, now: now), UInt64(server))
        let far = Date(timeIntervalSince1970: TimeInterval(server + 600))
        XCTAssertEqual(
            PayoutWalletFlow.tsUtc(serverTsUTC: server, now: far),
            UInt64(far.timeIntervalSince1970.rounded())
        )
    }

    func testTruncateAddress() {
        let full = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
        XCTAssertEqual(PayoutWalletFlow.truncateAddress(full), "0x7099…79C8")
    }

    func testRegistrationStoreRoundTrip() {
        PayoutRegistrationStore.clear()
        defer { PayoutRegistrationStore.clear() }
        PayoutRegistrationStore.save(
            address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            pendingUntilUTC: "2026-01-09T00:00:00Z"
        )
        let loaded = PayoutRegistrationStore.load()
        XCTAssertEqual(loaded?.address, "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
        XCTAssertEqual(loaded?.pendingUntilUTC, "2026-01-09T00:00:00Z")
    }
}
