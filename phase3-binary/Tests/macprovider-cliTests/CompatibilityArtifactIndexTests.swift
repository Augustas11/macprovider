import Foundation
import XCTest
@testable import macprovider_cli

final class CompatibilityArtifactIndexTests: XCTestCase {
    func testExactSignedReleaseSetIsAccepted() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let parsed = try CompatibilityArtifactIndex.loadValidated(
            from: fixture.index,
            compatibilityManifest: fixture.manifest,
            checksumsText: fixture.checksums,
            releaseAssetNames: fixture.releaseAssetNames
        )

        XCTAssertEqual(parsed.compatibilitySetID, fixture.manifest.compatibilitySetID)
        XCTAssertEqual(parsed.artifacts["coordinator"]?.name, "coordinator-linux-amd64")
    }

    func testCoordinatorDigestDriftIsRejectedEvenWhenLocalMembersMatch() throws {
        let fixture = try makeFixture(overrides: ["coordinator": String(repeating: "f", count: 64)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try CompatibilityArtifactIndex.loadValidated(
                from: fixture.index,
                compatibilityManifest: fixture.manifest,
                checksumsText: fixture.checksums,
                releaseAssetNames: fixture.releaseAssetNames
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.compatibilityArtifactIndexInvalid("artifact_coordinator").description
            )
        }
    }

    private func makeFixture(overrides: [String: String] = [:]) throws -> (
        root: URL,
        index: URL,
        manifest: CompatibilitySetManifest,
        checksums: String,
        releaseAssetNames: [String]
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compatibility-artifact-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let tag = "v1.8.33"
        let commit = String(repeating: "a", count: 40)
        let setID = "Augustas11/macprovider:\(tag)@\(commit)"
        let manifestSHA = String(repeating: "b", count: 64)
        let manifest = CompatibilitySetManifest(
            compatibilitySetID: setID,
            envelopeSHA256: manifestSHA,
            version: "1.8.33",
            catalogReleaseID: "catalog-test",
            catalogPolicyVersion: "1",
            maintenanceLeaseSeconds: 600,
            readinessTimeoutSeconds: 300
        )
        let names = [
            "catalog_candidates": "autotune-candidates.json",
            "catalog_candidates_signature": "autotune-candidates.json.sig",
            "catalog_demand": "demand-rank.json",
            "catalog_demand_signature": "demand-rank.json.sig",
            "catalog_manifest": "release.json",
            "catalog_tier2": "tier2-catalog.json",
            "catalog_trusted_keys": "trusted-keys.json",
            "compatibility_manifest": "compatibility-set.json",
            "coordinator": "coordinator-linux-amd64",
            "coordinator_cli": "coordinator-cli-linux-amd64",
            "gateway": "gateway-linux-amd64",
            "malibu_app": "Malibu-\(tag).dmg",
            "pearl_metadata": "pearl-release.json",
            "pearl_metadata_signature": "pearl-release.json.sig",
            "provider_cli": "macprovider-cli-\(tag)-darwin-arm64.tar.gz",
        ]
        var artifacts: [String: Any] = [:]
        var checksums: [String] = []
        for role in CompatibilityArtifactIndex.requiredRoles {
            let digest = role == "compatibility_manifest"
                ? manifestSHA
                : String(repeating: String(role.utf8.reduce(0) { $0 + Int($1) } % 10), count: 64)
            artifacts[role] = ["name": names[role]!, "sha256": overrides[role] ?? digest]
            checksums.append("\(digest)  \(names[role]!)")
        }
        let object: [String: Any] = [
            "artifacts": artifacts,
            "commit": commit,
            "compatibility_manifest_sha256": manifestSHA,
            "compatibility_set_id": setID,
            "repository": "Augustas11/macprovider",
            "schema_version": CompatibilityArtifactIndex.schemaVersion,
            "tag": tag,
        ]
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        let index = root.appendingPathComponent(CompatibilityArtifactIndex.fileName)
        try data.write(to: index)
        let releaseAssetNames = Array(names.values) + [
            CompatibilityArtifactIndex.fileName, "checksums.txt", "checksums.txt.sig",
        ]
        return (root, index, manifest, checksums.joined(separator: "\n") + "\n", releaseAssetNames)
    }
}
