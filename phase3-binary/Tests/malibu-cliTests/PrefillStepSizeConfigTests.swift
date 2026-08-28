import XCTest
@testable import MacProviderCore

// T3-02 adaptive prefill: config/env/CLI resolution for prefill_step_size.
final class PrefillStepSizeConfigTests: XCTestCase {
    func testDefaultPrefillStepSizeIs512() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in false },
            readFile: { _ in "" }
        )
        XCTAssertEqual(config.prefillStepSize, 512)
    }

    func testYAMLPrefillStepSize() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "prefill_step_size: 2048\n" }
        )
        XCTAssertEqual(config.prefillStepSize, 2048)
    }

    func testEnvPrefillStepSizeOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_PREFILL_STEP_SIZE": "4096"],
            fileExists: { _ in true },
            readFile: { _ in "prefill_step_size: 512\n" }
        )
        XCTAssertEqual(config.prefillStepSize, 4096)
    }

    func testCLIPrefillStepSizeOverridesEnvAndYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(prefillStepSize: 1024),
            environment: ["MACPROVIDER_PREFILL_STEP_SIZE": "4096"],
            fileExists: { _ in true },
            readFile: { _ in "prefill_step_size: 2048\n" }
        )
        XCTAssertEqual(config.prefillStepSize, 1024)
    }
}
