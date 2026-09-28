import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPAdmissionSidecarTests: XCTestCase {
    func testValidSidecarReturnsImmutableCapability() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capability = try NativeMTPAdmissionSidecar.load(
            sidecarData: fixture.sidecarData,
            signatureData: fixture.signatureData,
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring
        )

        XCTAssertEqual(capability.tupleSHA256, fixture.tupleSHA)
        XCTAssertEqual(capability.modelID, "mlx-community/Qwen3-MTP")
        XCTAssertEqual(capability.modelRevision, Self.modelRevision)
        XCTAssertEqual(capability.familyAdapter, "qwen3_mtp_v1")
        XCTAssertEqual(capability.maxProposalDepth, 4)
        XCTAssertEqual(capability.targetArtifactSHA256, fixture.digests["target.safetensors"])
        XCTAssertEqual(capability.mtpArtifactSHA256, fixture.digests["mtp.safetensors"])
        XCTAssertEqual(capability.tokenizerSHA256, fixture.digests["tokenizer.json"])
        XCTAssertEqual(capability.mtpManifestSHA256, fixture.digests["mtp-manifest.json"])
        XCTAssertEqual(capability.providerRevision, Self.providerRevision)
        XCTAssertEqual(capability.upstreamMLXSwiftLMRevision, Self.upstreamRevision)
        XCTAssertEqual(capability.qualifiedSlots, 8)
        XCTAssertEqual(capability.spec023ReleaseID, "native-mtp-release-2026-09-28")
        XCTAssertEqual(capability.evidenceArtifactSHA256, [Self.evidenceSHA])
    }

    func testDirectoryArtifactBindsCompleteSnapshotTree() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let targetDirectory = fixture.snapshot.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.snapshot.appendingPathComponent("target.safetensors"),
            to: targetDirectory.appendingPathComponent("model.safetensors")
        )
        try Data("config".utf8).write(to: targetDirectory.appendingPathComponent("config.json"))
        let digest = try MLXSnapshotIdentity.compute(directory: targetDirectory).digest
        let sidecar = try fixture.mutatingRoot({ root in
            var artifacts = root["artifacts"] as! [String: Any]
            artifacts["target"] = ["path": "target", "sha256": digest]
            root["artifacts"] = artifacts
        }, recomputeTuple: true)

        let capability = try NativeMTPAdmissionSidecar.load(
            sidecarData: sidecar,
            signatureData: fixture.signature(for: sidecar),
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring
        )
        XCTAssertEqual(capability.targetArtifactSHA256, digest)

        try Data("mutated".utf8).write(to: targetDirectory.appendingPathComponent("config.json"))
        XCTAssertEqual(
            try rejectedError(sidecar, fixture: fixture),
            .artifactDigestMismatch("target")
        )
    }

    func testDuplicateKeysRejectBeforeAdmission() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let duplicate = Data("""
        {"schema_version":"\(NativeMTPAdmissionSidecar.schemaVersion)","schema_version":"\(NativeMTPAdmissionSidecar.schemaVersion)"}
        """.utf8)

        XCTAssertThrowsError(try NativeMTPAdmissionSidecar.load(
            sidecarData: duplicate,
            signatureData: fixture.signature(for: duplicate),
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring
        )) { error in
            guard case .invalidJSON(let reason) = error as? NativeMTPAdmissionSidecarError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(reason.contains("duplicateKey"))
        }
    }

    func testUnknownAndMissingFieldsReject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { $0["surprise"] = true }, fixture: fixture),
            .unknownField("$.surprise")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { $0.removeValue(forKey: "flags") }, fixture: fixture),
            .missingField("$.flags")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { root in
                var model = root["model"] as! [String: Any]
                model["extra"] = "x"
                root["model"] = model
            }, fixture: fixture),
            .unknownField("$.model.extra")
        )
    }

    func testMalformedSHAAndUnsupportedTupleFieldsReject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { $0["tuple_sha256"] = String(repeating: "A", count: 64) }, fixture: fixture),
            .invalidValue("$.tuple_sha256")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { root in
                var cache = root["cache_state"] as! [String: Any]
                cache["cache_class"] = "classic_kv"
                root["cache_state"] = cache
            }, fixture: fixture),
            .unsupported("$.cache_state.cache_class")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var request = root["request_profile"] as! [String: Any]
                request["tools"] = true
                root["request_profile"] = request
            }, recomputeTuple: true), fixture: fixture),
            .unsupported("$.request_profile")
        )
    }

    func testFourBitAffineMLXTupleIsRepresentedWithoutClaimingMXFP8() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sidecar = try fixture.mutatingRoot({ root in
            root["quantization"] = [
                "target": "mlx_affine_4bit",
                "mtp": "mlx_affine_4bit",
            ]
        }, recomputeTuple: true)

        let capability = try NativeMTPAdmissionSidecar.load(
            sidecarData: sidecar,
            signatureData: fixture.signature(for: sidecar),
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring
        )

        XCTAssertEqual(capability.quantization.target, "mlx_affine_4bit")
        XCTAssertEqual(capability.quantization.mtp, "mlx_affine_4bit")
    }

    func testLiveTupleDriftAndAdmissionFlagsReject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let drifted = NativeMTPAdmissionSidecar.RuntimeContext(
            modelID: fixture.context.modelID,
            modelRevision: fixture.context.modelRevision,
            providerRevision: String(repeating: "e", count: 40),
            upstreamMLXSwiftLMRevision: fixture.context.upstreamMLXSwiftLMRevision,
            hardwareChip: fixture.context.hardwareChip,
            ramGB: fixture.context.ramGB,
            osVersion: fixture.context.osVersion,
            slotCount: fixture.context.slotCount,
            revokedTupleSHA256: []
        )

        XCTAssertEqual(
            try rejectedError(fixture.sidecarData, fixture: fixture, context: drifted),
            .liveTupleMismatch("$.revisions.provider")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { $0["admission_enabled"] = false }, fixture: fixture),
            .unsupported("admission flags")
        )
    }

    func testDetachedSignatureAndExactSignerAreRequiredBeforeParsing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var tampered = fixture.sidecarData
        tampered[tampered.count - 2] = UInt8(ascii: " ")
        let otherSigner = Curve25519.Signing.PrivateKey()
        let wrongKeyring = NativeMTPAdmissionSidecar.TrustedKeyring(
            publicKeysByKeyID: ["native-mtp-release": otherSigner.publicKey.rawRepresentation.base64EncodedString()],
            requiredKeyID: "native-mtp-release"
        )
        let wrongKeyID = NativeMTPAdmissionSidecar.TrustedKeyring(
            publicKeysByKeyID: fixture.trustedKeyring.publicKeysByKeyID,
            requiredKeyID: "other-release"
        )

        XCTAssertEqual(
            try rejectedError(tampered, signatureData: fixture.signatureData, fixture: fixture),
            .signatureInvalid("verification_failed")
        )
        XCTAssertEqual(
            try rejectedError(fixture.sidecarData, signatureData: fixture.signatureData, fixture: fixture, trustedKeyring: wrongKeyring),
            .signatureInvalid("verification_failed")
        )
        XCTAssertEqual(
            try rejectedError(fixture.sidecarData, signatureData: fixture.signatureData, fixture: fixture, trustedKeyring: wrongKeyID),
            .signatureInvalid("unexpected_key_id")
        )
    }

    func testTupleAndManifestDigestsAreRecomputed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { $0["tuple_sha256"] = String(repeating: "4", count: 64) }, fixture: fixture),
            .invalidValue("$.spec023.native_mtp_admission_tuple_sha256")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { root in
                var spec023 = root["spec023"] as! [String: Any]
                spec023["native_mtp_admission_tuple_sha256"] = String(repeating: "4", count: 64)
                root["spec023"] = spec023
            }, fixture: fixture),
            .invalidValue("$.spec023.native_mtp_admission_tuple_sha256")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["manifest_sha256"] = String(repeating: "4", count: 64)
                root["mtp"] = mtp
            }, recomputeTuple: true), fixture: fixture),
            .invalidValue("$.mtp.manifest_sha256")
        )
    }

    func testRevocationUnavailableOrRevokedRejects() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unavailable = NativeMTPAdmissionSidecar.RuntimeContext(
            modelID: fixture.context.modelID,
            modelRevision: fixture.context.modelRevision,
            providerRevision: fixture.context.providerRevision,
            upstreamMLXSwiftLMRevision: fixture.context.upstreamMLXSwiftLMRevision,
            hardwareChip: fixture.context.hardwareChip,
            ramGB: fixture.context.ramGB,
            osVersion: fixture.context.osVersion,
            slotCount: fixture.context.slotCount,
            revokedTupleSHA256: nil
        )
        let revoked = NativeMTPAdmissionSidecar.RuntimeContext(
            modelID: fixture.context.modelID,
            modelRevision: fixture.context.modelRevision,
            providerRevision: fixture.context.providerRevision,
            upstreamMLXSwiftLMRevision: fixture.context.upstreamMLXSwiftLMRevision,
            hardwareChip: fixture.context.hardwareChip,
            ramGB: fixture.context.ramGB,
            osVersion: fixture.context.osVersion,
            slotCount: fixture.context.slotCount,
            revokedTupleSHA256: [fixture.tupleSHA]
        )

        XCTAssertEqual(try rejectedError(fixture.sidecarData, fixture: fixture, context: unavailable), .revocationUnavailable)
        XCTAssertEqual(try rejectedError(fixture.sidecarData, fixture: fixture, context: revoked), .tupleRevoked(fixture.tupleSHA))
    }

    func testArtifactDigestMismatchRejects() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("drift".utf8).write(to: fixture.snapshot.appendingPathComponent("target.safetensors"))

        XCTAssertEqual(
            try rejectedError(fixture.sidecarData, fixture: fixture),
            .artifactDigestMismatch("target")
        )
    }

    func testArtifactPathsRejectAbsoluteTraversalNetworkBackslashAndMissing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for badPath in ["/tmp/target.safetensors", "../target.safetensors", "https://example.com/w", "nested\\file"] {
            XCTAssertEqual(
                try rejectedError(fixture.replacingArtifactPath("target", with: badPath), fixture: fixture),
                .pathRejected(badPath),
                badPath
            )
        }
        XCTAssertEqual(
            try rejectedError(fixture.replacingArtifactPath("target", with: "missing.safetensors"), fixture: fixture),
            .artifactNotFound("missing.safetensors")
        )
    }

    func testArtifactSymlinkRejectsEvenInsideSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.snapshot.appendingPathComponent("target.safetensors"))
        try FileManager.default.createSymbolicLink(
            at: fixture.snapshot.appendingPathComponent("target.safetensors"),
            withDestinationURL: fixture.snapshot.appendingPathComponent("mtp.safetensors")
        )

        XCTAssertEqual(
            try rejectedError(fixture.sidecarData, fixture: fixture),
            .artifactNotRegularFile("target.safetensors")
        )
    }

    func testUnmanifestedSnapshotArtifactsReject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("unmanifested".utf8).write(to: fixture.snapshot.appendingPathComponent("extra.safetensors"))

        XCTAssertEqual(
            try rejectedError(fixture.sidecarData, fixture: fixture),
            .artifactNotManifested("extra.safetensors")
        )
    }

    func testSymlinkDirectoryComponentRejects() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.snapshot.appendingPathComponent("target.safetensors"))
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("target weights".utf8).write(to: outside.appendingPathComponent("target.safetensors"))
        try FileManager.default.createSymbolicLink(
            at: fixture.snapshot.appendingPathComponent("linked"),
            withDestinationURL: outside
        )

        XCTAssertEqual(
            try rejectedError(fixture.replacingArtifactPath("target", with: "linked/target.safetensors"), fixture: fixture),
            .pathRejected("linked/target.safetensors")
        )
    }

    func testHardlinkedArtifactRejects() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let linked = fixture.snapshot.appendingPathComponent("target-hardlink.safetensors")
        try FileManager.default.linkItem(
            at: fixture.snapshot.appendingPathComponent("target.safetensors"),
            to: linked
        )

        XCTAssertEqual(
            try rejectedError(fixture.replacingArtifactPath("target", with: "target-hardlink.safetensors"), fixture: fixture),
            .artifactNotRegularFile("target-hardlink.safetensors")
        )
    }

    private func rejectedError(
        _ data: Data,
        signatureData: Data? = nil,
        fixture: Fixture,
        context: NativeMTPAdmissionSidecar.RuntimeContext? = nil,
        trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring? = nil
    ) throws -> NativeMTPAdmissionSidecarError {
        do {
            _ = try NativeMTPAdmissionSidecar.load(
                sidecarData: data,
                signatureData: signatureData ?? fixture.signature(for: data),
                snapshotRoot: fixture.snapshot,
                context: context ?? fixture.context,
                trustedKeyring: trustedKeyring ?? fixture.trustedKeyring
            )
            XCTFail("sidecar should reject")
            return .invalidValue("test did not reject")
        } catch let error as NativeMTPAdmissionSidecarError {
            return error
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-sidecar-\(UUID().uuidString)", isDirectory: true)
        let snapshot = root.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let files: [String: Data] = [
            "target.safetensors": Data("target weights".utf8),
            "mtp.safetensors": Data("mtp weights".utf8),
            "tokenizer.json": Data(#"{"kind":"tokenizer"}"#.utf8),
            "mtp-manifest.json": Data(#"{"layout":"mtp"}"#.utf8),
        ]
        var digests: [String: String] = [:]
        for (name, data) in files {
            try data.write(to: snapshot.appendingPathComponent(name))
            digests[name] = Self.sha256Hex(data)
        }
        let placeholderSHA = String(repeating: "1", count: 64)
        let placeholderObject = try Self.sidecarObject(digests: digests, tupleSHA: placeholderSHA)
        let tupleSHA = try NativeMTPAdmissionSidecar.admissionTupleSHA256ForTesting(placeholderObject)
        let rootObject = try Self.sidecarObject(digests: digests, tupleSHA: tupleSHA)
        let sidecarData = try Self.jsonData(rootObject)
        let signer = Curve25519.Signing.PrivateKey()
        let keyID = "native-mtp-release"
        return Fixture(
            root: root,
            snapshot: snapshot,
            rootObject: rootObject,
            sidecarData: sidecarData,
            signatureData: Self.signatureData(payload: sidecarData, signer: signer, keyID: keyID),
            digests: digests,
            tupleSHA: tupleSHA,
            signer: signer,
            trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring(
                publicKeysByKeyID: [keyID: signer.publicKey.rawRepresentation.base64EncodedString()],
                requiredKeyID: keyID
            ),
            context: NativeMTPAdmissionSidecar.RuntimeContext(
                modelID: "mlx-community/Qwen3-MTP",
                modelRevision: Self.modelRevision,
                providerRevision: Self.providerRevision,
                upstreamMLXSwiftLMRevision: Self.upstreamRevision,
                hardwareChip: "M2 Ultra",
                ramGB: 256,
                osVersion: "macOS 15.6",
                slotCount: 8,
                revokedTupleSHA256: []
            )
        )
    }

    private struct Fixture {
        let root: URL
        let snapshot: URL
        let rootObject: [String: Any]
        let sidecarData: Data
        let signatureData: Data
        let digests: [String: String]
        let tupleSHA: String
        let signer: Curve25519.Signing.PrivateKey
        let trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring
        let context: NativeMTPAdmissionSidecar.RuntimeContext

        func mutatingRoot(_ edit: (inout [String: Any]) -> Void, recomputeTuple: Bool = false) throws -> Data {
            var copy = rootObject
            edit(&copy)
            if recomputeTuple {
                let tupleSHA = try NativeMTPAdmissionSidecar.admissionTupleSHA256ForTesting(copy)
                copy["tuple_sha256"] = tupleSHA
                var spec023 = copy["spec023"] as! [String: Any]
                spec023["native_mtp_admission_tuple_sha256"] = tupleSHA
                copy["spec023"] = spec023
            }
            return try NativeMTPAdmissionSidecarTests.jsonData(copy)
        }

        func replacingArtifactPath(_ name: String, with path: String) throws -> Data {
            try mutatingRoot { root in
                var artifacts = root["artifacts"] as! [String: Any]
                var artifact = artifacts[name] as! [String: Any]
                artifact["path"] = path
                artifacts[name] = artifact
                root["artifacts"] = artifacts
            }
        }

        func signature(for payload: Data) -> Data {
            NativeMTPAdmissionSidecarTests.signatureData(
                payload: payload,
                signer: signer,
                keyID: trustedKeyring.requiredKeyID
            )
        }
    }

    private static let modelRevision = String(repeating: "a", count: 40)
    private static let providerRevision = String(repeating: "b", count: 40)
    private static let upstreamRevision = String(repeating: "c", count: 40)
    private static let evidenceSHA = String(repeating: "d", count: 64)

    private static func sidecarObject(digests: [String: String], tupleSHA: String) throws -> [String: Any] {
        [
            "schema_version": NativeMTPAdmissionSidecar.schemaVersion,
            "tuple_sha256": tupleSHA,
            "decode_path": "native_mtp",
            "admission_enabled": true,
            "model": [
                "id": "mlx-community/Qwen3-MTP",
                "revision": modelRevision,
                "family_adapter": "qwen3_mtp_v1",
            ],
            "artifacts": [
                "target": ["path": "target.safetensors", "sha256": digests["target.safetensors"]!],
                "mtp": ["path": "mtp.safetensors", "sha256": digests["mtp.safetensors"]!],
                "tokenizer": ["path": "tokenizer.json", "sha256": digests["tokenizer.json"]!],
                "manifest": ["path": "mtp-manifest.json", "sha256": digests["mtp-manifest.json"]!],
            ],
            "mtp": [
                "manifest_sha256": digests["mtp-manifest.json"]!,
                "source_layout": "separate_artifact",
                "prediction_layer_count": 4,
                "max_proposal_depth": 4,
                "adaptation_enabled": true,
                "adaptation_max_depth": 4,
            ],
            "quantization": [
                "target": "mlx_mxfp8",
                "mtp": "mlx_mxfp8",
            ],
            "cache_state": [
                "cache_class": "paged_kv",
                "state_class": "stageable_rewindable",
            ],
            "revisions": [
                "provider": providerRevision,
                "upstream_mlx_swift_lm": upstreamRevision,
            ],
            "hardware": [
                "chip": "M2 Ultra",
                "ram_gb": 256,
                "os_version": "macOS 15.6",
                "qualified_slots": 8,
                "max_slots": 8,
            ],
            "request_profile": [
                "text_only": true,
                "streaming": false,
                "tools": false,
                "structured_outputs": false,
                "logprobs": false,
                "penalties": false,
                "conversation_cache": false,
                "disk_cache": false,
                "max_prompt_tokens": 32768,
                "max_completion_tokens": 4096,
            ],
            "spec023": [
                "release_id": "native-mtp-release-2026-09-28",
                "source_commit": providerRevision,
                "reproducible_build_sha256": String(repeating: "2", count: 64),
                "benchmark_policy_sha256": String(repeating: "3", count: 64),
                "native_mtp_admission_tuple_sha256": tupleSHA,
                "evidence_artifact_sha256": [evidenceSHA],
            ],
            "flags": [
                "admission_allowed": true,
            ],
        ]
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signatureData(
        payload: Data,
        signer: Curve25519.Signing.PrivateKey,
        keyID: String
    ) -> Data {
        let signature = try! signer.signature(for: payload).base64EncodedString()
        return Data("""
        {"alg":"ed25519","key_id":"\(keyID)","signature":"\(signature)"}

        """.utf8)
    }
}
