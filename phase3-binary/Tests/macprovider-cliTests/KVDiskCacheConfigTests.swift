import Foundation
import MacProviderCore
import XCTest

/// SPEC-037 FR-KVP11 / AC-9 — fail-closed config resolution for the KV disk
/// tier: default-on (v0.2.2) with operator opt-out, triple-source precedence (YAML → env → CLI), each
/// invalid-value rule disables the tier (never aborts), buyer policy, and tilde expansion.
final class KVDiskCacheConfigTests: XCTestCase {

    private func resolve(
        yaml: [String: Any]? = nil,
        env: [String: String] = [:],
        cli: KVDiskCacheCLIOverrides = KVDiskCacheCLIOverrides(),
        home: String = "/Users/tester"
    ) -> KVDiskCacheConfig {
        KVDiskCacheConfigResolver.resolve(yaml: yaml, environment: env, cli: cli, homeDirectory: home)
    }

    // MARK: - Default on (SPEC-037 v0.2.2)

    func testDefaultOn() {
        let c = resolve()
        XCTAssertTrue(c.enabled)
        XCTAssertTrue(c.effectiveEnabled)
        XCTAssertTrue(c.errors.isEmpty)
        XCTAssertEqual(c.directory, "/Users/tester/Library/Caches/macprovider/kv-cache")
        XCTAssertEqual(c.maxBytes, 16 * 1024 * 1024 * 1024)
        XCTAssertEqual(c.maxEntries, 64)
        XCTAssertEqual(c.minFreeBytes, 8 * 1024 * 1024 * 1024)
    }

    // MARK: - Enable via each source

    func testEnableViaCLI() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true))
        XCTAssertTrue(c.effectiveEnabled)
    }

    func testEnableViaEnv() {
        let c = resolve(env: ["MACPROVIDER_KV_DISK_CACHE_ENABLED": "true"])
        XCTAssertTrue(c.effectiveEnabled)
    }

    func testEnableViaYAML() {
        let c = resolve(yaml: ["enabled": true])
        XCTAssertTrue(c.effectiveEnabled)
    }

    func testOperatorOptOutViaEachSource() {
        XCTAssertFalse(resolve(yaml: ["enabled": false]).effectiveEnabled)
        XCTAssertFalse(resolve(env: ["MACPROVIDER_KV_DISK_CACHE_ENABLED": "false"]).effectiveEnabled)
        XCTAssertFalse(resolve(cli: KVDiskCacheCLIOverrides(enabled: false)).effectiveEnabled)
    }

    // MARK: - Precedence (YAML < env < CLI)

    func testEnvOverridesYAML() {
        let c = resolve(yaml: ["enabled": false], env: ["MACPROVIDER_KV_DISK_CACHE_ENABLED": "true"])
        XCTAssertTrue(c.enabled)
    }

    func testCLIOverridesEnv() {
        let c = resolve(env: ["MACPROVIDER_KV_DISK_CACHE_ENABLED": "true"],
                        cli: KVDiskCacheCLIOverrides(enabled: false))
        XCTAssertFalse(c.enabled)
    }

    func testMaxBytesPrecedenceCLIWins() {
        let c = resolve(yaml: ["max_bytes": 1_000], env: ["MACPROVIDER_KV_DISK_CACHE_MAX_BYTES": "2000"],
                        cli: KVDiskCacheCLIOverrides(enabled: true, maxBytes: 3_000))
        XCTAssertEqual(c.maxBytes, 3_000)
        XCTAssertTrue(c.effectiveEnabled)
    }

    // MARK: - Buyer policy is independent of authenticated eligibility

    func testAllowBuyerKeysAcceptedCLI() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, allowBuyerKeys: true))
        XCTAssertTrue(c.effectiveEnabled)
        XCTAssertTrue(c.allowBuyerKeys)
        XCTAssertTrue(c.errors.isEmpty)
    }

    func testAllowBuyerKeysAcceptedYAML() {
        let c = resolve(yaml: ["enabled": true, "allow_buyer_keys": true])
        XCTAssertTrue(c.effectiveEnabled)
        XCTAssertTrue(c.allowBuyerKeys)
    }

    func testAllowBuyerKeysFalseIsFine() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, allowBuyerKeys: false))
        XCTAssertTrue(c.effectiveEnabled)
    }

    // MARK: - Invalid-value rules (each ⇒ tier disabled, error logged)

    func testInvalidMaxBytesZero() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, maxBytes: 0))
        XCTAssertFalse(c.effectiveEnabled)
        XCTAssertTrue(c.errors.contains { $0.contains("max_bytes") })
    }

    func testInvalidMaxBytesNonInteger() {
        let c = resolve(yaml: ["enabled": true, "max_bytes": "not-a-number"])
        XCTAssertFalse(c.effectiveEnabled)
        XCTAssertTrue(c.errors.contains { $0.contains("max_bytes") })
    }

    func testInvalidEnabledValue() {
        let c = resolve(env: ["MACPROVIDER_KV_DISK_CACHE_ENABLED": "maybe"])
        XCTAssertFalse(c.effectiveEnabled)
        XCTAssertTrue(c.errors.contains { $0.contains("enabled") })
    }

    func testStagingCeilingHardMax() {
        let over = 1024 * 1024 * 1024 + 1
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, stagingMaxBytes: over))
        XCTAssertFalse(c.effectiveEnabled)
        XCTAssertTrue(c.errors.contains { $0.contains("staging_max_bytes") })
    }

    func testStagingCeilingAcceptsOneGib() {
        let max = 1024 * 1024 * 1024
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, stagingMaxBytes: max))
        XCTAssertTrue(c.effectiveEnabled)
        XCTAssertEqual(c.stagingMaxBytes, max)
        XCTAssertTrue(c.errors.isEmpty)
    }

    func testStagingCeilingAcceptsFormer256Bound() {
        let formerOver = 256 * 1024 * 1024 + 1
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, stagingMaxBytes: formerOver))
        XCTAssertTrue(c.effectiveEnabled)
        XCTAssertEqual(c.stagingMaxBytes, formerOver)
        XCTAssertTrue(c.errors.isEmpty)
    }

    /// A non-finite or out-of-range YAML number disables the tier instead of trapping.
    func testNonFiniteYAMLNumberFailsClosed() {
        for bad in [Double.infinity, -Double.infinity, Double.nan, 1e300, 1.5] {
            let c = resolve(yaml: ["enabled": true, "max_bytes": bad])
            XCTAssertFalse(c.effectiveEnabled, "\(bad)")
            XCTAssertTrue(c.errors.contains { $0.contains("max_bytes") }, "\(bad)")
        }
        XCTAssertEqual(resolve(yaml: ["max_bytes": 2048.0]).maxBytes, 2048)
    }

    /// #2015: hosts that can serve hybrid 35B models default both staging ceilings
    /// to the 1 GiB hard max; smaller hosts keep 256 MiB; explicit values win.
    func testStagingDefaultsScaleWithHostMemory() {
        let gib: UInt64 = 1024 * 1024 * 1024
        let large = KVDiskCacheConfigResolver.resolve(
            yaml: nil, environment: [:], homeDirectory: "/Users/tester", physicalMemoryBytes: 64 * gib)
        XCTAssertEqual(large.stagingMaxBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(large.writeStagingMaxBytes, 1024 * 1024 * 1024)
        XCTAssertTrue(large.errors.isEmpty)

        let small = KVDiskCacheConfigResolver.resolve(
            yaml: nil, environment: [:], homeDirectory: "/Users/tester", physicalMemoryBytes: 64 * gib - 1)
        XCTAssertEqual(small.stagingMaxBytes, 256 * 1024 * 1024)
        XCTAssertEqual(small.writeStagingMaxBytes, 256 * 1024 * 1024)

        let explicit = KVDiskCacheConfigResolver.resolve(
            yaml: ["staging_max_bytes": 300_000_000],
            environment: ["MACPROVIDER_KV_DISK_CACHE_WRITE_STAGING_MAX_BYTES": "200000000"],
            homeDirectory: "/Users/tester", physicalMemoryBytes: 512 * gib)
        XCTAssertEqual(explicit.stagingMaxBytes, 300_000_000)
        XCTAssertEqual(explicit.writeStagingMaxBytes, 200_000_000)
    }

    func testWriteStagingCeilingHardMax() {
        let over = 1024 * 1024 * 1024 + 1
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, writeStagingMaxBytes: over))
        XCTAssertFalse(c.effectiveEnabled)
        XCTAssertTrue(c.errors.contains { $0.contains("write_staging_max_bytes") })
    }

    func testMinFreeBelowFloor() {
        let below = 1024 * 1024 * 1024 - 1
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, minFreeBytes: below))
        XCTAssertFalse(c.effectiveEnabled)
        XCTAssertTrue(c.errors.contains { $0.contains("min_free_bytes") })
    }

    func testShutdownDrainZeroIsValid() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, shutdownDrainSeconds: 0))
        XCTAssertTrue(c.effectiveEnabled)
        XCTAssertEqual(c.shutdownDrainSeconds, 0)
    }

    func testShutdownDrainNegativeInvalid() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, shutdownDrainSeconds: -1))
        XCTAssertFalse(c.effectiveEnabled)
    }

    func testPromotionMaxSecondsMustBePositive() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, promotionMaxSeconds: 0))
        XCTAssertFalse(c.effectiveEnabled)
    }

    // MARK: - Directory rules

    func testTildeExpansion() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, directory: "~/kv"))
        XCTAssertEqual(c.directory, "/Users/tester/kv")
        XCTAssertTrue(c.effectiveEnabled)
    }

    func testRelativeDirectoryRejected() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, directory: "kv-cache"))
        XCTAssertFalse(c.effectiveEnabled)
        XCTAssertTrue(c.errors.contains { $0.contains("directory") })
    }

    func testAbsoluteDirectoryAccepted() {
        let c = resolve(cli: KVDiskCacheCLIOverrides(enabled: true, directory: "/var/kv"))
        XCTAssertEqual(c.directory, "/var/kv")
        XCTAssertTrue(c.effectiveEnabled)
    }

    // MARK: - ConfigLoader end-to-end (YAML nested block + env override)

    func testConfigLoaderYAMLNestedBlock() throws {
        let yaml = """
        port: 8080
        kv_disk_cache:
          enabled: true
          max_entries: 32
          promotion_max_seconds: 9
        """
        let cfg = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in yaml })
        XCTAssertTrue(cfg.kvDiskCache.enabled)
        XCTAssertEqual(cfg.kvDiskCache.maxEntries, 32)
        XCTAssertEqual(cfg.kvDiskCache.promotionMaxSeconds, 9)
        XCTAssertTrue(cfg.kvDiskCache.effectiveEnabled)
    }

    func testConfigLoaderEnvOverridesYAML() throws {
        let yaml = """
        kv_disk_cache:
          enabled: false
        """
        let cfg = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_KV_DISK_CACHE_ENABLED": "true"],
            fileExists: { _ in true },
            readFile: { _ in yaml })
        XCTAssertTrue(cfg.kvDiskCache.enabled)
    }

    func testConfigLoaderNoFileDefaultsOn() throws {
        let cfg = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in false },
            readFile: { _ in "" })
        XCTAssertTrue(cfg.kvDiskCache.enabled)
        XCTAssertTrue(cfg.kvDiskCache.errors.isEmpty)
    }
}
