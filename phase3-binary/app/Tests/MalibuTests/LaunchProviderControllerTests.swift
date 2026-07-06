import XCTest
@testable import Malibu

@MainActor
final class LaunchProviderControllerTests: XCTestCase {

    func testLaunchViaCLIInstallWhenNotAlreadyRunning() async {
        let harness = Harness()
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testLaunchSkipsInstallerWhenLocalProviderAlreadyHealthy() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.cliImportRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testLaunchInstallFailureIsRetryable() async {
        let harness = Harness()
        harness.cliInstallError = NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "install failed"])
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "cliInstall")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, "install failed")
        } else {
            XCTFail("expected failed cliInstall stage")
        }
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
    }

    func testLaunchMonitorFailureIsRetryable() async {
        let harness = Harness()
        harness.monitorHealthy = false
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        if case let .failed(stage, retryable, _) = controller.stage {
            XCTAssertEqual(stage, "cliInstall")
            XCTAssertTrue(retryable)
        } else {
            XCTFail("expected failed cliInstall stage after monitor timeout")
        }
        XCTAssertEqual(harness.loginItemRegistrations, 1)
    }

    func testRetryRerunsInstallAfterFailure() async {
        let harness = Harness()
        harness.cliInstallError = NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "install failed"])
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()
        harness.cliInstallError = nil
        await controller.retry()

        XCTAssertEqual(harness.cliInstallRuns, 2)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testRefreshFromExistingInstallConnectsWithoutInstaller() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.refreshFromExistingInstall()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testImportFailureToleratedWhenProviderAlreadyHealthy() async {
        let harness = Harness()
        harness.cliImportError = NSError(domain: "tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "import failed"])
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    private final class Harness {
        var localInstallSucceeded = false
        var localInstallSucceededAfterInstall = false
        var cliInstallRuns = 0
        var cliImportRuns = 0
        var monitorRuns = 0
        var loginItemRegistrations = 0
        var monitorHealthy = true
        var cliInstallError: Error?
        var cliImportError: Error?
        var configModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
        var installLogLines: [String] = []

        func dependencies() -> LaunchProviderController.Dependencies {
            LaunchProviderController.Dependencies(
                localInstallSucceeded: {
                    self.localInstallSucceeded || self.localInstallSucceededAfterInstall
                },
                registerLoginItem: {
                    self.loginItemRegistrations += 1
                },
                runCLIInstall: { onLogLine in
                    self.cliInstallRuns += 1
                    if let error = self.cliInstallError { throw error }
                    self.localInstallSucceededAfterInstall = true
                    onLogLine("install.sh finished")
                },
                importCLIConfigAfterInstall: {
                    self.cliImportRuns += 1
                    if let error = self.cliImportError { throw error }
                },
                monitorInstalledProvider: {
                    self.monitorRuns += 1
                    return self.monitorHealthy
                },
                readConfigModel: { self.configModel }
            )
        }
    }
}
