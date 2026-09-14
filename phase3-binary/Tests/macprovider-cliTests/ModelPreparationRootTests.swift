import Darwin
import Foundation
@testable import macprovider_cli
import XCTest

final class ModelPreparationRootTests: XCTestCase {
    func testBootstrapCreatesPrivateV3NamespaceAndStableRootIdentity() throws {
        let root = try temporaryDirectory("model-prep-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifacts", isDirectory: true)
        let random = DeterministicModelPreparationRandomSource(
            nonce: Data(repeating: 0x42, count: 32),
            uuids: ["11111111-1111-4111-8111-111111111111"]
        )
        let store = ModelPreparationPrivateStore(authorityRoot: authority, artifactRoot: artifact, randomSource: random)

        let first = try store.bootstrap()
        let second = try store.bootstrap()

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.namespacePath.hasSuffix("/artifacts/.macprovider-prepared-v3"))
        try assertMode(authority, type: S_IFDIR, mode: 0o700)
        try assertMode(authority.appendingPathComponent("operation.lock"), type: S_IFREG, mode: 0o600)
        try assertMode(authority.appendingPathComponent("failure.lock"), type: S_IFREG, mode: 0o600)
        try assertMode(authority.appendingPathComponent("cancel.lock"), type: S_IFREG, mode: 0o600)
        let namespace = artifact.appendingPathComponent(".macprovider-prepared-v3", isDirectory: true)
        try assertMode(namespace, type: S_IFDIR, mode: 0o700)
        try assertMode(namespace.appendingPathComponent("bootstrap-tmp", isDirectory: true), type: S_IFDIR, mode: 0o700)
        try assertMode(namespace.appendingPathComponent("objects", isDirectory: true), type: S_IFDIR, mode: 0o700)
        try assertMode(namespace.appendingPathComponent("work/staging", isDirectory: true), type: S_IFDIR, mode: 0o700)
        try assertMode(namespace.appendingPathComponent("work/unpublished", isDirectory: true), type: S_IFDIR, mode: 0o700)
        let identityURL = namespace.appendingPathComponent("root.identity")
        try assertMode(identityURL, type: S_IFREG, mode: 0o600)
        try assertNoExtendedACL(identityURL)

        let data = try Data(contentsOf: identityURL)
        XCTAssertThrowsError(
            try ModelPreparationContracts.decode(
                ModelPreparationPrivateStateEnvelope.self,
                from: data,
                maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
            )
        )
        let identity = try ModelPreparationContracts.decode(
            ModelPreparationRootIdentityRecord.self,
            from: data,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        XCTAssertEqual(identity.canonicalPath, first.rootLocator.canonicalPath)
        XCTAssertEqual(try identity.digest, first.rootLocator.rootIdentityDigest)
        XCTAssertEqual(identity.stDev, first.rootLocator.stDev)
        XCTAssertEqual(identity.stIno, first.rootLocator.stIno)
    }

    func testBootstrapRejectsExistingRootIdentityWithExtendedACL() throws {
        let root = try temporaryDirectory("model-prep-root-acl")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifacts", isDirectory: true)
        let store = ModelPreparationPrivateStore(
            authorityRoot: authority,
            artifactRoot: artifact,
            randomSource: DeterministicModelPreparationRandomSource()
        )
        _ = try store.bootstrap()
        let identity = artifact
            .appendingPathComponent(".macprovider-prepared-v3", isDirectory: true)
            .appendingPathComponent("root.identity")
        try addReadACLEntry(to: identity)

        XCTAssertThrowsError(try store.bootstrap()) { error in
            XCTAssert(String(describing: error).contains("extended ACL"), String(describing: error))
        }
    }

    func testBootstrapRejectsEnvelopeBytesAtRootIdentity() throws {
        let root = try temporaryDirectory("model-prep-root-envelope")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifacts", isDirectory: true)
        let store = ModelPreparationPrivateStore(
            authorityRoot: authority,
            artifactRoot: artifact,
            randomSource: DeterministicModelPreparationRandomSource()
        )
        _ = try store.bootstrap()
        let identity = artifact
            .appendingPathComponent(".macprovider-prepared-v3", isDirectory: true)
            .appendingPathComponent("root.identity")
        let envelope = try ModelPreparationPrivateStateEnvelope(
            recordKind: .active,
            targetLeaf: "active.json",
            writerUUID: "33333333-3333-4333-8333-333333333333",
            generation: 1,
            payload: Data("not-root".utf8)
        )
        let envelopeData = try ModelPreparationContracts.encode(
            envelope,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        try envelopeData.write(to: identity)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)

        XCTAssertThrowsError(try store.bootstrap())
        XCTAssertEqual(try Data(contentsOf: identity), envelopeData)
    }

    func testRecoverRootIdentityTempCompletesRawRecordBytesOnly() throws {
        let root = try temporaryDirectory("model-prep-root-temp-recover")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifacts", isDirectory: true)
        let store = ModelPreparationPrivateStore(
            authorityRoot: authority,
            artifactRoot: artifact,
            randomSource: DeterministicModelPreparationRandomSource()
        )
        _ = try store.bootstrap()
        let namespace = artifact.appendingPathComponent(".macprovider-prepared-v3", isDirectory: true)
        let identity = namespace.appendingPathComponent("root.identity")
        let rawIdentity = try Data(contentsOf: identity)
        try FileManager.default.removeItem(at: identity)
        let temp = namespace
            .appendingPathComponent("bootstrap-tmp", isDirectory: true)
            .appendingPathComponent("root.identity.44444444-4444-4444-8444-444444444444.tmp")
        try rawIdentity.write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)

        let report = try store.recoverRootIdentityTemps()

        XCTAssertEqual(report.completed, [temp.lastPathComponent])
        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(try Data(contentsOf: identity), rawIdentity)
        XCTAssertThrowsError(
            try ModelPreparationContracts.decode(
                ModelPreparationPrivateStateEnvelope.self,
                from: rawIdentity,
                maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testBootstrapRejectsSymlinkRootWithoutMutatingOutsideSentinel() throws {
        let root = try temporaryDirectory("model-prep-root-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let sentinel = real.appendingPathComponent("sentinel")
        try Data("outside".utf8).write(to: sentinel)

        let store = ModelPreparationPrivateStore(
            authorityRoot: root.appendingPathComponent("authority", isDirectory: true),
            artifactRoot: link,
            randomSource: DeterministicModelPreparationRandomSource()
        )
        XCTAssertThrowsError(try store.bootstrap())
        XCTAssertEqual(try String(contentsOf: sentinel), "outside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent(".macprovider-prepared-v3").path))
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}

final class DeterministicModelPreparationRandomSource: @unchecked Sendable, ModelPreparationRandomSource {
    private let nonce: Data
    private let lock = NSLock()
    private var uuids: [String]

    init(
        nonce: Data = Data(repeating: 0x11, count: 32),
        uuids: [String] = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]
    ) {
        self.nonce = nonce
        self.uuids = uuids
    }

    func randomBytes(count: Int) throws -> Data {
        Data(nonce.prefix(count))
    }

    func uuidString() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if uuids.isEmpty { return UUID().uuidString.lowercased() }
        return uuids.removeFirst()
    }
}

func assertMode(
    _ url: URL,
    type: mode_t,
    mode: mode_t,
    expectedLinkCount: nlink_t? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    var info = stat()
    XCTAssertEqual(lstat(url.path, &info), 0, file: file, line: line)
    XCTAssertEqual(info.st_mode & S_IFMT, type, file: file, line: line)
    XCTAssertEqual(info.st_mode & 0o777, mode, file: file, line: line)
    if let expectedLinkCount {
        XCTAssertEqual(info.st_nlink, expectedLinkCount, file: file, line: line)
    }
}

func assertNoExtendedACL(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(fd, 0, file: file, line: line)
    defer { close(fd) }
    errno = 0
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
        XCTAssertTrue(errno == 0 || errno == ENOENT, file: file, line: line)
        return
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    XCTAssertEqual(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry), 0, file: file, line: line)
    XCTAssertNil(entry, file: file, line: line)
}

func addReadACLEntry(to url: URL) throws {
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/bin/chmod")
    command.arguments = ["+a", "\(NSUserName()) allow read", url.path]
    try command.run()
    command.waitUntilExit()
    XCTAssertEqual(command.terminationStatus, 0)
}
