import MacProviderCore
import XCTest

/// SPEC-003 v0.8 FR-C9.3 — atomic persist of a self-minted provisional
/// token into the on-disk YAML config. These tests pin the behavior the
/// coordinator-side mint flow relies on: the new token survives a write,
/// existing `provider_token:` lines are replaced (not duplicated), the
/// resulting file is mode 0600, and the write is atomic — so a crash or
/// concurrent reader never sees a half-written secret.
final class ProviderTokenPersistTests: XCTestCase {

    func testApplyProviderTokenLineAppendsWhenAbsent() {
        let existing = """
        port: 8080
        model: mlx-community/Qwen2.5-7B-Instruct-4bit
        coordinator_url: wss://coordinator.streamvc.live/ws/provider
        """
        let result = ProviderTokenPersist.applyProviderTokenLine(
            in: existing,
            token: "deadbeef" + String(repeating: "0", count: 56)
        )
        XCTAssertTrue(result.contains("provider_token: deadbeef"),
                      "expected appended provider_token line; got: \(result)")
        // Original keys preserved verbatim.
        XCTAssertTrue(result.contains("port: 8080"))
        XCTAssertTrue(result.contains("model: mlx-community/Qwen2.5-7B-Instruct-4bit"))
        XCTAssertTrue(result.contains("coordinator_url: wss://coordinator.streamvc.live/ws/provider"))
    }

    func testApplyProviderTokenLineReplacesExisting() {
        let existing = """
        port: 8080
        provider_token: 00000000000000000000000000000000
        model: mlx-community/Qwen2.5-7B-Instruct-4bit
        """
        let result = ProviderTokenPersist.applyProviderTokenLine(
            in: existing,
            token: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1"
        )
        // Exactly one provider_token line, with the new value.
        let providerTokenLines = result.split(separator: "\n").filter { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("provider_token:")
        }
        XCTAssertEqual(providerTokenLines.count, 1,
                       "expected exactly one provider_token line, got \(providerTokenLines.count): \(result)")
        XCTAssertTrue(result.contains("provider_token: ffffffffffffffffff"),
                      "expected replaced value to be the new token: \(result)")
        XCTAssertFalse(result.contains("provider_token: 00000000"),
                       "old token must not survive replace: \(result)")
        // Sibling keys are not perturbed.
        XCTAssertTrue(result.contains("port: 8080"))
        XCTAssertTrue(result.contains("model: mlx-community/Qwen2.5-7B-Instruct-4bit"))
    }

    func testWriteCreatesFileWithMode0600() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        let initial = "port: 8080\nmodel: m\n"
        try initial.write(toFile: configPath, atomically: true, encoding: .utf8)
        // Initial file likely has 0644 — the persist call must end at 0600.

        let token = String(repeating: "a", count: 64)
        try ProviderTokenPersist.write(token: token, configPath: configPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600,
                       "post-persist mode must be 0600 (secret-bearing file), got \(mode ?? -1) octal")
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("provider_token: \(token)"),
                      "token must be in the persisted file: \(onDisk)")
        XCTAssertTrue(onDisk.contains("port: 8080"), "pre-existing keys preserved")
    }

    func testWriteCreatesFileFromScratchWhenAbsent() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        let token = String(repeating: "b", count: 64)
        try ProviderTokenPersist.write(token: token, configPath: configPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("provider_token: \(token)"))
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
    }

    func testWriteThrowsParentDirectoryMissing() {
        let tempDir = "/tmp/macprovider-test-nonexistent-\(UUID().uuidString)"
        let configPath = tempDir + "/config.yaml"
        XCTAssertThrowsError(try ProviderTokenPersist.write(
            token: String(repeating: "c", count: 64),
            configPath: configPath
        )) { error in
            guard case ProviderTokenPersistError.parentDirectoryMissing = error else {
                XCTFail("expected parentDirectoryMissing, got \(error)")
                return
            }
        }
    }

    func testWriteIsAtomicNoPartialFileObservable() throws {
        // Soft check on atomicity: after a successful write the final
        // file exists at the configured path with the new content, no
        // .tmp leftovers, and the inode/path is the intended one. (A
        // hard concurrency test would need a separate reader thread —
        // out of scope for unit coverage; the implementation uses
        // rename(2) which is POSIX-atomic on same-filesystem renames.)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        try "port: 8080\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        let token = String(repeating: "d", count: 64)
        try ProviderTokenPersist.write(token: token, configPath: configPath)

        // The persist temp-file pattern is .config.yaml.token-persist-<UUID>.tmp;
        // none should remain after a successful rename.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir)
            .filter { $0.hasPrefix(".config.yaml.token-persist-") }
        XCTAssertEqual(leftovers, [], "no temp leftovers after successful persist")

        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("provider_token: \(token)"))
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "macprovider-token-persist-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        return dir
    }
}
