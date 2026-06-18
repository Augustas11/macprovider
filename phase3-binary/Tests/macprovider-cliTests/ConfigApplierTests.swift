import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ConfigApplierTests: XCTestCase {
    func testApplyCreatesBackupAtCounterZeroWhenNoCollision() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())

        let applied = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)

        XCTAssertEqual(applied.backupPath.lastPathComponent, "config.yaml.bak-1718712345-0")
        XCTAssertEqual(try String(contentsOf: applied.backupPath), sampleConfig())
        XCTAssertTrue(applied.summary.contains("backup at \(applied.backupPath.path)"))
    }

    func testApplyIncrementsCounterWhenBackupExists() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        try Data("old".utf8).write(to: fixture.configURL.deletingLastPathComponent()
            .appendingPathComponent("config.yaml.bak-1718712345-0"))

        let applied = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)

        XCTAssertEqual(applied.backupPath.lastPathComponent, "config.yaml.bak-1718712345-1")
    }

    func testApplyThrowsWhenAllCountersExhausted() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        for counter in 0...1 {
            try Data("collision".utf8).write(to: fixture.configURL.deletingLastPathComponent()
                .appendingPathComponent("config.yaml.bak-1718712345-\(counter)"))
        }

        XCTAssertThrowsError(try fixture.applier(maxBackupCounter: 1).apply(
            recommendation: recommendation(),
            now: fixture.now
        )) { error in
            XCTAssertEqual(error as? ConfigApplierError, .backupCollisionsExhausted)
        }
    }

    func testApplyPreservesNonOwnedKeysVerbatim() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())

        _ = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)

        let post = try String(contentsOf: fixture.configURL)
        XCTAssertTrue(post.contains("# important token comment\nprovider_token: keep-me\n"))
        XCTAssertTrue(post.contains("coordinator_endpoint: https://coordinator.example\n"))
        XCTAssertTrue(post.contains("log_path: /tmp/provider.log"))
    }

    func testApplyMutatesOnlyFourOwnedKeys() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())

        _ = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)

        let before = keyedLines(sampleConfig())
        let after = keyedLines(try String(contentsOf: fixture.configURL))
        let changedKeys = before.keys.sorted().filter { before[$0] != after[$0] }
        XCTAssertEqual(changedKeys, [
            "kv_bits",
            "max_concurrency_override",
            "max_context_override",
            "model",
        ])
    }

    func testApplyOmitsKVBitsKeyWhenNil() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let unquantized = RecommendationCore(
            model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            targetContext: 4_000,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 4_000),
            tpsMedian: 2,
            ttftP95MS: 10,
            replicates: 3
        )

        _ = try fixture.applier().apply(recommendation: unquantized, now: fixture.now)

        let post = try String(contentsOf: fixture.configURL)
        XCTAssertFalse(post.contains("kv_bits:"))
    }

    func testApplyIsIdempotent() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())

        _ = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)
        let firstPost = try String(contentsOf: fixture.configURL)
        let firstBackup = fixture.configURL.deletingLastPathComponent()
            .appendingPathComponent("config.yaml.bak-1718712345-0")

        _ = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)
        let secondPost = try String(contentsOf: fixture.configURL)
        let secondBackup = fixture.configURL.deletingLastPathComponent()
            .appendingPathComponent("config.yaml.bak-1718712345-1")

        XCTAssertEqual(secondPost, firstPost)
        XCTAssertEqual(try String(contentsOf: secondBackup), secondPost)
        XCTAssertEqual(try String(contentsOf: firstBackup), sampleConfig())
    }

    func testApplyWriteIsAtomic() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        var tempPaths: [URL] = []
        let applier = ConfigApplier(
            configPath: fixture.configURL,
            tempFileNamer: { destination, unixTS in
                let temp = destination.deletingLastPathComponent()
                    .appendingPathComponent("\(destination.lastPathComponent).tmp.\(unixTS).spy")
                tempPaths.append(temp)
                return temp
            }
        )

        _ = try applier.apply(recommendation: recommendation(), now: fixture.now)

        XCTAssertEqual(tempPaths.count, 1, "only the config write uses temp+rename; backup is exclusive-create")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.configURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.configURL.deletingLastPathComponent()
            .appendingPathComponent("config.yaml.bak-1718712345-0").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPaths[0].path))
    }

    func testApplyBackupUsesExclusiveCreateAgainstTOCTOURace() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let directory = fixture.configURL.deletingLastPathComponent()

        for counter in 0...3 {
            try Data("collision-\(counter)".utf8).write(
                to: directory.appendingPathComponent("config.yaml.bak-1718712345-\(counter)")
            )
        }

        let applied = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)

        XCTAssertEqual(applied.backupPath.lastPathComponent, "config.yaml.bak-1718712345-4")
        for counter in 0...3 {
            let preExisting = directory.appendingPathComponent("config.yaml.bak-1718712345-\(counter)")
            XCTAssertEqual(try String(contentsOf: preExisting), "collision-\(counter)",
                           "pre-existing backup at counter \(counter) must not be overwritten")
        }
        XCTAssertEqual(try String(contentsOf: applied.backupPath), sampleConfig())
    }

    func testApplyPreservesNonOwnedLinesByteIdentically() throws {
        let fixture = try ConfigFixture()
        let configWithSentinels = """
        # leading comment
        coordinator_endpoint: https://coordinator.example

        # block comment about provider
        provider_token: keep-me  # inline keepalive

        log_path: /tmp/provider.log
        # trailing comment
        auto_update_enabled: true

        # SPEC-013 zone — owned keys below this line
        model: old-model
        kv_bits: 8
        max_context_override: 2000
        max_concurrency_override: 2

        """
        try fixture.writeConfig(configWithSentinels)

        _ = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)
        let post = try String(contentsOf: fixture.configURL)

        let preNonOwned = nonOwnedLines(configWithSentinels)
        let postNonOwned = nonOwnedLines(post)
        XCTAssertEqual(preNonOwned, postNonOwned,
                       "non-owned lines (incl. comments + blanks) must be byte-identical pre/post")
    }

    func testApplyResultIsParseableByConfigLoader() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())

        _ = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)

        let cli = CLIOverrides(configPath: fixture.configURL.path)
        let loaded = try ConfigLoader.load(cli: cli, environment: [:])

        XCTAssertEqual(loaded.model, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertEqual(loaded.kvBitsOverride, 4)
        XCTAssertEqual(loaded.maxContextOverride, 4_000)
        XCTAssertEqual(loaded.maxConcurrencyOverride, 1)
    }

    func testLaunchdRestartHintIncludesAllRequiredSubstrings() {
        let hint = RecommendationEmitter.launchdRestartHint()

        XCTAssertTrue(hint.contains("launchctl bootout"))
        XCTAssertTrue(hint.contains("launchctl bootstrap"))
        XCTAssertTrue(hint.contains("~/Library/LaunchAgents/live.streamvc.macprovider.plist"))
        XCTAssertTrue(hint.contains("gui/$UID/live.streamvc.macprovider"))
    }

    private func sampleConfig() -> String {
        """
        # operator config
        coordinator_endpoint: https://coordinator.example
        model: old-model
        kv_bits: 8
        max_context_override: 2000
        max_concurrency_override: 2
        # important token comment
        provider_token: keep-me
        log_path: /tmp/provider.log
        """
    }

    private func recommendation() -> RecommendationCore {
        RecommendationCore(
            model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            targetContext: 4_000,
            knobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 4_000),
            tpsMedian: 2,
            ttftP95MS: 10,
            replicates: 3
        )
    }

    private func keyedLines(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator])
            result[key] = String(line)
        }
        return result
    }

    private func nonOwnedLines(_ text: String) -> [String] {
        let ownedKeys: Set<String> = [
            "model", "kv_bits", "max_context_override", "max_concurrency_override",
        ]
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { sub in
            let line = String(sub)
            guard let first = line.first, !first.isWhitespace else {
                return line
            }
            let isOwned = ownedKeys.contains { key in
                line == "\(key):" || line.hasPrefix("\(key): ") || line.hasPrefix("\(key):#")
            }
            return isOwned ? nil : line
        }
    }
}

private struct ConfigFixture {
    let tempDir: URL
    let configURL: URL
    let now = Date(timeIntervalSince1970: 1_718_712_345)

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigApplierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configURL = tempDir.appendingPathComponent("config.yaml")
    }

    func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    func applier(maxBackupCounter: Int = 65_535) -> ConfigApplier {
        ConfigApplier(configPath: configURL, maxBackupCounter: maxBackupCounter)
    }
}
