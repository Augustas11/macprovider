import ArgumentParser
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelsAdmissionRetryTests: XCTestCase {
    func testRetryRequiresConfirmationAndJSONBeforeRuntimeWork() throws {
        XCTAssertThrowsError(try ModelsAdmissionRetryCommand.parse(["mlx-community/model"]))
        XCTAssertThrowsError(try ModelsAdmissionRetryCommand.parse(["mlx-community/model", "--json"]))
        XCTAssertThrowsError(try ModelsAdmissionRetryCommand.parse(["mlx-community/model", "--yes"]))
        let command = try ModelsAdmissionRetryCommand.parse(["mlx-community/model", "--yes", "--json"])
        XCTAssertEqual(command.candidate, "mlx-community/model")
        XCTAssertTrue(command.yes)
        XCTAssertTrue(command.emitJSON)
    }

    func testRetryRejectsEmptyTarget() {
        XCTAssertThrowsError(try ModelsAdmissionRetryCommand.parse([" ", "--yes", "--json"]))
    }

    func testRetryCommandUsesConfiguredCustodyForTokenAndSigningIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.credentialStore = .protectedFile
        let environment = BYOMDiscoveryEnvironment(
            namespaceURL: root.appendingPathComponent("discovery"),
            mlxCacheRoot: root.appendingPathComponent("cache"), ollamaOrigin: nil
        )
        let command = try ModelsAdmissionRetryCommand.parse(["mlx-community/model", "--yes", "--json"])
        let runtime = try command.makeRuntime(environment: environment, config: config,
                                              coordinatorURL: "https://127.0.0.1:8080")
        XCTAssertTrue(runtime.credentialStore is ProtectedFileProviderCredentialStore)
        XCTAssertTrue(runtime.identityStore is ProtectedFileReceiptKeyStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Constructing retry must not provision custody")

        config.credentialStore = .keychain
        let defaultRuntime = try command.makeRuntime(environment: environment, config: config,
                                                     coordinatorURL: "https://127.0.0.1:8080")
        XCTAssertTrue(defaultRuntime.credentialStore is KeychainProviderCredentialStore)
        XCTAssertTrue(defaultRuntime.identityStore is KeychainReceiptKeyStore)
    }

}
