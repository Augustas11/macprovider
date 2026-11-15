import ArgumentParser
import Foundation
@testable import MacProviderCore
import XCTest
@testable import macprovider_cli

// SPEC-001-R017 *Configuration*: `warm_models` resolves YAML < env < CLI
// (SPEC-010 R-3.6.1), is trimmed and duplicate-free, never names the
// primary, and must be a subset of `supported_models` (or extends the
// effective list when that is unset). Empty changes nothing.
final class WarmModelsConfigTests: XCTestCase {
    private func load(
        cli: CLIOverrides = CLIOverrides(), environment: [String: String] = [:], yaml: String? = nil
    ) throws -> AppConfig {
        try ConfigLoader.load(
            cli: cli,
            environment: environment,
            fileExists: { _ in yaml != nil },
            readFile: { _ in yaml ?? "" }
        )
    }

    private func assertRejected(_ body: @autoclosure () throws -> AppConfig, value: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case let .invalidValue(key, rejected, _)? = error as? ConfigError else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
            XCTAssertEqual(key, "warm_models", file: file, line: line)
            XCTAssertEqual(rejected, value, file: file, line: line)
        }
    }

    // MARK: Resolution

    func testDefaultIsEmpty() throws {
        XCTAssertEqual(try load().warmModels, [])
        XCTAssertEqual(AppConfig.defaults().warmModels, [])
    }

    func testYAMLArrayAndCommaSeparatedString() throws {
        XCTAssertEqual(try load(yaml: "model: P\nwarm_models:\n  - A\n  - B\n").warmModels, ["A", "B"])
        XCTAssertEqual(try load(yaml: "model: P\nwarm_models: \"A, B\"\n").warmModels, ["A", "B"])
        XCTAssertThrowsError(try load(yaml: "warm_models: 3\n"))
    }

    func testEnvironmentOverridesYAML() throws {
        let config = try load(environment: ["MACPROVIDER_WARM_MODELS": "C,D"], yaml: "model: P\nwarm_models: [A]\n")
        XCTAssertEqual(config.warmModels, ["C", "D"])
    }

    func testEmptyEnvironmentKeepsYAML() throws {
        let config = try load(environment: ["MACPROVIDER_WARM_MODELS": " , "], yaml: "model: P\nwarm_models: [A]\n")
        XCTAssertEqual(config.warmModels, ["A"])
    }

    func testCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try load(
            cli: CLIOverrides(warmModels: ["E"]),
            environment: ["MACPROVIDER_WARM_MODELS": "C"],
            yaml: "model: P\nwarm_models: [A]\n")
        XCTAssertEqual(config.warmModels, ["E"])
    }

    func testServeOptionParsesCommaSeparatedList() throws {
        let command = try ServeCommand.parse(["--model", "P", "--warm-models", " A , B ,"])
        XCTAssertEqual(command.warmModels, " A , B ,")
        XCTAssertEqual(SupportedModels.parseCSV(command.warmModels), ["A", "B"])
        XCTAssertNil(try ServeCommand.parse(["--model", "P"]).warmModels)
    }

    // MARK: Validation

    func testEntriesAreTrimmedAndEmptyEntriesDropped() throws {
        let config = try load(yaml: "model: P\nwarm_models:\n  - \"  A \"\n  - \"\"\n  - B\n")
        XCTAssertEqual(config.warmModels, ["A", "B"])
    }

    func testCaseFoldedDuplicateIsRejected() {
        assertRejected(try load(yaml: "model: P\nwarm_models: [Org/Model-A, org/model-a]\n"), value: "org/model-a")
        assertRejected(try load(environment: ["MACPROVIDER_WARM_MODELS": "A, a"]), value: "a")
    }

    func testEntryEqualToPrimaryIsRejected() {
        assertRejected(try load(yaml: "model: Org/Primary\nwarm_models: [A, org/PRIMARY]\n"), value: "org/PRIMARY")
        // The primary set at a higher layer than the list still counts.
        assertRejected(try load(cli: CLIOverrides(model: "A"), yaml: "model: P\nwarm_models: [A]\n"), value: "A")
    }

    func testErrorNamesTheKey() {
        XCTAssertThrowsError(try load(yaml: "model: P\nwarm_models: [P]\n")) { error in
            XCTAssertTrue("\(error)".contains("warm_models"), "\(error)")
            XCTAssertTrue("\(error)".contains("primary"), "\(error)")
        }
    }

    // MARK: Supported-models preflight

    func testEmptyListLeavesSingleModelPreflightUnchanged() throws {
        var config = AppConfig.defaults()
        config.model = "P"
        try ServeCommand.runSupportedModelsPreflight(&config)
        XCTAssertNil(config.supportedModels)
    }

    func testUnsetSupportedModelsIsPrimaryFollowedByWarmModels() throws {
        var config = AppConfig.defaults()
        config.model = "P"
        config.warmModels = ["A", "B"]
        try ServeCommand.runSupportedModelsPreflight(&config)
        XCTAssertEqual(config.supportedModels, ["P", "A", "B"])
        // The preflight runs twice at startup; the second pass is a no-op.
        try ServeCommand.runSupportedModelsPreflight(&config)
        XCTAssertEqual(config.supportedModels, ["P", "A", "B"])
    }

    func testWarmModelsMustBeSupported() throws {
        var config = AppConfig.defaults()
        config.model = "P"
        config.supportedModels = ["p", "a", "B"]
        config.warmModels = ["A", "b"]
        try ServeCommand.runSupportedModelsPreflight(&config)
        XCTAssertEqual(config.supportedModels, ["p", "a", "B"])

        config.warmModels = ["A", "C"]
        XCTAssertThrowsError(try ServeCommand.runSupportedModelsPreflight(&config)) { error in
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
        XCTAssertThrowsError(try SupportedModels.validate(model: "P", supportedModels: ["P", "A"], warmModels: ["A", "C"])) { error in
            XCTAssertEqual(error as? SupportedModelsValidationError, .warmModelNotInCatalog(model: "C", catalog: ["P", "A"]))
            XCTAssertEqual("\(error)", "--warm-models C not in --supported-models")
        }
    }

    func testWarmModelsRequireAPrimaryModel() {
        var config = AppConfig.defaults()
        config.model = nil
        config.warmModels = ["A"]
        XCTAssertThrowsError(try ServeCommand.runSupportedModelsPreflight(&config)) { error in
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
        XCTAssertThrowsError(try SupportedModels.validate(model: "", supportedModels: nil, warmModels: ["A"])) { error in
            XCTAssertEqual(error as? SupportedModelsValidationError, .warmModelsRequireModel)
        }
    }

    func testDerivedListIsBoundedLikeSupportedModels() {
        let warm = (1..<SupportedModels.maxCatalogEntries + 1).map { "model-\($0)" }
        XCTAssertThrowsError(try SupportedModels.validate(model: "P", supportedModels: nil, warmModels: warm)) { error in
            XCTAssertEqual(error as? SupportedModelsValidationError, .catalogTooLarge(count: SupportedModels.maxCatalogEntries + 1))
        }
    }
}
