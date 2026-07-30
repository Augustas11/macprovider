import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class CompatibilitySetManifestTests: XCTestCase {
    func testDistributedRollbackPlanMatchesSupportedExecutionContract() throws {
        let phase3Root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let planURL = phase3Root.appendingPathComponent(
            "dist/compatibility-set-assets/updater-rollback.json"
        )

        let plan = try CompatibilitySetRollbackPlan.loadValidated(from: planURL)

        XCTAssertEqual(plan.activationCheckpoints, [
            "owned_resources_removed",
            "owned_resources_activated",
            "watchdog_script_activated",
            "provider_plist_activated",
            "watchdog_plist_activated",
            "binary_activated",
            "malibu_app_activated",
        ])
        XCTAssertEqual(
            plan.rollbackOrder,
            CompatibilitySetRollbackPlan.supportedRollbackOrder
        )
    }

    func testValidSignedCanonicalManifestBindsCatalogAndRelease() throws {
        let fixture = try CompatibilityManifestFixture()

        let manifest = try CompatibilitySetManifest.loadValidated(
            from: fixture.root,
            expectedProviderVersion: fixture.providerCLIVersion,
            publicKeyPEM: fixture.privateKey.publicKey.pemRepresentation
        )

        XCTAssertEqual(manifest.compatibilitySetID, fixture.compatibilitySetID)
        XCTAssertEqual(manifest.version, fixture.version)
        XCTAssertEqual(manifest.providerCLIVersion, fixture.providerCLIVersion)
        XCTAssertEqual(manifest.malibuAppVersion, fixture.malibuAppVersion)
        XCTAssertEqual(manifest.catalogReleaseID, "published-test-release")
        XCTAssertEqual(manifest.catalogPolicyVersion, "catalog-policy-v1")
        XCTAssertEqual(manifest.maintenanceLeaseSeconds, 1_200)
        XCTAssertEqual(manifest.readinessTimeoutSeconds, 1_200)
        XCTAssertEqual(manifest.envelopeSHA256.count, 64)
        XCTAssertEqual(
            CompatibilitySetManifest.requiredExternalGates,
            ["coordinator_admission"]
        )
        XCTAssertTrue(CompatibilitySetManifest.localActivationMembers.contains("malibu_app"))
        XCTAssertFalse(CompatibilitySetManifest.localActivationMembers.contains("coordinator_admission"))
    }

    func testInstalledManifestResolutionFollowsNormalBinarySymlinkTopology() throws {
        let fixture = try CompatibilityManifestFixture()
        let realBinary = fixture.root.appendingPathComponent("macprovider-cli")
        try Data("#!/bin/sh\n".utf8).write(to: realBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: realBinary.path
        )
        let binDirectory = fixture.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: false)
        let linkedBinary = binDirectory.appendingPathComponent("macprovider-cli")
        try FileManager.default.createSymbolicLink(
            at: linkedBinary,
            withDestinationURL: realBinary
        )

        let manifest = try XCTUnwrap(
            CompatibilitySetManifest.loadInstalled(
                executableURL: linkedBinary,
                expectedVersion: fixture.providerCLIVersion,
                publicKeyPEM: fixture.privateKey.publicKey.pemRepresentation
            )
        )

        XCTAssertEqual(
            CompatibilitySetManifest.resolvedExecutableURL(linkedBinary),
            realBinary.standardizedFileURL
        )
        XCTAssertEqual(manifest.compatibilitySetID, fixture.compatibilitySetID)
        XCTAssertEqual(manifest.providerCLIVersion, fixture.providerCLIVersion)
    }

    func testCatalogMutationIsRejectedAfterSignatureVerification() throws {
        let fixture = try CompatibilityManifestFixture()
        try Data("tampered".utf8).write(
            to: fixture.root.appendingPathComponent("catalog-release/release.json")
        )

        XCTAssertThrowsError(
            try CompatibilitySetManifest.loadValidated(
                from: fixture.root,
                expectedProviderVersion: fixture.providerCLIVersion,
                publicKeyPEM: fixture.privateKey.publicKey.pemRepresentation
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.compatibilityManifestInvalid("catalog_digest_mismatch").description
            )
        }
    }

    func testManifestSignatureCannotBeReusedForModifiedPayload() throws {
        let fixture = try CompatibilityManifestFixture()
        let url = fixture.root.appendingPathComponent(CompatibilitySetManifest.fileName)
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var signed = try XCTUnwrap(envelope["signed"] as? [String: Any])
        var transaction = try XCTUnwrap(signed["transaction"] as? [String: Any])
        var readiness = try XCTUnwrap(transaction["readiness_proof"] as? [String: Any])
        readiness["timeout_seconds"] = 1_199
        transaction["readiness_proof"] = readiness
        signed["transaction"] = transaction
        envelope["signed"] = signed
        try CompatibilityManifestFixture.canonicalData(envelope).write(to: url)

        XCTAssertThrowsError(
            try CompatibilitySetManifest.loadValidated(
                from: fixture.root,
                expectedProviderVersion: fixture.providerCLIVersion,
                publicKeyPEM: fixture.privateKey.publicKey.pemRepresentation
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.compatibilityManifestInvalid("signature_invalid").description
            )
        }
    }

    func testLocalActivationArtifactMutationIsRejected() throws {
        let fixture = try CompatibilityManifestFixture()
        try Data("tampered-watchdog".utf8).write(
            to: fixture.root.appendingPathComponent("compatibility-set-local/watchdog.sh")
        )

        XCTAssertThrowsError(
            try CompatibilitySetManifest.loadValidated(
                from: fixture.root,
                expectedProviderVersion: fixture.providerCLIVersion,
                publicKeyPEM: fixture.privateKey.publicKey.pemRepresentation
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.compatibilityManifestInvalid("watchdog_script_digest_mismatch").description
            )
        }
    }

    func testSignedButUnsupportedRollbackExecutionOrderIsRejected() throws {
        let fixture = try CompatibilityManifestFixture()
        let planURL = fixture.root.appendingPathComponent(
            "compatibility-set-local/updater-rollback.json"
        )
        var plan = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: planURL)) as? [String: Any]
        )
        plan["rollback_order"] = Array(
            CompatibilitySetRollbackPlan.supportedRollbackOrder.reversed()
        )
        try CompatibilityManifestFixture.canonicalData(plan).write(to: planURL)
        try fixture.writeManifest()

        XCTAssertThrowsError(
            try CompatibilitySetManifest.loadValidated(
                from: fixture.root,
                expectedProviderVersion: fixture.providerCLIVersion,
                publicKeyPEM: fixture.privateKey.publicKey.pemRepresentation
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.compatibilityManifestInvalid(
                    "updater_rollback_plan_noncanonical_or_unsupported"
                ).description
            )
        }
    }

    func testNoncanonicalEnvelopeAndVersionSkewFailClosed() throws {
        let fixture = try CompatibilityManifestFixture()
        let url = fixture.root.appendingPathComponent(CompatibilitySetManifest.fileName)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var pretty = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        pretty.append(0x0a)
        try pretty.write(to: url)

        XCTAssertThrowsError(
            try CompatibilitySetManifest.loadValidated(
                from: fixture.root,
                expectedProviderVersion: fixture.providerCLIVersion,
                publicKeyPEM: fixture.privateKey.publicKey.pemRepresentation
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.compatibilityManifestInvalid("noncanonical_envelope").description
            )
        }

        try fixture.writeManifest()
        XCTAssertThrowsError(
            try CompatibilitySetManifest.loadValidated(
                from: fixture.root,
                expectedProviderVersion: "9.9.9",
                publicKeyPEM: fixture.privateKey.publicKey.pemRepresentation
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.compatibilityManifestVersionMismatch(
                    expected: "9.9.9",
                    actual: fixture.providerCLIVersion
                ).description
            )
        }
    }
}

final class CompatibilityManifestFixture {
    static let catalogNames = [
        "autotune-candidates.json",
        "autotune-candidates.json.sig",
        "demand-rank.json",
        "demand-rank.json.sig",
        "rate-card.json",
        "rate-card.json.sig",
        "release.json",
        "tier2-catalog.json",
        "trusted-keys.json",
    ]

    let root: URL
    let privateKey: P256.Signing.PrivateKey
    let version: String
    let providerCLIVersion: String
    let malibuAppVersion: String
    let commit: String
    private let ownsRoot: Bool
    var compatibilitySetID: String {
        "Augustas11/macprovider:v\(version)@\(commit)"
    }

    init(
        root: URL? = nil,
        privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
        version: String = "1.8.42",
        providerCLIVersion: String = "1.8.40",
        malibuAppVersion: String = "1.8.41",
        commit: String = "0123456789abcdef0123456789abcdef01234567",
        populateResources: Bool = true
    ) throws {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("compatibility-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        self.privateKey = privateKey
        self.version = version
        self.providerCLIVersion = providerCLIVersion
        self.malibuAppVersion = malibuAppVersion
        self.commit = commit
        ownsRoot = root == nil
        if ownsRoot {
            try FileManager.default.createDirectory(
                at: self.root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if populateResources {
            try populateFixtureResources()
        }
        try writeManifest()
    }

    private func populateFixtureResources() throws {
        let catalog = root.appendingPathComponent("catalog-release", isDirectory: true)
        try FileManager.default.createDirectory(
            at: catalog,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for name in Self.catalogNames {
            try Data("fixture-\(name)".utf8).write(to: catalog.appendingPathComponent(name))
        }
        let local = root.appendingPathComponent("compatibility-set-local", isDirectory: true)
        try FileManager.default.createDirectory(
            at: local,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for name in [
            "install.sh",
            "provider-launch-agent.plist.template",
            "watchdog-launch-agent.plist.template",
            "watchdog.sh",
        ] {
            try Data("fixture-\(name)".utf8).write(to: local.appendingPathComponent(name))
        }
        try CompatibilitySetRollbackPlan.canonicalSupportedData().write(
            to: local.appendingPathComponent("updater-rollback.json")
        )
    }

    deinit {
        if ownsRoot {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func writeManifest() throws {
        let catalog = root.appendingPathComponent("catalog-release", isDirectory: true)
        var catalogDigests: [String: Any] = [:]
        for name in Self.catalogNames {
            let bytes = try Data(contentsOf: catalog.appendingPathComponent(name))
            catalogDigests[name] = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        func artifact(_ name: String) throws -> [String: Any] {
            let bytes = try Data(contentsOf: root.appendingPathComponent("compatibility-set-local/\(name)"))
            return [
                "path": "compatibility-set-local/\(name)",
                "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            ]
        }
        let signed: [String: Any] = [
            "schema_version": "macprovider.compatibility-set.v1",
            "compatibility_set_id": compatibilitySetID,
            "release": [
                "repository": "Augustas11/macprovider",
                "tag": "v\(version)",
                "version": version,
                "commit": commit,
            ],
            "artifact_binding": [
                "mode": "signed_release_checksums",
                "embedded_container_hashes": "excluded_to_avoid_self_reference",
            ],
            "components": [
                "catalog": [
                    "activation": "local",
                    "schema_version": "macprovider.autotune-release.v1",
                    "release_id": "published-test-release",
                    "policy_version": "catalog-policy-v1",
                    "files": catalogDigests,
                ],
                "malibu_app": [
                    "activation": "cli_owned_if_installed",
                    "bundle_id": "tech.malibu.app",
                    "compatibility_handoff": [
                        "delivery": "signed_dmg_transaction_member",
                        "embedded_manifest_path": "Contents/Resources/compatibility-set.json",
                        "provider_mutation": "forbidden",
                        "reader_compatibility": "backward_compatible",
                    ],
                    "minimum_status_reader": 1,
                    "version": malibuAppVersion,
                ],
                "provider_cli": [
                    "activation": "local",
                    "designated_identifier": "live.streamvc.macprovider.cli",
                    "platform": "darwin-arm64",
                    "status_contract": "macprovider.local-status.v1",
                    "version": providerCLIVersion,
                ],
                "launchd": [
                    "activation": "local",
                    "contract": "macprovider.launch-agent.v1",
                    "install_contract": try artifact("install.sh"),
                    "label": "live.streamvc.macprovider",
                    "plist_template": try artifact("provider-launch-agent.plist.template"),
                ],
                "watchdog": [
                    "activation": "local",
                    "contract": "macprovider.exact-service-pid-watchdog.v1",
                    "monitored_label": "live.streamvc.macprovider",
                    "plist_template": try artifact("watchdog-launch-agent.plist.template"),
                    "script": try artifact("watchdog.sh"),
                    "service_label": "live.streamvc.macprovider-watchdog",
                ],
                "coordinator_admission": [
                    "activation": "required_remote_gate",
                    "handshake": "accepted_set_echo_v1",
                    "policy_version": "provider-admission.v1",
                    "scope": "remote_coordinator_policy",
                    "version": version,
                    "rollout": [
                        "bridge_duration_seconds": 86_400,
                        "enforce_provider_admission": false,
                        "mode": "bridge_required",
                    ],
                ],
                "updater_rollback": [
                    "activation": "local",
                    "metadata": try artifact("updater-rollback.json"),
                    "metadata_version": 1,
                    "protocol": "macprovider.compatibility-set-transaction.v1",
                ],
            ],
            "transaction": [
                "activation": "crash_recoverable_local_activation_group",
                "autoupdate_scope": "compatibility_cohort",
                "maintenance_lease": [
                    "maximum_seconds": 1_200,
                    "protocol": "macprovider.maintenance-lease.v1",
                ],
                "membership": [
                    "local_activation_group": CompatibilitySetManifest.localActivationMembers,
                    "required_external_gates": CompatibilitySetManifest.requiredExternalGates,
                    "preserved_state_invariants": CompatibilitySetManifest.preservedStateInvariants,
                ],
                "preflight": [
                    "mode": "exact_target_set",
                    "remote_gate": "coordinator_acceptance_required",
                ],
                "readiness_proof": [
                    "compatibility_set_echo": "exact",
                    "contract": "macprovider.local-status.v1",
                    "network_state": "buyer_serving",
                    "timeout_seconds": 1_200,
                ],
                "rollback": [
                    "members": CompatibilitySetManifest.localActivationMembers,
                    "mode": "local_activation_group",
                ],
            ],
        ]
        let signedBytes = try Self.canonicalData(signed)
        let signature = try privateKey.signature(for: SHA256.hash(data: signedBytes))
        let envelope: [String: Any] = [
            "schema_version": "macprovider.compatibility-set-envelope.v1",
            "signatures": [[
                "algorithm": "ecdsa-p256-sha256",
                "key_id": "macprovider-release-p256-v1",
                "signature": signature.derRepresentation.base64EncodedString(),
            ]],
            "signed": signed,
        ]
        try Self.canonicalData(envelope).write(
            to: root.appendingPathComponent(CompatibilitySetManifest.fileName)
        )
    }

    static func canonicalData(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }
}
