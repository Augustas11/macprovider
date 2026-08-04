import ArgumentParser
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class SupportedModelsTests: XCTestCase {
    func testParseCSVNilInput() {
        XCTAssertNil(SupportedModels.parseCSV(nil))
        XCTAssertNil(SupportedModels.parseCSV(""))
        XCTAssertNil(SupportedModels.parseCSV("   \n\t  "))
    }

    func testParseCSVTrimsAndDropsEmpty() {
        XCTAssertEqual(SupportedModels.parseCSV(" A , ,B,  "), ["A", "B"])
    }

    func testValidateDefaultsToSingleEntry() throws {
        XCTAssertEqual(try SupportedModels.validate(model: "A", supportedModels: nil), ["A"])
    }

    func testValidateDefaultSingleEntryPreservesCase() throws {
        XCTAssertEqual(try SupportedModels.validate(model: "MlX/Foo", supportedModels: nil), ["MlX/Foo"])
    }

    func testValidateRejectsMissingModel() {
        XCTAssertThrowsError(try SupportedModels.validate(model: "", supportedModels: nil)) { error in
            XCTAssertEqual(error as? SupportedModelsValidationError, .modelMissing)
        }
    }

    func testValidateAcceptsCaseFoldedMatch() throws {
        XCTAssertEqual(
            try SupportedModels.validate(model: "MLX/FOO", supportedModels: ["mlx/foo", "B"]),
            ["mlx/foo", "B"]
        )
    }

    func testValidateRejectsModelNotInCatalog() {
        XCTAssertThrowsError(try SupportedModels.validate(model: "C", supportedModels: ["A", "B"])) { error in
            XCTAssertEqual(
                error as? SupportedModelsValidationError,
                .modelNotInCatalog(model: "C", catalog: ["A", "B"])
            )
            XCTAssertTrue("\(error)".contains("--model C not in --supported-models"))
        }
    }

    func testValidateRejectsTooLongEntry() {
        let entry = String(repeating: "a", count: 257)
        XCTAssertThrowsError(try SupportedModels.validate(model: "A", supportedModels: ["A", entry])) { error in
            XCTAssertEqual(
                error as? SupportedModelsValidationError,
                .entryTooLong(entry: entry, byteCount: 257)
            )
            XCTAssertTrue("\(error)".contains("--supported-models entry exceeds 256 UTF-8 bytes"))
        }
    }

    func testValidateRejectsTooManyEntries() {
        let catalog = (0..<65).map { "model-\($0)" }
        XCTAssertThrowsError(try SupportedModels.validate(model: "model-0", supportedModels: catalog)) { error in
            XCTAssertEqual(error as? SupportedModelsValidationError, .catalogTooLarge(count: 65))
            XCTAssertTrue("\(error)".contains("exceeds 64 entries"))
        }
    }

    func testValidateCountsUTF8BytesNotCharacters() {
        let entry = String(repeating: "😀", count: 65)
        XCTAssertThrowsError(try SupportedModels.validate(model: "A", supportedModels: ["A", entry])) { error in
            XCTAssertEqual(
                error as? SupportedModelsValidationError,
                .entryTooLong(entry: entry, byteCount: 260)
            )
        }
    }

    func testServeCommandSkipsPreflightWhenSupportedModelsUnset() throws {
        // SPEC-001 v1.3 AC-N.0: bare `serve` must not trip the SPEC-010
        // operator-provided catalog pre-flight when supported_models is unset.
        var config = AppConfig.defaults()
        config.model = nil
        config.supportedModels = nil

        try ServeCommand.runSupportedModelsPreflight(&config)

        XCTAssertNil(config.model)
        XCTAssertNil(config.supportedModels)
    }

    func testServeCommandPreflightExits2WhenSupportedModelsSetWithoutModel() {
        var config = AppConfig.defaults()
        config.model = nil
        config.supportedModels = ["A"]

        XCTAssertThrowsError(try ServeCommand.runSupportedModelsPreflight(&config)) { error in
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
    }

    func testServeCommandPreflightSkipsWhenOnlyModelSet() throws {
        var config = AppConfig.defaults()
        config.model = "A"
        config.supportedModels = nil

        try ServeCommand.runSupportedModelsPreflight(&config)

        XCTAssertEqual(config.model, "A")
        XCTAssertNil(config.supportedModels)
    }

    func testServeCommandExits2WhenModelNotInSupportedModels() async throws {
        let command = try ServeCommand.parse([
            "--model", "C",
            "--supported-models", "A,B",
        ])

        var config = AppConfig.defaults()
        config.model = command.model
        config.supportedModels = SupportedModels.parseCSV(command.supportedModels)
        XCTAssertThrowsError(try ServeCommand.runSupportedModelsPreflight(&config)) { error in
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
    }

    func testServeCommandExits2WhenDrainTimeoutBelowMinimum() {
        assertDrainTimeoutRejected(4)
    }

    func testServeCommandExits2WhenDrainTimeoutAboveMaximum() {
        assertDrainTimeoutRejected(601)
    }

    func testServeCommandExits2WhenDrainTimeoutIsNegative() {
        assertDrainTimeoutRejected(-1)
    }

    func testServeCommandAllowsDrainTimeoutMinimumBoundary() throws {
        try assertDrainTimeoutAccepted(5)
    }

    func testServeCommandAllowsDrainTimeoutDefault() throws {
        try assertDrainTimeoutAccepted(30)
    }

    func testServeCommandAllowsDrainTimeoutMaximumBoundary() throws {
        try assertDrainTimeoutAccepted(600)
    }

    private func assertDrainTimeoutRejected(_ value: Int) {
        var config = AppConfig.defaults()
        config.swapDrainTimeoutSeconds = value

        XCTAssertThrowsError(try ServeCommand.runDrainTimeoutPreflight(config)) { error in
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
    }

    private func assertDrainTimeoutAccepted(_ value: Int) throws {
        var config = AppConfig.defaults()
        config.swapDrainTimeoutSeconds = value

        try ServeCommand.runDrainTimeoutPreflight(config)
    }
}
