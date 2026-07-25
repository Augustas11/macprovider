import CryptoKit
import Darwin
import Foundation

extension MalibuReleaseContractError {
    static var authorizationReplay: MalibuReleaseContractError { .insecureState("authorization nonce was already consumed") }
    static var rollbackStateMismatch: MalibuReleaseContractError { .insecureState("rollback authorization state binding differs") }
    static var rotationPolicyViolation: MalibuReleaseContractError { .insecureState("key rotation overlap policy was not satisfied") }
}

/// A fail-closed, context-separated authorization for the only permitted anti-replay
/// exception. Validation consumes the nonce as its final step. A crash after that
/// point denies a retry rather than allowing a replay.
enum MalibuReleaseRollbackAuthorization {
    struct Validation: Equatable {
        let nonce: String
        let incident: String
        let issuer: String
        let issuedAt: Date
        let expiresAt: Date
        let keyID: String
        let spkiSHA256: String
    }

    static let schema = "malibu-release-rollback.v1"
    static let context = Data("malibu.release-rollback.v1".utf8) + Data([0])
    static let maximumTTL: TimeInterval = 60 * 60

    static func validateAndConsume(
        _ data: Data,
        trust: MalibuReleaseTrustPolicy,
        now: Date,
        current: MalibuReleaseAntiReplayState,
        target: MalibuReleaseAntiReplayState,
        receiptDirectory: URL
    ) throws {
        let validation = try validate(
            data,
            trust: trust,
            now: now,
            current: current,
            target: target
        )
        try MalibuReleaseAuthorizationReceiptStore.consume(
            nonce: validation.nonce,
            kind: "rollback",
            details: ["incident": validation.incident, "issuer": validation.issuer],
            directory: receiptDirectory
        )
    }

    static func validate(
        _ data: Data,
        trust: MalibuReleaseTrustPolicy,
        now: Date,
        current: MalibuReleaseAntiReplayState,
        target: MalibuReleaseAntiReplayState
    ) throws -> Validation {
        let document = try MalibuReleaseStrictJSON.parseCanonicalObject(data, label: "Malibu rollback authorization")
        try rrExactKeys(document, ["schema_version", "signature", "signed"], "rollback authorization")
        guard try rrString(document["schema_version"], "rollback schema") == schema else {
            throw MalibuReleaseContractError.invalidValue("rollback schema")
        }
        let signed = try rrObject(document["signed"], "rollback signed payload")
        let keyID = try rrVerify(document["signature"], signed: signed, context: context, trust: trust)
        try rrExactKeys(
            signed,
            ["current", "expires_at", "incident", "issued_at", "issuer", "nonce", "target"],
            "rollback signed payload"
        )
        let issuedAt = try rrTimestamp(signed["issued_at"], "rollback issued_at")
        let expiresAt = try rrTimestamp(signed["expires_at"], "rollback expires_at")
        guard issuedAt.timeIntervalSince(now) <= MalibuReleaseEnvelopeValidator.maximumFutureSkew else {
            throw MalibuReleaseContractError.futureDated
        }
        guard expiresAt > now else { throw MalibuReleaseContractError.expired }
        guard expiresAt > issuedAt, expiresAt.timeIntervalSince(issuedAt) <= maximumTTL else {
            throw MalibuReleaseContractError.invalidValue("rollback validity")
        }
        let incident = try rrToken(signed["incident"], label: "rollback incident", pattern: "^[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}$")
        let issuer = try rrToken(signed["issuer"], label: "rollback issuer", pattern: "^[A-Za-z0-9][A-Za-z0-9._@:/-]{2,127}$")
        let nonce = try rrToken(signed["nonce"], label: "rollback nonce", pattern: "^[0-9a-f]{64}$")
        let boundCurrent = try rrState(signed["current"], label: "rollback current")
        let boundTarget = try rrState(signed["target"], label: "rollback target")
        guard boundCurrent == current, boundTarget == target else {
            throw MalibuReleaseContractError.rollbackStateMismatch
        }
        guard target.highestIndexGeneration <= current.highestIndexGeneration,
              target.highestBuild <= current.highestBuild,
              target.highestEnvelopeGeneration <= current.highestEnvelopeGeneration,
              target.highestIndexGeneration < current.highestIndexGeneration
                || target.highestBuild < current.highestBuild
                || target.highestEnvelopeGeneration < current.highestEnvelopeGeneration
        else { throw MalibuReleaseContractError.invalidValue("rollback target") }
        guard let trustedKey = trust.keys[keyID] else {
            throw MalibuReleaseContractError.unknownKey(keyID)
        }
        return Validation(
            nonce: nonce,
            incident: incident,
            issuer: issuer,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            keyID: keyID,
            spkiSHA256: trustedKey.spkiSHA256
        )
    }
}

/// The rotation authorization is itself the overlap index: one canonical payload,
/// bound to an exact higher-generation candidate keyring and exact release index,
/// with independent retiring- and successor-policy signatures.
enum MalibuReleaseKeyRotationAuthorization {
    struct Validation: Equatable {
        let rotationID: String
        let overlapIndexGeneration: Int
        let overlapIndexSHA256: String
    }

    static let schema = "malibu-release-key-rotation.v1"
    static let retiringContext = Data("malibu.release-key-rotation.v1.retiring".utf8) + Data([0])
    static let successorContext = Data("malibu.release-key-rotation.v1.successor".utf8) + Data([0])
    static let maximumTTL: TimeInterval = 24 * 60 * 60

    static func validateOverlapAndCommit(
        _ data: Data,
        currentTrust: MalibuReleaseTrustPolicy,
        successorTrust: MalibuReleaseTrustPolicy,
        retiringKeyID: String,
        successorKeyID: String,
        overlapIndexData: Data,
        minimumIndexGeneration: Int,
        now: Date,
        receiptDirectory: URL
    ) throws {
        let validation = try validateOverlap(
            data,
            currentTrust: currentTrust,
            successorTrust: successorTrust,
            retiringKeyID: retiringKeyID,
            successorKeyID: successorKeyID,
            overlapIndexData: overlapIndexData,
            minimumIndexGeneration: minimumIndexGeneration,
            now: now
        )
        try MalibuReleaseAuthorizationReceiptStore.consume(
            nonce: validation.rotationID,
            kind: "rotation-overlap",
            details: [
                "current_keyring_sha256": currentTrust.keyringSHA256,
                "successor_keyring_sha256": successorTrust.keyringSHA256,
                "retiring_key_id": retiringKeyID,
                "successor_key_id": successorKeyID,
            ],
            directory: receiptDirectory
        )
    }

    static func validateOverlap(
        _ data: Data,
        currentTrust: MalibuReleaseTrustPolicy,
        successorTrust: MalibuReleaseTrustPolicy,
        retiringKeyID: String,
        successorKeyID: String,
        overlapIndexData: Data,
        minimumIndexGeneration: Int,
        now: Date
    ) throws -> Validation {
        guard retiringKeyID != successorKeyID,
              currentTrust.keys[retiringKeyID]?.status == "active" || currentTrust.keys[retiringKeyID]?.status == "retiring",
              currentTrust.keys[successorKeyID] == nil,
              successorTrust.keys[retiringKeyID]?.status == "retiring",
              successorTrust.keys[successorKeyID]?.status == "active",
              !successorTrust.revokedKeyIDs.contains(retiringKeyID),
              !successorTrust.revokedKeyIDs.contains(successorKeyID),
              successorTrust.generation > currentTrust.generation
        else { throw MalibuReleaseContractError.rotationPolicyViolation }

        let document = try MalibuReleaseStrictJSON.parseCanonicalObject(data, label: "Malibu key rotation authorization")
        try rrExactKeys(document, ["schema_version", "signatures", "signed"], "key rotation authorization")
        guard try rrString(document["schema_version"], "rotation schema") == schema else {
            throw MalibuReleaseContractError.invalidValue("rotation schema")
        }
        let signed = try rrObject(document["signed"], "rotation signed payload")
        let signatures = try rrObject(document["signatures"], "rotation signatures")
        try rrExactKeys(signatures, ["retiring", "successor"], "rotation signatures")
        try rrVerify(signatures["retiring"], signed: signed, context: retiringContext, trust: currentTrust, expectedKeyID: retiringKeyID)
        try rrVerify(signatures["successor"], signed: signed, context: successorContext, trust: successorTrust, expectedKeyID: successorKeyID)
        try rrExactKeys(
            signed,
            ["audit", "current_trust", "expires_at", "incident", "issued_at", "issuer", "overlap_index", "rotation_id", "successor_trust"],
            "rotation signed payload"
        )
        let issuedAt = try rrTimestamp(signed["issued_at"], "rotation issued_at")
        let expiresAt = try rrTimestamp(signed["expires_at"], "rotation expires_at")
        guard issuedAt.timeIntervalSince(now) <= MalibuReleaseEnvelopeValidator.maximumFutureSkew else {
            throw MalibuReleaseContractError.futureDated
        }
        guard expiresAt > now else { throw MalibuReleaseContractError.expired }
        guard expiresAt > issuedAt, expiresAt.timeIntervalSince(issuedAt) <= maximumTTL else {
            throw MalibuReleaseContractError.invalidValue("rotation validity")
        }
        _ = try rrToken(signed["incident"], label: "rotation incident", pattern: "^[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}$")
        _ = try rrToken(signed["issuer"], label: "rotation issuer", pattern: "^[A-Za-z0-9][A-Za-z0-9._@:/-]{2,127}$")
        let rotationID = try rrToken(signed["rotation_id"], label: "rotation ID", pattern: "^[0-9a-f]{64}$")
        try rrValidateTrustBinding(signed["current_trust"], trust: currentTrust, keyLabel: "retiring_key_id", keyID: retiringKeyID)
        try rrValidateTrustBinding(signed["successor_trust"], trust: successorTrust, keyLabel: "successor_key_id", keyID: successorKeyID)

        let overlap = try rrObject(signed["overlap_index"], "rotation overlap index")
        try rrExactKeys(overlap, ["index_generation", "sha256"], "rotation overlap index")
        let overlapIndexGeneration = try rrPositiveInt(
            overlap["index_generation"], "overlap index generation"
        )
        let overlapIndexSHA256 = try rrHex(overlap["sha256"], "overlap index digest")
        guard overlapIndexGeneration > minimumIndexGeneration,
              overlapIndexSHA256 == SHA256.hash(data: overlapIndexData).rrHex
        else { throw MalibuReleaseContractError.rotationPolicyViolation }
        let audit = try rrObject(signed["audit"], "rotation audit")
        try rrExactKeys(audit, ["report_sha256", "reviewer"], "rotation audit")
        _ = try rrHex(audit["report_sha256"], "rotation audit digest")
        _ = try rrToken(audit["reviewer"], label: "rotation reviewer", pattern: "^[A-Za-z0-9][A-Za-z0-9._@:/-]{2,127}$")

        return Validation(
            rotationID: rotationID,
            overlapIndexGeneration: overlapIndexGeneration,
            overlapIndexSHA256: overlapIndexSHA256
        )
    }

    /// Removal or revocation of the retiring key is denied unless the exact overlap
    /// transition receipt exists and the successor policy advances again.
    static func authorizeRetirement(
        overlapTrust: MalibuReleaseTrustPolicy,
        retirementTrust: MalibuReleaseTrustPolicy,
        retiringKeyID: String,
        successorKeyID: String,
        rotationID: String,
        receiptDirectory: URL
    ) throws {
        guard try MalibuReleaseAuthorizationReceiptStore.validate(
                nonce: rotationID,
                kind: "rotation-overlap",
                expectedDetails: [
                    "successor_keyring_sha256": overlapTrust.keyringSHA256,
                    "retiring_key_id": retiringKeyID,
                    "successor_key_id": successorKeyID,
                ],
                directory: receiptDirectory
              ) else { throw MalibuReleaseContractError.rotationPolicyViolation }
        try validateRetirement(
            overlapTrust: overlapTrust,
            retirementTrust: retirementTrust,
            retiringKeyID: retiringKeyID,
            successorKeyID: successorKeyID
        )
    }

    static func validateRetirement(
        overlapTrust: MalibuReleaseTrustPolicy,
        retirementTrust: MalibuReleaseTrustPolicy,
        retiringKeyID: String,
        successorKeyID: String
    ) throws {
        guard retirementTrust.generation > overlapTrust.generation,
              retirementTrust.revocationsGeneration >= overlapTrust.revocationsGeneration,
              overlapTrust.keys[retiringKeyID] != nil,
              overlapTrust.keys[successorKeyID] != nil,
              retirementTrust.keys[successorKeyID]?.status == "active",
              retirementTrust.keys[retiringKeyID] == nil || retirementTrust.revokedKeyIDs.contains(retiringKeyID)
        else { throw MalibuReleaseContractError.rotationPolicyViolation }
    }
}

/// A retirement is a second, independently signed transition. The overlap
/// authorization cannot be reused to remove its retiring key: this document is
/// signed by the active successor and binds the exact protected-state snapshot
/// plus both the overlap and retirement trust objects.
enum MalibuReleaseKeyRetirementAuthorization {
    struct Validation: Equatable { let nonce: String }

    static let schema = "malibu-release-key-retirement.v1"
    static let context = Data("malibu.release-key-retirement.v1".utf8) + Data([0])
    static let maximumTTL: TimeInterval = 60 * 60

    static func validate(
        _ data: Data,
        activeSuccessorTrust: MalibuReleaseTrustPolicy,
        retirementTrust: MalibuReleaseTrustPolicy,
        rotationID: String,
        retiringKeyID: String,
        successorKeyID: String,
        protectedRevision: Int,
        highWater: MalibuReleaseAntiReplayState,
        now: Date
    ) throws -> Validation {
        let document = try MalibuReleaseStrictJSON.parseCanonicalObject(
            data,
            label: "Malibu key retirement authorization"
        )
        try rrExactKeys(document, ["schema_version", "signature", "signed"], "key retirement authorization")
        guard try rrString(document["schema_version"], "retirement schema") == schema else {
            throw MalibuReleaseContractError.invalidValue("retirement schema")
        }
        let signed = try rrObject(document["signed"], "retirement signed payload")
        try rrVerify(
            document["signature"],
            signed: signed,
            context: context,
            trust: activeSuccessorTrust,
            expectedKeyID: successorKeyID
        )
        try rrExactKeys(
            signed,
            [
                "expires_at", "high_water", "issued_at", "nonce", "overlap_trust",
                "protected_revision", "retirement_trust", "retiring_key_id", "rotation_id",
                "successor_key_id",
            ],
            "retirement signed payload"
        )
        let issuedAt = try rrTimestamp(signed["issued_at"], "retirement issued_at")
        let expiresAt = try rrTimestamp(signed["expires_at"], "retirement expires_at")
        guard issuedAt.timeIntervalSince(now) <= MalibuReleaseEnvelopeValidator.maximumFutureSkew else {
            throw MalibuReleaseContractError.futureDated
        }
        guard expiresAt > now else { throw MalibuReleaseContractError.expired }
        guard expiresAt > issuedAt, expiresAt.timeIntervalSince(issuedAt) <= maximumTTL else {
            throw MalibuReleaseContractError.invalidValue("retirement validity")
        }
        let nonce = try rrToken(
            signed["nonce"],
            label: "retirement nonce",
            pattern: "^[0-9a-f]{64}$"
        )
        guard try rrToken(
            signed["rotation_id"],
            label: "retirement rotation ID",
            pattern: "^[0-9a-f]{64}$"
        ) == rotationID,
              try rrString(signed["retiring_key_id"], "retiring key ID") == retiringKeyID,
              try rrString(signed["successor_key_id"], "successor key ID") == successorKeyID,
              try rrPositiveInt(signed["protected_revision"], "protected revision") == protectedRevision,
              try rrState(signed["high_water"], label: "retirement high water") == highWater else {
            throw MalibuReleaseContractError.rotationPolicyViolation
        }
        try rrValidateTrustBinding(
            signed["overlap_trust"],
            trust: activeSuccessorTrust,
            keyLabel: "successor_key_id",
            keyID: successorKeyID
        )
        try rrValidateRetirementTrustBinding(
            signed["retirement_trust"],
            trust: retirementTrust,
            retiringKeyID: retiringKeyID,
            successorKeyID: successorKeyID
        )
        try MalibuReleaseKeyRotationAuthorization.validateRetirement(
            overlapTrust: activeSuccessorTrust,
            retirementTrust: retirementTrust,
            retiringKeyID: retiringKeyID,
            successorKeyID: successorKeyID
        )
        return Validation(nonce: nonce)
    }
}

enum MalibuReleaseAuthorizationReceiptStore {
    static func consume(nonce: String, kind: String, details: [String: String], directory: URL) throws {
        try secureDirectory(directory)
        let digest = SHA256.hash(data: Data("\(kind)\u{0}\(nonce)".utf8)).rrHex
        let url = directory.appendingPathComponent("\(kind)-\(digest).json")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw MalibuReleaseContractError.authorizationReplay }
            throw MalibuReleaseContractError.insecureState("could not atomically create authorization receipt")
        }
        defer { Darwin.close(descriptor) }
        var value: [String: Any] = ["kind": kind, "nonce": nonce, "schema_version": "malibu-release-authorization-receipt.v1"]
        value["details"] = details
        let bytes = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(value))
        var offset = 0
        while offset < bytes.count {
            let wrote = bytes.withUnsafeBytes { pointer in
                Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard wrote > 0 else {
                throw MalibuReleaseContractError.insecureState("could not persist authorization receipt")
            }
            offset += wrote
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MalibuReleaseContractError.insecureState("could not persist authorization receipt")
        }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard directoryDescriptor >= 0 else {
            throw MalibuReleaseContractError.insecureState("could not open authorization receipt directory")
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw MalibuReleaseContractError.insecureState("could not persist authorization receipt directory")
        }
    }

    static func validate(
        nonce: String,
        kind: String,
        expectedDetails: [String: String],
        directory: URL
    ) throws -> Bool {
        try secureDirectory(directory)
        let digest = SHA256.hash(data: Data("\(kind)\u{0}\(nonce)".utf8)).rrHex
        let url = directory.appendingPathComponent("\(kind)-\(digest).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
        else { throw MalibuReleaseContractError.insecureState("authorization receipt metadata is insecure") }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let receipt = try MalibuReleaseStrictJSON.parseCanonicalObject(data, label: "authorization receipt")
        try rrExactKeys(receipt, ["details", "kind", "nonce", "schema_version"], "authorization receipt")
        guard try rrString(receipt["schema_version"], "receipt schema") == "malibu-release-authorization-receipt.v1",
              try rrString(receipt["kind"], "receipt kind") == kind,
              try rrString(receipt["nonce"], "receipt nonce") == nonce
        else { throw MalibuReleaseContractError.insecureState("authorization receipt binding differs") }
        let details = try rrObject(receipt["details"], "authorization receipt details")
        for (key, expected) in expectedDetails {
            guard try rrString(details[key], "receipt detail \(key)") == expected else {
                throw MalibuReleaseContractError.insecureState("authorization receipt binding differs")
            }
        }
        return true
    }

    private static func secureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
        else { throw MalibuReleaseContractError.insecureState("authorization receipt directory is insecure") }
    }
}

private func rrValidateTrustBinding(_ raw: Any?, trust: MalibuReleaseTrustPolicy, keyLabel: String, keyID: String) throws {
    let value = try rrObject(raw, "rotation trust binding")
    try rrExactKeys(value, ["keyring_generation", "keyring_sha256", "revocations_generation", "revocations_sha256", keyLabel], "rotation trust binding")
    guard try rrPositiveInt(value["keyring_generation"], "keyring generation") == trust.generation,
          try rrHex(value["keyring_sha256"], "keyring digest") == trust.keyringSHA256,
          try rrPositiveInt(value["revocations_generation"], "revocations generation") == trust.revocationsGeneration,
          try rrHex(value["revocations_sha256"], "revocations digest") == trust.revocationsSHA256,
          try rrString(value[keyLabel], keyLabel) == keyID
    else { throw MalibuReleaseContractError.rotationPolicyViolation }
}

private func rrValidateRetirementTrustBinding(
    _ raw: Any?,
    trust: MalibuReleaseTrustPolicy,
    retiringKeyID: String,
    successorKeyID: String
) throws {
    let value = try rrObject(raw, "retirement trust binding")
    try rrExactKeys(
        value,
        [
            "keyring_generation", "keyring_sha256", "retiring_key_id",
            "revocations_generation", "revocations_sha256", "successor_key_id",
        ],
        "retirement trust binding"
    )
    guard try rrPositiveInt(value["keyring_generation"], "retirement keyring generation") == trust.generation,
          try rrHex(value["keyring_sha256"], "retirement keyring digest") == trust.keyringSHA256,
          try rrPositiveInt(value["revocations_generation"], "retirement revocations generation") == trust.revocationsGeneration,
          try rrHex(value["revocations_sha256"], "retirement revocations digest") == trust.revocationsSHA256,
          try rrString(value["retiring_key_id"], "retiring key ID") == retiringKeyID,
          try rrString(value["successor_key_id"], "successor key ID") == successorKeyID else {
        throw MalibuReleaseContractError.rotationPolicyViolation
    }
}

private func rrState(_ raw: Any?, label: String) throws -> MalibuReleaseAntiReplayState {
    let value = try rrObject(raw, label)
    try rrExactKeys(value, ["build", "envelope_generation", "envelope_sha256", "index_generation"], label)
    return MalibuReleaseAntiReplayState(
        schemaVersion: "malibu-release-anti-replay.v1",
        highestIndexGeneration: try rrPositiveInt(value["index_generation"], "\(label) index generation"),
        highestBuild: try rrPositiveInt(value["build"], "\(label) build"),
        highestEnvelopeGeneration: try rrPositiveInt(value["envelope_generation"], "\(label) envelope generation"),
        envelopeSHA256: try rrHex(value["envelope_sha256"], "\(label) envelope digest")
    )
}

@discardableResult
private func rrVerify(_ raw: Any?, signed: [String: Any], context: Data, trust: MalibuReleaseTrustPolicy, expectedKeyID: String? = nil) throws -> String {
    let signature = try rrObject(raw, "signature")
    try rrExactKeys(signature, ["algorithm", "key_id", "signature"], "signature")
    guard try rrString(signature["algorithm"], "signature algorithm") == "ecdsa-p256-sha256" else {
        throw MalibuReleaseContractError.invalidValue("signature algorithm")
    }
    let keyID = try rrString(signature["key_id"], "signature key ID")
    if let expectedKeyID, keyID != expectedKeyID { throw MalibuReleaseContractError.unknownKey(keyID) }
    if trust.revokedKeyIDs.contains(keyID) { throw MalibuReleaseContractError.revokedKey(keyID) }
    guard let key = trust.keys[keyID] else { throw MalibuReleaseContractError.unknownKey(keyID) }
    let encoded = try rrString(signature["signature"], "signature bytes")
    guard !encoded.contains("="), let der = rrBase64URL(encoded),
          let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: der)
    else { throw MalibuReleaseContractError.invalidSignature }
    let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(signed))
    guard key.publicKey.isValidSignature(ecdsa, for: context + canonical) else {
        throw MalibuReleaseContractError.invalidSignature
    }
    return keyID
}

private func rrExactKeys(_ value: [String: Any], _ keys: Set<String>, _ label: String) throws {
    guard Set(value.keys) == keys else { throw MalibuReleaseContractError.invalidFields(label) }
}

private func rrObject(_ raw: Any?, _ label: String) throws -> [String: Any] {
    guard let value = raw as? [String: Any] else { throw MalibuReleaseContractError.invalidValue(label) }
    return value
}

private func rrString(_ raw: Any?, _ label: String) throws -> String {
    guard let value = raw as? String, !value.isEmpty else { throw MalibuReleaseContractError.invalidValue(label) }
    return value
}

private func rrPositiveInt(_ raw: Any?, _ label: String) throws -> Int {
    guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.intValue > 0,
          value.doubleValue == Double(value.intValue) else { throw MalibuReleaseContractError.invalidValue(label) }
    return value.intValue
}

private func rrHex(_ raw: Any?, _ label: String) throws -> String {
    let value = try rrString(raw, label)
    guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw MalibuReleaseContractError.invalidValue(label)
    }
    return value
}

private func rrToken(_ raw: Any?, label: String, pattern: String) throws -> String {
    let value = try rrString(raw, label)
    guard value.range(of: pattern, options: .regularExpression) != nil else {
        throw MalibuReleaseContractError.invalidValue(label)
    }
    return value
}

private func rrTimestamp(_ raw: Any?, _ label: String) throws -> Date {
    let value = try rrString(raw, label)
    guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", options: .regularExpression) != nil else {
        throw MalibuReleaseContractError.invalidValue(label)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    guard let result = formatter.date(from: value) else { throw MalibuReleaseContractError.invalidValue(label) }
    return result
}

private func rrBase64URL(_ value: String) -> Data? {
    var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    return Data(base64Encoded: encoded)
}

private extension Digest {
    var rrHex: String { map { String(format: "%02x", $0) }.joined() }
}
