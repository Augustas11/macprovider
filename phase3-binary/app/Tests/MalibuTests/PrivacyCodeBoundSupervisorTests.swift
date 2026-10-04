import CryptoKit
import DeviceCheck
import Darwin
import XCTest
@testable import Malibu

/// SPEC-049 v0.2 supervisor-attestor: shared framing parity, the
/// SPEC-049-R026 child check, key custody and lifecycle (SPEC-049-R025,
/// SPEC-049-R033), and the authenticated socket. Real `DCAppAttestService`
/// cannot run here; it is replaced by a recording double.
final class PrivacyCodeBoundSupervisorTests: XCTestCase {
    private let teamID = "AB12CD34EF"
    private let childCDHash = String(repeating: "ab", count: 20)
    private let goodFlags: UInt32 = 0x2201_1311

    override func setUp() {
        super.setUp()
        PrivacyCodeBoundLatch.resetForTest()
    }

    override func tearDown() {
        PrivacyCodeBoundLatch.resetForTest()
        super.tearDown()
    }

    func testSharedFramingMatchesGoVector() throws {
        let vector = try fixture()
        let posture = try PrivacyPostureV2Statement(object: try XCTUnwrap(vector["posture_v2"] as? [String: Any]))
        XCTAssertEqual(hex(try posture.framing()), vector["posture_v2_framing_hex"] as? String)
        let enrollment = try PrivacyEnrollmentStatement(object: try XCTUnwrap(vector["enrollment"] as? [String: Any]))
        XCTAssertEqual(hex(try enrollment.framing()), vector["enrollment_framing_hex"] as? String)
    }

    func testCodeBoundSettingDefaultsOff() throws {
        let suite = "malibu.privacy-code-bound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(PrivacyCodeBoundSetting.isEnabled(defaults))
        defaults.set(true, forKey: PrivacyCodeBoundSetting.defaultsKey)
        XCTAssertTrue(PrivacyCodeBoundSetting.isEnabled(defaults))
    }

    func testDeviceCheckErrorMapping() {
        XCTAssertEqual(DeviceCheckAppAttestProvider.map(NSError(domain: DCError.errorDomain, code: DCError.Code.invalidKey.rawValue)), .invalidKey)
        XCTAssertEqual(DeviceCheckAppAttestProvider.map(NSError(domain: DCError.errorDomain, code: DCError.Code.featureUnsupported.rawValue)), .unsupported)
        XCTAssertEqual(DeviceCheckAppAttestProvider.map(NSError(domain: DCError.errorDomain, code: DCError.Code.serverUnavailable.rawValue)), .failed)
        XCTAssertEqual(DeviceCheckAppAttestProvider.map(NSError(domain: NSPOSIXErrorDomain, code: 1)), .failed)
    }

    func testUnsupportedPlatformRefusesWithoutCheckingTheChild() async {
        let attest = FakeAppAttest(supported: false)
        let harness = await makeSupervisor(attest: attest)
        let reply = await harness.supervisor.handle(.key(discard: nil), peer: childPeer())
        XCTAssertEqual(reply, .error(.unsupported))
        XCTAssertEqual(harness.inspector.calls, 0)
        XCTAssertNil(PrivacyCodeBoundLatch.latchedReason)
    }

    func testChildCheckFailuresTerminateAndLatch() async {
        let cases: [(String, PrivacyChildObservation?, PrivacyChildPeer?, PrivacyChildCheckFailure)] = [
            ("unknown peer", observation(), PrivacyChildPeer(pid: 999, pidVersion: 1, token: audit_token_t()), .unknownPeer),
            ("pid reused", observation(), PrivacyChildPeer(pid: 4242, pidVersion: 8, token: audit_token_t()), .unknownPeer),
            ("no code", nil, nil, .codeUnavailable),
            ("requirement", observation(requirement: false), nil, .requirementFailed),
            ("identifier", observation(identifier: "live.malibu.provider.cli.evil"), nil, .identifierMismatch),
            ("cdhash", observation(cdhash: String(repeating: "cd", count: 20)), nil, .cdhashMismatch),
            ("flags unreadable", observation(flags: nil), nil, .flagsUnreadable),
            ("debugged", observation(flags: goodFlags | 0x1000_0000), nil, .flagsRejected),
            ("get-task-allow", observation(flags: goodFlags | 0x0000_0004), nil, .flagsRejected),
            ("no runtime", observation(flags: goodFlags & ~0x0001_0000), nil, .flagsRejected),
        ]
        for (name, observed, peer, expected) in cases {
            PrivacyCodeBoundLatch.resetForTest()
            let harness = await makeSupervisor(observation: observed, noCode: observed == nil)
            let reply = await harness.supervisor.handle(.key(discard: nil), peer: peer ?? childPeer())
            XCTAssertEqual(reply, .error(.childCheckFailed), name)
            XCTAssertEqual(PrivacyCodeBoundLatch.latchedReason, expected, name)
            XCTAssertEqual(harness.terminations.count, 1, name)
            XCTAssertEqual(harness.attest.calls, [], name)
            // Latched: even a now-valid child is refused for the process lifetime.
            await harness.supervisor.childSpawned(pid: 4242, pidVersion: 7)
            let after = await harness.supervisor.handle(.key(discard: nil), peer: childPeer())
            XCTAssertEqual(after, .error(.childCheckFailed), name)
        }
    }

    func testRequirementPinsTeamIdentifierAndApprovedCDHash() async {
        let harness = await makeSupervisor()
        _ = await harness.supervisor.handle(.key(discard: nil), peer: childPeer())
        XCTAssertEqual(
            harness.inspector.lastRequirement,
            "anchor apple generic and identifier \"live.malibu.provider.cli\" and certificate leaf[subject.OU] = \"\(teamID)\" and cdhash H\"\(childCDHash)\""
        )
    }

    func testKeyCustodyAndDiscard() async {
        let harness = await makeSupervisor()
        let first = await harness.supervisor.handle(.key(discard: nil), peer: childPeer())
        let again = await harness.supervisor.handle(.key(discard: nil), peer: childPeer())
        XCTAssertEqual(first, again)
        XCTAssertEqual(harness.attest.calls, ["generateKey"])
        guard case .key(let keyID) = first else { return XCTFail("expected a key") }
        XCTAssertEqual(PrivacySupervisorBase64URL.toAppAttestKeyID(keyID), harness.store.load())

        // Discarding a keyId that is not the stored one changes nothing.
        let other = PrivacySupervisorBase64URL.encode(Data(repeating: 9, count: 32))
        let unchanged = await harness.supervisor.handle(.key(discard: other), peer: childPeer())
        XCTAssertEqual(unchanged, first)
        let replaced = await harness.supervisor.handle(.key(discard: keyID), peer: childPeer())
        XCTAssertNotEqual(replaced, first)
        XCTAssertEqual(harness.attest.calls, ["generateKey", "generateKey"])
    }

    func testAttestationFillsSupervisorFieldsAndHashesTheFraming() async throws {
        let harness = await makeSupervisor()
        guard case .key(let keyID) = await harness.supervisor.handle(.key(discard: nil), peer: childPeer()) else {
            return XCTFail("expected a key")
        }
        let draft = enrollmentDraft(keyID: keyID)
        let reply = await harness.supervisor.handle(.attest(draft), peer: childPeer())
        guard case .attestation(let statement, let attestation) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(statement.draft, draft)
        XCTAssertEqual(statement.supervisor.teamID, teamID)
        XCTAssertEqual(statement.supervisor.bundleID, "tech.malibu.app")
        XCTAssertEqual(statement.supervisor.environment, "production")
        XCTAssertEqual(statement.supervisor.childCDHash, childCDHash)
        XCTAssertEqual(statement.supervisor.childCSFlags, UInt64(goodFlags))
        XCTAssertEqual(statement.supervisor.supervisorBundleVersion, "213")
        XCTAssertEqual(statement.supervisor.issuedAtUnix, 1_700_000_000)
        XCTAssertEqual(attestation, FakeAppAttest.attestation)
        XCTAssertEqual(harness.attest.lastClientDataHash, Data(SHA256.hash(data: try statement.framing())))

        let wrongKey = enrollmentDraft(keyID: PrivacySupervisorBase64URL.encode(Data(repeating: 3, count: 32)))
        let refused = await harness.supervisor.handle(.attest(wrongKey), peer: childPeer())
        XCTAssertEqual(refused, .error(.keyInvalid))
    }

    func testAssertionRefusesDraftsThatDisagreeWithObservations() async throws {
        let harness = await makeSupervisor()
        guard case .key(let keyID) = await harness.supervisor.handle(.key(discard: nil), peer: childPeer()) else {
            return XCTFail("expected a key")
        }
        let good = postureDraft(keyID: keyID)
        var cdhash = good
        cdhash.codeCDHash = String(repeating: "ef", count: 20)
        var identifier = good
        identifier.signingIdentifier = "other.identifier"
        var team = good
        team.teamID = "ZZ99ZZ99ZZ"
        var stale = good
        stale.issuedAtUnix -= 8
        for draft in [cdhash, identifier, team, stale] {
            let reply = await harness.supervisor.handle(.assert(draft), peer: childPeer())
            XCTAssertEqual(reply, .error(.draftRejected))
        }
        var unknownKey = good
        unknownKey.appAttestKeyID = PrivacySupervisorBase64URL.encode(Data(repeating: 4, count: 32))
        let keyReply = await harness.supervisor.handle(.assert(unknownKey), peer: childPeer())
        XCTAssertEqual(keyReply, .error(.keyInvalid))
        XCTAssertNil(PrivacyCodeBoundLatch.latchedReason, "a refused draft is not a child-check failure")
        XCTAssertFalse(harness.attest.calls.contains("generateAssertion"))

        let reply = await harness.supervisor.handle(.assert(good), peer: childPeer())
        guard case .assertion(let statement, let assertion) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(statement.draft, good)
        XCTAssertTrue(statement.childCheckConsistent)
        XCTAssertEqual(statement.supervisor.childCheckedAtUnix, 1_700_000_000)
        XCTAssertTrue(statement.supervisor.childChannelPeerVerified)
        XCTAssertEqual(assertion, FakeAppAttest.assertion)
        XCTAssertEqual(harness.attest.lastClientDataHash, Data(SHA256.hash(data: try statement.framing())))
    }

    func testInvalidKeyIsDiscarded() async {
        let harness = await makeSupervisor()
        guard case .key(let keyID) = await harness.supervisor.handle(.key(discard: nil), peer: childPeer()) else {
            return XCTFail("expected a key")
        }
        harness.attest.failure = .invalidKey
        let reply = await harness.supervisor.handle(.assert(postureDraft(keyID: keyID)), peer: childPeer())
        XCTAssertEqual(reply, .error(.keyInvalid))
        XCTAssertNil(harness.store.load())
        harness.attest.failure = .failed
        let transient = await harness.supervisor.handle(.key(discard: nil), peer: childPeer())
        XCTAssertEqual(transient, .error(.unavailable))
        harness.attest.failure = nil
        let fresh = await harness.supervisor.handle(.key(discard: nil), peer: childPeer())
        XCTAssertNotEqual(fresh, .key(appAttestKeyID: keyID))
    }

    func testKeyIDFileIsOwnerOnlyAndValidated() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("malibu-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivacyAppAttestKeyIDFile(url: directory.appendingPathComponent("app-attest-key-id"))
        XCTAssertNil(store.load())
        let keyID = Data(repeating: 0x42, count: 32).base64EncodedString()
        try store.save(keyID)
        XCTAssertEqual(store.load(), keyID)
        var info = stat()
        XCTAssertEqual(stat(store.url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertThrowsError(try store.save("not-a-key-id"))
        store.delete()
        XCTAssertNil(store.load())
    }

    func testSocketIsOwnerOnlyAndPeerComesFromTheKernel() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mps-\(UUID().uuidString.prefix(8))")
        try PrivacyCodeBoundHost.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(PrivacyCodeBoundHost.socketName)
        let listener = try PrivacyCodeBoundHost.bindListener(at: url)
        defer { close(listener) }
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let accepted = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }
        let token = try XCTUnwrap(PrivacySupervisorPeer.auditToken(socket: accepted))
        XCTAssertEqual(PrivacySupervisorPeer.pid(token), getpid())
        let own = try XCTUnwrap(PrivacySupervisorPeer.auditToken(pid: getpid()))
        XCTAssertEqual(PrivacySupervisorPeer.pidVersion(token), PrivacySupervisorPeer.pidVersion(own))

        // A frame round-trips over the real socket.
        try PrivacySupervisorFrame.write(PrivacySupervisorRequest.key(discard: nil).wireObject, to: client)
        XCTAssertEqual(try PrivacySupervisorRequest(object: try PrivacySupervisorFrame.read(from: accepted)), .key(discard: nil))

        // A stale socket file is replaced; any other file type is refused.
        close(listener)
        let rebound = try PrivacyCodeBoundHost.bindListener(at: url)
        close(rebound)
        unlink(url.path)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        XCTAssertThrowsError(try PrivacyCodeBoundHost.bindListener(at: url))
    }

    // MARK: Helpers

    private struct Harness {
        let supervisor: PrivacyCodeBoundSupervisor
        let attest: FakeAppAttest
        let store: MemoryKeyStore
        let inspector: FakeInspector
        let terminations: TerminationRecorder
    }

    private func makeSupervisor(
        attest: FakeAppAttest = FakeAppAttest(supported: true),
        observation observed: PrivacyChildObservation? = nil,
        noCode: Bool = false
    ) async -> Harness {
        let store = MemoryKeyStore()
        let inspector = FakeInspector(observation: noCode ? nil : (observed ?? observation()))
        let terminations = TerminationRecorder()
        let supervisor = PrivacyCodeBoundSupervisor(
            identity: PrivacySupervisorIdentity(teamID: teamID, bundleVersion: "213", approvedChildCDHash: childCDHash),
            appAttest: attest,
            keyStore: store,
            inspector: inspector,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            terminateChild: { terminations.record() }
        )
        await supervisor.childSpawned(pid: 4242, pidVersion: 7)
        return Harness(supervisor: supervisor, attest: attest, store: store, inspector: inspector, terminations: terminations)
    }

    private func observation(
        requirement: Bool = true,
        identifier: String = "live.malibu.provider.cli",
        cdhash: String? = nil,
        flags: UInt32? = 0x2201_1311
    ) -> PrivacyChildObservation {
        PrivacyChildObservation(requirementSatisfied: requirement, identifier: identifier, cdhash: cdhash ?? childCDHash, csFlags: flags)
    }

    private func childPeer() -> PrivacyChildPeer {
        PrivacyChildPeer(pid: 4242, pidVersion: 7, token: audit_token_t())
    }

    private func enrollmentDraft(keyID: String) -> PrivacyEnrollmentDraft {
        PrivacyEnrollmentDraft(
            providerID: "provider-test",
            assignedSession: "session-test",
            challenge: PrivacySupervisorBase64URL.encode(Data(repeating: 0x22, count: 32)),
            appAttestKeyID: keyID,
            sePublicKey: PrivacySupervisorBase64URL.encode(Data(repeating: 0x55, count: 64)),
            identityPublicKey: PrivacySupervisorBase64URL.encode(Data(repeating: 0x66, count: 32))
        )
    }

    private func postureDraft(keyID: String) -> PrivacyPostureV2Draft {
        PrivacyPostureV2Draft(
            providerID: "provider-test",
            assignedSession: "session-test",
            nonce: PrivacySupervisorBase64URL.encode(Data(repeating: 0x5a, count: 32)),
            sequence: 3,
            issuedAtUnix: 1_700_000_002,
            binaryVersion: "1.8.213",
            codeCDHash: childCDHash,
            teamID: teamID,
            signingIdentifier: "live.malibu.provider.cli",
            hardenedRuntime: true,
            libraryValidation: true,
            getTaskAllow: false,
            csDebugged: false,
            pTraced: false,
            ptDenyAttachApplied: true,
            coreDumpsDisabled: true,
            sipEnabled: true,
            runtimeSource: "native_mlx",
            diagnosticEnvClear: true,
            kvDiskTierDisabled: true,
            seKeyBackend: "keychain",
            privacyKeyRecordDigests: [PrivacySupervisorBase64URL.encode(Data(repeating: 0x33, count: 32))],
            appAttestKeyID: keyID
        )
    }

    private func fixture() throws -> [String: Any] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = tests.appendingPathComponent("../../../../test/fixtures/relay-blind/privacy-code-bound-v2.json").standardizedFileURL
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private final class FakeAppAttest: AppAttestProviding, @unchecked Sendable {
    static let attestation = Data(repeating: 0xa7, count: 800)
    static let assertion = Data(repeating: 0x3c, count: 96)

    private let lock = NSLock()
    private let supported: Bool
    private var recorded: [String] = []
    private var hash: Data?
    private var nextKey: UInt8 = 1
    private var injected: AppAttestProviderError?

    init(supported: Bool) {
        self.supported = supported
    }

    var isSupported: Bool { supported }
    var calls: [String] { lock.withLock { recorded } }
    var lastClientDataHash: Data? { lock.withLock { hash } }
    var failure: AppAttestProviderError? {
        get { lock.withLock { injected } }
        set { lock.withLock { injected = newValue } }
    }

    func generateKey() async throws -> String {
        try lock.withLock {
            recorded.append("generateKey")
            if let injected { throw injected }
            defer { nextKey += 1 }
            return Data(repeating: nextKey, count: 32).base64EncodedString()
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            recorded.append("attestKey")
            hash = clientDataHash
            if let injected { throw injected }
            return Self.attestation
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            recorded.append("generateAssertion")
            hash = clientDataHash
            if let injected { throw injected }
            return Self.assertion
        }
    }
}

private final class MemoryKeyStore: PrivacyAppAttestKeyIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keyID: String?

    func load() -> String? { lock.withLock { keyID } }
    func save(_ keyID: String) throws { lock.withLock { self.keyID = keyID } }
    func delete() { lock.withLock { keyID = nil } }
}

private final class FakeInspector: PrivacyChildInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PrivacyChildObservation?
    private var count = 0
    private var requirement: String?

    init(observation: PrivacyChildObservation?) {
        stored = observation
    }

    var observation: PrivacyChildObservation? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var calls: Int { lock.withLock { count } }
    var lastRequirement: String? { lock.withLock { requirement } }

    func inspect(_ token: audit_token_t, requirement: String) -> PrivacyChildObservation? {
        lock.withLock {
            count += 1
            self.requirement = requirement
            return stored
        }
    }
}

private final class TerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
