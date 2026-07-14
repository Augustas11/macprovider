import CryptoKit
import Darwin
import Foundation

struct CompatibilitySetRollbackPlan: Equatable, Sendable {
    static let schemaVersion = "macprovider.compatibility-set-rollback-plan.v1"
    static let protocolVersion = "macprovider.compatibility-set-transaction.v1"
    static let supportedActivationCheckpoints = CompatibilitySetCutoverPhase.allCases.map(\.rawValue)
    static let supportedRollbackOrder = [
        "release_resources", "catalog", "updater_rollback", "watchdog", "launchd",
        "malibu_app", "provider_cli",
    ]

    let activationCheckpoints: [String]
    let rollbackOrder: [String]

    static func loadValidated(from url: URL) throws -> CompatibilitySetRollbackPlan {
        let data = try CompatibilitySetManifest.readTrustedRegularFile(url)
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(data)
        } catch {
            throw UpdateError.compatibilityManifestInvalid("updater_rollback_plan_json")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set([
                  "activation_checkpoints", "metadata_version", "protocol", "rollback_order",
                  "rollback_scope", "schema_version",
              ]),
              object["schema_version"] as? String == schemaVersion,
              object["metadata_version"] as? Int == 1,
              object["protocol"] as? String == protocolVersion,
              object["rollback_scope"] as? String == "all_activated_local_members",
              let activationCheckpoints = object["activation_checkpoints"] as? [String],
              let rollbackOrder = object["rollback_order"] as? [String]
        else {
            throw UpdateError.compatibilityManifestInvalid("updater_rollback_plan_fields")
        }
        guard data == (try canonicalSupportedData()) else {
            throw UpdateError.compatibilityManifestInvalid("updater_rollback_plan_noncanonical_or_unsupported")
        }
        return CompatibilitySetRollbackPlan(
            activationCheckpoints: activationCheckpoints,
            rollbackOrder: rollbackOrder
        )
    }

    static func canonicalSupportedData() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "activation_checkpoints": supportedActivationCheckpoints,
            "metadata_version": 1,
            "protocol": protocolVersion,
            "rollback_order": supportedRollbackOrder,
            "rollback_scope": "all_activated_local_members",
            "schema_version": schemaVersion,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        return data
    }
}

struct CompatibilityArtifactIndex: Equatable, Sendable {
    static let fileName = "compatibility-artifact-index.json"
    static let schemaVersion = "macprovider.compatibility-artifact-index.v1"
    static let requiredRoles = [
        "catalog_candidates",
        "catalog_candidates_signature",
        "catalog_demand",
        "catalog_demand_signature",
        "catalog_manifest",
        "catalog_trusted_keys",
        "compatibility_manifest",
        "coordinator",
        "coordinator_cli",
        "gateway",
        "malibu_app",
        "pearl_metadata",
        "pearl_metadata_signature",
        "provider_cli",
    ]

    struct Artifact: Equatable, Sendable {
        let name: String
        let sha256: String
    }

    let compatibilitySetID: String
    let artifacts: [String: Artifact]

    static func loadValidated(
        from url: URL,
        compatibilityManifest: CompatibilitySetManifest,
        checksumsText: String,
        releaseAssetNames: [String]
    ) throws -> CompatibilityArtifactIndex {
        let data = try CompatibilitySetManifest.readTrustedRegularFile(url)
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(data)
        } catch {
            throw UpdateError.compatibilityArtifactIndexInvalid("duplicate_or_invalid_json")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set([
                  "artifacts", "commit", "compatibility_manifest_sha256",
                  "compatibility_set_id", "repository", "schema_version", "tag",
              ]),
              object["schema_version"] as? String == schemaVersion,
              var canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else {
            throw UpdateError.compatibilityArtifactIndexInvalid("fields")
        }
        canonical.append(0x0a)
        guard canonical == data else {
            throw UpdateError.compatibilityArtifactIndexInvalid("noncanonical")
        }

        guard let repository = object["repository"] as? String,
              repository.range(
                  of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#,
                  options: .regularExpression
              ) != nil,
              let tag = object["tag"] as? String,
              tag == "v\(compatibilityManifest.version)",
              let commit = object["commit"] as? String,
              commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              let setID = object["compatibility_set_id"] as? String,
              setID == compatibilityManifest.compatibilitySetID,
              setID == "\(repository):\(tag)@\(commit)",
              object["compatibility_manifest_sha256"] as? String == compatibilityManifest.envelopeSHA256
        else {
            throw UpdateError.compatibilityArtifactIndexInvalid("release_identity")
        }

        guard let rawArtifacts = object["artifacts"] as? [String: Any],
              Set(rawArtifacts.keys) == Set(requiredRoles)
        else {
            throw UpdateError.compatibilityArtifactIndexInvalid("artifact_roles")
        }
        let expectedNames = expectedArtifactNames(tag: tag)
        let checksumEntries = try parseChecksums(checksumsText)
        guard Set(releaseAssetNames).count == releaseAssetNames.count,
              releaseAssetNames.contains(fileName)
        else {
            throw UpdateError.compatibilityArtifactIndexInvalid("release_asset_names")
        }
        let releaseNames = Set(releaseAssetNames)
        var artifacts: [String: Artifact] = [:]
        var seenNames = Set<String>()
        for role in requiredRoles {
            guard let row = rawArtifacts[role] as? [String: Any],
                  Set(row.keys) == Set(["name", "sha256"]),
                  let name = row["name"] as? String,
                  name == expectedNames[role],
                  let digest = row["sha256"] as? String,
                  digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  seenNames.insert(name).inserted,
                  releaseNames.contains(name),
                  checksumEntries[name] == digest
            else {
                throw UpdateError.compatibilityArtifactIndexInvalid("artifact_\(role)")
            }
            artifacts[role] = Artifact(name: name, sha256: digest)
        }
        guard artifacts["compatibility_manifest"]?.sha256 == compatibilityManifest.envelopeSHA256 else {
            throw UpdateError.compatibilityArtifactIndexInvalid("compatibility_manifest_digest")
        }
        return CompatibilityArtifactIndex(compatibilitySetID: setID, artifacts: artifacts)
    }

    private static func expectedArtifactNames(tag: String) -> [String: String] {
        [
            "catalog_candidates": "autotune-candidates.json",
            "catalog_candidates_signature": "autotune-candidates.json.sig",
            "catalog_demand": "demand-rank.json",
            "catalog_demand_signature": "demand-rank.json.sig",
            "catalog_manifest": "release.json",
            "catalog_trusted_keys": "trusted-keys.json",
            "compatibility_manifest": CompatibilitySetManifest.fileName,
            "coordinator": "coordinator-linux-amd64",
            "coordinator_cli": "coordinator-cli-linux-amd64",
            "gateway": "gateway-linux-amd64",
            "malibu_app": "Malibu-\(tag).dmg",
            "pearl_metadata": "pearl-release.json",
            "pearl_metadata_signature": "pearl-release.json.sig",
            "provider_cli": "macprovider-cli-\(tag)-darwin-arm64.tar.gz",
        ]
    }

    private static func parseChecksums(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.isEmpty { continue }
            let pieces = rawLine.split(separator: " ", omittingEmptySubsequences: false)
            guard pieces.count == 3,
                  pieces[1].isEmpty,
                  String(pieces[0]).range(
                      of: #"^[0-9a-f]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  String(pieces[2]).range(
                      of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$"#,
                      options: .regularExpression
                  ) != nil,
                  result.updateValue(String(pieces[0]), forKey: String(pieces[2])) == nil
            else {
                throw UpdateError.compatibilityArtifactIndexInvalid("checksums")
            }
        }
        return result
    }
}

struct CompatibilitySetManifest: Equatable, Sendable {
    static let fileName = "compatibility-set.json"
    static let localArtifactDirectoryName = "compatibility-set-local"
    static let maximumBytes = 1_048_576
    static let localActivationMembers = [
        "catalog", "launchd", "malibu_app", "provider_cli", "release_resources",
        "updater_rollback", "watchdog",
    ]
    static let requiredExternalGates = ["coordinator_admission"]
    static let preservedStateInvariants = ["credentials", "identity", "operator_config"]

    let compatibilitySetID: String
    let envelopeSHA256: String
    let version: String
    let catalogReleaseID: String
    let catalogPolicyVersion: String
    let maintenanceLeaseSeconds: Int
    let readinessTimeoutSeconds: Int

    static func isCanonicalCompatibilitySetID(_ value: String) -> Bool {
        guard value.utf8.count <= 256 else { return false }
        return value.range(
            of: #"^[A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,100}:v[0-9]+\.[0-9]+\.[0-9]+@[0-9a-f]{40}$"#,
            options: .regularExpression
        ) != nil
    }

    static func loadValidated(
        from payloadDirectory: URL,
        expectedVersion: String,
        publicKeyPEM: String = SelfUpdate.checksumPublicKeyPEM
    ) throws -> CompatibilitySetManifest {
        let url = payloadDirectory.appendingPathComponent(fileName)
        let data = try readTrustedRegularFile(url)
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(data)
        } catch {
            throw UpdateError.compatibilityManifestInvalid("duplicate_or_invalid_json")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.compatibilityManifestInvalid("top_level")
        }
        try requireExactKeys(envelope, ["schema_version", "signatures", "signed"], "envelope")
        try requireString(envelope["schema_version"], equals: "macprovider.compatibility-set-envelope.v1", "envelope_schema")
        guard var canonicalEnvelope = try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw UpdateError.compatibilityManifestInvalid("canonical_envelope")
        }
        canonicalEnvelope.append(0x0a)
        guard canonicalEnvelope == data else {
            throw UpdateError.compatibilityManifestInvalid("noncanonical_envelope")
        }

        guard let signatures = envelope["signatures"] as? [Any], signatures.count == 1,
              let signature = signatures.first as? [String: Any]
        else {
            throw UpdateError.compatibilityManifestInvalid("signature_count")
        }
        try requireExactKeys(signature, ["algorithm", "key_id", "signature"], "signature")
        try requireString(signature["algorithm"], equals: "ecdsa-p256-sha256", "signature_algorithm")
        try requireString(signature["key_id"], equals: "macprovider-release-p256-v1", "signature_key_id")
        guard let encodedSignature = signature["signature"] as? String,
              let signatureData = Data(base64Encoded: encodedSignature),
              signatureData.base64EncodedString() == encodedSignature,
              (64...80).contains(signatureData.count)
        else {
            throw UpdateError.compatibilityManifestInvalid("signature_encoding")
        }

        guard let signed = envelope["signed"] as? [String: Any] else {
            throw UpdateError.compatibilityManifestInvalid("signed_payload")
        }
        try requireExactKeys(
            signed,
            ["artifact_binding", "compatibility_set_id", "components", "release", "schema_version", "transaction"],
            "signed"
        )
        try requireString(signed["schema_version"], equals: "macprovider.compatibility-set.v1", "payload_schema")
        guard var signedBytes = try? JSONSerialization.data(
            withJSONObject: signed,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw UpdateError.compatibilityManifestInvalid("canonical_signed_payload")
        }
        signedBytes.append(0x0a)
        do {
            let publicKey = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
            let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            guard publicKey.isValidSignature(ecdsa, for: SHA256.hash(data: signedBytes)) else {
                throw UpdateError.compatibilityManifestInvalid("signature_invalid")
            }
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.compatibilityManifestInvalid("signature_invalid")
        }

        guard let release = signed["release"] as? [String: Any] else {
            throw UpdateError.compatibilityManifestInvalid("release")
        }
        try requireExactKeys(release, ["commit", "repository", "tag", "version"], "release")
        let version = try requirePattern(release["version"], #"^[0-9]+\.[0-9]+\.[0-9]+$"#, "release_version")
        let tag = try requirePattern(release["tag"], #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, "release_tag")
        let commit = try requirePattern(release["commit"], #"^[0-9a-f]{40}$"#, "release_commit")
        let repository = try requirePattern(release["repository"], #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, "release_repository")
        guard version == expectedVersion, tag == "v\(version)" else {
            throw UpdateError.compatibilityManifestVersionMismatch(expected: expectedVersion, actual: version)
        }
        let compatibilitySetID = try requireTrimmedString(signed["compatibility_set_id"], "compatibility_set_id")
        guard compatibilitySetID == "\(repository):\(tag)@\(commit)",
              isCanonicalCompatibilitySetID(compatibilitySetID) else {
            throw UpdateError.compatibilityManifestInvalid("compatibility_set_id")
        }

        guard let binding = signed["artifact_binding"] as? [String: Any] else {
            throw UpdateError.compatibilityManifestInvalid("artifact_binding")
        }
        try requireExactKeys(binding, ["embedded_container_hashes", "mode"], "artifact_binding")
        try requireString(binding["mode"], equals: "signed_release_checksums", "artifact_binding_mode")
        try requireString(binding["embedded_container_hashes"], equals: "excluded_to_avoid_self_reference", "artifact_binding_hashes")

        guard let components = signed["components"] as? [String: Any] else {
            throw UpdateError.compatibilityManifestInvalid("components")
        }
        try requireExactKeys(
            components,
            ["catalog", "coordinator_admission", "launchd", "malibu_app", "provider_cli", "updater_rollback", "watchdog"],
            "components"
        )
        let catalog = try validateCatalog(components["catalog"], payloadDirectory: payloadDirectory)
        try validateMalibu(components["malibu_app"], version: version)
        try validateCLI(components["provider_cli"], version: version)
        try validateLaunchd(components["launchd"], payloadDirectory: payloadDirectory)
        try validateWatchdog(components["watchdog"], payloadDirectory: payloadDirectory)
        try validateAdmission(components["coordinator_admission"], version: version)
        try validateUpdater(components["updater_rollback"], payloadDirectory: payloadDirectory)
        try validateLocalArtifactDirectory(payloadDirectory)

        let transaction = try validateTransaction(signed["transaction"])
        return CompatibilitySetManifest(
            compatibilitySetID: compatibilitySetID,
            envelopeSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            version: version,
            catalogReleaseID: catalog.releaseID,
            catalogPolicyVersion: catalog.policyVersion,
            maintenanceLeaseSeconds: transaction.leaseSeconds,
            readinessTimeoutSeconds: transaction.readinessSeconds
        )
    }

    static func loadInstalled(executableURL: URL?, expectedVersion: String) -> CompatibilitySetManifest? {
        guard let executableURL else { return nil }
        return try? loadValidated(
            from: executableURL.deletingLastPathComponent(),
            expectedVersion: expectedVersion
        )
    }

    private static func validateCatalog(
        _ raw: Any?,
        payloadDirectory: URL
    ) throws -> (releaseID: String, policyVersion: String) {
        guard let value = raw as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("catalog") }
        try requireExactKeys(value, ["activation", "files", "policy_version", "release_id", "schema_version"], "catalog")
        try requireString(value["activation"], equals: "local", "catalog_activation")
        try requireString(value["schema_version"], equals: "macprovider.autotune-release.v1", "catalog_schema")
        let releaseID = try requireTrimmedString(value["release_id"], "catalog_release_id")
        let policyVersion = try requireTrimmedString(value["policy_version"], "catalog_policy_version")
        guard let files = value["files"] as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("catalog_files") }
        let names = [
            "autotune-candidates.json", "autotune-candidates.json.sig", "demand-rank.json",
            "demand-rank.json.sig", "release.json", "trusted-keys.json",
        ]
        try requireExactKeys(files, Set(names), "catalog_files")
        let directory = payloadDirectory.appendingPathComponent("catalog-release", isDirectory: true)
        for name in names {
            let expected = try requirePattern(files[name], #"^[0-9a-f]{64}$"#, "catalog_digest")
            let bytes = try readTrustedRegularFile(directory.appendingPathComponent(name))
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError.compatibilityManifestInvalid("catalog_digest_mismatch") }
        }
        return (releaseID, policyVersion)
    }

    private static func validateMalibu(_ raw: Any?, version: String) throws {
        guard let value = raw as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("malibu") }
        try requireExactKeys(value, ["activation", "bundle_id", "compatibility_handoff", "minimum_status_reader", "version"], "malibu")
        try requireString(value["activation"], equals: "cli_owned_if_installed", "malibu_activation")
        try requireString(value["bundle_id"], equals: "tech.malibu.app", "malibu_bundle")
        try requireString(value["version"], equals: version, "malibu_version")
        try requireInteger(value["minimum_status_reader"], in: 1...1, "minimum_status_reader")
        guard let handoff = value["compatibility_handoff"] as? [String: Any] else {
            throw UpdateError.compatibilityManifestInvalid("malibu_handoff")
        }
        try requireExactKeys(handoff, ["delivery", "embedded_manifest_path", "provider_mutation", "reader_compatibility"], "malibu_handoff")
        try requireString(handoff["delivery"], equals: "signed_dmg_transaction_member", "malibu_delivery")
        try requireString(
            handoff["embedded_manifest_path"],
            equals: "Contents/Resources/compatibility-set.json",
            "malibu_manifest_path"
        )
        try requireString(handoff["provider_mutation"], equals: "forbidden", "malibu_provider_mutation")
        try requireString(handoff["reader_compatibility"], equals: "backward_compatible", "malibu_reader_compatibility")
    }

    private static func validateCLI(_ raw: Any?, version: String) throws {
        guard let value = raw as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("provider_cli") }
        try requireExactKeys(value, ["activation", "designated_identifier", "platform", "status_contract", "version"], "provider_cli")
        try requireString(value["activation"], equals: "local", "cli_activation")
        try requireString(value["designated_identifier"], equals: "live.streamvc.macprovider.cli", "cli_identifier")
        try requireString(value["platform"], equals: "darwin-arm64", "cli_platform")
        try requireString(value["status_contract"], equals: "macprovider.local-status.v1", "cli_status_contract")
        try requireString(value["version"], equals: version, "cli_version")
    }

    private static func validateLaunchd(_ raw: Any?, payloadDirectory: URL) throws {
        guard let value = raw as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("launchd") }
        try requireExactKeys(value, ["activation", "contract", "install_contract", "label", "plist_template"], "launchd")
        try requireString(value["activation"], equals: "local", "launchd_activation")
        try requireString(value["contract"], equals: "macprovider.launch-agent.v1", "launchd_contract")
        try requireString(value["label"], equals: "live.streamvc.macprovider", "launchd_label")
        try validateArtifact(
            value["install_contract"],
            expectedPath: "compatibility-set-local/install.sh",
            payloadDirectory: payloadDirectory,
            label: "launchd_install_contract"
        )
        try validateArtifact(
            value["plist_template"],
            expectedPath: "compatibility-set-local/provider-launch-agent.plist.template",
            payloadDirectory: payloadDirectory,
            label: "launchd_plist_template"
        )
    }

    private static func validateWatchdog(_ raw: Any?, payloadDirectory: URL) throws {
        guard let value = raw as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("watchdog") }
        try requireExactKeys(value, ["activation", "contract", "monitored_label", "plist_template", "script", "service_label"], "watchdog")
        try requireString(value["activation"], equals: "local", "watchdog_activation")
        try requireString(value["contract"], equals: "macprovider.exact-service-pid-watchdog.v1", "watchdog_contract")
        try requireString(value["monitored_label"], equals: "live.streamvc.macprovider", "watchdog_monitored_label")
        try requireString(value["service_label"], equals: "live.streamvc.macprovider-watchdog", "watchdog_service_label")
        try validateArtifact(
            value["script"],
            expectedPath: "compatibility-set-local/watchdog.sh",
            payloadDirectory: payloadDirectory,
            label: "watchdog_script"
        )
        try validateArtifact(
            value["plist_template"],
            expectedPath: "compatibility-set-local/watchdog-launch-agent.plist.template",
            payloadDirectory: payloadDirectory,
            label: "watchdog_plist_template"
        )
    }

    private static func validateAdmission(_ raw: Any?, version: String) throws {
        guard let value = raw as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("admission") }
        try requireExactKeys(value, ["activation", "handshake", "policy_version", "rollout", "scope", "version"], "admission")
        try requireString(value["activation"], equals: "required_remote_gate", "admission_activation")
        try requireString(value["handshake"], equals: "accepted_set_echo_v1", "admission_handshake")
        try requireString(value["scope"], equals: "remote_coordinator_policy", "admission_scope")
        try requireString(value["policy_version"], equals: "provider-admission.v1", "admission_policy")
        try requireString(value["version"], equals: version, "admission_version")
        guard let rollout = value["rollout"] as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("admission_rollout") }
        try requireExactKeys(rollout, ["bridge_duration_seconds", "enforce_provider_admission", "mode"], "admission_rollout")
        let mode = try requireTrimmedString(rollout["mode"], "admission_mode")
        let enforce = rollout["enforce_provider_admission"] as? Bool
        let duration = try requireInteger(rollout["bridge_duration_seconds"], in: 0...86_400, "admission_bridge_duration")
        guard (mode == "bridge_required" && enforce == false && duration == 86_400)
                || (mode == "strict_post_migration" && enforce == true && duration == 0)
        else { throw UpdateError.compatibilityManifestInvalid("admission_rollout") }
    }

    private static func validateUpdater(_ raw: Any?, payloadDirectory: URL) throws {
        guard let value = raw as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("updater") }
        try requireExactKeys(value, ["activation", "metadata", "metadata_version", "protocol"], "updater")
        try requireString(value["activation"], equals: "local", "updater_activation")
        try requireInteger(value["metadata_version"], in: 1...1, "updater_metadata")
        try requireString(value["protocol"], equals: "macprovider.compatibility-set-transaction.v1", "updater_protocol")
        try validateArtifact(
            value["metadata"],
            expectedPath: "compatibility-set-local/updater-rollback.json",
            payloadDirectory: payloadDirectory,
            label: "updater_metadata_artifact"
        )
        _ = try CompatibilitySetRollbackPlan.loadValidated(
            from: payloadDirectory.appendingPathComponent(
                "compatibility-set-local/updater-rollback.json"
            )
        )
    }

    private static func validateTransaction(_ raw: Any?) throws -> (leaseSeconds: Int, readinessSeconds: Int) {
        guard let value = raw as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("transaction") }
        try requireExactKeys(value, ["activation", "autoupdate_scope", "maintenance_lease", "membership", "preflight", "readiness_proof", "rollback"], "transaction")
        try requireString(value["activation"], equals: "crash_recoverable_local_activation_group", "activation")
        try requireString(value["autoupdate_scope"], equals: "compatibility_cohort", "autoupdate_scope")
        guard let membership = value["membership"] as? [String: Any] else {
            throw UpdateError.compatibilityManifestInvalid("membership")
        }
        try requireExactKeys(membership, ["local_activation_group", "preserved_state_invariants", "required_external_gates"], "membership")
        guard membership["local_activation_group"] as? [String] == localActivationMembers,
              membership["required_external_gates"] as? [String] == requiredExternalGates,
              membership["preserved_state_invariants"] as? [String] == preservedStateInvariants
        else { throw UpdateError.compatibilityManifestInvalid("membership_classification") }
        guard let lease = value["maintenance_lease"] as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("maintenance_lease") }
        try requireExactKeys(lease, ["maximum_seconds", "protocol"], "maintenance_lease")
        try requireString(lease["protocol"], equals: "macprovider.maintenance-lease.v1", "maintenance_protocol")
        let leaseSeconds = try requireInteger(lease["maximum_seconds"], in: 60...1_200, "maintenance_seconds")
        guard let preflight = value["preflight"] as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("preflight") }
        try requireExactKeys(preflight, ["mode", "remote_gate"], "preflight")
        try requireString(preflight["mode"], equals: "exact_target_set", "preflight_mode")
        try requireString(preflight["remote_gate"], equals: "coordinator_acceptance_required", "preflight_remote_gate")
        guard let proof = value["readiness_proof"] as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("readiness") }
        try requireExactKeys(proof, ["compatibility_set_echo", "contract", "network_state", "timeout_seconds"], "readiness")
        try requireString(proof["compatibility_set_echo"], equals: "exact", "readiness_set_echo")
        try requireString(proof["contract"], equals: "macprovider.local-status.v1", "readiness_contract")
        try requireString(proof["network_state"], equals: "buyer_serving", "readiness_network")
        let readinessSeconds = try requireInteger(proof["timeout_seconds"], in: 60...1_200, "readiness_timeout")
        guard let rollback = value["rollback"] as? [String: Any] else { throw UpdateError.compatibilityManifestInvalid("rollback") }
        try requireExactKeys(rollback, ["members", "mode"], "rollback")
        try requireString(rollback["mode"], equals: "local_activation_group", "rollback_mode")
        guard rollback["members"] as? [String] == localActivationMembers else {
            throw UpdateError.compatibilityManifestInvalid("rollback_members")
        }
        return (leaseSeconds, readinessSeconds)
    }

    private static func validateArtifact(
        _ raw: Any?,
        expectedPath: String,
        payloadDirectory: URL,
        label: String
    ) throws {
        guard let value = raw as? [String: Any] else {
            throw UpdateError.compatibilityManifestInvalid(label)
        }
        try requireExactKeys(value, ["path", "sha256"], label)
        try requireString(value["path"], equals: expectedPath, "\(label)_path")
        let expected = try requirePattern(value["sha256"], #"^[0-9a-f]{64}$"#, "\(label)_sha256")
        let bytes = try readTrustedRegularFile(payloadDirectory.appendingPathComponent(expectedPath))
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw UpdateError.compatibilityManifestInvalid("\(label)_digest_mismatch")
        }
    }

    private static func validateLocalArtifactDirectory(_ payloadDirectory: URL) throws {
        let expected = Set([
            "install.sh",
            "provider-launch-agent.plist.template",
            "updater-rollback.json",
            "watchdog-launch-agent.plist.template",
            "watchdog.sh",
        ])
        let directory = payloadDirectory.appendingPathComponent(localArtifactDirectoryName, isDirectory: true)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw UpdateError.compatibilityManifestInvalid("local_artifact_directory")
        }
        guard Set(entries.map(\.lastPathComponent)) == expected else {
            throw UpdateError.compatibilityManifestInvalid("local_artifact_members")
        }
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw UpdateError.compatibilityManifestInvalid("local_artifact_type")
            }
        }
    }

    fileprivate static func readTrustedRegularFile(_ url: URL) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              info.st_size > 0,
              info.st_size <= maximumBytes
        else { throw UpdateError.compatibilityManifestInvalid("unsafe_file") }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw UpdateError.compatibilityManifestInvalid("open_failed") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == info.st_dev,
              opened.st_ino == info.st_ino
        else { throw UpdateError.compatibilityManifestInvalid("file_changed") }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw UpdateError.compatibilityManifestInvalid("read_failed") }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else {
                throw UpdateError.compatibilityManifestInvalid("file_too_large")
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func requireExactKeys(_ object: [String: Any], _ keys: Set<String>, _ label: String) throws {
        guard Set(object.keys) == keys else { throw UpdateError.compatibilityManifestInvalid("\(label)_fields") }
    }

    private static func requireString(_ raw: Any?, equals expected: String, _ label: String) throws {
        guard raw as? String == expected else { throw UpdateError.compatibilityManifestInvalid(label) }
    }

    @discardableResult
    private static func requireInteger(_ raw: Any?, in range: ClosedRange<Int>, _ label: String) throws -> Int {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              range.contains(number.intValue)
        else { throw UpdateError.compatibilityManifestInvalid(label) }
        return number.intValue
    }

    private static func requireTrimmedString(_ raw: Any?, _ label: String) throws -> String {
        guard let value = raw as? String,
              !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 512
        else { throw UpdateError.compatibilityManifestInvalid(label) }
        return value
    }

    private static func requirePattern(_ raw: Any?, _ pattern: String, _ label: String) throws -> String {
        let value = try requireTrimmedString(raw, label)
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw UpdateError.compatibilityManifestInvalid(label)
        }
        return value
    }
}
