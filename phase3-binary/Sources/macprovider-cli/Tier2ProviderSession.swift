import CryptoKit
import Foundation

struct Tier2AuthAttempt: @unchecked Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKeyRaw: Data
    let publicKeyBase64URL: String

    init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        publicKeyRaw = privateKey.publicKey.rawRepresentation
        publicKeyBase64URL = publicKeyRaw.base64URLUnpadded()
    }
}

final class Tier2ProviderSession: @unchecked Sendable {
    static let aeadSuite = "A256GCM"

    struct RequestPayload: Sendable {
        let body: String
        let conversationKey: String?
    }

    struct LosslessnessProbePayload {
        let outerEnvelope: [String: Any]
    }

    let providerID: String
    let assignedID: String
    let selectedAEAD: String
    let keyID: String
    let c2pKey: Data
    let p2cKey: Data
    let c2pNonceBase: Data
    let p2cNonceBase: Data

    private let lock = NSLock()
    private var responseChunkPlaintextEnvelope = false
    private var c2pCounter: UInt64 = 0
    private var p2cCounter: UInt64 = 0

    init(
        providerID: String,
        assignedID: String,
        selectedAEAD: String,
        keyID: String,
        c2pKey: Data,
        p2cKey: Data,
        c2pNonceBase: Data,
        p2cNonceBase: Data
    ) throws {
        guard selectedAEAD == Self.aeadSuite else {
            throw Tier2ProviderError.unsupportedAEAD(selectedAEAD)
        }
        guard c2pKey.count == 32, p2cKey.count == 32, c2pNonceBase.count == 4, p2cNonceBase.count == 4 else {
            throw Tier2ProviderError.invalidKeyMaterial
        }
        self.providerID = providerID
        self.assignedID = assignedID
        self.selectedAEAD = selectedAEAD
        self.keyID = keyID
        self.c2pKey = c2pKey
        self.p2cKey = p2cKey
        self.c2pNonceBase = c2pNonceBase
        self.p2cNonceBase = p2cNonceBase
    }

    convenience init(
        attempt: Tier2AuthAttempt,
        providerID: String,
        assignedID: String,
        coordinatorPublicKeyBase64URL: String,
        selectedAEAD: String,
        expectedKeyID: String?
    ) throws {
        guard selectedAEAD == Self.aeadSuite else {
            throw Tier2ProviderError.unsupportedAEAD(selectedAEAD)
        }
        let coordinatorPublicRaw = try Data(base64URLUnpadded: coordinatorPublicKeyBase64URL)
        guard coordinatorPublicRaw.count == 32 else {
            throw Tier2ProviderError.invalidCoordinatorPublicKey
        }
        let coordinatorPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: coordinatorPublicRaw)
        let sharedSecret = try attempt.privateKey.sharedSecretFromKeyAgreement(with: coordinatorPublic)
        let transcript = Self.transcript(
            providerID: providerID,
            assignedID: assignedID,
            providerPublicKey: attempt.publicKeyRaw,
            coordinatorPublicKey: coordinatorPublicRaw,
            selectedAEAD: selectedAEAD
        )
        let keyID = Data(SHA256.hash(data: transcript).prefix(16)).base64URLUnpadded()
        if let expectedKeyID, expectedKeyID != keyID {
            throw Tier2ProviderError.keyIDMismatch(expected: expectedKeyID, derived: keyID)
        }
        try self.init(
            providerID: providerID,
            assignedID: assignedID,
            selectedAEAD: selectedAEAD,
            keyID: keyID,
            c2pKey: sharedSecret.hkdfData(salt: transcript, info: Data("macprovider/spec008/c2p/aead/v1".utf8), count: 32),
            p2cKey: sharedSecret.hkdfData(salt: transcript, info: Data("macprovider/spec008/p2c/aead/v1".utf8), count: 32),
            c2pNonceBase: sharedSecret.hkdfData(salt: transcript, info: Data("macprovider/spec008/c2p/nonce/v1".utf8), count: 4),
            p2cNonceBase: sharedSecret.hkdfData(salt: transcript, info: Data("macprovider/spec008/p2c/nonce/v1".utf8), count: 4)
        )
    }

    func enableResponseChunkPlaintextEnvelope() {
        lock.lock()
        responseChunkPlaintextEnvelope = true
        lock.unlock()
    }

    var countersForTest: (c2p: UInt64, p2c: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (c2pCounter, p2cCounter)
    }

    func openAEADRekeyCommit(_ message: [String: Any], rekeyID: String) throws -> Data {
        guard message["encrypted"] as? Bool == true,
              let enc = message["enc"] as? [String: Any]
        else {
            throw Tier2ProviderError.invalidEnvelope
        }
        lock.lock()
        defer { lock.unlock() }
        guard c2pCounter == 0 else {
            throw Tier2ProviderError.invalidEnvelope
        }
        let aad = Tier2FrameAAD(
            type: "aead_rekey_commit",
            direction: "c2p",
            requestID: rekeyID,
            stream: false,
            providerID: providerID,
            assignedID: assignedID,
            seq: 0
        )
        let plaintext = try Self.openEnvelope(
            enc,
            key: c2pKey,
            nonceBase: c2pNonceBase,
            keyID: keyID,
            expectedAAD: aad,
            expectedSeq: 0
        )
        c2pCounter = 1
        return plaintext
    }

    func sealAEADRekeyCommitted(rekeyID: String, proof: Data) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard p2cCounter == 0 else {
            throw Tier2ProviderError.invalidEnvelope
        }
        let aad = Tier2FrameAAD(
            type: "aead_rekey_committed",
            direction: "p2c",
            requestID: rekeyID,
            stream: false,
            providerID: providerID,
            assignedID: assignedID,
            seq: 0
        )
        let enc = try Self.sealEnvelope(
            proof,
            key: p2cKey,
            nonceBase: p2cNonceBase,
            keyID: keyID,
            aad: aad,
            seq: 0
        )
        p2cCounter = 1
        return enc
    }

    func openRequestBody(message: [String: Any], requestID: String, stream: Bool) throws -> String {
        try openRequestPayload(message: message, requestID: requestID, stream: stream).body
    }

    func openRequestPayload(message: [String: Any], requestID: String, stream: Bool) throws -> RequestPayload {
        guard message["encrypted"] as? Bool == true,
              let enc = message["enc"] as? [String: Any]
        else {
            throw Tier2ProviderError.invalidEnvelope
        }
        lock.lock()
        defer { lock.unlock() }
        let seq = c2pCounter
        let aad = Tier2FrameAAD(
            type: "inference_request",
            direction: "c2p",
            requestID: requestID,
            stream: stream,
            providerID: providerID,
            assignedID: assignedID,
            seq: seq
        )
        let plaintext = try Self.openEnvelope(enc, key: c2pKey, nonceBase: c2pNonceBase, keyID: keyID, expectedAAD: aad, expectedSeq: seq)
        c2pCounter += 1
        guard String(data: plaintext, encoding: .utf8) != nil else {
            throw Tier2ProviderError.invalidPlaintext
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              envelope["type"] as? String == "inference_request_plaintext",
              let envelopeBody = envelope["body"] as? String else {
            throw Tier2ProviderError.invalidPlaintext
        }
        let conversationKey = (envelope["conversation_key"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RequestPayload(
            body: envelopeBody,
            conversationKey: conversationKey?.isEmpty == false ? conversationKey : nil
        )
    }

    func openLosslessnessProbeRequestPayload(message: [String: Any], requestID: String) throws -> LosslessnessProbePayload {
        guard message["type"] as? String == LosslessnessProbeProtocol.encryptedRequestType,
              message["encrypted"] as? Bool == true,
              message["stream"] as? Bool == false,
              let enc = message["enc"] as? [String: Any]
        else {
            throw Tier2ProviderError.invalidEnvelope
        }
        lock.lock()
        defer { lock.unlock() }
        let seq = c2pCounter
        let aad = Tier2FrameAAD(
            type: LosslessnessProbeProtocol.encryptedRequestType,
            direction: "c2p",
            requestID: requestID,
            stream: false,
            providerID: providerID,
            assignedID: assignedID,
            seq: seq
        )
        let plaintext = try Self.openEnvelope(enc, key: c2pKey, nonceBase: c2pNonceBase, keyID: keyID, expectedAAD: aad, expectedSeq: seq)
        c2pCounter += 1
        guard let envelope = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              envelope["type"] as? String == LosslessnessProbeProtocol.requestPlaintextType,
              let payload = envelope["payload"] as? [String: Any] else {
            throw Tier2ProviderError.invalidPlaintext
        }
        return LosslessnessProbePayload(outerEnvelope: payload)
    }

    func sealLosslessnessProbeResult(requestID: String, outerEnvelope: [String: Any]) throws -> [String: Any] {
        let plaintext = try JSONSerialization.data(
            withJSONObject: [
                "type": LosslessnessProbeProtocol.resultPlaintextType,
                "payload": outerEnvelope,
            ],
            options: [.sortedKeys]
        )
        lock.lock()
        defer { lock.unlock() }
        let seq = p2cCounter
        let aad = Tier2FrameAAD(
            type: LosslessnessProbeProtocol.encryptedResultType,
            direction: "p2c",
            requestID: requestID,
            stream: false,
            providerID: providerID,
            assignedID: assignedID,
            seq: seq
        )
        let enc = try Self.sealEnvelope(
            plaintext,
            key: p2cKey,
            nonceBase: p2cNonceBase,
            keyID: keyID,
            aad: aad,
            seq: seq
        )
        p2cCounter += 1
        return [
            "type": LosslessnessProbeProtocol.encryptedResultType,
            "request_id": requestID,
            "stream": false,
            "encrypted": true,
            "enc": enc,
        ]
    }

    func sealResponseChunk(requestID: String, stream: Bool, seq: Int, plaintext: String) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let plaintextData: Data
        if responseChunkPlaintextEnvelope {
            let plaintextEnvelope: [String: Any] = [
                "type": "inference_response_chunk_plaintext",
                "seq": seq,
                "data": plaintext,
            ]
            plaintextData = try JSONSerialization.data(withJSONObject: plaintextEnvelope, options: [.sortedKeys])
        } else {
            plaintextData = Data(plaintext.utf8)
        }
        let aeadSeq = p2cCounter
        let aad = Tier2FrameAAD(
            type: "inference_response_chunk",
            direction: "p2c",
            requestID: requestID,
            stream: stream,
            providerID: providerID,
            assignedID: assignedID,
            seq: aeadSeq
        )
        let enc = try Self.sealEnvelope(
            plaintextData,
            key: p2cKey,
            nonceBase: p2cNonceBase,
            keyID: keyID,
            aad: aad,
            seq: aeadSeq
        )
        p2cCounter += 1
        return [
            "type": "inference_response_chunk",
            "request_id": requestID,
            "encrypted": true,
            "enc": enc,
        ]
    }

    func sealResponseEnd(requestID: String, stream: Bool, payload: [String: Any]) throws -> [String: Any] {
        let plaintext = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        lock.lock()
        defer { lock.unlock() }
        let seq = p2cCounter
        let aad = Tier2FrameAAD(
            type: "inference_response_end",
            direction: "p2c",
            requestID: requestID,
            stream: stream,
            providerID: providerID,
            assignedID: assignedID,
            seq: seq
        )
        let enc = try Self.sealEnvelope(
            plaintext,
            key: p2cKey,
            nonceBase: p2cNonceBase,
            keyID: keyID,
            aad: aad,
            seq: seq
        )
        p2cCounter += 1
        return [
            "type": "inference_response_end",
            "request_id": requestID,
            "encrypted": true,
            "enc": enc,
        ]
    }

    static func sealRequestForTest(session: Tier2ProviderSession, requestID: String, stream: Bool, plaintext: String, conversationKey: String? = nil, seq: UInt64 = 0) throws -> [String: Any] {
        let aad = Tier2FrameAAD(
            type: "inference_request",
            direction: "c2p",
            requestID: requestID,
            stream: stream,
            providerID: session.providerID,
            assignedID: session.assignedID,
            seq: seq
        )
        var plaintextEnvelope: [String: Any] = [
            "type": "inference_request_plaintext",
            "body": plaintext,
        ]
        if let conversationKey = conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines), !conversationKey.isEmpty {
            plaintextEnvelope["conversation_key"] = conversationKey
        }
        let plaintextData = try JSONSerialization.data(withJSONObject: plaintextEnvelope, options: [.sortedKeys])
        let enc = try sealEnvelope(
            plaintextData,
            key: session.c2pKey,
            nonceBase: session.c2pNonceBase,
            keyID: session.keyID,
            aad: aad,
            seq: seq
        )
        return [
            "type": "inference_request",
            "request_id": requestID,
            "stream": stream,
            "encrypted": true,
            "enc": enc,
        ]
    }

    static func sealLosslessnessRequestForTest(session: Tier2ProviderSession, requestID: String, outerEnvelope: [String: Any], seq: UInt64 = 0) throws -> [String: Any] {
        let aad = Tier2FrameAAD(
            type: LosslessnessProbeProtocol.encryptedRequestType,
            direction: "c2p",
            requestID: requestID,
            stream: false,
            providerID: session.providerID,
            assignedID: session.assignedID,
            seq: seq
        )
        let plaintextEnvelope: [String: Any] = [
            "type": LosslessnessProbeProtocol.requestPlaintextType,
            "payload": outerEnvelope,
        ]
        let plaintextData = try JSONSerialization.data(withJSONObject: plaintextEnvelope, options: [.sortedKeys])
        let enc = try sealEnvelope(
            plaintextData,
            key: session.c2pKey,
            nonceBase: session.c2pNonceBase,
            keyID: session.keyID,
            aad: aad,
            seq: seq
        )
        return [
            "type": LosslessnessProbeProtocol.encryptedRequestType,
            "request_id": requestID,
            "stream": false,
            "encrypted": true,
            "enc": enc,
        ]
    }

    static func openLosslessnessResultForTest(session: Tier2ProviderSession, frame: [String: Any], requestID: String, seq: UInt64 = 0) throws -> [String: Any] {
        guard frame["type"] as? String == LosslessnessProbeProtocol.encryptedResultType,
              frame["encrypted"] as? Bool == true,
              frame["stream"] as? Bool == false,
              let enc = frame["enc"] as? [String: Any] else {
            throw Tier2ProviderError.invalidEnvelope
        }
        let aad = Tier2FrameAAD(
            type: LosslessnessProbeProtocol.encryptedResultType,
            direction: "p2c",
            requestID: requestID,
            stream: false,
            providerID: session.providerID,
            assignedID: session.assignedID,
            seq: seq
        )
        let plaintext = try openEnvelope(enc, key: session.p2cKey, nonceBase: session.p2cNonceBase, keyID: session.keyID, expectedAAD: aad, expectedSeq: seq)
        guard let envelope = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              envelope["type"] as? String == LosslessnessProbeProtocol.resultPlaintextType,
              let payload = envelope["payload"] as? [String: Any] else {
            throw Tier2ProviderError.invalidPlaintext
        }
        return payload
    }

    static func openResponseChunkForTest(session: Tier2ProviderSession, frame: [String: Any], requestID: String, stream: Bool, seq: UInt64 = 0) throws -> String {
        guard frame["encrypted"] as? Bool == true, let enc = frame["enc"] as? [String: Any] else {
            throw Tier2ProviderError.invalidEnvelope
        }
        let aad = Tier2FrameAAD(
            type: "inference_response_chunk",
            direction: "p2c",
            requestID: requestID,
            stream: stream,
            providerID: session.providerID,
            assignedID: session.assignedID,
            seq: seq
        )
        let plaintext = try openEnvelope(enc, key: session.p2cKey, nonceBase: session.p2cNonceBase, keyID: session.keyID, expectedAAD: aad, expectedSeq: seq)
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              object["type"] as? String == "inference_response_chunk_plaintext",
              let data = object["data"] as? String else {
            throw Tier2ProviderError.invalidPlaintext
        }
        return data
    }

    static func openResponseEndForTest(session: Tier2ProviderSession, frame: [String: Any], requestID: String, stream: Bool, seq: UInt64 = 0) throws -> [String: Any] {
        guard frame["encrypted"] as? Bool == true, let enc = frame["enc"] as? [String: Any] else {
            throw Tier2ProviderError.invalidEnvelope
        }
        let aad = Tier2FrameAAD(
            type: "inference_response_end",
            direction: "p2c",
            requestID: requestID,
            stream: stream,
            providerID: session.providerID,
            assignedID: session.assignedID,
            seq: seq
        )
        let plaintext = try openEnvelope(enc, key: session.p2cKey, nonceBase: session.p2cNonceBase, keyID: session.keyID, expectedAAD: aad, expectedSeq: seq)
        let object = try JSONSerialization.jsonObject(with: plaintext)
        guard let dict = object as? [String: Any] else {
            throw Tier2ProviderError.invalidPlaintext
        }
        return dict
    }

    static func coordinatorSessionForRekeyTest(
        coordinatorPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        providerID: String,
        assignedID: String,
        providerPublicKeyBase64URL: String,
        selectedAEAD: String
    ) throws -> Tier2ProviderSession {
        let providerPublicRaw = try Data(base64URLUnpadded: providerPublicKeyBase64URL)
        let providerPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: providerPublicRaw)
        let sharedSecret = try coordinatorPrivateKey.sharedSecretFromKeyAgreement(with: providerPublic)
        let coordinatorPublicRaw = coordinatorPrivateKey.publicKey.rawRepresentation
        let transcript = transcript(
            providerID: providerID,
            assignedID: assignedID,
            providerPublicKey: providerPublicRaw,
            coordinatorPublicKey: coordinatorPublicRaw,
            selectedAEAD: selectedAEAD
        )
        let keyID = Data(SHA256.hash(data: transcript).prefix(16)).base64URLUnpadded()
        return try Tier2ProviderSession(
            providerID: providerID,
            assignedID: assignedID,
            selectedAEAD: selectedAEAD,
            keyID: keyID,
            c2pKey: sharedSecret.hkdfData(salt: transcript, info: Data("macprovider/spec008/c2p/aead/v1".utf8), count: 32),
            p2cKey: sharedSecret.hkdfData(salt: transcript, info: Data("macprovider/spec008/p2c/aead/v1".utf8), count: 32),
            c2pNonceBase: sharedSecret.hkdfData(salt: transcript, info: Data("macprovider/spec008/c2p/nonce/v1".utf8), count: 4),
            p2cNonceBase: sharedSecret.hkdfData(salt: transcript, info: Data("macprovider/spec008/p2c/nonce/v1".utf8), count: 4)
        )
    }

    static func sealAEADRekeyCommitForTest(session: Tier2ProviderSession, rekeyID: String, proof: Data) throws -> [String: Any] {
        let aad = Tier2FrameAAD(
            type: "aead_rekey_commit",
            direction: "c2p",
            requestID: rekeyID,
            stream: false,
            providerID: session.providerID,
            assignedID: session.assignedID,
            seq: 0
        )
        return try sealEnvelope(proof, key: session.c2pKey, nonceBase: session.c2pNonceBase, keyID: session.keyID, aad: aad, seq: 0)
    }

    static func openAEADRekeyCommittedForTest(session: Tier2ProviderSession, frame: [String: Any], rekeyID: String) throws -> Data {
        guard frame["encrypted"] as? Bool == true,
              let enc = frame["enc"] as? [String: Any]
        else {
            throw Tier2ProviderError.invalidEnvelope
        }
        let aad = Tier2FrameAAD(
            type: "aead_rekey_committed",
            direction: "p2c",
            requestID: rekeyID,
            stream: false,
            providerID: session.providerID,
            assignedID: session.assignedID,
            seq: 0
        )
        return try openEnvelope(enc, key: session.p2cKey, nonceBase: session.p2cNonceBase, keyID: session.keyID, expectedAAD: aad, expectedSeq: 0)
    }

    private static func sealEnvelope(_ plaintext: Data, key: Data, nonceBase: Data, keyID: String, aad: Tier2FrameAAD, seq: UInt64) throws -> [String: Any] {
        let aadRaw = try aad.encoded()
        let nonceData = try nonce(nonceBase: nonceBase, seq: seq)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: aadRaw)
        return [
            "alg": Self.aeadSuite,
            "kid": keyID,
            "seq": Int(seq),
            "nonce": nonceData.base64URLUnpadded(),
            "aad": aadRaw.base64URLUnpadded(),
            "ciphertext": sealed.ciphertext.base64URLUnpadded(),
            "tag": sealed.tag.base64URLUnpadded(),
        ]
    }

    private static func openEnvelope(_ enc: [String: Any], key: Data, nonceBase: Data, keyID: String, expectedAAD: Tier2FrameAAD, expectedSeq: UInt64) throws -> Data {
        guard enc["alg"] as? String == Self.aeadSuite,
              enc["kid"] as? String == keyID,
              let seqValue = uint64Value(enc["seq"]),
              seqValue == expectedSeq,
              let nonceEncoded = enc["nonce"] as? String,
              let aadEncoded = enc["aad"] as? String,
              let ciphertextEncoded = enc["ciphertext"] as? String,
              let tagEncoded = enc["tag"] as? String
        else {
            throw Tier2ProviderError.invalidEnvelope
        }
        let nonceData = try Data(base64URLUnpadded: nonceEncoded)
        guard nonceData == (try nonce(nonceBase: nonceBase, seq: expectedSeq)) else {
            throw Tier2ProviderError.nonceMismatch
        }
        let expectedAADRaw = try expectedAAD.encoded()
        let aadRaw = try Data(base64URLUnpadded: aadEncoded)
        guard aadRaw == expectedAADRaw else {
            throw Tier2ProviderError.aadMismatch
        }
        let ciphertext = try Data(base64URLUnpadded: ciphertextEncoded)
        let tag = try Data(base64URLUnpadded: tagEncoded)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aadRaw)
    }

    private static func transcript(providerID: String, assignedID: String, providerPublicKey: Data, coordinatorPublicKey: Data, selectedAEAD: String) -> Data {
        var data = Data("macprovider/spec008/pillar-b/transcript/v1".utf8)
        appendTranscriptField(label: "provider_id", value: Data(providerID.utf8), to: &data)
        appendTranscriptField(label: "assigned_id", value: Data(assignedID.utf8), to: &data)
        appendTranscriptField(label: "provider_public", value: providerPublicKey, to: &data)
        appendTranscriptField(label: "coordinator_public", value: coordinatorPublicKey, to: &data)
        appendTranscriptField(label: "selected_aead", value: Data(selectedAEAD.utf8), to: &data)
        return Data(SHA256.hash(data: data))
    }

    private static func appendTranscriptField(label: String, value: Data, to data: inout Data) {
        appendUInt32(UInt32(label.utf8.count), to: &data)
        data.append(Data(label.utf8))
        appendUInt32(UInt32(value.count), to: &data)
        data.append(value)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64:
            return value
        case let value as Int where value >= 0:
            return UInt64(value)
        case let value as NSNumber:
            return value.uint64Value
        default:
            return nil
        }
    }

    private static func nonce(nonceBase: Data, seq: UInt64) throws -> Data {
        guard nonceBase.count == 4 else {
            throw Tier2ProviderError.invalidKeyMaterial
        }
        var nonce = Data(nonceBase)
        var bigEndian = seq.bigEndian
        withUnsafeBytes(of: &bigEndian) { nonce.append(contentsOf: $0) }
        return nonce
    }
}

enum Tier2ProviderError: Error, Equatable {
    case aadMismatch
    case invalidCoordinatorPublicKey
    case invalidEnvelope
    case invalidKeyMaterial
    case invalidPlaintext
    case keyIDMismatch(expected: String, derived: String)
    case nonceMismatch
    case unsupportedAEAD(String)
}

private struct Tier2FrameAAD: Equatable {
    private static let prefix = Data("macprovider/spec008/pillar-b/aad/v1\0".utf8)

    let type: String
    let direction: String
    let requestID: String
    let stream: Bool
    let providerID: String
    let assignedID: String
    let seq: UInt64

    func encoded() throws -> Data {
        var data = Self.prefix
        data.appendAADString(type)
        data.appendAADString(direction)
        data.appendAADString(requestID)
        data.append(stream ? 1 : 0)
        data.appendAADString(providerID)
        data.appendAADString(assignedID)
        data.appendUInt64BE(seq)
        return data
    }
}

private extension Data {
    mutating func appendAADString(_ value: String) {
        let bytes = Data(value.utf8)
        appendUInt32BE(UInt32(bytes.count))
        append(bytes)
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xff))
        append(UInt8((value >> 48) & 0xff))
        append(UInt8((value >> 40) & 0xff))
        append(UInt8((value >> 32) & 0xff))
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}

private extension SharedSecret {
    func hkdfData(salt: Data, info: Data, count: Int) -> Data {
        let key = hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: count
        )
        return key.dataRepresentation
    }
}

private extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}

extension Data {
    init(base64URLUnpadded value: String) throws {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        guard let decoded = Data(base64Encoded: base64) else {
            throw Tier2ProviderError.invalidEnvelope
        }
        self = decoded
    }

    func base64URLUnpadded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
