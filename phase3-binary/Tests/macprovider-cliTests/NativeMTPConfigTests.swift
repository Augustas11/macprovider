import ArgumentParser
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class NativeMTPConfigTests: XCTestCase {
    func testNativeMTPDefaultsOff() throws {
        let config = try load()
        XCTAssertEqual(config.nativeMTPMode, .off)
    }

    func testNativeMTPCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try load(
            cli: CLIOverrides(nativeMTPMode: "off"),
            environment: ["MACPROVIDER_NATIVE_MTP_MODE": "auto"],
            yaml: "native_mtp_mode: auto\n"
        )
        XCTAssertEqual(config.nativeMTPMode, .off)
    }

    func testNativeMTPEnvironmentOverridesYAML() throws {
        let config = try load(
            environment: ["MACPROVIDER_NATIVE_MTP_MODE": "off"],
            yaml: "native_mtp_mode: auto\n"
        )
        XCTAssertEqual(config.nativeMTPMode, .off)
    }

    func testNativeMTPYAMLAuto() throws {
        XCTAssertEqual(try load(yaml: "native_mtp_mode: auto\n").nativeMTPMode, .auto)
    }

    func testNativeMTPRejectsInvalidAndEmptyValues() throws {
        XCTAssertThrowsError(try load(yaml: "native_mtp_mode: maybe\n"))
        XCTAssertThrowsError(try load(yaml: "native_mtp_mode:\n"))
        XCTAssertThrowsError(try load(environment: ["MACPROVIDER_NATIVE_MTP_MODE": ""]))
        XCTAssertThrowsError(try load(cli: CLIOverrides(nativeMTPMode: "maybe")))
        XCTAssertThrowsError(try load(cli: CLIOverrides(nativeMTPMode: "")))
    }

    func testServeCommandParsesNativeMTPOption() throws {
        let command = try ServeCommand.parse(["--native-mtp", "auto"])
        XCTAssertEqual(command.nativeMTP, "auto")
    }

    private func load(
        cli: CLIOverrides = CLIOverrides(),
        environment: [String: String] = [:],
        yaml: String? = nil
    ) throws -> AppConfig {
        try ConfigLoader.load(
            cli: cli,
            environment: environment,
            fileExists: { _ in yaml != nil },
            readFile: { _ in yaml ?? "" }
        )
    }
}
