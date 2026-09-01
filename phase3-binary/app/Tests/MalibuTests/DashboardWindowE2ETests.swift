import AppKit
import Vision
import XCTest
@testable import Malibu

/// Hosted-window click-through of this branch's dashboard. Does not launch
/// `/Applications/Malibu.app` and does not attach to the live provider.
@MainActor
final class DashboardWindowE2ETests: XCTestCase {
    func testHostedDashboardClickThroughResizeScrollAndCopy() throws {
        let artifacts = Self.makeArtifactsDirectory()
        let agent = MalibuAgent(initialSnapshot: Self.readyUSDCWithoutMALIBU())
        let window = DashboardWindow.make(
            agent: agent,
            onExportDiagnostics: {},
            onResetProvider: {}
        )
        window.title = "MalibuDashboardE2E"
        defer {
            SettingsWindowPresenter.shared.present().close()
            window.sheets.forEach { window.endSheet($0) }
            window.close()
        }

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Self.spin(0.8)

        let mining = AgentSnapshotPresenter.miningHealth(agent.snapshot)
        XCTAssertEqual(mining.status, "Eligible, idle")
        XCTAssertEqual(mining.reasonCode, "idle_no_work")
        XCTAssertEqual(mining.trustSummary, "MALIBU trust telemetry not published yet")
        XCTAssertFalse(mining.status.contains("Reward status unavailable"))

        let initialPNG = try Self.writePNG(Self.capture(window), to: artifacts.appendingPathComponent("01-initial.png"))
        let initialText = Self.ocr(initialPNG)
        Self.write(initialText, to: artifacts.appendingPathComponent("01-initial-text.txt"))
        Self.write(Self.viewTree(window), to: artifacts.appendingPathComponent("01-initial-tree.txt"))
        Self.assertRenderedCopy(initialText, mustContain: ["Eligible, idle", "Change Model", "MALIBU trust telemetry not published yet"])

        let gear = Self.firstView(in: window) {
            String(describing: type(of: $0)).contains("SwiftUIAppKitButton") && $0.frame.width <= 24
        }
        XCTAssertNotNil(gear, "Settings must be a compact SwiftUI button")
        XCTAssertLessThanOrEqual(gear?.frame.width ?? .infinity, 24)

        let changeModel = Self.firstView(in: window) { view in
            (view as? NSButton)?.title.contains("Change Model") == true
        }
        XCTAssertNotNil(changeModel, "Change Model NSButton missing. tree=\n\(Self.viewTree(window))")
        let changeButton = try XCTUnwrap(changeModel as? NSButton)
        XCTAssertNotNil(changeButton.target, "Change Model NSButton has no target")
        changeButton.performClick(nil)
        Self.spin(1.2)
        var sheetText = Self.ocrAllVisibleWindows()
        var index = 0
        for extra in NSApp.windows where extra.isVisible {
            if let png = Self.capture(extra) {
                try Self.writePNG(png, to: artifacts.appendingPathComponent(String(format: "04-window-%02d.png", index)))
                index += 1
            }
        }
        Self.write(sheetText, to: artifacts.appendingPathComponent("04-change-model-text.txt"))
        Self.write(NSApp.windows.map { "title=\($0.title) sheet=\($0.isSheet) frame=\($0.frame)" }.joined(separator: "\n"), to: artifacts.appendingPathComponent("04-windows.txt"))
        let openedSwitcher = NSApp.windows.contains(where: \.isSheet)
            || sheetText.contains("Model switcher")
        XCTAssertTrue(
            openedSwitcher,
            "Change Model must open the switcher. windows=\(NSApp.windows.map { "\($0.title) sheet=\($0.isSheet)" }) OCR:\n\(sheetText)"
        )
        Self.assertRenderedCopy(sheetText, mustContain: ["Model switcher", "Close"])
        Self.clickCloseIfNeeded(in: window)
        Self.spin(0.25)

        let settingsButton = Self.firstView(in: window) {
            String(describing: type(of: $0)).contains("SwiftUIAppKitButton") && $0.frame.width <= 24
        }
        Self.click(settingsButton ?? gear)
        Self.spin(0.6)
        let settingsWindow = NSApp.windows.first { $0.title == "Malibu Settings" }
        XCTAssertNotNil(settingsWindow, "Settings gear must open Malibu Settings. windows=\(NSApp.windows.map(\.title))")
        if let settingsWindow {
            try Self.writePNG(Self.capture(settingsWindow), to: artifacts.appendingPathComponent("05-settings.png"))
            settingsWindow.close()
        }

        window.setContentSize(NSSize(width: 660, height: 540))
        window.contentView?.layoutSubtreeIfNeeded()
        Self.spin(0.35)
        XCTAssertGreaterThanOrEqual(window.frame.width, 640)
        XCTAssertGreaterThanOrEqual(window.frame.height, 520)
        let shrunkPNG = try Self.writePNG(Self.capture(window), to: artifacts.appendingPathComponent("02-shrunk.png"))
        let shrunkText = Self.ocr(shrunkPNG)
        Self.write(shrunkText, to: artifacts.appendingPathComponent("02-shrunk-text.txt"))
        Self.assertRenderedCopy(shrunkText, mustContain: ["Eligible, idle"])

        if let scroll = Self.firstView(in: window, { $0 is NSScrollView }) as? NSScrollView {
            let documentHeight = scroll.documentView?.frame.height ?? 0
            XCTAssertGreaterThan(
                documentHeight,
                scroll.contentView.bounds.height - 1,
                "Shrunk window must scroll instead of clipping. document=\(documentHeight) clip=\(scroll.contentView.bounds.height)"
            )
            Self.scroll(scroll, to: .zero)
            try Self.writePNG(Self.capture(window), to: artifacts.appendingPathComponent("03-scrolled-top.png"))
            Self.scroll(scroll, to: NSPoint(x: 0, y: max(0, documentHeight - scroll.contentView.bounds.height)))
            Self.spin(0.2)
            let bottomPNG = try Self.writePNG(Self.capture(window), to: artifacts.appendingPathComponent("03-scrolled-bottom.png"))
            let bottomText = Self.ocr(bottomPNG)
            Self.write(bottomText, to: artifacts.appendingPathComponent("03-scrolled-bottom-text.txt"))
            Self.assertRenderedCopy(
                bottomText,
                mustContain: ["Last setup failure", "None recorded", "Provider service started"]
            )
            Self.scroll(scroll, to: .zero)
            Self.spin(0.15)
        } else {
            XCTFail("Dashboard ScrollView missing after shrink")
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

    private static func click(_ view: NSView?) {
        guard let view, let window = view.window else { return }
        window.makeKeyAndOrderFront(nil)
        if view is NSControl || String(describing: type(of: view)).contains("SwiftUIAppKitButton") {
            _ = view.accessibilityPerformPress()
            (view as? NSControl)?.performClick(nil)
        }
        let local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let windowPoint = view.convert(local, to: nil)
        click(window, at: windowPoint)
        let screenRect = window.convertToScreen(NSRect(origin: windowPoint, size: CGSize(width: 1, height: 1)))
        let global = CGPoint(
            x: screenRect.midX,
            y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenRect.midY
        )
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: global, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: global, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
        Self.spin(0.05)
    }

    private static func click(leftOf view: NSView?, offset: CGFloat) {
        guard let view, let window = view.window else { return }
        let local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        var location = view.convert(local, to: nil)
        location.x -= offset
        click(window, at: location)
    }

    private static func click(_ window: NSWindow, at location: NSPoint) {
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: Int.random(in: 1..<10_000),
                clickCount: 1,
                pressure: 1
            )
        }
        if let down = mouse(.leftMouseDown) { window.sendEvent(down) }
        if let up = mouse(.leftMouseUp) { window.sendEvent(up) }
    }

    private static func clickCloseIfNeeded(in window: NSWindow) {
        if let close = firstView(in: window, {
            String(describing: type(of: $0)).contains("FocusRingView") && $0.frame.width < 90 && $0.frame.minY < 90
        }) {
            click(close)
        }
        window.sheets.forEach { window.endSheet($0) }
    }

    private static func scroll(_ scrollView: NSScrollView, to point: NSPoint) {
        if scrollView.documentView?.isFlipped == true {
            scrollView.contentView.scroll(to: point)
        } else {
            scrollView.contentView.scroll(to: point)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func ocrAllVisibleWindows() -> String {
        NSApp.windows.compactMap { window -> String? in
            guard window.isVisible, let png = capture(window) else { return nil }
            return ocr(png)
        }.joined(separator: "\n---\n")
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
        guard let view = window.contentView else { return nil }
        let bounds = view.bounds
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            return rep
        }
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
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
