import CryptoKit
import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084: cross-language golden vectors for the SPEC-051 group messages and
/// attestation, shared with the coordinator at
/// `test/fixtures/shard-group/wire-golden-v1.json`. Inputs and keys are fixed; Ed25519
/// signatures from CryptoKit are randomized, so the file's signatures are checked
/// by verification and every other byte by equality. Set
/// `SHARD_WIRE_GOLDEN_WRITE=1` to rewrite the file after a deliberate wire change.
final class ShardGroupWireGoldenTests: XCTestCase {
    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../test/fixtures/shard-group/wire-golden-v1.json").standardizedFileURL
    }

    private let headKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
    private let tailKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    private let artifactHash = String(repeating: "c", count: 64)

    private func generate() throws -> [String: Any] {
        let epoch: UInt64 = 3
        let config = ShardGroupHeadConfig(
            groupEpoch: epoch, poolModelID: "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b", headLayerEnd: 14,
            stages: [ShardGroupStageConfig(memberDeviceID: "mac-b", endpoint: "169.254.1.2:7101", layerStart: 14, layerEnd: 28)],
            maxConcurrency: 4)
        let probe = ShardBenchLatency(seconds: [0.0004])
        let chain = [
            ShardBenchHello(role: .head, modelType: "llama", totalLayers: 28, hiddenSize: 3072, layerStart: 0, layerEnd: 14,
                            memberDeviceID: "prov-head"),
            ShardBenchHello(role: .tail, modelType: "llama", totalLayers: 28, hiddenSize: 3072, layerStart: 14, layerEnd: 28,
                            upstreamProbe: probe, memberDeviceID: "mac-b", upstreamInterface: ShardLinkInterface.thunderbolt),
        ]
        let record = try ShardGroupWire.record(
            config: config, chain: chain, groupEpoch: epoch, providerID: "prov-head", wireModelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            poolModelID: "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b", artifactHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1, artifactHash: artifactHash)
        let register = try ShardGroupWire.register(record: record, key: headKey)
        let links = ShardGroupWire.linkReports(chain: chain, providerID: "prov-head", health: nil, now: 0, staleAfter: 1)
        let heartbeat = try ShardGroupWire.heartbeat(
            groupEpoch: epoch, providerID: "prov-head", chain: chain,
            members: ShardGroupWire.memberHealth(chainCount: chain.count, running: true, links: links), links: links)
        let hello = try XCTUnwrap(try ShardGroupWire.memberHello(
            config: ShardMemberConfig(groupProviderID: "prov-head", groupEpoch: epoch, stageIndex: 1, layerStart: 14, layerEnd: 28, listen: "0.0.0.0:7101"),
            status: ShardMemberStatus(
                listening: true, chain: chain, stageIndex: 1, upstreamPeer: "prov-head", downstreamPeer: "prov-head",
                upstreamInterface: ShardLinkInterface.thunderbolt, downstreamInterface: ShardLinkInterface.thunderbolt,
                sessionsServed: 0, lastError: nil),
            memberDeviceID: "mac-b", artifactHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1, artifactHash: artifactHash))

        // Head out == tail in; tail out == head in.
        let activations = String(repeating: "a1", count: 32)
        let tokens = String(repeating: "b2", count: 32)
        let receipts = try [
            ShardMemberSigner(memberDeviceID: "prov-head", key: headKey).sign(ShardMemberSubReceipt(
                memberDeviceID: "prov-head", groupEpoch: epoch, stageIndex: 0, layerStart: 0, layerEnd: 14, requestID: "req_golden_1",
                promptTokens: 12, decodeSteps: 4, inDigest: tokens, outDigest: activations)),
            ShardMemberSigner(memberDeviceID: "mac-b", key: tailKey).sign(ShardMemberSubReceipt(
                memberDeviceID: "mac-b", groupEpoch: epoch, stageIndex: 1, layerStart: 14, layerEnd: 28, requestID: "req_golden_1",
                promptTokens: 12, decodeSteps: 4, inDigest: activations, outDigest: tokens)),
        ]
        let tuple = Data(#"{"attempt_n":1,"provider_id":"prov-head","receipt_version":"4","request_id":"req_golden_1"}"#.utf8)
        let receipt = tuple.base64EncodedString() + "." + Data(repeating: 0x33, count: 64).base64EncodedString()
        let attestation = try ShardGroupWire.attestation(
            receipt: receipt,
            evidence: ShardGroupCompletionEvidence(
                attestation: ShardRequestAttestation(verdict: "ok", fault: nil, groupEpoch: epoch, receipts: receipts, replays: []),
                tokenSteps: 5),
            key: headKey)
        return [
            "head_public_key": headKey.publicKey.rawRepresentation.base64EncodedString(),
            "tail_public_key": tailKey.publicKey.rawRepresentation.base64EncodedString(),
            "receipt": receipt,
            "shard_group_register": try JSONSerialization.jsonObject(with: register),
            "shard_group_heartbeat": try JSONSerialization.jsonObject(with: heartbeat),
            "shard_member_hello": try JSONSerialization.jsonObject(with: hello),
            "group_attestation": attestation,
        ]
    }

    /// The value with every signature member removed, for byte-stable comparison.
    private func unsigned(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { $0.key != "signature" && $0.key != "record_signature" }.mapValues { unsigned($0) }
        case let array as [Any]:
            return array.map { unsigned($0) }
        default:
            return value
        }
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    func testGoldenVectorsMatchTheProviderEncodingAndVerify() throws {
        let generated = try generate()
        if ProcessInfo.processInfo.environment["SHARD_WIRE_GOLDEN_WRITE"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: generated, options: [.sortedKeys, .prettyPrinted]).write(to: Self.goldenURL)
        }
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.goldenURL)) as? [String: Any])
        XCTAssertEqual(try canonical(unsigned(golden)), try canonical(unsigned(generated)), "provider encoding drifted from the golden vectors")

        // Record signature: head receipt key over the record domain and JCS(record).
        let register = try XCTUnwrap(golden["shard_group_register"] as? [String: Any])
        let record = try XCTUnwrap(register["record"] as? [String: Any])
        let recordSignature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(register["record_signature"] as? String)))
        XCTAssertTrue(headKey.publicKey.isValidSignature(
            recordSignature, for: Data(("macprovider.shard-group-record.v1\n" + (try RFC8785JCS.canonicalStringRawStrings(jcs(record)))).utf8)))

        // Attestation signature: head receipt key over the domain and JCS(object without signature).
        var attestation = try XCTUnwrap(golden["group_attestation"] as? [String: Any])
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(attestation.removeValue(forKey: "signature") as? String)))
        XCTAssertTrue(headKey.publicKey.isValidSignature(
            signature, for: Data(("macprovider.shard-group-attestation.v1\n" + (try RFC8785JCS.canonicalStringRawStrings(jcs(attestation)))).utf8)))
        let segments = try XCTUnwrap(attestation["segments"] as? [[String: Any]])
        let subReceipts = try XCTUnwrap(segments.first?["sub_receipts"] as? [Any])
        let decoded = try subReceipts.map { try JSONDecoder().decode(ShardSignedSubReceipt.self, from: JSONSerialization.data(withJSONObject: $0)) }
        XCTAssertTrue(decoded.allSatisfy(\.signatureIsValid))
        XCTAssertEqual(decoded.map(\.publicKey), [golden["head_public_key"] as? String, golden["tail_public_key"] as? String].compactMap { $0 })
        XCTAssertEqual(ShardGroupAttestationVerifier.verify(signed: decoded), .ok)
    }

    private func jcs(_ value: Any) -> RFC8785JCS.Value {
        switch value {
        case let object as [String: Any]: return .object(object.mapValues { jcs($0) })
        case let array as [Any]: return .array(array.map { jcs($0) })
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return .bool(number.boolValue)
        case let number as NSNumber: return .int(number.intValue)
        case let string as String: return .rawString(string)
        default: return .null
        }
    }
}
