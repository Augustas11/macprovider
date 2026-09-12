import CryptoKit
import Foundation

enum ModelPreparationContractError: Error, Equatable {
    case malformed(String)
    case overLimit(limit: Int)
    case bindingMismatch(String)
}

enum ModelPreparationContracts {
    static let failedDispatchMaxBytes = 16_384
    static let eventMaxBytes = 16_384
    static let cancelAcknowledgementMaxBytes = 4_096
    static let activeRecordMaxBytes = 65_536
    static let deletionRecordMaxBytes = 32_768
    static let publicationReceiptMaxBytes = 16_384
    static let uniqueTempEnvelopeMaxBytes = 270_336
    static let reservationHistoryMaxBytes = 262_144
    static let inventoryMaxBytes = 262_144
    static let maxJavaScriptSafeInteger = 9_007_199_254_740_991
    static let maxEstimatedBytes = 1_099_511_627_776
    static let localPrepareLabel = "Prepare locally"
    static let localPrepareDetail = "Download and verify this model for local use. This does not offer it to the network or enable earnings."
    static let localPrepareConfirmation = "Download and verify {estimated_size} for local use?"
    static let trustedPrepareLabel = "Prepare model"
    static let trustedPrepareDetail = "Download and verify this model from the trusted catalog. Preparation does not offer it to the network, change the running model, or guarantee earnings."
    static let trustedPrepareConfirmation = "Download and verify {estimated_size} from the trusted catalog?"
    static let cleanupConfirmation = "Remove this verified prepared model ({reclaimable_size} of managed data)? The current model and legacy model files will be kept."
    static let settlementCapableMeaning = "Eligible to earn on qualifying settled requests"
    static let localOnlyMeaning = "Retained as local inventory only; this admission state does not claim the model is prepared, installed, ready, reachable, or usable."
    static let localDefaultNotOfferedMeaning = "Coordinator offer state is unavailable or has not been queried."
    static let coordinatorNotOfferedMeaning = "Coordinator reports no active network offer for this model."

    static func rootIdentityDigest(version: String, nonceHex: String, canonicalPath: String, stDev: UInt64, stIno: UInt64) throws -> String {
        guard let nonce = Data(hexString: nonceHex), nonce.count == 32 else {
            throw ModelPreparationContractError.malformed("root nonce")
        }
        var data = Data()
        data.appendLengthPrefixedUTF8("macprovider.model_catalog.root_identity.v2")
        data.appendLengthPrefixedUTF8(version)
        data.appendLengthPrefixedUTF8(canonicalPath)
        data.append(nonce)
        data.appendUInt64BE(stDev)
        data.appendUInt64BE(stIno)
        return data.sha256Hex()
    }

    static func artifactIdentityDigest(
        displayModelID: String,
        modelRevision: String,
        artifactID: String,
        releaseID: String,
        rootIdentityDigest: String,
        receiptSHA256: String
    ) throws -> String {
        try requireHex64(rootIdentityDigest, field: "root_identity_digest")
        try requireHex64(receiptSHA256, field: "receipt_sha256")
        var data = Data()
        data.appendLengthPrefixedUTF8("macprovider.model_catalog.artifact_identity.v1")
        data.appendLengthPrefixedUTF8(displayModelID)
        data.appendLengthPrefixedUTF8(modelRevision)
        data.appendLengthPrefixedUTF8(artifactID)
        data.appendLengthPrefixedUTF8(releaseID)
        data.appendLengthPrefixedUTF8(rootIdentityDigest)
        data.appendLengthPrefixedUTF8(receiptSHA256)
        return data.sha256Hex()
    }


    static func tupleSHA256(_ tuple: ModelPreparationTupleRecord) throws -> String {
        try encode(tuple).sha256Hex()
    }

    static func receiptSHA256(_ receipt: ModelPreparationPublicationReceipt) throws -> String {
        try encode(receipt, maxBytes: publicationReceiptMaxBytes).sha256Hex()
    }

    static func sha256Hex(for data: Data) -> String {
        data.sha256Hex()
    }

    static func requireCanonicalRFC3339(_ value: String, field: String) throws {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw ModelPreparationContractError.malformed(field)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw ModelPreparationContractError.malformed(field)
        }
    }

    static func requireNonNegativeSafeInteger(_ value: Int64, field: String) throws {
        guard value >= 0 && value <= maxJavaScriptSafeInteger else {
            throw ModelPreparationContractError.malformed(field)
        }
    }

    static func requireNonNegativeSafeInteger(_ value: Int, field: String) throws {
        guard value >= 0 && value <= maxJavaScriptSafeInteger else {
            throw ModelPreparationContractError.malformed(field)
        }
    }

    static func requirePathLeaf(_ value: String, field: String, maxUTF8Bytes: Int = 128) throws {
        try requireSafeString(value, field: field, maxUTF8Bytes: maxUTF8Bytes)
        guard value != ".", value != "..",
              !value.hasPrefix("/"),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("..") else {
            throw ModelPreparationContractError.malformed(field)
        }
    }

    static func encode<T: Encodable>(_ value: T, maxBytes: Int? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        if let maxBytes, data.count > maxBytes {
            throw ModelPreparationContractError.overLimit(limit: maxBytes)
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, maxBytes: Int) throws -> T {
        guard data.count <= maxBytes else { throw ModelPreparationContractError.overLimit(limit: maxBytes) }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ModelPreparationContractError.malformed("invalid utf8")
        }
        var scanner = ModelPreparationJSONDuplicateKeyScanner(data)
        try scanner.validate()
        var numberScanner = ModelPreparationJSONNumberTokenScanner(data)
        try numberScanner.validate()
        try ModelPreparationJSONShapeValidator.validate(data)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    static func validateCleanupBinding(rowAction: ModelPreparationAction, target: ModelPreparationCleanupTarget) throws {
        let rowJCS = try rowAction.jcsValue().canonicalRawUTF8()
        let targetJCS = try target.cleanup.jcsValue().canonicalRawUTF8()
        guard rowJCS == targetJCS else {
            throw ModelPreparationContractError.bindingMismatch("cleanup action jcs")
        }
        try validateActionTargetBinding(rowAction, target: target)
        try validateActionTargetBinding(target.cleanup, target: target)
    }

    static func validateActionTargetBinding(_ action: ModelPreparationAction, target: ModelPreparationCleanupTarget) throws {
        guard action.artifactIdentityDigest == target.artifactIdentityDigest else {
            throw ModelPreparationContractError.bindingMismatch("artifact_identity_digest")
        }
        guard action.estimatedBytes == target.estimatedBytes else {
            throw ModelPreparationContractError.bindingMismatch("estimated_bytes")
        }
    }

    static func requireUUIDv4(_ value: String, field: String) throws {
        guard value.utf8.count == 36,
              value.lowercased() == value,
              UUID(uuidString: value) != nil else {
            throw ModelPreparationContractError.malformed(field)
        }
        let scalars = Array(value)
        guard scalars[14] == "4",
              ["8", "9", "a", "b"].contains(String(scalars[19])) else {
            throw ModelPreparationContractError.malformed(field)
        }
    }

    static func requireHex64(_ value: String, field: String) throws {
        guard value.count == 64, value.lowercased() == value,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw ModelPreparationContractError.malformed(field)
        }
    }

    static func requireSafeString(_ value: String, field: String, maxUTF8Bytes: Int = 1_024, allowEmpty: Bool = false) throws {
        guard (allowEmpty || !value.isEmpty), value.utf8.count <= maxUTF8Bytes else {
            throw ModelPreparationContractError.malformed(field)
        }
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
        }) else {
            throw ModelPreparationContractError.malformed(field)
        }
    }
}

enum ModelPreparationTransactionKind: String, Codable, CaseIterable, Sendable {
    case switchModel = "switch_model"
    case switchModelDeferred = "switch_model_deferred"
    case prepareModel = "prepare_model"
    case evaluateModel = "evaluate_model"
    case adoptRecommendation = "adopt_recommendation"
    case cleanupStaging = "cleanup_staging"
    case cleanupPublishedArtifact = "cleanup_published_artifact"
}

enum ModelPreparationRuntimeState: String, Codable, CaseIterable, Sendable {
    case current
    case ready
    case catalog
    case needsPreparation = "needs_preparation"
    case blocked
}

enum ModelPreparationFit: String, Codable, CaseIterable, Sendable {
    case fits
    case doesNotFit = "does_not_fit"
    case unknown
}

enum ModelPreparationAdmissionSource: String, Codable, CaseIterable, Sendable {
    case localDefault = "local_default"
    case coordinator
}

enum ModelPreparationAdmissionState: String, Codable, CaseIterable, Sendable {
    case localOnly = "local_only"
    case notOffered = "not_offered"
    case offerable
    case offerSubmitted = "offer_submitted"
    case offerRejected = "offer_rejected"
    case sandboxProbeOnly = "sandbox_probe_only"
    case networkVisibleUnpriced = "network_visible_unpriced"
    case networkAdmittedUnsettled = "network_admitted_unsettled"
    case catalogPriced = "catalog_priced"
    case settlementCapable = "settlement_capable"
    case withdrawn
    case revoked
}

enum ModelPreparationEconomicsState: String, Codable, CaseIterable, Sendable {
    case trusted
    case fallback
    case stale
    case blocked
    case unavailable
}

enum ModelPreparationRateSource: String, Codable, CaseIterable, Sendable {
    case liveSigned = "live_signed"
    case staticSigned = "static_signed"
    case none
}

enum ModelPreparationEventState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case cancelRequested = "cancel_requested"
    case cancelled
    case succeeded
    case failed
    case timedOut = "timed_out"
}

enum ModelPreparationEventErrorCode: String, Codable, CaseIterable, Sendable {
    case actionUnavailable = "action_unavailable"
    case staleTransaction = "stale_transaction"
    case operationConflict = "operation_conflict"
    case authorityUnavailable = "authority_unavailable"
    case artifactUnqualified = "artifact_unqualified"
    case artifactIdentityMismatch = "artifact_identity_mismatch"
    case rootUnavailable = "root_unavailable"
    case rootIdentityMismatch = "root_identity_mismatch"
    case unsafeFilesystemObject = "unsafe_filesystem_object"
    case resourceLimitExceeded = "resource_limit_exceeded"
    case insufficientDiskSpace = "insufficient_disk_space"
    case managedBudgetExceeded = "managed_budget_exceeded"
    case managedObjectLimitExceeded = "managed_object_limit_exceeded"
    case managedInventoryInvalid = "managed_inventory_invalid"
    case transferFailed = "transfer_failed"
    case transferSizeExceeded = "transfer_size_exceeded"
    case verificationFailed = "verification_failed"
    case publicationFailed = "publication_failed"
    case cleanupFailed = "cleanup_failed"
    case cancelFailed = "cancel_failed"
    case timedOut = "timed_out"
    case internalError = "internal_error"
}

enum ModelPreparationEventWarningCode: String, Codable, CaseIterable, Sendable {
    case stagingCleanupRequired = "staging_cleanup_required"
    case publishedCleanupAvailable = "published_cleanup_available"
    case configuredLegacyAccountingUnavailable = "configured_legacy_accounting_unavailable"
    case managedInventoryOverflow = "managed_inventory_overflow"
    case cancellationPending = "cancellation_pending"
}

enum ModelPreparationFailedDispatchErrorCode: String, Codable, CaseIterable, Sendable {
    case staleTransaction = "stale_transaction"
    case actionUnavailable = "action_unavailable"
    case operationConflict = "operation_conflict"
}

enum ModelPreparationCancelOutcome: String, Codable, CaseIterable, Sendable {
    case recorded
    case alreadyRecorded = "already_recorded"
    case terminal
    case notActive = "not_active"
    case stale
    case busy
}

enum ModelPreparationKeepSetStatus: String, Codable, CaseIterable, Sendable {
    case protected
    case reclaimable
}

enum ModelPreparationCleanupPhase: String, Codable, CaseIterable, Sendable {
    case intent
    case tombstoned
    case removed
}

enum ModelPreparationCleanupTargetKind: String, Codable, CaseIterable, Sendable {
    case published
    case staging
}

enum ModelPreparationHistoryTerminalState: String, Codable, CaseIterable, Sendable {
    case failed
    case cancelled
    case succeeded
    case timedOut = "timed_out"
}


enum ModelPreparationActivePhase: String, Codable, CaseIterable, Sendable {
    case queued
    case transferring
    case verifying
    case publishing
    case cleanup
    case terminal
}

struct ModelPreparationRootLocator: Codable, Equatable, Sendable {
    let canonicalPath: String
    let stDev: UInt64
    let stIno: UInt64
    let identityVersion: String
    let rootIdentityDigest: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case canonicalPath = "canonical_path"
        case stDev = "st_dev"
        case stIno = "st_ino"
        case identityVersion = "identity_version"
        case rootIdentityDigest = "root_identity_digest"
    }

    init(canonicalPath: String, stDev: UInt64, stIno: UInt64, identityVersion: String, rootIdentityDigest: String) throws {
        try ModelPreparationContracts.requireSafeString(canonicalPath, field: "canonical_path")
        guard canonicalPath.hasPrefix("/") else { throw ModelPreparationContractError.malformed("canonical_path") }
        guard identityVersion == "model_catalog_root_identity.v1" else {
            throw ModelPreparationContractError.malformed("identity_version")
        }
        try ModelPreparationContracts.requireHex64(rootIdentityDigest, field: "root_identity_digest")
        self.canonicalPath = canonicalPath
        self.stDev = stDev
        self.stIno = stIno
        self.identityVersion = identityVersion
        self.rootIdentityDigest = rootIdentityDigest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            canonicalPath: try container.decode(String.self, forKey: .canonicalPath),
            stDev: try container.decode(UInt64.self, forKey: .stDev),
            stIno: try container.decode(UInt64.self, forKey: .stIno),
            identityVersion: try container.decode(String.self, forKey: .identityVersion),
            rootIdentityDigest: try container.decode(String.self, forKey: .rootIdentityDigest)
        )
    }
}

struct ModelPreparationRootIdentityRecord: Codable, Equatable, Sendable {
    let version: String
    let nonceHex: String
    let canonicalPath: String
    let stDev: UInt64
    let stIno: UInt64

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case nonceHex = "nonce_hex"
        case canonicalPath = "canonical_path"
        case stDev = "st_dev"
        case stIno = "st_ino"
    }

    var digest: String {
        get throws {
            try ModelPreparationContracts.rootIdentityDigest(
                version: version,
                nonceHex: nonceHex,
                canonicalPath: canonicalPath,
                stDev: stDev,
                stIno: stIno
            )
        }
    }

    init(version: String, nonceHex: String, canonicalPath: String, stDev: UInt64, stIno: UInt64) throws {
        guard version == "model_catalog_root_identity.v1" else {
            throw ModelPreparationContractError.malformed("version")
        }
        try ModelPreparationContracts.requireHex64(nonceHex, field: "nonce_hex")
        try ModelPreparationContracts.requireSafeString(canonicalPath, field: "canonical_path")
        guard canonicalPath.hasPrefix("/") else { throw ModelPreparationContractError.malformed("canonical_path") }
        self.version = version
        self.nonceHex = nonceHex
        self.canonicalPath = canonicalPath
        self.stDev = stDev
        self.stIno = stIno
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            version: try container.decode(String.self, forKey: .version),
            nonceHex: try container.decode(String.self, forKey: .nonceHex),
            canonicalPath: try container.decode(String.self, forKey: .canonicalPath),
            stDev: try container.decode(UInt64.self, forKey: .stDev),
            stIno: try container.decode(UInt64.self, forKey: .stIno)
        )
    }
}

struct ModelPreparationAction: Codable, Equatable, Sendable {
    let available: Bool
    let requiresConfirmation: Bool
    let transactionKind: ModelPreparationTransactionKind?
    let transactionID: String?
    let actionTimeoutSeconds: Int?
    let estimatedBytes: Int64?
    let unavailableReason: String?
    let artifactIdentityDigest: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case available
        case requiresConfirmation = "requires_confirmation"
        case transactionKind = "transaction_kind"
        case transactionID = "transaction_id"
        case actionTimeoutSeconds = "action_timeout_seconds"
        case estimatedBytes = "estimated_bytes"
        case unavailableReason = "unavailable_reason"
        case artifactIdentityDigest = "artifact_identity_digest"
    }

    init(
        available: Bool,
        requiresConfirmation: Bool,
        transactionKind: ModelPreparationTransactionKind?,
        transactionID: String?,
        actionTimeoutSeconds: Int?,
        estimatedBytes: Int64?,
        unavailableReason: String?,
        artifactIdentityDigest: String?
    ) throws {
        if available {
            guard let transactionKind, let transactionID, let actionTimeoutSeconds else {
                throw ModelPreparationContractError.malformed("available action")
            }
            try ModelPreparationContracts.requireUUIDv4(transactionID, field: "transaction_id")
            guard actionTimeoutSeconds > 0 && actionTimeoutSeconds <= 1_800 else {
                throw ModelPreparationContractError.malformed("action_timeout_seconds")
            }
            let mustConfirm: Bool
            switch transactionKind {
            case .switchModel, .switchModelDeferred, .prepareModel, .cleanupStaging, .adoptRecommendation, .cleanupPublishedArtifact:
                mustConfirm = true
            case .evaluateModel:
                mustConfirm = estimatedBytes != nil || actionTimeoutSeconds > 10
            }
            if mustConfirm, requiresConfirmation == false {
                throw ModelPreparationContractError.malformed("requires_confirmation")
            }
            switch transactionKind {
            case .prepareModel:
                guard let estimatedBytes, estimatedBytes > 0, estimatedBytes <= ModelPreparationContracts.maxEstimatedBytes else {
                    throw ModelPreparationContractError.malformed("estimated_bytes")
                }
            case .adoptRecommendation, .evaluateModel:
                if let estimatedBytes {
                    guard estimatedBytes > 0, estimatedBytes <= ModelPreparationContracts.maxEstimatedBytes else {
                        throw ModelPreparationContractError.malformed("estimated_bytes")
                    }
                }
            case .cleanupPublishedArtifact:
                guard let artifactIdentityDigest else {
                    throw ModelPreparationContractError.malformed("artifact_identity_digest")
                }
                try ModelPreparationContracts.requireHex64(artifactIdentityDigest, field: "artifact_identity_digest")
                guard let estimatedBytes, estimatedBytes > 0, estimatedBytes <= ModelPreparationContracts.maxEstimatedBytes else {
                    throw ModelPreparationContractError.malformed("estimated_bytes")
                }
            case .switchModel, .switchModelDeferred, .cleanupStaging:
                if let estimatedBytes {
                    guard estimatedBytes > 0, estimatedBytes <= ModelPreparationContracts.maxEstimatedBytes else {
                        throw ModelPreparationContractError.malformed("estimated_bytes")
                    }
                }
            }
            if transactionKind != .cleanupPublishedArtifact, artifactIdentityDigest != nil {
                throw ModelPreparationContractError.malformed("artifact_identity_digest")
            }
            guard unavailableReason == nil else {
                throw ModelPreparationContractError.malformed("unavailable_reason")
            }
        } else {
            guard transactionKind == nil, transactionID == nil, actionTimeoutSeconds == nil, estimatedBytes == nil, artifactIdentityDigest == nil else {
                throw ModelPreparationContractError.malformed("unavailable action")
            }
            guard let unavailableReason else {
                throw ModelPreparationContractError.malformed("unavailable_reason")
            }
            try ModelPreparationContracts.requireSafeString(unavailableReason, field: "unavailable_reason", maxUTF8Bytes: 512)
        }
        self.available = available
        self.requiresConfirmation = requiresConfirmation
        self.transactionKind = transactionKind
        self.transactionID = transactionID
        self.actionTimeoutSeconds = actionTimeoutSeconds
        self.estimatedBytes = estimatedBytes
        self.unavailableReason = unavailableReason
        self.artifactIdentityDigest = artifactIdentityDigest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            available: try container.decode(Bool.self, forKey: .available),
            requiresConfirmation: try container.decode(Bool.self, forKey: .requiresConfirmation),
            transactionKind: try container.decodeRequiredNullable(ModelPreparationTransactionKind.self, forKey: .transactionKind),
            transactionID: try container.decodeRequiredNullable(String.self, forKey: .transactionID),
            actionTimeoutSeconds: try container.decodeRequiredNullable(Int.self, forKey: .actionTimeoutSeconds),
            estimatedBytes: try container.decodeRequiredNullable(Int64.self, forKey: .estimatedBytes),
            unavailableReason: try container.decodeRequiredNullable(String.self, forKey: .unavailableReason),
            artifactIdentityDigest: try container.decodeRequiredNullable(String.self, forKey: .artifactIdentityDigest)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(requiresConfirmation, forKey: .requiresConfirmation)
        try container.encodeNullable(transactionKind, forKey: .transactionKind)
        try container.encodeNullable(transactionID, forKey: .transactionID)
        try container.encodeNullable(actionTimeoutSeconds, forKey: .actionTimeoutSeconds)
        try container.encodeNullable(estimatedBytes, forKey: .estimatedBytes)
        try container.encodeNullable(unavailableReason, forKey: .unavailableReason)
        try container.encodeNullable(artifactIdentityDigest, forKey: .artifactIdentityDigest)
    }

    func jcsValue() -> RFC8785JCS.Value {
        .object([
            "action_timeout_seconds": actionTimeoutSeconds.map { .int($0) } ?? .null,
            "artifact_identity_digest": artifactIdentityDigest.map { .rawString($0) } ?? .null,
            "available": .bool(available),
            "estimated_bytes": estimatedBytes.map { .int(Int($0)) } ?? .null,
            "requires_confirmation": .bool(requiresConfirmation),
            "transaction_id": transactionID.map { .rawString($0) } ?? .null,
            "transaction_kind": transactionKind.map { .rawString($0.rawValue) } ?? .null,
            "unavailable_reason": unavailableReason.map { .rawString($0) } ?? .null,
        ])
    }
}

struct ModelPreparationCleanupTarget: Codable, Equatable, Sendable {
    let artifactIdentityDigest: String
    let displayModelID: String
    let modelRevision: String
    let artifactID: String
    let releaseID: String
    let modelKey: String?
    let eventModelKey: String
    let rootIdentityDigest: String
    let receiptSHA256: String
    let estimatedBytes: Int64
    let keepSetStatus: ModelPreparationKeepSetStatus
    let protectedReason: String?
    let cleanup: ModelPreparationAction

    enum CodingKeys: String, CodingKey, CaseIterable {
        case artifactIdentityDigest = "artifact_identity_digest"
        case displayModelID = "display_model_id"
        case modelRevision = "model_revision"
        case artifactID = "artifact_id"
        case releaseID = "release_id"
        case modelKey = "model_key"
        case eventModelKey = "event_model_key"
        case rootIdentityDigest = "root_identity_digest"
        case receiptSHA256 = "receipt_sha256"
        case estimatedBytes = "estimated_bytes"
        case keepSetStatus = "keep_set_status"
        case protectedReason = "protected_reason"
        case cleanup
    }

    init(
        artifactIdentityDigest: String,
        displayModelID: String,
        modelRevision: String,
        artifactID: String,
        releaseID: String,
        modelKey: String?,
        eventModelKey: String,
        rootIdentityDigest: String,
        receiptSHA256: String,
        estimatedBytes: Int64,
        keepSetStatus: ModelPreparationKeepSetStatus,
        protectedReason: String?,
        cleanup: ModelPreparationAction
    ) throws {
        try ModelPreparationContracts.requireHex64(artifactIdentityDigest, field: "artifact_identity_digest")
        try ModelPreparationContracts.requireHex64(rootIdentityDigest, field: "root_identity_digest")
        try ModelPreparationContracts.requireHex64(receiptSHA256, field: "receipt_sha256")
        try ModelPreparationContracts.requireSafeString(displayModelID, field: "display_model_id")
        try ModelPreparationContracts.requireSafeString(modelRevision, field: "model_revision")
        try ModelPreparationContracts.requireSafeString(artifactID, field: "artifact_id")
        try ModelPreparationContracts.requireSafeString(releaseID, field: "release_id")
        let expectedArtifactIdentityDigest = try ModelPreparationContracts.artifactIdentityDigest(
            displayModelID: displayModelID,
            modelRevision: modelRevision,
            artifactID: artifactID,
            releaseID: releaseID,
            rootIdentityDigest: rootIdentityDigest,
            receiptSHA256: receiptSHA256
        )
        guard artifactIdentityDigest == expectedArtifactIdentityDigest else {
            throw ModelPreparationContractError.bindingMismatch("artifact_identity_digest")
        }
        try ModelPreparationContracts.requireSafeString(eventModelKey, field: "event_model_key")
        if let modelKey { try ModelPreparationContracts.requireSafeString(modelKey, field: "model_key") }
        try ModelPreparationContracts.requireNonNegativeSafeInteger(estimatedBytes, field: "estimated_bytes")
        switch keepSetStatus {
        case .protected:
            guard let protectedReason, !cleanup.available else {
                throw ModelPreparationContractError.malformed("protected cleanup")
            }
            try ModelPreparationContracts.requireSafeString(protectedReason, field: "protected_reason", maxUTF8Bytes: 512)
        case .reclaimable:
            guard protectedReason == nil, estimatedBytes > 0, cleanup.available, cleanup.transactionKind == .cleanupPublishedArtifact else {
                throw ModelPreparationContractError.malformed("reclaimable cleanup")
            }
            guard cleanup.artifactIdentityDigest == artifactIdentityDigest,
                  cleanup.estimatedBytes == estimatedBytes else {
                throw ModelPreparationContractError.bindingMismatch("cleanup")
            }
        }
        self.artifactIdentityDigest = artifactIdentityDigest
        self.displayModelID = displayModelID
        self.modelRevision = modelRevision
        self.artifactID = artifactID
        self.releaseID = releaseID
        self.modelKey = modelKey
        self.eventModelKey = eventModelKey
        self.rootIdentityDigest = rootIdentityDigest
        self.receiptSHA256 = receiptSHA256
        self.estimatedBytes = estimatedBytes
        self.keepSetStatus = keepSetStatus
        self.protectedReason = protectedReason
        self.cleanup = cleanup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            artifactIdentityDigest: try container.decode(String.self, forKey: .artifactIdentityDigest),
            displayModelID: try container.decode(String.self, forKey: .displayModelID),
            modelRevision: try container.decode(String.self, forKey: .modelRevision),
            artifactID: try container.decode(String.self, forKey: .artifactID),
            releaseID: try container.decode(String.self, forKey: .releaseID),
            modelKey: try container.decodeRequiredNullable(String.self, forKey: .modelKey),
            eventModelKey: try container.decode(String.self, forKey: .eventModelKey),
            rootIdentityDigest: try container.decode(String.self, forKey: .rootIdentityDigest),
            receiptSHA256: try container.decode(String.self, forKey: .receiptSHA256),
            estimatedBytes: try container.decode(Int64.self, forKey: .estimatedBytes),
            keepSetStatus: try container.decode(ModelPreparationKeepSetStatus.self, forKey: .keepSetStatus),
            protectedReason: try container.decodeRequiredNullable(String.self, forKey: .protectedReason),
            cleanup: try container.decode(ModelPreparationAction.self, forKey: .cleanup)
        )
    }
}

struct ModelPreparationTupleRecord: Codable, Equatable, Sendable {
    let schema: String
    let tupleID: String
    let eventModelKey: String
    let displayModelID: String
    let modelRevision: String
    let artifactID: String
    let releaseID: String
    let artifactSHA256: String
    let estimatedBytes: Int64
    let root: ModelPreparationRootLocator
    let authorityOrder: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case tupleID = "tuple_id"
        case eventModelKey = "event_model_key"
        case displayModelID = "display_model_id"
        case modelRevision = "model_revision"
        case artifactID = "artifact_id"
        case releaseID = "release_id"
        case artifactSHA256 = "artifact_sha256"
        case estimatedBytes = "estimated_bytes"
        case root
        case authorityOrder = "authority_order"
    }

    init(
        schema: String = "model_catalog_preparation_tuple.v1",
        tupleID: String,
        eventModelKey: String,
        displayModelID: String,
        modelRevision: String,
        artifactID: String,
        releaseID: String,
        artifactSHA256: String,
        estimatedBytes: Int64,
        root: ModelPreparationRootLocator,
        authorityOrder: Int
    ) throws {
        guard schema == "model_catalog_preparation_tuple.v1" else { throw ModelPreparationContractError.malformed("schema") }
        try ModelPreparationContracts.requireSafeString(tupleID, field: "tuple_id")
        try ModelPreparationContracts.requireSafeString(eventModelKey, field: "event_model_key")
        try ModelPreparationContracts.requireSafeString(displayModelID, field: "display_model_id")
        try ModelPreparationContracts.requireSafeString(modelRevision, field: "model_revision")
        try ModelPreparationContracts.requireSafeString(artifactID, field: "artifact_id")
        try ModelPreparationContracts.requireSafeString(releaseID, field: "release_id")
        try ModelPreparationContracts.requireHex64(artifactSHA256, field: "artifact_sha256")
        guard estimatedBytes > 0 && estimatedBytes <= ModelPreparationContracts.maxEstimatedBytes else {
            throw ModelPreparationContractError.malformed("estimated_bytes")
        }
        guard authorityOrder >= 0 && authorityOrder < 256 else {
            throw ModelPreparationContractError.malformed("authority_order")
        }
        self.schema = schema
        self.tupleID = tupleID
        self.eventModelKey = eventModelKey
        self.displayModelID = displayModelID
        self.modelRevision = modelRevision
        self.artifactID = artifactID
        self.releaseID = releaseID
        self.artifactSHA256 = artifactSHA256
        self.estimatedBytes = estimatedBytes
        self.root = root
        self.authorityOrder = authorityOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            tupleID: try container.decode(String.self, forKey: .tupleID),
            eventModelKey: try container.decode(String.self, forKey: .eventModelKey),
            displayModelID: try container.decode(String.self, forKey: .displayModelID),
            modelRevision: try container.decode(String.self, forKey: .modelRevision),
            artifactID: try container.decode(String.self, forKey: .artifactID),
            releaseID: try container.decode(String.self, forKey: .releaseID),
            artifactSHA256: try container.decode(String.self, forKey: .artifactSHA256),
            estimatedBytes: try container.decode(Int64.self, forKey: .estimatedBytes),
            root: try container.decode(ModelPreparationRootLocator.self, forKey: .root),
            authorityOrder: try container.decode(Int.self, forKey: .authorityOrder)
        )
    }
}

struct ModelPreparationReservationRecord: Codable, Equatable, Sendable {
    let schema: String
    let transactionID: String
    let transactionKind: ModelPreparationTransactionKind
    let eventModelKey: String
    let root: ModelPreparationRootLocator
    let tuple: ModelPreparationTupleRecord
    let tupleSHA256: String
    let projectionBindingSHA256: String
    let createdAt: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case transactionID = "transaction_id"
        case transactionKind = "transaction_kind"
        case eventModelKey = "event_model_key"
        case root
        case tuple
        case tupleSHA256 = "tuple_sha256"
        case projectionBindingSHA256 = "projection_binding_sha256"
        case createdAt = "created_at"
    }

    init(
        schema: String = "model_catalog_reservation.v3",
        transactionID: String,
        transactionKind: ModelPreparationTransactionKind,
        eventModelKey: String,
        root: ModelPreparationRootLocator,
        tuple: ModelPreparationTupleRecord,
        tupleSHA256: String,
        projectionBindingSHA256: String,
        createdAt: String
    ) throws {
        guard schema == "model_catalog_reservation.v3" else { throw ModelPreparationContractError.malformed("schema") }
        try ModelPreparationContracts.requireUUIDv4(transactionID, field: "transaction_id")
        try ModelPreparationContracts.requireSafeString(eventModelKey, field: "event_model_key")
        guard eventModelKey == tuple.eventModelKey else {
            throw ModelPreparationContractError.bindingMismatch("event_model_key")
        }
        guard root == tuple.root else {
            throw ModelPreparationContractError.bindingMismatch("root")
        }
        try ModelPreparationContracts.requireHex64(tupleSHA256, field: "tuple_sha256")
        let expectedTupleSHA256 = try ModelPreparationContracts.tupleSHA256(tuple)
        guard tupleSHA256 == expectedTupleSHA256 else {
            throw ModelPreparationContractError.bindingMismatch("tuple_sha256")
        }
        try ModelPreparationContracts.requireHex64(projectionBindingSHA256, field: "projection_binding_sha256")
        try ModelPreparationContracts.requireCanonicalRFC3339(createdAt, field: "created_at")
        self.schema = schema
        self.transactionID = transactionID
        self.transactionKind = transactionKind
        self.eventModelKey = eventModelKey
        self.root = root
        self.tuple = tuple
        self.tupleSHA256 = tupleSHA256
        self.projectionBindingSHA256 = projectionBindingSHA256
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            transactionID: try container.decode(String.self, forKey: .transactionID),
            transactionKind: try container.decode(ModelPreparationTransactionKind.self, forKey: .transactionKind),
            eventModelKey: try container.decode(String.self, forKey: .eventModelKey),
            root: try container.decode(ModelPreparationRootLocator.self, forKey: .root),
            tuple: try container.decode(ModelPreparationTupleRecord.self, forKey: .tuple),
            tupleSHA256: try container.decode(String.self, forKey: .tupleSHA256),
            projectionBindingSHA256: try container.decode(String.self, forKey: .projectionBindingSHA256),
            createdAt: try container.decode(String.self, forKey: .createdAt)
        )
    }
}

struct ModelPreparationFailedDispatchRecord: Codable, Equatable, Sendable {
    let schema: String
    let transactionID: String
    let attemptID: String
    let transactionKind: ModelPreparationTransactionKind
    let eventModelKey: String
    let root: ModelPreparationRootLocator
    let tupleSHA256: String
    let projectionBindingSHA256: String
    let eventSequence: Int
    let terminalState: ModelPreparationHistoryTerminalState
    let errorCode: ModelPreparationFailedDispatchErrorCode
    let liveAttempt: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case transactionID = "transaction_id"
        case attemptID = "attempt_id"
        case transactionKind = "transaction_kind"
        case eventModelKey = "event_model_key"
        case root
        case tupleSHA256 = "tuple_sha256"
        case projectionBindingSHA256 = "projection_binding_sha256"
        case eventSequence = "event_sequence"
        case terminalState = "terminal_state"
        case errorCode = "error_code"
        case liveAttempt = "live_attempt"
    }

    init(
        schema: String = "model_catalog_failed_dispatch.v1",
        transactionID: String,
        attemptID: String,
        transactionKind: ModelPreparationTransactionKind,
        eventModelKey: String,
        root: ModelPreparationRootLocator,
        tupleSHA256: String,
        projectionBindingSHA256: String,
        eventSequence: Int = 1,
        terminalState: ModelPreparationHistoryTerminalState = .failed,
        errorCode: ModelPreparationFailedDispatchErrorCode,
        liveAttempt: Bool = false
    ) throws {
        guard schema == "model_catalog_failed_dispatch.v1" else { throw ModelPreparationContractError.malformed("schema") }
        try ModelPreparationContracts.requireUUIDv4(transactionID, field: "transaction_id")
        try ModelPreparationContracts.requireUUIDv4(attemptID, field: "attempt_id")
        try ModelPreparationContracts.requireSafeString(eventModelKey, field: "event_model_key")
        try ModelPreparationContracts.requireHex64(tupleSHA256, field: "tuple_sha256")
        try ModelPreparationContracts.requireHex64(projectionBindingSHA256, field: "projection_binding_sha256")
        guard eventSequence == 1, terminalState == .failed, liveAttempt == false else {
            throw ModelPreparationContractError.malformed("failed dispatch terminal")
        }
        self.schema = schema
        self.transactionID = transactionID
        self.attemptID = attemptID
        self.transactionKind = transactionKind
        self.eventModelKey = eventModelKey
        self.root = root
        self.tupleSHA256 = tupleSHA256
        self.projectionBindingSHA256 = projectionBindingSHA256
        self.eventSequence = eventSequence
        self.terminalState = terminalState
        self.errorCode = errorCode
        self.liveAttempt = liveAttempt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            transactionID: try container.decode(String.self, forKey: .transactionID),
            attemptID: try container.decode(String.self, forKey: .attemptID),
            transactionKind: try container.decode(ModelPreparationTransactionKind.self, forKey: .transactionKind),
            eventModelKey: try container.decode(String.self, forKey: .eventModelKey),
            root: try container.decode(ModelPreparationRootLocator.self, forKey: .root),
            tupleSHA256: try container.decode(String.self, forKey: .tupleSHA256),
            projectionBindingSHA256: try container.decode(String.self, forKey: .projectionBindingSHA256),
            eventSequence: try container.decode(Int.self, forKey: .eventSequence),
            terminalState: try container.decode(ModelPreparationHistoryTerminalState.self, forKey: .terminalState),
            errorCode: try container.decode(ModelPreparationFailedDispatchErrorCode.self, forKey: .errorCode),
            liveAttempt: try container.decode(Bool.self, forKey: .liveAttempt)
        )
    }
}

struct ModelPreparationActiveCounters: Codable, Equatable, Sendable {
    let bytesCompleted: Int64
    let bytesExpected: Int64
    let filesCompleted: Int
    let filesExpected: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case bytesCompleted = "bytes_completed"
        case bytesExpected = "bytes_expected"
        case filesCompleted = "files_completed"
        case filesExpected = "files_expected"
    }

    init(bytesCompleted: Int64, bytesExpected: Int64, filesCompleted: Int, filesExpected: Int) throws {
        try ModelPreparationContracts.requireNonNegativeSafeInteger(bytesCompleted, field: "bytes_completed")
        try ModelPreparationContracts.requireNonNegativeSafeInteger(bytesExpected, field: "bytes_expected")
        try ModelPreparationContracts.requireNonNegativeSafeInteger(filesCompleted, field: "files_completed")
        try ModelPreparationContracts.requireNonNegativeSafeInteger(filesExpected, field: "files_expected")
        guard bytesCompleted <= bytesExpected else { throw ModelPreparationContractError.malformed("bytes_completed") }
        guard filesCompleted <= filesExpected else { throw ModelPreparationContractError.malformed("files_completed") }
        self.bytesCompleted = bytesCompleted
        self.bytesExpected = bytesExpected
        self.filesCompleted = filesCompleted
        self.filesExpected = filesExpected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            bytesCompleted: try container.decode(Int64.self, forKey: .bytesCompleted),
            bytesExpected: try container.decode(Int64.self, forKey: .bytesExpected),
            filesCompleted: try container.decode(Int.self, forKey: .filesCompleted),
            filesExpected: try container.decode(Int.self, forKey: .filesExpected)
        )
    }
}

struct ModelPreparationBarrierProgress: Codable, Equatable, Sendable {
    let objectParentSynced: Bool
    let objectParentFullSynced: Bool
    let phaseRecordSynced: Bool
    let phaseRecordReadBack: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case objectParentSynced = "object_parent_synced"
        case objectParentFullSynced = "object_parent_full_synced"
        case phaseRecordSynced = "phase_record_synced"
        case phaseRecordReadBack = "phase_record_readback"
    }

    init(objectParentSynced: Bool, objectParentFullSynced: Bool, phaseRecordSynced: Bool, phaseRecordReadBack: Bool) {
        self.objectParentSynced = objectParentSynced
        self.objectParentFullSynced = objectParentFullSynced
        self.phaseRecordSynced = phaseRecordSynced
        self.phaseRecordReadBack = phaseRecordReadBack
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        self.objectParentSynced = try container.decode(Bool.self, forKey: .objectParentSynced)
        self.objectParentFullSynced = try container.decode(Bool.self, forKey: .objectParentFullSynced)
        self.phaseRecordSynced = try container.decode(Bool.self, forKey: .phaseRecordSynced)
        self.phaseRecordReadBack = try container.decode(Bool.self, forKey: .phaseRecordReadBack)
    }
}

struct ModelPreparationTerminalResult: Codable, Equatable, Sendable {
    let state: ModelPreparationHistoryTerminalState
    let errorCode: ModelPreparationEventErrorCode?
    let completedAt: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case state
        case errorCode = "error_code"
        case completedAt = "completed_at"
    }

    init(state: ModelPreparationHistoryTerminalState, errorCode: ModelPreparationEventErrorCode?, completedAt: String) throws {
        if state == .failed || state == .timedOut {
            guard errorCode != nil else { throw ModelPreparationContractError.malformed("error_code") }
        } else if errorCode != nil {
            throw ModelPreparationContractError.malformed("error_code")
        }
        try ModelPreparationContracts.requireCanonicalRFC3339(completedAt, field: "completed_at")
        self.state = state
        self.errorCode = errorCode
        self.completedAt = completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            state: try container.decode(ModelPreparationHistoryTerminalState.self, forKey: .state),
            errorCode: try container.decodeRequiredNullable(ModelPreparationEventErrorCode.self, forKey: .errorCode),
            completedAt: try container.decode(String.self, forKey: .completedAt)
        )
    }
}

struct ModelPreparationActiveRecord: Codable, Equatable, Sendable {
    let schema: String
    let transactionID: String
    let attemptID: String
    let transactionKind: ModelPreparationTransactionKind
    let eventModelKey: String
    let root: ModelPreparationRootLocator
    let tuple: ModelPreparationTupleRecord
    let tupleSHA256: String
    let projectionBindingSHA256: String
    let nextEventSequence: Int
    let phase: ModelPreparationActivePhase
    let counters: ModelPreparationActiveCounters
    let recordedLeaves: [String]
    let barrierProgress: ModelPreparationBarrierProgress
    let terminalResult: ModelPreparationTerminalResult?
    let cancellationRequested: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case transactionID = "transaction_id"
        case attemptID = "attempt_id"
        case transactionKind = "transaction_kind"
        case eventModelKey = "event_model_key"
        case root
        case tuple
        case tupleSHA256 = "tuple_sha256"
        case projectionBindingSHA256 = "projection_binding_sha256"
        case nextEventSequence = "next_event_sequence"
        case phase
        case counters
        case recordedLeaves = "recorded_leaves"
        case barrierProgress = "barrier_progress"
        case terminalResult = "terminal_result"
        case cancellationRequested = "cancellation_requested"
    }

    init(
        schema: String = "model_catalog_active_attempt.v1",
        transactionID: String,
        attemptID: String,
        transactionKind: ModelPreparationTransactionKind,
        eventModelKey: String,
        root: ModelPreparationRootLocator,
        tuple: ModelPreparationTupleRecord,
        tupleSHA256: String,
        projectionBindingSHA256: String,
        nextEventSequence: Int,
        phase: ModelPreparationActivePhase,
        counters: ModelPreparationActiveCounters,
        recordedLeaves: [String],
        barrierProgress: ModelPreparationBarrierProgress,
        terminalResult: ModelPreparationTerminalResult?,
        cancellationRequested: Bool
    ) throws {
        guard schema == "model_catalog_active_attempt.v1" else { throw ModelPreparationContractError.malformed("schema") }
        try ModelPreparationContracts.requireUUIDv4(transactionID, field: "transaction_id")
        try ModelPreparationContracts.requireUUIDv4(attemptID, field: "attempt_id")
        try ModelPreparationContracts.requireSafeString(eventModelKey, field: "event_model_key")
        guard eventModelKey == tuple.eventModelKey else { throw ModelPreparationContractError.bindingMismatch("event_model_key") }
        guard root == tuple.root else { throw ModelPreparationContractError.bindingMismatch("root") }
        try ModelPreparationContracts.requireHex64(tupleSHA256, field: "tuple_sha256")
        let expectedTupleSHA256 = try ModelPreparationContracts.tupleSHA256(tuple)
        guard tupleSHA256 == expectedTupleSHA256 else {
            throw ModelPreparationContractError.bindingMismatch("tuple_sha256")
        }
        try ModelPreparationContracts.requireHex64(projectionBindingSHA256, field: "projection_binding_sha256")
        try ModelPreparationContracts.requireNonNegativeSafeInteger(nextEventSequence, field: "next_event_sequence")
        guard nextEventSequence >= 1 else { throw ModelPreparationContractError.malformed("next_event_sequence") }
        guard recordedLeaves.count <= 256, Set(recordedLeaves).count == recordedLeaves.count else {
            throw ModelPreparationContractError.malformed("recorded_leaves")
        }
        for leaf in recordedLeaves {
            try ModelPreparationContracts.requirePathLeaf(leaf, field: "recorded_leaves")
        }
        if phase == .terminal {
            guard terminalResult != nil else { throw ModelPreparationContractError.malformed("terminal_result") }
        } else if terminalResult != nil {
            throw ModelPreparationContractError.malformed("terminal_result")
        }
        self.schema = schema
        self.transactionID = transactionID
        self.attemptID = attemptID
        self.transactionKind = transactionKind
        self.eventModelKey = eventModelKey
        self.root = root
        self.tuple = tuple
        self.tupleSHA256 = tupleSHA256
        self.projectionBindingSHA256 = projectionBindingSHA256
        self.nextEventSequence = nextEventSequence
        self.phase = phase
        self.counters = counters
        self.recordedLeaves = recordedLeaves
        self.barrierProgress = barrierProgress
        self.terminalResult = terminalResult
        self.cancellationRequested = cancellationRequested
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            transactionID: try container.decode(String.self, forKey: .transactionID),
            attemptID: try container.decode(String.self, forKey: .attemptID),
            transactionKind: try container.decode(ModelPreparationTransactionKind.self, forKey: .transactionKind),
            eventModelKey: try container.decode(String.self, forKey: .eventModelKey),
            root: try container.decode(ModelPreparationRootLocator.self, forKey: .root),
            tuple: try container.decode(ModelPreparationTupleRecord.self, forKey: .tuple),
            tupleSHA256: try container.decode(String.self, forKey: .tupleSHA256),
            projectionBindingSHA256: try container.decode(String.self, forKey: .projectionBindingSHA256),
            nextEventSequence: try container.decode(Int.self, forKey: .nextEventSequence),
            phase: try container.decode(ModelPreparationActivePhase.self, forKey: .phase),
            counters: try container.decode(ModelPreparationActiveCounters.self, forKey: .counters),
            recordedLeaves: try container.decode([String].self, forKey: .recordedLeaves),
            barrierProgress: try container.decode(ModelPreparationBarrierProgress.self, forKey: .barrierProgress),
            terminalResult: try container.decodeRequiredNullable(ModelPreparationTerminalResult.self, forKey: .terminalResult),
            cancellationRequested: try container.decode(Bool.self, forKey: .cancellationRequested)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encode(attemptID, forKey: .attemptID)
        try container.encode(transactionKind, forKey: .transactionKind)
        try container.encode(eventModelKey, forKey: .eventModelKey)
        try container.encode(root, forKey: .root)
        try container.encode(tuple, forKey: .tuple)
        try container.encode(tupleSHA256, forKey: .tupleSHA256)
        try container.encode(projectionBindingSHA256, forKey: .projectionBindingSHA256)
        try container.encode(nextEventSequence, forKey: .nextEventSequence)
        try container.encode(phase, forKey: .phase)
        try container.encode(counters, forKey: .counters)
        try container.encode(recordedLeaves, forKey: .recordedLeaves)
        try container.encode(barrierProgress, forKey: .barrierProgress)
        try container.encodeNullable(terminalResult, forKey: .terminalResult)
        try container.encode(cancellationRequested, forKey: .cancellationRequested)
    }
}

struct ModelPreparationCancelAcknowledgement: Codable, Equatable, Sendable {
    let schema: String
    let transactionID: String
    let attemptID: String?
    let outcome: ModelPreparationCancelOutcome
    let observedAt: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case transactionID = "transaction_id"
        case attemptID = "attempt_id"
        case outcome
        case observedAt = "observed_at"
    }

    init(
        schema: String = "model_catalog_transaction_cancel_ack.v1",
        transactionID: String,
        attemptID: String?,
        outcome: ModelPreparationCancelOutcome,
        observedAt: String
    ) throws {
        guard schema == "model_catalog_transaction_cancel_ack.v1" else { throw ModelPreparationContractError.malformed("schema") }
        try ModelPreparationContracts.requireUUIDv4(transactionID, field: "transaction_id")
        if let attemptID { try ModelPreparationContracts.requireUUIDv4(attemptID, field: "attempt_id") }
        switch outcome {
        case .recorded, .alreadyRecorded, .terminal:
            guard attemptID != nil else { throw ModelPreparationContractError.malformed("attempt_id") }
        case .notActive, .busy:
            guard attemptID == nil else { throw ModelPreparationContractError.malformed("attempt_id") }
        case .stale:
            break
        }
        self.schema = schema
        self.transactionID = transactionID
        self.attemptID = attemptID
        self.outcome = outcome
        try ModelPreparationContracts.requireCanonicalRFC3339(observedAt, field: "observed_at")
        self.observedAt = observedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            transactionID: try container.decode(String.self, forKey: .transactionID),
            attemptID: try container.decodeRequiredNullable(String.self, forKey: .attemptID),
            outcome: try container.decode(ModelPreparationCancelOutcome.self, forKey: .outcome),
            observedAt: try container.decode(String.self, forKey: .observedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encodeNullable(attemptID, forKey: .attemptID)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(observedAt, forKey: .observedAt)
    }
}

struct ModelPreparationTransactionEvent: Codable, Equatable, Sendable {
    struct Progress: Codable, Equatable, Sendable {
        let stageLabelKey: String
        let bytesCompleted: Int64?
        let bytesExpected: Int64?
        let percentComplete: Double?
        let heartbeat: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case stageLabelKey = "stage_label_key"
            case bytesCompleted = "bytes_completed"
            case bytesExpected = "bytes_expected"
            case percentComplete = "percent_complete"
            case heartbeat
        }

        init(stageLabelKey: String, bytesCompleted: Int64?, bytesExpected: Int64?, percentComplete: Double?, heartbeat: Bool?) throws {
            try ModelPreparationContracts.requireSafeString(stageLabelKey, field: "stage_label_key", maxUTF8Bytes: 128)
            guard bytesCompleted != nil || bytesExpected != nil || percentComplete != nil || heartbeat == true else {
                throw ModelPreparationContractError.malformed("progress")
            }
            if let bytesCompleted {
                try ModelPreparationContracts.requireNonNegativeSafeInteger(bytesCompleted, field: "bytes_completed")
            }
            if let bytesExpected {
                try ModelPreparationContracts.requireNonNegativeSafeInteger(bytesExpected, field: "bytes_expected")
            }
            if let bytesCompleted, let bytesExpected, bytesCompleted > bytesExpected {
                throw ModelPreparationContractError.malformed("bytes_completed")
            }
            if let percentComplete {
                guard percentComplete.isFinite, percentComplete >= 0, percentComplete <= 100 else {
                    throw ModelPreparationContractError.malformed("percent_complete")
                }
            }
            self.stageLabelKey = stageLabelKey
            self.bytesCompleted = bytesCompleted
            self.bytesExpected = bytesExpected
            self.percentComplete = percentComplete
            self.heartbeat = heartbeat
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try container.requireExactlyKeys(CodingKeys.self)
            try self.init(
                stageLabelKey: try container.decode(String.self, forKey: .stageLabelKey),
                bytesCompleted: try container.decodeRequiredNullable(Int64.self, forKey: .bytesCompleted),
                bytesExpected: try container.decodeRequiredNullable(Int64.self, forKey: .bytesExpected),
                percentComplete: try container.decodeRequiredNullable(Double.self, forKey: .percentComplete),
                heartbeat: try container.decodeRequiredNullable(Bool.self, forKey: .heartbeat)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stageLabelKey, forKey: .stageLabelKey)
            try container.encodeNullable(bytesCompleted, forKey: .bytesCompleted)
            try container.encodeNullable(bytesExpected, forKey: .bytesExpected)
            try container.encodeNullable(percentComplete, forKey: .percentComplete)
            try container.encodeNullable(heartbeat, forKey: .heartbeat)
        }
    }

    let schema: String
    let transactionID: String
    let transactionKind: ModelPreparationTransactionKind
    let modelKey: String
    let eventSequence: Int
    let emittedAt: String
    let state: ModelPreparationEventState
    let progress: Progress?
    let errorCode: ModelPreparationEventErrorCode?
    let warningCode: ModelPreparationEventWarningCode?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case transactionID = "transaction_id"
        case transactionKind = "transaction_kind"
        case modelKey = "model_key"
        case eventSequence = "event_sequence"
        case emittedAt = "emitted_at"
        case state
        case progress
        case errorCode = "error_code"
        case warningCode = "warning_code"
    }

    init(
        schema: String = "model_catalog_transaction_event.v1",
        transactionID: String,
        transactionKind: ModelPreparationTransactionKind,
        modelKey: String,
        eventSequence: Int,
        emittedAt: String,
        state: ModelPreparationEventState,
        progress: Progress?,
        errorCode: ModelPreparationEventErrorCode?,
        warningCode: ModelPreparationEventWarningCode?
    ) throws {
        guard schema == "model_catalog_transaction_event.v1" else { throw ModelPreparationContractError.malformed("schema") }
        try ModelPreparationContracts.requireUUIDv4(transactionID, field: "transaction_id")
        try ModelPreparationContracts.requireSafeString(modelKey, field: "model_key")
        try ModelPreparationContracts.requireNonNegativeSafeInteger(eventSequence, field: "event_sequence")
        guard eventSequence >= 1 else { throw ModelPreparationContractError.malformed("event_sequence") }
        if state == .failed || state == .timedOut {
            guard errorCode != nil else { throw ModelPreparationContractError.malformed("error_code") }
        } else if errorCode != nil {
            throw ModelPreparationContractError.malformed("error_code")
        }
        if state == .succeeded || state == .failed || state == .timedOut || state == .cancelled {
            guard progress == nil else { throw ModelPreparationContractError.malformed("progress") }
        }
        if state == .running || state == .cancelRequested {
            guard progress != nil else { throw ModelPreparationContractError.malformed("progress") }
        }
        self.schema = schema
        self.transactionID = transactionID
        self.transactionKind = transactionKind
        self.modelKey = modelKey
        self.eventSequence = eventSequence
        try ModelPreparationContracts.requireCanonicalRFC3339(emittedAt, field: "emitted_at")
        self.emittedAt = emittedAt
        self.state = state
        self.progress = progress
        self.errorCode = errorCode
        self.warningCode = warningCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            transactionID: try container.decode(String.self, forKey: .transactionID),
            transactionKind: try container.decode(ModelPreparationTransactionKind.self, forKey: .transactionKind),
            modelKey: try container.decode(String.self, forKey: .modelKey),
            eventSequence: try container.decode(Int.self, forKey: .eventSequence),
            emittedAt: try container.decode(String.self, forKey: .emittedAt),
            state: try container.decode(ModelPreparationEventState.self, forKey: .state),
            progress: try container.decodeRequiredNullable(Progress.self, forKey: .progress),
            errorCode: try container.decodeRequiredNullable(ModelPreparationEventErrorCode.self, forKey: .errorCode),
            warningCode: try container.decodeRequiredNullable(ModelPreparationEventWarningCode.self, forKey: .warningCode)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encode(transactionKind, forKey: .transactionKind)
        try container.encode(modelKey, forKey: .modelKey)
        try container.encode(eventSequence, forKey: .eventSequence)
        try container.encode(emittedAt, forKey: .emittedAt)
        try container.encode(state, forKey: .state)
        try container.encodeNullable(progress, forKey: .progress)
        try container.encodeNullable(errorCode, forKey: .errorCode)
        try container.encodeNullable(warningCode, forKey: .warningCode)
    }
}

struct ModelPreparationPublicationReceipt: Codable, Equatable, Sendable {
    let schema: String
    let eventModelKey: String
    let root: ModelPreparationRootLocator
    let tuple: ModelPreparationTupleRecord
    let tupleSHA256: String
    let publishedAt: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case eventModelKey = "event_model_key"
        case root
        case tuple
        case tupleSHA256 = "tuple_sha256"
        case publishedAt = "published_at"
    }

    init(
        schema: String = "model_catalog_publication_receipt.v1",
        eventModelKey: String,
        root: ModelPreparationRootLocator,
        tuple: ModelPreparationTupleRecord,
        tupleSHA256: String,
        publishedAt: String
    ) throws {
        guard schema == "model_catalog_publication_receipt.v1" else { throw ModelPreparationContractError.malformed("schema") }
        try ModelPreparationContracts.requireSafeString(eventModelKey, field: "event_model_key")
        guard eventModelKey == tuple.eventModelKey else {
            throw ModelPreparationContractError.bindingMismatch("event_model_key")
        }
        guard root == tuple.root else { throw ModelPreparationContractError.bindingMismatch("root") }
        try ModelPreparationContracts.requireHex64(tupleSHA256, field: "tuple_sha256")
        let expectedTupleSHA256 = try ModelPreparationContracts.tupleSHA256(tuple)
        guard tupleSHA256 == expectedTupleSHA256 else {
            throw ModelPreparationContractError.bindingMismatch("tuple_sha256")
        }
        self.schema = schema
        self.eventModelKey = eventModelKey
        self.root = root
        self.tuple = tuple
        self.tupleSHA256 = tupleSHA256
        try ModelPreparationContracts.requireCanonicalRFC3339(publishedAt, field: "published_at")
        self.publishedAt = publishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            eventModelKey: try container.decode(String.self, forKey: .eventModelKey),
            root: try container.decode(ModelPreparationRootLocator.self, forKey: .root),
            tuple: try container.decode(ModelPreparationTupleRecord.self, forKey: .tuple),
            tupleSHA256: try container.decode(String.self, forKey: .tupleSHA256),
            publishedAt: try container.decode(String.self, forKey: .publishedAt)
        )
    }
}

struct ModelPreparationInventoryRecord: Codable, Equatable, Sendable {
    let schema: String
    let root: ModelPreparationRootLocator
    let targets: [ModelPreparationCleanupTarget]
    let generatedAt: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case root
        case targets
        case generatedAt = "generated_at"
    }

    init(schema: String = "model_catalog_published_inventory.v1", root: ModelPreparationRootLocator, targets: [ModelPreparationCleanupTarget], generatedAt: String) throws {
        guard schema == "model_catalog_published_inventory.v1" else { throw ModelPreparationContractError.malformed("schema") }
        guard targets.count <= 256 else { throw ModelPreparationContractError.malformed("targets") }
        let sorted = targets.map(\.artifactIdentityDigest).sorted()
        guard targets.map(\.artifactIdentityDigest) == sorted, Set(sorted).count == sorted.count else {
            throw ModelPreparationContractError.malformed("targets")
        }
        guard targets.allSatisfy({ $0.rootIdentityDigest == root.rootIdentityDigest }) else {
            throw ModelPreparationContractError.bindingMismatch("root_identity_digest")
        }
        self.schema = schema
        self.root = root
        self.targets = targets
        try ModelPreparationContracts.requireCanonicalRFC3339(generatedAt, field: "generated_at")
        self.generatedAt = generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            root: try container.decode(ModelPreparationRootLocator.self, forKey: .root),
            targets: try container.decode([ModelPreparationCleanupTarget].self, forKey: .targets),
            generatedAt: try container.decode(String.self, forKey: .generatedAt)
        )
    }
}

struct ModelPreparationCleanupRecord: Codable, Equatable, Sendable {
    let schema: String
    let targetKind: ModelPreparationCleanupTargetKind
    let phase: ModelPreparationCleanupPhase
    let transactionID: String
    let attemptID: String
    let eventModelKey: String
    let root: ModelPreparationRootLocator
    let tuple: ModelPreparationTupleRecord
    let tupleSHA256: String
    let receipt: ModelPreparationPublicationReceipt
    let receiptSHA256: String
    let artifactIdentityDigest: String
    let finalLeaf: String
    let tombstoneLeaf: String
    let expectedBytes: Int64
    let expectedFiles: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case targetKind = "target_kind"
        case phase
        case transactionID = "transaction_id"
        case attemptID = "attempt_id"
        case eventModelKey = "event_model_key"
        case root
        case tuple
        case tupleSHA256 = "tuple_sha256"
        case receipt
        case receiptSHA256 = "receipt_sha256"
        case artifactIdentityDigest = "artifact_identity_digest"
        case finalLeaf = "final_leaf"
        case tombstoneLeaf = "tombstone_leaf"
        case expectedBytes = "expected_bytes"
        case expectedFiles = "expected_files"
    }

    init(
        schema: String = "model_catalog_cleanup_record.v1",
        targetKind: ModelPreparationCleanupTargetKind,
        phase: ModelPreparationCleanupPhase,
        transactionID: String,
        attemptID: String,
        eventModelKey: String,
        root: ModelPreparationRootLocator,
        tuple: ModelPreparationTupleRecord,
        tupleSHA256: String,
        receipt: ModelPreparationPublicationReceipt,
        receiptSHA256: String,
        artifactIdentityDigest: String,
        finalLeaf: String,
        tombstoneLeaf: String,
        expectedBytes: Int64,
        expectedFiles: Int
    ) throws {
        guard schema == "model_catalog_cleanup_record.v1" else { throw ModelPreparationContractError.malformed("schema") }
        try ModelPreparationContracts.requireUUIDv4(transactionID, field: "transaction_id")
        try ModelPreparationContracts.requireUUIDv4(attemptID, field: "attempt_id")
        try ModelPreparationContracts.requireSafeString(eventModelKey, field: "event_model_key")
        guard eventModelKey == tuple.eventModelKey, eventModelKey == receipt.eventModelKey else {
            throw ModelPreparationContractError.bindingMismatch("event_model_key")
        }
        guard root == tuple.root, root == receipt.root else { throw ModelPreparationContractError.bindingMismatch("root") }
        guard tuple == receipt.tuple else { throw ModelPreparationContractError.bindingMismatch("tuple") }
        try ModelPreparationContracts.requireHex64(tupleSHA256, field: "tuple_sha256")
        let expectedTupleSHA256 = try ModelPreparationContracts.tupleSHA256(tuple)
        guard tupleSHA256 == expectedTupleSHA256, tupleSHA256 == receipt.tupleSHA256 else {
            throw ModelPreparationContractError.bindingMismatch("tuple_sha256")
        }
        try ModelPreparationContracts.requireHex64(receiptSHA256, field: "receipt_sha256")
        let expectedReceiptSHA256 = try ModelPreparationContracts.receiptSHA256(receipt)
        guard receiptSHA256 == expectedReceiptSHA256 else {
            throw ModelPreparationContractError.bindingMismatch("receipt_sha256")
        }
        let expectedArtifactIdentityDigest = try ModelPreparationContracts.artifactIdentityDigest(
            displayModelID: tuple.displayModelID,
            modelRevision: tuple.modelRevision,
            artifactID: tuple.artifactID,
            releaseID: tuple.releaseID,
            rootIdentityDigest: root.rootIdentityDigest,
            receiptSHA256: receiptSHA256
        )
        try ModelPreparationContracts.requireHex64(artifactIdentityDigest, field: "artifact_identity_digest")
        guard artifactIdentityDigest == expectedArtifactIdentityDigest else {
            throw ModelPreparationContractError.bindingMismatch("artifact_identity_digest")
        }
        try ModelPreparationContracts.requirePathLeaf(finalLeaf, field: "final_leaf")
        try ModelPreparationContracts.requirePathLeaf(tombstoneLeaf, field: "tombstone_leaf")
        switch targetKind {
        case .published:
            guard finalLeaf == artifactIdentityDigest, tombstoneLeaf == "\(artifactIdentityDigest).tombstone" else {
                throw ModelPreparationContractError.malformed("leaf")
            }
        case .staging:
            guard finalLeaf == "\(attemptID).staging", tombstoneLeaf == "\(attemptID).staging.tombstone" else {
                throw ModelPreparationContractError.malformed("leaf")
            }
        }
        guard expectedBytes > 0 else { throw ModelPreparationContractError.malformed("expected_bytes") }
        try ModelPreparationContracts.requireNonNegativeSafeInteger(expectedBytes, field: "expected_bytes")
        guard expectedFiles > 0 else { throw ModelPreparationContractError.malformed("expected_files") }
        try ModelPreparationContracts.requireNonNegativeSafeInteger(expectedFiles, field: "expected_files")
        self.schema = schema
        self.targetKind = targetKind
        self.phase = phase
        self.transactionID = transactionID
        self.attemptID = attemptID
        self.eventModelKey = eventModelKey
        self.root = root
        self.tuple = tuple
        self.tupleSHA256 = tupleSHA256
        self.receipt = receipt
        self.receiptSHA256 = receiptSHA256
        self.artifactIdentityDigest = artifactIdentityDigest
        self.finalLeaf = finalLeaf
        self.tombstoneLeaf = tombstoneLeaf
        self.expectedBytes = expectedBytes
        self.expectedFiles = expectedFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            targetKind: try container.decode(ModelPreparationCleanupTargetKind.self, forKey: .targetKind),
            phase: try container.decode(ModelPreparationCleanupPhase.self, forKey: .phase),
            transactionID: try container.decode(String.self, forKey: .transactionID),
            attemptID: try container.decode(String.self, forKey: .attemptID),
            eventModelKey: try container.decode(String.self, forKey: .eventModelKey),
            root: try container.decode(ModelPreparationRootLocator.self, forKey: .root),
            tuple: try container.decode(ModelPreparationTupleRecord.self, forKey: .tuple),
            tupleSHA256: try container.decode(String.self, forKey: .tupleSHA256),
            receipt: try container.decode(ModelPreparationPublicationReceipt.self, forKey: .receipt),
            receiptSHA256: try container.decode(String.self, forKey: .receiptSHA256),
            artifactIdentityDigest: try container.decode(String.self, forKey: .artifactIdentityDigest),
            finalLeaf: try container.decode(String.self, forKey: .finalLeaf),
            tombstoneLeaf: try container.decode(String.self, forKey: .tombstoneLeaf),
            expectedBytes: try container.decode(Int64.self, forKey: .expectedBytes),
            expectedFiles: try container.decode(Int.self, forKey: .expectedFiles)
        )
    }
}

enum ModelPreparationUniqueTempRecordKind: String, Codable, CaseIterable, Sendable {
    case failedDispatch = "failed_dispatch"
    case transactionEvent = "transaction_event"
    case cancelAcknowledgement = "cancel_acknowledgement"
    case activeRecord = "active_record"
    case cleanupRecord = "cleanup_record"
    case reservationHistory = "reservation_history"
    case inventory = "inventory"
}

struct ModelPreparationUniqueTempRecord: Codable, Equatable, Sendable {
    let schema: String
    let recordKind: ModelPreparationUniqueTempRecordKind
    let targetLeaf: String
    let writerUUID: String
    let generation: Int
    let payload: Data
    let payloadSHA256: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case recordKind = "record_kind"
        case targetLeaf = "target_leaf"
        case writerUUID = "writer_uuid"
        case generation
        case payloadBase64 = "payload_base64"
        case payloadSHA256 = "payload_sha256"
    }

    init(
        schema: String = "model_catalog_unique_temp.v2",
        recordKind: ModelPreparationUniqueTempRecordKind,
        targetLeaf: String,
        writerUUID: String,
        generation: Int,
        payload: Data,
        payloadSHA256: String? = nil
    ) throws {
        guard schema == "model_catalog_unique_temp.v2" else { throw ModelPreparationContractError.malformed("schema") }
        let expectedLeaf = Self.expectedTargetLeaf(for: recordKind)
        try ModelPreparationContracts.requirePathLeaf(targetLeaf, field: "target_leaf")
        guard targetLeaf == expectedLeaf else { throw ModelPreparationContractError.bindingMismatch("target_leaf") }
        try ModelPreparationContracts.requireUUIDv4(writerUUID, field: "writer_uuid")
        try ModelPreparationContracts.requireNonNegativeSafeInteger(generation, field: "generation")
        let payloadMaxBytes = Self.payloadMaxBytes(for: recordKind)
        guard payload.count <= payloadMaxBytes else {
            throw ModelPreparationContractError.overLimit(limit: payloadMaxBytes)
        }
        let expectedPayloadSHA256 = ModelPreparationContracts.sha256Hex(for: payload)
        if let payloadSHA256 {
            try ModelPreparationContracts.requireHex64(payloadSHA256, field: "payload_sha256")
            guard payloadSHA256 == expectedPayloadSHA256 else {
                throw ModelPreparationContractError.bindingMismatch("payload_sha256")
            }
        }
        self.schema = schema
        self.recordKind = recordKind
        self.targetLeaf = targetLeaf
        self.writerUUID = writerUUID
        self.generation = generation
        self.payload = payload
        self.payloadSHA256 = expectedPayloadSHA256
        _ = try ModelPreparationContracts.encode(self, maxBytes: ModelPreparationContracts.uniqueTempEnvelopeMaxBytes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.requireExactlyKeys(CodingKeys.self)
        let payloadBase64 = try container.decode(String.self, forKey: .payloadBase64)
        guard let payload = Data(base64Encoded: payloadBase64) else {
            throw ModelPreparationContractError.malformed("payload_base64")
        }
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            recordKind: try container.decode(ModelPreparationUniqueTempRecordKind.self, forKey: .recordKind),
            targetLeaf: try container.decode(String.self, forKey: .targetLeaf),
            writerUUID: try container.decode(String.self, forKey: .writerUUID),
            generation: try container.decode(Int.self, forKey: .generation),
            payload: payload,
            payloadSHA256: try container.decode(String.self, forKey: .payloadSHA256)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(recordKind, forKey: .recordKind)
        try container.encode(targetLeaf, forKey: .targetLeaf)
        try container.encode(writerUUID, forKey: .writerUUID)
        try container.encode(generation, forKey: .generation)
        try container.encode(payload.base64EncodedString(), forKey: .payloadBase64)
        try container.encode(payloadSHA256, forKey: .payloadSHA256)
    }

    static func expectedTargetLeaf(for recordKind: ModelPreparationUniqueTempRecordKind) -> String {
        switch recordKind {
        case .failedDispatch: return "failed-dispatch.json"
        case .transactionEvent: return "transaction-event.json"
        case .cancelAcknowledgement: return "cancel-acknowledgement.json"
        case .activeRecord: return "active.json"
        case .cleanupRecord: return "cleanup-record.json"
        case .reservationHistory: return "reservation-history.json"
        case .inventory: return "inventory.json"
        }
    }

    static func payloadMaxBytes(for recordKind: ModelPreparationUniqueTempRecordKind) -> Int {
        switch recordKind {
        case .failedDispatch: return ModelPreparationContracts.failedDispatchMaxBytes
        case .transactionEvent: return ModelPreparationContracts.eventMaxBytes
        case .cancelAcknowledgement: return ModelPreparationContracts.cancelAcknowledgementMaxBytes
        case .activeRecord: return ModelPreparationContracts.activeRecordMaxBytes
        case .cleanupRecord: return ModelPreparationContracts.deletionRecordMaxBytes
        case .reservationHistory: return ModelPreparationContracts.reservationHistoryMaxBytes
        case .inventory: return ModelPreparationContracts.inventoryMaxBytes
        }
    }

    static func expectedFilename(recordKind: ModelPreparationUniqueTempRecordKind, targetLeaf: String, writerUUID: String) throws -> String {
        try ModelPreparationContracts.requirePathLeaf(targetLeaf, field: "target_leaf")
        guard targetLeaf == expectedTargetLeaf(for: recordKind) else {
            throw ModelPreparationContractError.bindingMismatch("target_leaf")
        }
        try ModelPreparationContracts.requireUUIDv4(writerUUID, field: "writer_uuid")
        return "\(targetLeaf).\(writerUUID).tmp"
    }

    func expectedFilename() throws -> String {
        try Self.expectedFilename(recordKind: recordKind, targetLeaf: targetLeaf, writerUUID: writerUUID)
    }

    func validateFilename(_ filename: String) throws {
        guard filename == (try expectedFilename()) else {
            throw ModelPreparationContractError.bindingMismatch("filename")
        }
    }
}

private extension KeyedDecodingContainer {
    func requireExactlyKeys<ExpectedKey: CodingKey & CaseIterable>(_ keyType: ExpectedKey.Type) throws {
        let allowed = Set(ExpectedKey.allCases.map(\.stringValue))
        let present = Set(allKeys.map(\.stringValue))
        guard present == allowed else {
            throw ModelPreparationContractError.malformed("keys")
        }
    }

    func decodeRequiredNullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else { throw ModelPreparationContractError.malformed(key.stringValue) }
        return try decodeIfPresent(T.self, forKey: key)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

private extension RFC8785JCS.Value {
    func canonicalRawUTF8() throws -> Data {
        Data(try RFC8785JCS.canonicalStringRawStrings(self).utf8)
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    mutating func appendLengthPrefixedUTF8(_ value: String) {
        let bytes = Data(value.utf8)
        appendUInt32BE(UInt32(bytes.count))
        append(bytes)
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func sha256Hex() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ModelPreparationJSONDuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func validate() throws {
        skipWS()
        try parseValue()
        skipWS()
        guard index == bytes.count else { throw ModelPreparationContractError.malformed("trailing bytes") }
    }

    private mutating func parseValue() throws {
        guard index < bytes.count else { throw ModelPreparationContractError.malformed("unexpected end") }
        switch bytes[index] {
        case 0x7B: try parseObject()
        case 0x5B: try parseArray()
        case 0x22: _ = try parseString()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        default: try parseNumber()
        }
    }

    private mutating func parseObject() throws {
        index += 1
        skipWS()
        var keys = Set<String>()
        if consume(0x7D) { return }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else { throw ModelPreparationContractError.malformed("object key") }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw ModelPreparationContractError.malformed("duplicate key") }
            skipWS()
            guard consume(0x3A) else { throw ModelPreparationContractError.malformed("colon") }
            skipWS()
            try parseValue()
            skipWS()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw ModelPreparationContractError.malformed("separator") }
            skipWS()
        }
    }

    private mutating func parseArray() throws {
        index += 1
        skipWS()
        if consume(0x5D) { return }
        while true {
            try parseValue()
            skipWS()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw ModelPreparationContractError.malformed("array separator") }
            skipWS()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let token = Data(bytes[start ..< index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
                    throw ModelPreparationContractError.malformed("string")
                }
                return decoded
            } else if byte < 0x20 {
                throw ModelPreparationContractError.malformed("control char")
            }
        }
        throw ModelPreparationContractError.malformed("unterminated string")
    }

    private mutating func parseNumber() throws {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw ModelPreparationContractError.malformed("number") }
        let token = Data(bytes[start ..< index])
        guard (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) is NSNumber else {
            throw ModelPreparationContractError.malformed("number")
        }
    }

    private mutating func literal(_ string: String) throws {
        let expected = Array(string.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index ..< index + expected.count]) == expected else {
            throw ModelPreparationContractError.malformed("literal")
        }
        index += expected.count
    }

    private mutating func skipWS() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}

private struct ModelPreparationJSONNumberTokenScanner {
    private let bytes: [UInt8]
    private var index = 0
    private var lastString: String?
    private var currentKey: String?

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    mutating func validate() throws {
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x22:
                lastString = try readString()
            case 0x3A:
                currentKey = lastString
                index += 1
            case 0x2D, 0x30...0x39:
                try readNumber()
            default:
                index += 1
            }
        }
    }

    private mutating func readString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let data = Data(bytes[start..<index])
                return (try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String) ?? ""
            }
        }
        throw ModelPreparationContractError.malformed("string")
    }

    private mutating func readNumber() throws {
        let start = index
        if bytes[index] == 0x2D { index += 1 }
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        var hasDecimal = false
        var hasExponent = false
        if index < bytes.count, bytes[index] == 0x2E {
            hasDecimal = true
            index += 1
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x65 || index < bytes.count && bytes[index] == 0x45 {
            hasExponent = true
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        if token == "-0" || token.hasPrefix("-0.") || token.hasPrefix("-0e") || token.hasPrefix("-0E") {
            throw ModelPreparationContractError.malformed("number")
        }
        if currentKey == "percent_complete" {
            if hasExponent { throw ModelPreparationContractError.malformed("percent_complete") }
        } else if hasDecimal || hasExponent {
            throw ModelPreparationContractError.malformed(currentKey ?? "number")
        }
        currentKey = nil
    }
}

private enum ModelPreparationJSONShapeValidator {
    private static let allowedKeySets: Set<Set<String>> = [
        Set(ModelPreparationRootLocator.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationRootIdentityRecord.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationAction.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationCleanupTarget.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationTupleRecord.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationReservationRecord.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationFailedDispatchRecord.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationActiveCounters.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationBarrierProgress.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationTerminalResult.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationActiveRecord.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationCancelAcknowledgement.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationTransactionEvent.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationTransactionEvent.Progress.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationPublicationReceipt.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationInventoryRecord.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationCleanupRecord.CodingKeys.allCases.map(\.stringValue)),
        Set(ModelPreparationUniqueTempRecord.CodingKeys.allCases.map(\.stringValue)),
    ]

    static func validate(_ data: Data) throws {
        let value = try JSONSerialization.jsonObject(with: data)
        try validate(value)
    }

    private static func validate(_ value: Any) throws {
        if let object = value as? [String: Any] {
            let keys = Set(object.keys)
            guard allowedKeySets.contains(keys) else {
                throw ModelPreparationContractError.malformed("keys")
            }
            for member in object.values {
                try validate(member)
            }
        } else if let array = value as? [Any] {
            for member in array {
                try validate(member)
            }
        }
    }
}
