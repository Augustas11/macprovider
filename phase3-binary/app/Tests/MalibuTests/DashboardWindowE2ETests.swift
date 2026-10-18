import AppKit
import Vision
import XCTest
@testable import Malibu

/// Hosted-window click-through of this branch's dashboard. Does not launch
/// `/Applications/Malibu.app` and does not attach to the live provider.
@MainActor
final class DashboardWindowE2ETests: XCTestCase {
    func testHostedShellVisitsEverySectionResizesAndScrolls() throws {
        let artifacts = Self.makeArtifactsDirectory()
        let agent = MalibuAgent(initialSnapshot: Self.readyUSDCWithoutMALIBU())
        let navigation = MalibuNavigation()
        let window = DashboardWindow.make(
            agent: agent,
            navigation: navigation,
            onExportDiagnostics: {},
            onResetProvider: {}
        )
        window.title = "MalibuDashboardE2E"
        defer {
            window.sheets.forEach { window.endSheet($0) }
            window.close()
        }

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Self.spin(0.8)

        XCTAssertEqual(navigation.selection, .dashboard, "the window opens on Dashboard")
        XCTAssertEqual(AgentSnapshotPresenter.statusPill(agent.snapshot).label, "Serving")
        XCTAssertFalse(DashboardCopy.showsStatusNotice(agent.snapshot))
        XCTAssertNotNil(
            Self.firstView(in: window) { String(describing: type(of: $0)).contains("NSSplitView") || $0 is NSSplitView },
            "the shell must be a split view with a sidebar. tree=\n\(Self.viewTree(window))"
        )

        for (index, section) in MalibuSection.allCases.enumerated() {
            navigation.show(section)
            Self.spin(1.5)
            XCTAssertEqual(navigation.selection, section)
            Self.write(Self.viewTree(window), to: artifacts.appendingPathComponent(String(format: "%02d-%@-tree.txt", index + 1, section.rawValue)))
            // Regression: a detail measured at zero width once made the split
            // view taller than the window and the whole window drew blank.
            let split = Self.firstView(in: window) { String(describing: type(of: $0)).contains("NavigationSplitRepresentable") }
            XCTAssertLessThanOrEqual(
                split?.frame.height ?? .infinity,
                window.contentView?.bounds.height ?? 0,
                "\(section.rawValue) overflows the window"
            )
            let png = try Self.writePNG(
                Self.capture(window),
                to: artifacts.appendingPathComponent(String(format: "%02d-%@.png", index + 1, section.rawValue))
            )
            let text = Self.ocr(png)
            Self.write(text, to: artifacts.appendingPathComponent(String(format: "%02d-%@-text.txt", index + 1, section.rawValue)))
            Self.assertRenderedCopy(text, mustContain: [section.title, "Serving"])
        }

        navigation.show(.dashboard)
        Self.spin(0.4)
        Self.assertRenderedCopy(Self.ocr(try Self.writePNG(Self.capture(window), to: artifacts.appendingPathComponent("10-dashboard-again.png"))),
                                mustContain: ["Earnings (USDC)", "Your model"])

        window.setContentSize(NSSize(width: 840, height: 580))
        window.contentView?.layoutSubtreeIfNeeded()
        Self.spin(0.35)
        XCTAssertGreaterThanOrEqual(window.frame.width, DashboardWindow.minimumContentSize.width)
        XCTAssertGreaterThanOrEqual(window.frame.height, DashboardWindow.minimumContentSize.height)
        try Self.writePNG(Self.capture(window), to: artifacts.appendingPathComponent("11-shrunk.png"))

        if let scroll = Self.firstView(in: window, { view in
            guard let scroll = view as? NSScrollView else { return false }
            return (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height
        }) as? NSScrollView {
            let documentHeight = scroll.documentView?.frame.height ?? 0
            Self.scroll(scroll, to: NSPoint(x: 0, y: max(0, documentHeight - scroll.contentView.bounds.height)))
            Self.spin(0.2)
            try Self.writePNG(Self.capture(window), to: artifacts.appendingPathComponent("12-scrolled-bottom.png"))
            Self.scroll(scroll, to: .zero)
        }

        FileHandle.standardError.write(Data("E2E artifacts: \(artifacts.path)\n".utf8))
    }

    private static func assertRenderedCopy(_ text: String, mustContain needles: [String]) {
        // Pixel OCR is opt-in. GitHub Actions does not reliably pass CI=true into
        // the Malibu test host, and the runner's Vision output is junk.
        guard ProcessInfo.processInfo.environment["MALIBU_DASHBOARD_E2E_OCR"] == "1" else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            XCTFail("MALIBU_DASHBOARD_E2E_OCR=1 but OCR returned no dashboard text")
            return
        }
        for needle in needles {
            XCTAssertTrue(trimmed.contains(needle), "OCR missing \(needle). OCR:\n\(trimmed)")
        }
    }

    private static func firstView(in window: NSWindow, _ predicate: (NSView) -> Bool) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if predicate(view) { return view }
            for child in view.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(search)
    }

    private static func viewTree(_ window: NSWindow) -> String {
        var lines: [String] = []
        func walk(_ view: NSView, indent: String) {
            lines.append("\(indent)\(type(of: view)) frame=\(view.frame)")
            for child in view.subviews {
                walk(child, indent: indent + "  ")
            }
        }
        if let view = window.contentView {
            walk(view, indent: "")
        }
        return lines.joined(separator: "\n")
    }

    private static func scroll(_ scrollView: NSScrollView, to point: NSPoint) {
        if scrollView.documentView?.isFlipped == true {
            scrollView.contentView.scroll(to: point)
        } else {
            scrollView.contentView.scroll(to: point)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func ocr(_ image: NSBitmapImageRep) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n") ?? ""
    }

    private static func capture(_ window: NSWindow) -> NSBitmapImageRep? {
        window.contentView?.layoutSubtreeIfNeeded()
        // The window server image shows SwiftUI content as drawn; fall back
        // to the view cache when the test host lacks screen capture access.
        if let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.bestResolution, .boundsIgnoreFraming]
        ), cgImage.width > 1 {
            return NSBitmapImageRep(cgImage: cgImage)
        }
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @discardableResult
    private static func writePNG(_ rep: NSBitmapImageRep?, to url: URL) throws -> NSBitmapImageRep {
        guard let rep, let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "DashboardWindowE2E",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing png \(url.lastPathComponent)"]
            )
        }
        try data.write(to: url)
        return rep
    }

    private static func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func makeArtifactsDirectory() -> URL {
        let url = URL(fileURLWithPath: "/tmp/malibu-dashboard-e2e")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func readyUSDCWithoutMALIBU() -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.currentModelID = "qwen3-8b"
        snapshot.updateRewardInputs(providerEarningsFresh: true, malibuProjectionFresh: false)
        snapshot.walletBound = true
        snapshot.earningsUsdcToday = 0
        snapshot.earningsUsdcPending = 0.07
        snapshot.earningsUsdcLifetime = 0.07
        snapshot.lifecycleLastRestart = ProviderLifecycleEventSnapshot(
            sequence: 1,
            transitionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            transitionAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: "starting_provider",
            reason: "launchd_service_started",
            writer: "serve",
            compatibilitySetID: nil,
            operationID: nil
        )
        return snapshot
    }
}
