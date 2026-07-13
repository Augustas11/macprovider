import XCTest
@testable import Malibu

@MainActor
final class CLIChildProcessTests: XCTestCase {
    func testManagedBearerUsesTokenFDWithoutPuttingSecretInArgumentsOrEnvironment() throws {
        let secret = "payout-bearing-secret"
        let launch = CLIChildProcess.Launch(
            executable: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            configPath: URL(fileURLWithPath: "/tmp/config.yaml"),
            controlSocketPath: URL(fileURLWithPath: "/tmp/control.sock"),
            httpPort: 18080,
            logFileURL: URL(fileURLWithPath: "/tmp/provider.log"),
            extraEnvironment: ["SAFE": "1"],
            providerToken: secret
        )

        let arguments = CLIChildProcess.buildArguments(launch: launch)
        XCTAssertTrue(arguments.contains("--token-fd"))
        XCTAssertTrue(arguments.contains("0"))
        XCTAssertFalse(arguments.contains(secret))
        XCTAssertNil(launch.extraEnvironment["MACPROVIDER_PROVIDER_TOKEN"])
    }
}
