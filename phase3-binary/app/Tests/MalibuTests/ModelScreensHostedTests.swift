import AppKit
import SwiftUI
import XCTest
@testable import Malibu

/// Hosts the Models and Discover screens over a store fed by a fake CLI
/// projection, so the populated screens render and are captured for review.
/// Does not run the provider CLI and does not attach to the live provider.
@MainActor
final class ModelScreensHostedTests: XCTestCase {
    func testPopulatedModelsAndDiscoverScreensRender() async throws {
        let rows = [
            ShellScreensTests.rowJSON(key: "llama-3.2-3b-instruct", isCurrent: true, estimatedGB: 1.8, completion: 0.08, demandRank: 9),
            ShellScreensTests.rowJSON(key: "qwen3.6-35b-a3b", weightsLocal: true, estimatedGB: 20.4, completion: 0.52, demandRank: 2, switchable: true),
            ShellScreensTests.rowJSON(key: "gpt-oss-20b", weightsLocal: false, runtimeState: "needs_preparation", estimatedGB: 12.1, completion: 0.31, demandRank: 4),
            ShellScreensTests.rowJSON(key: "llama-3.3-70b", fit: "does_not_fit", weightsLocal: false, estimatedGB: 40, completion: 0.9, demandRank: 1),
        ]
        let cli = ProjectionCLI(stdout: Self.projection(rows: rows))
        let store = ModelManagementStore(
            cli: cli,
            browseCLI: ProjectionCLI(stdout: ""),
            paths: Self.paths(),
            defaults: UserDefaults(suiteName: "ModelScreensHostedTests.\(UUID().uuidString)")!
        )
        await store.refresh(currentModelID: "llama-3.2-3b-instruct", peer: Self.peer())
        XCTAssertEqual(store.listState, .ready)
        XCTAssertEqual(
            ModelsPresentation.sections(store.rows).map(\.title),
            ["Current", "Ready to switch", "Needs preparation"]
        )
        XCTAssertEqual(DiscoverPresentation.visibleRows(store.rows, search: "", fitsOnly: true, sort: .catalog).count, 3)

        let agent = MalibuAgent(initialSnapshot: .empty)
        let artifacts = URL(fileURLWithPath: "/tmp/malibu-dashboard-e2e", isDirectory: true)
        try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try host(ModelsScreen(store: store, agent: agent), png: artifacts.appendingPathComponent("20-models-populated.png"))
        try host(DiscoverScreen(store: store, agent: agent), png: artifacts.appendingPathComponent("21-discover-populated.png"))
        let ready = try XCTUnwrap(store.rows.first { $0.action == .switchModel })
        try host(ModelSwitchSheet(store: store, row: ready, isRevert: false) {}, png: artifacts.appendingPathComponent("22-switch-confirm.png"), size: NSSize(width: 480, height: 330))
    }

    private func host<V: View>(_ view: V, png: URL, size: NSSize = NSSize(width: 830, height: 620)) throws {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.frame(width: size.width, height: size.height)))
        window.setContentSize(size)
        defer { window.close() }
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let rep: NSBitmapImageRep?
        if let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
           cgImage.width > 1 {
            rep = NSBitmapImageRep(cgImage: cgImage)
        } else if let content = window.contentView, let cached = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: cached)
            rep = cached
        } else {
            rep = nil
        }
        let data = try XCTUnwrap(rep?.representation(using: .png, properties: [:]))
        try data.write(to: png)
    }

    private static func projection(rows: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = formatter.string(from: Date())
        return """
        {"schema":"model_catalog_economics.v1","generated_at":"\(now)","projection_sequence":1,"source":{"cli_version":"1.8.256","cli_build_commit":"test","process_launch_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","process_started_at":"\(now)","projection_protocol_version":"1","rate_card_source":"live_signed","rate_card_digest":"\(String(repeating: "a", count: 64))","rate_card_signature_digest":null,"demand_feed_digest":"\(String(repeating: "b", count: 64))","candidate_feed_digest":"\(String(repeating: "c", count: 64))","rate_card_max_age_seconds":604800},"rows":[\(rows.joined(separator: ","))],"warnings":[]}
        """
    }

    private static func peer() -> MalibuModelPeerEvidence {
        let manifest = MalibuModelCapabilityManifest.checkedIn
        var capabilities = Set<String>()
        var version = "0.0.0"
        for name in [MalibuModelCapabilityManifest.readySwitch, MalibuModelCapabilityManifest.catalogEconomics] {
            let tier = manifest.tiers[name]!
            capabilities.formUnion(tier.localStatusCapabilities)
            capabilities.formUnion(tier.commandSchemas)
            capabilities.formUnion(tier.controlFrameSchemas)
            if ProviderCLIVersion.compare(tier.firstSupportingBinaryVersion, version) == .descending {
                version = tier.firstSupportingBinaryVersion
            }
        }
        return MalibuModelPeerEvidence(
            binaryVersion: version,
            capabilities: capabilities,
            contractCompatible: true,
            lifecycleOwner: "macprovider_cli",
            serviceInstanceID: "instance",
            servicePID: Int(getpid()),
            observedAt: Date(),
            observationValidForMS: 5_000,
            observationFresh: true
        )
    }

    private static func paths() -> ProviderPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-model-screens-\(UUID().uuidString)", isDirectory: true)
        return ProviderPaths(
            configFile: root.appendingPathComponent("config.yaml"),
            controlSocket: root.appendingPathComponent("ctl.sock"),
            cliLogFile: root.appendingPathComponent("cli.log"),
            launchdStdoutLog: root.appendingPathComponent("out.log"),
            launchdStderrLog: root.appendingPathComponent("err.log"),
            appSupport: root,
            appMarkerFile: root.appendingPathComponent(".installed-by-app"),
            onboardingStateFile: root.appendingPathComponent("onboarding.json"),
            downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )
    }
}

/// Answers every call with one fixed projection.
private final class ProjectionCLI: MalibuModelCLIRunning {
    private let stdout: String

    init(stdout: String) {
        self.stdout = stdout
    }

    func run(
        arguments: [String],
        peer: MalibuModelPeerEvidence?,
        stdinData: Data?,
        priority: ModelCLIWorkPriority,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ModelCLIResult {
        ModelCLIResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
