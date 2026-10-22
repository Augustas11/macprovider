import CryptoKit
import Foundation
import XCTest
@testable import MacProviderCore

/// Issue #2084 SPEC-051-R011: HMAC-SHA256 frame protection with per-epoch, per-link
/// keys from a key agreement the two members sign with their receipt keys.
final class ShardLinkProtectionTests: XCTestCase {
    private let epoch: UInt64 = 7
    private let headSigner = ShardMemberSigner(memberDeviceID: "mac-a", key: Curve25519.Signing.PrivateKey())
    private let tailSigner = ShardMemberSigner(memberDeviceID: "mac-b", key: Curve25519.Signing.PrivateKey())

    private func configuration(epoch: UInt64? = nil, protection: ShardLinkFrameProtection = .hmacSHA256) -> ShardLinkConfiguration {
        ShardLinkConfiguration(groupEpoch: epoch ?? self.epoch, heartbeatInterval: 0.05, missedHeartbeatLimit: 4, frameProtection: protection)
    }

    /// A loopback pair: (accepted side, dialing side), not yet authenticated.
    private func pair(_ configuration: ShardLinkConfiguration) throws -> (ShardStageLink, ShardStageLink) {
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let dialed = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: configuration)
        let accepted = try listener.accept(timeout: 5, configuration: configuration)
        return (accepted, dialed)
    }

    /// Both ends authenticate concurrently, as two members do.
    private func authenticate(
        _ accepted: ShardStageLink, _ dialed: ShardStageLink, acceptedSigner: ShardMemberSigner? = nil, dialedSigner: ShardMemberSigner? = nil
    ) -> (Result<ShardLinkPeer?, Error>, Result<ShardLinkPeer?, Error>) {
        let box = ResultBox()
        let done = expectation(description: "responder authenticated")
        let responder = acceptedSigner ?? tailSigner
        DispatchQueue.global().async {
            box.value = Result { try accepted.authenticate(signer: responder, role: .responder, timeout: 3) }
            done.fulfill()
        }
        let initiator = Result { try dialed.authenticate(signer: dialedSigner ?? self.headSigner, role: .initiator, timeout: 3) }
        wait(for: [done], timeout: 5)
        return (box.value ?? .failure(ShardLinkError.closed), initiator)
    }

    private func activation(step: UInt32) -> ShardStageFrame {
        ShardStageFrame(
            header: ShardStageFrameHeader(
                kind: .activation, dtype: .bfloat16, groupEpoch: epoch, requestID: 1, tokenStep: step, sourceStage: 0,
                destinationStage: 1, layerStart: 0, layerEnd: 4, shape: [1, 1, 8]),
            payload: Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ Int(step)) }))
    }

    private func derivedKeys(epoch: UInt64) throws -> (initiator: ShardLinkHandshake.Keys, responder: ShardLinkHandshake.Keys) {
        let initiatorEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let responderEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let i = initiatorEphemeral.publicKey.rawRepresentation
        let r = responderEphemeral.publicKey.rawRepresentation
        let initiatorAuth = try ShardLinkHandshake.auth(signer: headSigner, epoch: epoch, role: .initiator, initiatorEphemeral: i, responderEphemeral: r)
        let responderAuth = try ShardLinkHandshake.auth(signer: tailSigner, epoch: epoch, role: .responder, initiatorEphemeral: i, responderEphemeral: r)
        let initiator = try ShardLinkHandshake.complete(
            ephemeral: initiatorEphemeral, role: .initiator, epoch: epoch, ownPublicKey: headSigner.publicKeyBase64,
            peerShare: .init(ephemeral: responderEphemeral.publicKey), peerAuth: responderAuth)
        let responder = try ShardLinkHandshake.complete(
            ephemeral: responderEphemeral, role: .responder, epoch: epoch, ownPublicKey: tailSigner.publicKeyBase64,
            peerShare: .init(ephemeral: initiatorEphemeral.publicKey), peerAuth: initiatorAuth)
        return (initiator.keys, responder.keys)
    }

    private func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    func testProtectedLinkAuthenticatesBothMembersAndCarriesTaggedFrames() throws {
        let (accepted, dialed) = try pair(configuration())
        defer { accepted.close(); dialed.close() }
        let (responderPeer, initiatorPeer) = authenticate(accepted, dialed)
        XCTAssertEqual(try responderPeer.get(), ShardLinkPeer(memberDeviceID: "mac-a", publicKey: headSigner.publicKeyBase64))
        XCTAssertEqual(try initiatorPeer.get(), ShardLinkPeer(memberDeviceID: "mac-b", publicKey: tailSigner.publicKeyBase64))
        XCTAssertEqual(dialed.peer?.memberDeviceID, "mac-b")
        for step in 0..<10 as Range<UInt32> {
            try dialed.send(activation(step: step))
            XCTAssertEqual(try accepted.receive(timeout: 2).header.tokenStep, step)
        }
        try accepted.send(ShardStageFrame(
            header: ShardStageFrameHeader(kind: .token, dtype: .int32, groupEpoch: epoch, shape: [1]), payload: Data([9, 0, 0, 0])))
        XCTAssertEqual(try dialed.receive(timeout: 2).payload, Data([9, 0, 0, 0]))
        // Tagged heartbeats keep the idle link alive once the keys are in place.
        XCTAssertThrowsError(try accepted.receive(timeout: 0.4)) { XCTAssertEqual($0 as? ShardLinkError, .receiveTimedOut) }
        XCTAssertGreaterThan(accepted.statistics.heartbeatsReceived, 2)
        // Each frame is the CRC32C frame plus the 32-byte tag.
        let sent = dialed.statistics
        XCTAssertGreaterThanOrEqual(sent.bytesSent, sent.framesSent * UInt64(ShardStageFrameCodec.fixedHeaderSize + 4 + ShardFrameAuthenticator.tagSize))
    }

    func testNothingButTheKeyAgreementCrossesBeforeTheKeysAreInPlace() throws {
        let (accepted, dialed) = try pair(configuration())
        defer { accepted.close(); dialed.close() }
        XCTAssertThrowsError(try dialed.send(activation(step: 0))) { XCTAssertEqual($0 as? ShardLinkError, .protectionNotEstablished) }
        // No heartbeat leaves an unauthenticated protected link.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(dialed.statistics.heartbeatsSent, 0)
        XCTAssertEqual(accepted.statistics.heartbeatsSent, 0)
    }

    func testCRC32CLinkSkipsTheKeyAgreement() throws {
        let (accepted, dialed) = try pair(configuration(protection: .crc32c))
        defer { accepted.close(); dialed.close() }
        XCTAssertNil(try dialed.authenticate(signer: headSigner, role: .initiator, timeout: 1))
        try dialed.send(activation(step: 0))
        XCTAssertEqual(try accepted.receive(timeout: 2).header.tokenStep, 0)
    }

    func testAProtectedMemberRefusesAnUnprotectedPeer() throws {
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let dialed = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: configuration(protection: .crc32c))
        let accepted = try listener.accept(timeout: 5, configuration: configuration())
        defer { accepted.close(); dialed.close() }
        try dialed.send(activation(step: 0))
        XCTAssertThrowsError(try accepted.authenticate(signer: tailSigner, role: .responder, timeout: 2)) { error in
            XCTAssertEqual(error as? ShardLinkError, .protectionNotEstablished)
        }
    }

    func testTamperedFrameIsRejected() throws {
        let keys = try derivedKeys(epoch: epoch)
        let sealed = ShardFrameAuthenticator(key: keys.initiator.send).seal(try ShardStageFrameCodec.encode(activation(step: 0)))
        let receiver = ShardFrameAuthenticator(key: keys.responder.receive)
        XCTAssertNoThrow(try receiver.open(sealed))
        // A flipped bit in the header, the payload, the CRC or the tag fails the tag.
        for offset in [8, ShardStageFrameCodec.fixedHeaderSize + 12 + 3, sealed.count - 33, sealed.count - 1] {
            var tampered = sealed
            tampered[offset] ^= 0x01
            XCTAssertThrowsError(try receiver.open(tampered), "offset \(offset)") {
                XCTAssertEqual($0 as? ShardFrameError, .authenticationFailed)
            }
        }
        // A frame whose CRC was recomputed after tampering still fails the tag.
        var frame = activation(step: 0)
        frame.payload[0] ^= 0xFF
        let forged = try ShardStageFrameCodec.encode(frame) + sealed.suffix(ShardFrameAuthenticator.tagSize)
        XCTAssertThrowsError(try receiver.open(forged)) { XCTAssertEqual($0 as? ShardFrameError, .authenticationFailed) }
    }

    func testAnotherEpochsOrLinksKeyIsRejected() throws {
        let current = try derivedKeys(epoch: epoch)
        let previous = try derivedKeys(epoch: epoch - 1)
        let otherLink = try derivedKeys(epoch: epoch)
        let encoded = try ShardStageFrameCodec.encode(activation(step: 0))
        var receiver = ShardProtectedReceiver(
            authenticator: ShardFrameAuthenticator(key: current.responder.receive), state: ShardLinkReceiveState(groupEpoch: epoch))
        for key in [previous.initiator.send, otherLink.initiator.send, current.responder.send, current.initiator.receive] {
            XCTAssertThrowsError(try receiver.accept(ShardFrameAuthenticator(key: key).seal(encoded))) {
                XCTAssertEqual($0 as? ShardFrameError, .authenticationFailed)
            }
        }
        XCTAssertEqual(try receiver.accept(ShardFrameAuthenticator(key: current.initiator.send).seal(encoded)).header.tokenStep, 0)
        // Fresh keys per link and per epoch: no two agreements share a key.
        let all = [current, previous, otherLink].flatMap { [$0.initiator.send, $0.initiator.receive] }.map(raw)
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(raw(current.initiator.send), raw(current.responder.receive))
        XCTAssertEqual(raw(current.initiator.receive), raw(current.responder.send))
    }

    func testReplayedFrameIsRejected() throws {
        let keys = try derivedKeys(epoch: epoch)
        let sender = ShardFrameAuthenticator(key: keys.initiator.send)
        var receiver = ShardProtectedReceiver(
            authenticator: ShardFrameAuthenticator(key: keys.responder.receive), state: ShardLinkReceiveState(groupEpoch: epoch))
        var first = activation(step: 0)
        first.header.sequence = 0
        let sealed = sender.seal(try ShardStageFrameCodec.encode(first))
        XCTAssertNoThrow(try receiver.accept(sealed))
        // The tag still verifies, but the sequence number repeats (SPEC-051-R012).
        XCTAssertThrowsError(try receiver.accept(sealed)) {
            XCTAssertEqual($0 as? ShardFrameError, .sequenceReplay(expected: 1, actual: 0))
        }
        // Rewriting the sequence number to the expected one breaks the tag.
        var bytes = sealed
        bytes[44] = 1
        XCTAssertThrowsError(try receiver.accept(bytes)) { XCTAssertEqual($0 as? ShardFrameError, .authenticationFailed) }
    }

    func testKeyAgreementRefusesForgedOrReflectedMessages() throws {
        let initiatorEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let responderEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let i = initiatorEphemeral.publicKey.rawRepresentation
        let r = responderEphemeral.publicKey.rawRepresentation
        func complete(_ auth: ShardLinkHandshake.Auth, share: ShardLinkHandshake.Share? = nil) throws {
            _ = try ShardLinkHandshake.complete(
                ephemeral: initiatorEphemeral, role: .initiator, epoch: epoch, ownPublicKey: headSigner.publicKeyBase64,
                peerShare: share ?? .init(ephemeral: responderEphemeral.publicKey), peerAuth: auth)
        }
        let good = try ShardLinkHandshake.auth(signer: tailSigner, epoch: epoch, role: .responder, initiatorEphemeral: i, responderEphemeral: r)
        XCTAssertNoThrow(try complete(good))
        let otherEpoch = try ShardLinkHandshake.auth(signer: tailSigner, epoch: epoch + 1, role: .responder, initiatorEphemeral: i, responderEphemeral: r)
        let wrongRole = try ShardLinkHandshake.auth(signer: tailSigner, epoch: epoch, role: .initiator, initiatorEphemeral: i, responderEphemeral: r)
        let otherExchange = try ShardLinkHandshake.auth(
            signer: tailSigner, epoch: epoch, role: .responder, initiatorEphemeral: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            responderEphemeral: r)
        let impostor = ShardLinkHandshake.Auth(memberDeviceID: "mac-b", publicKey: headSigner.publicKeyBase64, signature: good.signature)
        for forged in [otherEpoch, wrongRole, otherExchange, impostor] {
            XCTAssertThrowsError(try complete(forged)) { error in
                XCTAssertEqual(error as? ShardLinkHandshake.Failure, .signatureInvalid(memberDeviceID: "mac-b"))
            }
        }
        XCTAssertThrowsError(try complete(good, share: .init(ephemeral: initiatorEphemeral.publicKey))) {
            XCTAssertEqual($0 as? ShardLinkHandshake.Failure, .reflected)
        }
    }

    func testDerivedKeysNeverTravelInTheKeyAgreement() throws {
        // The four messages of one agreement, exactly as the link encodes them.
        let initiatorEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let responderEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let i = initiatorEphemeral.publicKey.rawRepresentation
        let r = responderEphemeral.publicKey.rawRepresentation
        let initiatorShare = ShardLinkHandshake.Share(ephemeral: initiatorEphemeral.publicKey)
        let responderShare = ShardLinkHandshake.Share(ephemeral: responderEphemeral.publicKey)
        let initiatorAuth = try ShardLinkHandshake.auth(signer: headSigner, epoch: epoch, role: .initiator, initiatorEphemeral: i, responderEphemeral: r)
        let responderAuth = try ShardLinkHandshake.auth(signer: tailSigner, epoch: epoch, role: .responder, initiatorEphemeral: i, responderEphemeral: r)
        let encoder = JSONEncoder()
        let wire = try [encoder.encode(initiatorShare), encoder.encode(responderShare), encoder.encode(initiatorAuth), encoder.encode(responderAuth)]
            .reduce(Data(), +)
        let initiator = try ShardLinkHandshake.complete(
            ephemeral: initiatorEphemeral, role: .initiator, epoch: epoch, ownPublicKey: headSigner.publicKeyBase64,
            peerShare: responderShare, peerAuth: responderAuth)
        let responder = try ShardLinkHandshake.complete(
            ephemeral: responderEphemeral, role: .responder, epoch: epoch, ownPublicKey: tailSigner.publicKeyBase64,
            peerShare: initiatorShare, peerAuth: initiatorAuth)
        XCTAssertEqual(raw(initiator.keys.send), raw(responder.keys.receive))
        // Only public values cross: ephemeral public keys, identities and signatures.
        for key in [initiator.keys.send, initiator.keys.receive] {
            XCTAssertNil(wire.range(of: raw(key)))
            XCTAssertNil(wire.range(of: Data(raw(key).base64EncodedString().utf8)))
        }
        for message in [try encoder.encode(initiatorShare), try encoder.encode(initiatorAuth)] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: message) as? [String: Any])
            XCTAssertTrue(Set(object.keys).isSubset(of: ["op", "ephemeral", "member_device_id", "public_key", "signature"]))
        }
        // The same members agreeing again at the same epoch get fresh keys.
        let again = try derivedKeys(epoch: epoch)
        XCTAssertNotEqual(raw(again.initiator.send), raw(initiator.keys.send))
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<ShardLinkPeer?, Error>?
}
