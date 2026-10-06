import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-023 §12.5 Stage A delivery (G3): fetch, pre-check, and private
/// materialization of the native-MTP admission set.
final class NativeMTPAdmissionFeedTests: XCTestCase {
    private let keyID = "streamvc-autotune-static-test"

    private func signedMembers(
        key: Curve25519.Signing.PrivateKey,
        keyID: String? = nil,
        releaseID: String = "release-1",
        signerKeyID: String? = nil
    ) throws -> NativeMTPAdmissionFeed.Members {
        let sidecar = Data(#"{"release_id":"\#(releaseID)","signer_key_id":"\#(signerKeyID ?? self.keyID)","schema_version":"macprovider.native-mtp-admission.v1"}"#.utf8)
        let signature = try key.signature(for: sidecar)
        let envelope = try JSONSerialization.data(withJSONObject: [
            "alg": "ed25519",
            "key_id": keyID ?? self.keyID,
            "signature": signature.base64EncodedString(),
        ])
        return NativeMTPAdmissionFeed.Members(
            sidecar: sidecar,
            signature: envelope,
            manifest: Data(#"{"manifest":1}"#.utf8),
            bank: Data(#"{"bank":1}"#.utf8),
            bankSignature: Data(#"{"alg":"ed25519"}"#.utf8)
        )
    }

    private func keyring(_ key: Curve25519.Signing.PrivateKey) -> [String: String] {
        [keyID: key.publicKey.rawRepresentation.base64EncodedString()]
    }

    func testPrecheckAcceptsOnlyTheReleaseSignerAndRelease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let members = try signedMembers(key: key)
        XCTAssertNoThrow(try NativeMTPAdmissionFeed.precheck(members, releaseID: "release-1", signerKeyID: keyID, trustedPublicKeys: keyring(key)))
        XCTAssertThrowsError(try NativeMTPAdmissionFeed.precheck(members, releaseID: "release-2", signerKeyID: keyID, trustedPublicKeys: keyring(key))) {
            XCTAssertEqual($0 as? NativeMTPAdmissionFeed.FetchError, .releaseMismatch)
        }
        XCTAssertThrowsError(try NativeMTPAdmissionFeed.precheck(members, releaseID: "release-1", signerKeyID: "other-key", trustedPublicKeys: keyring(key))) {
            XCTAssertEqual($0 as? NativeMTPAdmissionFeed.FetchError, .signerMismatch)
        }
        let foreign = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try NativeMTPAdmissionFeed.precheck(signedMembers(key: foreign), releaseID: "release-1", signerKeyID: keyID, trustedPublicKeys: keyring(key))) {
            XCTAssertEqual($0 as? NativeMTPAdmissionFeed.FetchError, .signatureInvalid)
        }
        let tampered = NativeMTPAdmissionFeed.Members(
            sidecar: Data(members.sidecar.reversed()),
            signature: members.signature,
            manifest: members.manifest,
            bank: members.bank,
            bankSignature: members.bankSignature
        )
        XCTAssertThrowsError(try NativeMTPAdmissionFeed.precheck(tampered, releaseID: "release-1", signerKeyID: keyID, trustedPublicKeys: keyring(key)))
        XCTAssertThrowsError(try NativeMTPAdmissionFeed.precheck(signedMembers(key: key, signerKeyID: "other-key"), releaseID: "release-1", signerKeyID: keyID, trustedPublicKeys: keyring(key))) {
            XCTAssertEqual($0 as? NativeMTPAdmissionFeed.FetchError, .signerMismatch)
        }
    }

    func testFetchMaterializesExactBytesPrivatelyAndDropsOtherReleases() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let members = try signedMembers(key: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-mtp-feed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("stale-release", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        let served: [String: Data] = [
            "native-mtp-admission": members.sidecar,
            "native-mtp-admission.sig": members.signature,
            "native-mtp-artifact-manifest": members.manifest,
            "native-mtp-selftest-bank": members.bank,
            "native-mtp-selftest-bank.sig": members.bankSignature,
        ]
        var requested: [String] = []
        let sidecarURL = try await NativeMTPAdmissionFeed.fetchAndMaterialize(
            releaseID: "release-1",
            signerKeyID: keyID,
            trustedPublicKeys: keyring(key),
            fetch: { url in
                requested.append(url.path)
                guard let data = served[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
                return data
            },
            baseURL: URL(string: "https://feeds.example")!,
            root: root
        )

        XCTAssertEqual(Set(requested), Set(served.keys.map { "/v1/\($0)" }))
        let directory = sidecarURL.deletingLastPathComponent()
        XCTAssertEqual(directory, NativeMTPAdmissionFeed.releaseDirectory(root: root, releaseID: "release-1"))
        for (name, data) in [
            ("native-mtp-admission.json", members.sidecar),
            ("native-mtp-admission.json.sig", members.signature),
            ("native-mtp-artifact-manifest.json", members.manifest),
            ("native-mtp-selftest-bank.json", members.bank),
            ("native-mtp-selftest-bank.json.sig", members.bankSignature),
        ] {
            let url = directory.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: url), data, name)
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, name)
        }
        for url in [root, directory] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o700, url.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testMissingMemberOrOversizedMemberWritesNothing() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let members = try signedMembers(key: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-mtp-feed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for broken in ["native-mtp-selftest-bank.sig", "native-mtp-admission"] {
            do {
                _ = try await NativeMTPAdmissionFeed.fetchAndMaterialize(
                    releaseID: "release-1",
                    signerKeyID: keyID,
                    trustedPublicKeys: keyring(key),
                    fetch: { url in
                        switch url.lastPathComponent {
                        case broken where broken == "native-mtp-admission":
                            return Data(count: NativeMTPAdmissionSidecar.maxSidecarBytes + 1)
                        case broken:
                            throw URLError(.fileDoesNotExist)
                        case "native-mtp-admission": return members.sidecar
                        case "native-mtp-admission.sig": return members.signature
                        case "native-mtp-artifact-manifest": return members.manifest
                        case "native-mtp-selftest-bank": return members.bank
                        default: return members.bankSignature
                        }
                    },
                    root: root
                )
                XCTFail("\(broken) accepted")
            } catch {
                XCTAssertNotNil(error as? NativeMTPAdmissionFeed.FetchError)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), broken)
        }
    }

    // MARK: - Store-layout projection (drafter delivery)

    private let targetRevision = String(repeating: "1", count: 40)
    private let drafterRevision = String(repeating: "2", count: 40)
    private let targetSHA = String(repeating: "a", count: 64)
    private let drafterSHA = String(repeating: "b", count: 64)

    private func storeManifest(targetPath: String? = nil, mtpPath: String? = nil) throws -> Data {
        let target = targetPath ?? "mlx-community--Qwen3.6-35B-A3B-4bit/\(targetRevision)/\(targetSHA)"
        let mtp = mtpPath ?? "mlx-community--Qwen3.6-35B-A3B-MTP-4bit/\(drafterRevision)/\(drafterSHA)"
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": "macprovider.native-mtp-artifact-projection.v1",
            "artifacts": [
                "target": ["path": target, "sha256": targetSHA],
                "mtp": ["path": mtp, "sha256": drafterSHA],
                "tokenizer": ["path": target + "/tokenizer.json", "sha256": String(repeating: "c", count: 64)],
                "manifest": ["path": mtp + "/config.json", "sha256": String(repeating: "d", count: 64)],
            ],
        ])
    }

    func testStoreProjectionMemberReversesTheStoreEscapingExactly() {
        let path = "mlx-community--Qwen3.6-35B-A3B-MTP-4bit/\(drafterRevision)/\(drafterSHA)"
        XCTAssertEqual(
            NativeMTPStoreProjection.member(path: path, sha256: drafterSHA),
            .init(repoID: "mlx-community/Qwen3.6-35B-A3B-MTP-4bit", revision: drafterRevision, sha256: drafterSHA)
        )
        for bad in [
            "mlx-community--Qwen3.6-MTP/\(drafterRevision)/\(targetSHA)",     // digest is not the member's
            "mlx-community--Qwen3.6-MTP/main/\(drafterSHA)",                  // revision is not pinned
            "mlx-community/Qwen3.6-MTP/\(drafterRevision)/\(drafterSHA)",     // four components
            "mlx-community--a--b/\(drafterRevision)/\(drafterSHA)",          // ambiguous escaping
            "Qwen3.6-MTP/\(drafterRevision)/\(drafterSHA)",                  // no owner
            "..--x/\(drafterRevision)/\(drafterSHA)",                        // traversal
            "mlx-community---x/\(drafterRevision)/\(drafterSHA)",            // owner ends in '-'
        ] {
            XCTAssertNil(NativeMTPStoreProjection.member(path: bad, sha256: drafterSHA), bad)
        }
    }

    func testStoreProjectionFetchesTheDrafterAndReturnsTheStoreRoot() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("store-\(UUID().uuidString)")
        let resolver = CachedModelArtifactResolver(durableRoot: root)
        let served = root.appendingPathComponent("mlx-community--Qwen3.6-35B-A3B-4bit/\(targetRevision)/\(targetSHA)")
        let drafterURL = root.appendingPathComponent("mlx-community--Qwen3.6-35B-A3B-MTP-4bit/\(drafterRevision)/\(drafterSHA)")
        var requested: CandidateCatalog.Row?
        let prepared = await NativeMTPStoreProjection.prepare(
            manifest: try storeManifest(),
            servedTargetURL: served,
            resolver: resolver,
            fetchDrafter: { _, row, _ in
                requested = row
                return VerifiedModelArtifact(
                    modelArgument: drafterURL.path, sha256: row.modelSHA256!, sizeBytes: 1,
                    configJSONData: nil, configSHA256: nil
                )
            }
        )
        XCTAssertEqual(prepared?.path, root.standardizedFileURL.path)
        XCTAssertEqual(requested?.modelID, "mlx-community/Qwen3.6-35B-A3B-MTP-4bit")
        XCTAssertEqual(requested?.modelRevision, drafterRevision)
        XCTAssertEqual(requested?.modelSHA256, drafterSHA)
    }

    func testStoreProjectionStaysOrdinaryUnlessTargetAndDrafterBothBind() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("store-\(UUID().uuidString)")
        let resolver = CachedModelArtifactResolver(durableRoot: root)
        let served = root.appendingPathComponent("mlx-community--Qwen3.6-35B-A3B-4bit/\(targetRevision)/\(targetSHA)")
        let drafterURL = root.appendingPathComponent("mlx-community--Qwen3.6-35B-A3B-MTP-4bit/\(drafterRevision)/\(drafterSHA)")
        func fetched(_ path: URL, sha: String? = nil) -> (CachedModelArtifactResolver, CandidateCatalog.Row, Date) async throws -> VerifiedModelArtifact {
            { _, row, _ in
                VerifiedModelArtifact(modelArgument: path.path, sha256: sha ?? row.modelSHA256!, sizeBytes: 1,
                                      configJSONData: nil, configSHA256: nil)
            }
        }
        // The projection's target is not the artifact being served.
        let other = root.appendingPathComponent("other/\(targetRevision)/\(targetSHA)")
        let notServed = await NativeMTPStoreProjection.prepare(
            manifest: try storeManifest(), servedTargetURL: other, resolver: resolver, fetchDrafter: fetched(drafterURL))
        XCTAssertNil(notServed)
        // The drafter cannot be fetched.
        let unreachable = await NativeMTPStoreProjection.prepare(
            manifest: try storeManifest(), servedTargetURL: served, resolver: resolver,
            fetchDrafter: { _, _, _ in throw AutotuneRecommendError.invalidArtifact("offline") })
        XCTAssertNil(unreachable)
        // The adopted drafter is not at the projected path, or not the projected bytes.
        let misplaced = await NativeMTPStoreProjection.prepare(
            manifest: try storeManifest(), servedTargetURL: served, resolver: resolver,
            fetchDrafter: fetched(root.appendingPathComponent("elsewhere")))
        XCTAssertNil(misplaced)
        let wrongBytes = await NativeMTPStoreProjection.prepare(
            manifest: try storeManifest(), servedTargetURL: served, resolver: resolver,
            fetchDrafter: fetched(drafterURL, sha: String(repeating: "e", count: 64)))
        XCTAssertNil(wrongBytes)
        // A bundle-layout manifest is not a store projection.
        XCTAssertNil(NativeMTPStoreProjection.members(manifest: try storeManifest(targetPath: "target", mtpPath: "mtp")))
    }
}

