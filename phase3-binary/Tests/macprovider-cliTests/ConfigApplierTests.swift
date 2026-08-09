import Darwin
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
        XCTAssertEqual(
            try String(contentsOf: applied.backupPath),
            ProviderTokenPersist.removingProviderTokenLines(in: sampleConfig())
        )
        XCTAssertFalse(try String(contentsOf: applied.backupPath).contains("provider_token:"))
        XCTAssertTrue(applied.summary.contains("backup at \(applied.backupPath.path)"))
        XCTAssertEqual(try fileMode(applied.backupPath) & 0o777, 0o600)
        XCTAssertEqual(try fileMode(fixture.configURL) & 0o777, 0o600)
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

    func testApplyFailsClosedWhenExistingConfigCannotBeRead() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let applier = ConfigApplier(
            configPath: fixture.configURL,
            readData: { _ in throw CocoaError(.fileReadNoPermission) }
        )

        XCTAssertThrowsError(try applier.apply(recommendation: recommendation(), now: fixture.now)) { error in
            XCTAssertEqual(error as? ConfigApplierError, .configReadFailed(applier.configPath.path))
        }
        XCTAssertEqual(try String(contentsOf: fixture.configURL), sampleConfig())
    }

    func testApplyRejectsHardLinkedConfigAlias() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let alias = fixture.tempDir.appendingPathComponent("config-alias.yaml")
        try FileManager.default.linkItem(at: fixture.configURL, to: alias)
        let applier = ConfigApplier(configPath: alias)

        XCTAssertThrowsError(try applier.apply(recommendation: recommendation(), now: fixture.now)) { error in
            XCTAssertEqual(error as? ConfigApplierError, .unsafeConfigPath(applier.configPath.path))
        }
        XCTAssertEqual(try String(contentsOf: fixture.configURL), sampleConfig())
    }

    func testApplyCanonicalizesSymlinkAliasBeforeLockingAndMutation() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let alias = fixture.tempDir.appendingPathComponent("config-link.yaml")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.configURL)
        let applier = ConfigApplier(configPath: alias)

        _ = try applier.apply(recommendation: recommendation(), now: fixture.now)

        XCTAssertEqual(applier.configPath, fixture.configURL.resolvingSymlinksInPath())
        XCTAssertTrue(try String(contentsOf: fixture.configURL).contains("model: mlx-community/Qwen2.5-Coder-7B-Instruct-4bit\n"))
    }

    func testApplyQuotesCatalogStringsInsteadOfInjectingYAMLKeys() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        var unsafe = recommendation()
        unsafe.modelCatalogRevision = "revision\ninjected_key: value"

        _ = try fixture.applier().apply(recommendation: unsafe, now: fixture.now)

        let post = try String(contentsOf: fixture.configURL)
        XCTAssertFalse(post.contains("\ninjected_key: value\n"))
        XCTAssertEqual(
            try ConfigLoader.load(cli: CLIOverrides(configPath: fixture.configURL.path)).modelCatalogRevision,
            "revision\ninjected_key: value"
        )
    }

    func testRestoreRecommendationOwnedFieldsPreservesNonOwnedKeys() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let before = try String(contentsOf: fixture.configURL)
        let applied = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now)

        try fixture.applier().restoreRecommendationOwnedFields(from: applied.backupPath, now: fixture.now)

        XCTAssertEqual(try String(contentsOf: fixture.configURL), before)
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

    func testApplyWritesArtifactHashAndConfigLoaderReadsIt() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let artifactSHA = String(repeating: "a", count: 64)
        var recommendation = recommendation()
        recommendation.model = "test-public-model"
        recommendation.modelArtifactPath = "/tmp/macprovider-test-snapshot"
        recommendation.modelArtifactSHA256 = artifactSHA

        _ = try fixture.applier().apply(recommendation: recommendation, now: fixture.now)

        let post = try String(contentsOf: fixture.configURL)
        XCTAssertTrue(post.contains("model: test-public-model\n"))
        XCTAssertTrue(post.contains("model_artifact_path: /tmp/macprovider-test-snapshot\n"))
        XCTAssertTrue(post.contains("model_artifact_sha256: \(artifactSHA)\n"))
        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(configPath: fixture.configURL.path),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in post }
        )
        XCTAssertEqual(loaded.model, "test-public-model")
        XCTAssertEqual(loaded.modelArtifactPath, "/tmp/macprovider-test-snapshot")
        XCTAssertEqual(loaded.modelArtifactSHA256, artifactSHA)
    }

    func testApplyWritesDonorCatalogBindingAndConfigLoaderReadsIt() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let artifactSHA = String(repeating: "b", count: 64)
        let catalogHash = String(repeating: "c", count: 64)
        var recommendation = recommendation()
        recommendation.model = "test-model"
        recommendation.modelArtifactPath = "/tmp/macprovider-test-snapshot"
        recommendation.modelArtifactSHA256 = artifactSHA
        recommendation.modelCatalogKey = "test-model"
        recommendation.modelCatalogModelID = "test/model"
        recommendation.modelCatalogRevision = String(repeating: "1", count: 40)
        recommendation.modelCatalogSHA256 = artifactSHA
        recommendation.modelCatalogVersion = "test-catalog"
        recommendation.modelCatalogHash = catalogHash

        _ = try fixture.applier().apply(recommendation: recommendation, now: fixture.now, donorMode: true)

        let post = try String(contentsOf: fixture.configURL)
        XCTAssertTrue(post.contains("model_catalog_key: test-model\n"))
        XCTAssertTrue(post.contains("model_catalog_model_id: test/model\n"))
        XCTAssertTrue(post.contains("model_catalog_revision: \(String(repeating: "1", count: 40))\n"))
        XCTAssertTrue(post.contains("model_catalog_sha256: \(artifactSHA)\n"))
        XCTAssertTrue(post.contains("model_catalog_version: test-catalog\n"))
        XCTAssertTrue(post.contains("model_catalog_hash: \(catalogHash)\n"))
        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(configPath: fixture.configURL.path),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in post }
        )
        XCTAssertTrue(loaded.donorMode)
        XCTAssertEqual(loaded.modelCatalogKey, "test-model")
        XCTAssertEqual(loaded.modelCatalogModelID, "test/model")
        XCTAssertEqual(loaded.modelCatalogRevision, String(repeating: "1", count: 40))
        XCTAssertEqual(loaded.modelCatalogSHA256, artifactSHA)
        XCTAssertEqual(loaded.modelCatalogVersion, "test-catalog")
        XCTAssertEqual(loaded.modelCatalogHash, catalogHash)
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
        XCTAssertEqual(
            try String(contentsOf: secondBackup),
            ProviderTokenPersist.removingProviderTokenLines(in: secondPost)
        )
        XCTAssertEqual(
            try String(contentsOf: firstBackup),
            ProviderTokenPersist.removingProviderTokenLines(in: sampleConfig())
        )
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

    func testApplyWaitsForSharedProviderConfigMutationLock() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let lockURL = fixture.configURL.deletingLastPathComponent()
            .appendingPathComponent(".config.yaml.lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        guard lockFD >= 0 else { return }
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let recommendation = recommendation()
        DispatchQueue.global().async {
            started.signal()
            _ = try? fixture.applier().apply(recommendation: recommendation, now: fixture.now)
            finished.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            finished.wait(timeout: .now() + 0.15),
            .timedOut,
            "ConfigApplier must not read or rename while credential cleanup owns the shared lock"
        )
        XCTAssertEqual(flock(lockFD, LOCK_UN), 0)
        _ = close(lockFD)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    func testRecommendationRecoveryLockFailsWithinBoundedTimeout() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())
        let lockURL = fixture.configURL.deletingLastPathComponent()
            .appendingPathComponent(".config.yaml.lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        guard lockFD >= 0 else { return }
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)
        defer {
            _ = flock(lockFD, LOCK_UN)
            _ = close(lockFD)
        }

        let startedAt = Date()
        XCTAssertThrowsError(
            try fixture.applier().acquireRecommendationMutationLock(timeoutSeconds: 0.05)
        )
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
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
        XCTAssertEqual(
            try String(contentsOf: applied.backupPath),
            ProviderTokenPersist.removingProviderTokenLines(in: sampleConfig())
        )
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

    func testApplyDonorModeWritesConfigAndSummary() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig(sampleConfig())

        let applied = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now, donorMode: true)

        let post = try String(contentsOf: fixture.configURL)
        XCTAssertTrue(post.contains("donor_mode: true\n"))
        XCTAssertTrue(applied.summary.contains("donor_mode=true"))
        let loaded = try ConfigLoader.load(cli: CLIOverrides(configPath: fixture.configURL.path), environment: [:])
        XCTAssertTrue(loaded.donorMode)
    }

    func testApplyDonorModeRendersForNewConfig() throws {
        let fixture = try ConfigFixture()

        _ = try fixture.applier().apply(recommendation: recommendation(), now: fixture.now, donorMode: true)

        let post = try String(contentsOf: fixture.configURL)
        XCTAssertTrue(post.contains("donor_mode: true\n"))
    }

    func testConfigLoaderReadsDonorModeFromEnvironment() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_DONOR_MODE": "true"],
            fileExists: { _ in false }
        )

        XCTAssertTrue(config.donorMode)
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
            "model", "model_artifact_sha256", "model_catalog_key", "model_catalog_model_id",
            "model_artifact_path", "model_catalog_revision", "model_catalog_sha256",
            "model_catalog_version", "model_catalog_hash", "kv_bits", "max_context_override",
            "max_concurrency_override",
            "donor_mode",
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

    // MARK: - #745 model vs model_artifact_path

    /// AC-1/AC-5: serve --model <A> with config naming B must not keep B's artifact.
    func testCLIModelPathClearsMismatchedConfigArtifactBinding() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig("""
        model: openai/gpt-oss-20b
        model_artifact_path: /tmp/incumbent-gpt-oss-weights
        model_artifact_sha256: \(String(repeating: "a", count: 64))
        port: 8080
        """)

        let candidatePath = "/tmp/candidate-llama-3.2-3b-weights"
        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(model: candidatePath, configPath: fixture.configURL.path),
            environment: [:]
        )

        XCTAssertEqual(loaded.model, candidatePath)
        XCTAssertNil(loaded.modelArtifactPath, "mismatched config artifact must not silently win over --model")
        XCTAssertNil(loaded.modelArtifactSHA256, "incumbent SHA must not bind to a different --model")
        XCTAssertNil(loaded.modelCatalogModelID, "stale catalog alias must not survive --model mismatch")
        // ModelRuntime load path is modelLoadPath ?? modelID → candidate path.
        XCTAssertEqual(loaded.modelArtifactPath ?? loaded.model, candidatePath)
    }

    /// Preserve working case: no artifact path → --model is the load identity.
    func testCLIModelWithoutConfigArtifactLeavesPathNilForFallback() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig("""
        model: some-old-id
        port: 8080
        """)

        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(model: "/tmp/fresh-candidate", configPath: fixture.configURL.path),
            environment: [:]
        )

        XCTAssertEqual(loaded.model, "/tmp/fresh-candidate")
        XCTAssertNil(loaded.modelArtifactPath)
        XCTAssertEqual(loaded.modelArtifactPath ?? loaded.model, "/tmp/fresh-candidate")
    }

    /// Same path via --model keeps the configured SHA binding.
    func testCLIModelMatchingArtifactPathKeepsSHA() throws {
        let fixture = try ConfigFixture()
        let path = "/tmp/same-weights"
        let sha = String(repeating: "b", count: 64)
        try fixture.writeConfig("""
        model: openai/gpt-oss-20b
        model_artifact_path: \(path)
        model_artifact_sha256: \(sha)
        port: 8080
        """)

        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(model: path, configPath: fixture.configURL.path),
            environment: [:]
        )

        XCTAssertEqual(loaded.model, path)
        XCTAssertEqual(loaded.modelArtifactPath, path)
        XCTAssertEqual(loaded.modelArtifactSHA256, sha)
    }

    /// Changing model identity string while an artifact is bound clears the artifact.
    func testCLIModelIDDifferentFromConfigClearsArtifact() throws {
        let fixture = try ConfigFixture()
        try fixture.writeConfig("""
        model: openai/gpt-oss-20b
        model_artifact_path: /tmp/gpt-oss-weights
        model_artifact_sha256: \(String(repeating: "c", count: 64))
        port: 8080
        """)

        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(model: "meta-llama/llama-3.2-3b-instruct", configPath: fixture.configURL.path),
            environment: [:]
        )

        XCTAssertEqual(loaded.model, "meta-llama/llama-3.2-3b-instruct")
        XCTAssertNil(loaded.modelArtifactPath)
        XCTAssertNil(loaded.modelArtifactSHA256)
    }

    func testStandardizedPathIfFilesystemDetectsAbsoluteAndHomePaths() {
        XCTAssertEqual(
            ConfigLoader.standardizedPathIfFilesystem("/tmp/model"),
            URL(fileURLWithPath: "/tmp/model").standardizedFileURL.path
        )
        XCTAssertNil(ConfigLoader.standardizedPathIfFilesystem("mlx-community/Llama-3.2-3B-Instruct-4bit"))
        XCTAssertNil(ConfigLoader.standardizedPathIfFilesystem("openai/gpt-oss-20b"))
    }

    private func fileMode(_ url: URL) throws -> mode_t {
        var st = stat()
        XCTAssertEqual(lstat(url.path, &st), 0)
        return st.st_mode
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
