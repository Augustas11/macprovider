import CryptoKit
import Foundation
import XCTest
@testable import MacProviderCore

/// Issue #2084 SPEC-051-R023: a member's link follows the head to a later epoch
/// (a rebuild after a takeover) and refuses an earlier one.
final class ShardLinkEpochTests: XCTestCase {
    private func pair(headEpoch: UInt64, memberMinimum: UInt64, protection: ShardLinkFrameProtection = .crc32c) throws -> (member: ShardStageLink, head: ShardStageLink) {
        let member = ShardLinkConfiguration(
            groupEpoch: memberMinimum, heartbeatInterval: 0.05, missedHeartbeatLimit: 4, armLivenessOnOpen: false,
            frameProtection: protection, adoptsHigherEpoch: true)
        let head = ShardLinkConfiguration(
            groupEpoch: headEpoch, heartbeatInterval: 0.05, missedHeartbeatLimit: 4, armLivenessOnOpen: false, frameProtection: protection)
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let dialed = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: head)
        return (try listener.accept(timeout: 5, configuration: member), dialed)
    }

    private func hello() -> ShardStageFrame {
        ShardStageFrame(header: ShardStageFrameHeader(kind: .hello, groupEpoch: 0), payload: Data("{}".utf8))
    }

    func testAMemberAdoptsAHigherHeadEpochAndSendsNothingBefore() throws {
        let (member, head) = try pair(headEpoch: 7, memberMinimum: 5)
        defer { member.close(); head.close() }
        XCTAssertThrowsError(try member.send(hello())) { XCTAssertEqual($0 as? ShardLinkError, .epochNotSettled) }
        // The head's first frame (its first heartbeat here) names the epoch.
        XCTAssertEqual(try member.awaitSettledEpoch(timeout: 2), 7)
        try head.send(hello())
        XCTAssertEqual(try member.receive(timeout: 2).header.groupEpoch, 7)
        XCTAssertEqual(member.groupEpoch, 7)
        XCTAssertEqual(try member.awaitSettledEpoch(timeout: 1), 7)
        try member.send(hello())
        XCTAssertEqual(try head.receive(timeout: 2).header.groupEpoch, 7)
        // Heartbeats now flow both ways at the adopted epoch.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertGreaterThan(head.statistics.heartbeatsReceived, 0)
    }

    func testAMemberRefusesALowerHeadEpoch() throws {
        let (member, head) = try pair(headEpoch: 4, memberMinimum: 5)
        defer { member.close(); head.close() }
        try head.send(hello())
        XCTAssertThrowsError(try member.receive(timeout: 2)) { error in
            XCTAssertEqual(error as? ShardLinkError, .frame(.epochMismatch(expected: 5, actual: 4)))
        }
        XCTAssertThrowsError(try member.awaitSettledEpoch(timeout: 0.5))
    }

    func testAnHMACMemberAdoptsTheEpochItsKeyAgreementNames() throws {
        let (member, head) = try pair(headEpoch: 9, memberMinimum: 5, protection: .hmacSHA256)
        defer { member.close(); head.close() }
        let memberSigner = ShardMemberSigner(memberDeviceID: "mac-b", key: Curve25519.Signing.PrivateKey())
        let headSigner = ShardMemberSigner(memberDeviceID: "mac-a", key: Curve25519.Signing.PrivateKey())
        let done = expectation(description: "member authenticated")
        let outcome = PeerBox()
        DispatchQueue.global().async {
            outcome.result = Result { try member.authenticate(signer: memberSigner, role: .responder, timeout: 3) }
            done.fulfill()
        }
        XCTAssertEqual(try head.authenticate(signer: headSigner, role: .initiator, timeout: 3)?.memberDeviceID, "mac-b")
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try outcome.result?.get()?.memberDeviceID, "mac-a")
        XCTAssertEqual(member.groupEpoch, 9)
        try head.send(hello())
        XCTAssertEqual(try member.receive(timeout: 2).header.groupEpoch, 9)
    }
}

private final class PeerBox: @unchecked Sendable {
    var result: Result<ShardLinkPeer?, Error>?
}
