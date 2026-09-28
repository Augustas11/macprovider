import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPAdmissionSidecarTests: XCTestCase {
    func testValidSidecarReturnsImmutableCapability() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capability = try NativeMTPAdmissionSidecar.load(
            sidecarData: fixture.releaseSidecarData,
            signatureData: fixture.signature(for: fixture.releaseSidecarData),
            snapshotRoot: fixture.snapshot,
            context: fixture.releaseContext,
            trustedKeyring: fixture.trustedKeyring,
            resolvedArtifactAuthority: fixture.releaseAuthority
        )

        XCTAssertEqual(capability.modelID, "mlx-community/Qwen3-MTP")
        XCTAssertEqual(capability.modelRevision, fixture.digests["target.safetensors"])
        XCTAssertEqual(capability.familyAdapter, "qwen3_mtp_v1")
        XCTAssertEqual(capability.maxProposalDepth, 4)
        XCTAssertEqual(capability.targetArtifactSHA256, fixture.digests["target.safetensors"])
        XCTAssertEqual(capability.mtpArtifactSHA256, fixture.digests["mtp.safetensors"])
        XCTAssertEqual(capability.tokenizerSHA256, fixture.digests["tokenizer.json"])
        XCTAssertEqual(capability.mtpManifestSHA256, fixture.digests["mtp-manifest.json"])
        XCTAssertEqual(capability.providerRevision, Self.providerRevision)
        XCTAssertEqual(capability.upstreamMLXSwiftLMRevision, Self.upstreamRevision)
        XCTAssertEqual(capability.qualifiedSlots, 8)
        XCTAssertEqual(capability.sourceLayout, "separate_artifact")
        XCTAssertEqual(capability.predictionLayerCount, 4)
        XCTAssertEqual(capability.completeWindowBytesByDepth, [1024, 2048, 4096, 8192, 16384])
        XCTAssertEqual(capability.throughputDeltaPPM, 42_000)
        XCTAssertEqual(capability.maxPromptTokens, 1_048_576)
        XCTAssertEqual(capability.maxCompletionTokens, 1_048_576)
        XCTAssertEqual(capability.spec023ReleaseID, "native-mtp-release-2026-09-28")
        XCTAssertEqual(capability.spec023LiveExecutableCDHash, Self.liveExecutableCDHash)
        XCTAssertEqual(
            capability.evidenceArtifactSHA256,
            Array(repeating: Self.evidenceSHA, count: 7)
        )
        XCTAssertNil(capability.capturedArtifacts)
    }

    func testURLLoaderCapsSidecarAndSignatureBeforeWholeRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sidecarURL = fixture.root.appendingPathComponent("native-mtp-admission.json")
        let signatureURL = fixture.root.appendingPathComponent("native-mtp-admission.json.sig")
        try fixture.sidecarData.write(to: sidecarURL)
        try fixture.signatureData.write(to: signatureURL)

        try Data(repeating: UInt8(ascii: "{"), count: NativeMTPAdmissionSidecar.maxSidecarBytes + 1)
            .write(to: sidecarURL)
        XCTAssertEqual(
            try rejectedURLError(sidecarURL: sidecarURL, signatureURL: signatureURL, fixture: fixture),
            .artifactTooLarge("native-mtp-admission.json")
        )

        try fixture.sidecarData.write(to: sidecarURL)
        try Data(repeating: UInt8(ascii: "s"), count: NativeMTPAdmissionSidecar.maxSignatureBytes + 1)
            .write(to: signatureURL)
        XCTAssertEqual(
            try rejectedURLError(sidecarURL: sidecarURL, signatureURL: signatureURL, fixture: fixture),
            .artifactTooLarge("native-mtp-admission.json.sig")
        )
    }

    func testDataLoaderCapsAlreadyMaterializedSidecarAndSignature() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(
                Data(repeating: UInt8(ascii: "{"), count: NativeMTPAdmissionSidecar.maxSidecarBytes + 1),
                signatureData: fixture.signatureData,
                fixture: fixture
            ),
            .artifactTooLarge("native-mtp-admission.json")
        )
        XCTAssertEqual(
            try rejectedError(
                fixture.sidecarData,
                signatureData: Data(repeating: UInt8(ascii: "s"), count: NativeMTPAdmissionSidecar.maxSignatureBytes + 1),
                fixture: fixture
            ),
            .artifactTooLarge("native-mtp-admission.json.sig")
        )
    }

    func testAdmissionTupleBindsMTPLayoutAndPredictionLayerCount() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["source_layout"] = "checkpoint_mtp"
                root["mtp"] = mtp
            }, fixture: fixture),
            .invalidValue("$.tuple_sha256")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["prediction_layer_count"] = 8
                root["mtp"] = mtp
            }, fixture: fixture),
            .invalidValue("$.tuple_sha256")
        )
    }

    func testCaptureArtifactsReturnsPrivateStagedBytesAndSurvivesSourceMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sidecarURL = fixture.root.appendingPathComponent("native-mtp-admission.json")
        let signatureURL = fixture.root.appendingPathComponent("native-mtp-admission.json.sig")
        try fixture.sidecarData.write(to: sidecarURL)
        try fixture.signatureData.write(to: signatureURL)

        let capability = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
            sidecarURL: sidecarURL,
            signatureURL: signatureURL,
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring,
            captureArtifacts: true
        )
        let captured = try XCTUnwrap(capability.capturedArtifacts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured.rootURL.path))
        XCTAssertEqual(try Data(contentsOf: captured.mtpURL), Data("mtp weights".utf8))
        XCTAssertEqual(try permissions(captured.rootURL) & 0o777, 0o500)
        XCTAssertEqual(try permissions(captured.mtpURL) & 0o777, 0o400)
        XCTAssertNoThrow(try captured.revalidateAfterLoad())

        try Data("mutated source".utf8).write(to: fixture.snapshot.appendingPathComponent("mtp.safetensors"))
        XCTAssertEqual(try Data(contentsOf: captured.mtpURL), Data("mtp weights".utf8))
        XCTAssertNoThrow(try captured.revalidateAfterLoad())
    }

    func testDirectoryCaptureHashesStagedTree() throws {
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
        let sidecarURL = fixture.root.appendingPathComponent("native-mtp-admission.json")
        let signatureURL = fixture.root.appendingPathComponent("native-mtp-admission.json.sig")
        try sidecar.write(to: sidecarURL)
        try fixture.signature(for: sidecar).write(to: signatureURL)

        let capability = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
            sidecarURL: sidecarURL,
            signatureURL: signatureURL,
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring,
            captureArtifacts: true
        )
        let captured = try XCTUnwrap(capability.capturedArtifacts)
        XCTAssertEqual(try MLXSnapshotIdentity.compute(directory: captured.targetURL).digest, digest)
    }

    func testCaptureArtifactsReusesNestedTokenizerAndManifestAlreadyCopiedByParentDirectories() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let targetDirectory = fixture.snapshot.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = fixture.snapshot.appendingPathComponent("mtp", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mtpDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.snapshot.appendingPathComponent("target.safetensors"),
            to: targetDirectory.appendingPathComponent("model.safetensors")
        )
        try FileManager.default.moveItem(
            at: fixture.snapshot.appendingPathComponent("tokenizer.json"),
            to: targetDirectory.appendingPathComponent("tokenizer.json")
        )
        try FileManager.default.moveItem(
            at: fixture.snapshot.appendingPathComponent("mtp.safetensors"),
            to: mtpDirectory.appendingPathComponent("model.safetensors")
        )
        try FileManager.default.moveItem(
            at: fixture.snapshot.appendingPathComponent("mtp-manifest.json"),
            to: mtpDirectory.appendingPathComponent("config.json")
        )
        let targetDigest = try MLXSnapshotIdentity.compute(directory: targetDirectory).digest
        let mtpDigest = try MLXSnapshotIdentity.compute(directory: mtpDirectory).digest
        let tokenizerDigest = fixture.digests["tokenizer.json"]!
        let manifestDigest = fixture.digests["mtp-manifest.json"]!
        let sidecar = try fixture.mutatingRoot({ root in
            var artifacts = root["artifacts"] as! [String: Any]
            artifacts["target"] = ["path": "target", "sha256": targetDigest]
            artifacts["mtp"] = ["path": "mtp", "sha256": mtpDigest]
            artifacts["tokenizer"] = ["path": "target/tokenizer.json", "sha256": tokenizerDigest]
            artifacts["manifest"] = ["path": "mtp/config.json", "sha256": manifestDigest]
            root["artifacts"] = artifacts
            var mtp = root["mtp"] as! [String: Any]
            mtp["manifest_sha256"] = manifestDigest
            root["mtp"] = mtp
        }, recomputeTuple: true)
        let sidecarURL = fixture.root.appendingPathComponent("native-mtp-admission.json")
        let signatureURL = fixture.root.appendingPathComponent("native-mtp-admission.json.sig")
        try sidecar.write(to: sidecarURL)
        try fixture.signature(for: sidecar).write(to: signatureURL)

        let capability = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
            sidecarURL: sidecarURL,
            signatureURL: signatureURL,
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring,
            captureArtifacts: true
        )
        let captured = try XCTUnwrap(capability.capturedArtifacts)
        XCTAssertTrue(captured.tokenizerURL.path.hasPrefix(captured.targetURL.path + "/"))
        XCTAssertTrue(captured.manifestURL.path.hasPrefix(captured.mtpURL.path + "/"))
        XCTAssertEqual(try Data(contentsOf: captured.tokenizerURL), Data(#"{"kind":"tokenizer"}"#.utf8))
        XCTAssertEqual(try Data(contentsOf: captured.manifestURL), Data(#"{"layout":"mtp"}"#.utf8))
        XCTAssertEqual(try MLXSnapshotIdentity.compute(directory: captured.targetURL).digest, targetDigest)
        XCTAssertEqual(try MLXSnapshotIdentity.compute(directory: captured.mtpURL).digest, mtpDigest)
    }

    func testCaptureRejectsPathSwapAfterValidation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { NativeMTPAdmissionSidecar.testingDescriptorCaptureMutationHook = nil }
        NativeMTPAdmissionSidecar.testingDescriptorCaptureMutationHook = { _ in
            try FileManager.default.removeItem(at: fixture.snapshot.appendingPathComponent("target.safetensors"))
            try FileManager.default.createSymbolicLink(
                at: fixture.snapshot.appendingPathComponent("target.safetensors"),
                withDestinationURL: fixture.snapshot.appendingPathComponent("mtp.safetensors")
            )
        }

        XCTAssertEqual(
            try rejectedCaptureError(fixture.sidecarData, fixture: fixture),
            .artifactNotRegularFile("target.safetensors")
        )
    }

    func testCaptureRejectsRenameReplacementAfterValidation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { NativeMTPAdmissionSidecar.testingDescriptorCaptureMutationHook = nil }
        NativeMTPAdmissionSidecar.testingDescriptorCaptureMutationHook = { _ in
            let target = fixture.snapshot.appendingPathComponent("target.safetensors")
            try FileManager.default.moveItem(
                at: target,
                to: fixture.snapshot.appendingPathComponent("target.old")
            )
            try Data("target weights".utf8).write(to: target)
        }

        XCTAssertEqual(
            try rejectedCaptureError(fixture.sidecarData, fixture: fixture),
            .artifactNotRegularFile("target.safetensors")
        )
    }

    func testCaptureRejectsTruncationAfterValidation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { NativeMTPAdmissionSidecar.testingDescriptorCaptureMutationHook = nil }
        NativeMTPAdmissionSidecar.testingDescriptorCaptureMutationHook = { _ in
            try Data().write(to: fixture.snapshot.appendingPathComponent("target.safetensors"))
        }

        XCTAssertEqual(
            try rejectedCaptureError(fixture.sidecarData, fixture: fixture),
            .artifactNotRegularFile("target.safetensors")
        )
    }

    func testCaptureRejectsSameSizeRewriteWithRestoredMTimeAfterValidation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.snapshot.appendingPathComponent("target.safetensors")
        var before = stat()
        XCTAssertEqual(lstat(target.path, &before), 0)
        defer { NativeMTPAdmissionSidecar.testingDescriptorCaptureMutationHook = nil }
        NativeMTPAdmissionSidecar.testingDescriptorCaptureMutationHook = { _ in
            try Data("TARGET weights".utf8).write(to: target)
            var times = [
                timeval(tv_sec: before.st_atimespec.tv_sec, tv_usec: Int32(before.st_atimespec.tv_nsec / 1000)),
                timeval(tv_sec: before.st_mtimespec.tv_sec, tv_usec: Int32(before.st_mtimespec.tv_nsec / 1000)),
            ]
            XCTAssertEqual(times.withUnsafeMutableBufferPointer { utimes(target.path, $0.baseAddress) }, 0)
        }

        XCTAssertEqual(
            try rejectedCaptureError(fixture.sidecarData, fixture: fixture),
            .artifactNotRegularFile("target.safetensors")
        )
    }

    func testCaptureRejectsGroupWritableSourceMode() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.snapshot.appendingPathComponent("target.safetensors")
        XCTAssertEqual(chmod(target.path, 0o664), 0)

        XCTAssertEqual(
            try rejectedCaptureError(fixture.sidecarData, fixture: fixture),
            .pathRejected("target.safetensors")
        )
    }

    func testCaptureRejectsStagingDeviceMismatch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var st = stat()
        XCTAssertEqual(lstat(fixture.snapshot.path, &st), 0)
        defer { NativeMTPAdmissionSidecar.testingExpectedStagingDeviceOverride = nil }
        NativeMTPAdmissionSidecar.testingExpectedStagingDeviceOverride = st.st_dev == 0 ? 1 : 0

        XCTAssertEqual(
            try rejectedCaptureError(fixture.sidecarData, fixture: fixture),
            .pathRejected("captured_artifacts")
        )
    }

    func testRevalidateAfterLoadRejectsStagedMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let captured = try loadCapturedArtifacts(fixture)
        XCTAssertNoThrow(try captured.revalidateAfterLoad())

        XCTAssertEqual(chmod(captured.mtpURL.path, 0o600), 0)
        try Data("mutated staged".utf8).write(to: captured.mtpURL)
        XCTAssertThrowsError(try captured.revalidateAfterLoad())
    }

    func testCapturedLeaseDeinitRemovesFrozenPrivateTree() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var captured: NativeMTPAdmissionCapturedArtifacts? = try loadCapturedArtifacts(fixture)
        let stagedRoot = try XCTUnwrap(captured?.rootURL)
        let stagedFile = try XCTUnwrap(captured?.targetURL)
        XCTAssertEqual(try permissions(stagedRoot) & 0o777, 0o500)
        XCTAssertEqual(try permissions(stagedFile) & 0o777, 0o400)

        captured = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedRoot.path))
    }

    func testCaptureReclaimsUnlockedStalePrivateSiblingsAndPreservesLockedLiveSiblings() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staleRoot = fixture.root
            .appendingPathComponent(
                "\(NativeMTPAdmissionCapturedArtifacts.captureDirectoryPrefix)stale",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: staleRoot.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        let staleFile = staleRoot.appendingPathComponent("nested/file.bin")
        try Data("stale capture".utf8).write(to: staleFile)
        let staleLease = staleRoot.appendingPathComponent(NativeMTPAdmissionCapturedArtifacts.leaseFileName)
        try Data("stale lease".utf8).write(to: staleLease)
        XCTAssertEqual(chmod(staleLease.path, 0o400), 0)
        XCTAssertEqual(chmod(staleFile.path, 0o400), 0)
        XCTAssertEqual(chmod(staleRoot.appendingPathComponent("nested", isDirectory: true).path, 0o500), 0)
        XCTAssertEqual(chmod(staleRoot.path, 0o500), 0)

        let liveRoot = fixture.root
            .appendingPathComponent(
                "\(NativeMTPAdmissionCapturedArtifacts.captureDirectoryPrefix)live",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: false)
        let liveLeaseFD = try NativeMTPAdmissionCapturedArtifacts.openLockedLease(
            for: liveRoot,
            create: true,
            nonblocking: false
        )
        defer { close(liveLeaseFD) }
        let liveFile = liveRoot.appendingPathComponent("live.bin")
        try Data("live capture".utf8).write(to: liveFile)
        XCTAssertEqual(chmod(liveRoot.appendingPathComponent(NativeMTPAdmissionCapturedArtifacts.leaseFileName).path, 0o400), 0)
        XCTAssertEqual(chmod(liveFile.path, 0o400), 0)
        XCTAssertEqual(chmod(liveRoot.path, 0o500), 0)
        defer { try? NativeMTPAdmissionCapturedArtifacts.removePrivateCaptureTree(liveRoot) }

        let captured = try loadCapturedArtifacts(fixture)
        defer { _ = captured }

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured.rootURL.path))
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

        let capability = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
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

        XCTAssertThrowsError(try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
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

    func testProductionLoaderRejectsLegacyObjectSchema() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try NativeMTPAdmissionSidecar.load(
            sidecarData: fixture.sidecarData,
            signatureData: fixture.signatureData,
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring
        )) {
            XCTAssertEqual(
                $0 as? NativeMTPAdmissionSidecarError,
                .missingField("$.entries")
            )
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

        let capability = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
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
                spec023["live_executable_cdhash"] = String(repeating: "e", count: 40)
                root["spec023"] = spec023
            }, fixture: fixture),
            .invalidValue("$.tuple_sha256")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["complete_window_bytes_by_depth"] = [2048, 4096, 8192, 16384, 32768]
                root["mtp"] = mtp
            }, fixture: fixture),
            .invalidValue("$.tuple_sha256")
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

    func testCompleteWindowBytesByDepthIsRequiredMonotonicAndCapacityBounded() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var mtp = root["mtp"] as! [String: Any]
                mtp.removeValue(forKey: "complete_window_bytes_by_depth")
                root["mtp"] = mtp
            }, recomputeTuple: true), fixture: fixture),
            .missingField("$.mtp.complete_window_bytes_by_depth")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["complete_window_bytes_by_depth"] = [1024, 2048, 4096, 8192]
                root["mtp"] = mtp
            }, recomputeTuple: true), fixture: fixture),
            .invalidValue("$.mtp.complete_window_bytes_by_depth")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["complete_window_bytes_by_depth"] = [1024, 4096, 2048, 8192, 16384]
                root["mtp"] = mtp
            }, recomputeTuple: true), fixture: fixture),
            .invalidValue("$.mtp.complete_window_bytes_by_depth[2]")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["complete_window_bytes_by_depth"] = [1, 2, 3, 4, Int.max]
                root["mtp"] = mtp
            }, recomputeTuple: true), fixture: fixture),
            .invalidValue("$.mtp.complete_window_bytes_by_depth")
        )
    }

    func testThroughputDeltaPPMIsRequiredSignedSidecarData() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var mtp = root["mtp"] as! [String: Any]
                mtp.removeValue(forKey: "throughput_delta_ppm")
                root["mtp"] = mtp
            }, recomputeTuple: true), fixture: fixture),
            .missingField("$.mtp.throughput_delta_ppm")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["throughput_delta_ppm"] = 1_000_001
                root["mtp"] = mtp
            }, recomputeTuple: true), fixture: fixture),
            .invalidValue("$.mtp.throughput_delta_ppm")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { root in
                var mtp = root["mtp"] as! [String: Any]
                mtp["throughput_delta_ppm"] = -10
                root["mtp"] = mtp
            }, fixture: fixture),
            .invalidValue("$.tuple_sha256")
        )
    }

    func testSelfTestChallengeBankIsRequiredAndSignedIntoTuple() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                root.removeValue(forKey: "selftest")
            }, recomputeTuple: false), fixture: fixture),
            .missingField("$.selftest")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var selftest = root["selftest"] as! [String: Any]
                selftest["challenge_bank_sha256"] = String(repeating: "e", count: 63)
                root["selftest"] = selftest
            }, recomputeTuple: true), fixture: fixture),
            .invalidValue("$.selftest.challenge_bank_sha256")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot { root in
                var selftest = root["selftest"] as! [String: Any]
                selftest["signer_key_id"] = "different-signer"
                root["selftest"] = selftest
            }, fixture: fixture),
            .invalidValue("$.tuple_sha256")
        )
    }

    func testSpec023LiveExecutableCDHashIsRequiredLowercaseAndSignedIntoTuple() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var spec023 = root["spec023"] as! [String: Any]
                spec023.removeValue(forKey: "live_executable_cdhash")
                root["spec023"] = spec023
            }, recomputeTuple: true), fixture: fixture),
            .missingField("$.spec023.live_executable_cdhash")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var spec023 = root["spec023"] as! [String: Any]
                spec023["live_executable_cdhash"] = String(repeating: "E", count: 40)
                root["spec023"] = spec023
            }, recomputeTuple: true), fixture: fixture),
            .invalidValue("$.spec023.live_executable_cdhash")
        )
        XCTAssertEqual(
            try rejectedError(fixture.mutatingRoot({ root in
                var spec023 = root["spec023"] as! [String: Any]
                spec023["live_executable_cdhash"] = String(repeating: "e", count: 39)
                root["spec023"] = spec023
            }, recomputeTuple: true), fixture: fixture),
            .invalidValue("$.spec023.live_executable_cdhash")
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

    func testReleaseEnvelopeRequiresResolvedArtifactAuthority() throws {
        let fixture = try makeReleaseEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }

        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, includeAuthority: false),
            .missingField("$.artifact_authority")
        )
    }

    func testReleaseEnvelopeRejectsUnverifiedArtifactFeedMember() throws {
        let fixture = try makeReleaseEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }

        for status in ["declared", "blocked"] {
            XCTAssertEqual(
                try rejectedReleaseEnvelopeError(
                    fixture,
                    authority: fixture.authority(verificationStatus: status)
                ),
                .invalidValue("$.artifact_authority.verification_status"),
                status
            )
        }
    }

    func testReleaseEnvelopeRejectsAuthorityIdentityDrift() throws {
        let fixture = try makeReleaseEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }

        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, authority: fixture.authority(feedSHA256: "not-hex")),
            .invalidValue("$.artifact_authority.feed_sha256")
        )
        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, authority: fixture.authority(releaseID: "other-release")),
            .liveTupleMismatch("$.artifact_authority.release_id")
        )
        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, authority: fixture.authority(signerKeyID: "other-signer")),
            .signatureInvalid("artifact_authority_signer")
        )
        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, authority: fixture.authority(modelKey: "other/model")),
            .liveTupleMismatch("$.artifact_authority.model_key")
        )
        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, authority: fixture.authority(artifactID: "other-artifact")),
            .liveTupleMismatch("$.artifact_authority.artifact_id")
        )
        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, authority: fixture.authority(hashAlgorithm: "sha256")),
            .liveTupleMismatch("$.artifact_authority.hash_algorithm")
        )
        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, authority: fixture.authority(hash: String(repeating: "9", count: 64))),
            .liveTupleMismatch("$.artifact_authority.hash")
        )
    }

    func testReleaseEnvelopeRejectsNonCanonicalHardwareClass() throws {
        let fixture = try makeReleaseEnvelopeFixture(entryEdit: { entry in
            entry["hardware_class"] = "M2 Ultra"
        })
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }

        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture),
            .invalidValue("$.entries[0].hardware_class")
        )
    }

    func testReleaseEnvelopeRejectsCanonicalHardwareMismatch() throws {
        let fixture = try makeReleaseEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }
        let wrongHardware = NativeMTPAdmissionSidecar.RuntimeContext(
            modelID: fixture.context.modelID,
            modelRevision: fixture.context.modelRevision,
            providerRevision: fixture.context.providerRevision,
            upstreamMLXSwiftLMRevision: fixture.context.upstreamMLXSwiftLMRevision,
            hardwareChip: "M1 Max",
            ramGB: fixture.context.ramGB,
            osVersion: fixture.context.osVersion,
            slotCount: fixture.context.slotCount,
            revokedTupleSHA256: []
        )

        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, context: wrongHardware),
            .liveTupleMismatch("$.entries")
        )
    }

    func testReleaseEnvelopeRejectsLegacySHA256HashAlgorithm() throws {
        let fixture = try makeReleaseEnvelopeFixture(entryEdit: { entry in
            entry["hash_algorithm"] = "sha256"
        })
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }

        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture),
            .invalidValue("$.entries[0].hash_algorithm")
        )
    }

    func testReleaseEnvelopeRejectsTargetRootAndHashMismatch() throws {
        let fixture = try makeReleaseEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }

        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(
                fixture,
                authority: fixture.authority(targetURLPath: fixture.base.root.appendingPathComponent("other-target").path)
            ),
            .liveTupleMismatch("$.artifact_authority.target_url")
        )
        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture, authority: fixture.authority(targetSHA256: String(repeating: "8", count: 64))),
            .artifactDigestMismatch("$.artifact_authority.target_sha256")
        )
    }

    func testReleaseEnvelopeRejectsProjectionManifestReplacingTargetAuthority() throws {
        let fixture = try makeReleaseEnvelopeFixture(mutateProjectionArtifacts: { artifacts in
            artifacts["target"] = ["path": "invented-target.safetensors", "sha256": String(repeating: "7", count: 64)]
        })
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }

        XCTAssertEqual(
            try rejectedReleaseEnvelopeError(fixture),
            .liveTupleMismatch("$.artifact_authority.target_url")
        )
    }

    func testReleaseEnvelopeAcceptsVerifiedMemberWithContainedAuxiliaryLayout() throws {
        let fixture = try makeReleaseEnvelopeFixture(prepareSnapshot: { base in
            let targetDirectory = base.snapshot.appendingPathComponent("target", isDirectory: true)
            let mtpDirectory = base.snapshot.appendingPathComponent("mtp", isDirectory: true)
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: mtpDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: base.snapshot.appendingPathComponent("target.safetensors"),
                to: targetDirectory.appendingPathComponent("model.safetensors")
            )
            try FileManager.default.moveItem(
                at: base.snapshot.appendingPathComponent("tokenizer.json"),
                to: targetDirectory.appendingPathComponent("tokenizer.json")
            )
            try FileManager.default.moveItem(
                at: base.snapshot.appendingPathComponent("mtp.safetensors"),
                to: mtpDirectory.appendingPathComponent("model.safetensors")
            )
            try FileManager.default.moveItem(
                at: base.snapshot.appendingPathComponent("mtp-manifest.json"),
                to: mtpDirectory.appendingPathComponent("config.json")
            )
            let targetDigest = try MLXSnapshotIdentity.compute(directory: targetDirectory).digest
            let mtpDigest = try MLXSnapshotIdentity.compute(directory: mtpDirectory).digest
            return ReleaseLayout(
                targetPath: "target",
                targetSHA256: targetDigest,
                mtpPath: "mtp",
                mtpSHA256: mtpDigest,
                tokenizerPath: "target/tokenizer.json",
                tokenizerSHA256: base.digests["tokenizer.json"]!,
                manifestPath: "mtp/config.json",
                manifestSHA256: base.digests["mtp-manifest.json"]!
            )
        })
        defer { try? FileManager.default.removeItem(at: fixture.base.root) }

        let capability = try NativeMTPAdmissionSidecar.load(
            sidecarData: fixture.sidecarData,
            signatureData: fixture.signatureData,
            snapshotRoot: fixture.base.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.base.trustedKeyring,
            resolvedArtifactAuthority: fixture.authority,
            captureArtifacts: true
        )

        XCTAssertEqual(capability.modelID, fixture.authority.modelKey)
        XCTAssertEqual(capability.targetArtifactSHA256, fixture.authority.hash)
        let captured = try XCTUnwrap(capability.capturedArtifacts)
        XCTAssertTrue(captured.tokenizerURL.path.hasPrefix(captured.targetURL.path + "/"))
        XCTAssertTrue(captured.manifestURL.path.hasPrefix(captured.mtpURL.path + "/"))
        XCTAssertEqual(try MLXSnapshotIdentity.compute(directory: captured.targetURL).digest, fixture.authority.hash)
    }

    private func rejectedError(
        _ data: Data,
        signatureData: Data? = nil,
        fixture: Fixture,
        context: NativeMTPAdmissionSidecar.RuntimeContext? = nil,
        trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring? = nil
    ) throws -> NativeMTPAdmissionSidecarError {
        do {
            _ = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
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

    private func rejectedReleaseEnvelopeError(
        _ fixture: ReleaseEnvelopeFixture,
        authority: NativeMTPResolvedArtifactAuthority? = nil,
        includeAuthority: Bool = true,
        context: NativeMTPAdmissionSidecar.RuntimeContext? = nil
    ) throws -> NativeMTPAdmissionSidecarError {
        do {
            _ = try NativeMTPAdmissionSidecar.load(
                sidecarData: fixture.sidecarData,
                signatureData: fixture.signatureData,
                snapshotRoot: fixture.base.snapshot,
                context: context ?? fixture.context,
                trustedKeyring: fixture.base.trustedKeyring,
                resolvedArtifactAuthority: includeAuthority ? (authority ?? fixture.authority) : nil
            )
            XCTFail("release envelope should reject")
            return .invalidValue("test did not reject")
        } catch let error as NativeMTPAdmissionSidecarError {
            return error
        }
    }

    private func rejectedCaptureError(
        _ data: Data,
        fixture: Fixture
    ) throws -> NativeMTPAdmissionSidecarError {
        do {
            _ = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
                sidecarData: data,
                signatureData: fixture.signature(for: data),
                snapshotRoot: fixture.snapshot,
                context: fixture.context,
                trustedKeyring: fixture.trustedKeyring,
                captureArtifacts: true
            )
            XCTFail("sidecar should reject")
            return .invalidValue("test did not reject")
        } catch let error as NativeMTPAdmissionSidecarError {
            return error
        }
    }

    private func loadCapturedArtifacts(_ fixture: Fixture) throws -> NativeMTPAdmissionCapturedArtifacts {
        let capability = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
            sidecarData: fixture.sidecarData,
            signatureData: fixture.signatureData,
            snapshotRoot: fixture.snapshot,
            context: fixture.context,
            trustedKeyring: fixture.trustedKeyring,
            captureArtifacts: true
        )
        return try XCTUnwrap(capability.capturedArtifacts)
    }

    private func rejectedURLError(
        sidecarURL: URL,
        signatureURL: URL,
        fixture: Fixture
    ) throws -> NativeMTPAdmissionSidecarError {
        do {
            _ = try NativeMTPAdmissionSidecar.load(
                sidecarURL: sidecarURL,
                signatureURL: signatureURL,
                snapshotRoot: fixture.snapshot,
                context: fixture.context,
                trustedKeyring: fixture.trustedKeyring
            )
            XCTFail("sidecar should reject")
            return .invalidValue("test did not reject")
        } catch let error as NativeMTPAdmissionSidecarError {
            return error
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(url.lastPathComponent)
        }
        return Int(st.st_mode)
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
        let selfTestBankData = Data(#"{"schema":"native_mtp_selftest_bank.v1","release_id":"native-mtp-selftest-2026-09-28","prompts":[[1,2,3]]}"#.utf8)
        try selfTestBankData.write(to: snapshot.appendingPathComponent("native-mtp-selftest-bank.json"))
        let selfTestSigner = Curve25519.Signing.PrivateKey()
        let selfTestSignerKeyID = "native-mtp-selftest-release"
        let selfTestSignatureData = Self.signatureData(
            payload: selfTestBankData,
            signer: selfTestSigner,
            keyID: selfTestSignerKeyID
        )
        try selfTestSignatureData.write(to: snapshot.appendingPathComponent("native-mtp-selftest-bank.json.sig"))
        let placeholderSHA = String(repeating: "1", count: 64)
        let placeholderObject = try Self.sidecarObject(
            digests: digests,
            tupleSHA: placeholderSHA,
            selfTestBankSHA256: Self.sha256Hex(selfTestBankData),
            selfTestSignerKeyID: selfTestSignerKeyID,
            selfTestSignatureSHA256: Self.sha256Hex(selfTestSignatureData)
        )
        let tupleSHA = try NativeMTPAdmissionSidecar.admissionTupleSHA256ForTesting(placeholderObject)
        let rootObject = try Self.sidecarObject(
            digests: digests,
            tupleSHA: tupleSHA,
            selfTestBankSHA256: Self.sha256Hex(selfTestBankData),
            selfTestSignerKeyID: selfTestSignerKeyID,
            selfTestSignatureSHA256: Self.sha256Hex(selfTestSignatureData)
        )
        let sidecarData = try Self.jsonData(rootObject)
        let signer = Curve25519.Signing.PrivateKey()
        let keyID = "native-mtp-release"
        let releaseLayout = ReleaseLayout(
            targetPath: "target.safetensors",
            targetSHA256: digests["target.safetensors"]!,
            mtpPath: "mtp.safetensors",
            mtpSHA256: digests["mtp.safetensors"]!,
            tokenizerPath: "tokenizer.json",
            tokenizerSHA256: digests["tokenizer.json"]!,
            manifestPath: "mtp-manifest.json",
            manifestSHA256: digests["mtp-manifest.json"]!
        )
        let releaseProjectionData = try Self.projectionData(layout: releaseLayout)
        try releaseProjectionData.write(to: snapshot.appendingPathComponent("native-mtp-artifact-manifest.json"))
        let releaseSidecarData = try Self.releaseEnvelopeData(
            layout: releaseLayout,
            artifactManifestSHA256: Self.sha256Hex(releaseProjectionData),
            challengeBankSHA256: Self.sha256Hex(selfTestBankData),
            signerKeyID: keyID,
            challengeBankSignerKeyID: selfTestSignerKeyID
        )
        let releaseContext = NativeMTPAdmissionSidecar.RuntimeContext(
            modelID: "mlx-community/Qwen3-MTP",
            modelRevision: releaseLayout.targetSHA256,
            providerRevision: Self.providerRevision,
            upstreamMLXSwiftLMRevision: Self.upstreamRevision,
            hardwareChip: "M2 Ultra",
            ramGB: 256,
            osVersion: "macOS 15.6",
            slotCount: 8,
            revokedTupleSHA256: []
        )
        let releaseAuthority = NativeMTPResolvedArtifactAuthority.uncheckedForTesting(
            releaseID: Self.releaseID,
            signerKeyID: keyID,
            feedSHA256: String(repeating: "5", count: 64),
            modelKey: "mlx-community/Qwen3-MTP",
            artifactID: "primary",
            hashAlgorithm: NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm,
            hash: releaseLayout.targetSHA256,
            verificationStatus: "verified",
            targetURLPath: snapshot.appendingPathComponent(releaseLayout.targetPath).standardizedFileURL.path,
            targetSHA256: releaseLayout.targetSHA256
        )
        return Fixture(
            root: root,
            snapshot: snapshot,
            rootObject: rootObject,
            sidecarData: sidecarData,
            signatureData: Self.signatureData(payload: sidecarData, signer: signer, keyID: keyID),
            releaseSidecarData: releaseSidecarData,
            releaseContext: releaseContext,
            releaseAuthority: releaseAuthority,
            digests: digests,
            tupleSHA: tupleSHA,
            signer: signer,
            selfTestBankSHA256: Self.sha256Hex(selfTestBankData),
            selfTestSignerKeyID: selfTestSignerKeyID,
            trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring(
                publicKeysByKeyID: [
                    keyID: signer.publicKey.rawRepresentation.base64EncodedString(),
                    selfTestSignerKeyID: selfTestSigner.publicKey.rawRepresentation.base64EncodedString(),
                ],
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

    private func makeReleaseEnvelopeFixture(
        prepareSnapshot: ((Fixture) throws -> ReleaseLayout)? = nil,
        mutateProjectionArtifacts: ((inout [String: Any]) -> Void)? = nil,
        entryEdit: ((inout [String: Any]) -> Void)? = nil
    ) throws -> ReleaseEnvelopeFixture {
        let base = try makeFixture()
        let layout = try prepareSnapshot?(base) ?? ReleaseLayout(
            targetPath: "target.safetensors",
            targetSHA256: base.digests["target.safetensors"]!,
            mtpPath: "mtp.safetensors",
            mtpSHA256: base.digests["mtp.safetensors"]!,
            tokenizerPath: "tokenizer.json",
            tokenizerSHA256: base.digests["tokenizer.json"]!,
            manifestPath: "mtp-manifest.json",
            manifestSHA256: base.digests["mtp-manifest.json"]!
        )
        var projectionArtifacts: [String: Any] = [
            "target": ["path": layout.targetPath, "sha256": layout.targetSHA256],
            "mtp": ["path": layout.mtpPath, "sha256": layout.mtpSHA256],
            "tokenizer": ["path": layout.tokenizerPath, "sha256": layout.tokenizerSHA256],
            "manifest": ["path": layout.manifestPath, "sha256": layout.manifestSHA256],
        ]
        mutateProjectionArtifacts?(&projectionArtifacts)
        let projectionData = try Self.projectionData(artifacts: projectionArtifacts)
        try projectionData.write(to: base.snapshot.appendingPathComponent("native-mtp-artifact-manifest.json"))
        let keyID = base.trustedKeyring.requiredKeyID
        let sidecarData = try Self.releaseEnvelopeData(
            layout: layout,
            artifactManifestSHA256: Self.sha256Hex(projectionData),
            challengeBankSHA256: base.selfTestBankSHA256,
            signerKeyID: keyID,
            challengeBankSignerKeyID: base.selfTestSignerKeyID,
            entryEdit: entryEdit
        )
        let context = NativeMTPAdmissionSidecar.RuntimeContext(
            modelID: "mlx-community/Qwen3-MTP",
            modelRevision: layout.targetSHA256,
            providerRevision: Self.providerRevision,
            upstreamMLXSwiftLMRevision: Self.upstreamRevision,
            hardwareChip: "M2 Ultra",
            ramGB: 256,
            osVersion: "macOS 15.6",
            slotCount: 8,
            revokedTupleSHA256: []
        )
        let authority = NativeMTPResolvedArtifactAuthority.uncheckedForTesting(
            releaseID: Self.releaseID,
            signerKeyID: keyID,
            feedSHA256: String(repeating: "5", count: 64),
            modelKey: "mlx-community/Qwen3-MTP",
            artifactID: "primary",
            hashAlgorithm: NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm,
            hash: layout.targetSHA256,
            verificationStatus: "verified",
            targetURLPath: base.snapshot.appendingPathComponent(layout.targetPath).standardizedFileURL.path,
            targetSHA256: layout.targetSHA256
        )
        return ReleaseEnvelopeFixture(
            base: base,
            sidecarData: sidecarData,
            signatureData: base.signature(for: sidecarData),
            context: context,
            authority: authority
        )
    }

    private struct Fixture {
        let root: URL
        let snapshot: URL
        let rootObject: [String: Any]
        let sidecarData: Data
        let signatureData: Data
        let releaseSidecarData: Data
        let releaseContext: NativeMTPAdmissionSidecar.RuntimeContext
        let releaseAuthority: NativeMTPResolvedArtifactAuthority
        let digests: [String: String]
        let tupleSHA: String
        let signer: Curve25519.Signing.PrivateKey
        let selfTestBankSHA256: String
        let selfTestSignerKeyID: String
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

    private struct ReleaseLayout {
        let targetPath: String
        let targetSHA256: String
        let mtpPath: String
        let mtpSHA256: String
        let tokenizerPath: String
        let tokenizerSHA256: String
        let manifestPath: String
        let manifestSHA256: String
    }

    private struct ReleaseEnvelopeFixture {
        let base: Fixture
        let sidecarData: Data
        let signatureData: Data
        let context: NativeMTPAdmissionSidecar.RuntimeContext
        let authority: NativeMTPResolvedArtifactAuthority

        func authority(
            releaseID: String? = nil,
            signerKeyID: String? = nil,
            feedSHA256: String? = nil,
            modelKey: String? = nil,
            artifactID: String? = nil,
            hashAlgorithm: String? = nil,
            hash: String? = nil,
            verificationStatus: String? = nil,
            targetURLPath: String? = nil,
            targetSHA256: String? = nil
        ) -> NativeMTPResolvedArtifactAuthority {
            NativeMTPResolvedArtifactAuthority.uncheckedForTesting(
                releaseID: releaseID ?? authority.releaseID,
                signerKeyID: signerKeyID ?? authority.signerKeyID,
                feedSHA256: feedSHA256 ?? authority.feedSHA256,
                modelKey: modelKey ?? authority.modelKey,
                artifactID: artifactID ?? authority.artifactID,
                hashAlgorithm: hashAlgorithm ?? authority.hashAlgorithm,
                hash: hash ?? authority.hash,
                verificationStatus: verificationStatus ?? authority.verificationStatus,
                targetURLPath: targetURLPath ?? authority.targetURLPath,
                targetSHA256: targetSHA256 ?? authority.targetSHA256
            )
        }
    }

    private static let modelRevision = String(repeating: "a", count: 40)
    private static let providerRevision = String(repeating: "b", count: 40)
    private static let upstreamRevision = String(repeating: "c", count: 40)
    private static let evidenceSHA = String(repeating: "d", count: 64)
    private static let liveExecutableCDHash = String(repeating: "4", count: 40)
    private static let releaseID = "native-mtp-release-2026-09-28"

    private static func sidecarObject(
        digests: [String: String],
        tupleSHA: String,
        selfTestBankSHA256: String,
        selfTestSignerKeyID: String,
        selfTestSignatureSHA256: String
    ) throws -> [String: Any] {
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
                "complete_window_bytes_by_depth": [1024, 2048, 4096, 8192, 16384],
                "throughput_delta_ppm": 42_000,
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
                "streaming": true,
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
                "live_executable_cdhash": liveExecutableCDHash,
                "benchmark_policy_sha256": String(repeating: "3", count: 64),
                "native_mtp_admission_tuple_sha256": tupleSHA,
                "evidence_artifact_sha256": [evidenceSHA],
            ],
            "selftest": [
                "release_id": "native-mtp-selftest-2026-09-28",
                "challenge_bank_path": "native-mtp-selftest-bank.json",
                "challenge_bank_sha256": selfTestBankSHA256,
                "signature_path": "native-mtp-selftest-bank.json.sig",
                "signer_key_id": selfTestSignerKeyID,
                "signature_sha256": selfTestSignatureSHA256,
            ],
            "flags": [
                "admission_allowed": true,
            ],
        ]
    }

    private static func releaseEntry(
        layout: ReleaseLayout,
        artifactManifestSHA256: String,
        challengeBankSHA256: String
    ) -> [String: Any] {
        [
            "model_key": "mlx-community/Qwen3-MTP",
            "artifact_id": "primary",
            "hash_algorithm": NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm,
            "artifact_hash": layout.targetSHA256,
            "artifact_manifest_sha256": artifactManifestSHA256,
            "tokenizer_sha256": layout.tokenizerSHA256,
            "decode_path": "native_mtp",
            "mtp_manifest_sha256": layout.manifestSHA256,
            "mtp_family_adapter": "qwen3_mtp_v1",
            "mtp_state_class": "stageable_rewindable",
            "mtp_head_count": 4,
            "proposal_depth": 4,
            "complete_window_bytes_by_depth": [1024, 2048, 4096, 8192, 16384],
            "runtime_revision": upstreamRevision,
            "provider_revision": providerRevision,
            "source_commit": providerRevision,
            "reproducible_build_sha256": String(repeating: "2", count: 64),
            "live_executable_cdhash": liveExecutableCDHash,
            "cache_state_classes": ["stageable_rewindable"],
            "hardware_class": "m2-ultra",
            "ram_bytes": 256 * 1_073_741_824,
            "qualified_slots": 8,
            "request_feature_profile": "native_mtp_greedy_text_v1",
            "decrease_threshold_ppm": 1,
            "increase_threshold_ppm": 2,
            "max_verification_positions_per_committed_milli": 1000,
            "throughput_delta_ppm": 42_000,
            "benchmark_policy_sha256": String(repeating: "3", count: 64),
            "challenge_bank_sha256": challengeBankSHA256,
            "fit_evidence_sha256": evidenceSHA,
            "quality_evidence_sha256": evidenceSHA,
            "correctness_evidence_sha256": evidenceSHA,
            "state_rollback_evidence_sha256": evidenceSHA,
            "batch_evidence_sha256": evidenceSHA,
            "performance_evidence_sha256": evidenceSHA,
            "security_negative_evidence_sha256": evidenceSHA,
            "quantization": [
                "kind": "base",
                "packed_data_dtype": "none",
                "packed_layout": "none",
                "scale_dtype": "none",
                "scale_layout": "none",
                "block_size_elements": NSNull(),
                "alignment_bytes": NSNull(),
                "padding_rule": "none",
                "unquantized_exceptions": [],
                "per_layer_exceptions": [],
                "representation_manifest_sha256": String(repeating: "7", count: 64),
            ],
            "ordinary_baseline": [
                "decode_path": "ordinary",
                "runtime_revision": upstreamRevision,
                "provider_revision": providerRevision,
                "artifact_hash": layout.targetSHA256,
                "qualified_slots": 8,
                "measurement_sha256": String(repeating: "8", count: 64),
                "aggregate_tps_milli": 1,
            ],
        ]
    }

    private static func projectionData(layout: ReleaseLayout) throws -> Data {
        try projectionData(artifacts: [
            "target": ["path": layout.targetPath, "sha256": layout.targetSHA256],
            "mtp": ["path": layout.mtpPath, "sha256": layout.mtpSHA256],
            "tokenizer": ["path": layout.tokenizerPath, "sha256": layout.tokenizerSHA256],
            "manifest": ["path": layout.manifestPath, "sha256": layout.manifestSHA256],
        ])
    }

    private static func projectionData(artifacts: [String: Any]) throws -> Data {
        try jsonData([
            "schema_version": "macprovider.native-mtp-artifact-projection.v1",
            "artifacts": artifacts,
        ])
    }

    private static func releaseEnvelopeData(
        layout: ReleaseLayout,
        artifactManifestSHA256: String,
        challengeBankSHA256: String,
        signerKeyID: String,
        challengeBankSignerKeyID: String,
        entryEdit: ((inout [String: Any]) -> Void)? = nil
    ) throws -> Data {
        var entry = releaseEntry(
            layout: layout,
            artifactManifestSHA256: artifactManifestSHA256,
            challengeBankSHA256: challengeBankSHA256
        )
        entryEdit?(&entry)
        return try jsonData([
            "schema_version": NativeMTPAdmissionSidecar.schemaVersion,
            "release_id": releaseID,
            "issued_at": iso8601Seconds(Date().addingTimeInterval(-3600)),
            "expires_at": iso8601Seconds(Date().addingTimeInterval(3600)),
            "signer_key_id": signerKeyID,
            "challenge_bank_signer_key_id": challengeBankSignerKeyID,
            "revocation_signer_key_id": signerKeyID,
            "entries": [entry],
        ])
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

    private static func iso8601Seconds(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
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
