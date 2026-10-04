import Darwin
import Foundation
import Security

// SPEC-049 v0.2 supervisor-attestor wire (§4.10, §4.11, SPEC-049-R025,
// SPEC-049-R026). This one file is compiled into both macprovider-cli and
// Malibu.app (phase3-binary/app/project.yml), so both sides frame statements
// and channel messages from the same source. It must stay free of types that
// exist in only one of the two targets.

enum PrivacySupervisorConstants {
    static let privacyClass = "operator_constrained_beta_v1"
    static let assuranceBeta = "device_bound_self_attested_beta"
    static let assuranceCodeBound = "code_bound_attested"
    static let postureV2Version = "privacy-posture-v2"
    static let postureV2Domain = "macprovider/spec049/posture/v2"
    static let enrollmentVersion = "privacy-app-attest-enrollment-v1"
    static let enrollmentDomain = "macprovider/spec049/app-attest-enrollment/v1"
    static let supervisorBundleID = "tech.malibu.app"
    static let childSigningIdentifier = "live.malibu.provider.cli"
    static let environment = "production"
    static let runtimeSource = "native_mlx"
    static let seBackendFile = "file"
    static let seBackendKeychain = "keychain"
    /// CS_VALID | CS_HARD | CS_KILL | CS_RUNTIME (§4.1).
    static let requiredChildCSFlags: UInt64 = 0x0001_0301
    /// CS_ADHOC | CS_GET_TASK_ALLOW | CS_INVALID_ALLOWED | CS_DEBUGGED (§4.1).
    static let forbiddenChildCSFlags: UInt64 = 0x1000_0026
    static let childCheckSkewSeconds: Int64 = 5
    static let maxIdentifierBytes = 128
    static let maxSupervisorBundleVersionBytes = 64
    static let maxKeyRecordDigests = 8
    /// Decoded App Attest object caps (§4.10, §4.11).
    static let maxAttestationBytes = 16384
    static let maxAssertionBytes = 2048
    /// Channel frame body cap. An attestation reply is the largest message.
    static let maxChannelFrameBytes = 65536
    static let channelVersion = 1

    static func childCSFlagsOK(_ flags: UInt64) -> Bool {
        flags <= 0xffff_ffff
            && flags & requiredChildCSFlags == requiredChildCSFlags
            && flags & forbiddenChildCSFlags == 0
    }
}

enum PrivacySupervisorWireError: Error, Equatable, CustomStringConvertible {
    case invalid

    var description: String { "privacy_supervisor_invalid_message" }
}

// MARK: - Statements

/// Fields 1..26 of `privacy-posture-v2`: everything the child owns. The
/// supervisor fills fields 27..34 from its own observations (SPEC-049-R025).
struct PrivacyPostureV2Draft: Equatable, Sendable {
    var version: String
    var privacyClass: String
    var providerID: String
    var assignedSession: String
    var nonce: String
    var sequence: UInt64
    var issuedAtUnix: Int64
    var binaryVersion: String
    var codeCDHash: String
    var teamID: String
    var signingIdentifier: String
    var hardenedRuntime: Bool
    var libraryValidation: Bool
    var getTaskAllow: Bool
    var csDebugged: Bool
    var pTraced: Bool
    var ptDenyAttachApplied: Bool
    var coreDumpsDisabled: Bool
    var sipEnabled: Bool
    var runtimeSource: String
    var diagnosticEnvClear: Bool
    var kvDiskTierDisabled: Bool
    var seKeyBackend: String
    /// Strictly ascending; framing does not sort.
    var privacyKeyRecordDigests: [String]
    var assurance: String
    var appAttestKeyID: String

    static let fieldNames: Set<String> = [
        "version", "privacy_class", "provider_id", "assigned_session", "nonce", "sequence", "issued_at_unix",
        "binary_version", "code_cdhash", "team_id", "signing_identifier", "hardened_runtime", "library_validation",
        "get_task_allow", "cs_debugged", "p_traced", "pt_deny_attach_applied", "core_dumps_disabled", "sip_enabled",
        "runtime_source", "diagnostic_env_clear", "kv_disk_tier_disabled", "se_key_backend", "privacy_key_record_digests",
        "assurance", "app_attest_key_id",
    ]

    var wireObject: [String: Any] {
        [
            "version": version,
            "privacy_class": privacyClass,
            "provider_id": providerID,
            "assigned_session": assignedSession,
            "nonce": nonce,
            "sequence": NSNumber(value: sequence),
            "issued_at_unix": NSNumber(value: issuedAtUnix),
            "binary_version": binaryVersion,
            "code_cdhash": codeCDHash,
            "team_id": teamID,
            "signing_identifier": signingIdentifier,
            "hardened_runtime": hardenedRuntime,
            "library_validation": libraryValidation,
            "get_task_allow": getTaskAllow,
            "cs_debugged": csDebugged,
            "p_traced": pTraced,
            "pt_deny_attach_applied": ptDenyAttachApplied,
            "core_dumps_disabled": coreDumpsDisabled,
            "sip_enabled": sipEnabled,
            "runtime_source": runtimeSource,
            "diagnostic_env_clear": diagnosticEnvClear,
            "kv_disk_tier_disabled": kvDiskTierDisabled,
            "se_key_backend": seKeyBackend,
            "privacy_key_record_digests": privacyKeyRecordDigests,
            "assurance": assurance,
            "app_attest_key_id": appAttestKeyID,
        ]
    }

    init(
        version: String = PrivacySupervisorConstants.postureV2Version,
        privacyClass: String = PrivacySupervisorConstants.privacyClass,
        providerID: String,
        assignedSession: String,
        nonce: String,
        sequence: UInt64,
        issuedAtUnix: Int64,
        binaryVersion: String,
        codeCDHash: String,
        teamID: String,
        signingIdentifier: String,
        hardenedRuntime: Bool,
        libraryValidation: Bool,
        getTaskAllow: Bool,
        csDebugged: Bool,
        pTraced: Bool,
        ptDenyAttachApplied: Bool,
        coreDumpsDisabled: Bool,
        sipEnabled: Bool,
        runtimeSource: String,
        diagnosticEnvClear: Bool,
        kvDiskTierDisabled: Bool,
        seKeyBackend: String,
        privacyKeyRecordDigests: [String],
        assurance: String = PrivacySupervisorConstants.assuranceCodeBound,
        appAttestKeyID: String
    ) {
        self.version = version
        self.privacyClass = privacyClass
        self.providerID = providerID
        self.assignedSession = assignedSession
        self.nonce = nonce
        self.sequence = sequence
        self.issuedAtUnix = issuedAtUnix
        self.binaryVersion = binaryVersion
        self.codeCDHash = codeCDHash
        self.teamID = teamID
        self.signingIdentifier = signingIdentifier
        self.hardenedRuntime = hardenedRuntime
        self.libraryValidation = libraryValidation
        self.getTaskAllow = getTaskAllow
        self.csDebugged = csDebugged
        self.pTraced = pTraced
        self.ptDenyAttachApplied = ptDenyAttachApplied
        self.coreDumpsDisabled = coreDumpsDisabled
        self.sipEnabled = sipEnabled
        self.runtimeSource = runtimeSource
        self.diagnosticEnvClear = diagnosticEnvClear
        self.kvDiskTierDisabled = kvDiskTierDisabled
        self.seKeyBackend = seKeyBackend
        self.privacyKeyRecordDigests = privacyKeyRecordDigests
        self.assurance = assurance
        self.appAttestKeyID = appAttestKeyID
    }

    /// Closed decode of exactly fields 1..26.
    init(object: [String: Any]) throws {
        try self.init(reader: PrivacySupervisorReader(object, keys: Self.fieldNames))
    }

    fileprivate init(reader r: PrivacySupervisorReader) throws {
        self.init(
            version: try r.string("version"),
            privacyClass: try r.string("privacy_class"),
            providerID: try r.string("provider_id"),
            assignedSession: try r.string("assigned_session"),
            nonce: try r.string("nonce"),
            sequence: try r.unsigned("sequence"),
            issuedAtUnix: try r.signed("issued_at_unix"),
            binaryVersion: try r.string("binary_version"),
            codeCDHash: try r.string("code_cdhash"),
            teamID: try r.string("team_id"),
            signingIdentifier: try r.string("signing_identifier"),
            hardenedRuntime: try r.bool("hardened_runtime"),
            libraryValidation: try r.bool("library_validation"),
            getTaskAllow: try r.bool("get_task_allow"),
            csDebugged: try r.bool("cs_debugged"),
            pTraced: try r.bool("p_traced"),
            ptDenyAttachApplied: try r.bool("pt_deny_attach_applied"),
            coreDumpsDisabled: try r.bool("core_dumps_disabled"),
            sipEnabled: try r.bool("sip_enabled"),
            runtimeSource: try r.string("runtime_source"),
            diagnosticEnvClear: try r.bool("diagnostic_env_clear"),
            kvDiskTierDisabled: try r.bool("kv_disk_tier_disabled"),
            seKeyBackend: try r.string("se_key_backend"),
            privacyKeyRecordDigests: try r.strings("privacy_key_record_digests"),
            assurance: try r.string("assurance"),
            appAttestKeyID: try r.string("app_attest_key_id")
        )
        try validate()
    }

    /// Syntax of fields 1..26 (§4.3, §4.10). SPEC-049-R006 values are not
    /// enforced here; the coordinator applies them.
    func validate() throws {
        let c = PrivacySupervisorConstants.self
        guard version == c.postureV2Version,
              privacyClass == c.privacyClass,
              runtimeSource == c.runtimeSource,
              psvVisibleASCII(providerID, maxBytes: c.maxIdentifierBytes),
              psvVisibleASCII(assignedSession, maxBytes: c.maxIdentifierBytes),
              psvFixed(nonce, count: 32) != nil,
              psvVisibleASCII(binaryVersion, maxBytes: c.maxIdentifierBytes),
              psvCDHash(codeCDHash),
              psvTeamID(teamID),
              psvVisibleASCII(signingIdentifier, maxBytes: c.maxIdentifierBytes),
              seKeyBackend == c.seBackendFile || seKeyBackend == c.seBackendKeychain,
              psvDigestSet(privacyKeyRecordDigests),
              assurance == c.assuranceCodeBound,
              psvFixed(appAttestKeyID, count: 32) != nil else {
            throw PrivacySupervisorWireError.invalid
        }
    }

    /// Domain plus fields 1..26 in §4.3/§4.10 order.
    fileprivate func appendFraming(to framed: inout Data) throws {
        try validate()
        guard let nonceBytes = psvFixed(nonce, count: 32),
              let keyID = psvFixed(appAttestKeyID, count: 32) else {
            throw PrivacySupervisorWireError.invalid
        }
        for value in [PrivacySupervisorConstants.postureV2Domain, version, privacyClass, providerID, assignedSession] {
            framed.psvAppendFramed(Data(value.utf8))
        }
        framed.psvAppendFramed(nonceBytes)
        framed.psvAppendUnsigned64(sequence)
        framed.psvAppendUnsigned64(UInt64(bitPattern: issuedAtUnix))
        for value in [binaryVersion, codeCDHash, teamID, signingIdentifier] {
            framed.psvAppendFramed(Data(value.utf8))
        }
        for flag in [hardenedRuntime, libraryValidation, getTaskAllow, csDebugged, pTraced, ptDenyAttachApplied, coreDumpsDisabled, sipEnabled] {
            framed.psvAppendUnsigned64(flag ? 1 : 0)
        }
        framed.psvAppendFramed(Data(runtimeSource.utf8))
        framed.psvAppendUnsigned64(diagnosticEnvClear ? 1 : 0)
        framed.psvAppendUnsigned64(kvDiskTierDisabled ? 1 : 0)
        framed.psvAppendFramed(Data(seKeyBackend.utf8))
        framed.psvAppendUnsigned32(UInt32(privacyKeyRecordDigests.count))
        for digest in privacyKeyRecordDigests {
            framed.psvAppendFramed(Data(digest.utf8))
        }
        framed.psvAppendFramed(Data(assurance.utf8))
        framed.psvAppendFramed(keyID)
    }
}

/// §4.10 fields 27..34, observed by the supervisor.
struct PrivacySupervisorPostureFields: Equatable, Sendable {
    var supervisorTeamID: String
    var supervisorBundleID: String
    var supervisorBundleVersion: String
    var childCDHash: String
    var childSigningIdentifier: String
    var childCSFlags: UInt64
    var childCheckedAtUnix: Int64
    var childChannelPeerVerified: Bool

    static let fieldNames: Set<String> = [
        "supervisor_team_id", "supervisor_bundle_id", "supervisor_bundle_version", "child_cdhash",
        "child_signing_identifier", "child_cs_flags", "child_checked_at_unix", "child_channel_peer_verified",
    ]

    func validate() throws {
        let c = PrivacySupervisorConstants.self
        guard psvTeamID(supervisorTeamID),
              psvVisibleASCII(supervisorBundleID, maxBytes: c.maxIdentifierBytes),
              psvVisibleASCII(supervisorBundleVersion, maxBytes: c.maxSupervisorBundleVersionBytes),
              psvCDHash(childCDHash),
              psvVisibleASCII(childSigningIdentifier, maxBytes: c.maxIdentifierBytes),
              childCSFlags <= 0xffff_ffff else {
            throw PrivacySupervisorWireError.invalid
        }
    }
}

/// The closed `privacy-posture-v2` statement (§4.10).
struct PrivacyPostureV2Statement: Equatable, Sendable {
    var draft: PrivacyPostureV2Draft
    var supervisor: PrivacySupervisorPostureFields

    static let fieldNames = PrivacyPostureV2Draft.fieldNames.union(PrivacySupervisorPostureFields.fieldNames)

    init(draft: PrivacyPostureV2Draft, supervisor: PrivacySupervisorPostureFields) {
        self.draft = draft
        self.supervisor = supervisor
    }

    init(object: [String: Any]) throws {
        let reader = try PrivacySupervisorReader(object, keys: Self.fieldNames)
        draft = try PrivacyPostureV2Draft(reader: reader)
        supervisor = PrivacySupervisorPostureFields(
            supervisorTeamID: try reader.string("supervisor_team_id"),
            supervisorBundleID: try reader.string("supervisor_bundle_id"),
            supervisorBundleVersion: try reader.string("supervisor_bundle_version"),
            childCDHash: try reader.string("child_cdhash"),
            childSigningIdentifier: try reader.string("child_signing_identifier"),
            childCSFlags: try reader.unsigned("child_cs_flags"),
            childCheckedAtUnix: try reader.signed("child_checked_at_unix"),
            childChannelPeerVerified: try reader.bool("child_channel_peer_verified")
        )
        try supervisor.validate()
    }

    var wireObject: [String: Any] {
        var object = draft.wireObject
        object["supervisor_team_id"] = supervisor.supervisorTeamID
        object["supervisor_bundle_id"] = supervisor.supervisorBundleID
        object["supervisor_bundle_version"] = supervisor.supervisorBundleVersion
        object["child_cdhash"] = supervisor.childCDHash
        object["child_signing_identifier"] = supervisor.childSigningIdentifier
        object["child_cs_flags"] = NSNumber(value: supervisor.childCSFlags)
        object["child_checked_at_unix"] = NSNumber(value: supervisor.childCheckedAtUnix)
        object["child_channel_peer_verified"] = supervisor.childChannelPeerVerified
        return object
    }

    /// The v2 domain followed by fields 1..34 (§4.10). Byte-identical to the
    /// coordinator's `PostureStatementV2.Framing`.
    func framing() throws -> Data {
        try supervisor.validate()
        var framed = Data()
        try draft.appendFraming(to: &framed)
        for value in [
            supervisor.supervisorTeamID, supervisor.supervisorBundleID, supervisor.supervisorBundleVersion,
            supervisor.childCDHash, supervisor.childSigningIdentifier,
        ] {
            framed.psvAppendFramed(Data(value.utf8))
        }
        framed.psvAppendUnsigned64(supervisor.childCSFlags)
        framed.psvAppendUnsigned64(UInt64(bitPattern: supervisor.childCheckedAtUnix))
        framed.psvAppendUnsigned64(supervisor.childChannelPeerVerified ? 1 : 0)
        return framed
    }

    /// The §4.10 fields 30..34 rules the coordinator quarantines on. Both the
    /// supervisor (before asserting) and the child (before signing) refuse a
    /// statement that would fail them.
    var childCheckConsistent: Bool {
        supervisor.childCDHash == draft.codeCDHash
            && supervisor.childSigningIdentifier == PrivacySupervisorConstants.childSigningIdentifier
            && draft.signingIdentifier == PrivacySupervisorConstants.childSigningIdentifier
            && PrivacySupervisorConstants.childCSFlagsOK(supervisor.childCSFlags)
            && abs(supervisor.childCheckedAtUnix - draft.issuedAtUnix) <= PrivacySupervisorConstants.childCheckSkewSeconds
            && supervisor.childChannelPeerVerified
            && supervisor.supervisorBundleID == PrivacySupervisorConstants.supervisorBundleID
            && supervisor.supervisorTeamID == draft.teamID
    }
}

/// Child-owned fields of `privacy-app-attest-enrollment-v1` (§4.11 fields
/// 1..6, 10, 11).
struct PrivacyEnrollmentDraft: Equatable, Sendable {
    var version: String
    var privacyClass: String
    var providerID: String
    var assignedSession: String
    var challenge: String
    var appAttestKeyID: String
    var sePublicKey: String
    var identityPublicKey: String

    static let fieldNames: Set<String> = [
        "version", "privacy_class", "provider_id", "assigned_session", "challenge", "app_attest_key_id",
        "se_public_key", "identity_public_key",
    ]

    init(
        providerID: String,
        assignedSession: String,
        challenge: String,
        appAttestKeyID: String,
        sePublicKey: String,
        identityPublicKey: String,
        version: String = PrivacySupervisorConstants.enrollmentVersion,
        privacyClass: String = PrivacySupervisorConstants.privacyClass
    ) {
        self.version = version
        self.privacyClass = privacyClass
        self.providerID = providerID
        self.assignedSession = assignedSession
        self.challenge = challenge
        self.appAttestKeyID = appAttestKeyID
        self.sePublicKey = sePublicKey
        self.identityPublicKey = identityPublicKey
    }

    init(object: [String: Any]) throws {
        try self.init(reader: PrivacySupervisorReader(object, keys: Self.fieldNames))
    }

    fileprivate init(reader r: PrivacySupervisorReader) throws {
        self.init(
            providerID: try r.string("provider_id"),
            assignedSession: try r.string("assigned_session"),
            challenge: try r.string("challenge"),
            appAttestKeyID: try r.string("app_attest_key_id"),
            sePublicKey: try r.string("se_public_key"),
            identityPublicKey: try r.string("identity_public_key"),
            version: try r.string("version"),
            privacyClass: try r.string("privacy_class")
        )
        try validate()
    }

    var wireObject: [String: Any] {
        [
            "version": version,
            "privacy_class": privacyClass,
            "provider_id": providerID,
            "assigned_session": assignedSession,
            "challenge": challenge,
            "app_attest_key_id": appAttestKeyID,
            "se_public_key": sePublicKey,
            "identity_public_key": identityPublicKey,
        ]
    }

    func validate() throws {
        let c = PrivacySupervisorConstants.self
        guard version == c.enrollmentVersion,
              privacyClass == c.privacyClass,
              psvVisibleASCII(providerID, maxBytes: c.maxIdentifierBytes),
              psvVisibleASCII(assignedSession, maxBytes: c.maxIdentifierBytes),
              psvFixed(challenge, count: 32) != nil,
              psvFixed(appAttestKeyID, count: 32) != nil,
              psvFixed(sePublicKey, count: 64) != nil,
              psvFixed(identityPublicKey, count: 32) != nil else {
            throw PrivacySupervisorWireError.invalid
        }
    }
}

/// Supervisor-owned enrollment fields (§4.11 fields 7..9 and 12..15).
struct PrivacySupervisorEnrollmentFields: Equatable, Sendable {
    var teamID: String
    var bundleID: String
    var environment: String
    var childCDHash: String
    var childCSFlags: UInt64
    var supervisorBundleVersion: String
    var issuedAtUnix: Int64

    static let fieldNames: Set<String> = [
        "team_id", "bundle_id", "environment", "child_cdhash", "child_cs_flags", "supervisor_bundle_version",
        "issued_at_unix",
    ]

    func validate() throws {
        let c = PrivacySupervisorConstants.self
        guard psvTeamID(teamID),
              psvVisibleASCII(bundleID, maxBytes: c.maxIdentifierBytes),
              psvVisibleASCII(environment, maxBytes: c.maxIdentifierBytes),
              psvCDHash(childCDHash),
              childCSFlags <= 0xffff_ffff,
              psvVisibleASCII(supervisorBundleVersion, maxBytes: c.maxSupervisorBundleVersionBytes) else {
            throw PrivacySupervisorWireError.invalid
        }
    }
}

/// The closed `privacy-app-attest-enrollment-v1` statement (§4.11).
struct PrivacyEnrollmentStatement: Equatable, Sendable {
    var draft: PrivacyEnrollmentDraft
    var supervisor: PrivacySupervisorEnrollmentFields

    static let fieldNames = PrivacyEnrollmentDraft.fieldNames.union(PrivacySupervisorEnrollmentFields.fieldNames)

    init(draft: PrivacyEnrollmentDraft, supervisor: PrivacySupervisorEnrollmentFields) {
        self.draft = draft
        self.supervisor = supervisor
    }

    init(object: [String: Any]) throws {
        let reader = try PrivacySupervisorReader(object, keys: Self.fieldNames)
        draft = try PrivacyEnrollmentDraft(reader: reader)
        supervisor = PrivacySupervisorEnrollmentFields(
            teamID: try reader.string("team_id"),
            bundleID: try reader.string("bundle_id"),
            environment: try reader.string("environment"),
            childCDHash: try reader.string("child_cdhash"),
            childCSFlags: try reader.unsigned("child_cs_flags"),
            supervisorBundleVersion: try reader.string("supervisor_bundle_version"),
            issuedAtUnix: try reader.signed("issued_at_unix")
        )
        try supervisor.validate()
    }

    var wireObject: [String: Any] {
        var object = draft.wireObject
        object["team_id"] = supervisor.teamID
        object["bundle_id"] = supervisor.bundleID
        object["environment"] = supervisor.environment
        object["child_cdhash"] = supervisor.childCDHash
        object["child_cs_flags"] = NSNumber(value: supervisor.childCSFlags)
        object["supervisor_bundle_version"] = supervisor.supervisorBundleVersion
        object["issued_at_unix"] = NSNumber(value: supervisor.issuedAtUnix)
        return object
    }

    /// The enrollment domain followed by fields 1..15 (§4.11). Byte-identical
    /// to the coordinator's `AppAttestEnrollmentStatement.Framing`.
    func framing() throws -> Data {
        try draft.validate()
        try supervisor.validate()
        guard let challenge = psvFixed(draft.challenge, count: 32),
              let keyID = psvFixed(draft.appAttestKeyID, count: 32),
              let sePublicKey = psvFixed(draft.sePublicKey, count: 64),
              let identityPublicKey = psvFixed(draft.identityPublicKey, count: 32) else {
            throw PrivacySupervisorWireError.invalid
        }
        var framed = Data()
        for value in [PrivacySupervisorConstants.enrollmentDomain, draft.version, draft.privacyClass, draft.providerID, draft.assignedSession] {
            framed.psvAppendFramed(Data(value.utf8))
        }
        framed.psvAppendFramed(challenge)
        framed.psvAppendFramed(keyID)
        for value in [supervisor.teamID, supervisor.bundleID, supervisor.environment] {
            framed.psvAppendFramed(Data(value.utf8))
        }
        framed.psvAppendFramed(sePublicKey)
        framed.psvAppendFramed(identityPublicKey)
        framed.psvAppendFramed(Data(supervisor.childCDHash.utf8))
        framed.psvAppendUnsigned64(supervisor.childCSFlags)
        framed.psvAppendFramed(Data(supervisor.supervisorBundleVersion.utf8))
        framed.psvAppendUnsigned64(UInt64(bitPattern: supervisor.issuedAtUnix))
        return framed
    }

    /// The compiled constants and §4.1 masks the coordinator checks.
    var supervisorConsistent: Bool {
        supervisor.bundleID == PrivacySupervisorConstants.supervisorBundleID
            && supervisor.environment == PrivacySupervisorConstants.environment
            && PrivacySupervisorConstants.childCSFlagsOK(supervisor.childCSFlags)
    }
}

// MARK: - Channel messages

/// Bounded local reason codes. They never carry prompts, keys, or OS error text.
enum PrivacySupervisorErrorReason: String, Equatable, Sendable, CaseIterable {
    /// macOS older than 27, App Attest unsupported, or the supervisor is not
    /// a signed Malibu.app with the App Attest profile.
    case unsupported
    /// A transient App Attest or supervisor failure.
    case unavailable
    /// The App Attest key is unusable; the supervisor discarded it (SPEC-049-R033).
    case keyInvalid = "key_invalid"
    /// SPEC-049-R026 failed; the supervisor terminates the child.
    case childCheckFailed = "child_check_failed"
    /// The child-supplied draft disagrees with the supervisor's observations.
    case draftRejected = "draft_rejected"
}

enum PrivacySupervisorRequest: Equatable, Sendable {
    /// Returns the current keyId, generating one when none is stored. A
    /// non-nil `discard` names a keyId the coordinator retired; the supervisor
    /// deletes it first when it is still the stored one.
    case key(discard: String?)
    case attest(PrivacyEnrollmentDraft)
    case assert(PrivacyPostureV2Draft)

    static let keyType = "privacy_supervisor_key_request"
    static let attestType = "privacy_supervisor_attest_request"
    static let assertType = "privacy_supervisor_assert_request"

    var wireObject: [String: Any] {
        let version = PrivacySupervisorConstants.channelVersion
        switch self {
        case .key(let discard):
            return ["type": Self.keyType, "version": version, "discard_app_attest_key_id": discard ?? ""]
        case .attest(let draft):
            return ["type": Self.attestType, "version": version, "draft": draft.wireObject]
        case .assert(let draft):
            return ["type": Self.assertType, "version": version, "draft": draft.wireObject]
        }
    }

    init(object: [String: Any]) throws {
        guard let type = object["type"] as? String else { throw PrivacySupervisorWireError.invalid }
        switch type {
        case Self.keyType:
            let reader = try PrivacySupervisorReader(object, keys: ["type", "version", "discard_app_attest_key_id"])
            try reader.requireVersion()
            let discard = try reader.string("discard_app_attest_key_id")
            if discard.isEmpty {
                self = .key(discard: nil)
            } else {
                guard psvFixed(discard, count: 32) != nil else { throw PrivacySupervisorWireError.invalid }
                self = .key(discard: discard)
            }
        case Self.attestType:
            let reader = try PrivacySupervisorReader(object, keys: ["type", "version", "draft"])
            try reader.requireVersion()
            self = .attest(try PrivacyEnrollmentDraft(object: try reader.object("draft")))
        case Self.assertType:
            let reader = try PrivacySupervisorReader(object, keys: ["type", "version", "draft"])
            try reader.requireVersion()
            self = .assert(try PrivacyPostureV2Draft(object: try reader.object("draft")))
        default:
            throw PrivacySupervisorWireError.invalid
        }
    }
}

enum PrivacySupervisorReply: Equatable, Sendable {
    case key(appAttestKeyID: String)
    case attestation(PrivacyEnrollmentStatement, attestation: Data)
    case assertion(PrivacyPostureV2Statement, assertion: Data)
    case error(PrivacySupervisorErrorReason)

    static let keyType = "privacy_supervisor_key"
    static let attestationType = "privacy_supervisor_attestation"
    static let assertionType = "privacy_supervisor_assertion"
    static let errorType = "privacy_supervisor_error"

    var wireObject: [String: Any] {
        let version = PrivacySupervisorConstants.channelVersion
        switch self {
        case .key(let keyID):
            return ["type": Self.keyType, "version": version, "app_attest_key_id": keyID]
        case .attestation(let statement, let attestation):
            return [
                "type": Self.attestationType, "version": version, "statement": statement.wireObject,
                "attestation": PrivacySupervisorBase64URL.encode(attestation),
            ]
        case .assertion(let statement, let assertion):
            return [
                "type": Self.assertionType, "version": version, "statement": statement.wireObject,
                "assertion": PrivacySupervisorBase64URL.encode(assertion),
            ]
        case .error(let reason):
            return ["type": Self.errorType, "version": version, "reason": reason.rawValue]
        }
    }

    init(object: [String: Any]) throws {
        guard let type = object["type"] as? String else { throw PrivacySupervisorWireError.invalid }
        switch type {
        case Self.keyType:
            let reader = try PrivacySupervisorReader(object, keys: ["type", "version", "app_attest_key_id"])
            try reader.requireVersion()
            let keyID = try reader.string("app_attest_key_id")
            guard psvFixed(keyID, count: 32) != nil else { throw PrivacySupervisorWireError.invalid }
            self = .key(appAttestKeyID: keyID)
        case Self.attestationType:
            let reader = try PrivacySupervisorReader(object, keys: ["type", "version", "statement", "attestation"])
            try reader.requireVersion()
            let statement = try PrivacyEnrollmentStatement(object: try reader.object("statement"))
            guard let attestation = PrivacySupervisorBase64URL.decode(try reader.string("attestation")),
                  (1...PrivacySupervisorConstants.maxAttestationBytes).contains(attestation.count) else {
                throw PrivacySupervisorWireError.invalid
            }
            self = .attestation(statement, attestation: attestation)
        case Self.assertionType:
            let reader = try PrivacySupervisorReader(object, keys: ["type", "version", "statement", "assertion"])
            try reader.requireVersion()
            let statement = try PrivacyPostureV2Statement(object: try reader.object("statement"))
            guard let assertion = PrivacySupervisorBase64URL.decode(try reader.string("assertion")),
                  (1...PrivacySupervisorConstants.maxAssertionBytes).contains(assertion.count) else {
                throw PrivacySupervisorWireError.invalid
            }
            self = .assertion(statement, assertion: assertion)
        case Self.errorType:
            let reader = try PrivacySupervisorReader(object, keys: ["type", "version", "reason"])
            try reader.requireVersion()
            guard let reason = PrivacySupervisorErrorReason(rawValue: try reader.string("reason")) else {
                throw PrivacySupervisorWireError.invalid
            }
            self = .error(reason)
        default:
            throw PrivacySupervisorWireError.invalid
        }
    }
}

/// Channel framing: a u32 big-endian body length (1..65536) followed by the
/// body, which is the canonical JSON encoding (sorted keys, no escaped
/// slashes, no whitespace) of one closed object. The decoder re-encodes the
/// parsed object and requires the same bytes, which rejects duplicate keys,
/// non-canonical numbers, whitespace, and trailing data.
enum PrivacySupervisorFrame {
    static let headerBytes = 4

    static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw PrivacySupervisorWireError.invalid }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw PrivacySupervisorWireError.invalid
        }
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        let body = try canonicalJSON(object)
        guard (1...PrivacySupervisorConstants.maxChannelFrameBytes).contains(body.count) else {
            throw PrivacySupervisorWireError.invalid
        }
        var frame = Data()
        frame.psvAppendUnsigned32(UInt32(body.count))
        frame.append(body)
        return frame
    }

    static func bodyLength(header: Data) throws -> Int {
        guard header.count == headerBytes else { throw PrivacySupervisorWireError.invalid }
        let bytes = Array(header)
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard (1...PrivacySupervisorConstants.maxChannelFrameBytes).contains(length) else {
            throw PrivacySupervisorWireError.invalid
        }
        return length
    }

    static func decodeBody(_ body: Data) throws -> [String: Any] {
        guard (1...PrivacySupervisorConstants.maxChannelFrameBytes).contains(body.count),
              let object = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
              try canonicalJSON(object) == body else {
            throw PrivacySupervisorWireError.invalid
        }
        return object
    }

    /// Decodes one whole frame (header plus body). For tests and buffered readers.
    static func decode(_ frame: Data) throws -> [String: Any] {
        guard frame.count > headerBytes else { throw PrivacySupervisorWireError.invalid }
        let length = try bodyLength(header: frame.prefix(headerBytes))
        guard frame.count == headerBytes + length else { throw PrivacySupervisorWireError.invalid }
        return try decodeBody(frame.dropFirst(headerBytes))
    }

    /// Blocking whole-frame I/O on a stream socket. The caller sets
    /// SO_RCVTIMEO/SO_SNDTIMEO; a timeout or short read is an error.
    static func write(_ object: [String: Any], to fd: Int32) throws {
        let frame = try encode(object)
        var offset = 0
        try frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw PrivacySupervisorWireError.invalid }
            while offset < frame.count {
                let count = Darwin.write(fd, base.advanced(by: offset), frame.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PrivacySupervisorWireError.invalid }
                offset += count
            }
        }
    }

    static func read(from fd: Int32) throws -> [String: Any] {
        let header = try readExactly(fd, count: headerBytes)
        return try decodeBody(try readExactly(fd, count: try bodyLength(header: header)))
    }

    private static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw PrivacySupervisorWireError.invalid }
            while offset < count {
                let read = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw PrivacySupervisorWireError.invalid }
                offset += read
            }
        }
        return data
    }
}

// MARK: - Peer identity by kernel audit token

/// Reads the peer of a connected Unix-domain socket from the kernel and checks
/// its dynamic code identity (SPEC-049-R026 steps 1..5). The audit token comes
/// only from `LOCAL_PEERTOKEN`, never from a message.
enum PrivacySupervisorPeer {
    /// `<sys/un.h>` SOL_LOCAL and LOCAL_PEERTOKEN.
    private static let solLocal: Int32 = 0
    private static let localPeerToken: Int32 = 0x006
    /// `<sys/codesign.h>` CS_OPS_STATUS.
    private static let csOpsStatus: UInt32 = 0
    /// `<Security/SecCode.h>` kSecCSSigningInformation and kSecCSDynamicInformation.
    private static let signingInformation = SecCSFlags(rawValue: 1 << 1)
    private static let dynamicInformation = SecCSFlags(rawValue: 1 << 3)

    static func auditToken(socket fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, solLocal, localPeerToken, UnsafeMutableRawPointer(pointer), &length)
        }
        guard rc == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }

    /// `audit_token_to_pid`: element 5 of the token.
    static func pid(_ token: audit_token_t) -> pid_t { pid_t(bitPattern: token.val.5) }

    /// `audit_token_to_pidversion`: element 7 of the token.
    static func pidVersion(_ token: audit_token_t) -> UInt32 { token.val.7 }

    static func tokenData(_ token: audit_token_t) -> Data {
        withUnsafeBytes(of: token) { Data($0) }
    }

    /// The audit token of a process this process spawned, read once right after
    /// spawn so later peers can be matched by PID and PID version.
    static func auditToken(pid: pid_t) -> audit_token_t? {
        var task: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS, Self.pid(token) == pid else { return nil }
        return token
    }

    static func code(for token: audit_token_t) -> SecCode? {
        let attributes = [kSecGuestAttributeAudit as String: tokenData(token)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess else { return nil }
        return code
    }

    static func satisfies(_ code: SecCode, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    /// Identifier, team, and lowercase-hex cdhash of the running code.
    static func dynamicIdentity(_ code: SecCode) -> (identifier: String, teamID: String, cdhash: String)? {
        var information: CFDictionary?
        let staticView = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(staticView, SecCSFlags(rawValue: signingInformation.rawValue | dynamicInformation.rawValue), &information) == errSecSuccess,
              let info = information as NSDictionary?,
              let unique = info[kSecCodeInfoUnique as String] as? Data,
              unique.count == 20 else {
            return nil
        }
        return (
            info[kSecCodeInfoIdentifier as String] as? String ?? "",
            info[kSecCodeInfoTeamIdentifier as String] as? String ?? "",
            unique.map { String(format: "%02x", $0) }.joined()
        )
    }

    /// `csops_audittoken(pid, CS_OPS_STATUS, ...)`. Nil when unreadable.
    static func codeSigningFlags(_ token: audit_token_t) -> UInt32? {
        typealias CSOpsAuditToken = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<audit_token_t>?) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops_audittoken") else { return nil }
        let function = unsafeBitCast(symbol, to: CSOpsAuditToken.self)
        var flags: UInt32 = 0
        var mutableToken = token
        let rc = withUnsafeMutablePointer(to: &flags) { flagsPointer in
            withUnsafeMutablePointer(to: &mutableToken) { tokenPointer in
                function(pid(token), csOpsStatus, UnsafeMutableRawPointer(flagsPointer), MemoryLayout<UInt32>.size, tokenPointer)
            }
        }
        return rc == 0 ? flags : nil
    }

    /// Requirement text with every interpolated value restricted to a safe
    /// charset so a value can never change the requirement's grammar.
    static func requirement(identifier: String, teamID: String, cdhash: String? = nil) -> String? {
        guard psvTeamID(teamID),
              !identifier.isEmpty,
              identifier.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2e || $0 == 0x2d }) else {
            return nil
        }
        var text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        if let cdhash {
            guard psvCDHash(cdhash) else { return nil }
            text += " and cdhash H\"\(cdhash)\""
        }
        return text
    }
}

// MARK: - Encoding helpers

enum PrivacySupervisorBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Canonical unpadded base64url only.
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty,
              text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x5f }),
              text.utf8.count % 4 != 1 else {
            return nil
        }
        let remainder = text.utf8.count % 4
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)
        guard let data = Data(base64Encoded: standard), encode(data) == text else { return nil }
        return data
    }

    /// App Attest keyIds are standard base64 of 32 bytes; the wire uses base64url.
    static func fromAppAttestKeyID(_ keyID: String) -> String? {
        guard let data = Data(base64Encoded: keyID), data.count == 32, data.base64EncodedString() == keyID else {
            return nil
        }
        return encode(data)
    }

    static func toAppAttestKeyID(_ wire: String) -> String? {
        guard let data = decode(wire), data.count == 32 else { return nil }
        return data.base64EncodedString()
    }
}

private struct PrivacySupervisorReader {
    let object: [String: Any]

    init(_ object: [String: Any], keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw PrivacySupervisorWireError.invalid }
        self.object = object
    }

    func requireVersion() throws {
        guard try signed("version") == Int64(PrivacySupervisorConstants.channelVersion) else {
            throw PrivacySupervisorWireError.invalid
        }
    }

    func string(_ key: String) throws -> String {
        guard let value = object[key] as? String else { throw PrivacySupervisorWireError.invalid }
        return value
    }

    func strings(_ key: String) throws -> [String] {
        guard let values = object[key] as? [Any] else { throw PrivacySupervisorWireError.invalid }
        return try values.map { value in
            guard let text = value as? String else { throw PrivacySupervisorWireError.invalid }
            return text
        }
    }

    func object(_ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw PrivacySupervisorWireError.invalid }
        return value
    }

    func bool(_ key: String) throws -> Bool {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw PrivacySupervisorWireError.invalid
        }
        return number.boolValue
    }

    func signed(_ key: String) throws -> Int64 {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw PrivacySupervisorWireError.invalid
        }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e"), let value = Int64(text) else {
            throw PrivacySupervisorWireError.invalid
        }
        return value
    }

    func unsigned(_ key: String) throws -> UInt64 {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw PrivacySupervisorWireError.invalid
        }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e"), let value = UInt64(text) else {
            throw PrivacySupervisorWireError.invalid
        }
        return value
    }
}

private func psvFixed(_ text: String, count: Int) -> Data? {
    guard let data = PrivacySupervisorBase64URL.decode(text), data.count == count else { return nil }
    return data
}

private func psvVisibleASCII(_ value: String, maxBytes: Int) -> Bool {
    let bytes = Array(value.utf8)
    return !bytes.isEmpty && bytes.count <= maxBytes && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
}

private func psvCDHash(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 40 && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
}

private func psvTeamID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 10 && bytes.allSatisfy { ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39) }
}

private func psvDigestSet(_ values: [String]) -> Bool {
    guard values.count <= PrivacySupervisorConstants.maxKeyRecordDigests else { return false }
    for (index, value) in values.enumerated() {
        guard psvFixed(value, count: 32) != nil else { return false }
        if index > 0 && !Array(values[index - 1].utf8).lexicographicallyPrecedes(Array(value.utf8)) { return false }
    }
    return true
}

private extension Data {
    mutating func psvAppendUnsigned32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    mutating func psvAppendUnsigned64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(value >> UInt64(shift) & 0xff))
        }
    }

    mutating func psvAppendFramed(_ value: Data) {
        psvAppendUnsigned32(UInt32(value.count))
        append(value)
    }
}
