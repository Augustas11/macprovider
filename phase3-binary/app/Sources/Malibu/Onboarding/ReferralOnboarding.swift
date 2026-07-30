import CryptoKit
import Darwin
import Foundation

enum ReferralOnboardingInput {
    enum ValidationError: Swift.Error, LocalizedError, Equatable {
        case invalidCodeOrLink

        var errorDescription: String? {
            "Enter a valid Malibu invite code or a https://malibu.tech/j#/ invite link."
        }
    }

    private static let codePattern = #"^MAL1-[SP]-[A-Za-z0-9_]{1,32}-[A-Za-z0-9_]{1,32}-[A-Z2-7]{26}$"#

    static func normalize(_ input: String) throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= 512 else { throw ValidationError.invalidCodeOrLink }

        if isValidCode(trimmed) {
            return trimmed
        }
        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host?.lowercased() == "malibu.tech",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.percentEncodedPath == "/j",
              components.percentEncodedFragment == components.fragment,
              let fragment = components.fragment,
              fragment.hasPrefix("/") else {
            throw ValidationError.invalidCodeOrLink
        }
        let payload = String(fragment.dropFirst())
        let pieces = payload.components(separatedBy: "?c=")
        guard (pieces.count == 1 || (pieces.count == 2 && isChallenge(pieces[1]))),
              isValidCode(pieces[0]) else {
            throw ValidationError.invalidCodeOrLink
        }
        return pieces[0]
    }

    static func isValidCode(_ value: String) -> Bool {
        value.range(of: codePattern, options: .regularExpression) != nil
    }

    private static func isChallenge(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}

enum BundledInstallContractVerifier {
    enum VerificationError: Swift.Error, LocalizedError, Equatable {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(reason):
                return "The signed provider installer is unavailable: \(reason)"
            }
        }
    }

    private static let maximumManifestBytes = 1_048_576
    private static let maximumInstallScriptBytes = 8_388_608
    private static let releasePublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwwd0Vzj35OP8DlZU+0lUa8vI9gHK
    09J48LDizWScsH6rutnZLkKnGQ4X5Q8lT9L5mglF8Ba0DDoUXKrFfSAX4Q==
    -----END PUBLIC KEY-----
    """

    static func verify(
        scriptURL: URL,
        manifestURL: URL,
        publicKeyPEM: String? = nil
    ) throws -> Data {
        let scriptData = try readRegularFile(
            scriptURL,
            label: "install.sh",
            maximumBytes: maximumInstallScriptBytes
        )
        let manifestData = try readRegularFile(
            manifestURL,
            label: "compatibility-set.json",
            maximumBytes: maximumManifestBytes
        )
        guard let object = try? JSONSerialization.jsonObject(with: manifestData),
              let envelope = object as? [String: Any],
              Set(envelope.keys) == ["schema_version", "signatures", "signed"],
              envelope["schema_version"] as? String == "macprovider.compatibility-set-envelope.v1",
              let signatures = envelope["signatures"] as? [[String: Any]],
              signatures.count == 1,
              let signature = signatures.first,
              Set(signature.keys) == ["algorithm", "key_id", "signature"],
              signature["algorithm"] as? String == "ecdsa-p256-sha256",
              signature["key_id"] as? String == "macprovider-release-p256-v1",
              let encodedSignature = signature["signature"] as? String,
              let signatureData = Data(base64Encoded: encodedSignature),
              signatureData.base64EncodedString() == encodedSignature,
              (64...80).contains(signatureData.count),
              let signed = envelope["signed"] as? [String: Any],
              Set(signed.keys) == [
                  "artifact_binding", "compatibility_set_id", "components",
                  "release", "schema_version", "transaction",
              ],
              signed["schema_version"] as? String == "macprovider.compatibility-set.v1",
              let components = signed["components"] as? [String: Any],
              Set(components.keys) == [
                  "catalog", "coordinator_admission", "launchd", "malibu_app",
                  "provider_cli", "updater_rollback", "watchdog",
              ],
              let launchd = components["launchd"] as? [String: Any],
              Set(launchd.keys) == ["activation", "contract", "install_contract", "label", "plist_template"],
              launchd["activation"] as? String == "local",
              launchd["contract"] as? String == "macprovider.launch-agent.v1",
              launchd["label"] as? String == "live.streamvc.macprovider",
              let contract = launchd["install_contract"] as? [String: Any],
              Set(contract.keys) == ["path", "sha256"],
              contract["path"] as? String == "compatibility-set-local/install.sh",
              let expectedDigest = contract["sha256"] as? String,
              expectedDigest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw VerificationError.unavailable("compatibility-set.json is not a canonical signed launchd contract")
        }
        guard var canonicalEnvelope = try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw VerificationError.unavailable("compatibility-set.json cannot be canonicalized")
        }
        canonicalEnvelope.append(0x0a)
        guard canonicalEnvelope == manifestData else {
            throw VerificationError.unavailable("compatibility-set.json is not canonically encoded")
        }
        guard var signedBytes = try? JSONSerialization.data(
            withJSONObject: signed,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw VerificationError.unavailable("Provider software verification payload is invalid")
        }
        signedBytes.append(0x0a)
        do {
            let publicKey = try P256.Signing.PublicKey(
                pemRepresentation: publicKeyPEM ?? releasePublicKeyPEM
            )
            let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            guard publicKey.isValidSignature(ecdsa, for: SHA256.hash(data: signedBytes)) else {
                throw VerificationError.unavailable("Provider software verification signature is invalid")
            }
        } catch let error as VerificationError {
            throw error
        } catch {
            throw VerificationError.unavailable("Provider software verification signature is invalid")
        }

        let actualDigest = SHA256.hash(data: scriptData).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == expectedDigest else {
            throw VerificationError.unavailable("Provider software installer could not be verified")
        }
        return scriptData
    }

    private static func readRegularFile(
        _ url: URL,
        label: String,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw VerificationError.unavailable("\(label) is missing or unreadable")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw VerificationError.unavailable("\(label) is not a regular file")
        }
        guard info.st_size > 0, info.st_size <= maximumBytes else {
            throw VerificationError.unavailable("\(label) has an invalid size")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw VerificationError.unavailable("\(label) could not be read")
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw VerificationError.unavailable("\(label) has an invalid size")
        }
        return data
    }
}

enum ReferralCodeFile {
    enum WriteError: Swift.Error, LocalizedError {
        case couldNotCreate

        var errorDescription: String? {
            "Could not securely prepare the invite code for the provider."
        }
    }

    static func create(code: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("macprovider-referral-\(UUID().uuidString)")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WriteError.couldNotCreate }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { unlink(url.path) }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_nlink == 1,
              hasNoExtendedACL(descriptor) else {
            throw WriteError.couldNotCreate
        }
        let bytes = Array(code.utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count, fsync(descriptor) == 0 else {
            throw WriteError.couldNotCreate
        }
        succeeded = true
        return url
    }

    private static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 else { return false }
        return entry == nil
    }
}
