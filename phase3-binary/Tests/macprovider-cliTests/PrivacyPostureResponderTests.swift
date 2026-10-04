import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class PrivacyPostureResponderTests: XCTestCase {
    func testResponseSignaturesVerifyAndSequenceMonotonic() async throws {
        let root = try makeStateRoot()
        let runtime = try makeRuntime(directory: root, models: ["model-a"])
        let signer = try SELivenessTestSigning.generate()
        let responder = PrivacyPostureResponder(
            probe: MutablePrivacyPostureProbe(greenPrivacyObservation()),
            seSigner: signer,
            seKeyBackend: PrivacyClassConstants.seBackendFile,
            relayBlindRuntime: runtime,
            providerID: "provider-test",
            binaryVersion: CoordinatorClient.binaryVersion
        )
        var rejected = postureChallenge()
        rejected["version"] = true
        XCTAssertThrowsError(try responder.respond(to: rejected, assignedSession: "session-1"))

        let first = try XCTUnwrap(responder.respond(to: postureChallenge(), assignedSession: "session-1"))
        let second = try XCTUnwrap(responder.respond(to: postureChallenge(nonce: Data(repeating: 0x22, count: 32)), assignedSession: "session-1"))
        try assertPostureSignatures(first, signer: signer, identity: runtime.keyManager, sequence: 1)
        try assertPostureSignatures(second, signer: signer, identity: runtime.keyManager, sequence: 2)
    }

    func testProbeFailureDisablesAdvertisingPermanently() throws {
        defer { PrivacyRuntimeHardening.resetDecryptRecheckForTest() }
        let root = try makeStateRoot()
        let runtime = try makeRuntime(directory: root, models: ["model-a"])
        let signer = try SELivenessTestSigning.generate()
        let probe = MutablePrivacyPostureProbe(greenPrivacyObservation())
        let responder = makeResponder(runtime: runtime, signer: signer, probe: probe)
        XCTAssertNotNil(try responder.respond(to: postureChallenge(), assignedSession: "session-1"))

        probe.observation.pTraced = true
        probe.observation.failureReasons = ["p_traced"]
        probe.traced = true
        XCTAssertNil(try responder.respond(to: postureChallenge(), assignedSession: "session-1"))
        XCTAssertNil(responder.privacyKeyRecords())
        XCTAssertTrue(responder.isAdvertisingDisabled)

        probe.observation = greenPrivacyObservation()
        probe.traced = false
        XCTAssertNil(try responder.respond(to: postureChallenge(), assignedSession: "session-1"))
        XCTAssertNil(responder.privacyKeyRecords())

        let latchedRoot = try makeStateRoot()
        let latchedRuntime = try makeRuntime(directory: latchedRoot, models: ["model-a"])
        let latched = makeResponder(
            runtime: latchedRuntime,
            signer: try SELivenessTestSigning.generate(),
            probe: MutablePrivacyPostureProbe(greenPrivacyObservation())
        )
        PrivacyRuntimeHardening.noteDecryptRecheckFailed()
        XCTAssertNil(try latched.respond(to: postureChallenge(), assignedSession: "session-1"))
        XCTAssertNil(latched.privacyKeyRecords())
        PrivacyRuntimeHardening.resetDecryptRecheckForTest()
        XCTAssertNil(try latched.respond(to: postureChallenge(), assignedSession: "session-1"))
        XCTAssertTrue(latched.isAdvertisingDisabled)

        let fresh = makeResponder(
            runtime: latchedRuntime,
            signer: try SELivenessTestSigning.generate(),
            probe: MutablePrivacyPostureProbe(greenPrivacyObservation())
        )
        XCTAssertNotNil(try fresh.respond(to: postureChallenge(), assignedSession: "session-1"))
    }

    func testHeartbeatCarriesPrivacyRecordsNotRelayBlind() async throws {
        let root = try makeStateRoot()
        let probe = MutablePrivacyPostureProbe(greenPrivacyObservation())
        let signer = try SELivenessTestSigning.generate()
        let recorder = PrivacyFrameRecorder()
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-privacy-posture-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.relayBlindEnabled = true
        config.privacyClassBeta = true
        config.relayBlindStateDirectory = root.path
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: IdlePrivacyRuntime(),
            providerStatus: ProviderStatus(
                modelID: "model-a",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
            ),
            sendOverride: { frame in
                await recorder.append(frame)
            },
            attestationGenerator: ManagedDeviceAttestationGenerator(),
            privacyPostureProbeOverride: probe,
            privacySESignerOverride: signer,
            sleepAssertionFactory: { nil },
            installedCompatibilityManifest: { _, _ in nil },
            watchdogExitHook: { _ in }
        ))
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("encryption.current.x25519").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("encryption.current.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("execution-journal").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("privacy/execution-journal").path))

        try await client.sendHeartbeatForTest()
        let heartbeatFrames = await recorder.frames()
        let heartbeat = try XCTUnwrap(heartbeatFrames.first)
        let hello = await client.helloMessage()
        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        for message in [heartbeat, hello, auth] {
            XCTAssertNil(message["relay_blind_key_records"])
            let records = try XCTUnwrap(message["privacy_key_records"] as? [[String: Any]])
            XCTAssertFalse(records.isEmpty)
            let attestation = try XCTUnwrap(records[0]["privacy_key_attestation"] as? [String: Any])
            XCTAssertEqual(attestation["code_cdhash"] as? String, probe.observation.codeCDHash)
            XCTAssertEqual(attestation["binary_version"] as? String, CoordinatorClient.binaryVersion)
        }

        await client.acceptAssignedSessionForTest(assignedID: "session-accepted")
        let challenge = postureChallenge()
        let challengeData = try JSONSerialization.data(withJSONObject: challenge)
        try await client.handleForTest(.string(String(decoding: challengeData, as: UTF8.self)))
        let sent = await recorder.frames()
        let response = try XCTUnwrap(sent.last)
        XCTAssertEqual(response["type"] as? String, "privacy_posture_response")
        let statement = try XCTUnwrap(response["statement"] as? [String: Any])
        XCTAssertEqual(statement["privacy_key_record_digests"] as? [String], try recordDigests(try XCTUnwrap(heartbeat["privacy_key_records"] as? [[String: Any]])))
        XCTAssertEqual(try wireUInt64(statement["sequence"]), 1)
        XCTAssertEqual(statement["provider_id"] as? String, "provider-test")
        XCTAssertEqual(statement["assigned_session"] as? String, "session-accepted")
    }

    func testStatementListsExactlyAdvertisedDigests() throws {
        let root = try makeStateRoot()
        let runtime = try makeRuntime(directory: root, models: ["model-b", "model-a"])
        let responder = makeResponder(
            runtime: runtime,
            signer: try SELivenessTestSigning.generate(),
            probe: MutablePrivacyPostureProbe(greenPrivacyObservation())
        )
        let records = try XCTUnwrap(responder.privacyKeyRecords())
        XCTAssertEqual(records.count, 2)
        let digests = try recordDigests(records)
        XCTAssertEqual(digests, digests.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        let response = try XCTUnwrap(responder.respond(to: postureChallenge(), assignedSession: "session-1"))
        let statement = try XCTUnwrap(response["statement"] as? [String: Any])
        XCTAssertEqual(statement["privacy_key_record_digests"] as? [String], digests)
    }

    func testPostureResponseFramingMatchesFixtureHex() throws {
        let fixture = try privacyFixture()
        let posture = try XCTUnwrap(fixture["posture"] as? [String: Any])
        let expected = try XCTUnwrap(fixture["posture_framing_hex"] as? String)
        let statement = try postureStatement(posture)
        XCTAssertEqual(try statement.framing().hex, expected)

        let signer = try SELivenessTestSigning.generate()
        let framing = try statement.framing()
        let identity = Curve25519.Signing.PrivateKey()
        let response: [String: Any] = [
            "type": "privacy_posture_response",
            "version": 1,
            "statement": statement.wireObject,
            "se_signature": RelayBlindBase64URL.encode(try signer.sign(framing)),
            "identity_signature": RelayBlindBase64URL.encode(try identity.signature(for: framing)),
        ]
        let url = try makeStateRoot().appendingPathComponent("privacy-posture-response.json")
        let encoded = try JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
        try encoded.write(to: url, options: .atomic)
        let readBack = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let parsed = try XCTUnwrap(readBack)
        XCTAssertEqual(parsed["type"] as? String, "privacy_posture_response")
        XCTAssertEqual(parsed["version"] as? Int, 1)
        let rebuilt = try postureStatement(try XCTUnwrap(parsed["statement"] as? [String: Any]))
        let rebuiltFraming = try rebuilt.framing()
        XCTAssertEqual(rebuiltFraming.hex, expected)
        var x963 = Data([0x04])
        x963.append(signer.publicKeyRaw)
        let publicKey = try P256.Signing.PublicKey(x963Representation: x963)
        let der = try RelayBlindBase64URL.decode(try XCTUnwrap(parsed["se_signature"] as? String))
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der), for: rebuiltFraming))
        let identitySignature = try RelayBlindBase64URL.decode(try XCTUnwrap(parsed["identity_signature"] as? String), exactCount: 64)
        XCTAssertTrue(identity.publicKey.isValidSignature(identitySignature, for: rebuiltFraming))
    }

    func testFixtureSEPublicKeyPersistsWithMode0600() throws {
        let root = try makeStateRoot()
        let first = try FixturePrivacySEKey.loadOrCreate(stateRoot: root)
        let second = try FixturePrivacySEKey.loadOrCreate(stateRoot: root)
        XCTAssertEqual(first.publicKeyBase64, second.publicKeyBase64)
        XCTAssertEqual(first.publicKeyRaw.count, 64)
        XCTAssertEqual(second.publicKeyRaw.count, 64)
        let url = root.appendingPathComponent("privacy").appendingPathComponent(FixturePrivacySEKey.fileName)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        var info = stat()
        XCTAssertEqual(fstat(fd, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let directory = root.appendingPathComponent("privacy")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let directoryMode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(directoryMode & 0o777, 0o700)
    }

    private func makeResponder(
        runtime: RelayBlindProviderRuntime,
        signer: SELivenessTestSigning,
        probe: MutablePrivacyPostureProbe
    ) -> PrivacyPostureResponder {
        PrivacyPostureResponder(
            probe: probe,
            seSigner: signer,
            seKeyBackend: PrivacyClassConstants.seBackendFile,
            relayBlindRuntime: runtime,
            providerID: "provider-test",
            binaryVersion: CoordinatorClient.binaryVersion
        )
    }

    private func assertPostureSignatures(
        _ response: [String: Any],
        signer: SELivenessTestSigning,
        identity: RelayBlindKeyManager,
        sequence: UInt64
    ) throws {
        XCTAssertEqual(response["type"] as? String, "privacy_posture_response")
        XCTAssertEqual(response["version"] as? Int, 1)
        let statementObject = try XCTUnwrap(response["statement"] as? [String: Any])
        let statement = try postureStatement(statementObject)
        XCTAssertEqual(statement.sequence, sequence)
        let framing = try statement.framing()
        var x963 = Data([0x04])
        x963.append(signer.publicKeyRaw)
        let publicKey = try P256.Signing.PublicKey(x963Representation: x963)
        let der = try RelayBlindBase64URL.decode(try XCTUnwrap(response["se_signature"] as? String))
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der), for: framing))
        let identityKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: try RelayBlindBase64URL.decode(identity.identityPublicKeyBase64URL(), exactCount: 32)
        )
        let identitySignature = try RelayBlindBase64URL.decode(try XCTUnwrap(response["identity_signature"] as? String), exactCount: 64)
        XCTAssertTrue(identityKey.isValidSignature(identitySignature, for: framing))
    }
}

private actor PrivacyFrameRecorder {
    private var stored: [[String: Any]] = []

    func append(_ frame: [String: Any]) {
        stored.append(frame)
    }

    func frames() -> [[String: Any]] { stored }
}

private actor IdlePrivacyRuntime: ModelRuntimeServing {
    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        throw RelayBlindProviderError.providerUnsupported
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        throw RelayBlindProviderError.providerUnsupported
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        throw RelayBlindProviderError.providerUnsupported
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        throw RelayBlindProviderError.providerUnsupported
    }

    func unregisterInFlight(_ id: Int) {}

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { false }
    func setProviderStatus(_ providerStatus: ProviderStatus) async {}
    nonisolated var isSettlementReceiptEligible: Bool { false }
    nonisolated var settlementRuntimeSource: String? { nil }
}

private final class MutablePrivacyPostureProbe: PrivacyPostureProbe, @unchecked Sendable {
    var observation: PrivacyPostureObservation
    var traced: Bool

    init(_ observation: PrivacyPostureObservation, traced: Bool = false) {
        self.observation = observation
        self.traced = traced
    }

    func observe() -> PrivacyPostureObservation { observation }
    func isTracedOrDebugged() -> Bool { traced }
}

private func greenPrivacyObservation() -> PrivacyPostureObservation {
    PrivacyPostureObservation(
        hardenedRuntime: true,
        libraryValidation: true,
        getTaskAllow: false,
        csDebugged: false,
        pTraced: false,
        ptDenyAttachApplied: true,
        coreDumpsDisabled: true,
        sipEnabled: true,
        diagnosticEnvClear: true,
        kvDiskTierDisabled: true,
        runtimeSource: PrivacyClassConstants.runtimeSource,
        codeCDHash: String(repeating: "ab", count: 20),
        teamID: "AB12CD34EF",
        signingIdentifier: "live.malibu.provider.cli",
        binaryVersion: CoordinatorClient.binaryVersion,
        failureReasons: []
    )
}

private func postureChallenge(nonce: Data = Data(repeating: 0x11, count: 32)) -> [String: Any] {
    [
        "type": "privacy_posture_challenge",
        "version": 1,
        "nonce": RelayBlindBase64URL.encode(nonce),
        "issued_at_unix": 1_700_000_000,
    ]
}

private func makeStateRoot() throws -> URL {
    let root = makeStateRootURL()
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return root
}

private func makeStateRootURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("macprovider-privacy-posture-\(UUID().uuidString)", isDirectory: true)
}

private func makeRuntime(directory: URL, models: [String]) throws -> RelayBlindProviderRuntime {
    let keys = try RelayBlindKeyManager(
        directory: directory,
        models: models,
        persistAgreementKey: false
    )
    let journal = try RelayBlindExecutionJournal(
        directory: try PrivacyStateDirectory.executionJournal(stateRoot: directory)
    )
    return RelayBlindProviderRuntime(keyManager: keys, journal: journal)
}

private func recordDigests(_ records: [[String: Any]]) throws -> [String] {
    try records.map { record in
        let attestation = try XCTUnwrap(record["privacy_key_attestation"] as? [String: Any])
        let key = try XCTUnwrap(record["key_record"] as? [String: Any])
        let fromAttestation = try XCTUnwrap(attestation["key_record_digest"] as? String)
        XCTAssertEqual(fromAttestation, key["key_record_digest"] as? String)
        XCTAssertEqual(attestation["not_before_unix"] as? Int, key["not_before_unix"] as? Int)
        XCTAssertEqual(attestation["expires_at_unix"] as? Int, key["expires_at_unix"] as? Int)
        return fromAttestation
    }
}

private func postureStatement(_ object: [String: Any]) throws -> PrivacyPostureStatement {
    PrivacyPostureStatement(
        version: try wireString(object, "version"),
        privacyClass: try wireString(object, "privacy_class"),
        providerID: try wireString(object, "provider_id"),
        assignedSession: try wireString(object, "assigned_session"),
        nonce: try wireString(object, "nonce"),
        sequence: try wireUInt64(object["sequence"]),
        issuedAtUnix: try wireInt64(object["issued_at_unix"]),
        binaryVersion: try wireString(object, "binary_version"),
        codeCDHash: try wireString(object, "code_cdhash"),
        teamID: try wireString(object, "team_id"),
        signingIdentifier: try wireString(object, "signing_identifier"),
        hardenedRuntime: try wireBool(object["hardened_runtime"]),
        libraryValidation: try wireBool(object["library_validation"]),
        getTaskAllow: try wireBool(object["get_task_allow"]),
        csDebugged: try wireBool(object["cs_debugged"]),
        pTraced: try wireBool(object["p_traced"]),
        ptDenyAttachApplied: try wireBool(object["pt_deny_attach_applied"]),
        coreDumpsDisabled: try wireBool(object["core_dumps_disabled"]),
        sipEnabled: try wireBool(object["sip_enabled"]),
        runtimeSource: try wireString(object, "runtime_source"),
        diagnosticEnvClear: try wireBool(object["diagnostic_env_clear"]),
        kvDiskTierDisabled: try wireBool(object["kv_disk_tier_disabled"]),
        seKeyBackend: try wireString(object, "se_key_backend"),
        privacyKeyRecordDigests: try XCTUnwrap(object["privacy_key_record_digests"] as? [String])
    )
}

private func privacyFixture() throws -> [String: Any] {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = tests.appendingPathComponent("../../../test/fixtures/relay-blind/privacy-response-v1.json").standardizedFileURL
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func wireString(_ object: [String: Any], _ key: String) throws -> String {
    try XCTUnwrap(object[key] as? String)
}

private func wireBool(_ value: Any?) throws -> Bool {
    if let value = value as? Bool { return value }
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue
    }
    throw PrivacyClassError.invalidMaterial
}

private func wireUInt64(_ value: Any?) throws -> UInt64 {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw PrivacyClassError.invalidMaterial
    }
    return number.uint64Value
}

private func wireInt64(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw PrivacyClassError.invalidMaterial
    }
    return number.int64Value
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
