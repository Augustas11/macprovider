import CryptoKit
import XCTest
@testable import MacProviderCore

/// Issue #2084 slice 4: chained activation digests, member sub-receipts and the
/// chain verifier (SPEC-051-R019).
final class ShardGroupAttestationTests: XCTestCase {
    private func chain(_ frames: [(UInt32, Data)], request: UInt64 = 7) -> String {
        var digest = ShardActivationDigestChain()
        for (step, payload) in frames { digest.fold(requestID: request, tokenStep: step, payload: payload) }
        return digest.hex
    }

    private func receipt(_ member: String, stage: Int, layers: Range<Int>, inDigest: String, outDigest: String,
                         request: UInt64 = 7, epoch: UInt64 = 4) -> ShardMemberSubReceipt {
        ShardMemberSubReceipt(
            memberDeviceID: member, groupEpoch: epoch, stageIndex: stage, layerStart: layers.lowerBound,
            layerEnd: layers.upperBound, requestID: request, promptTokens: 5, decodeSteps: 1,
            inDigest: inDigest, outDigest: outDigest)
    }

    /// A three-stage request where every member reports exactly what crossed its links.
    private func honestChain() -> [ShardMemberSubReceipt] {
        let headOut = [(UInt32(0), Data([1, 2, 3])), (1, Data([4, 5]))]
        let middleOut = [(UInt32(0), Data([9, 9, 9])), (1, Data([8]))]
        let tokens = [(UInt32(0), Data([42, 0, 0, 0])), (1, Data([43, 0, 0, 0]))]
        return [
            receipt("head", stage: 0, layers: 0..<10, inDigest: chain(tokens), outDigest: chain(headOut)),
            receipt("middle", stage: 1, layers: 10..<20, inDigest: chain(headOut), outDigest: chain(middleOut)),
            receipt("tail", stage: 2, layers: 20..<32, inDigest: chain(middleOut), outDigest: chain(tokens)),
        ]
    }

    func testDigestChainFoldsRequestStepAndPayloadInOrder() {
        var digest = ShardActivationDigestChain()
        XCTAssertEqual(digest.hex, String(repeating: "0", count: 64))
        digest.fold(requestID: 7, tokenStep: 0, payload: Data([1, 2, 3]))
        var expected = SHA256()
        expected.update(data: [UInt8](repeating: 0, count: 32))
        expected.update(data: [7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        expected.update(data: Array(SHA256.hash(data: Data([1, 2, 3]))))
        XCTAssertEqual(digest.value, Array(expected.finalize()))
        XCTAssertEqual(digest.frames, 1)

        let a = (UInt32(0), Data([1])), b = (UInt32(1), Data([2]))
        XCTAssertNotEqual(chain([a, b]), chain([b, a]), "order matters")
        XCTAssertNotEqual(chain([a]), chain([a], request: 8), "the request is bound")
        XCTAssertNotEqual(chain([a]), chain([(1, Data([1]))]), "the step is bound")
    }

    func testCanonicalJSONIsSortedAndCompact() throws {
        let json = try receipt("mac-a", stage: 1, layers: 3..<9, inDigest: "aa", outDigest: "bb").canonicalJSON()
        XCTAssertEqual(
            String(decoding: json, as: UTF8.self),
            #"{"decode_steps":1,"group_epoch":4,"in_digest":"aa","layer_end":9,"layer_start":3,"member_device_id":"mac-a","out_digest":"bb","prompt_tokens":5,"request_id":7,"stage_index":1}"#)
        XCTAssertEqual(try JSONDecoder().decode(ShardMemberSubReceipt.self, from: json).memberDeviceID, "mac-a")
    }

    func testHonestChainVerifies() {
        XCTAssertEqual(ShardGroupAttestationVerifier.verify(honestChain()), .ok)
    }

    func testTamperedMiddleBreaksTheLinkAfterIt() {
        var receipts = honestChain()
        // The middle claims it sent different bytes than the tail received.
        receipts[1].outDigest = chain([(0, Data([9, 9, 7])), (1, Data([8]))])
        guard case .broken(let fault) = ShardGroupAttestationVerifier.verify(receipts) else { return XCTFail("tamper not detected") }
        XCTAssertEqual(fault.kind, .digestMismatch)
        XCTAssertEqual([fault.fromStage, fault.toStage], [1, 2])
        XCTAssertEqual(fault.fromMember, "middle")
        XCTAssertEqual(fault.toMember, "tail")
    }

    func testTamperedTokensBreakTheReturnLink() {
        var receipts = honestChain()
        receipts[2].outDigest = chain([(0, Data([41, 0, 0, 0])), (1, Data([43, 0, 0, 0]))])
        guard case .broken(let fault) = ShardGroupAttestationVerifier.verify(receipts) else { return XCTFail("tamper not detected") }
        XCTAssertEqual(fault.kind, .digestMismatch)
        XCTAssertEqual([fault.fromStage, fault.toStage], [2, 0])
    }

    func testReorderedMembersAreRefused() {
        let honest = honestChain()
        guard case .broken(let fault) = ShardGroupAttestationVerifier.verify([honest[0], honest[2], honest[1]]) else {
            return XCTFail("reorder not detected")
        }
        XCTAssertEqual(fault.kind, .stageOrder)
        XCTAssertEqual(fault.toStage, 1)

        // Swapping the stage indices too still breaks: the layers no longer chain.
        var swapped = [honest[0], honest[2], honest[1]]
        swapped[1].stageIndex = 1
        swapped[2].stageIndex = 2
        guard case .broken(let second) = ShardGroupAttestationVerifier.verify(swapped) else { return XCTFail("swap not detected") }
        XCTAssertEqual(second.kind, .layerGap)
        XCTAssertEqual([second.fromStage, second.toStage], [0, 1])
    }

    func testMixedRequestsEpochsAndShortChainsAreRefused() {
        var receipts = honestChain()
        receipts[2].requestID = 8
        guard case .broken(let request) = ShardGroupAttestationVerifier.verify(receipts) else { return XCTFail() }
        XCTAssertEqual(request.kind, .requestMismatch)

        receipts = honestChain()
        receipts[1].groupEpoch = 5
        guard case .broken(let epoch) = ShardGroupAttestationVerifier.verify(receipts) else { return XCTFail() }
        XCTAssertEqual(epoch.kind, .epochMismatch)

        guard case .broken(let short) = ShardGroupAttestationVerifier.verify([honestChain()[0]]) else { return XCTFail() }
        XCTAssertEqual(short.kind, .tooFewMembers)
    }

    // MARK: Member signatures

    private func signedChain(keys: [Curve25519.Signing.PrivateKey]) throws -> [ShardSignedSubReceipt] {
        try zip(honestChain(), keys).map { receipt, key in
            try ShardMemberSigner(memberDeviceID: receipt.memberDeviceID, key: key).sign(receipt)
        }
    }

    func testSignedSubReceiptsVerifyUnderTheMembersKeys() throws {
        let keys = (0..<3).map { _ in Curve25519.Signing.PrivateKey() }
        let signed = try signedChain(keys: keys)
        XCTAssertTrue(signed.allSatisfy(\.signatureIsValid))
        XCTAssertEqual(signed[1].publicKey, keys[1].publicKey.rawRepresentation.base64EncodedString())
        // The signature covers the domain-separated canonical JSON, nothing else.
        let message = Data("macprovider.shard-sub-receipt.v1\n".utf8) + (try signed[1].receipt.canonicalJSON())
        XCTAssertTrue(keys[1].publicKey.isValidSignature(try XCTUnwrap(Data(base64Encoded: signed[1].signature)), for: message))
        let expected = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.offset, $0.element.publicKey.rawRepresentation.base64EncodedString()) })
        XCTAssertEqual(ShardGroupAttestationVerifier.verify(signed: signed, expectedKeys: expected), .ok)
        // Wire form round-trips with snake_case keys.
        let json = try JSONEncoder().encode(signed[0])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sub_receipt", "public_key", "signature"])
        XCTAssertEqual(try JSONDecoder().decode(ShardSignedSubReceipt.self, from: json), signed[0])
    }

    func testAlteredSubReceiptFailsItsSignature() throws {
        var signed = try signedChain(keys: (0..<3).map { _ in Curve25519.Signing.PrivateKey() })
        signed[2].receipt.decodeSteps += 1
        XCTAssertFalse(signed[2].signatureIsValid)
        guard case .broken(let fault) = ShardGroupAttestationVerifier.verify(signed: signed) else {
            return XCTFail("an altered sub-receipt must not verify")
        }
        XCTAssertEqual(fault.kind, .signatureInvalid)
        XCTAssertEqual(fault.toMember, "tail")
    }

    func testSubReceiptSignedByAnotherKeyThanAnnouncedIsRefused() throws {
        let keys = (0..<3).map { _ in Curve25519.Signing.PrivateKey() }
        let signed = try signedChain(keys: keys)
        let announced = [1: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()]
        guard case .broken(let fault) = ShardGroupAttestationVerifier.verify(signed: signed, expectedKeys: announced) else {
            return XCTFail("a key other than the announced one must not verify")
        }
        XCTAssertEqual(fault.kind, .keyMismatch)
        XCTAssertEqual(fault.fromMember, "middle")
    }

    func testValidSignaturesDoNotHideABrokenChain() throws {
        var receipts = honestChain()
        receipts[1].outDigest = String(repeating: "f", count: 64)
        let signed = try receipts.map { try ShardMemberSigner(memberDeviceID: $0.memberDeviceID, key: Curve25519.Signing.PrivateKey()).sign($0) }
        guard case .broken(let fault) = ShardGroupAttestationVerifier.verify(signed: signed) else {
            return XCTFail("the chain check must still run")
        }
        XCTAssertEqual(fault.kind, .digestMismatch)
        XCTAssertEqual([fault.fromStage, fault.toStage], [1, 2])
    }
}
