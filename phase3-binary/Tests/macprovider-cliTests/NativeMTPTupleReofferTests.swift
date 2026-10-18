import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-048-R016 (v0.1.48) re-offer policy after a coordinator
/// `bank_mismatch`. CPU-only: no model, no Metal.
final class NativeMTPTupleReofferTests: XCTestCase {
    static func offer(bank: String = String(repeating: "b", count: 64), generation: UInt64 = 7) -> NativeMTPPublishedTupleOffer {
        NativeMTPPublishedTupleOffer(
            targetGeneration: generation,
            providerRevision: "1.8.251",
            runtimeRevision: "mlx-swift-lm-test",
            runtimeTuple: NativeMTPPublishedRuntimeTuple(
                modelID: "model-a",
                modelHash: String(repeating: "a", count: 64),
                modelHashAlgorithm: "sha256",
                providerRevision: "1.8.251",
                runtimeRevision: "mlx-swift-lm-test",
                tokenizerDigest: String(repeating: "1", count: 64),
                artifactDigest: String(repeating: "2", count: 64),
                manifestDigest: String(repeating: "3", count: 64),
                sidecarDigest: String(repeating: "4", count: 64),
                providerBinarySHA256: String(repeating: "5", count: 64),
                runtimeCDHash: String(repeating: "6", count: 40),
                cacheNamespace: "native-mtp-test",
                stateDigest: String(repeating: "8", count: 64),
                proposalDepth: 1
            ),
            nativeMTPAdmissionTupleSHA256: String(repeating: "7", count: 64),
            servedSnapshotID: "snapshot-a",
            sidecarDigest: String(repeating: "4", count: 64),
            challengeBankReleaseID: "release-new",
            challengeBankSHA256: bank,
            challengeCorpusSHA256: bank,
            selftestProfile: "native_mtp_selftest_v1",
            selftestPassDigest: String(repeating: "9", count: 64),
            selftestObservedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    func testNothingIsDueUntilATupleIsParked() {
        var gate = NativeMTPTupleReofferGate()
        XCTAssertFalse(gate.awaitingReoffer)
        XCTAssertNil(gate.reofferDue(session: 1, observedCoordinatorBankSHA256: Self.offer().challengeBankSHA256))
    }

    func testANewSessionReoffersOnceAndTheRejectingSessionNever() {
        let offer = Self.offer()
        var gate = NativeMTPTupleReofferGate()
        gate.park(offer, session: 4, observedCoordinatorBankSHA256: nil)
        XCTAssertTrue(gate.awaitingReoffer)
        XCTAssertNil(gate.reofferDue(session: 4, observedCoordinatorBankSHA256: nil), "the rejecting session must not re-offer")
        XCTAssertEqual(gate.reofferDue(session: 5, observedCoordinatorBankSHA256: nil), offer)
        XCTAssertNil(gate.reofferDue(session: 5, observedCoordinatorBankSHA256: nil), "one re-offer per session")
    }

    func testACoordinatorBankChangeToTheOfferedBankReoffersOncePerSession() {
        let offer = Self.offer()
        let stale = String(repeating: "c", count: 64)
        var gate = NativeMTPTupleReofferGate()
        gate.park(offer, session: 4, observedCoordinatorBankSHA256: stale)
        XCTAssertNil(gate.reofferDue(session: 4, observedCoordinatorBankSHA256: stale))
        XCTAssertNil(gate.reofferDue(session: 4, observedCoordinatorBankSHA256: String(repeating: "d", count: 64)),
                     "a bank change to a bank this provider did not qualify on is not a trigger")
        XCTAssertEqual(gate.reofferDue(session: 4, observedCoordinatorBankSHA256: offer.challengeBankSHA256), offer)
        XCTAssertNil(gate.reofferDue(session: 4, observedCoordinatorBankSHA256: offer.challengeBankSHA256))
    }

    func testRepeatedRejectionsNeverLoop() {
        let offer = Self.offer()
        var gate = NativeMTPTupleReofferGate()
        gate.park(offer, session: 4, observedCoordinatorBankSHA256: nil)
        XCTAssertEqual(gate.reofferDue(session: 5, observedCoordinatorBankSHA256: nil), offer)
        gate.markRestored()
        XCTAssertFalse(gate.awaitingReoffer)
        XCTAssertNil(gate.reofferDue(session: 6, observedCoordinatorBankSHA256: nil), "a restored tuple is not re-offered")
        // Rejected again in session 5, with the coordinator serving our bank:
        // no trigger remains in session 5.
        gate.park(offer, session: 5, observedCoordinatorBankSHA256: offer.challengeBankSHA256)
        XCTAssertNil(gate.reofferDue(session: 5, observedCoordinatorBankSHA256: nil))
        XCTAssertNil(gate.reofferDue(session: 5, observedCoordinatorBankSHA256: offer.challengeBankSHA256))
        // Only a later session tries again.
        XCTAssertEqual(gate.reofferDue(session: 6, observedCoordinatorBankSHA256: offer.challengeBankSHA256), offer)
    }

    func testClearDropsTheParkedTuple() {
        var gate = NativeMTPTupleReofferGate()
        gate.park(Self.offer(), session: 1, observedCoordinatorBankSHA256: nil)
        gate.clear()
        XCTAssertFalse(gate.awaitingReoffer)
        XCTAssertNil(gate.reofferDue(session: 2, observedCoordinatorBankSHA256: nil))
    }

    func testParkingADifferentTupleStartsFresh() {
        var gate = NativeMTPTupleReofferGate()
        gate.park(Self.offer(generation: 7), session: 1, observedCoordinatorBankSHA256: nil)
        _ = gate.reofferDue(session: 2, observedCoordinatorBankSHA256: nil)
        let next = Self.offer(generation: 8)
        gate.park(next, session: 2, observedCoordinatorBankSHA256: nil)
        XCTAssertEqual(gate.reofferDue(session: 3, observedCoordinatorBankSHA256: nil), next)
    }

    func testServedBankPollBacksOffToFifteenMinutes() {
        XCTAssertEqual((0..<8).map(NativeMTPServedBankPoll.delaySeconds(attempt:)), [60, 120, 240, 480, 900, 900, 900, 900])
        XCTAssertEqual(NativeMTPServedBankPoll.delaySeconds(attempt: Int.max), 900)
    }

    func testServedBankDigestIsTheSHA256OfTheServedBytesOrNil() async {
        let bank = Data(#"{"schema_version":"macprovider.native-mtp-challenge-bank.v1"}"#.utf8)
        let base = URL(string: "https://coordinator.example")!
        let digest = await NativeMTPAdmissionFeed.servedBankSHA256(
            fetcher: { url, _ in
                XCTAssertEqual(url.path, "/v1/native-mtp-selftest-bank")
                return .init(statusCode: 200, body: bank)
            },
            baseURL: base
        )
        XCTAssertEqual(digest, SHA256.hash(data: bank).map { String(format: "%02x", $0) }.joined())
        let missing = await NativeMTPAdmissionFeed.servedBankSHA256(
            fetcher: { _, _ in .init(statusCode: 404, body: Data("{}".utf8)) },
            baseURL: base
        )
        XCTAssertNil(missing)
        let redirected = await NativeMTPAdmissionFeed.servedBankSHA256(
            fetcher: { _, _ in .init(statusCode: 200, body: bank, redirected: true) },
            baseURL: base
        )
        XCTAssertNil(redirected)
    }
}
