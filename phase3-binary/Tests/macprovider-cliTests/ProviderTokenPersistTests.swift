import MacProviderCore
import Dispatch
import XCTest

/// SPEC-003 v0.8 FR-C9.3 — atomic persist of a self-minted provisional
/// token into the on-disk YAML config. These tests pin the behavior the
/// coordinator-side mint flow relies on: the new token survives a write,
/// existing `provider_token:` lines are replaced (not duplicated), the
/// resulting file is mode 0600, and the write is atomic — so a crash or
/// concurrent reader never sees a half-written secret.
final class ProviderTokenPersistTests: XCTestCase {

    func testRemoveDeletesOnlyExactExpectedTopLevelToken() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        let token = String(repeating: "a", count: 64)
        try "provider_id: provider-a\nprovider_token: \(token)\nmodel: m\n".write(
            toFile: configPath,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(try ProviderTokenPersist.remove(expectedToken: token, configPath: configPath))
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("provider_token:"))
        XCTAssertTrue(onDisk.contains("provider_id: provider-a"))
        XCTAssertTrue(onDisk.contains("model: m"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: configPath)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRemoveRedactsLegacyAutotuneBackupsButNotOperatorArchives() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        let token = String(repeating: "a", count: 64)
        let secretConfig = "provider_id: provider-a\nprovider_token: \(token)\nmodel: m\n"
        try secretConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        let automaticBackup = tempDir + "/config.yaml.bak-1718712345-0"
        let operatorArchive = tempDir + "/config.yaml.cli-backup-20260714T120000Z"
        try secretConfig.write(toFile: automaticBackup, atomically: true, encoding: .utf8)
        try secretConfig.write(toFile: operatorArchive, atomically: true, encoding: .utf8)

        XCTAssertTrue(try ProviderTokenPersist.remove(expectedToken: token, configPath: configPath))

        XCTAssertFalse(try String(contentsOfFile: automaticBackup).contains("provider_token:"))
        XCTAssertTrue(try String(contentsOfFile: automaticBackup).contains("model: m"))
        XCTAssertTrue(try String(contentsOfFile: operatorArchive).contains("provider_token: \(token)"))
    }

    func testRemovePreservesConfigWhenExpectedTokenDoesNotMatch() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        let original = "provider_id: provider-a\nprovider_token: current-token\n"
        try original.write(toFile: configPath, atomically: true, encoding: .utf8)

        XCTAssertFalse(try ProviderTokenPersist.remove(expectedToken: "stale-token", configPath: configPath))
        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), original)
    }

    func testRemovePreservesNestedProviderToken() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        try "provider_token: current-token\nauth:\n  provider_token: nested-token\n".write(
            toFile: configPath,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(try ProviderTokenPersist.remove(expectedToken: "current-token", configPath: configPath))
        XCTAssertEqual(
            try String(contentsOfFile: configPath, encoding: .utf8),
            "auth:\n  provider_token: nested-token\n"
        )
    }

    func testRemoveHandlesQuotedEscapedYAMLProviderTokenKey() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        try """
        "provider\\u005ftoken": "secret-token"
        model: m
        # provider_token: comment-only
        auth:
          provider_token: nested-token
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(try ProviderTokenPersist.remove(expectedToken: "secret-token", configPath: configPath))
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("secret-token"))
        XCTAssertTrue(onDisk.contains("model: m"))
        XCTAssertTrue(onDisk.contains("# provider_token: comment-only"))
        XCTAssertTrue(onDisk.contains("  provider_token: nested-token"))
    }

    func testRemoveRefusesEscapedYAMLKeyWhenExpectedTokenDiffers() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        let original = "\"provider\\u005ftoken\": \"secret-token\"\nmodel: m\n"
        try original.write(toFile: configPath, atomically: true, encoding: .utf8)

        XCTAssertFalse(try ProviderTokenPersist.remove(expectedToken: "other-token", configPath: configPath))
        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), original)
    }

    func testRemoveThroughSymlinkMutatesCanonicalConfigWithoutReplacingAlias() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        let aliasPath = tempDir + "/config-link.yaml"
        let token = String(repeating: "a", count: 64)
        try "provider_id: provider-a\nprovider_token: \(token)\nmodel: m\n".write(
            toFile: configPath,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: aliasPath,
            withDestinationPath: configPath
        )

        XCTAssertTrue(try ProviderTokenPersist.remove(expectedToken: token, configPath: aliasPath))
        XCTAssertFalse(try String(contentsOfFile: configPath).contains("provider_token:"))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: aliasPath),
            configPath
        )
    }

    func testApplyProviderTokenLineAppendsWhenAbsent() {
        let existing = """
        port: 8080
        model: mlx-community/Qwen2.5-7B-Instruct-4bit
        coordinator_url: wss://coordinator.malibu.tech/ws/provider
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
        XCTAssertTrue(result.contains("coordinator_url: wss://coordinator.malibu.tech/ws/provider"))
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

    func testConcurrentWritesSerializeToSingleValidTokenLine() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let configPath = tempDir + "/config.yaml"
        try "port: 8080\nmodel: m\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        let queue = DispatchQueue(label: "token-persist-test", attributes: .concurrent)
        let group = DispatchGroup()
        for index in 0..<12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                let token = String(repeating: String(format: "%x", index % 16), count: 64)
                try? ProviderTokenPersist.write(token: token, configPath: configPath)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        let tokenLines = onDisk.split(separator: "\n").filter { $0.hasPrefix("provider_token:") }
        XCTAssertEqual(tokenLines.count, 1, "serialized writers must leave one canonical provider_token line: \(onDisk)")
        XCTAssertTrue(onDisk.contains("port: 8080"))
        XCTAssertTrue(onDisk.contains("model: m"))
    }

    // SPEC-003 v0.8 FR-C9.3 — codex code-reviewer MAJOR-1 fix:
    // an indented `provider_token:` (e.g. nested under `auth:`) MUST
    // be preserved verbatim, not rewritten as a top-level key. Pre-fix
    // the line was matched after trimmingCharacters, which collapsed an
    // `auth: { provider_token: ... }` block into a top-level field and
    // broke the parent block.
    func testApplyProviderTokenLinePreservesIndentedNestedKey() {
        let existing = """
        port: 8080
        auth:
          provider_token: legacy-nested-value
        model: m
        """
        let result = ProviderTokenPersist.applyProviderTokenLine(
            in: existing,
            token: String(repeating: "e", count: 64)
        )
        // The nested key must survive untouched.
        XCTAssertTrue(result.contains("  provider_token: legacy-nested-value"),
                      "indented provider_token must be preserved verbatim: \(result)")
        // And a fresh top-level line must have been APPENDED.
        let topLevel = result.split(separator: "\n").filter { line in
            line.hasPrefix("provider_token:")
        }
        XCTAssertEqual(topLevel.count, 1,
                       "expected exactly one top-level provider_token line, got \(topLevel.count): \(result)")
        XCTAssertTrue(result.contains("provider_token: " + String(repeating: "e", count: 64)))
        // Sibling top-level keys preserved.
        XCTAssertTrue(result.contains("port: 8080"))
        XCTAssertTrue(result.contains("model: m"))
    }

    // SPEC-003 v0.8 FR-C9.3 — codex code-reviewer MAJOR-2 fix:
    // when the config has multiple top-level `provider_token:` lines
    // (e.g. from a botched earlier write), ALL must be replaced. Pre-
    // fix, only the first was rewritten and the rest survived, and the
    // YAML parser's pick between them was undefined.
    func testApplyProviderTokenLineReplacesAllDuplicateTopLevelLines() {
        let existing = """
        port: 8080
        provider_token: first-old-value
        model: m
        provider_token: second-old-value
        coordinator_url: wss://example
        provider_token: third-old-value
        """
        let result = ProviderTokenPersist.applyProviderTokenLine(
            in: existing,
            token: String(repeating: "f", count: 64)
        )
        let topLevel = result.split(separator: "\n").filter { line in
            line.hasPrefix("provider_token:")
        }
        XCTAssertEqual(topLevel.count, 1,
                       "expected exactly one provider_token line after dedup, got \(topLevel.count): \(result)")
        XCTAssertTrue(result.contains("provider_token: " + String(repeating: "f", count: 64)),
                      "expected new token to be the only one: \(result)")
        for oldValue in ["first-old-value", "second-old-value", "third-old-value"] {
            XCTAssertFalse(result.contains(oldValue),
                           "old duplicate value \(oldValue) must not survive: \(result)")
        }
        // Sibling keys preserved.
        XCTAssertTrue(result.contains("port: 8080"))
        XCTAssertTrue(result.contains("model: m"))
        XCTAssertTrue(result.contains("coordinator_url: wss://example"))
    }

    // SPEC-003 v0.8 FR-C9.3 — codex security audit NIT/comment-clobber
    // edge case: a comment line containing `provider_token:` as text
    // (e.g. `# provider_token: <legacy notes>`) MUST be preserved
    // verbatim. The prefix-only matcher already passes this because
    // comment lines start with `#`, but we lock the contract with a
    // regression test.
    func testApplyProviderTokenLinePreservesCommentLines() {
        let existing = """
        port: 8080
        # provider_token: historical-note do not change
        coordinator_url: wss://example
        """
        let result = ProviderTokenPersist.applyProviderTokenLine(
            in: existing,
            token: String(repeating: "9", count: 64)
        )
        XCTAssertTrue(result.contains("# provider_token: historical-note do not change"),
                      "comment with provider_token text must be preserved: \(result)")
        XCTAssertTrue(result.contains("provider_token: " + String(repeating: "9", count: 64)))
    }

    func testRemovingProviderTokenLinesHandlesQuotedEscapedAndBlockKeys() {
        let existing = """
        provider_token: literal-secret
        'provider_token': single-quoted-secret
        "provider\\u005ftoken": "escaped-secret"
        "provider_token": |-
          block-secret
        model: m
        auth:
          provider_token: nested-secret
        """

        let result = ProviderTokenPersist.removingProviderTokenLines(in: existing)
        XCTAssertFalse(result.contains("literal-secret"))
        XCTAssertFalse(result.contains("single-quoted-secret"))
        XCTAssertFalse(result.contains("escaped-secret"))
        XCTAssertFalse(result.contains("block-secret"))
        XCTAssertTrue(result.contains("model: m"))
        XCTAssertTrue(result.contains("  provider_token: nested-secret"))
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "macprovider-token-persist-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        return dir
    }
}
