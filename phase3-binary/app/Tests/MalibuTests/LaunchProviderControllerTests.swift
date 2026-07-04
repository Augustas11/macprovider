import CryptoKit
import XCTest
@testable import Malibu

@MainActor
final class LaunchProviderControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set("v2", forKey: "onboardingFlow")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "onboardingFlow")
        super.tearDown()
    }

    func testLaunchHappyPathRunsOrderedStateMachine() async {
        let harness = Harness()
        let controller = LaunchProviderController(
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            bundledCLIPath: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            dependencies: harness.dependencies()
        )

        await controller.launch()

        XCTAssertEqual(harness.savedProviderID, "p_test")
        XCTAssertEqual(harness.savedToken, "provider-token")
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.agentStarts, 1)
        XCTAssertEqual(harness.autotuneRuns, 1)
        XCTAssertEqual(harness.modelDownloads.map(\.modelName), ["recommended"])
        XCTAssertEqual(harness.stageUpdates, ["registered", "autotuning", "cliReady", "downloadingModel", "modelReady", "startingAgent", "live"])
        XCTAssertEqual(controller.stage, .live(model: "recommended", tier: .provisional))
    }

    func testLaunchRegisterFailureIsRetryableAtRegisteringStage() async {
        let harness = Harness()
        harness.registerError = NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "register failed"])
        let controller = LaunchProviderController(
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            bundledCLIPath: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            dependencies: harness.dependencies()
        )

        await controller.launch()

        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "registering")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, "register failed")
        } else {
            XCTFail("expected failed registering stage")
        }
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.agentStarts, 0)
    }

    func testLaunchResumesConfiguredPartialModelDownloadWithoutReregistering() async {
        let harness = Harness()
        harness.configured = true
        harness.loadedState = OnboardingState(
            onboardingSchemaVersion: 2,
            providerID: "p_test",
            createdAt: Date(timeIntervalSince1970: 1),
            lastStage: "downloadingModel",
            firstServingAt: nil,
            modelDownload: OnboardingState.ModelDownloadState(
                modelID: "Qwen2.5-7B-Instruct",
                targetURL: URL(string: "https://models.example/qwen")!,
                targetSHA256: "abc123",
                partialBytes: 4096
            )
        )
        let controller = LaunchProviderController(
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            bundledCLIPath: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            dependencies: harness.dependencies()
        )

        await controller.launch()

        XCTAssertNil(harness.savedProviderID)
        XCTAssertEqual(harness.autotuneRuns, 0)
        XCTAssertEqual(harness.modelDownloads.map(\.modelName), ["Qwen2.5-7B-Instruct"])
        XCTAssertEqual(harness.stageUpdates, ["downloadingModel", "modelReady", "startingAgent", "live"])
        XCTAssertEqual(harness.agentStarts, 1)
        XCTAssertEqual(controller.stage, .live(model: "Qwen2.5-7B-Instruct", tier: .provisional))
    }

    func testLaunchStartsConfiguredInstallWithoutSynthesizingFirstServingState() async {
        let harness = Harness()
        harness.configured = true
        let controller = LaunchProviderController(
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            bundledCLIPath: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            dependencies: harness.dependencies()
        )

        await controller.launch()

        XCTAssertEqual(harness.agentStarts, 1)
        XCTAssertTrue(harness.stageUpdates.isEmpty)
        XCTAssertEqual(controller.stage, .live(model: "configured", tier: .provisional))
    }

    func testLaunchResumesIdentityReadyByRegisteringBeforeAutotune() async {
        let harness = Harness()
        harness.loadedState = OnboardingState(
            onboardingSchemaVersion: 2,
            providerID: "p_test",
            createdAt: Date(timeIntervalSince1970: 1),
            lastStage: "identityReady",
            firstServingAt: nil,
            modelDownload: nil
        )
        let controller = LaunchProviderController(
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            bundledCLIPath: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            dependencies: harness.dependencies()
        )

        await controller.launch()

        XCTAssertEqual(harness.savedProviderID, "p_test")
        XCTAssertEqual(harness.savedToken, "provider-token")
        XCTAssertEqual(harness.stageUpdates, ["registered", "autotuning", "cliReady", "downloadingModel", "modelReady", "startingAgent", "live"])
        XCTAssertEqual(harness.autotuneRuns, 1)
        XCTAssertEqual(harness.agentStarts, 1)
        XCTAssertEqual(controller.stage, .live(model: "recommended", tier: .provisional))
    }

    func testLaunchRepairsMarkerlessRegisteredStateBeforeResume() async {
        let harness = Harness()
        harness.configured = false
        harness.configProviderID = "p_test"
        harness.providerToken = "provider-token"
        harness.loadedState = OnboardingState(
            onboardingSchemaVersion: 2,
            providerID: "p_test",
            createdAt: Date(timeIntervalSince1970: 1),
            lastStage: "registered",
            firstServingAt: nil,
            modelDownload: nil
        )
        let controller = LaunchProviderController(
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            bundledCLIPath: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            dependencies: harness.dependencies()
        )

        await controller.launch()

        XCTAssertEqual(harness.markerRepairs, ["p_test"])
        XCTAssertNil(harness.savedProviderID)
        XCTAssertEqual(harness.autotuneRuns, 1)
        XCTAssertEqual(harness.stageUpdates, ["autotuning", "cliReady", "downloadingModel", "modelReady", "startingAgent", "live"])
        XCTAssertEqual(harness.agentStarts, 1)
        XCTAssertEqual(controller.stage, .live(model: "recommended", tier: .provisional))
    }

    func testLaunchRepairsMarkerlessStartingAgentStateBeforeResume() async {
        let harness = Harness()
        harness.configured = false
        harness.configProviderID = "p_test"
        harness.providerToken = "provider-token"
        harness.loadedState = OnboardingState(
            onboardingSchemaVersion: 2,
            providerID: "p_test",
            createdAt: Date(timeIntervalSince1970: 1),
            lastStage: "startingAgent",
            firstServingAt: nil,
            modelDownload: OnboardingState.ModelDownloadState(
                modelID: "Qwen2.5-7B-Instruct",
                targetURL: URL(string: "https://models.example/qwen")!,
                targetSHA256: "abc123",
                partialBytes: 0
            )
        )
        let controller = LaunchProviderController(
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            bundledCLIPath: URL(fileURLWithPath: "/tmp/macprovider-cli"),
            dependencies: harness.dependencies()
        )

        await controller.launch()

        XCTAssertEqual(harness.markerRepairs, ["p_test"])
        XCTAssertNil(harness.savedProviderID)
        XCTAssertEqual(harness.autotuneRuns, 0)
        XCTAssertTrue(harness.modelDownloads.isEmpty)
        XCTAssertEqual(harness.stageUpdates, ["startingAgent", "live"])
        XCTAssertEqual(harness.agentStarts, 1)
        XCTAssertEqual(controller.stage, .live(model: "Qwen2.5-7B-Instruct", tier: .provisional))
    }

    private final class Harness {
        var savedProviderID: String?
        var savedToken: String?
        var loginItemRegistrations = 0
        var agentStarts = 0
        var markerRepairs: [String] = []
        var linkStates: [ProviderConfig.LinkState] = []
        var stageUpdates: [String] = []
        var modelDownloads: [LaunchProviderController.ModelDownloadPlan] = []
        var autotuneRuns = 0
        var configured = false
        var configProviderID = "p_test"
        var providerToken: String?
        var loadedState: OnboardingState?
        var registerError: Error?
        let key = Curve25519.Signing.PrivateKey()

        func dependencies() -> LaunchProviderController.Dependencies {
            LaunchProviderController.Dependencies(
                isConfigured: { self.configured },
                loadState: { self.loadedState },
                loadOrGenerateIdentity: { self.key },
                loadExistingIdentity: { self.key },
                providerID: { _ in "p_test" },
                currentProviderToken: { _ in self.providerToken },
                registerProvider: { _, _ in
                    if let error = self.registerError { throw error }
                    return RegisterResponse(
                        providerID: "p_test",
                        providerToken: "provider-token",
                        trustTier: "provisional",
                        coordinatorWebSocketURL: URL(string: "wss://coordinator.streamvc.live/v2/provider")!
                    )
                },
                saveProviderIdentity: { providerID, token in
                    self.savedProviderID = providerID
                    self.savedToken = token
                },
                repairMarkerlessAppConfig: { providerID in
                    self.markerRepairs.append(providerID)
                    self.configured = true
                },
                saveState: { _ in },
                updateState: { _, lastStage, _, _ in
                    self.stageUpdates.append(lastStage)
                },
                markLinkState: { state in
                    self.linkStates.append(state)
                },
                runAutotune: { _ in
                    self.autotuneRuns += 1
                    return .recommended
                },
                ensureCLIReady: {},
                downloadModel: { plan in
                    self.modelDownloads.append(plan)
                    return plan.state ?? OnboardingState.ModelDownloadState(
                        modelID: plan.modelName,
                        targetURL: URL(string: "https://models.example/\(plan.modelName)")!,
                        targetSHA256: "sha256",
                        partialBytes: 0
                    )
                },
                registerLoginItem: {
                    self.loginItemRegistrations += 1
                },
                startAgent: {
                    self.agentStarts += 1
                },
                waitForFirstServing: {
                    Date(timeIntervalSince1970: 2)
                },
                readProviderID: { self.configProviderID }
            )
        }
    }
}
