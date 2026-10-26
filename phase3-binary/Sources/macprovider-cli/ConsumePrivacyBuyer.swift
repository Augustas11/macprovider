import CryptoKit
import Foundation

/// No predispatch error permits falling back to plaintext. Once the encrypted
/// inference POST is attempted, uncertainty must never cause resubmission.
enum ConsumePrivacyBuyerError: Error, Equatable {
    case preDispatch(code: String)
    case doNotResubmit(code: String)
}

/// Buyer orchestration for the SPEC-041/049 protocol. Request AAD, signed key
/// framing and response key/frame derivation are shared with the provider.
/// As in relay-blind-client, no plaintext is released before the authenticated
/// final frame and the relay's bounded clear usage/disclosures agree.
struct ConsumePrivacyBuyer: Sendable {
    static let maximumResponseBytes = 2 << 20
    let directoryPublicKey: String
    var requiredAssurance: String? = nil

    private var assurance: String { requiredAssurance ?? PrivacyClassConstants.assurance }

    func forward(_ request: ConsumeUpstreamRequest, family: String) async throws -> ConsumeUpstreamResponse {
        var attemptedInference = false
        do {
            guard requiredAssurance == nil || requiredAssurance == "code_bound_attested",
                  ["chat_completions", "responses", "messages"].contains(family),
                  request.body.count > 0, request.body.count <= RelayBlindEnvelope.maxCiphertextBytes,
                  let base = URL(string: request.origin), base.scheme == "https",
                  base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
                  base.host != nil, base.path.isEmpty || base.path == "/",
                  !request.bearerToken.isEmpty,
                  !request.bearerToken.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw invalid("local_privacy_configuration_invalid")
            }
            let pinnedKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: RelayBlindBase64URL.decode(directoryPublicKey, exactCount: 32)
            )
            let input = try Self.requestMetadata(request.body, family: family, streaming: request.streaming)
            let network = ConsumePrivacyHTTP()
            let directoryResponse = try await network.exchange(
                url: base.appendingPathComponent("v1/privacy-class/directory"), method: "GET",
                bearer: request.bearerToken, body: nil, headers: [:], cancellation: request.cancellation,
                limit: 1 << 20
            )
            guard directoryResponse.response.statusCode == 200 else { throw invalid("local_privacy_directory_unavailable") }
            let directory = try Self.verifyDirectory(directoryResponse.data, publicKey: pinnedKey, now: Date())
            var reservationBody: [String: Any] = [
                "endpoint_family": family, "model": input.model, "stream": request.streaming,
                "max_output_tokens": input.outputCap, "input_token_upper_bound": input.inputCap,
                "encrypted_request_bytes": request.body.count,
            ]
            if !input.requires.isEmpty { reservationBody["requires"] = input.requires }
            var reservationHeaders = Self.privacyHeaders
            if let requiredAssurance { reservationHeaders["X-MacProvider-Privacy-Assurance-Required"] = requiredAssurance }
            let reserved = try await network.exchange(
                url: base.appendingPathComponent("v1/relay-blind/route-reservations"), method: "POST",
                bearer: request.bearerToken, body: try Self.encode(reservationBody),
                headers: reservationHeaders, cancellation: request.cancellation, limit: 1 << 20
            )
            guard reserved.response.statusCode == 200 else { throw invalid("local_privacy_reservation_unavailable") }
            let reservation = try Self.verifyReservation(
                reserved.data, input: input, family: family, stream: request.streaming,
                assurance: assurance, directory: directory, now: Date()
            )
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let secret = try privateKey.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: reservation.key.publicKey)
            )
            var shared = secret.withUnsafeBytes { Data($0) }
            defer { shared.resetBytes(in: 0..<shared.count) }
            guard shared.contains(where: { $0 != 0 }) else { throw invalid("local_privacy_key_rejected") }
            let requestID = "req_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            // CryptoKit supplies fresh cryptographic entropy for both ephemeral
            // material and the independent request replay nonce.
            var replayNonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            defer { replayNonce.resetBytes(in: 0..<replayNonce.count) }
            var envelope: [String: Any] = [
                "version": RelayBlindEnvelope.version, "mode": RelayBlindEnvelope.mode,
                "endpoint_family": family, "model": input.model,
                "provider_model": reservation.providerModel, "stream": request.streaming,
                "request_id": requestID, "max_output_tokens": input.outputCap,
                "input_token_upper_bound": input.inputCap,
                "reservation_token_cap": input.inputCap + input.outputCap,
                "provider_binding": reservation.providerBinding, "buyer_binding": reservation.buyerBinding,
                "key_record_digest": reservation.key.keyRecordDigest, "kid": reservation.key.kid,
                "buyer_ephemeral_public_key": RelayBlindBase64URL.encode(privateKey.publicKey.rawRepresentation),
                "request_replay_nonce": RelayBlindBase64URL.encode(replayNonce),
                "issued_at_unix": Int64(Date().timeIntervalSince1970),
                "algorithm": RelayBlindKeyRecord.algorithm,
                "ciphertext": RelayBlindBase64URL.encode(Data([0])),
                "tag": RelayBlindBase64URL.encode(Data(repeating: 0, count: 16)),
            ]
            if !input.requires.isEmpty { envelope["requires"] = input.requires }
            let parsed = try RelayBlindEnvelope.parse(
                String(decoding: Self.encode(envelope), as: UTF8.self), nowUnix: Int64(Date().timeIntervalSince1970)
            )
            let aad = parsed.aad
            let requestCipher = try parsed.requestCipher(sharedSecret: secret)
            var nonce = requestCipher.nonce
            defer { nonce.resetBytes(in: 0..<nonce.count) }
            let sealed = try AES.GCM.seal(request.body, using: requestCipher.key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            envelope["ciphertext"] = RelayBlindBase64URL.encode(sealed.ciphertext)
            envelope["tag"] = RelayBlindBase64URL.encode(sealed.tag)
            let encryptedBody = try Self.encode(envelope)
            // Digest exactly the transmitted JSON bytes, never a re-serialization.
            let digest = RelayBlindBase64URL.encode(Data(SHA256.hash(data: encryptedBody)))
            let responseKeys = try PrivacyResponseSealer.derive(sharedSecret: secret, aad: aad)
            guard !Task.isCancelled, request.cancellation?.isCancelled() != true else {
                throw invalid("local_privacy_cancelled")
            }
            let endpoint = family == "chat_completions" ? "chat/completions" : family
            var headers = Self.privacyHeaders
            headers["X-Request-ID"] = requestID
            headers["Accept"] = request.streaming ? "text/event-stream" : "application/json"
            attemptedInference = true
            let response = try await network.exchange(
                url: base.appendingPathComponent("v1/" + endpoint), method: "POST",
                bearer: request.bearerToken, body: encryptedBody, headers: headers,
                cancellation: request.cancellation, limit: Self.maximumResponseBytes
            )
            guard (200..<300).contains(response.response.statusCode) else {
                throw invalid("local_privacy_inference_failed")
            }
            try Self.verifyResponseHeaders(response.response, assurance: assurance)
            let opened = try Self.openResponse(
                response.data, streaming: request.streaming, responseKey: responseKeys.key,
                noncePrefix: responseKeys.noncePrefix, digest: digest, kid: reservation.key.kid,
                requestID: requestID, model: input.model, inputCap: input.inputCap,
                outputCap: input.outputCap, assurance: assurance
            )
            let verifiedHeaders = [
                ("content-type", request.streaming ? "text/event-stream" : "application/json"),
                ("cache-control", "no-store"),
                ("x-macprovider-privacy-class", PrivacyClassConstants.v1),
                ("x-macprovider-privacy-assurance", assurance),
                ("x-macprovider-response-encryption", PrivacyClassConstants.responseEncryption),
                ("x-macprovider-requested-privacy-mode", "relay_blind_required"),
                ("x-macprovider-effective-privacy-outcome", "relay_blind_satisfied"),
                ("x-macprovider-privacy-mode", "relay_blind_required"),
                ("x-macprovider-privacy-mode-disclosure", "content_hidden_from_network_relays; serving_provider_runtime_reads_plaintext; metadata_visible_to_relays"),
            ]
            return ConsumeUpstreamResponse(statusCode: response.response.statusCode, headers: verifiedHeaders,
                                           body: opened.body, verifiedUsage: opened.usage)
        } catch {
            // Never expose remote error bodies, crypto errors, content, or keys.
            if attemptedInference { throw ConsumePrivacyBuyerError.doNotResubmit(code: "local_privacy_do_not_resubmit") }
            if let classified = error as? ConsumePrivacyBuyerError { throw classified }
            throw invalid("local_privacy_pre_dispatch_rejected")
        }
    }

    private static let privacyHeaders = [
        "X-MacProvider-Privacy-Class": PrivacyClassConstants.v1,
        "X-MacProvider-Privacy-Mode": "relay_blind_required",
    ]

    private func invalid(_ code: String) -> ConsumePrivacyBuyerError { .preDispatch(code: code) }

    struct RequestMetadata {
        let model: String
        let outputCap: UInt64
        let inputCap: UInt64
        let requires: [String]
    }

    static func requestMetadata(_ data: Data, family: String, streaming: Bool) throws -> RequestMetadata {
        let object = try object(data)
        let model = try string(object, "model")
        try RelayBlindValidation.printableASCII(model, maxBytes: 128)
        if let value = object["stream"] {
            guard let stream = value as? NSNumber, CFGetTypeID(stream) == CFBooleanGetTypeID(),
                  stream.boolValue == streaming else { throw PrivacyClassError.invalidMaterial }
        } else if streaming { throw PrivacyClassError.invalidMaterial }
        let field = family == "responses" ? "max_output_tokens" : "max_tokens"
        let output: UInt64
        if let cap = object[field] {
            guard let parsed = RelayBlindStrictJSON.uint64(cap), parsed > 0 else { throw PrivacyClassError.invalidMaterial }
            output = parsed
        } else if family == "chat_completions", let cap = object["max_completion_tokens"] {
            guard let parsed = RelayBlindStrictJSON.uint64(cap), parsed > 0 else { throw PrivacyClassError.invalidMaterial }
            output = parsed
        } else {
            // The provider bounds an omitted Chat/Responses cap to this
            // envelope cap; the original encrypted body stays byte-identical.
            output = 4096
        }
        let input = UInt64(data.count) + 4096
        guard output <= UInt64(Int32.max), input + output <= UInt64(Int32.max) else { throw PrivacyClassError.invalidMaterial }
        var required: [String] = []
        if let format = object["response_format"] as? [String: Any], format["type"] as? String == "json_schema",
           let schema = format["json_schema"] as? [String: Any], schema["strict"] as? Bool != true {
            required = [RelayBlindEnvelope.capabilityJSONSchemaNonStrict]
        }
        if family == "responses", let text = object["text"] as? [String: Any],
           let format = text["format"] as? [String: Any], format["type"] as? String == "json_schema",
           format["strict"] as? Bool != true {
            required = [RelayBlindEnvelope.capabilityJSONSchemaNonStrict]
        }
        return RequestMetadata(model: model, outputCap: output, inputCap: input, requires: required)
    }

    struct Directory {
        let issuedAt: Int64
        let expiresAt: Int64
        let entries: [[String: Any]]
    }

    static func verifyDirectory(_ raw: Data, publicKey: Curve25519.Signing.PublicKey, now: Date) throws -> Directory {
        let envelope = try object(raw, keys: ["version", "key_id", "payload", "signature"])
        guard try string(envelope, "version") == "privacy-identity-directory-envelope-v1",
              try string(envelope, "key_id") == fingerprint(publicKey.rawRepresentation) else { throw PrivacyClassError.invalidMaterial }
        let payload = try RelayBlindBase64URL.decode(string(envelope, "payload"))
        let signature = try RelayBlindBase64URL.decode(string(envelope, "signature"), exactCount: 64)
        var framed = Data()
        framed.appendFramed(Data("macprovider/spec049/identity-directory/v1".utf8))
        framed.appendFramed(payload)
        guard publicKey.isValidSignature(signature, for: framed) else { throw PrivacyClassError.invalidMaterial }
        let directory = try object(payload, keys: ["version", "privacy_class", "issued_at_unix", "expires_at_unix", "entries"])
        let issued = try signed(directory, "issued_at_unix"), expires = try signed(directory, "expires_at_unix")
        let clock = Int64(now.timeIntervalSince1970)
        guard try string(directory, "version") == "privacy-identity-directory-v1",
              try string(directory, "privacy_class") == PrivacyClassConstants.v1,
              issued >= 0, expires > issued, expires - issued >= 60, expires - issued <= 3600,
              issued <= clock + 60, expires > clock,
              let entries = directory["entries"] as? [[String: Any]], entries.count <= 4096 else { throw PrivacyClassError.invalidMaterial }
        var previous = ""
        for entry in entries {
            try exact(entry, ["identity_public_key", "fingerprint", "se_public_key_fingerprint", "source", "enrolled_at_unix", "revoked"])
            let identity = try RelayBlindBase64URL.decode(string(entry, "identity_public_key"), exactCount: 32)
            let current = try string(entry, "fingerprint")
            _ = try RelayBlindBase64URL.decode(string(entry, "se_public_key_fingerprint"), exactCount: 32)
            guard current == fingerprint(identity), current > previous,
                  ["enrolled", "operator_pin"].contains(try string(entry, "source")),
                  try signed(entry, "enrolled_at_unix") >= 0,
                  let flag = entry["revoked"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw PrivacyClassError.invalidMaterial }
            previous = current
        }
        return Directory(issuedAt: issued, expiresAt: expires, entries: entries)
    }

    struct Reservation {
        let key: RelayBlindKeyRecord
        let providerBinding: String
        let buyerBinding: String
        let providerModel: String
    }

    static func verifyReservation(_ raw: Data, input: RequestMetadata, family: String, stream: Bool,
                                          assurance: String, directory: Directory, now: Date) throws -> Reservation {
        let expected: Set<String> = ["version", "provider_binding", "buyer_binding", "key_record_digest", "key_record", "kid",
            "endpoint_family", "model", "provider_model", "stream", "max_encrypted_request_bytes", "max_output_tokens",
            "input_token_upper_bound", "reservation_token_cap", "expires_at_unix", "cache_policy", "failover_policy",
            "privacy_class", "privacy_assurance", "privacy_key_attestation", "privacy_key_attestation_signature", "privacy_posture_verified_at_unix"]
        let reservation = try object(raw, keys: expected)
        let clock = Int64(now.timeIntervalSince1970)
        guard try string(reservation, "version") == PrivacyClassConstants.reservationVersion,
              try string(reservation, "endpoint_family") == family,
              try string(reservation, "model") == input.model,
              try boolean(reservation, "stream") == stream,
              try unsigned(reservation, "max_output_tokens") == input.outputCap,
              try unsigned(reservation, "input_token_upper_bound") == input.inputCap,
              try unsigned(reservation, "reservation_token_cap") == input.inputCap + input.outputCap,
              try string(reservation, "cache_policy") == "no-store",
              try string(reservation, "failover_policy") == "disabled",
              try string(reservation, "privacy_class") == PrivacyClassConstants.v1,
              try string(reservation, "privacy_assurance") == assurance,
              try signed(reservation, "privacy_posture_verified_at_unix") > 0,
              try signed(reservation, "expires_at_unix") > clock,
              directory.expiresAt > clock,
              let record = reservation["key_record"] as? [String: Any] else { throw PrivacyClassError.invalidMaterial }
        try exact(record, ["alg", "public_key", "identity_fingerprint", "models", "max_encrypted_request_bytes", "endpoint_families",
                           "signature_algorithm", "not_before_unix", "expires_at_unix", "kid", "key_record_digest", "signature"])
        let fingerprint = try string(record, "identity_fingerprint")
        guard let entry = directory.entries.first(where: { $0["fingerprint"] as? String == fingerprint }),
              try !boolean(entry, "revoked"),
              let models = record["models"] as? [String], let families = record["endpoint_families"] as? [String],
              try RelayBlindValidation.canonicalModels(models) == models, models.contains(input.model),
              !families.isEmpty, families == families.sorted(), Set(families).count == families.count,
              Set(families).isSubset(of: ["chat_completions", "responses", "messages"]), families.contains(family),
              try string(record, "alg") == RelayBlindKeyRecord.algorithm,
              try string(record, "signature_algorithm") == RelayBlindKeyRecord.signatureAlgorithm else { throw PrivacyClassError.invalidMaterial }
        let notBefore = try signed(record, "not_before_unix"), expires = try signed(record, "expires_at_unix")
        let capacity = try unsigned(record, "max_encrypted_request_bytes")
        guard notBefore >= 0, notBefore <= clock + 60, expires > clock, expires > notBefore, expires - notBefore <= 3600,
              try signed(reservation, "expires_at_unix") <= expires,
              capacity > 0, capacity <= UInt64(RelayBlindEnvelope.maxCiphertextBytes),
              try unsigned(reservation, "max_encrypted_request_bytes") <= capacity,
              try unsigned(reservation, "max_encrypted_request_bytes") >= input.inputCap - 4096 else { throw PrivacyClassError.invalidMaterial }
        let key = RelayBlindKeyRecord(
            publicKey: try RelayBlindBase64URL.decode(string(record, "public_key"), exactCount: 32),
            identityFingerprint: try RelayBlindBase64URL.decode(fingerprint, exactCount: 32), models: models,
            maxEncryptedRequestBytes: capacity, endpointFamilies: families, notBeforeUnix: notBefore, expiresAtUnix: expires,
            kid: try string(record, "kid"), keyRecordDigest: try string(record, "key_record_digest"),
            signature: try RelayBlindBase64URL.decode(string(record, "signature"), exactCount: 64)
        )
        let immutable = RelayBlindFraming.keyRecordImmutable(publicKey: key.publicKey, identityFingerprint: key.identityFingerprint,
            models: key.models, maxEncryptedRequestBytes: key.maxEncryptedRequestBytes, endpointFamilies: families)
        var signedRecord = immutable
        signedRecord.appendSigned64(notBefore); signedRecord.appendSigned64(expires)
        let identity = try Curve25519.Signing.PublicKey(rawRepresentation: RelayBlindBase64URL.decode(string(entry, "identity_public_key"), exactCount: 32))
        guard key.kid == RelayBlindBase64URL.encode(Data(SHA256.hash(data: immutable).prefix(16))),
              key.keyRecordDigest == Self.fingerprint(signedRecord),
              try string(reservation, "kid") == key.kid,
              try string(reservation, "key_record_digest") == key.keyRecordDigest,
              identity.isValidSignature(key.signature, for: signedRecord),
              let attested = reservation["privacy_key_attestation"] as? [String: Any] else { throw PrivacyClassError.invalidMaterial }
        try exact(attested, ["version", "key_record_digest", "privacy_class", "assurance", "binary_version", "code_cdhash", "not_before_unix", "expires_at_unix"])
        let attestation = PrivacyKeyAttestation(version: try string(attested, "version"), keyRecordDigest: try string(attested, "key_record_digest"),
            privacyClass: try string(attested, "privacy_class"), assurance: try string(attested, "assurance"),
            binaryVersion: try string(attested, "binary_version"), codeCDHash: try string(attested, "code_cdhash"),
            notBeforeUnix: try signed(attested, "not_before_unix"), expiresAtUnix: try signed(attested, "expires_at_unix"))
        let signature = try RelayBlindBase64URL.decode(string(reservation, "privacy_key_attestation_signature"), exactCount: 64)
        guard attestation.privacyClass == PrivacyClassConstants.v1, attestation.assurance == PrivacyClassConstants.assurance,
              attestation.keyRecordDigest == key.keyRecordDigest, attestation.notBeforeUnix == notBefore, attestation.expiresAtUnix == expires,
              identity.isValidSignature(signature, for: try attestation.framing()) else { throw PrivacyClassError.invalidMaterial }
        let providerBinding = try string(reservation, "provider_binding"), buyerBinding = try string(reservation, "buyer_binding")
        _ = try RelayBlindBase64URL.decode(providerBinding, exactCount: 32)
        _ = try RelayBlindBase64URL.decode(buyerBinding, exactCount: 32)
        let providerModel = try string(reservation, "provider_model")
        try RelayBlindValidation.printableASCII(providerModel, maxBytes: 128)
        return Reservation(key: key, providerBinding: providerBinding, buyerBinding: buyerBinding, providerModel: providerModel)
    }

    private static func verifyResponseHeaders(_ response: HTTPURLResponse, assurance: String) throws {
        for (name, wanted) in [
            "X-MacProvider-Requested-Privacy-Mode": "relay_blind_required",
            "X-MacProvider-Effective-Privacy-Outcome": "relay_blind_satisfied",
            "X-MacProvider-Privacy-Class": PrivacyClassConstants.v1,
            "X-MacProvider-Privacy-Assurance": assurance,
            "X-MacProvider-Response-Encryption": PrivacyClassConstants.responseEncryption,
        ] {
            // Foundation joins duplicate response values with a comma; exact
            // comparison refuses duplicates as well as a changed value.
            guard response.value(forHTTPHeaderField: name) == wanted else { throw PrivacyClassError.invalidMaterial }
        }
    }

    static func openResponse(_ raw: Data, streaming: Bool, responseKey: SymmetricKey, noncePrefix: Data,
                             digest: String, kid: String, requestID: String, model: String,
                             inputCap: UInt64, outputCap: UInt64, assurance: String) throws -> (body: Data, usage: Data) {
        guard raw.count <= maximumResponseBytes, noncePrefix.count == 4 else { throw PrivacyClassError.invalidMaterial }
        var frames: [[String: Any]] = []
        var usage: [String: Any]?
        if streaming {
            guard let text = String(data: raw, encoding: .utf8) else { throw PrivacyClassError.invalidMaterial }
            var done = false, final = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = line.last == "\r" ? line.dropLast() : line[...]
                if line.isEmpty { continue }
                guard !done, line.hasPrefix("data:") else { throw PrivacyClassError.invalidMaterial }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    guard final, usage != nil else { throw PrivacyClassError.invalidMaterial }
                    done = true; continue
                }
                let event = try object(Data(payload.utf8))
                if event["object"] as? String == PrivacyClassConstants.frameObject {
                    guard !final, usage == nil else { throw PrivacyClassError.invalidMaterial }
                    final = try boolean(event, "final")
                    frames.append(event)
                } else {
                    try exact(event, ["object", "model", "choices", "usage"])
                    guard final, usage == nil, event["object"] as? String == "chat.completion.chunk",
                          event["model"] as? String == model,
                          let choices = event["choices"] as? [Any], choices.isEmpty,
                          let value = event["usage"] as? [String: Any] else { throw PrivacyClassError.invalidMaterial }
                    usage = value
                }
            }
            guard done else { throw PrivacyClassError.invalidMaterial }
        } else {
            let response = try object(raw, keys: ["object", "version", "frames", "usage"])
            guard response["object"] as? String == PrivacyClassConstants.responseObject,
                  response["version"] as? String == PrivacyClassConstants.responseVersion,
                  let values = response["frames"] as? [[String: Any]],
                  let value = response["usage"] as? [String: Any] else { throw PrivacyClassError.invalidMaterial }
            frames = values; usage = value
        }
        guard !frames.isEmpty, frames.count < 1 << 20, let usage else { throw PrivacyClassError.invalidMaterial }
        var plaintext = Data(), finalPayload: Data?
        defer { if finalPayload != nil { finalPayload!.resetBytes(in: 0..<finalPayload!.count) } }
        do {
            for (index, frame) in frames.enumerated() {
                try exact(frame, ["object", "version", "seq", "final", "ciphertext"])
                let final = try boolean(frame, "final")
                guard frame["object"] as? String == PrivacyClassConstants.frameObject,
                      frame["version"] as? String == PrivacyClassConstants.responseVersion,
                      try unsigned(frame, "seq") == UInt64(index), final == (index == frames.count - 1) else { throw PrivacyClassError.invalidMaterial }
                let ciphertext = try RelayBlindBase64URL.decode(string(frame, "ciphertext"))
                guard ciphertext.count >= 16, ciphertext.count <= RelayBlindEnvelope.maxCiphertextBytes + 16 else { throw PrivacyClassError.invalidMaterial }
                var nonce = noncePrefix; nonce.appendUnsigned64(UInt64(index))
                let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
                var opened = try AES.GCM.open(sealed, using: responseKey, authenticating: PrivacyResponseSealer.frameAAD(
                    envelopeDigest: digest, kid: kid, requestID: requestID, stream: streaming, seq: UInt64(index), final: final))
                defer { opened.resetBytes(in: 0..<opened.count) }
                guard plaintext.count <= maximumResponseBytes - raw.count - opened.count else { throw PrivacyClassError.invalidMaterial }
                if final { finalPayload = opened } else { plaintext.append(opened) }
            }
            guard let finalPayload else { throw PrivacyClassError.invalidMaterial }
            let final = try object(finalPayload, keys: ["version", "status", "prompt_tokens", "completion_tokens"])
            guard finalPayload.count <= 4096, final["version"] as? String == PrivacyClassConstants.finalVersion,
                  final["status"] as? String == "complete" else { throw PrivacyClassError.invalidMaterial }
            let finalPrompt = try signed(final, "prompt_tokens"), finalCompletion = try signed(final, "completion_tokens")
            guard finalPrompt >= 0, finalCompletion >= 0 else { throw PrivacyClassError.invalidMaterial }
            let prompt = min(UInt64(finalPrompt), inputCap), completion = min(UInt64(finalCompletion), outputCap)
            guard try unsigned(usage, "prompt_tokens") == prompt, try unsigned(usage, "completion_tokens") == completion,
                  try unsigned(usage, "total_tokens") == prompt + completion else { throw PrivacyClassError.invalidMaterial }
            try verifyDisclosure(usage, assurance: assurance)
            return (plaintext, try encode(usage))
        } catch {
            plaintext.resetBytes(in: 0..<plaintext.count)
            throw error
        }
    }

    private static func verifyDisclosure(_ usage: [String: Any], assurance: String) throws {
        guard let meta = usage["macprovider"] as? [String: Any],
              meta["requested_privacy_mode"] as? String == "relay_blind_required",
              meta["effective_privacy_outcome"] as? String == "relay_blind_satisfied",
              meta["scope"] as? String == "request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays",
              let settlement = meta["settlement"] as? [String: Any],
              settlement["verified_model_settlement"] as? String == "unavailable_for_relay_blind_request",
              settlement["usage_settlement"] as? String == "standard_usage_settlement_and_clear_cap_enforcement_still_apply",
              let privacy = meta["privacy"] as? [String: Any] else { throw PrivacyClassError.invalidMaterial }
        try exact(privacy, ["class", "assurance", "scope", "protects", "does_not_protect", "residual_risks", "posture_verified_at_unix"])
        let disclosure = ConsumePrivacyDisclosure(assurance: assurance)
        guard privacy["class"] as? String == PrivacyClassConstants.v1, privacy["assurance"] as? String == assurance,
              privacy["scope"] as? String == disclosure.scope,
              privacy["protects"] as? [String] == disclosure.protects,
              privacy["does_not_protect"] as? [String] == disclosure.doesNotProtect,
              privacy["residual_risks"] as? [String] == disclosure.residualRisks,
              try signed(privacy, "posture_verified_at_unix") > 0 else { throw PrivacyClassError.invalidMaterial }
    }

    private static func object(_ raw: Data, keys: Set<String>? = nil) throws -> [String: Any] {
        try AutotuneStrictJSON.rejectDuplicateKeys(raw)
        guard let result = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw PrivacyClassError.invalidMaterial }
        if let keys { try exact(result, keys) }
        return result
    }
    private static func exact(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw PrivacyClassError.invalidMaterial }
    }
    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw PrivacyClassError.invalidMaterial }; return value
    }
    private static func signed(_ object: [String: Any], _ key: String) throws -> Int64 {
        guard let value = RelayBlindStrictJSON.int64(object[key]) else { throw PrivacyClassError.invalidMaterial }; return value
    }
    private static func unsigned(_ object: [String: Any], _ key: String) throws -> UInt64 {
        guard let value = RelayBlindStrictJSON.uint64(object[key]) else { throw PrivacyClassError.invalidMaterial }; return value
    }
    private static func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw PrivacyClassError.invalidMaterial }; return value.boolValue
    }
    private static func encode(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private static func fingerprint(_ bytes: Data) -> String { RelayBlindBase64URL.encode(Data(SHA256.hash(data: bytes))) }
}

/// Only one URLSession task is ever created per exchange. Redirects, cookies,
/// caches and credential challenges are refused; received bytes are capped as
/// they arrive rather than after URLSession has accumulated an unbounded body.
private final class ConsumePrivacyHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: Sendable { let data: Data; let response: HTTPURLResponse }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var limit = 0
    private var session: URLSession?

    func exchange(url: URL, method: String, bearer: String, body: Data?, headers: [String: String],
                  cancellation: ConsumeUpstreamCancellationHandle?, limit: Int) async throws -> Result {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); self.continuation = continuation; self.body = Data(); self.response = nil
                self.limit = limit; self.session = session; lock.unlock()
                cancellation?.setCancel { task.cancel() }
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        }, onCancel: { task.cancel() })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let valid = (response as? HTTPURLResponse) != nil && (response.expectedContentLength < 0 || response.expectedContentLength <= limit)
        if valid { self.response = response as? HTTPURLResponse }
        lock.unlock()
        completionHandler(valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let overflow = body.count > limit - data.count
        if !overflow { body.append(data) }
        lock.unlock()
        if overflow { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let completion = continuation; continuation = nil
        let data = body, response = response; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let error { completion?.resume(throwing: error) }
        else if let response { completion?.resume(returning: Result(data: data, response: response)) }
        else { completion?.resume(throwing: PrivacyClassError.invalidMaterial) }
    }
}

/// Fixed SPEC-049-R020 strings, kept equal to the reference buyer client.
struct ConsumePrivacyDisclosure {
    let assurance: String
    var codeBound: Bool { assurance == "code_bound_attested" }
    var scope: String {
        codeBound
            ? "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_asserted_by_apple_attested_malibu_app_after_kernel_code_identity_check; label_verified_by_coordinator_not_by_buyer"
            : "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_self_attested_device_bound_not_code_bound"
    }
    var protects: [String] {
        ["request_content_from_gateway_and_coordinator", "response_content_from_gateway_and_coordinator",
         "debugger_attach_to_approved_signed_runtime", "core_dumps_of_approved_signed_runtime",
         "prompt_and_completion_in_provider_logs_traces_receipts_and_telemetry", "prompt_and_completion_in_provider_disk_and_conversation_caches",
         "plaintext_proxy_or_subprocess_runtime_hop", "dev_debug_unsigned_or_unapproved_builds_refused_by_routing",
         "sip_disabled_hosts_refused_by_routing"] + (codeBound ? ["modified_or_resigned_runtime_binary_refused_by_attested_app_check",
            "modified_or_resigned_malibu_app_cannot_assert_posture", "posture_replay_refused_by_attested_counter"] : [])
    }
    var doesNotProtect: [String] {
        if codeBound { return ["provider_runtime_reads_plaintext_to_infer", "request_metadata_visible_to_relays",
            "confidential_compute_or_hardware_enclave_execution", "end_to_end_encryption_excluding_the_provider",
            "kernel_or_firmware_compromise_with_sip_on", "compromised_team_signing_key", "pool_scoped_requests"] }
        return ["provider_runtime_reads_plaintext_to_infer", "operator_running_a_modified_runtime_binary",
            "request_metadata_visible_to_relays", "confidential_compute_or_hardware_enclave_execution",
            "end_to_end_encryption_excluding_the_provider", "pool_scoped_requests"]
    }
    var residualRisks: [String] {
        let common = ["physical_or_hardware_attack", "gpu_and_unified_memory_residue", "encrypted_swap_and_hibernation_images",
            "compromise_of_the_live_runtime_process", "malicious_signed_release_or_supply_chain"]
        let tail = ["crash_report_register_and_stack_residue", "secure_boot_level_not_evaluated", "immutable_prompt_strings_not_zeroized",
            "relays_observe_sizes_timing_and_token_counts", "provider_identity_enrolled_on_first_attested_session",
            "coordinator_operator_signs_provider_identity_directory"]
        if codeBound { return ["kernel_or_firmware_compromise_with_sip_on"] + common + ["compromised_team_signing_key",
            "apple_is_root_of_trust_for_app_attest", "sip_and_full_security_attested_when_app_attest_key_was_attested",
            "label_verified_by_coordinator_not_by_buyer"] + tail }
        return ["modified_binary_can_forge_posture_se_key_device_bound_not_code_bound", "root_sip_bypass_kernel_or_firmware_compromise"] + common + tail
    }
}
