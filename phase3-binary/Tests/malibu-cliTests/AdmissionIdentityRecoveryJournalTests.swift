import Foundation
import XCTest
@testable import malibu_cli

final class AdmissionIdentityRecoveryJournalTests: XCTestCase {
    func testJournalPersistsExactRequestAndReusesItAcrossRestaging() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = AdmissionIdentityRecoveryJournalStore(url: fixture.journalURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = AdmissionIdentityRecoveryJournalRecord(
            providerID: "provider-a",
            candidatePublicKeySHA256: String(repeating: "a", count: 64),
            requestedUntil: now.addingTimeInterval(3_600),
            reason: "operator requested recovery",
            incidentID: "incident-original"
        )
        let replacement = AdmissionIdentityRecoveryJournalRecord(
            providerID: "provider-a",
            candidatePublicKeySHA256: String(repeating: "a", count: 64),
            requestedUntil: now.addingTimeInterval(7_200),
            reason: "different retry text",
            incidentID: "incident-retry"
        )

        XCTAssertEqual(
            try store.persistOrReuse(original, configPath: fixture.configURL.path, now: now),
            original
        )
        XCTAssertEqual(
            try store.persistOrReuse(replacement, configPath: fixture.configURL.path, now: now),
            original,
            "an app restart must resume the exact original operator request"
        )
        XCTAssertEqual(try store.load(configPath: fixture.configURL.path), original)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: fixture.journalURL.path)[.posixPermissions] as? Int,
            0o600
        )
    }

    func testJournalReplacesExpiredRequestButClearsOnlyExactRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = AdmissionIdentityRecoveryJournalStore(url: fixture.journalURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = AdmissionIdentityRecoveryJournalRecord(
            providerID: "provider-a",
            candidatePublicKeySHA256: String(repeating: "b", count: 64),
            requestedUntil: now.addingTimeInterval(-1),
            reason: "expired request",
            incidentID: "incident-expired"
        )
        let live = AdmissionIdentityRecoveryJournalRecord(
            providerID: "provider-a",
            candidatePublicKeySHA256: String(repeating: "b", count: 64),
            requestedUntil: now.addingTimeInterval(3_600),
            reason: "replacement request",
            incidentID: "incident-live"
        )

        _ = try store.persistOrReuse(expired, configPath: fixture.configURL.path, now: now.addingTimeInterval(-10))
        XCTAssertThrowsError(
            try store.loadRequired(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .expired)
        }
        XCTAssertEqual(
            try store.loadRequired(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                now: now,
                allowExpired: true
            ),
            expired,
            "activation must be able to clear an expired journal after the candidate was already committed"
        )
        XCTAssertEqual(
            try store.persistOrReuse(live, configPath: fixture.configURL.path, now: now),
            live
        )
        XCTAssertFalse(try store.clearIfMatches(expired, configPath: fixture.configURL.path))
        XCTAssertEqual(try store.load(configPath: fixture.configURL.path), live)
        XCTAssertTrue(try store.clearIfMatches(live, configPath: fixture.configURL.path))
        XCTAssertNil(try store.load(configPath: fixture.configURL.path))
    }

    func testJournalRejectsGroupReadableRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = AdmissionIdentityRecoveryJournalRecord(
            providerID: "provider-a",
            candidatePublicKeySHA256: String(repeating: "c", count: 64),
            requestedUntil: Date().addingTimeInterval(3_600),
            reason: "permission test",
            incidentID: "incident-permissions"
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: fixture.journalURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: fixture.journalURL.path
        )

        XCTAssertThrowsError(
            try AdmissionIdentityRecoveryJournalStore(url: fixture.journalURL)
                .load(configPath: fixture.configURL.path)
        ) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
    }

    func testJournalRejectsBroadParentDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = AdmissionIdentityRecoveryJournalStore(url: fixture.journalURL)
        XCTAssertEqual(chmod(fixture.directory.path, 0o755), 0)

        XCTAssertThrowsError(
            try store.persistOrReuse(
                fixture.record(digest: "d", incidentID: "incident-broad-parent"),
                configPath: fixture.configURL.path,
                now: Date()
            )
        ) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    func testJournalRejectsSymlinkWithoutReplacingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.directory.appendingPathComponent("attacker.json")
        let targetData = Data("attacker-owned".utf8)
        try targetData.write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(
            at: fixture.journalURL,
            withDestinationURL: target
        )
        let store = AdmissionIdentityRecoveryJournalStore(url: fixture.journalURL)

        XCTAssertThrowsError(try store.load(configPath: fixture.configURL.path)) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
        XCTAssertThrowsError(
            try store.persistOrReuse(
                fixture.record(digest: "e", incidentID: "incident-symlink"),
                configPath: fixture.configURL.path,
                now: Date()
            )
        ) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), targetData)
    }

    func testJournalRejectsHardLinkAndDoesNotClearEitherName() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = AdmissionIdentityRecoveryJournalStore(url: fixture.journalURL)
        let record = fixture.record(digest: "f", incidentID: "incident-hard-link")
        _ = try store.persistOrReuse(record, configPath: fixture.configURL.path, now: Date())
        let secondName = fixture.directory.appendingPathComponent("second-name.json")
        try FileManager.default.linkItem(at: fixture.journalURL, to: secondName)

        XCTAssertThrowsError(try store.load(configPath: fixture.configURL.path)) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
        XCTAssertThrowsError(
            try store.clearIfMatches(record, configPath: fixture.configURL.path)
        ) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondName.path))
    }

    func testJournalRejectsSymlinkedLockWithoutMutatingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.directory.appendingPathComponent("attacker-lock")
        let targetData = Data("do-not-touch".utf8)
        try targetData.write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        let lockURL = fixture.directory.appendingPathComponent(".\(fixture.journalURL.lastPathComponent).lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)

        XCTAssertThrowsError(
            try AdmissionIdentityRecoveryJournalStore(url: fixture.journalURL)
                .load(configPath: fixture.configURL.path)
        ) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), targetData)
    }

    func testJournalRejectsExtendedACLOnParentAndRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = AdmissionIdentityRecoveryJournalStore(url: fixture.journalURL)
        let record = fixture.record(digest: "a", incidentID: "incident-acl")

        try fixture.addExtendedACL(to: fixture.directory)
        XCTAssertThrowsError(try store.load(configPath: fixture.configURL.path)) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
        try fixture.removeExtendedACL(from: fixture.directory)

        _ = try store.persistOrReuse(record, configPath: fixture.configURL.path, now: Date())
        try fixture.addExtendedACL(to: fixture.journalURL)
        XCTAssertThrowsError(try store.load(configPath: fixture.configURL.path)) { error in
            XCTAssertEqual(error as? AdmissionIdentityRecoveryJournalError, .insecureFile)
        }
        try fixture.removeExtendedACL(from: fixture.journalURL)
    }
}

private final class Fixture {
    let directory: URL
    let configURL: URL
    let journalURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-recovery-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        configURL = directory.appendingPathComponent("config.yaml")
        journalURL = directory.appendingPathComponent("journal.json")
        try Data("provider_id: provider-a\nport: 9999\n".utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func record(digest: Character, incidentID: String) -> AdmissionIdentityRecoveryJournalRecord {
        AdmissionIdentityRecoveryJournalRecord(
            providerID: "provider-a",
            candidatePublicKeySHA256: String(repeating: digest, count: 64),
            requestedUntil: Date().addingTimeInterval(3_600),
            reason: "filesystem integrity test",
            incidentID: incidentID
        )
    }

    func addExtendedACL(to url: URL) throws {
        try runChmod(["+a", "\(NSUserName()) allow read", url.path])
    }

    func removeExtendedACL(from url: URL) throws {
        try runChmod(["-N", url.path])
    }

    private func runChmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AdmissionIdentityRecoveryJournalTests.chmod",
                code: Int(process.terminationStatus)
            )
        }
    }
}
