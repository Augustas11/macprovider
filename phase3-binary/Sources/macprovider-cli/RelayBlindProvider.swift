import CryptoKit
import Darwin
import Foundation
import MacProviderCore

enum RelayBlindProviderError: Error, Equatable, CustomStringConvertible {
    case disabled
    case invalidConfiguration(String)
    case invalidEnvelope
    case ciphertextInvalid
    case decryptFailed
    case executionAlreadyClaimed
    case journalUnavailable
    case providerUnsupported
    case committedFailed

    var code: String {
        switch self {
        case .disabled: return "relay_blind_disabled"
        case .invalidConfiguration, .providerUnsupported: return "relay_blind_provider_unsupported"
        case .invalidEnvelope: return "relay_blind_envelope_invalid"
        case .ciphertextInvalid: return "relay_blind_ciphertext_invalid"
        case .decryptFailed: return "relay_blind_decrypt_failed"
        case .executionAlreadyClaimed: return "relay_blind_replay"
        case .journalUnavailable: return "relay_blind_committed_failed"
        case .committedFailed: return "relay_blind_committed_failed"
        }
    }

    var description: String { code }
}

struct RelayBlindKeyRecord: Sendable, Equatable {
    static let algorithm = "x25519-hkdf-sha256-a256gcm-v1"
    static let signatureAlgorithm = "ed25519"

    let publicKey: Data
    let identityFingerprint: Data
    let models: [String]
    let maxEncryptedRequestBytes: UInt64
    let endpointFamilies: [String]
    let notBeforeUnix: Int64
    let expiresAtUnix: Int64
    let kid: String
    let keyRecordDigest: String
    let signature: Data

    var wireObject: [String: Any] {
        [
            "alg": Self.algorithm,
            "public_key": RelayBlindBase64URL.encode(publicKey),
            "identity_fingerprint": RelayBlindBase64URL.encode(identityFingerprint),
            "models": models,
            "max_encrypted_request_bytes": maxEncryptedRequestBytes,
            "endpoint_families": endpointFamilies,
            "signature_algorithm": Self.signatureAlgorithm,
            "not_before_unix": notBeforeUnix,
            "expires_at_unix": expiresAtUnix,
            "kid": kid,
            "key_record_digest": keyRecordDigest,
            "signature": RelayBlindBase64URL.encode(signature),
        ]
    }

    static func make(
        identityKey: Curve25519.Signing.PrivateKey,
        encryptionKey: Curve25519.KeyAgreement.PrivateKey,
        models: [String],
        maxEncryptedRequestBytes: UInt64,
        notBeforeUnix: Int64,
        expiresAtUnix: Int64
    ) throws -> RelayBlindKeyRecord {
        let sortedModels = try RelayBlindValidation.canonicalModels(models)
        guard (1...1_048_576).contains(maxEncryptedRequestBytes),
              notBeforeUnix >= 0,
              notBeforeUnix < expiresAtUnix,
              expiresAtUnix - notBeforeUnix <= 86_400 else {
            throw RelayBlindProviderError.invalidConfiguration("invalid key-record bounds")
        }
        let identityFingerprint = Data(SHA256.hash(data: identityKey.publicKey.rawRepresentation))
        let immutable = RelayBlindFraming.keyRecordImmutable(
            publicKey: encryptionKey.publicKey.rawRepresentation,
            identityFingerprint: identityFingerprint,
            models: sortedModels,
            maxEncryptedRequestBytes: maxEncryptedRequestBytes
        )
        let kid = RelayBlindBase64URL.encode(Data(SHA256.hash(data: immutable).prefix(16)))
        var signed = immutable
        signed.appendSigned64(notBeforeUnix)
        signed.appendSigned64(expiresAtUnix)
        let digest = RelayBlindBase64URL.encode(Data(SHA256.hash(data: signed)))
        let signature = try identityKey.signature(for: signed)
        return RelayBlindKeyRecord(
            publicKey: encryptionKey.publicKey.rawRepresentation,
            identityFingerprint: identityFingerprint,
            models: sortedModels,
            maxEncryptedRequestBytes: maxEncryptedRequestBytes,
            endpointFamilies: ["chat_completions"],
            notBeforeUnix: notBeforeUnix,
            expiresAtUnix: expiresAtUnix,
            kid: kid,
            keyRecordDigest: digest,
            signature: signature
        )
    }
}

struct RelayBlindEnvelope: Sendable, Equatable {
    static let version = "relay-blind-request-v1"
    static let mode = "required"
    static let endpointFamily = "chat_completions"
    static let maxCiphertextBytes = 1_048_576
    // Canonical base64url expansion plus a bounded allowance for the closed,
    // length-limited metadata fields.
    static let maxSerializedBytes = ((maxCiphertextBytes + 2) / 3) * 4 + 4_096

    let model: String
    let providerModel: String
    let stream: Bool
    let requestID: String
    let maxOutputTokens: UInt64
    let inputTokenUpperBound: UInt64
    let reservationTokenCap: UInt64
    let providerBinding: String
    let buyerBinding: String
    let keyRecordDigest: String
    let kid: String
    let buyerEphemeralPublicKey: Data
    let requestReplayNonce: Data
    let issuedAtUnix: Int64
    let ciphertext: Data
    let tag: Data

    static let keys: Set<String> = [
        "version", "mode", "endpoint_family", "model", "provider_model", "stream", "request_id",
        "max_output_tokens", "input_token_upper_bound", "reservation_token_cap", "provider_binding",
        "buyer_binding", "key_record_digest", "kid", "buyer_ephemeral_public_key",
        "request_replay_nonce", "issued_at_unix", "algorithm", "ciphertext", "tag",
    ]

    static func parse(_ body: String, nowUnix: Int64, allowedSkewSeconds: Int64 = 60) throws -> RelayBlindEnvelope {
        let data = Data(body.utf8)
        guard data.count <= maxSerializedBytes else { throw RelayBlindProviderError.invalidEnvelope }
        let raw = try RelayBlindStrictJSON.topLevelScalars(data)
        guard Set(raw.keys) == keys, Set(raw.keys).count == raw.keys.count,
              raw.isBoolean("stream"),
              raw.isUnsignedInteger("max_output_tokens"),
              raw.isUnsignedInteger("input_token_upper_bound"),
              raw.isUnsignedInteger("reservation_token_cap"),
              raw.isSignedInteger("issued_at_unix"),
              let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              object.count == keys.count,
              object["version"] as? String == version,
              object["mode"] as? String == mode,
              object["endpoint_family"] as? String == endpointFamily,
              object["algorithm"] as? String == RelayBlindKeyRecord.algorithm,
              let model = object["model"] as? String,
              let providerModel = object["provider_model"] as? String,
              let stream = object["stream"] as? Bool,
              let requestID = object["request_id"] as? String,
              let maxOutputTokens = RelayBlindStrictJSON.uint64(object["max_output_tokens"]),
              let inputTokenUpperBound = RelayBlindStrictJSON.uint64(object["input_token_upper_bound"]),
              let reservationTokenCap = RelayBlindStrictJSON.uint64(object["reservation_token_cap"]),
              let providerBinding = object["provider_binding"] as? String,
              let buyerBinding = object["buyer_binding"] as? String,
              let keyRecordDigest = object["key_record_digest"] as? String,
              let kid = object["kid"] as? String,
              let ephemeralText = object["buyer_ephemeral_public_key"] as? String,
              let replayText = object["request_replay_nonce"] as? String,
              let issuedAtUnix = RelayBlindStrictJSON.int64(object["issued_at_unix"]),
              let ciphertextText = object["ciphertext"] as? String,
              let tagText = object["tag"] as? String else {
            throw RelayBlindProviderError.invalidEnvelope
        }
        try RelayBlindValidation.printableASCII(model, maxBytes: 128)
        try RelayBlindValidation.printableASCII(providerModel, maxBytes: 128)
        try RelayBlindValidation.printableASCII(requestID, maxBytes: 128)
        guard maxOutputTokens > 0, inputTokenUpperBound > 0,
              maxOutputTokens <= UInt64(Int32.max), inputTokenUpperBound <= UInt64(Int32.max),
              reservationTokenCap <= UInt64(Int32.max),
              maxOutputTokens.addingReportingOverflow(inputTokenUpperBound).overflow == false,
              reservationTokenCap == maxOutputTokens + inputTokenUpperBound,
              issuedAtUnix >= 0, abs(nowUnix - issuedAtUnix) <= allowedSkewSeconds else {
            throw RelayBlindProviderError.invalidEnvelope
        }
        let providerBindingBytes = try RelayBlindBase64URL.decode(providerBinding, exactCount: 32)
        let buyerBindingBytes = try RelayBlindBase64URL.decode(buyerBinding, exactCount: 32)
        guard providerBinding.utf8.count == 43, buyerBinding.utf8.count == 43,
              providerBindingBytes.count == 32, buyerBindingBytes.count == 32,
              keyRecordDigest.utf8.count == 43, kid.utf8.count == 22 else {
            throw RelayBlindProviderError.invalidEnvelope
        }
        _ = try RelayBlindBase64URL.decode(keyRecordDigest, exactCount: 32)
        _ = try RelayBlindBase64URL.decode(kid, exactCount: 16)
        let ephemeral = try RelayBlindBase64URL.decode(ephemeralText, exactCount: 32)
        let replay = try RelayBlindBase64URL.decode(replayText, exactCount: 32)
        let ciphertext = try RelayBlindBase64URL.decode(ciphertextText)
        let tag = try RelayBlindBase64URL.decode(tagText, exactCount: 16)
        guard (1...maxCiphertextBytes).contains(ciphertext.count) else {
            throw RelayBlindProviderError.invalidEnvelope
        }
        return RelayBlindEnvelope(
            model: model,
            providerModel: providerModel,
            stream: stream,
            requestID: requestID,
            maxOutputTokens: maxOutputTokens,
            inputTokenUpperBound: inputTokenUpperBound,
            reservationTokenCap: reservationTokenCap,
            providerBinding: providerBinding,
            buyerBinding: buyerBinding,
            keyRecordDigest: keyRecordDigest,
            kid: kid,
            buyerEphemeralPublicKey: ephemeral,
            requestReplayNonce: replay,
            issuedAtUnix: issuedAtUnix,
            ciphertext: ciphertext,
            tag: tag
        )
    }

    var aad: Data {
        RelayBlindFraming.envelopeAAD(self)
    }
}

struct RelayBlindDispatchContext: Sendable, Equatable {
    static let keys: Set<String> = [
        "execution_auth_digest", "envelope_digest", "provider_binding_digest", "buyer_binding_digest",
        "kid", "assigned_session", "request_id", "input_token_upper_bound", "max_output_tokens",
    ]
    let executionAuthDigest: String
    let envelopeDigest: String
    let providerBindingDigest: String
    let buyerBindingDigest: String
    let kid: String
    let assignedSession: String
    let requestID: String
    let inputTokenUpperBound: UInt64
    let maxOutputTokens: UInt64

    static func parse(_ object: [String: Any]) throws -> RelayBlindDispatchContext {
        guard Set(object.keys) == keys,
              let execution = object["execution_auth_digest"] as? String,
              let envelope = object["envelope_digest"] as? String,
              let provider = object["provider_binding_digest"] as? String,
              let buyer = object["buyer_binding_digest"] as? String,
              let kid = object["kid"] as? String,
              let assigned = object["assigned_session"] as? String,
              let requestID = object["request_id"] as? String,
              let inputCap = RelayBlindStrictJSON.uint64(object["input_token_upper_bound"]),
              let outputCap = RelayBlindStrictJSON.uint64(object["max_output_tokens"]) else {
            throw RelayBlindProviderError.invalidEnvelope
        }
        for digest in [execution, envelope, provider, buyer] {
            _ = try RelayBlindBase64URL.decode(digest, exactCount: 32)
        }
        _ = try RelayBlindBase64URL.decode(kid, exactCount: 16)
        try RelayBlindValidation.printableASCII(assigned, maxBytes: 128)
        try RelayBlindValidation.printableASCII(requestID, maxBytes: 128)
        guard inputCap > 0, outputCap > 0 else { throw RelayBlindProviderError.invalidEnvelope }
        return RelayBlindDispatchContext(
            executionAuthDigest: execution, envelopeDigest: envelope,
            providerBindingDigest: provider, buyerBindingDigest: buyer,
            kid: kid, assignedSession: assigned, requestID: requestID,
            inputTokenUpperBound: inputCap, maxOutputTokens: outputCap
        )
    }

    func validate(envelope: RelayBlindEnvelope, envelopeBody: String, assignedSession: String?) throws {
        let computedEnvelope = RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(envelopeBody.utf8))))
        let computedProvider = RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(envelope.providerBinding.utf8))))
        let computedBuyer = RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(envelope.buyerBinding.utf8))))
        guard envelopeDigest == computedEnvelope,
              providerBindingDigest == computedProvider,
              buyerBindingDigest == computedBuyer,
              kid == envelope.kid,
              requestID == envelope.requestID,
              inputTokenUpperBound == envelope.inputTokenUpperBound,
              maxOutputTokens == envelope.maxOutputTokens,
              assignedSession == nil || self.assignedSession == assignedSession else {
            throw RelayBlindProviderError.invalidEnvelope
        }
    }
}

struct RelayBlindValidationEvidence: Sendable, Equatable {
    let context: RelayBlindDispatchContext
    let inputTokens: Int
    let state: String
    let errorCode: String?

    init(context: RelayBlindDispatchContext, inputTokens: Int, state: String, errorCode: String? = nil) {
        self.context = context
        self.inputTokens = inputTokens
        self.state = state
        self.errorCode = errorCode
    }

    var wireObject: [String: Any] {
        var object: [String: Any] = [
            "execution_auth_digest": context.executionAuthDigest,
            "envelope_digest": context.envelopeDigest,
            "kid": context.kid,
            "provider_binding_digest": context.providerBindingDigest,
            "buyer_binding_digest": context.buyerBindingDigest,
            "assigned_session": context.assignedSession,
            "request_id": context.requestID,
            "state": state,
            "input_tokens": inputTokens,
            "input_token_upper_bound": context.inputTokenUpperBound,
            "max_output_tokens": context.maxOutputTokens,
        ]
        if let errorCode { object["error_code"] = errorCode }
        return object
    }

    func terminal() -> RelayBlindValidationEvidence {
        RelayBlindValidationEvidence(context: context, inputTokens: inputTokens, state: "terminal")
    }

    func terminalWireObject() -> [String: Any] {
        state == "rejected" ? wireObject : terminal().wireObject
    }

    static func rejected(context: RelayBlindDispatchContext, error: RelayBlindProviderError) -> RelayBlindValidationEvidence {
        RelayBlindValidationEvidence(context: context, inputTokens: 0, state: "rejected", errorCode: error.code)
    }
}

struct RelayBlindProviderRejection: Error {
    let error: RelayBlindProviderError
    let evidence: RelayBlindValidationEvidence
    let claim: RelayBlindExecutionJournal.Claim
}

final class RelayBlindProviderRuntime: @unchecked Sendable {
    struct OpenedRequest: Sendable {
        let request: ChatCompletionRequest
        let envelope: RelayBlindEnvelope
        let context: RelayBlindDispatchContext
        let claim: RelayBlindExecutionJournal.Claim
    }

    let keyManager: RelayBlindKeyManager
    let journal: RelayBlindExecutionJournal
    let assignedSession: String?

    init(keyManager: RelayBlindKeyManager, journal: RelayBlindExecutionJournal, assignedSession: String? = nil) {
        self.keyManager = keyManager
        self.journal = journal
        self.assignedSession = assignedSession
    }

    func advertisedRecord(now: Date = Date()) throws -> RelayBlindKeyRecord {
        try keyManager.currentRecord(now: now)
    }

    func advertisedRecords(now: Date = Date()) throws -> [RelayBlindKeyRecord] {
        try keyManager.currentRecords(now: now)
    }

    func open(
        envelopeBody: String,
        outerRequestID: String,
        outerStream: Bool,
        contextObject: [String: Any],
        expectedAssignedSession: String?,
        now: Date = Date()
    ) throws -> OpenedRequest {
        let envelope = try RelayBlindEnvelope.parse(envelopeBody, nowUnix: Int64(now.timeIntervalSince1970))
        let context = try RelayBlindDispatchContext.parse(contextObject)
        try context.validate(
            envelope: envelope,
            envelopeBody: envelopeBody,
            assignedSession: expectedAssignedSession ?? assignedSession
        )
        guard envelope.requestID == outerRequestID, envelope.stream == outerStream else {
            throw RelayBlindProviderError.invalidEnvelope
        }
        let claim = try journal.claim(
            buyerBinding: envelope.buyerBinding,
            providerBinding: envelope.providerBinding,
            kid: envelope.kid,
            requestID: envelope.requestID,
            envelopeDigest: context.envelopeDigest,
            inputTokenUpperBound: envelope.inputTokenUpperBound,
            maxOutputTokens: envelope.maxOutputTokens,
            now: now
        )
        do {
            let active = try keyManager.key(for: envelope.kid, digest: envelope.keyRecordDigest, now: now)
            guard envelope.ciphertext.count <= active.record.maxEncryptedRequestBytes else {
                throw RelayBlindProviderError.invalidEnvelope
            }
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.buyerEphemeralPublicKey)
            let secret = try active.privateKey.sharedSecretFromKeyAgreement(with: peer)
            let shared = secret.withUnsafeBytes { Data($0) }
            guard shared.count == 32, shared.contains(where: { $0 != 0 }) else {
                throw RelayBlindProviderError.ciphertextInvalid
            }
            let transcript = Data(SHA256.hash(data: Data("macprovider/spec041/relay-blind/transcript/v1".utf8) + envelope.aad))
            let requestKey = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: transcript,
                sharedInfo: Data("macprovider/spec041/request/aead/v1".utf8),
                outputByteCount: 32
            )
            let nonceKey = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: transcript,
                sharedInfo: Data("macprovider/spec041/request/aead-nonce/v1".utf8),
                outputByteCount: 12
            )
            let nonceData = nonceKey.withUnsafeBytes { Data($0) }
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData), ciphertext: envelope.ciphertext, tag: envelope.tag
            )
            let plaintext: Data
            do {
                plaintext = try AES.GCM.open(sealed, using: requestKey, authenticating: envelope.aad)
            } catch {
                throw RelayBlindProviderError.ciphertextInvalid
            }
            guard plaintext.count <= active.record.maxEncryptedRequestBytes else {
                throw RelayBlindProviderError.ciphertextInvalid
            }
            let request = try ChatCompletionRequest.parse(data: plaintext).withIngestProvenance(.relay)
            guard request.model == envelope.model,
                  request.stream == envelope.stream,
                  request.maxTokens == Int(exactly: envelope.maxOutputTokens) else {
                throw RelayBlindProviderError.ciphertextInvalid
            }
            return OpenedRequest(request: request, envelope: envelope, context: context, claim: claim)
        } catch let error as RelayBlindProviderError {
            try? journal.markTerminal(claim, now: now)
            throw RelayBlindProviderRejection(
                error: error,
                evidence: .rejected(context: context, error: error),
                claim: claim
            )
        } catch {
            try? journal.markTerminal(claim, now: now)
            let providerError = RelayBlindProviderError.ciphertextInvalid
            throw RelayBlindProviderRejection(
                error: providerError,
                evidence: .rejected(context: context, error: providerError),
                claim: claim
            )
        }
    }
}

final class RelayBlindKeyManager: @unchecked Sendable {
    struct ActiveKey: @unchecked Sendable {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let record: RelayBlindKeyRecord
    }

    private let lock = NSLock()
    private let directory: URL
    private let secureDirectory: RelayBlindSecureDirectory
    private let identityKey: Curve25519.Signing.PrivateKey
    private var encryptionKey: Curve25519.KeyAgreement.PrivateKey
    private var notBeforeUnix: Int64
    private var expiresAtUnix: Int64
    private var revokedKids: Set<String>
    private let models: [String]
    private let maxEncryptedRequestBytes: UInt64
    private let lifetimeSeconds: Int64

    init(
        directory: URL,
        models: [String],
        maxEncryptedRequestBytes: UInt64 = 1_048_576,
        lifetimeSeconds: Int64 = 3_600,
        now: Date = Date()
    ) throws {
        guard directory.path.hasPrefix("/"), lifetimeSeconds > 0, lifetimeSeconds <= 86_400 else {
            throw RelayBlindProviderError.invalidConfiguration("relay-blind state directory and key lifetime are invalid")
        }
        let secureDirectory = try RelayBlindSecureDirectory.openOrCreate(directory)
        try RelayBlindSecureFiles.removeOrphanTemps(
            secureDirectory,
            allowedTargets: ["encryption.current.x25519", "encryption.current.json", "revoked-kids.json"]
        )
        self.directory = directory
        self.secureDirectory = secureDirectory
        self.models = try RelayBlindValidation.canonicalModels(models)
        self.maxEncryptedRequestBytes = maxEncryptedRequestBytes
        self.lifetimeSeconds = lifetimeSeconds
        self.identityKey = try RelayBlindSecureFiles.loadOrCreateSigningKey(secureDirectory, name: "identity.ed25519")
        let loaded = try RelayBlindSecureFiles.loadOrCreateAgreementKey(secureDirectory, name: "encryption.current.x25519")
        self.encryptionKey = loaded
        let nowUnix = Int64(now.timeIntervalSince1970)
        if let times = try RelayBlindSecureFiles.loadTimes(secureDirectory, name: "encryption.current.json"), times.0 < times.1, times.1 > nowUnix {
            self.notBeforeUnix = times.0
            self.expiresAtUnix = times.1
        } else {
            self.notBeforeUnix = max(0, nowUnix - 1)
            self.expiresAtUnix = nowUnix + lifetimeSeconds
            try RelayBlindSecureFiles.storeTimes(secureDirectory, name: "encryption.current.json", notBefore: self.notBeforeUnix, expiresAt: self.expiresAtUnix)
        }
        self.revokedKids = try RelayBlindSecureFiles.loadRevocations(secureDirectory, name: "revoked-kids.json")
    }

    func identityPublicKeyBase64URL() -> String {
        RelayBlindBase64URL.encode(identityKey.publicKey.rawRepresentation)
    }

    func identityFingerprintBase64URL() -> String {
        RelayBlindBase64URL.encode(Data(SHA256.hash(data: identityKey.publicKey.rawRepresentation)))
    }

    func currentRecord(now: Date = Date()) throws -> RelayBlindKeyRecord {
        guard let record = try currentRecords(now: now).first else {
            throw RelayBlindProviderError.providerUnsupported
        }
        return record
    }

    func currentRecords(now: Date = Date()) throws -> [RelayBlindKeyRecord] {
        lock.lock()
        defer { lock.unlock() }
        try reloadRevocationsLocked()
        let nowUnix = Int64(now.timeIntervalSince1970)
        if expiresAtUnix <= nowUnix {
            try rotateLocked(nowUnix: nowUnix)
        }
        let records = try models.map { try makeRecordLocked(models: [$0]) }
            .filter { !revokedKids.contains($0.kid) }
        return records
    }

    func key(for kid: String, digest: String, now: Date = Date()) throws -> ActiveKey {
        lock.lock()
        defer { lock.unlock() }
        try reloadRevocationsLocked()
        guard let record = try models.lazy.map({ try makeRecordLocked(models: [$0]) })
            .first(where: { $0.kid == kid }) else {
            throw RelayBlindProviderError.ciphertextInvalid
        }
        let nowUnix = Int64(now.timeIntervalSince1970)
        guard record.keyRecordDigest == digest,
              record.notBeforeUnix <= nowUnix, nowUnix < record.expiresAtUnix,
              !revokedKids.contains(kid) else {
            throw RelayBlindProviderError.ciphertextInvalid
        }
        return ActiveKey(privateKey: encryptionKey, record: record)
    }

    @discardableResult
    func rotate(now: Date = Date()) throws -> RelayBlindKeyRecord {
        lock.lock()
        defer { lock.unlock() }
        try rotateLocked(nowUnix: Int64(now.timeIntervalSince1970))
        return try makeRecordLocked(models: [models[0]])
    }

    func revokeCurrent(now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try reloadRevocationsLocked()
        for model in models {
            revokedKids.insert(try makeRecordLocked(models: [model]).kid)
        }
        try RelayBlindSecureFiles.storeRevocations(secureDirectory, name: "revoked-kids.json", revokedKids)
    }

    func revoke(kid: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try reloadRevocationsLocked()
        _ = try RelayBlindBase64URL.decode(kid, exactCount: 16)
        let currentKids = try Set(models.map { try makeRecordLocked(models: [$0]).kid })
        guard currentKids.contains(kid) else { throw RelayBlindProviderError.invalidConfiguration("unknown relay-blind kid") }
        revokedKids.insert(kid)
        try RelayBlindSecureFiles.storeRevocations(secureDirectory, name: "revoked-kids.json", revokedKids)
    }

    private func rotateLocked(nowUnix: Int64) throws {
        let next = Curve25519.KeyAgreement.PrivateKey()
        try RelayBlindSecureFiles.replaceSecret(secureDirectory, name: "encryption.current.x25519", data: next.rawRepresentation)
        encryptionKey = next
        notBeforeUnix = max(0, nowUnix - 1)
        expiresAtUnix = nowUnix + lifetimeSeconds
        try RelayBlindSecureFiles.storeTimes(secureDirectory, name: "encryption.current.json", notBefore: notBeforeUnix, expiresAt: expiresAtUnix)
    }

    private func reloadRevocationsLocked() throws {
        revokedKids = try RelayBlindSecureFiles.loadRevocations(secureDirectory, name: "revoked-kids.json")
    }

    private func makeRecordLocked(models: [String]) throws -> RelayBlindKeyRecord {
        try RelayBlindKeyRecord.make(
            identityKey: identityKey,
            encryptionKey: encryptionKey,
            models: models,
            maxEncryptedRequestBytes: maxEncryptedRequestBytes,
            notBeforeUnix: notBeforeUnix,
            expiresAtUnix: expiresAtUnix
        )
    }
}

final class RelayBlindExecutionJournal: @unchecked Sendable {
    struct Claim: Sendable, Equatable {
        let filename: String
        let path: String
        let envelopeDigest: String
    }

    private let directory: URL
    private let secureDirectory: RelayBlindSecureDirectory
    private let maxEntries: Int
    private let replayRetentionSeconds: TimeInterval
    private let lock = NSLock()

    init(
        directory: URL,
        maxEntries: Int = 100_000,
        replayRetentionSeconds: TimeInterval = 86_400,
        now: Date = Date()
    ) throws {
        guard maxEntries > 0 else { throw RelayBlindProviderError.invalidConfiguration("journal capacity is invalid") }
        guard replayRetentionSeconds > 0 else {
            throw RelayBlindProviderError.invalidConfiguration("journal replay retention is invalid")
        }
        let secureDirectory = try RelayBlindSecureDirectory.openOrCreate(directory)
        try RelayBlindSecureFiles.removeOrphanJournalTemps(secureDirectory)
        self.directory = directory
        self.secureDirectory = secureDirectory
        self.maxEntries = maxEntries
        self.replayRetentionSeconds = replayRetentionSeconds
        try Self.recoverUncertainEntries(in: secureDirectory, now: now)
    }

    func claim(
        buyerBinding: String,
        providerBinding: String,
        kid: String,
        requestID: String,
        envelopeDigest: String,
        inputTokenUpperBound: UInt64,
        maxOutputTokens: UInt64,
        now: Date
    ) throws -> Claim {
        lock.lock()
        defer { lock.unlock() }
        var identity = Data()
        identity.appendFramed(Data(buyerBinding.utf8))
        identity.appendFramed(Data(providerBinding.utf8))
        identity.appendFramed(Data(kid.utf8))
        identity.appendFramed(Data(requestID.utf8))
        identity.appendFramed(Data(envelopeDigest.utf8))
        let filename = Data(SHA256.hash(data: identity)).map { String(format: "%02x", $0) }.joined() + ".json"
        let path = secureDirectory.displayPath(for: filename)
        do {
            try pruneExpiredTerminalEntries(now: now)
        } catch {
            throw RelayBlindProviderError.journalUnavailable
        }
        guard let count = try? secureDirectory.contents().count else {
            throw RelayBlindProviderError.journalUnavailable
        }
        if count >= maxEntries {
            if secureDirectory.exists(filename) { throw RelayBlindProviderError.executionAlreadyClaimed }
            throw RelayBlindProviderError.journalUnavailable
        }
        let payload: [String: Any] = [
            "version": "relay-blind-execution-journal-v1",
            "state": "claimed",
            "envelope_digest": envelopeDigest,
            "created_at_unix": Int64(now.timeIntervalSince1970),
            "input_token_upper_bound": inputTokenUpperBound,
            "max_output_tokens": maxOutputTokens,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        do {
            try RelayBlindSecureFiles.createExclusive(secureDirectory, name: filename, data: data)
        } catch RelayBlindSecureFileError.alreadyExists {
            throw RelayBlindProviderError.executionAlreadyClaimed
        } catch {
            throw RelayBlindProviderError.journalUnavailable
        }
        return Claim(filename: filename, path: path, envelopeDigest: envelopeDigest)
    }

    func markValidated(_ claim: Claim, inputTokens: Int, now: Date = Date()) throws {
        try update(claim, state: "validated", inputTokens: inputTokens, now: now)
    }

    func markTerminal(_ claim: Claim, inputTokens: Int? = nil, now: Date = Date()) throws {
        try update(claim, state: "terminal", inputTokens: inputTokens, now: now)
    }

    private func update(_ claim: Claim, state: String, inputTokens: Int?, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard var object = try RelayBlindSecureFiles.loadStateObject(secureDirectory, name: claim.filename, maxBytes: 4096),
                  object["version"] as? String == "relay-blind-execution-journal-v1",
                  object["envelope_digest"] as? String == claim.envelopeDigest else {
                throw RelayBlindSecureFileError.invalid
            }
            object["state"] = state
            object["updated_at_unix"] = Int64(now.timeIntervalSince1970)
            if let inputTokens { object["input_tokens"] = inputTokens }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try RelayBlindSecureFiles.replaceAtomically(secureDirectory, name: claim.filename, data: data)
        } catch {
            throw RelayBlindProviderError.journalUnavailable
        }
    }

    private func pruneExpiredTerminalEntries(now: Date) throws {
        let filenames = try Self.validatedFilenames(in: secureDirectory)
        let cutoff = Int64(now.timeIntervalSince1970 - replayRetentionSeconds)
        var removedAny = false
        for filename in filenames {
            guard let object = try RelayBlindSecureFiles.loadStateObject(secureDirectory, name: filename, maxBytes: 4096),
                  object["version"] as? String == "relay-blind-execution-journal-v1",
                  let state = object["state"] as? String else {
                throw RelayBlindSecureFileError.invalid
            }
            guard state == "terminal" || state == "unknown_postdispatch" else {
                guard state == "claimed" || state == "validated" else {
                    throw RelayBlindSecureFileError.invalid
                }
                continue
            }
            let retainedFrom = RelayBlindStrictJSON.int64(object["updated_at_unix"])
                ?? RelayBlindStrictJSON.int64(object["created_at_unix"])
            guard let retainedFrom, retainedFrom <= cutoff else { continue }
            try secureDirectory.remove(filename)
            removedAny = true
        }
        if removedAny { try secureDirectory.synchronize() }
    }

    private static func validatedFilenames(in directory: RelayBlindSecureDirectory) throws -> [String] {
        let filenames: [String]
        do {
            filenames = try directory.contents()
        } catch {
            throw RelayBlindProviderError.journalUnavailable
        }
        for filename in filenames {
            guard filename.hasSuffix(".json"), filename.count == 69,
                  filename.dropLast(5).allSatisfy({ $0.isHexDigit }) else {
                throw RelayBlindProviderError.journalUnavailable
            }
        }
        return filenames
    }

    private static func recoverUncertainEntries(in directory: RelayBlindSecureDirectory, now: Date) throws {
        let filenames = try validatedFilenames(in: directory)
        for filename in filenames {
            do {
                guard var object = try RelayBlindSecureFiles.loadStateObject(directory, name: filename, maxBytes: 4096),
                      object["version"] as? String == "relay-blind-execution-journal-v1",
                      let state = object["state"] as? String else {
                    throw RelayBlindSecureFileError.invalid
                }
                if state == "claimed" || state == "validated" {
                    object["state"] = "unknown_postdispatch"
                    object["updated_at_unix"] = Int64(now.timeIntervalSince1970)
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    try RelayBlindSecureFiles.replaceAtomically(directory, name: filename, data: data)
                } else if state != "terminal" && state != "unknown_postdispatch" {
                    throw RelayBlindSecureFileError.invalid
                }
            } catch {
                throw RelayBlindProviderError.journalUnavailable
            }
        }
    }
}

enum RelayBlindFraming {
    static func keyRecordImmutable(
        publicKey: Data,
        identityFingerprint: Data,
        models: [String],
        maxEncryptedRequestBytes: UInt64
    ) -> Data {
        var data = Data()
        data.appendFramed(Data(RelayBlindKeyRecord.algorithm.utf8))
        data.appendFramed(publicKey)
        data.appendFramed(identityFingerprint)
        data.appendUnsigned32(UInt32(models.count))
        for model in models { data.appendFramed(Data(model.utf8)) }
        data.appendUnsigned64(maxEncryptedRequestBytes)
        data.appendUnsigned32(1)
        data.appendFramed(Data("chat_completions".utf8))
        data.appendFramed(Data(RelayBlindKeyRecord.signatureAlgorithm.utf8))
        return data
    }

    static func envelopeAAD(_ value: RelayBlindEnvelope) -> Data {
        var data = Data()
        data.appendFramed(Data(RelayBlindEnvelope.version.utf8))
        data.appendFramed(Data(RelayBlindEnvelope.mode.utf8))
        data.appendFramed(Data(RelayBlindEnvelope.endpointFamily.utf8))
        data.appendFramed(Data(value.model.utf8))
        data.appendFramed(Data(value.providerModel.utf8))
        data.appendUnsigned64(value.stream ? 1 : 0)
        data.appendFramed(Data(value.requestID.utf8))
        data.appendUnsigned64(value.maxOutputTokens)
        data.appendUnsigned64(value.inputTokenUpperBound)
        data.appendUnsigned64(value.reservationTokenCap)
        data.appendFramed(Data(value.providerBinding.utf8))
        data.appendFramed(Data(value.buyerBinding.utf8))
        data.appendFramed(Data(value.keyRecordDigest.utf8))
        data.appendFramed(Data(value.kid.utf8))
        data.appendFramed(value.buyerEphemeralPublicKey)
        data.appendFramed(value.requestReplayNonce)
        data.appendSigned64(value.issuedAtUnix)
        data.appendFramed(Data(RelayBlindKeyRecord.algorithm.utf8))
        return data
    }
}

enum RelayBlindBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String, exactCount: Int? = nil) throws -> Data {
        guard !text.isEmpty,
              !text.contains("="),
              text.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (65...90).contains($0.value) ||
                      (97...122).contains($0.value) || $0 == "-" || $0 == "_"
              }) else { throw RelayBlindProviderError.invalidEnvelope }
        let remainder = text.utf8.count % 4
        guard remainder != 1 else { throw RelayBlindProviderError.invalidEnvelope }
        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard), encode(data) == text,
              exactCount == nil || data.count == exactCount else {
            throw RelayBlindProviderError.invalidEnvelope
        }
        return data
    }
}

enum RelayBlindValidation {
    static func printableASCII(_ value: String, maxBytes: Int) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maxBytes,
              bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else {
            throw RelayBlindProviderError.invalidEnvelope
        }
    }

    static func canonicalModels(_ models: [String]) throws -> [String] {
        guard (1...16).contains(models.count) else {
            throw RelayBlindProviderError.invalidConfiguration("relay-blind model scope is empty or overbroad")
        }
        for model in models { try printableASCII(model, maxBytes: 128) }
        let sorted = models.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        guard Set(sorted).count == sorted.count else {
            throw RelayBlindProviderError.invalidConfiguration("relay-blind model scope contains duplicates")
        }
        return sorted
    }
}

enum RelayBlindStrictJSON {
    enum Scalar: Equatable {
        case string(String)
        case number(String)
        case boolean(Bool)
        case null
    }

    struct TopLevelScalars {
        let entries: [(String, Scalar)]
        var keys: [String] { entries.map(\.0) }

        func isBoolean(_ key: String) -> Bool {
            guard let scalar = entries.first(where: { $0.0 == key })?.1,
                  case .boolean = scalar else { return false }
            return true
        }

        func isUnsignedInteger(_ key: String) -> Bool {
            guard let scalar = entries.first(where: { $0.0 == key })?.1,
                  case .number(let text) = scalar else { return false }
            return Self.isCanonicalUnsigned(text)
        }

        func isSignedInteger(_ key: String) -> Bool {
            guard let scalar = entries.first(where: { $0.0 == key })?.1,
                  case .number(let text) = scalar else { return false }
            if text.hasPrefix("-") { return Self.isCanonicalUnsigned(String(text.dropFirst())) }
            return Self.isCanonicalUnsigned(text)
        }

        private static func isCanonicalUnsigned(_ text: String) -> Bool {
            let bytes = Array(text.utf8)
            guard !bytes.isEmpty, bytes.allSatisfy({ (48...57).contains($0) }) else { return false }
            return bytes.count == 1 || bytes[0] != 48
        }
    }

    static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e"), !text.hasPrefix("-") else { return nil }
        return UInt64(text)
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e") else { return nil }
        return Int64(text)
    }

    static func topLevelScalars(_ data: Data) throws -> TopLevelScalars {
        let bytes = Array(data)
        var index = 0
        func skipWhitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func parseString() throws -> String {
            guard index < bytes.count, bytes[index] == 0x22 else { throw RelayBlindProviderError.invalidEnvelope }
            let start = index
            index += 1
            var escaped = false
            var closed = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped { escaped = false; continue }
                if byte == 0x5c { escaped = true; continue }
                if byte == 0x22 { closed = true; break }
            }
            guard closed,
                  let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                throw RelayBlindProviderError.invalidEnvelope
            }
            return value
        }
        func consume(_ literal: [UInt8]) -> Bool {
            guard index + literal.count <= bytes.count,
                  Array(bytes[index..<(index + literal.count)]) == literal else { return false }
            index += literal.count
            return true
        }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x7b else { throw RelayBlindProviderError.invalidEnvelope }
        index += 1
        var entries: [(String, Scalar)] = []
        while true {
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x7d {
                index += 1
                break
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3a else { throw RelayBlindProviderError.invalidEnvelope }
            index += 1
            skipWhitespace()
            let scalar: Scalar
            if index < bytes.count, bytes[index] == 0x22 {
                scalar = .string(try parseString())
            } else if consume(Array("true".utf8)) {
                scalar = .boolean(true)
            } else if consume(Array("false".utf8)) {
                scalar = .boolean(false)
            } else if consume(Array("null".utf8)) {
                scalar = .null
            } else {
                let start = index
                while index < bytes.count,
                      ![9, 10, 13, 32, 44, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw RelayBlindProviderError.invalidEnvelope }
                scalar = .number(String(decoding: bytes[start..<index], as: UTF8.self))
            }
            entries.append((key, scalar))
            skipWhitespace()
            guard index < bytes.count else { throw RelayBlindProviderError.invalidEnvelope }
            if bytes[index] == 0x2c {
                index += 1
                skipWhitespace()
                guard index < bytes.count, bytes[index] != 0x7d else {
                    throw RelayBlindProviderError.invalidEnvelope
                }
                continue
            }
            if bytes[index] == 0x7d { index += 1; break }
            throw RelayBlindProviderError.invalidEnvelope
        }
        skipWhitespace()
        guard index == bytes.count else { throw RelayBlindProviderError.invalidEnvelope }
        return TopLevelScalars(entries: entries)
    }
}

private enum RelayBlindSecureFileError: Error { case alreadyExists, invalid }

private final class RelayBlindSecureDirectory: @unchecked Sendable {
    let path: String
    private let descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    static func openOrCreate(_ url: URL) throws -> RelayBlindSecureDirectory {
        var path = url.standardizedFileURL.path
        // macOS exposes these immutable root-owned aliases by default. Resolve only
        // these known aliases; user-controlled symlink components remain rejected.
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        guard path.hasPrefix("/"), path != cwd, !path.hasPrefix(cwd + "/") else {
            throw RelayBlindProviderError.invalidConfiguration("relay-blind state must be outside the repository/current directory")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("/") }) else {
            throw RelayBlindSecureFileError.invalid
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw RelayBlindSecureFileError.invalid }
        var keepCurrent = false
        defer { if !keepCurrent { close(current) } }
        for (index, component) in components.enumerated() {
            let isLeaf = index == components.count - 1
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0, isLeaf, errno == ENOENT {
                guard mkdirat(current, component, 0o700) == 0,
                      fsync(current) == 0 else { throw RelayBlindSecureFileError.invalid }
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard next >= 0 else { throw RelayBlindSecureFileError.invalid }
            var value = stat()
            let valid: Bool
            if fstat(next, &value) != 0 || (value.st_mode & S_IFMT) != S_IFDIR {
                valid = false
            } else if isLeaf {
                valid = value.st_uid == getuid() && (value.st_mode & 0o077) == 0
            } else {
                valid = (value.st_uid == 0 || value.st_uid == getuid()) && (value.st_mode & 0o022) == 0
            }
            guard valid else { close(next); throw RelayBlindSecureFileError.invalid }
            close(current)
            current = next
        }
        keepCurrent = true
        return RelayBlindSecureDirectory(path: path, descriptor: current)
    }

    func displayPath(for name: String) -> String { path + "/" + name }

    func contents() throws -> [String] {
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard copy >= 0 else { throw RelayBlindSecureFileError.invalid }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw RelayBlindSecureFileError.invalid
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let end = raw.firstIndex(of: 0) ?? raw.count
                return String(decoding: raw[..<end], as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw RelayBlindSecureFileError.invalid }
        return names
    }

    func openFile(_ name: String, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        try validate(name)
        let fd = openat(descriptor, name, flags | O_NOFOLLOW, mode)
        if fd < 0 {
            if errno == EEXIST { throw RelayBlindSecureFileError.alreadyExists }
            throw RelayBlindSecureFileError.invalid
        }
        return fd
    }

    func exists(_ name: String) -> Bool {
        guard (try? validate(name)) != nil else { return false }
        var value = stat()
        return fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0
    }

    func validatePrivateRegularFile(_ name: String, maxBytes: Int) throws {
        let fd = try openFile(name, flags: O_RDONLY)
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == getuid(),
              (value.st_mode & 0o077) == 0,
              value.st_size >= 0,
              value.st_size <= maxBytes else {
            throw RelayBlindSecureFileError.invalid
        }
    }

    func rename(_ source: String, to destination: String) throws {
        try validate(source)
        try validate(destination)
        guard renameat(descriptor, source, descriptor, destination) == 0 else {
            throw RelayBlindSecureFileError.invalid
        }
    }

    func remove(_ name: String) throws {
        try validate(name)
        guard unlinkat(descriptor, name, 0) == 0 else { throw RelayBlindSecureFileError.invalid }
    }

    func synchronize() throws {
        guard fsync(descriptor) == 0 else { throw RelayBlindSecureFileError.invalid }
    }

    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.utf8.count <= Int(NAME_MAX) else {
            throw RelayBlindSecureFileError.invalid
        }
    }
}

private enum RelayBlindSecureFiles {
    static func removeOrphanTemps(_ directory: RelayBlindSecureDirectory, allowedTargets: Set<String>) throws {
        try removeOrphanTemps(directory) { allowedTargets.contains($0) }
    }

    static func removeOrphanJournalTemps(_ directory: RelayBlindSecureDirectory) throws {
        try removeOrphanTemps(directory) { target in
            target.hasSuffix(".json") && target.count == 69 &&
                target.dropLast(5).allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        }
    }

    private static func removeOrphanTemps(
        _ directory: RelayBlindSecureDirectory,
        targetAllowed: (String) -> Bool
    ) throws {
        var removedAny = false
        for name in try directory.contents() where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            let body = name.dropFirst().dropLast(4)
            guard let separator = body.lastIndex(of: ".") else { throw RelayBlindSecureFileError.invalid }
            let target = String(body[..<separator])
            let uuidText = String(body[body.index(after: separator)...])
            guard targetAllowed(target), let uuid = UUID(uuidString: uuidText), uuid.uuidString == uuidText else {
                throw RelayBlindSecureFileError.invalid
            }
            try directory.validatePrivateRegularFile(name, maxBytes: RelayBlindEnvelope.maxSerializedBytes)
            try directory.remove(name)
            removedAny = true
        }
        if removedAny { try directory.synchronize() }
    }

    static func loadOrCreateSigningKey(_ directory: RelayBlindSecureDirectory, name: String) throws -> Curve25519.Signing.PrivateKey {
        if let data = try loadSecret(directory, name: name) { return try Curve25519.Signing.PrivateKey(rawRepresentation: data) }
        let key = Curve25519.Signing.PrivateKey()
        do { try createExclusive(directory, name: name, data: key.rawRepresentation) }
        catch RelayBlindSecureFileError.alreadyExists {
            guard let data = try loadSecret(directory, name: name) else { throw RelayBlindSecureFileError.invalid }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        return key
    }

    static func loadOrCreateAgreementKey(_ directory: RelayBlindSecureDirectory, name: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = try loadSecret(directory, name: name) { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) }
        let key = Curve25519.KeyAgreement.PrivateKey()
        do { try createExclusive(directory, name: name, data: key.rawRepresentation) }
        catch RelayBlindSecureFileError.alreadyExists {
            guard let data = try loadSecret(directory, name: name) else { throw RelayBlindSecureFileError.invalid }
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        return key
    }

    static func loadSecret(_ directory: RelayBlindSecureDirectory, name: String) throws -> Data? {
        let fd: Int32
        do { fd = try directory.openFile(name, flags: O_RDONLY) }
        catch RelayBlindSecureFileError.invalid { if !directory.exists(name) { return nil }; throw RelayBlindSecureFileError.invalid }
        defer { close(fd) }
        var statValue = stat()
        guard fstat(fd, &statValue) == 0, (statValue.st_mode & S_IFMT) == S_IFREG,
              statValue.st_uid == getuid(), (statValue.st_mode & 0o077) == 0,
              statValue.st_size == 32 else { throw RelayBlindSecureFileError.invalid }
        var data = Data(count: 32)
        let readCount = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, 32) }
        guard readCount == 32 else { throw RelayBlindSecureFileError.invalid }
        return data
    }

    static func createExclusive(_ directory: RelayBlindSecureDirectory, name: String, data: Data) throws {
        let fd = try directory.openFile(name, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        var success = false
        defer { close(fd); if !success { try? directory.remove(name) } }
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: written), data.count - written) }
            guard count > 0 else { throw RelayBlindSecureFileError.invalid }
            written += count
        }
        guard fsync(fd) == 0 else { throw RelayBlindSecureFileError.invalid }
        success = true
        try directory.synchronize()
    }

    static func replaceSecret(_ directory: RelayBlindSecureDirectory, name: String, data: Data) throws {
        try replaceAtomically(directory, name: name, data: data)
    }

    static func replaceAtomically(_ directory: RelayBlindSecureDirectory, name: String, data: Data) throws {
        let temp = ".\(name).\(UUID().uuidString).tmp"
        try createExclusive(directory, name: temp, data: data)
        do { try directory.rename(temp, to: name) }
        catch { try? directory.remove(temp); throw RelayBlindSecureFileError.invalid }
        let fd = try directory.openFile(name, flags: O_RDONLY)
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RelayBlindSecureFileError.invalid }
        try directory.synchronize()
    }

    static func loadTimes(_ directory: RelayBlindSecureDirectory, name: String) throws -> (Int64, Int64)? {
        guard let object = try loadStateObject(directory, name: name, maxBytes: 4096) else { return nil }
        guard Set(object.keys) == ["not_before_unix", "expires_at_unix"],
              let notBefore = RelayBlindStrictJSON.int64(object["not_before_unix"]),
              let expires = RelayBlindStrictJSON.int64(object["expires_at_unix"]) else { return nil }
        return (notBefore, expires)
    }

    static func storeTimes(_ directory: RelayBlindSecureDirectory, name: String, notBefore: Int64, expiresAt: Int64) throws {
        let data = try JSONSerialization.data(withJSONObject: ["not_before_unix": notBefore, "expires_at_unix": expiresAt], options: [.sortedKeys])
        try replaceAtomically(directory, name: name, data: data)
    }

    static func loadRevocations(_ directory: RelayBlindSecureDirectory, name: String) throws -> Set<String> {
        guard let data = try loadState(directory, name: name, maxBytes: 16_384) else { return [] }
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String] else { throw RelayBlindSecureFileError.invalid }
        for value in values { _ = try RelayBlindBase64URL.decode(value, exactCount: 16) }
        return Set(values)
    }

    static func storeRevocations(_ directory: RelayBlindSecureDirectory, name: String, _ values: Set<String>) throws {
        let data = try JSONSerialization.data(withJSONObject: values.sorted(), options: [])
        try replaceAtomically(directory, name: name, data: data)
    }

    static func loadStateObject(_ directory: RelayBlindSecureDirectory, name: String, maxBytes: Int) throws -> [String: Any]? {
        guard let data = try loadState(directory, name: name, maxBytes: maxBytes) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func loadState(_ directory: RelayBlindSecureDirectory, name: String, maxBytes: Int) throws -> Data? {
        let fd: Int32
        do { fd = try directory.openFile(name, flags: O_RDONLY) }
        catch RelayBlindSecureFileError.invalid { if !directory.exists(name) { return nil }; throw RelayBlindSecureFileError.invalid }
        defer { close(fd) }
        var statValue = stat()
        guard fstat(fd, &statValue) == 0,
              (statValue.st_mode & S_IFMT) == S_IFREG,
              statValue.st_uid == getuid(),
              (statValue.st_mode & 0o077) == 0,
              statValue.st_size >= 0,
              statValue.st_size <= maxBytes else {
            throw RelayBlindSecureFileError.invalid
        }
        let byteCount = Int(statValue.st_size)
        var data = Data(count: byteCount)
        var readCount = 0
        while readCount < byteCount {
            let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: readCount), byteCount - readCount) }
            guard count > 0 else { throw RelayBlindSecureFileError.invalid }
            readCount += count
        }
        return data
    }
}

private extension Data {
    mutating func appendUnsigned32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value)])
    }

    mutating func appendUnsigned64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((value >> UInt64(shift)) & 0xff)) }
    }

    mutating func appendSigned64(_ value: Int64) { appendUnsigned64(UInt64(bitPattern: value)) }

    mutating func appendFramed(_ value: Data) {
        appendUnsigned32(UInt32(value.count))
        append(value)
    }
}
