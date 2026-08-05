import XCTest
import Darwin
@testable import macprovider_cli

final class BootstrapAuthCommandTests: XCTestCase {
    func testCredentialBootstrapPrincipalRequiresExactLowercase128BitSuffix() {
        XCTAssertTrue(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789abcdef0123456789abcdef"
        ))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal("office-mac"))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789ABCDEF0123456789ABCDEF"
        ))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789abcdef0123456789abcde"
        ))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789abcdef0123456789abcdef0"
        ))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789abcdef0123456789abcd٢"
        ))
    }

    func testExistingCLIKeychainCredentialSkipsBootstrapForAnyProviderID() throws {
        let store = InMemoryProviderCredentialStore(values: [
            "office-mac": "existing-token",
            "mp-0123456789abcdef0123456789abcdef": "existing-token",
        ])

        XCTAssertTrue(try BootstrapAuthCommand.storedCredentialPresent(
            providerID: "office-mac",
            store: store
        ))
        XCTAssertTrue(try BootstrapAuthCommand.storedCredentialPresent(
            providerID: "mp-0123456789abcdef0123456789abcdef",
            store: store
        ))
    }

    func testReferralCodeFileRequiresOwnerOnlyRegularBoundedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("referral-code")
        try Data("  MAL1-S-key-issuer-tag\n".utf8).write(to: valid)
        XCTAssertEqual(chmod(valid.path, 0o600), 0)

        let input = try ReferralCodeFile.read(path: valid.path)
        XCTAssertEqual(input.code, "MAL1-S-key-issuer-tag")
        XCTAssertEqual(input.digestSHA256.count, 64)

        XCTAssertEqual(chmod(valid.path, 0o644), 0)
        XCTAssertThrowsError(try ReferralCodeFile.read(path: valid.path)) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .invalid))
        }
    }

    func testReferralCodeFileRejectsSymlinkAndOversizedInput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try ReferralCodeFile.read(
            path: directory.appendingPathComponent("missing").path
        )) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .required))
        }
        XCTAssertThrowsError(try ReferralCodeFile.read(path: directory.path)) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .invalid))
        }
        let target = directory.appendingPathComponent("target")
        try Data("MAL1-S-key-issuer-tag".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ReferralCodeFile.read(path: link.path)) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .invalid))
        }

        let oversized = directory.appendingPathComponent("oversized")
        try Data(repeating: 0x41, count: ReferralCodeFile.maximumBytes + 1).write(to: oversized)
        XCTAssertEqual(chmod(oversized.path, 0o600), 0)
        XCTAssertThrowsError(try ReferralCodeFile.read(path: oversized.path)) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .invalid))
        }
    }

    func testReferralCodeFileRejectsHardLinkedInput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let alias = directory.appendingPathComponent("alias")
        try Data("MAL1-S-key-issuer-tag".utf8).write(to: source)
        XCTAssertEqual(chmod(source.path, 0o600), 0)
        XCTAssertEqual(link(source.path, alias.path), 0)

        XCTAssertThrowsError(try ReferralCodeFile.read(path: source.path)) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .invalid))
        }
    }

    func testReferralCodeFileDoesNotRetireInPlaceMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data("MAL1-S-key-original-tag".utf8).write(to: source)
        XCTAssertEqual(chmod(source.path, 0o600), 0)
        let input = try ReferralCodeFile.read(path: source.path)

        let descriptor = open(source.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let replacement = Data("MAL1-S-key-revised-tag".utf8)
        XCTAssertEqual(replacement.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }, replacement.count)
        XCTAssertEqual(close(descriptor), 0)

        XCTAssertThrowsError(try ReferralCodeFile.removeIfUnchanged(input)) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .unavailable))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "MAL1-S-key-revised-tag")
    }

    func testReferralJournalResumesSameBindingAndRejectsPendingCodeChange() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstInput = try makeReferralInput(in: directory, name: "first", code: "MAL1-S-key-first-tag")
        let secondInput = try makeReferralInput(in: directory, name: "second", code: "MAL1-S-key-second-tag")
        let journal = ReferralBootstrapJournal(url: directory.appendingPathComponent("attempt.json"))

        let first = try journal.prepare(
            providerID: "mp-0123456789abcdef0123456789abcdef",
            receiptPublicKey: "receipt-public-key",
            input: firstInput,
            now: Date(timeIntervalSince1970: 1)
        )
        let resumed = try journal.prepare(
            providerID: first.providerID,
            receiptPublicKey: "receipt-public-key",
            input: firstInput,
            now: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(resumed.attemptID, first.attemptID)
        XCTAssertEqual(resumed.createdAt, first.createdAt)
        XCTAssertEqual(resumed.state, .pending)
        XCTAssertNil(resumed.terminalCode)
        let persistedJournal = try String(contentsOf: journal.url, encoding: .utf8)
        XCTAssertFalse(persistedJournal.contains(firstInput.code))
        XCTAssertThrowsError(try journal.prepare(
            providerID: first.providerID,
            receiptPublicKey: "receipt-public-key",
            input: secondInput
        )) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .conflict))
        }
    }

    func testReplacementReferralJournalIsProviderScopedAndPreservesDefaultJournal() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let providerID = "mp-0123456789abcdef0123456789abcdef"
        let defaultURL = ReferralBootstrapJournal.defaultURL(home: home)
        let replacementURL = ReferralBootstrapJournal.replacementJournal(providerID: providerID, home: home).url

        XCTAssertNotEqual(replacementURL, defaultURL)
        XCTAssertTrue(replacementURL.lastPathComponent.contains(providerID))
        XCTAssertTrue(try BootstrapAuthCommand.referralJournal(
            providerID: providerID,
            replacingIncumbentProvider: true
        ).url.lastPathComponent.contains(providerID))
        XCTAssertThrowsError(try BootstrapAuthCommand.referralJournal(
            providerID: "office-mac",
            replacingIncumbentProvider: true
        )) { error in
            XCTAssertTrue("\(error)".contains("--replace-referral-journal"))
        }
    }

    func testReferralJournalTerminalCorrectionAndCommittedCleanup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstInput = try makeReferralInput(in: directory, name: "first", code: "MAL1-S-key-first-tag")
        let secondInput = try makeReferralInput(in: directory, name: "second", code: "MAL1-S-key-second-tag")
        let journal = ReferralBootstrapJournal(url: directory.appendingPathComponent("attempt.json"))
        let first = try journal.prepare(
            providerID: "mp-0123456789abcdef0123456789abcdef",
            receiptPublicKey: "receipt-public-key",
            input: firstInput
        )
        try journal.markTerminal(attemptID: first.attemptID, failure: .init(kind: .invalid))
        XCTAssertEqual(try journal.load()?.state, .terminal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstInput.path))

        let corrected = try journal.prepare(
            providerID: first.providerID,
            receiptPublicKey: "receipt-public-key",
            input: secondInput
        )
        XCTAssertNotEqual(corrected.attemptID, first.attemptID)
        try journal.markCommitted(attemptID: corrected.attemptID)
        try ReferralCodeFile.removeIfUnchanged(secondInput)
        XCTAssertEqual(try journal.load()?.state, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondInput.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstInput.path))

        let committedReplay = try makeReferralInput(
            in: directory,
            name: "committed-replay",
            code: secondInput.code
        )
        try BootstrapAuthCommand.reconcilePersistedReferral(
            providerID: corrected.providerID,
            receiptPublicKey: "receipt-public-key",
            input: committedReplay,
            journal: journal
        )
        XCTAssertEqual(try journal.load()?.state, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committedReplay.path))
    }

    func testRetryAfterCredentialPersistenceCommitsPendingJournalAndRetiresExactSource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try makeReferralInput(
            in: directory,
            name: "response-loss-referral",
            code: "MAL1-S-key-response-loss-tag"
        )
        let journal = ReferralBootstrapJournal(url: directory.appendingPathComponent("attempt.json"))
        let attempt = try journal.prepare(
            providerID: "mp-0123456789abcdef0123456789abcdef",
            receiptPublicKey: "receipt-public-key",
            input: input
        )
        XCTAssertEqual(attempt.state, .pending)

        // A retry reaches this path only after the CLI-owned Keychain already
        // contains the coordinator-minted credential from the lost response.
        try BootstrapAuthCommand.reconcilePersistedReferral(
            providerID: attempt.providerID,
            receiptPublicKey: "receipt-public-key",
            input: input,
            journal: journal
        )

        XCTAssertEqual(try journal.load()?.state, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    }

    func testPersistedCredentialReconciliationRequiresExactReceiptKeyBinding() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try makeReferralInput(
            in: directory,
            name: "receipt-mismatch-referral",
            code: "MAL1-S-key-receipt-mismatch-tag"
        )
        let journal = ReferralBootstrapJournal(url: directory.appendingPathComponent("attempt.json"))
        let attempt = try journal.prepare(
            providerID: "mp-0123456789abcdef0123456789abcdef",
            receiptPublicKey: "expected-receipt-public-key",
            input: input
        )

        XCTAssertThrowsError(try BootstrapAuthCommand.reconcilePersistedReferral(
            providerID: attempt.providerID,
            receiptPublicKey: "different-receipt-public-key",
            input: input,
            journal: journal
        )) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .conflict))
        }
        XCTAssertEqual(try journal.load()?.state, .pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    func testExistingCredentialCannotClaimReferralWithoutMatchingPendingAttempt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try makeReferralInput(
            in: directory,
            name: "unbound-referral",
            code: "MAL1-S-key-unbound-tag"
        )
        let journal = ReferralBootstrapJournal(url: directory.appendingPathComponent("attempt.json"))

        XCTAssertThrowsError(try BootstrapAuthCommand.reconcilePersistedReferral(
            providerID: "mp-0123456789abcdef0123456789abcdef",
            receiptPublicKey: "receipt-public-key",
            input: input,
            journal: journal
        )) { error in
            XCTAssertEqual(error as? ReferralBootstrapFailure, .init(kind: .conflict))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    func testReferralFailureExitCodeContract() {
        let expected: [(ReferralBootstrapFailure.Kind, Int32)] = [
            (.required, 20), (.invalid, 21), (.expired, 22), (.revoked, 23),
            (.exhausted, 24), (.conflict, 25), (.rateLimited, 26), (.unavailable, 27),
        ]
        for (kind, code) in expected {
            XCTAssertEqual(ReferralBootstrapFailure(kind: kind).exitCode, code)
        }
        XCTAssertEqual(ReferralBootstrapFailure.coordinatorCode("referral_required")?.kind, .required)
        XCTAssertEqual(ReferralBootstrapFailure.coordinatorCode("referral_invalid")?.kind, .invalid)
        XCTAssertEqual(ReferralBootstrapFailure.coordinatorCode("referral_expired")?.kind, .expired)
        XCTAssertEqual(ReferralBootstrapFailure.coordinatorCode("referral_revoked")?.kind, .revoked)
        XCTAssertEqual(ReferralBootstrapFailure.coordinatorCode("referral_exhausted")?.kind, .exhausted)
        XCTAssertEqual(ReferralBootstrapFailure.coordinatorCode("referral_conflict")?.kind, .conflict)
        XCTAssertEqual(
            ReferralBootstrapFailure.coordinatorCode("credential_bootstrap_rate_limited")?.kind,
            .rateLimited
        )
        XCTAssertNil(ReferralBootstrapFailure.coordinatorCode("invalid_token"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("referral-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }

    private func makeReferralInput(in directory: URL, name: String, code: String) throws -> ReferralCodeInput {
        let url = directory.appendingPathComponent(name)
        try Data(code.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        return try ReferralCodeFile.read(path: url.path)
    }
}
