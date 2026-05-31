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

    let providerID: String
    let assignedID: String
    let selectedAEAD: String
    let keyID: String
    let c2pKey: Data
    let p2cKey: Data
    let c2pNonceBase: Data
    let p2cNonceBase: Data

    private let lock = NSLock()
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

    var countersForTest: (c2p: UInt64, p2c: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (c2pCounter, p2cCounter)
    }

    func openRequestBody(message: [String: Any], requestID: String, stream: Bool) throws -> String {
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
        guard let body = String(data: plaintext, encoding: .utf8) else {
            throw Tier2ProviderError.invalidPlaintext
        }
        return body
    }

    func sealResponseChunk(requestID: String, stream: Bool, plaintext: String) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let seq = p2cCounter
        let aad = Tier2FrameAAD(
            type: "inference_response_chunk",
            direction: "p2c",
            requestID: requestID,
            stream: stream,
            providerID: providerID,
            assignedID: assignedID,
            seq: seq
        )
        let enc = try Self.sealEnvelope(
            Data(plaintext.utf8),
            key: p2cKey,
            nonceBase: p2cNonceBase,
            keyID: keyID,
            aad: aad,
            seq: seq
        )
        p2cCounter += 1
        return [
            "type": "inference_response_chunk",
            "request_id": requestID,
            "encrypted": true,
            "enc": enc,
        ]
    }

    static func sealRequestForTest(session: Tier2ProviderSession, requestID: String, stream: Bool, plaintext: String, seq: UInt64 = 0) throws -> [String: Any] {
        let aad = Tier2FrameAAD(
            type: "inference_request",
            direction: "c2p",
            requestID: requestID,
            stream: stream,
            providerID: session.providerID,
            assignedID: session.assignedID,
            seq: seq
        )
        let enc = try sealEnvelope(
            Data(plaintext.utf8),
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
        guard let data = String(data: plaintext, encoding: .utf8) else {
            throw Tier2ProviderError.invalidPlaintext
        }
        return data
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
    let type: String
    let direction: String
    let requestID: String
    let stream: Bool
    let providerID: String
    let assignedID: String
    let seq: UInt64

    func encoded() throws -> Data {
        let orderedFields: [(String, Tier2AADValue)] = [
            ("type", .string(type)),
            ("direction", .string(direction)),
            ("request_id", .string(requestID)),
            ("stream", .bool(stream)),
            ("provider_id", .string(providerID)),
            ("assigned_id", .string(assignedID)),
            ("seq", .uint(seq)),
        ]
        var data = Data("{".utf8)
        for (index, field) in orderedFields.enumerated() {
            if index > 0 {
                data.append(Data(",".utf8))
            }
            data.append(Self.goJSONString(field.0))
            data.append(Data(":".utf8))
            switch field.1 {
            case .string(let value):
                data.append(Self.goJSONString(value))
            case .bool(let value):
                data.append(Data((value ? "true" : "false").utf8))
            case .uint(let value):
                data.append(Data(String(value).utf8))
            }
        }
        data.append(Data("}".utf8))
        return data
    }

    private static func goJSONString(_ value: String) -> Data {
        var data = Data("\"".utf8)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                data.append(Data(#"\b"#.utf8))
            case 0x0c:
                data.append(Data(#"\f"#.utf8))
            case 0x0a:
                data.append(Data(#"\n"#.utf8))
            case 0x0d:
                data.append(Data(#"\r"#.utf8))
            case 0x09:
                data.append(Data(#"\t"#.utf8))
            case 0x22:
                data.append(Data(#"\""#.utf8))
            case 0x5c:
                data.append(Data(#"\\"#.utf8))
            case 0x26:
                data.append(Data(#"\u0026"#.utf8))
            case 0x3c:
                data.append(Data(#"\u003c"#.utf8))
            case 0x3e:
                data.append(Data(#"\u003e"#.utf8))
            case 0x2028:
                data.append(Data(#"\u2028"#.utf8))
            case 0x2029:
                data.append(Data(#"\u2029"#.utf8))
            case 0x00..<0x20:
                data.append(Data(String(format: #"\u%04x"#, scalar.value).utf8))
            default:
                data.append(Data(String(scalar).utf8))
            }
        }
        data.append(Data("\"".utf8))
        return data
    }
}

private enum Tier2AADValue {
    case string(String)
    case bool(Bool)
    case uint(UInt64)
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
