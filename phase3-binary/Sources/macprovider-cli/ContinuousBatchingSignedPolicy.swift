import CryptoKit
import CoreFoundation
import Foundation
import MacProviderCore

struct ContinuousBatchingPolicyProvenance: Sendable, Equatable {
    let source: String
    let status: String
    let evidenceID: String
    let packageManifestSHA256: String
    let studioCampaignSHA256: String
    let providerCLIVersion: String
    let liveExecutableCDHash: String
}

struct ContinuousBatchingPolicyEntry: Sendable, Equatable {
    let tupleSHA256: String
    let modelKey: String
    let rollout: ContinuousBatchingMode
    let tuple: ContinuousBatchingAcceptedTuple
    let provenance: ContinuousBatchingPolicyProvenance
}

struct ContinuousBatchingPolicySelection: Sendable, Equatable {
    let releaseID: String
    let policyVersion: String
    let generatedAt: Date
    let expiresAt: Date
    let candidateCatalogSHA256: String
    let signerKeyID: String
    let source: String
    let entries: [ContinuousBatchingPolicyEntry]

    static let emptyOff = ContinuousBatchingPolicySelection(
        releaseID: "baked-empty-off",
        policyVersion: "",
        generatedAt: .distantPast,
        expiresAt: .distantFuture,
        candidateCatalogSHA256: "",
        signerKeyID: "",
        source: "baked_empty_off",
        entries: []
    )

    var acceptanceCoverage: ContinuousBatchingAcceptanceCoverage {
        ContinuousBatchingAcceptanceCoverage(acceptedTuples: entries.map(\.tuple))
    }
}

enum ContinuousBatchingPolicyLoadStatus: String, Sendable, Equatable {
    case liveVerified = "live_verified"
    case absentFallback = "absent_empty_off_fallback"
    case integrityFailureFallback = "integrity_failure_empty_off_fallback"
    case updateRequiredFallback = "update_required_empty_off_fallback"
}

struct ContinuousBatchingPolicyLoadResult: Sendable, Equatable {
    let selection: ContinuousBatchingPolicySelection
    let status: ContinuousBatchingPolicyLoadStatus
    let policySHA256: String?
    let signerKeyID: String?
}

enum ContinuousBatchingSignedPolicyError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case unknownField(String)
    case missingField(String)
    case wrongType(String)
    case invalidValue(String)
    case unsupported(String)
    case signatureInvalid(String)
    case catalogMismatch
    case rowMismatch(String)
    case expired
    case futureDated

    var description: String {
        switch self {
        case .invalidJSON(let reason): return "invalid JSON: \(reason)"
        case .unknownField(let field): return "unknown field: \(field)"
        case .missingField(let field): return "missing field: \(field)"
        case .wrongType(let field): return "wrong type: \(field)"
        case .invalidValue(let field): return "invalid value: \(field)"
        case .unsupported(let field): return "unsupported: \(field)"
        case .signatureInvalid(let reason): return "signature invalid: \(reason)"
        case .catalogMismatch: return "candidate catalog mismatch"
        case .rowMismatch(let field): return "catalog row mismatch: \(field)"
        case .expired: return "policy expired"
        case .futureDated: return "policy generated_at is in the future"
        }
    }
}

enum ContinuousBatchingSignedPolicy {
    static let schemaVersion = "macprovider.continuous-batching-policy.v1"
    static let maxPolicyBytes = 512 * 1024
    static let maxSignatureBytes = 16 * 1024
    static let tupleIdentitySchemaVersion = "macprovider.continuous-batching-policy-tuple.v1"
    private static let tupleIdentityDomain = "macprovider.continuous-batching-policy-tuple.v1\n"
    private static let maxClockSkew: TimeInterval = 10 * 60

    static func matchesRuntimeProvenance(
        _ entry: ContinuousBatchingPolicyEntry,
        providerCLIVersion: String = CoordinatorClient.binaryVersion,
        liveExecutableCDHash: String?
    ) -> Bool {
        entry.provenance.providerCLIVersion == providerCLIVersion
            && entry.provenance.liveExecutableCDHash == liveExecutableCDHash
    }

    struct TrustedKeyring: Sendable, Equatable {
        let publicKeysByKeyID: [String: String]
        let requiredKeyID: String

        init(
            publicKeysByKeyID: [String: String] = AutotuneStaticInputs.defaultTrustedPublicKeys,
            requiredKeyID: String = AutotuneStaticInputs.keyID
        ) {
            self.publicKeysByKeyID = publicKeysByKeyID
            self.requiredKeyID = requiredKeyID
        }
    }

    static func verify(
        policyData: Data,
        signatureData: Data,
        catalog: AutotuneStaticSelection<CandidateCatalog>,
        trustedKeyring: TrustedKeyring = TrustedKeyring(),
        now: Date = Date(),
        source: String = "coordinator"
    ) throws -> ContinuousBatchingPolicySelection {
        guard policyData.count <= maxPolicyBytes else {
            throw ContinuousBatchingSignedPolicyError.invalidValue("$.bytes")
        }
        guard signatureData.count <= maxSignatureBytes else {
            throw ContinuousBatchingSignedPolicyError.signatureInvalid("too_large")
        }
        try AutotuneStrictJSON.rejectDuplicateKeys(policyData)
        let signatureKeyID = try verifyDetachedSignature(
            payload: policyData,
            signatureData: signatureData,
            trustedKeyring: trustedKeyring
        )
        guard let root = try JSONSerialization.jsonObject(with: policyData) as? [String: Any] else {
            throw ContinuousBatchingSignedPolicyError.wrongType("$")
        }
        let parsed = try parseRoot(root, signatureKeyID: signatureKeyID)
        guard parsed.candidateCatalogSHA256 == AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalog.selectedBytes) else {
            throw ContinuousBatchingSignedPolicyError.catalogMismatch
        }
        guard parsed.releaseID == catalog.value.version else {
            throw ContinuousBatchingSignedPolicyError.rowMismatch("$.release_id")
        }
        guard parsed.policyVersion == catalog.value.policyVersion else {
            throw ContinuousBatchingSignedPolicyError.rowMismatch("$.policy_version")
        }
        guard parsed.generatedAt == catalog.value.generatedAt else {
            throw ContinuousBatchingSignedPolicyError.rowMismatch("$.generated_at")
        }
        guard let catalogSignerKeyID = catalog.signerKeyID,
              parsed.signerKeyID == catalogSignerKeyID else {
            throw ContinuousBatchingSignedPolicyError.signatureInvalid("catalog_signer_mismatch")
        }
        guard parsed.generatedAt <= now.addingTimeInterval(maxClockSkew) else {
            throw ContinuousBatchingSignedPolicyError.futureDated
        }
        guard now < parsed.expiresAt else {
            throw ContinuousBatchingSignedPolicyError.expired
        }
        try validateCatalogRows(parsed.entries, catalog: catalog.value)
        return ContinuousBatchingPolicySelection(
            releaseID: parsed.releaseID,
            policyVersion: parsed.policyVersion,
            generatedAt: parsed.generatedAt,
            expiresAt: parsed.expiresAt,
            candidateCatalogSHA256: parsed.candidateCatalogSHA256,
            signerKeyID: parsed.signerKeyID,
            source: source,
            entries: parsed.entries.filter { $0.rollout != .off }
        )
    }

    static func tupleSHA256(
        releaseID: String,
        policyVersion: String,
        generatedAt: String,
        expiresAt: String,
        candidateCatalogSHA256: String,
        signerKeyID: String,
        entry: [String: Any]
    ) throws -> String {
        var entryWithoutDigest = entry
        entryWithoutDigest.removeValue(forKey: "tuple_sha256")
        let identity = try CanonicalJSON.fromJSONLike([
            "schema_version": tupleIdentitySchemaVersion,
            "release_id": releaseID,
            "policy_version": policyVersion,
            "generated_at": generatedAt,
            "expires_at": expiresAt,
            "candidate_catalog_sha256": candidateCatalogSHA256,
            "signer_key_id": signerKeyID,
            "entry": entryWithoutDigest,
        ])
        let canonical = try CanonicalJSON.canonicalString(identity)
        return sha256Hex(Data((tupleIdentityDomain + canonical).utf8))
    }

    private struct Parsed {
        let releaseID: String
        let policyVersion: String
        let generatedAt: Date
        let generatedAtRaw: String
        let expiresAt: Date
        let expiresAtRaw: String
        let candidateCatalogSHA256: String
        let signerKeyID: String
        let entries: [ContinuousBatchingPolicyEntry]
    }

    private static func parseRoot(_ root: [String: Any], signatureKeyID: String) throws -> Parsed {
        try exactKeys(
            root,
            allowed: ["schema_version", "release_id", "policy_version", "generated_at", "expires_at", "candidate_catalog_sha256", "signer_key_id", "entries"],
            required: ["schema_version", "release_id", "policy_version", "generated_at", "expires_at", "candidate_catalog_sha256", "signer_key_id", "entries"],
            path: "$"
        )
        try requireString(root, "schema_version", path: "$", equals: schemaVersion)
        let releaseID = try requireASCIIString(root, "release_id", path: "$", range: 1...128)
        let policyVersion = try requireASCIIString(root, "policy_version", path: "$", range: 1...128)
        let generatedAtRaw = try requireRFC3339UTCSecondsString(root, "generated_at", path: "$")
        let expiresAtRaw = try requireRFC3339UTCSecondsString(root, "expires_at", path: "$")
        let generatedAt = try parseRFC3339UTCSeconds(generatedAtRaw, path: "$.generated_at")
        let expiresAt = try parseRFC3339UTCSeconds(expiresAtRaw, path: "$.expires_at")
        guard generatedAt < expiresAt else {
            throw ContinuousBatchingSignedPolicyError.invalidValue("$.expires_at")
        }
        let candidateCatalogSHA256 = try requireSHA256(root, "candidate_catalog_sha256", path: "$")
        let signerKeyID = try requireASCIIString(root, "signer_key_id", path: "$", range: 1...128)
        guard signerKeyID == signatureKeyID else {
            throw ContinuousBatchingSignedPolicyError.signatureInvalid("signer_key_id_mismatch")
        }
        guard let rawEntries = root["entries"] as? [Any], (0...10_000).contains(rawEntries.count) else {
            throw ContinuousBatchingSignedPolicyError.wrongType("$.entries")
        }
        let entries = try rawEntries.enumerated().map { index, rawEntry -> ContinuousBatchingPolicyEntry in
            guard let entry = rawEntry as? [String: Any] else {
                throw ContinuousBatchingSignedPolicyError.wrongType("$.entries[\(index)]")
            }
            return try parseEntry(
                entry,
                path: "$.entries[\(index)]",
                releaseID: releaseID,
                policyVersion: policyVersion,
                generatedAtRaw: generatedAtRaw,
                expiresAtRaw: expiresAtRaw,
                candidateCatalogSHA256: candidateCatalogSHA256,
                signerKeyID: signerKeyID
            )
        }
        guard Set(entries.map(\.tupleSHA256)).count == entries.count else {
            throw ContinuousBatchingSignedPolicyError.invalidValue("$.entries.tuple_sha256")
        }
        return Parsed(
            releaseID: releaseID,
            policyVersion: policyVersion,
            generatedAt: generatedAt,
            generatedAtRaw: generatedAtRaw,
            expiresAt: expiresAt,
            expiresAtRaw: expiresAtRaw,
            candidateCatalogSHA256: candidateCatalogSHA256,
            signerKeyID: signerKeyID,
            entries: entries
        )
    }

    private static func parseEntry(
        _ entry: [String: Any],
        path: String,
        releaseID: String,
        policyVersion: String,
        generatedAtRaw: String,
        expiresAtRaw: String,
        candidateCatalogSHA256: String,
        signerKeyID: String
    ) throws -> ContinuousBatchingPolicyEntry {
        try exactKeys(
            entry,
            allowed: [
                "tuple_sha256", "model_key", "model_id", "model_sha256", "tokenizer_sha256",
                "chat_template_sha256", "cache_class", "kv_dtype", "requires_moe", "hardware_class",
                "metallib_sha256", "kernel_identifier", "rollout", "cached_turns_accepted", "provenance",
            ],
            required: [
                "tuple_sha256", "model_key", "model_id", "model_sha256", "tokenizer_sha256",
                "chat_template_sha256", "cache_class", "kv_dtype", "requires_moe", "hardware_class",
                "metallib_sha256", "kernel_identifier", "rollout", "cached_turns_accepted", "provenance",
            ],
            path: path
        )
        let expectedTupleSHA256 = try tupleSHA256(
            releaseID: releaseID,
            policyVersion: policyVersion,
            generatedAt: generatedAtRaw,
            expiresAt: expiresAtRaw,
            candidateCatalogSHA256: candidateCatalogSHA256,
            signerKeyID: signerKeyID,
            entry: entry
        )
        let tupleSHA256 = try requireSHA256(entry, "tuple_sha256", path: path)
        guard tupleSHA256 == expectedTupleSHA256 else {
            throw ContinuousBatchingSignedPolicyError.invalidValue("\(path).tuple_sha256")
        }
        let rawRollout = try requireString(entry, "rollout", path: path, allowed: ["off", "canary", "on"])
        let kvDTypeRaw = try requireString(entry, "kv_dtype", path: path, allowed: ["fp16", "bf16"])
        let provenance = try parseProvenance(try requireObject(entry, "provenance", path: path), path: "\(path).provenance")
        return ContinuousBatchingPolicyEntry(
            tupleSHA256: tupleSHA256,
            modelKey: try requireShortString(entry, "model_key", path: path),
            rollout: ContinuousBatchingMode(rawValue: rawRollout)!,
            tuple: ContinuousBatchingAcceptedTuple(
                modelID: try requireShortString(entry, "model_id", path: path),
                modelSHA256: try requireSHA256(entry, "model_sha256", path: path),
                tokenizerSHA256: try requireSHA256(entry, "tokenizer_sha256", path: path),
                chatTemplateSHA256: try requireSHA256(entry, "chat_template_sha256", path: path),
                cacheClass: try requireString(entry, "cache_class", path: path, allowed: ["KVCacheSimple"]),
                kvDType: PagedKVDType(rawValue: kvDTypeRaw)!,
                requiresMoE: try requireBool(entry, "requires_moe", path: path),
                hardwareClass: try requireShortString(entry, "hardware_class", path: path),
                metallibSHA256: try requireSHA256(entry, "metallib_sha256", path: path),
                kernelIdentifier: try requireShortString(entry, "kernel_identifier", path: path),
                cachedTurnsAccepted: try requireBool(entry, "cached_turns_accepted", path: path)
            ),
            provenance: provenance
        )
    }

    private static func parseProvenance(
        _ provenance: [String: Any],
        path: String
    ) throws -> ContinuousBatchingPolicyProvenance {
        try exactKeys(
            provenance,
            allowed: [
                "source", "status", "evidence_id", "package_manifest_sha256",
                "studio_campaign_sha256", "provider_cli_version", "live_executable_cdhash",
            ],
            required: [
                "source", "status", "evidence_id", "package_manifest_sha256",
                "studio_campaign_sha256", "provider_cli_version", "live_executable_cdhash",
            ],
            path: path
        )
        let source = try requireString(
            provenance,
            "source",
            path: path,
            allowed: ["packaged_studio_campaign", "release_review", "operator_review"]
        )
        let status = try requireString(provenance, "status", path: path, allowed: ["qualified"])
        return ContinuousBatchingPolicyProvenance(
            source: source,
            status: status,
            evidenceID: try requireShortString(provenance, "evidence_id", path: path),
            packageManifestSHA256: try requireSHA256(provenance, "package_manifest_sha256", path: path),
            studioCampaignSHA256: try requireSHA256(provenance, "studio_campaign_sha256", path: path),
            providerCLIVersion: try requireShortString(provenance, "provider_cli_version", path: path),
            liveExecutableCDHash: try requireHex(provenance, "live_executable_cdhash", path: path, bytes: 20)
        )
    }

    private static func validateCatalogRows(
        _ entries: [ContinuousBatchingPolicyEntry],
        catalog: CandidateCatalog
    ) throws {
        for entry in entries {
            guard let row = catalog.rows[entry.modelKey] else {
                throw ContinuousBatchingSignedPolicyError.rowMismatch("\(entry.modelKey).missing")
            }
            guard entry.tuple.modelID == entry.modelKey else {
                throw ContinuousBatchingSignedPolicyError.rowMismatch("\(entry.modelKey).tuple_model_id")
            }
            guard row.modelSHA256 == entry.tuple.modelSHA256 else {
                throw ContinuousBatchingSignedPolicyError.rowMismatch("\(entry.modelKey).model_sha256")
            }
            guard ["candidate", "listed", "recommendable"].contains(row.runtimeStatus) else {
                throw ContinuousBatchingSignedPolicyError.rowMismatch("\(entry.modelKey).runtime_status")
            }
        }
    }

    private static func verifyDetachedSignature(
        payload: Data,
        signatureData: Data,
        trustedKeyring: TrustedKeyring
    ) throws -> String {
        try AutotuneStrictJSON.rejectDuplicateKeys(signatureData)
        guard let object = try JSONSerialization.jsonObject(with: signatureData) as? [String: Any] else {
            throw ContinuousBatchingSignedPolicyError.signatureInvalid("sidecar_type")
        }
        try exactKeys(
            object,
            allowed: ["key_id", "alg", "signature"],
            required: ["key_id", "alg", "signature"],
            path: "$.signature"
        )
        let keyID = try requireShortString(object, "key_id", path: "$.signature")
        guard keyID == trustedKeyring.requiredKeyID else {
            throw ContinuousBatchingSignedPolicyError.signatureInvalid("unexpected_key_id")
        }
        try requireString(object, "alg", path: "$.signature", equals: "ed25519")
        guard let encodedPublicKey = trustedKeyring.publicKeysByKeyID[keyID],
              let publicKeyBytes = Data(base64Encoded: encodedPublicKey),
              publicKeyBytes.count == 32,
              publicKeyBytes.base64EncodedString() == encodedPublicKey,
              let signatureEncoded = object["signature"] as? String,
              let signature = Data(base64Encoded: signatureEncoded),
              signature.count == 64,
              signature.base64EncodedString() == signatureEncoded,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes),
              publicKey.isValidSignature(signature, for: payload) else {
            throw ContinuousBatchingSignedPolicyError.signatureInvalid("verification_failed")
        }
        return keyID
    }

    private static func exactKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        required: Set<String>,
        path: String
    ) throws {
        let actual = Set(object.keys)
        for key in actual.subtracting(allowed) {
            throw ContinuousBatchingSignedPolicyError.unknownField("\(path).\(key)")
        }
        for key in required.subtracting(actual) {
            throw ContinuousBatchingSignedPolicyError.missingField("\(path).\(key)")
        }
    }

    private static func requireObject(_ object: [String: Any], _ key: String, path: String) throws -> [String: Any] {
        guard let value = object[key] else { throw ContinuousBatchingSignedPolicyError.missingField("\(path).\(key)") }
        guard let fields = value as? [String: Any] else { throw ContinuousBatchingSignedPolicyError.wrongType("\(path).\(key)") }
        return fields
    }

    @discardableResult
    private static func requireString(
        _ object: [String: Any],
        _ key: String,
        path: String,
        equals expected: String
    ) throws -> String {
        let value = try requireShortString(object, key, path: path)
        guard value == expected else { throw ContinuousBatchingSignedPolicyError.invalidValue("\(path).\(key)") }
        return value
    }

    private static func requireString(
        _ object: [String: Any],
        _ key: String,
        path: String,
        allowed: Set<String>
    ) throws -> String {
        let value = try requireShortString(object, key, path: path)
        guard allowed.contains(value) else { throw ContinuousBatchingSignedPolicyError.unsupported("\(path).\(key)") }
        return value
    }

    private static func requireShortString(_ object: [String: Any], _ key: String, path: String) throws -> String {
        guard let value = object[key] else { throw ContinuousBatchingSignedPolicyError.missingField("\(path).\(key)") }
        guard let string = value as? String else { throw ContinuousBatchingSignedPolicyError.wrongType("\(path).\(key)") }
        guard (1...256).contains(string.utf8.count),
              string == string.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ContinuousBatchingSignedPolicyError.invalidValue("\(path).\(key)")
        }
        return string
    }

    private static func requireASCIIString(
        _ object: [String: Any],
        _ key: String,
        path: String,
        range: ClosedRange<Int>
    ) throws -> String {
        let value = try requireShortString(object, key, path: path)
        guard range.contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else {
            throw ContinuousBatchingSignedPolicyError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireSHA256(_ object: [String: Any], _ key: String, path: String) throws -> String {
        try requireHex(object, key, path: path, bytes: 32)
    }

    private static func requireHex(_ object: [String: Any], _ key: String, path: String, bytes: Int) throws -> String {
        let value = try requireShortString(object, key, path: path)
        guard value.utf8.count == bytes * 2,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ContinuousBatchingSignedPolicyError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireBool(_ object: [String: Any], _ key: String, path: String) throws -> Bool {
        guard let value = object[key] else { throw ContinuousBatchingSignedPolicyError.missingField("\(path).\(key)") }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ContinuousBatchingSignedPolicyError.wrongType("\(path).\(key)")
        }
        return number.boolValue
    }

    private static func requireRFC3339UTCSecondsString(
        _ object: [String: Any],
        _ key: String,
        path: String
    ) throws -> String {
        let value = try requireShortString(object, key, path: path)
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil else {
            throw ContinuousBatchingSignedPolicyError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func parseRFC3339UTCSeconds(_ value: String, path: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw ContinuousBatchingSignedPolicyError.invalidValue(path)
        }
        return date
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AutotuneStaticInputs {
    func loadContinuousBatchingPolicy(
        candidateCatalog catalog: AutotuneStaticSelection<CandidateCatalog>,
        baseURL: URL = URL(string: "https://coordinator.malibu.tech")!
    ) async -> ContinuousBatchingPolicyLoadResult {
        guard !catalog.usedFallback,
              catalog.signerKeyID != nil,
              catalog.warnings.isDisjoint(with: [.candidateCatalogIntegrityFailure, .candidateCatalogUpdateRequired])
        else {
            return ContinuousBatchingPolicyLoadResult(
                selection: .emptyOff,
                status: .updateRequiredFallback,
                policySHA256: nil,
                signerKeyID: nil
            )
        }
        let policyURL = Self.staticFeedURL(baseURL: baseURL, name: "continuous-batching-policy")
        let signatureURL = Self.staticFeedURL(baseURL: baseURL, name: "continuous-batching-policy.sig")
        let policyData: Data
        do {
            policyData = try await fetch(policyURL)
        } catch {
            return ContinuousBatchingPolicyLoadResult(
                selection: .emptyOff,
                status: .absentFallback,
                policySHA256: nil,
                signerKeyID: nil
            )
        }
        let signatureData: Data
        do {
            signatureData = try await fetch(signatureURL)
        } catch {
            return ContinuousBatchingPolicyLoadResult(
                selection: .emptyOff,
                status: .integrityFailureFallback,
                policySHA256: Self.candidateCatalogSHA256(bytes: policyData),
                signerKeyID: nil
            )
        }
        do {
            let selection = try ContinuousBatchingSignedPolicy.verify(
                policyData: policyData,
                signatureData: signatureData,
                catalog: catalog,
                trustedKeyring: ContinuousBatchingSignedPolicy.TrustedKeyring(
                    publicKeysByKeyID: trustedPublicKeys,
                    requiredKeyID: catalog.signerKeyID ?? Self.keyID
                ),
                now: now(),
                source: "coordinator"
            )
            return ContinuousBatchingPolicyLoadResult(
                selection: selection,
                status: .liveVerified,
                policySHA256: Self.candidateCatalogSHA256(bytes: policyData),
                signerKeyID: selection.signerKeyID
            )
        } catch let error as ContinuousBatchingSignedPolicyError {
            let status: ContinuousBatchingPolicyLoadStatus
            switch error {
            case .expired, .futureDated, .catalogMismatch, .rowMismatch:
                status = .updateRequiredFallback
            case .invalidJSON, .unknownField, .missingField, .wrongType, .invalidValue, .unsupported, .signatureInvalid:
                status = .integrityFailureFallback
            }
            return ContinuousBatchingPolicyLoadResult(
                selection: .emptyOff,
                status: status,
                policySHA256: Self.candidateCatalogSHA256(bytes: policyData),
                signerKeyID: nil
            )
        } catch {
            return ContinuousBatchingPolicyLoadResult(
                selection: .emptyOff,
                status: .integrityFailureFallback,
                policySHA256: Self.candidateCatalogSHA256(bytes: policyData),
                signerKeyID: nil
            )
        }
    }
}
