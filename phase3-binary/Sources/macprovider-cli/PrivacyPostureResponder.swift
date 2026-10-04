import Darwin
import Foundation

/// SPEC-049 encoded posture response cap. Matches coordinator `MaxPrivacyPostureResponseBytes`.
private let maxPrivacyPostureResponseBytes = 8192

/// Creates `<state>/privacy` at mode 0700. `RelayBlindSecureDirectory` creates only the leaf,
/// so the privacy journal and the fixture SE file need this parent first.
enum PrivacyStateDirectory {
    static func prepare(stateRoot: URL) throws -> URL {
        let privacy = stateRoot.appendingPathComponent("privacy", isDirectory: true)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: privacy.path) {
            try fileManager.createDirectory(
                at: privacy,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privacy.path)
        let attributes = try fileManager.attributesOfItem(atPath: privacy.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        guard (mode & 0o777) == 0o700 else {
            throw RelayBlindProviderError.invalidConfiguration("privacy state directory mode")
        }
        return privacy
    }

    static func executionJournal(stateRoot: URL) throws -> URL {
        try prepare(stateRoot: stateRoot).appendingPathComponent("execution-journal", isDirectory: true)
    }
}

/// SPEC-049 posture signer. Sequence is in-memory and starts at 1.
/// A probe failure or decrypt-recheck failure stops responses and privacy-key advertisement
/// for this instance even if the process-global recheck flag is later cleared (R007/R017).
final class PrivacyPostureResponder: @unchecked Sendable {
    private let lock = NSLock()
    private let probe: any PrivacyPostureProbe
    private let seSigner: any SEBlobSigner
    private let seKeyBackend: String
    private let relayBlindRuntime: RelayBlindProviderRuntime
    private let providerID: String
    private let binaryVersion: String
    private var sequence: UInt64 = 0
    private var advertisingDisabled = false
    private var decryptFailureLatched = false

    init(
        probe: any PrivacyPostureProbe,
        seSigner: any SEBlobSigner,
        seKeyBackend: String,
        relayBlindRuntime: RelayBlindProviderRuntime,
        providerID: String,
        binaryVersion: String
    ) {
        self.probe = probe
        self.seSigner = seSigner
        self.seKeyBackend = seKeyBackend
        self.relayBlindRuntime = relayBlindRuntime
        self.providerID = providerID
        self.binaryVersion = binaryVersion
    }

    var isAdvertisingDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        noteDecryptRecheckLocked()
        return advertisingDisabled
    }

    /// Nil means omit `privacy_key_records`. An empty array is an honest empty advertisement.
    func privacyKeyRecords(now: Date = Date()) -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        guard let observation = healthyObservationLocked() else { return nil }
        do {
            switch try buildRecordsLocked(observation: observation, now: now) {
            case .disabled:
                return nil
            case .ready(let records, _):
                return records
            }
        } catch {
            return nil
        }
    }

    func respond(to challenge: [String: Any], assignedSession: String, now: Date = Date()) throws -> [String: Any]? {
        try parseChallenge(challenge)
        guard privacyVisibleASCII(assignedSession, maxBytes: PrivacyClassConstants.maxIdentifierBytes),
              let nonce = challenge["nonce"] as? String else {
            throw PrivacyClassError.invalidMaterial
        }
        lock.lock()
        defer { lock.unlock() }
        guard let observation = healthyObservationLocked() else { return nil }
        let built = try buildRecordsLocked(observation: observation, now: now)
        let digests: [String]
        switch built {
        case .disabled:
            return nil
        case .ready(_, let values):
            digests = values
        }
        guard sequence < UInt64.max else { throw PrivacyClassError.invalidMaterial }
        sequence += 1
        let issuedAt = Int64(now.timeIntervalSince1970)
        let statement = PrivacyPostureStatement(
            version: PrivacyClassConstants.postureVersion,
            privacyClass: PrivacyClassConstants.v1,
            providerID: providerID,
            assignedSession: assignedSession,
            nonce: nonce,
            sequence: sequence,
            issuedAtUnix: issuedAt,
            binaryVersion: observation.binaryVersion,
            codeCDHash: observation.codeCDHash,
            teamID: observation.teamID,
            signingIdentifier: observation.signingIdentifier,
            hardenedRuntime: observation.hardenedRuntime,
            libraryValidation: observation.libraryValidation,
            getTaskAllow: observation.getTaskAllow,
            csDebugged: observation.csDebugged,
            pTraced: observation.pTraced,
            ptDenyAttachApplied: observation.ptDenyAttachApplied,
            coreDumpsDisabled: observation.coreDumpsDisabled,
            sipEnabled: observation.sipEnabled,
            runtimeSource: observation.runtimeSource,
            diagnosticEnvClear: observation.diagnosticEnvClear,
            kvDiskTierDisabled: observation.kvDiskTierDisabled,
            seKeyBackend: seKeyBackend,
            privacyKeyRecordDigests: digests
        )
        let framing = try statement.framing()
        guard seSigner.publicKeyRaw.count == 64 else { throw PrivacyClassError.invalidMaterial }
        let seSignature = RelayBlindBase64URL.encode(try seSigner.sign(framing))
        let identitySignature = try relayBlindRuntime.identitySignatureBase64URL(for: framing)
        let response: [String: Any] = [
            "type": "privacy_posture_response",
            "version": 1,
            "statement": statement.wireObject,
            "se_signature": seSignature,
            "identity_signature": identitySignature,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
        guard encoded.count <= maxPrivacyPostureResponseBytes else { throw PrivacyClassError.invalidMaterial }
        return response
    }

    private func noteDecryptRecheckLocked() {
        if PrivacyRuntimeHardening.decryptRecheckFailed {
            decryptFailureLatched = true
            advertisingDisabled = true
        }
    }

    /// Calls `observe()`, which on the production probe runs `ptrace(PT_DENY_ATTACH)`.
    private func healthyObservationLocked() -> PrivacyPostureObservation? {
        noteDecryptRecheckLocked()
        if advertisingDisabled { return nil }
        let observation = probe.observe()
        if !postureAcceptable(observation) || probe.isTracedOrDebugged() {
            advertisingDisabled = true
            return nil
        }
        return observation
    }

    private func postureAcceptable(_ observation: PrivacyPostureObservation) -> Bool {
        observation.failureReasons.isEmpty
            && observation.hardenedRuntime
            && observation.libraryValidation
            && !observation.getTaskAllow
            && !observation.csDebugged
            && !observation.pTraced
            && observation.ptDenyAttachApplied
            && observation.coreDumpsDisabled
            && observation.sipEnabled
            && observation.diagnosticEnvClear
            && observation.kvDiskTierDisabled
            && observation.runtimeSource == PrivacyClassConstants.runtimeSource
            && observation.binaryVersion == binaryVersion
    }

    private enum BuiltRecords {
        case ready([[String: Any]], digests: [String])
        case disabled
    }

    private func buildRecordsLocked(observation: PrivacyPostureObservation, now: Date) throws -> BuiltRecords {
        let records = try relayBlindRuntime.advertisedRecords(now: now)
        if records.count > PrivacyClassConstants.maxKeyRecordDigests {
            advertisingDisabled = true
            return .disabled
        }
        let sorted = records.sorted {
            $0.keyRecordDigest.utf8.lexicographicallyPrecedes($1.keyRecordDigest.utf8)
        }
        var wire: [[String: Any]] = []
        var digests: [String] = []
        wire.reserveCapacity(sorted.count)
        digests.reserveCapacity(sorted.count)
        for record in sorted {
            let attestation = PrivacyKeyAttestation(
                version: PrivacyClassConstants.keyAttestationVersion,
                keyRecordDigest: record.keyRecordDigest,
                privacyClass: PrivacyClassConstants.v1,
                assurance: PrivacyClassConstants.assurance,
                binaryVersion: observation.binaryVersion,
                codeCDHash: observation.codeCDHash,
                notBeforeUnix: record.notBeforeUnix,
                expiresAtUnix: record.expiresAtUnix
            )
            let signature = try relayBlindRuntime.identitySignatureBase64URL(for: try attestation.framing())
            wire.append([
                "key_record": record.wireObject,
                "privacy_key_attestation": attestation.wireObject,
                "signature": signature,
            ])
            digests.append(record.keyRecordDigest)
        }
        return .ready(wire, digests: digests)
    }

    private func parseChallenge(_ object: [String: Any]) throws {
        guard Set(object.keys) == ["type", "version", "nonce", "issued_at_unix"],
              object["type"] as? String == "privacy_posture_challenge",
              strictJSONInt64(object["version"]) == 1,
              let nonce = object["nonce"] as? String,
              strictJSONInt64(object["issued_at_unix"]) != nil else {
            throw PrivacyClassError.invalidMaterial
        }
        _ = try RelayBlindBase64URL.decode(nonce, exactCount: 32)
    }
}

/// All-green fixture probe. `codeCDHash` defaults to a 40-hex stand-in for the plan token `f1x7`,
/// which is not lowercase hex and cannot be signed under SPEC-049 §4.3.
struct FixturePrivacyPostureProbe: PrivacyPostureProbe {
    static let defaultCodeCDHash = "f1a7" + String(repeating: "0", count: 36)
    // SPEC-049 team ids are exactly 10 of A-Z and 0-9. "FIXTURE0001" is 11.
    static let teamID = "FIXTURE001"
    static let signingIdentifier = "live.malibu.provider.cli"

    var traced: Bool
    var codeCDHash: String
    var binaryVersion: String

    func observe() -> PrivacyPostureObservation {
        PrivacyPostureObservation(
            hardenedRuntime: true,
            libraryValidation: true,
            getTaskAllow: false,
            csDebugged: traced,
            pTraced: traced,
            ptDenyAttachApplied: true,
            coreDumpsDisabled: true,
            sipEnabled: true,
            diagnosticEnvClear: true,
            kvDiskTierDisabled: true,
            runtimeSource: PrivacyClassConstants.runtimeSource,
            codeCDHash: codeCDHash,
            teamID: Self.teamID,
            signingIdentifier: Self.signingIdentifier,
            binaryVersion: binaryVersion,
            failureReasons: traced ? ["p_traced"] : []
        )
    }

    func isTracedOrDebugged() -> Bool { traced }
}

enum FixturePrivacySEKey {
    static let fileName = "se-p256.raw"

    static func loadOrCreate(stateRoot: URL) throws -> SELivenessTestSigning {
        let privacy = try PrivacyStateDirectory.prepare(stateRoot: stateRoot)
        let url = privacy.appendingPathComponent(fileName)
        if var existing = try readSEBlob(url) {
            defer { existing.resetBytes(in: 0..<existing.count) }
            return try SELivenessTestSigning.load(externalPrivateRepresentation: existing)
        }
        let created = try SELivenessTestSigning.generate()
        var blob = try created.externalPrivateRepresentation()
        defer { blob.resetBytes(in: 0..<blob.count) }
        do {
            try writeExclusiveSEBlob(url, data: blob)
        } catch PrivacySEFileError.alreadyExists {
            var raced = try readSEBlob(url) ?? Data()
            defer { raced.resetBytes(in: 0..<raced.count) }
            guard !raced.isEmpty else { throw PrivacySEFileError.unavailable }
            return try SELivenessTestSigning.load(externalPrivateRepresentation: raced)
        }
        return created
    }
}

private enum PrivacySEFileError: Error {
    case unavailable
    case alreadyExists
}

private func privacyVisibleASCII(_ value: String, maxBytes: Int) -> Bool {
    let bytes = Array(value.utf8)
    return !bytes.isEmpty && bytes.count <= maxBytes && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
}

func privacyFixtureCDHash(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 40 else { return false }
    return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
}

private func strictJSONInt64(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let text = number.stringValue
    guard !text.contains("."), !text.lowercased().contains("e") else { return nil }
    return Int64(text)
}

private func readSEBlob(_ url: URL) throws -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    if fd < 0 {
        if errno == ENOENT { return nil }
        throw PrivacySEFileError.unavailable
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw PrivacySEFileError.unavailable }
    guard (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == getuid(),
          (info.st_mode & 0o777) == 0o600,
          info.st_size >= 1,
          info.st_size <= 512 else {
        throw PrivacySEFileError.unavailable
    }
    let size = Int(info.st_size)
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, size) }
    guard count == size else { throw PrivacySEFileError.unavailable }
    return data
}

private func writeExclusiveSEBlob(_ url: URL, data: Data) throws {
    guard (1...512).contains(data.count) else { throw PrivacySEFileError.unavailable }
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    if fd < 0 {
        if errno == EEXIST { throw PrivacySEFileError.alreadyExists }
        throw PrivacySEFileError.unavailable
    }
    var success = false
    defer {
        close(fd)
        if !success { unlink(url.path) }
    }
    guard fchmod(fd, 0o600) == 0 else { throw PrivacySEFileError.unavailable }
    var written = 0
    while written < data.count {
        let count = data.withUnsafeBytes { raw in
            write(fd, raw.baseAddress!.advanced(by: written), data.count - written)
        }
        guard count > 0 else { throw PrivacySEFileError.unavailable }
        written += count
    }
    var info = stat()
    guard fstat(fd, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == getuid(),
          (info.st_mode & 0o777) == 0o600,
          fsync(fd) == 0 else {
        throw PrivacySEFileError.unavailable
    }
    success = true
}
