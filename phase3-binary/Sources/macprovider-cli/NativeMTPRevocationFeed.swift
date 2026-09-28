import CryptoKit
import Darwin
import Foundation
import Security

struct NativeMTPRevocationFeed: Equatable, Sendable {
    static let schemaVersion = "macprovider.native-mtp-revocations.v1"
    static let maxFeedBytes = 256 * 1024
    static let maxSignatureBytes = 16 * 1024
    static let maxRevokedTuples = 4_096

    let schemaVersion: String
    let generation: UInt64
    let issuedAt: Date
    let expiresAt: Date
    let signerKeyID: String
    let revokedAdmissionTupleSHA256: [String]

    var revokedSet: Set<String> { Set(revokedAdmissionTupleSHA256) }
    var revokedSetSHA256: String {
        Self.sha256Hex(Data(revokedAdmissionTupleSHA256.joined(separator: "\n").utf8))
    }

    func contains(tupleSHA256: String) -> Bool {
        revokedSet.contains(tupleSHA256)
    }
}

struct NativeMTPRevocationAnchor: Equatable, Codable, Sendable {
    let generation: UInt64
    let bodySHA256: String
    let revokedSetSHA256: String

    enum CodingKeys: String, CodingKey {
        case generation
        case bodySHA256 = "body_sha256"
        case revokedSetSHA256 = "revoked_set_sha256"
    }
}

enum NativeMTPRevocationFeedError: Error, Equatable, CustomStringConvertible {
    case missingFeed
    case invalidJSON(String)
    case duplicateKey(String)
    case unknownField(String)
    case missingField(String)
    case invalidField(String)
    case payloadTooLarge(String)
    case signatureInvalid(String)
    case signerMismatch
    case futureIssued
    case expired
    case rollback
    case revokedSetRegression
    case anchorMismatch
    case cacheCorrupt
    case storeFailed(String)

    var description: String {
        switch self {
        case .missingFeed: return "native-MTP revocation feed unavailable"
        case .invalidJSON(let field): return "invalid native-MTP revocation JSON: \(field)"
        case .duplicateKey(let field): return "duplicate native-MTP revocation key: \(field)"
        case .unknownField(let field): return "unknown native-MTP revocation field: \(field)"
        case .missingField(let field): return "missing native-MTP revocation field: \(field)"
        case .invalidField(let field): return "invalid native-MTP revocation field: \(field)"
        case .payloadTooLarge(let field): return "native-MTP revocation payload too large: \(field)"
        case .signatureInvalid(let reason): return "invalid native-MTP revocation signature: \(reason)"
        case .signerMismatch: return "native-MTP revocation signer mismatch"
        case .futureIssued: return "native-MTP revocation feed issued in the future"
        case .expired: return "native-MTP revocation feed expired"
        case .rollback: return "native-MTP revocation generation rollback"
        case .revokedSetRegression: return "native-MTP revocation set regression"
        case .anchorMismatch: return "native-MTP revocation anchor mismatch"
        case .cacheCorrupt: return "native-MTP revocation cache corrupt"
        case .storeFailed(let reason): return "native-MTP revocation store failed: \(reason)"
        }
    }
}

protocol NativeMTPRevocationSignatureVerifying: Sendable {
    func verify(payload: Data, signatureData: Data, expectedSignerKeyID: String) throws
}

struct NativeMTPRevocationEd25519Verifier: NativeMTPRevocationSignatureVerifying {
    let publicKeysByKeyID: [String: String]

    func verify(payload: Data, signatureData: Data, expectedSignerKeyID: String) throws {
        guard let text = String(data: signatureData, encoding: .utf8) else {
            throw NativeMTPRevocationFeedError.signatureInvalid("utf8")
        }
        let raw = try NativeMTPRevocationFeed.decodeJSONObject(
            textData: Data(text.utf8),
            allowedKeys: ["key_id", "alg", "signature"],
            label: "signature"
        )
        let keyID = try NativeMTPRevocationFeed.requireString(raw, "key_id", maxBytes: 128)
        guard keyID == expectedSignerKeyID else {
            throw NativeMTPRevocationFeedError.signatureInvalid("unexpected_key_id")
        }
        guard try NativeMTPRevocationFeed.requireString(raw, "alg", maxBytes: 32) == "ed25519" else {
            throw NativeMTPRevocationFeedError.signatureInvalid("alg")
        }
        let encodedSignature = try NativeMTPRevocationFeed.requireString(raw, "signature", maxBytes: 128)
        guard let encodedPublicKey = publicKeysByKeyID[keyID],
              let publicKeyBytes = Data(base64Encoded: encodedPublicKey),
              publicKeyBytes.count == 32,
              publicKeyBytes.base64EncodedString() == encodedPublicKey,
              let signature = Data(base64Encoded: encodedSignature),
              signature.count == 64,
              signature.base64EncodedString() == encodedSignature,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes),
              publicKey.isValidSignature(signature, for: payload) else {
            throw NativeMTPRevocationFeedError.signatureInvalid("verification_failed")
        }
    }
}

protocol NativeMTPRevocationStore: Sendable {
    func loadAnchor(signerKeyID: String) throws -> NativeMTPRevocationAnchor?
    func loadCachedFeed(signerKeyID: String) throws -> Data?
    func commitAcceptedFeed(_ feedData: Data, anchor: NativeMTPRevocationAnchor, signerKeyID: String) throws
}

struct NativeMTPRevocationState: Equatable, Sendable {
    let feed: NativeMTPRevocationFeed
    let source: Source

    enum Source: String, Equatable, Sendable {
        case network
        case cache
    }

    func isRevoked(tupleSHA256: String) -> Bool {
        feed.contains(tupleSHA256: tupleSHA256)
    }
}

enum NativeMTPRevocationFeedManager {
    static func accept(
        feedData: Data,
        signatureData: Data,
        pinnedSignerKeyID: String,
        verifier: NativeMTPRevocationSignatureVerifying,
        store: NativeMTPRevocationStore,
        now: Date = Date()
    ) throws -> NativeMTPRevocationState {
        guard feedData.count <= NativeMTPRevocationFeed.maxFeedBytes else {
            throw NativeMTPRevocationFeedError.payloadTooLarge("feed")
        }
        guard signatureData.count <= NativeMTPRevocationFeed.maxSignatureBytes else {
            throw NativeMTPRevocationFeedError.payloadTooLarge("signature")
        }
        try verifier.verify(payload: feedData, signatureData: signatureData, expectedSignerKeyID: pinnedSignerKeyID)
        let feed = try NativeMTPRevocationFeed.parse(feedData)
        let bodySHA256 = NativeMTPRevocationFeed.sha256Hex(feedData)
        try validate(
            feed: feed,
            bodySHA256: bodySHA256,
            pinnedSignerKeyID: pinnedSignerKeyID,
            store: store,
            now: now
        )
        let anchor = NativeMTPRevocationAnchor(
            generation: feed.generation,
            bodySHA256: bodySHA256,
            revokedSetSHA256: feed.revokedSetSHA256
        )
        try store.commitAcceptedFeed(feedData, anchor: anchor, signerKeyID: pinnedSignerKeyID)
        return NativeMTPRevocationState(feed: feed, source: .network)
    }

    static func loadCached(
        pinnedSignerKeyID: String,
        store: NativeMTPRevocationStore,
        now: Date = Date()
    ) throws -> NativeMTPRevocationState {
        guard let anchor = try store.loadAnchor(signerKeyID: pinnedSignerKeyID),
              let data = try store.loadCachedFeed(signerKeyID: pinnedSignerKeyID) else {
            throw NativeMTPRevocationFeedError.missingFeed
        }
        let feed = try NativeMTPRevocationFeed.parse(data)
        guard feed.signerKeyID == pinnedSignerKeyID,
              feed.generation == anchor.generation,
              NativeMTPRevocationFeed.sha256Hex(data) == anchor.bodySHA256,
              feed.revokedSetSHA256 == anchor.revokedSetSHA256 else {
            throw NativeMTPRevocationFeedError.anchorMismatch
        }
        try validateFreshness(feed: feed, now: now)
        return NativeMTPRevocationState(feed: feed, source: .cache)
    }

    private static func validate(
        feed: NativeMTPRevocationFeed,
        bodySHA256: String,
        pinnedSignerKeyID: String,
        store: NativeMTPRevocationStore,
        now: Date
    ) throws {
        guard feed.signerKeyID == pinnedSignerKeyID else {
            throw NativeMTPRevocationFeedError.signerMismatch
        }
        try validateFreshness(feed: feed, now: now)
        guard let previous = try store.loadAnchor(signerKeyID: pinnedSignerKeyID) else {
            guard now.timeIntervalSince(feed.issuedAt) <= 15 * 60 else {
                throw NativeMTPRevocationFeedError.expired
            }
            return
        }
        guard feed.generation >= previous.generation else {
            throw NativeMTPRevocationFeedError.rollback
        }
        guard let cached = try store.loadCachedFeed(signerKeyID: pinnedSignerKeyID) else {
            throw NativeMTPRevocationFeedError.cacheCorrupt
        }
        let previousFeed = try NativeMTPRevocationFeed.parse(cached)
        guard previousFeed.signerKeyID == pinnedSignerKeyID,
              previousFeed.generation == previous.generation,
              NativeMTPRevocationFeed.sha256Hex(cached) == previous.bodySHA256,
              previousFeed.revokedSetSHA256 == previous.revokedSetSHA256 else {
            throw NativeMTPRevocationFeedError.anchorMismatch
        }
        if feed.generation == previous.generation {
            guard bodySHA256 == previous.bodySHA256,
                  feed.revokedSetSHA256 == previous.revokedSetSHA256 else {
                throw NativeMTPRevocationFeedError.rollback
            }
            return
        }
        guard feed.revokedSet.isSuperset(of: previousFeed.revokedSet) else {
            throw NativeMTPRevocationFeedError.revokedSetRegression
        }
    }

    private static func validateFreshness(feed: NativeMTPRevocationFeed, now: Date) throws {
        guard feed.issuedAt <= now else {
            throw NativeMTPRevocationFeedError.futureIssued
        }
        guard feed.issuedAt < feed.expiresAt,
              feed.expiresAt.timeIntervalSince(feed.issuedAt) <= 60 * 60 else {
            throw NativeMTPRevocationFeedError.invalidField("expires_at")
        }
        guard now < feed.expiresAt else {
            throw NativeMTPRevocationFeedError.expired
        }
    }

}

extension NativeMTPRevocationFeed {
    static func parse(_ data: Data) throws -> NativeMTPRevocationFeed {
        guard data.count <= maxFeedBytes else {
            throw NativeMTPRevocationFeedError.payloadTooLarge("feed")
        }
        let numberLiterals = try topLevelNumberLiterals(data, label: "feed")
        let raw = try decodeJSONObject(
            textData: data,
            allowedKeys: [
                "schema_version",
                "generation",
                "issued_at",
                "expires_at",
                "signer_key_id",
                "revoked_admission_tuple_sha256",
            ],
            label: "feed"
        )
        let schemaVersion = try requireString(raw, "schema_version", maxBytes: 128)
        guard schemaVersion == Self.schemaVersion else {
            throw NativeMTPRevocationFeedError.invalidField("schema_version")
        }
        let signerKeyID = try requireASCIIString(raw, "signer_key_id", maxBytes: 128)
        return NativeMTPRevocationFeed(
            schemaVersion: schemaVersion,
            generation: try requireUInt64Literal(numberLiterals["generation"], "generation"),
            issuedAt: try requireDate(raw, "issued_at"),
            expiresAt: try requireDate(raw, "expires_at"),
            signerKeyID: signerKeyID,
            revokedAdmissionTupleSHA256: try requireSortedUniqueSHA256Array(raw, "revoked_admission_tuple_sha256")
        )
    }

    static func decodeJSONObject(textData: Data, allowedKeys: Set<String>, label: String) throws -> [String: Any] {
        do {
            var scanner = NativeMTPRevocationDuplicateKeyScanner(data: textData, label: label)
            try scanner.validate()
        } catch {
            if let feedError = error as? NativeMTPRevocationFeedError {
                throw feedError
            }
            throw NativeMTPRevocationFeedError.duplicateKey(label)
        }
        guard let object = try JSONSerialization.jsonObject(with: textData) as? [String: Any] else {
            throw NativeMTPRevocationFeedError.invalidJSON(label)
        }
        for key in object.keys where !allowedKeys.contains(key) {
            throw NativeMTPRevocationFeedError.unknownField(key)
        }
        for key in allowedKeys where object[key] == nil {
            throw NativeMTPRevocationFeedError.missingField(key)
        }
        return object
    }

    private static func topLevelNumberLiterals(_ data: Data, label: String) throws -> [String: String] {
        var scanner = NativeMTPRevocationDuplicateKeyScanner(data: data, label: label)
        try scanner.validate()
        return scanner.topLevelNumberLiterals
    }

    static func requireString(_ object: [String: Any], _ key: String, maxBytes: Int) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw NativeMTPRevocationFeedError.invalidField(key)
        }
        guard value.utf8.count <= maxBytes else {
            throw NativeMTPRevocationFeedError.invalidField(key)
        }
        guard value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw NativeMTPRevocationFeedError.invalidField(key)
        }
        return value
    }

    static func requireASCIIString(_ object: [String: Any], _ key: String, maxBytes: Int) throws -> String {
        let value = try requireString(object, key, maxBytes: maxBytes)
        guard value.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw NativeMTPRevocationFeedError.invalidField(key)
        }
        return value
    }

    private static func requireDate(_ object: [String: Any], _ key: String) throws -> Date {
        let value = try requireString(object, key, maxBytes: 64)
        guard let date = iso8601.date(from: value) else {
            throw NativeMTPRevocationFeedError.invalidField(key)
        }
        return date
    }

    private static func requireUInt64Literal(_ literal: String?, _ key: String) throws -> UInt64 {
        guard let literal,
              !literal.isEmpty,
              literal.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              literal == "0" || literal.first != "0",
              let value = UInt64(literal) else {
            throw NativeMTPRevocationFeedError.invalidField(key)
        }
        return value
    }

    private static func requireSortedUniqueSHA256Array(_ object: [String: Any], _ key: String) throws -> [String] {
        guard let values = object[key] as? [String],
              values.count <= maxRevokedTuples else {
            throw NativeMTPRevocationFeedError.invalidField(key)
        }
        var previous: String?
        for value in values {
            guard isLowercaseSHA256(value) else {
                throw NativeMTPRevocationFeedError.invalidField(key)
            }
            if let previous {
                guard previous < value else {
                    throw NativeMTPRevocationFeedError.invalidField(key)
                }
            }
            previous = value
        }
        return values
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

final class FileNativeMTPRevocationStore: NativeMTPRevocationStore, @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func loadAnchor(signerKeyID: String) throws -> NativeMTPRevocationAnchor? {
        let url = anchorURL(signerKeyID: signerKeyID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try readSecureFile(url, maxBytes: 4096)
        do {
            return try JSONDecoder().decode(NativeMTPRevocationAnchor.self, from: data)
        } catch {
            throw NativeMTPRevocationFeedError.cacheCorrupt
        }
    }

    func loadCachedFeed(signerKeyID: String) throws -> Data? {
        let url = cacheURL(signerKeyID: signerKeyID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readSecureFile(url, maxBytes: NativeMTPRevocationFeed.maxFeedBytes)
    }

    func commitAcceptedFeed(_ feedData: Data, anchor: NativeMTPRevocationAnchor, signerKeyID: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeAtomic(feedData, to: cacheURL(signerKeyID: signerKeyID))
        let anchorData = try JSONEncoder.sorted.encode(anchor)
        try writeAtomic(anchorData, to: anchorURL(signerKeyID: signerKeyID))
    }

    private func cacheURL(signerKeyID: String) -> URL {
        directory.appendingPathComponent("native-mtp-revocations.\(sanitize(signerKeyID)).json", isDirectory: false)
    }

    private func anchorURL(signerKeyID: String) -> URL {
        directory.appendingPathComponent("native-mtp-revocations.\(sanitize(signerKeyID)).anchor.json", isDirectory: false)
    }

    private func sanitize(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
                ? character
                : "_"
        }.reduce(into: "") { $0.append($1) }
    }

    private func readSecureFile(_ url: URL, maxBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeMTPRevocationFeedError.cacheCorrupt }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0,
              info.st_size >= 0,
              info.st_size <= maxBytes else {
            throw NativeMTPRevocationFeedError.cacheCorrupt
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let readCount = read(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if readCount > 0 {
                    offset += readCount
                    continue
                }
                if readCount == 0 {
                    throw NativeMTPRevocationFeedError.cacheCorrupt
                }
                if errno == EINTR {
                    continue
                }
                throw NativeMTPRevocationFeedError.cacheCorrupt
            }
        }
        return data
    }

    private func writeAtomic(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw NativeMTPRevocationFeedError.storeFailed("open")
        }
        var fdOpen = true
        var success = false
        defer {
            if fdOpen {
                close(fd)
            }
            if !success {
                try? fileManager.removeItem(at: temp)
            }
        }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if errno == EINTR {
                        continue
                    }
                    if written <= 0 {
                        throw NativeMTPRevocationFeedError.storeFailed("write")
                    }
                }
            }
            guard fsync(fd) == 0 else {
                throw NativeMTPRevocationFeedError.storeFailed("fsync")
            }
            close(fd)
            fdOpen = false
            guard rename(temp.path, url.path) == 0 else {
                throw NativeMTPRevocationFeedError.storeFailed("rename")
            }
            try fsyncDirectory(url.deletingLastPathComponent())
            success = true
        } catch {
            throw error
        }
    }

    func fsyncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw NativeMTPRevocationFeedError.storeFailed("directory_open")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw NativeMTPRevocationFeedError.storeFailed("directory_fsync")
        }
    }
}

final class KeychainNativeMTPRevocationStore: NativeMTPRevocationStore, @unchecked Sendable {
    static let anchorService = "macprovider.native-mtp-revocation-generation"

    private let cacheStore: FileNativeMTPRevocationStore

    init(cacheDirectory: URL = KeychainNativeMTPRevocationStore.defaultCacheDirectory()) {
        self.cacheStore = FileNativeMTPRevocationStore(directory: cacheDirectory)
    }

    func loadAnchor(signerKeyID: String) throws -> NativeMTPRevocationAnchor? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.anchorService,
            kSecAttrAccount as String: signerKeyID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw NativeMTPRevocationFeedError.cacheCorrupt
            }
            do {
                return try JSONDecoder().decode(NativeMTPRevocationAnchor.self, from: data)
            } catch {
                throw NativeMTPRevocationFeedError.cacheCorrupt
            }
        case errSecItemNotFound:
            return nil
        default:
            throw NativeMTPRevocationFeedError.storeFailed("keychain_read_\(status)")
        }
    }

    func loadCachedFeed(signerKeyID: String) throws -> Data? {
        try cacheStore.loadCachedFeed(signerKeyID: signerKeyID)
    }

    func commitAcceptedFeed(_ feedData: Data, anchor: NativeMTPRevocationAnchor, signerKeyID: String) throws {
        try cacheStore.commitAcceptedFeed(feedData, anchor: anchor, signerKeyID: signerKeyID)
        let data = try JSONEncoder.sorted.encode(anchor)
        try replaceAnchor(data, signerKeyID: signerKeyID)
    }

    private func replaceAnchor(_ data: Data, signerKeyID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.anchorService,
            kSecAttrAccount as String: signerKeyID,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return
            }
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw NativeMTPRevocationFeedError.storeFailed("keychain_update_\(retryStatus)")
                }
                return
            }
            throw NativeMTPRevocationFeedError.storeFailed("keychain_add_\(addStatus)")
        default:
            throw NativeMTPRevocationFeedError.storeFailed("keychain_update_\(updateStatus)")
        }
    }

    private static func defaultCacheDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/macprovider/native-mtp-revocations", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct NativeMTPRevocationDuplicateKeyScanner {
    private let bytes: [UInt8]
    private let label: String
    private var index = 0
    private var objectDepth = 0
    private(set) var topLevelNumberLiterals: [String: String] = [:]

    init(data: Data, label: String) {
        self.bytes = Array(data)
        self.label = label
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw NativeMTPRevocationFeedError.invalidJSON(label)
        }
    }

    private mutating func parseValue() throws {
        guard index < bytes.count else {
            throw NativeMTPRevocationFeedError.invalidJSON(label)
        }
        switch bytes[index] {
        case 0x7b: try parseObject()
        case 0x5b: try parseArray()
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral("true")
        case 0x66: try consumeLiteral("false")
        case 0x6e: try consumeLiteral("null")
        default: try parseNumber()
        }
    }

    private mutating func parseObject() throws {
        index += 1
        objectDepth += 1
        defer { objectDepth -= 1 }
        skipWhitespace()
        var keys = Set<String>()
        if consume(0x7d) { return }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw NativeMTPRevocationFeedError.invalidJSON(label)
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw NativeMTPRevocationFeedError.duplicateKey(key)
            }
            skipWhitespace()
            guard consume(0x3a) else {
                throw NativeMTPRevocationFeedError.invalidJSON(label)
            }
            skipWhitespace()
            let valueStart = index
            try parseValue()
            if objectDepth == 1,
               let literal = numberLiteral(from: valueStart, to: index) {
                topLevelNumberLiterals[key] = literal
            }
            skipWhitespace()
            if consume(0x7d) { return }
            guard consume(0x2c) else {
                throw NativeMTPRevocationFeedError.invalidJSON(label)
            }
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5d) { return }
        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5d) { return }
            guard consume(0x2c) else {
                throw NativeMTPRevocationFeedError.invalidJSON(label)
            }
            skipWhitespace()
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
                continue
            }
            if byte == 0x5c {
                escaped = true
            } else if byte == 0x22 {
                let token = Data(bytes[start ..< index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
                    throw NativeMTPRevocationFeedError.invalidJSON(label)
                }
                return decoded
            } else if byte < 0x20 {
                throw NativeMTPRevocationFeedError.invalidJSON(label)
            }
        }
        throw NativeMTPRevocationFeedError.invalidJSON(label)
    }

    private mutating func parseNumber() throws {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[index]) {
            index += 1
        }
        guard index > start else {
            throw NativeMTPRevocationFeedError.invalidJSON(label)
        }
        let token = Data(bytes[start ..< index])
        guard (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) is NSNumber else {
            throw NativeMTPRevocationFeedError.invalidJSON(label)
        }
    }

    private func numberLiteral(from start: Int, to end: Int) -> String? {
        guard start < end else { return nil }
        let tokenBytes = bytes[start ..< end]
        guard let first = tokenBytes.first,
              first == UInt8(ascii: "-") || (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")) else {
            return nil
        }
        return String(decoding: tokenBytes, as: UTF8.self)
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index ..< index + expected.count]) == expected else {
            throw NativeMTPRevocationFeedError.invalidJSON(label)
        }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
