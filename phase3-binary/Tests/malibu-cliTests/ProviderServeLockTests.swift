import Foundation
import XCTest
@testable import malibu_cli

final class ProviderServeLockTests: XCTestCase {
    func testLockFileNameIsStableAndFilesystemSafe() {
        let first = ProviderServeLock.lockFileName(port: 61_919)
        let second = ProviderServeLock.lockFileName(port: 61_919)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("serve-port-61919-"), first)
        XCTAssertTrue(first.hasSuffix(".lock"), first)
        XCTAssertNil(first.range(of: #"[^A-Za-z0-9._-]"#, options: .regularExpression), first)
    }

    func testSecondAcquireFailsWhileFirstLockIsHeld() throws {
        let directory = try makeTemporaryDirectory()
        let first = try ProviderServeLock.acquire(providerID: "mac", port: 61_919, directory: directory)
        defer { first.release() }

        do {
            _ = try ProviderServeLock.acquire(providerID: "mac", port: 61_919, directory: directory)
            XCTFail("second same-provider same-port lock should fail")
        } catch let error as ProviderServeLockError {
            guard case .alreadyRunning(let providerID, let port, let lockPath) = error else {
                XCTFail("unexpected lock error: \(error)")
                return
            }
            XCTAssertEqual(providerID, "mac")
            XCTAssertEqual(port, 61_919)
            XCTAssertEqual(lockPath, first.url.path)
        }
    }

    func testReleaseAllowsReacquire() throws {
        let directory = try makeTemporaryDirectory()
        let first = try ProviderServeLock.acquire(providerID: "mac", port: 61_919, directory: directory)
        let lockPath = first.url.path
        first.release()

        let second = try ProviderServeLock.acquire(providerID: "mac", port: 61_919, directory: directory)
        defer { second.release() }

        XCTAssertEqual(second.url.path, lockPath)
    }

    func testDifferentPortsCanRunConcurrently() throws {
        let directory = try makeTemporaryDirectory()
        let first = try ProviderServeLock.acquire(providerID: "mac", port: 61_919, directory: directory)
        defer { first.release() }

        let second = try ProviderServeLock.acquire(providerID: "mac", port: 61_920, directory: directory)
        defer { second.release() }

        XCTAssertNotEqual(first.url.path, second.url.path)
    }

    func testSamePortDifferentProviderFailsBeforeBind() throws {
        let directory = try makeTemporaryDirectory()
        let first = try ProviderServeLock.acquire(providerID: "mac", port: 61_919, directory: directory)
        defer { first.release() }

        do {
            _ = try ProviderServeLock.acquire(providerID: "other-provider", port: 61_919, directory: directory)
            XCTFail("second same-port lock should fail even for a different provider ID")
        } catch let error as ProviderServeLockError {
            guard case .alreadyRunning(let providerID, let port, let lockPath) = error else {
                XCTFail("unexpected lock error: \(error)")
                return
            }
            XCTAssertEqual(providerID, "other-provider")
            XCTAssertEqual(port, 61_919)
            XCTAssertEqual(lockPath, first.url.path)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderServeLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
