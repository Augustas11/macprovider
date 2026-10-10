import CryptoKit
import DeviceCheck
import XCTest
@testable import Malibu

final class AppAttestEnrollmentTests: XCTestCase {
    private let providerID = "mp-0123456789abcdef0123456789abcdef"
    private let challengeB64 = Data(repeating: 0xA1, count: 32).base64EncodedString()
    private let clientData = #"{"purpose":"app-attest","nonce":"x/y"}"#
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppAttestEnrollmentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUnsupportedPlatformDoesNothing() async {
        let keys = FakeKeyService(isSupported: false)
        let cli = FakeCLI(responses: [])
        let outcome = await makeEnrollment(keys: keys, cli: cli).run(providerID: providerID)

        XCTAssertEqual(outcome, .unsupported)
        XCTAssertTrue(cli.calls.isEmpty)
        XCTAssertTrue(keys.attested.isEmpty)
        XCTAssertFalse(store.isDone(providerID))
        XCTAssertNil(store.nextAttempt(providerID))
    }

    func testRealServiceIsUnsupportedBeforeMacOS27() throws {
        try XCTSkipIf(ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        ))
        XCTAssertFalse(DeviceCheckAppAttestKeyService().isSupported)
    }

    func testAlreadyRecordedShortCircuitsAndPersistsDone() async {
        let keys = FakeKeyService()
        let cli = FakeCLI(responses: [ok(#"{"status":"already_recorded","provider_id":"\#(providerID)"}"#)])
        let enrollment = makeEnrollment(keys: keys, cli: cli)

        let outcome = await enrollment.run(providerID: providerID)

        XCTAssertEqual(outcome, .alreadyRecorded)
        XCTAssertEqual(cli.calls.map(\.arguments), [["app-attest", "challenge"]])
        XCTAssertEqual(keys.generated, 0)
        XCTAssertTrue(store.isDone(providerID))

        let again = await enrollment.run(providerID: providerID)
        XCTAssertEqual(again, .alreadyDone)
        XCTAssertEqual(cli.calls.count, 1)
    }

    func testSuccessAttestsClientDataHashAndSubmitsExactArguments() async throws {
        let keys = FakeKeyService()
        let cli = FakeCLI(responses: [
            ok(challengeJSON()),
            ok(#"{"status":"recorded","provider_id":"\#(providerID)"}"#),
        ])

        let outcome = await makeEnrollment(keys: keys, cli: cli).run(providerID: providerID)

        XCTAssertEqual(outcome, .recorded)
        XCTAssertEqual(keys.attested.count, 1)
        XCTAssertEqual(keys.attested.first?.keyID, FakeKeyService.keyID)
        XCTAssertEqual(keys.attested.first?.hash, Data(SHA256.hash(data: Data(clientData.utf8))))
        XCTAssertEqual(cli.calls.count, 2)
        XCTAssertNil(cli.calls[0].stdin)
        XCTAssertEqual(cli.calls[1].arguments, [
            "app-attest", "submit", "--challenge", challengeB64, "--key-id", FakeKeyService.keyID,
        ])
        XCTAssertEqual(cli.calls[1].stdin, Data(FakeKeyService.attestation.base64EncodedString().utf8))
        XCTAssertTrue(store.isDone(providerID))
        XCTAssertNil(store.nextAttempt(providerID))
    }

    func testSubmitFailureDoesNotPersistDoneAndBacksOffThenRetries() async {
        let keys = FakeKeyService()
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let cli = FakeCLI(responses: [
            ok(challengeJSON()),
            AppAttestCLIResult(stdout: Data(), stderr: Data("app-attest submit failed: HTTP 503\n".utf8), status: 5),
            ok(#"{"status":"already_recorded","provider_id":"\#(providerID)"}"#),
        ])
        let enrollment = makeEnrollment(keys: keys, cli: cli, clock: clock)

        let first = await enrollment.run(providerID: providerID)
        XCTAssertEqual(first, .failed("submit_exit_5"))
        XCTAssertFalse(store.isDone(providerID))
        let next = try? XCTUnwrap(store.nextAttempt(providerID))
        XCTAssertEqual(next, clock.now.addingTimeInterval(AppAttestEnrollmentStore.backoff[0]))

        let blocked = await enrollment.run(providerID: providerID)
        XCTAssertEqual(blocked, .backingOff(until: next!))
        XCTAssertEqual(cli.calls.count, 2)

        clock.now = next!
        let retried = await enrollment.run(providerID: providerID)
        XCTAssertEqual(retried, .alreadyRecorded)
        XCTAssertTrue(store.isDone(providerID))
    }

    func testBackoffGrowsAndIsBounded() {
        let start = Date(timeIntervalSince1970: 0)
        for _ in 0..<10 { store.recordFailure(providerID, now: start) }
        XCTAssertEqual(store.nextAttempt(providerID), start.addingTimeInterval(AppAttestEnrollmentStore.backoff.last!))
    }

    func testAttestFailureDoesNotSubmitOrPersistDone() async {
        let keys = FakeKeyService(attestError: NSError(domain: DCError.errorDomain, code: 2))
        let cli = FakeCLI(responses: [ok(challengeJSON())])

        let outcome = await makeEnrollment(keys: keys, cli: cli).run(providerID: providerID)

        XCTAssertEqual(outcome, .failed("device_check_error_2"))
        XCTAssertEqual(cli.calls.count, 1)
        XCTAssertFalse(store.isDone(providerID))
        XCTAssertNotNil(store.nextAttempt(providerID))
    }

    func testChallengeErrorsAndMismatchedProviderDoNotPersistDone() async {
        let cases: [(AppAttestCLIResult, String)] = [
            (AppAttestCLIResult(stdout: Data(), stderr: Data(), status: 3), "challenge_exit_3"),
            (ok("not json"), "challenge_unparseable"),
            (ok(#"{"status":"already_recorded","provider_id":"mp-other"}"#), "challenge_provider_mismatch"),
            (ok(#"{"status":"challenge","provider_id":"\#(providerID)"}"#), "challenge_malformed"),
            (ok(#"{"status":"weird","provider_id":"\#(providerID)"}"#), "challenge_unexpected_status"),
        ]
        for (response, reason) in cases {
            defaults.removePersistentDomain(forName: suiteName)
            let keys = FakeKeyService()
            let outcome = await makeEnrollment(keys: keys, cli: FakeCLI(responses: [response])).run(providerID: providerID)
            XCTAssertEqual(outcome, .failed(reason))
            XCTAssertEqual(keys.generated, 0, reason)
            XCTAssertFalse(store.isDone(providerID), reason)
        }
    }

    func testRunnerErrorIsAFailureNotACrash() async {
        let cli = FakeCLI(responses: [], error: POSIXError(.ENOENT))
        let outcome = await makeEnrollment(keys: FakeKeyService(), cli: cli).run(providerID: providerID)
        guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertFalse(store.isDone(providerID))
    }

    func testDoneIsPerProviderID() async {
        store.markDone("mp-previous")
        let cli = FakeCLI(responses: [ok(#"{"status":"already_recorded","provider_id":"\#(providerID)"}"#)])
        let outcome = await makeEnrollment(keys: FakeKeyService(), cli: cli).run(providerID: providerID)
        XCTAssertEqual(outcome, .alreadyRecorded)
        XCTAssertEqual(cli.calls.count, 1)
    }

    // MARK: - helpers

    private var store: AppAttestEnrollmentStore { AppAttestEnrollmentStore(defaults: defaults) }

    private func makeEnrollment(keys: FakeKeyService, cli: FakeCLI, clock: Clock = Clock(Date())) -> AppAttestEnrollment {
        AppAttestEnrollment(
            keyService: keys,
            runCLI: { arguments, stdin in try cli.run(arguments, stdin) },
            store: store,
            now: { clock.now }
        )
    }

    private func challengeJSON() -> String {
        let object: [String: String] = [
            "status": "challenge",
            "provider_id": providerID,
            "challenge": challengeB64,
            "client_data": clientData,
            "expires_at": "2026-10-11T00:00:00Z",
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func ok(_ json: String) -> AppAttestCLIResult {
        AppAttestCLIResult(stdout: Data((json + "\n").utf8), stderr: Data(), status: 0)
    }
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class FakeKeyService: AppAttestKeyService, @unchecked Sendable {
    static let keyID = Data(repeating: 0xB2, count: 32).base64EncodedString()
    static let attestation = Data([0xA3, 0x63, 0x66, 0x6D, 0x74])

    let isSupported: Bool
    private let attestError: Error?
    private let lock = NSLock()
    private(set) var generated = 0
    private(set) var attested: [(keyID: String, hash: Data)] = []

    init(isSupported: Bool = true, attestError: Error? = nil) {
        self.isSupported = isSupported
        self.attestError = attestError
    }

    func generateKey() async throws -> String {
        lock.withLock { generated += 1 }
        return Self.keyID
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        if let attestError { throw attestError }
        lock.withLock { attested.append((keyID, clientDataHash)) }
        return Self.attestation
    }
}

private final class FakeCLI: @unchecked Sendable {
    struct Call { let arguments: [String]; let stdin: Data? }

    private let lock = NSLock()
    private var responses: [AppAttestCLIResult]
    private let error: Error?
    private(set) var calls: [Call] = []

    init(responses: [AppAttestCLIResult], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func run(_ arguments: [String], _ stdin: Data?) throws -> AppAttestCLIResult {
        try lock.withLock {
            calls.append(Call(arguments: arguments, stdin: stdin))
            if let error { throw error }
            guard !responses.isEmpty else { throw POSIXError(.EIO) }
            return responses.removeFirst()
        }
    }
}
