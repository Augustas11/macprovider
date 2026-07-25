import CryptoKit
import Darwin
import Foundation

enum MalibuReleaseContractError: Error, LocalizedError, Equatable {
    case invalidJSON(String)
    case duplicateKey(String)
    case nonCanonical(String)
    case invalidFields(String)
    case invalidValue(String)
    case unknownKey(String)
    case revokedKey(String)
    case revokedKeyringGeneration(Int)
    case keyringRollback
    case invalidSignature
    case futureDated
    case expired
    case indexTTLExceeded
    case indexRollback
    case buildRollback
    case envelopeRollback
    case digestMismatch
    case insecureState(String)

    var errorDescription: String? {
        switch self {
        case let .invalidJSON(reason): return "Invalid Malibu release JSON: \(reason)."
        case let .duplicateKey(key): return "Malibu release JSON contains duplicate key \(key)."
        case let .nonCanonical(label): return "\(label) is not exact CanonicalJSON."
        case let .invalidFields(label): return "\(label) contains missing or unknown fields."
        case let .invalidValue(label): return "\(label) contains an invalid value."
        case let .unknownKey(key): return "Malibu release key \(key) is not pinned."
        case let .revokedKey(key): return "Malibu release key \(key) is revoked."
        case let .revokedKeyringGeneration(generation): return "Malibu keyring generation \(generation) is revoked."
        case .keyringRollback: return "Malibu keyring generation would roll back."
        case .invalidSignature: return "Malibu release signature is invalid."
        case .futureDated: return "Malibu release metadata is future-dated."
        case .expired: return "Malibu release metadata is expired."
        case .indexTTLExceeded: return "Malibu release index exceeds the seven-day TTL."
        case .indexRollback: return "Malibu release index generation would roll back."
        case .buildRollback: return "Malibu app build would roll back."
        case .envelopeRollback: return "Malibu release envelope generation would roll back."
        case .digestMismatch: return "Malibu release envelope digest does not match the signed index."
        case let .insecureState(reason): return "Malibu release anti-replay state is insecure: \(reason)."
        }
    }
}

struct MalibuReleaseTrustPolicy {
    struct TrustedKey {
        let keyID: String
        let publicKey: P256.Signing.PublicKey
        let spkiSHA256: String
        let status: String
    }

    static let initialKeyID = "macprovider-release-p256-v1"
    static let initialSPKISHA256 = "2cd6171cea8cd7964c12292e3443078c2b3d0cdcc20ae600fe8261090392c7f8"

    let generation: Int
    let keyringSHA256: String
    let revocationsGeneration: Int
    let revocationsSHA256: String
    let keys: [String: TrustedKey]
    let revokedKeyIDs: Set<String>
    let revokedKeyringGenerations: Set<Int>

    static func parse(
        keyringData: Data,
        revocationsData: Data,
        minimumGeneration: Int,
        publicKeyLoader: (String) throws -> Data
    ) throws -> MalibuReleaseTrustPolicy {
        let keyring = try MalibuReleaseStrictJSON.parseCanonicalObject(
            keyringData,
            label: "Malibu release keyring",
            allowFinalNewline: true
        )
        try exactKeys(keyring, ["generation", "keys", "schema_version"], "Malibu release keyring")
        guard try string(keyring["schema_version"], "keyring schema") == "malibu-release-keyring.v1" else {
            throw MalibuReleaseContractError.invalidValue("keyring schema")
        }
        let generation = try positiveInt(keyring["generation"], "keyring generation")
        guard generation >= minimumGeneration else { throw MalibuReleaseContractError.keyringRollback }

        let revocations = try MalibuReleaseStrictJSON.parseCanonicalObject(
            revocationsData,
            label: "Malibu release revocations",
            allowFinalNewline: true
        )
        try exactKeys(
            revocations,
            ["generation", "issued_at", "keyring_generation", "revoked_key_ids", "revoked_keyring_generations", "schema_version"],
            "Malibu release revocations"
        )
        guard try string(revocations["schema_version"], "revocations schema") == "malibu-release-revocations.v1",
              try positiveInt(revocations["keyring_generation"], "revocations keyring generation") == generation
        else { throw MalibuReleaseContractError.invalidValue("revocations keyring binding") }
        let revocationsGeneration = try positiveInt(revocations["generation"], "revocations generation")
        _ = try timestamp(revocations["issued_at"], "revocations issued_at")
        let revokedIDs = Set(try stringArray(revocations["revoked_key_ids"], "revoked key IDs", allowEmpty: true))
        let revokedGenerations = Set(try intArray(revocations["revoked_keyring_generations"], "revoked keyring generations"))
        if revokedGenerations.contains(generation) {
            throw MalibuReleaseContractError.revokedKeyringGeneration(generation)
        }

        let rows = try objectArray(keyring["keys"], "keyring keys")
        guard !rows.isEmpty else { throw MalibuReleaseContractError.invalidValue("keyring keys") }
        var trusted: [String: TrustedKey] = [:]
        for row in rows {
            try exactKeys(row, ["algorithm", "key_id", "public_key_path", "public_key_spki_sha256", "status"], "Malibu release key")
            guard try string(row["algorithm"], "key algorithm") == "ecdsa-p256-sha256" else {
                throw MalibuReleaseContractError.invalidValue("key algorithm")
            }
            let keyID = try string(row["key_id"], "key ID")
            guard !keyID.isEmpty, trusted[keyID] == nil else {
                throw MalibuReleaseContractError.invalidValue("key ID")
            }
            let status = try string(row["status"], "key status")
            guard status == "active" || status == "retiring" else {
                throw MalibuReleaseContractError.invalidValue("key status")
            }
            let expectedDigest = try hexDigest(row["public_key_spki_sha256"], "key SPKI digest")
            let pem = try publicKeyLoader(try string(row["public_key_path"], "public key path"))
            guard let pemString = String(data: pem, encoding: .utf8),
                  let publicKey = try? P256.Signing.PublicKey(pemRepresentation: pemString)
            else { throw MalibuReleaseContractError.invalidValue("P-256 public key") }
            let actualDigest = SHA256.hash(data: publicKey.derRepresentation).hexString
            guard actualDigest == expectedDigest else { throw MalibuReleaseContractError.digestMismatch }
            if keyID == initialKeyID, expectedDigest != initialSPKISHA256 {
                throw MalibuReleaseContractError.digestMismatch
            }
            trusted[keyID] = TrustedKey(keyID: keyID, publicKey: publicKey, spkiSHA256: expectedDigest, status: status)
        }
        return MalibuReleaseTrustPolicy(
            generation: generation,
            keyringSHA256: SHA256.hash(data: keyringData).hexString,
            revocationsGeneration: revocationsGeneration,
            revocationsSHA256: SHA256.hash(data: revocationsData).hexString,
            keys: trusted,
            revokedKeyIDs: revokedIDs,
            revokedKeyringGenerations: revokedGenerations
        )
    }
}

struct MalibuReleaseAntiReplayState: Codable, Equatable {
    let schemaVersion: String
    let highestIndexGeneration: Int
    let highestBuild: Int
    let highestEnvelopeGeneration: Int
    let envelopeSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case highestIndexGeneration = "highest_index_generation"
        case highestBuild = "highest_build"
        case highestEnvelopeGeneration = "highest_envelope_generation"
        case envelopeSHA256 = "envelope_sha256"
    }

    static let empty = MalibuReleaseAntiReplayState(
        schemaVersion: "malibu-release-anti-replay.v1",
        highestIndexGeneration: 0,
        highestBuild: 0,
        highestEnvelopeGeneration: 0,
        envelopeSHA256: String(repeating: "0", count: 64)
    )
}

struct MalibuReleaseEnvelopeIdentity: Equatable {
    let marketingVersion: String
    let build: Int
    let entryCount: Int
    let rootMode: Int
    let treeSHA256: String
    let generation: Int
    let compatibilitySetID: String
    let compatibilityManifestSHA256: String
    let providerCLIVersion: String
    let providerCLISHA256: String
    let legacyBootstrap: MalibuLegacyBootstrapPolicy
    let digest: String
}

struct MalibuLegacyBootstrapPolicy: Equatable {
    struct Cohort: Equatable, Hashable {
        let appVersion: String
        let cliVersion: String
        let appBuild: Int
        let appEntryCount: Int
        let appRootMode: Int
        let appTreeSHA256: String
    }

    let expiresAt: Date
    let allowedSourceCohorts: Set<Cohort>

    func authorizes(appVersion: String?, cliVersion: String?, now: Date) -> Bool {
        guard now < expiresAt,
              let appVersion,
              let cliVersion,
              let normalizedApp = ProviderCLIVersion.strictNormalize(appVersion),
              let normalizedCLI = ProviderCLIVersion.strictNormalize(cliVersion) else {
            return false
        }
        return allowedSourceCohorts.contains(
            Cohort(appVersion: normalizedApp, cliVersion: normalizedCLI)
        )
    }
}

enum MalibuReleaseValidationUse {
    case discovery
    case installedTransaction
}

enum MalibuReleaseEnvelopeValidator {
    static let envelopeContext = Data("malibu.release-envelope.v1".utf8) + Data([0])
    static let indexContext = Data("malibu.release-index.v1".utf8) + Data([0])
    static let maximumFutureSkew: TimeInterval = 300
    static let maximumIndexTTL: TimeInterval = 7 * 24 * 60 * 60
    static let compatibilitySetID = "Augustas11/macprovider:v1.8.40@18638472fe3e885f3534eeac29ab89b4c7ffdd7a"
    static let compatibilityManifestSHA256 = "fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c"

    static func validateEnvelope(
        _ data: Data,
        trust: MalibuReleaseTrustPolicy,
        now: Date,
        state: MalibuReleaseAntiReplayState,
        use: MalibuReleaseValidationUse = .discovery
    ) throws -> MalibuReleaseEnvelopeIdentity {
        let document = try MalibuReleaseStrictJSON.parseCanonicalObject(data, label: "Malibu release envelope")
        try exactKeys(document, ["schema_version", "signature", "signed"], "Malibu release envelope")
        guard try string(document["schema_version"], "envelope schema") == "malibu-release-envelope.v1" else {
            throw MalibuReleaseContractError.invalidValue("envelope schema")
        }
        let signed = try object(document["signed"], "envelope signed payload")
        try verifySignature(document["signature"], signed: signed, context: envelopeContext, trust: trust)
        try exactKeys(signed, ["app", "artifacts", "envelope_generation", "legacy_bootstrap", "publication", "runtime_posture", "supported_provider"], "envelope signed payload")

        let app = try object(signed["app"], "envelope app")
        try exactKeys(app, ["build", "bundle_id", "designated_requirement", "entry_count", "marketing_version", "release_tag", "root_mode", "source_commit", "team_id", "tree_sha256"], "envelope app")
        let version = try semver(app["marketing_version"], "app marketing version")
        let build = try positiveInt(app["build"], "app build")
        let entryCount = try positiveInt(app["entry_count"], "app entry count")
        let rootMode = try positiveInt(app["root_mode"], "app root mode")
        guard rootMode <= 0o7777 else { throw MalibuReleaseContractError.invalidValue("app root mode") }
        let treeSHA256 = try hexDigest(app["tree_sha256"], "app tree digest")
        guard try string(app["release_tag"], "app tag") == "malibu-v\(version)",
              try string(app["bundle_id"], "app bundle ID") == "tech.malibu.app",
              try string(app["team_id"], "app Team ID") == "YF7XNRJUG4",
              try string(app["source_commit"], "source commit").isHex(count: 40)
        else { throw MalibuReleaseContractError.invalidValue("app identity") }
        let requirement = try string(app["designated_requirement"], "app designated requirement")
        guard requirement.contains("tech.malibu.app"), requirement.contains("YF7XNRJUG4") else {
            throw MalibuReleaseContractError.invalidValue("app designated requirement")
        }
        let generation = try positiveInt(signed["envelope_generation"], "envelope generation")
        guard build >= state.highestBuild else { throw MalibuReleaseContractError.buildRollback }
        guard generation >= state.highestEnvelopeGeneration else { throw MalibuReleaseContractError.envelopeRollback }

        let artifacts = try object(signed["artifacts"], "envelope artifacts")
        try exactKeys(artifacts, ["bundled_provider_cli", "dmg"], "envelope artifacts")
        try validateArtifact(artifacts["dmg"], expectedName: "Malibu-v\(version).dmg", label: "Malibu DMG")
        let bundledCLI = try object(artifacts["bundled_provider_cli"], "bundled provider CLI")
        try exactKeys(bundledCLI, ["sha256", "version"], "bundled provider CLI")
        let providerCLIVersion = try string(bundledCLI["version"], "bundled CLI version")
        guard providerCLIVersion == "1.8.40" else {
            throw MalibuReleaseContractError.invalidValue("bundled CLI version")
        }
        let providerCLISHA256 = try hexDigest(bundledCLI["sha256"], "bundled CLI digest")

        let publication = try object(signed["publication"], "envelope publication")
        try exactKeys(publication, ["published_at"], "envelope publication")
        if try timestamp(publication["published_at"], "published_at").timeIntervalSince(now) > maximumFutureSkew {
            throw MalibuReleaseContractError.futureDated
        }
        let posture = try object(signed["runtime_posture"], "runtime posture")
        try exactKeys(posture, ["hardened_runtime", "notarized", "stapled"], "runtime posture")
        for key in ["hardened_runtime", "notarized", "stapled"] where try boolean(posture[key], key) != true {
            throw MalibuReleaseContractError.invalidValue("runtime posture")
        }

        let supported = try object(signed["supported_provider"], "supported provider")
        try exactKeys(supported, ["capabilities", "compatibility_sets", "provider_mutation"], "supported provider")
        guard try string(supported["provider_mutation"], "provider mutation") == "forbidden" else {
            throw MalibuReleaseContractError.invalidValue("provider mutation")
        }
        let capabilities = try object(supported["capabilities"], "provider capabilities")
        try exactKeys(capabilities, ["admission_recovery", "control_socket", "credential_handoff", "local_status_reader"], "provider capabilities")
        for key in capabilities.keys {
            let values = try stringArray(capabilities[key], "capability \(key)")
            guard !values.isEmpty, Set(values).count == values.count,
                  values.allSatisfy({ $0.range(of: "^v[1-9][0-9]*$", options: .regularExpression) != nil })
            else { throw MalibuReleaseContractError.invalidValue("capability \(key)") }
        }
        let sets = try objectArray(supported["compatibility_sets"], "compatibility sets")
        guard sets.count == 1 else { throw MalibuReleaseContractError.invalidValue("compatibility sets") }
        let set = sets[0]
        try exactKeys(set, ["id", "manifest_sha256", "provider_cli"], "compatibility set")
        guard try string(set["id"], "compatibility set ID") == compatibilitySetID,
              try hexDigest(set["manifest_sha256"], "manifest digest") == compatibilityManifestSHA256
        else { throw MalibuReleaseContractError.invalidValue("compatibility set identity") }
        let cli = try object(set["provider_cli"], "provider CLI identity")
        try exactKeys(cli, ["designated_identifier", "team_id", "version"], "provider CLI identity")
        guard try string(cli["version"], "provider CLI version") == "1.8.40",
              try string(cli["team_id"], "provider CLI Team ID") == "YF7XNRJUG4",
              try string(cli["designated_identifier"], "provider CLI identifier") == "live.streamvc.macprovider.cli"
        else { throw MalibuReleaseContractError.invalidValue("provider CLI identity") }

        let bootstrap = try object(signed["legacy_bootstrap"], "legacy bootstrap")
        try exactKeys(bootstrap, ["allowed_source_cohorts", "backend_handoff_required", "caller_selected_target", "expires_at", "no_downgrade", "target_cli_version", "target_manifest_sha256"], "legacy bootstrap")
        guard try boolean(bootstrap["backend_handoff_required"], "backend handoff"),
              !(try boolean(bootstrap["caller_selected_target"], "caller-selected target")),
              try boolean(bootstrap["no_downgrade"], "no downgrade"),
              try string(bootstrap["target_cli_version"], "bootstrap target") == "1.8.40",
              try hexDigest(bootstrap["target_manifest_sha256"], "bootstrap manifest") == compatibilityManifestSHA256
        else { throw MalibuReleaseContractError.invalidValue("legacy bootstrap policy") }
        let bootstrapExpiry = try timestamp(bootstrap["expires_at"], "bootstrap expiry")
        guard use == .installedTransaction || bootstrapExpiry > now else {
            throw MalibuReleaseContractError.expired
        }
        let rawCohorts = try objectArray(bootstrap["allowed_source_cohorts"], "legacy cohorts")
        guard !rawCohorts.isEmpty else { throw MalibuReleaseContractError.invalidValue("legacy cohorts") }
        var cohorts = Set<MalibuLegacyBootstrapPolicy.Cohort>()
        for cohort in rawCohorts {
            try exactKeys(
                cohort,
                [
                    "app_build", "app_entry_count", "app_root_mode", "app_tree_sha256",
                    "app_version", "cli_version",
                ],
                "legacy cohort"
            )
            let value = MalibuLegacyBootstrapPolicy.Cohort(
                appVersion: try semver(cohort["app_version"], "cohort app"),
                cliVersion: try semver(cohort["cli_version"], "cohort CLI"),
                appBuild: try positiveInt(cohort["app_build"], "cohort app build"),
                appEntryCount: try positiveInt(cohort["app_entry_count"], "cohort app entry count"),
                appRootMode: try positiveInt(cohort["app_root_mode"], "cohort app root mode"),
                appTreeSHA256: try hexDigest(cohort["app_tree_sha256"], "cohort app tree")
            )
            guard value.appRootMode <= 0o7777 else {
                throw MalibuReleaseContractError.invalidValue("legacy cohort app root mode")
            }
            guard cohorts.insert(value).inserted else {
                throw MalibuReleaseContractError.invalidValue("legacy cohorts")
            }
        }

        let digest = SHA256.hash(data: data).hexString
        if generation == state.highestEnvelopeGeneration,
           state.highestEnvelopeGeneration > 0,
           state.envelopeSHA256 != digest {
            throw MalibuReleaseContractError.envelopeRollback
        }
        return MalibuReleaseEnvelopeIdentity(
            marketingVersion: version,
            build: build,
            entryCount: entryCount,
            rootMode: rootMode,
            treeSHA256: treeSHA256,
            generation: generation,
            compatibilitySetID: compatibilitySetID,
            compatibilityManifestSHA256: compatibilityManifestSHA256,
            providerCLIVersion: providerCLIVersion,
            providerCLISHA256: providerCLISHA256,
            legacyBootstrap: MalibuLegacyBootstrapPolicy(
                expiresAt: bootstrapExpiry,
                allowedSourceCohorts: cohorts
            ),
            digest: digest
        )
    }

    static func validateIndex(
        _ data: Data,
        envelopeData: Data,
        trust: MalibuReleaseTrustPolicy,
        now: Date,
        state: MalibuReleaseAntiReplayState,
        expectedChannel: String = "stable",
        use: MalibuReleaseValidationUse = .discovery
    ) throws -> MalibuReleaseAntiReplayState {
        let envelope = try validateEnvelope(
            envelopeData,
            trust: trust,
            now: now,
            state: state,
            use: use
        )
        let document = try MalibuReleaseStrictJSON.parseCanonicalObject(data, label: "Malibu release index")
        try exactKeys(document, ["schema_version", "signature", "signed"], "Malibu release index")
        guard try string(document["schema_version"], "index schema") == "malibu-release-index.v1" else {
            throw MalibuReleaseContractError.invalidValue("index schema")
        }
        let signed = try object(document["signed"], "index signed payload")
        try verifySignature(document["signature"], signed: signed, context: indexContext, trust: trust)
        try exactKeys(signed, ["channel", "envelope", "expires_at", "index_generation", "issued_at", "minimum_accepted_envelope_generation", "trust"], "index signed payload")
        guard try string(signed["channel"], "index channel") == expectedChannel else {
            throw MalibuReleaseContractError.invalidValue("index channel")
        }
        let indexGeneration = try positiveInt(signed["index_generation"], "index generation")
        guard indexGeneration >= state.highestIndexGeneration else { throw MalibuReleaseContractError.indexRollback }
        let issuedAt = try timestamp(signed["issued_at"], "index issued_at")
        let expiresAt = try timestamp(signed["expires_at"], "index expires_at")
        guard issuedAt.timeIntervalSince(now) <= maximumFutureSkew else { throw MalibuReleaseContractError.futureDated }
        guard use == .installedTransaction || expiresAt > now else {
            throw MalibuReleaseContractError.expired
        }
        let ttl = expiresAt.timeIntervalSince(issuedAt)
        guard ttl > 0, ttl <= maximumIndexTTL else { throw MalibuReleaseContractError.indexTTLExceeded }
        let minimumEnvelope = try positiveInt(signed["minimum_accepted_envelope_generation"], "minimum envelope generation")
        guard minimumEnvelope >= state.highestEnvelopeGeneration else { throw MalibuReleaseContractError.envelopeRollback }
        let indexed = try object(signed["envelope"], "indexed envelope")
        try exactKeys(indexed, ["build", "generation", "name", "sha256"], "indexed envelope")
        let indexedBuild = try positiveInt(indexed["build"], "indexed build")
        let indexedGeneration = try positiveInt(indexed["generation"], "indexed generation")
        guard indexedBuild == envelope.build, indexedBuild >= state.highestBuild else {
            throw MalibuReleaseContractError.buildRollback
        }
        guard indexedGeneration == envelope.generation,
              indexedGeneration >= minimumEnvelope,
              indexedGeneration >= state.highestEnvelopeGeneration
        else { throw MalibuReleaseContractError.envelopeRollback }
        guard try hexDigest(indexed["sha256"], "indexed envelope digest") == envelope.digest else {
            throw MalibuReleaseContractError.digestMismatch
        }
        _ = try string(indexed["name"], "indexed envelope name")
        let signedTrust = try object(signed["trust"], "index trust binding")
        try exactKeys(signedTrust, ["keyring_generation", "keyring_sha256", "revocations_generation", "revocations_sha256"], "index trust binding")
        guard try positiveInt(signedTrust["keyring_generation"], "index keyring generation") == trust.generation,
              try hexDigest(signedTrust["keyring_sha256"], "index keyring digest") == trust.keyringSHA256,
              try positiveInt(signedTrust["revocations_generation"], "index revocations generation") == trust.revocationsGeneration,
              try hexDigest(signedTrust["revocations_sha256"], "index revocations digest") == trust.revocationsSHA256
        else { throw MalibuReleaseContractError.digestMismatch }
        if indexGeneration == state.highestIndexGeneration,
           state.highestIndexGeneration > 0,
           state.envelopeSHA256 != envelope.digest {
            throw MalibuReleaseContractError.indexRollback
        }
        return MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: indexGeneration,
            highestBuild: indexedBuild,
            highestEnvelopeGeneration: indexedGeneration,
            envelopeSHA256: envelope.digest
        )
    }

    private static func verifySignature(
        _ rawSignature: Any?,
        signed: [String: Any],
        context: Data,
        trust: MalibuReleaseTrustPolicy
    ) throws {
        let signature = try object(rawSignature, "signature")
        try exactKeys(signature, ["algorithm", "key_id", "signature"], "signature")
        guard try string(signature["algorithm"], "signature algorithm") == "ecdsa-p256-sha256" else {
            throw MalibuReleaseContractError.invalidValue("signature algorithm")
        }
        let keyID = try string(signature["key_id"], "signature key ID")
        if trust.revokedKeyIDs.contains(keyID) { throw MalibuReleaseContractError.revokedKey(keyID) }
        guard let trusted = trust.keys[keyID] else { throw MalibuReleaseContractError.unknownKey(keyID) }
        let encoded = try string(signature["signature"], "signature bytes")
        guard !encoded.isEmpty, !encoded.contains("="),
              let der = Data(base64URLEncoded: encoded),
              let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: der)
        else { throw MalibuReleaseContractError.invalidSignature }
        let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(signed))
        guard trusted.publicKey.isValidSignature(ecdsa, for: context + canonical) else {
            throw MalibuReleaseContractError.invalidSignature
        }
    }

    private static func validateArtifact(_ raw: Any?, expectedName: String, label: String) throws {
        let artifact = try object(raw, label)
        try exactKeys(artifact, ["name", "sha256"], label)
        guard try string(artifact["name"], "\(label) name") == expectedName else {
            throw MalibuReleaseContractError.invalidValue("\(label) name")
        }
        _ = try hexDigest(artifact["sha256"], "\(label) digest")
    }
}

enum MalibuReleaseAntiReplayStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Malibu", isDirectory: true)
            .appendingPathComponent("release-anti-replay-v1.json")
    }

    static func load(from url: URL, fileManager: FileManager = .default) throws -> MalibuReleaseAntiReplayState {
        guard fileManager.fileExists(atPath: url.path) else { return .empty }
        let metadata = try fileManager.attributesOfItem(atPath: url.path)
        guard metadata[.type] as? FileAttributeType == .typeRegular else {
            throw MalibuReleaseContractError.insecureState("not a regular file")
        }
        guard (metadata[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw MalibuReleaseContractError.insecureState("mode must be 0600")
        }
        guard (metadata[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
            throw MalibuReleaseContractError.insecureState("owner differs from current user")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let object = try MalibuReleaseStrictJSON.parseCanonicalObject(data, label: "Malibu release anti-replay state")
        try exactKeys(object, ["envelope_sha256", "highest_build", "highest_envelope_generation", "highest_index_generation", "schema_version"], "anti-replay state")
        guard try string(object["schema_version"], "anti-replay schema") == "malibu-release-anti-replay.v1" else {
            throw MalibuReleaseContractError.insecureState("unsupported schema")
        }
        return MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: try nonnegativeInt(object["highest_index_generation"], "highest index generation"),
            highestBuild: try nonnegativeInt(object["highest_build"], "highest build"),
            highestEnvelopeGeneration: try nonnegativeInt(object["highest_envelope_generation"], "highest envelope generation"),
            envelopeSHA256: try hexDigest(object["envelope_sha256"], "envelope digest")
        )
    }

    static func commit(
        _ state: MalibuReleaseAntiReplayState,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let value: [String: Any] = [
            "envelope_sha256": state.envelopeSHA256,
            "highest_build": state.highestBuild,
            "highest_envelope_generation": state.highestEnvelopeGeneration,
            "highest_index_generation": state.highestIndexGeneration,
            "schema_version": state.schemaVersion,
        ]
        let data = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(value))
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.lowercased())")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw MalibuReleaseContractError.insecureState("could not create temporary state")
        }
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private func exactKeys(_ object: [String: Any], _ expected: Set<String>, _ label: String) throws {
    guard Set(object.keys) == expected else { throw MalibuReleaseContractError.invalidFields(label) }
}

private func object(_ value: Any?, _ label: String) throws -> [String: Any] {
    guard let result = value as? [String: Any] else { throw MalibuReleaseContractError.invalidValue(label) }
    return result
}

private func objectArray(_ value: Any?, _ label: String) throws -> [[String: Any]] {
    guard let result = value as? [[String: Any]] else { throw MalibuReleaseContractError.invalidValue(label) }
    return result
}

private func string(_ value: Any?, _ label: String) throws -> String {
    guard let result = value as? String, !result.isEmpty else { throw MalibuReleaseContractError.invalidValue(label) }
    return result
}

private func semver(_ value: Any?, _ label: String) throws -> String {
    let result = try string(value, label)
    guard result.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else {
        throw MalibuReleaseContractError.invalidValue(label)
    }
    return result
}

private func positiveInt(_ value: Any?, _ label: String) throws -> Int {
    let result = try nonnegativeInt(value, label)
    guard result > 0 else { throw MalibuReleaseContractError.invalidValue(label) }
    return result
}

private func nonnegativeInt(_ value: Any?, _ label: String) throws -> Int {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue == Double(number.intValue),
          number.intValue >= 0
    else { throw MalibuReleaseContractError.invalidValue(label) }
    return number.intValue
}

private func boolean(_ value: Any?, _ label: String) throws -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw MalibuReleaseContractError.invalidValue(label)
    }
    return number.boolValue
}

private func stringArray(_ value: Any?, _ label: String, allowEmpty: Bool = false) throws -> [String] {
    guard let values = value as? [Any] else { throw MalibuReleaseContractError.invalidValue(label) }
    let result = try values.map { try string($0, label) }
    guard allowEmpty || !result.isEmpty else { throw MalibuReleaseContractError.invalidValue(label) }
    guard Set(result).count == result.count else { throw MalibuReleaseContractError.invalidValue(label) }
    return result
}

private func intArray(_ value: Any?, _ label: String) throws -> [Int] {
    guard let values = value as? [Any] else { throw MalibuReleaseContractError.invalidValue(label) }
    let result = try values.map { try positiveInt($0, label) }
    guard Set(result).count == result.count else { throw MalibuReleaseContractError.invalidValue(label) }
    return result
}

private func hexDigest(_ value: Any?, _ label: String) throws -> String {
    let result = try string(value, label)
    guard result.isHex(count: 64) else { throw MalibuReleaseContractError.invalidValue(label) }
    return result
}

private func timestamp(_ value: Any?, _ label: String) throws -> Date {
    let result = try string(value, label)
    guard result.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", options: .regularExpression) != nil else {
        throw MalibuReleaseContractError.invalidValue(label)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    guard let date = formatter.date(from: result) else { throw MalibuReleaseContractError.invalidValue(label) }
    return date
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    func isHex(count: Int) -> Bool {
        self.count == count && range(of: "^[0-9a-f]{\(count)}$", options: .regularExpression) != nil
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
