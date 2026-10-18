import XCTest
@testable import Malibu

/// View-model tests for the Phase 2 sidebar shell and its screens (#2054).
final class ShellScreensTests: XCTestCase {
    // MARK: Shell

    func testSidebarSectionsAreInTheAuditOrder() {
        XCTAssertEqual(
            MalibuSection.allCases.map(\.title),
            ["Dashboard", "Chat", "Models", "Discover", "Provider", "Settings", "Diagnostics"]
        )
        XCTAssertEqual(MalibuSection.primary, [.dashboard, .chat, .models, .discover, .provider])
        XCTAssertEqual(MalibuSection.utility, [.settings, .diagnostics])
        XCTAssertEqual(Set(MalibuSection.allCases.map(\.systemImage)).count, MalibuSection.allCases.count)
    }

    @MainActor
    func testNavigationOpensOnDashboardAndShowsARequestedSection() {
        let navigation = MalibuNavigation()
        XCTAssertEqual(navigation.selection, .dashboard)
        navigation.show(.settings)
        XCTAssertEqual(navigation.selection, .settings)
    }

    func testSidebarFooterShowsLoadedModelAndHealth() {
        var snapshot = AgentSnapshot.empty
        XCTAssertEqual(ShellSidebarPresentation.footerModel(snapshot), "No model loaded")
        XCTAssertNil(ShellSidebarPresentation.footerHealth(snapshot))
        snapshot.currentModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
        snapshot.advertisedMaxConcurrency = 1
        snapshot.thermalState = .nominal
        XCTAssertEqual(ShellSidebarPresentation.footerModel(snapshot), "Llama-3.2-3B-Instruct-4bit")
        snapshot.currentModelID = "org/evil\u{202E}name\nline"
        XCTAssertEqual(ShellSidebarPresentation.footerModel(snapshot), "evilname line", "provider text is one plain line")
        XCTAssertEqual(ShellSidebarPresentation.footerHealth(snapshot), "1 slot · cool")
        snapshot.advertisedMaxConcurrency = 4
        snapshot.thermalState = .critical
        XCTAssertEqual(ShellSidebarPresentation.footerHealth(snapshot), "4 slots · throttled by heat")
    }

    func testChatPlaceholderPromisesNothingAboutEarnings() {
        let text = ChatPlaceholderScreen.message.lowercased()
        XCTAssertTrue(text.contains("later"))
        XCTAssertTrue(text.contains("stay on this mac"))
        assertNoForbiddenCopy([text])
    }

    // MARK: Dashboard

    func testDashboardYourModelCardShowsRateDemandAndDisclosureForTrustedCurrentRow() throws {
        let current = try Self.row(key: "qwen3-8b", isCurrent: true)
        let lines = DashboardCopy.yourModelLines(currentModelID: "qwen3-8b", listState: .ready, rows: [current])
        XCTAssertEqual(lines[0], "qwen3-8b")
        XCTAssertEqual(lines[1], "Serving this model. Switching is available.")
        XCTAssertEqual(lines[2], d("Provider share rate $0§36 per 1M completion tokens · network demand rank 7"))
        XCTAssertEqual(lines[3], ModelsPresentation.rateDisclosure)
        assertNoForbiddenCopy(lines)

        let noRows = DashboardCopy.yourModelLines(currentModelID: "qwen3-8b", listState: .unavailable, rows: [])
        XCTAssertEqual(noRows, ["qwen3-8b", "Serving this model. Switching is unavailable right now; open Models to retry."])
    }

    func testDashboardHasNoAdvancedDiagnosticsAndNoInviteNudgeWithoutAnInvite() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "qwen3-8b"
        let strings = DashboardCopy.defaultPublicStrings(snapshot)
        XCTAssertEqual(strings.first, "Dashboard")
        XCTAssertTrue(strings.contains(DashboardCopy.yourModelTitle))
        XCTAssertFalse(strings.contains("Advanced diagnostics"))
        XCTAssertFalse(DashboardCopy.showsInviteNudge(snapshot))
        XCTAssertFalse(strings.contains(DashboardCopy.invitesNudge))
    }

    // MARK: Models

    func testModelsSectionsFollowSpec044R008OrderAndFilter() throws {
        let rows = try [
            Self.row(key: "blocked-model", fit: "does_not_fit", weightsLocal: true),
            Self.row(key: "catalog-model", weightsLocal: true),
            Self.row(key: "ready-model", weightsLocal: true, switchable: true),
            Self.row(key: "current-model", isCurrent: true),
            Self.row(key: "remote-model", weightsLocal: false, runtimeState: "needs_preparation"),
        ]
        let sections = ModelsPresentation.sections(rows)
        XCTAssertEqual(sections.map(\.title), ["Current", "Ready to switch", "Network catalog", "Needs preparation", "Blocked"])
        XCTAssertEqual(sections.map { $0.rows.map(ModelsPresentation.name) }, [
            ["current-model"], ["ready-model"], ["catalog-model"], ["remote-model"], ["blocked-model"],
        ])
        XCTAssertEqual(ModelsPresentation.sections(rows, filter: "READY").map(\.title), ["Ready to switch"])
        XCTAssertTrue(ModelsPresentation.sections(rows, filter: "nothing-matches").isEmpty)
    }

    func testModelsRowColumnsAndReasons() throws {
        let ready = try Self.row(key: "ready-model", weightsLocal: true, switchable: true)
        XCTAssertEqual(ready.action, .switchModel)
        XCTAssertEqual(ModelsPresentation.sizeText(ready), d("4§0 GB"))
        XCTAssertEqual(ModelsPresentation.fitText(ready), "Fits")
        XCTAssertEqual(ModelsPresentation.statusText(ready), "Ready to switch")
        XCTAssertEqual(ModelsPresentation.rateText(ready), d("$0§36"))
        XCTAssertEqual(ModelsPresentation.reason(ready), "On this Mac, fits, and ready for a live switch.")

        let current = try Self.row(key: "current-model", isCurrent: true)
        XCTAssertEqual(ModelsPresentation.statusText(current), "Serving")
        XCTAssertEqual(ModelsPresentation.reason(current), "This Mac is serving this model.")

        let blocked = try Self.row(key: "big", fit: "does_not_fit", weightsLocal: true, economicsState: "stale")
        XCTAssertEqual(ModelsPresentation.fitText(blocked), "Does not fit")
        XCTAssertEqual(ModelsPresentation.rateText(blocked), "—", "an untrusted row shows no rate")
        XCTAssertNotNil(ModelsPresentation.reason(blocked), "every non-actionable row states why")
    }

    func testModelsHeaderCountsOnlyLocalWeights() throws {
        let rows = try [
            Self.row(key: "a", weightsLocal: true, estimatedGB: 4.0),
            Self.row(key: "b", weightsLocal: true, estimatedGB: 20.4),
            Self.row(key: "c", weightsLocal: false, estimatedGB: 40),
        ]
        XCTAssertEqual(ModelsPresentation.localSummary(rows), d("2 models on this Mac · about 24§4 GB"))
        XCTAssertEqual(ModelsPresentation.localSummary([]), "0 models on this Mac")
    }

    func testSwitchingLineFollowsWarmSwapNotRowActions() {
        XCTAssertEqual(ModelsPresentation.switchingLine(listState: .ready, warmSwapAvailable: true), "Switching available.")
        XCTAssertEqual(ModelsPresentation.switchingLine(listState: .viewOnly, warmSwapAvailable: true), "Switching available.",
                       "a projection with only the current model still has switching")
        XCTAssertEqual(ModelsPresentation.switchingLine(listState: .ready, warmSwapAvailable: false), "Switching off: warm swap is not running on this Mac.",
                       "an evaluate-only projection does not mean switching works")
        XCTAssertEqual(ModelsPresentation.switchingLine(listState: .unavailable, warmSwapAvailable: true), "Switching unavailable right now.")
    }

    func testRowsFollowTheCompleteSpec044R005Order() throws {
        let rows = try [
            Self.row(key: "b-model", weightsLocal: true, supplyDeficit: 1.0),
            Self.row(key: "a-model", weightsLocal: true, supplyDeficit: 1.0),
            Self.row(key: "c-model", weightsLocal: true, supplyDeficit: 2.0),
            Self.row(key: "d-model", weightsLocal: true, demandRank: 3),
            Self.row(key: "e-model", weightsLocal: true, completion: 0.9),
        ].shuffled()
        XCTAssertEqual(rows.sortedForDisplay().map(\.id), ["e-model", "d-model", "c-model", "a-model", "b-model"],
                       "rate, then demand rank, then supply deficit, then canonical identity bytes")
    }

    func testProviderTextIsShownAsOnePlainLine() {
        XCTAssertEqual(ShellText.display("a\u{0007}b\u{200F}c\nd"), "abc d")
        XCTAssertEqual(ShellText.display(String(repeating: "x", count: 50), maxLength: 10), "xxxxxxxxx…")
    }

    func testModelsScreenCopyCarriesTheRateDisclosureAndNoIncomeClaims() throws {
        let rows = try [
            Self.row(key: "current-model", isCurrent: true),
            Self.row(key: "ready-model", weightsLocal: true, switchable: true),
        ]
        let strings = ModelsPresentation.screenStrings(rows: rows, listState: .ready)
        XCTAssertTrue(strings.contains(ModelsPresentation.rateDisclosure))
        XCTAssertTrue(strings.contains(ModelsPresentation.switchingCost))
        XCTAssertTrue(ModelsPresentation.switchingCost.contains("503"))
        assertNoForbiddenCopy(strings)
        print("MALIBU_MODELS_RENDER_BEGIN\n" + strings.joined(separator: "\n") + "\nMALIBU_MODELS_RENDER_END")
    }

    // MARK: Switch sheet

    func testSwitchConfirmationStatesCustomerImpactAndNoCancel() throws {
        let ready = try Self.row(key: "ready-model", weightsLocal: true, switchable: true)
        let lines = SwitchSheetPresentation.confirmLines(row: ready, currentModelID: "current-model", allRows: [ready])
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("From current-model to ready-model."))
        XCTAssertTrue(text.contains("HTTP 503"))
        XCTAssertTrue(text.contains("can't be cancelled once it starts"))
        XCTAssertTrue(text.contains("nothing is downloaded"))
        XCTAssertTrue(text.contains(d("Provider share rate $0§36")))
        XCTAssertTrue(lines.contains(ModelsPresentation.rateDisclosure))
        XCTAssertTrue(lines.contains(try XCTUnwrap(ready.nonEarningDisclosure)), "a catalog_priced row keeps its no-credit caveat")
        assertNoForbiddenCopy(lines)
        XCTAssertEqual(SwitchSheetPresentation.confirmTitle(target: "x", isRevert: false), "Switch to x?")
        XCTAssertEqual(SwitchSheetPresentation.confirmTitle(target: "x", isRevert: true), "Revert to x?")
    }

    func testSwitchSheetStageFollowsSwitchProgress() {
        typealias Op = ModelManagementStore.Operation
        func stage(_ op: Op, current: String? = "old", observed: Bool = true) -> SwitchSheetPresentation.Stage {
            SwitchSheetPresentation.stage(operation: op, target: "new", currentModelID: current, statusLine: "Load failed.", observedStart: observed)
        }
        XCTAssertEqual(stage(.failed("earlier"), observed: false), .running(phase: "requested", elapsedSeconds: 0),
                       "an earlier failure is not this switch's outcome")
        XCTAssertEqual(stage(.switching(target: "new", phase: "loading", elapsedMS: 4_500)), .running(phase: "loading", elapsedSeconds: 4))
        XCTAssertEqual(stage(.switching(target: "new", phase: "draining", elapsedMS: 9_000)), .running(phase: "draining", elapsedSeconds: 9))
        XCTAssertEqual(stage(.switching(target: "new", phase: "failed", elapsedMS: 9_000)), .failed("Load failed."))
        XCTAssertEqual(stage(.reconciling(target: "new")), .reconciling)
        XCTAssertEqual(stage(.idle, current: "new"), .succeeded)
        XCTAssertEqual(stage(.failed("x")), .failed("Load failed."))
        XCTAssertEqual(stage(.runtimeConflict(expected: "new", observed: "old")), .failed("Load failed."))
        XCTAssertTrue(SwitchSheetPresentation.stageLine(.failed("Load failed.")).contains("keeps serving"))
        XCTAssertEqual(SwitchSheetPresentation.steps, ["requested", "loading", "draining", "loaded"])
    }

    // MARK: Discover

    func testDiscoverListsSignedCatalogRowsOnly() throws {
        let catalog = try Self.row(key: "catalog-model", weightsLocal: true)
        let byom = try Self.row(key: "local-candidate", economicsState: "blocked", catalogPermitted: false)
        XCTAssertEqual(DiscoverPresentation.catalogRows([catalog, byom]).map(\.id), ["catalog-model"])
        XCTAssertTrue(DiscoverPresentation.showsRecommendation("Catalog-Model", rows: [catalog, byom]))
        XCTAssertFalse(DiscoverPresentation.showsRecommendation("local-candidate", rows: [catalog, byom]),
                       "a recommendation's rates never show for a non-catalog model")
        XCTAssertFalse(DiscoverPresentation.showsRecommendation(nil, rows: [catalog]))
    }

    func testDiscoverFitFilterAndSortsKeepCatalogOrderAsTieBreak() throws {
        let rows = try [
            Self.row(key: "a", weightsLocal: true, estimatedGB: 20, completion: 0.30, demandRank: 3),
            Self.row(key: "b", weightsLocal: true, estimatedGB: 4, completion: 0.50, demandRank: 3),
            Self.row(key: "c", fit: "does_not_fit", weightsLocal: false, estimatedGB: 40, completion: 0.90, demandRank: 1),
        ]
        func ids(_ fitsOnly: Bool, _ sort: DiscoverPresentation.Sort, _ search: String = "") -> [String] {
            DiscoverPresentation.visibleRows(rows, search: search, fitsOnly: fitsOnly, sort: sort).map(\.id)
        }
        XCTAssertEqual(ids(true, .catalog), ["a", "b"])
        XCTAssertEqual(ids(false, .catalog), ["a", "b", "c"])
        XCTAssertEqual(ids(false, .demand), ["c", "a", "b"], "equal ranks keep catalog order")
        XCTAssertEqual(ids(false, .rate), ["c", "b", "a"])
        XCTAssertEqual(ids(false, .size), ["b", "a", "c"])
        XCTAssertEqual(ids(false, .catalog, "B"), ["b"])
    }

    func testDiscoverDetailShowsRatesShareDemandAndProvidersOnly() throws {
        let row = try Self.row(key: "qwen3-8b", weightsLocal: false, runtimeState: "needs_preparation", estimatedGB: 4)
        let lines = DiscoverPresentation.detailLines(row, hostMemoryGB: 32)
        XCTAssertEqual(lines[0], d("About 4§0 GB of weights · fits this Mac's 32 GB"))
        XCTAssertTrue(lines.contains("Provider share: 90% of the catalog rate."))
        XCTAssertTrue(lines.contains("Network demand rank 7."))
        XCTAssertTrue(lines.contains("4 providers are ready to serve it."))
        XCTAssertTrue(lines.contains("Weights are not on this Mac."))
        XCTAssertTrue(lines.contains { $0.hasPrefix(d("Provider share rate: completion $0§36 per 1M tokens")) })
        assertNoForbiddenCopy(lines)
        XCTAssertEqual(DiscoverPresentation.primaryAction(row), .preparationNotOffered,
                       "SPEC-044-R006: no Prepare without a typed CLI transaction")
        XCTAssertEqual(DiscoverPresentation.primaryAction(try Self.row(key: "r", weightsLocal: true, switchable: true)), .switchModel)
        XCTAssertEqual(DiscoverPresentation.primaryAction(try Self.row(key: "c", isCurrent: true)), .serving)
    }

    func testDiscoverEmptyStatesAndRender() throws {
        XCTAssertTrue(DiscoverPresentation.screenStrings(rows: [], hostMemoryGB: 32).contains(DiscoverPresentation.emptyCatalog))
        let big = try Self.row(key: "big", fit: "does_not_fit", weightsLocal: false)
        XCTAssertTrue(DiscoverPresentation.screenStrings(rows: [big], hostMemoryGB: 32).contains(DiscoverPresentation.emptyFilter))
        let rows = try [
            Self.row(key: "current-model", isCurrent: true),
            Self.row(key: "qwen3.6-35b-a3b", weightsLocal: false, runtimeState: "needs_preparation", estimatedGB: 20.4, completion: 0.52, demandRank: 2),
        ]
        let strings = DiscoverPresentation.screenStrings(rows: rows, hostMemoryGB: 32)
        XCTAssertTrue(strings.contains(ModelsPresentation.rateDisclosure))
        XCTAssertTrue(strings.contains(DiscoverPresentation.otherMLXTitle))
        assertNoForbiddenCopy(strings + [DiscoverPresentation.otherMLXExplainer, DiscoverPresentation.preparationNotOffered])
        print("MALIBU_DISCOVER_RENDER_BEGIN\n" + strings.joined(separator: "\n") + "\nMALIBU_DISCOVER_RENDER_END")
    }

    // MARK: Other MLX models (models browse)

    func testBrowseDecodeIsStrictAndNeverActionable() throws {
        let rows = try MalibuOtherMLXModel.decodeBrowse(Self.browseJSON())
        XCTAssertEqual(rows, [MalibuOtherMLXModel(id: "mlx-community/Qwen3-8B-4bit", fit: "fits", estimatedGB: 4.6)])
        XCTAssertEqual(DiscoverPresentation.otherMLXSubtitle(rows[0]), d("4§6 GB · fits · not earnable"))

        XCTAssertThrowsError(try MalibuOtherMLXModel.decodeBrowse(Self.browseJSON(actionable: true)))
        XCTAssertThrowsError(try MalibuOtherMLXModel.decodeBrowse(Self.browseJSON(actionModelID: "\"x\"")))
        XCTAssertThrowsError(try MalibuOtherMLXModel.decodeBrowse(Self.browseJSON(schema: "models_browse.v2")))
        XCTAssertThrowsError(try MalibuOtherMLXModel.decodeBrowse(Self.browseJSON(extraRowKey: true)))
        XCTAssertThrowsError(try MalibuOtherMLXModel.decodeBrowse(Self.browseJSON(extraRootKey: true)), "the envelope is closed too")
        XCTAssertThrowsError(try MalibuOtherMLXModel.decodeBrowse(Self.browseJSON(modelID: "/Users/me/model")))
        XCTAssertThrowsError(try MalibuOtherMLXModel.decodeBrowse(Self.browseJSON(fit: "huge")))
    }

    func testBrowseQueryIsSanitized() {
        XCTAssertNil(MalibuOtherMLXModel.sanitizedQuery("   "))
        XCTAssertEqual(MalibuOtherMLXModel.sanitizedQuery("qwen"), "qwen")
        XCTAssertEqual(MalibuOtherMLXModel.sanitizedQuery("--limit 999"), "limit 999", "a query never reads as a flag")
        XCTAssertEqual(MalibuOtherMLXModel.sanitizedQuery("llama;rm -rf"), "llamarm -rf")
        XCTAssertEqual(MalibuOtherMLXModel.sanitizedQuery(String(repeating: "a", count: 100))?.count, 64)
    }

    // MARK: Provider

    func testEngineStatusDecodesCBAndMTPFromStatus() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"continuous_batching":{"mode":"on","active":true,"unsupported_reason":null,"scheduler":{"slots_total":8,"slots_free":6,"waiting_count":2}},
         "native_mtp":{"supported":true,"enabled":true,"mode":"active","mean_accepted_length":1.84}}
        """.utf8)) as? [String: Any])
        let engine = try XCTUnwrap(ProviderEngineStatus.decode(status: object))
        XCTAssertEqual(ProviderScreenPresentation.continuousBatchingLine(engine), "On · 6 of 8 rows free · 2 waiting")
        XCTAssertEqual(ProviderScreenPresentation.nativeMTPLine(engine), d("On · 1§84 tokens accepted per step"))
        XCTAssertNil(ProviderEngineStatus.decode(status: [:]), "an older CLI reports neither")

        let off = try XCTUnwrap(ProviderEngineStatus.decode(status: [
            "continuous_batching": ["mode": "off", "active": false],
            "native_mtp": ["supported": false, "enabled": false, "mode": "off"],
        ]))
        XCTAssertEqual(ProviderScreenPresentation.continuousBatchingLine(off), "Off: requests run one at a time per slot.")
        XCTAssertEqual(ProviderScreenPresentation.nativeMTPLine(off), "Not available for this model.")

        let unsafe = try XCTUnwrap(ProviderEngineStatus.decode(status: [
            "continuous_batching": ["mode": "On Air <script>", "active": "yes"],
        ]))
        XCTAssertNil(unsafe.continuousBatchingMode, "free text is never rendered")
        XCTAssertNil(unsafe.continuousBatchingActive)

        let unknown = try XCTUnwrap(ProviderEngineStatus.decode(status: [
            "continuous_batching": ["mode": "turbo", "active": false],
            "native_mtp": ["supported": true, "enabled": true, "mode": "hyper"],
        ]))
        XCTAssertNil(ProviderScreenPresentation.continuousBatchingLine(unknown), "an unknown CB mode is not shown as a known state")
        XCTAssertNil(ProviderScreenPresentation.nativeMTPLine(unknown), "an unknown MTP mode is not shown as a known state")
    }

    func testProviderScreenShowsReportedValuesOnlyAndPauseMatchesState() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.advertisedMaxConcurrency = 1
        let strings = ProviderScreenPresentation.screenStrings(snapshot)
        XCTAssertFalse(strings.contains { $0.hasPrefix("Continuous batching") }, "absent CB state is omitted")
        XCTAssertFalse(strings.contains { $0.contains("0 queued") })
        XCTAssertTrue(strings.contains("POST /v1/chat/completions"))
        XCTAssertEqual(ProviderScreenPresentation.pauseAction(snapshot), .pause)
        snapshot.state = .paused
        XCTAssertEqual(ProviderScreenPresentation.pauseAction(snapshot), .resume)
        snapshot.state = .idle
        XCTAssertEqual(ProviderScreenPresentation.pauseAction(snapshot), .none)
        print("MALIBU_PROVIDER_RENDER_BEGIN\n" + strings.joined(separator: "\n") + "\nMALIBU_PROVIDER_RENDER_END")
    }

    // MARK: Diagnostics and Settings

    func testDiagnosticsLogFilterCollapsesIdlePrewarmNoise() {
        let lines = [
            #"{"event":"idle_prewarm_skipped","reason":"not_idle_yet"}"#,
            #"{"event":"idle_prewarm_skipped","reason":"not_idle_yet"}"#,
            "event=cb_self_check action=applied",
            "coordinator join failed: timeout",
        ]
        let all = DiagnosticsPresentation.filteredLog(lines, filter: .all)
        XCTAssertEqual(all.lines, ["event=cb_self_check action=applied", "coordinator join failed: timeout"])
        XCTAssertEqual(all.hiddenIdlePrewarm, 2)
        XCTAssertEqual(DiagnosticsPresentation.hiddenLine(2), "2 idle warm-up lines hidden.")
        XCTAssertNil(DiagnosticsPresentation.hiddenLine(0))
        XCTAssertEqual(DiagnosticsPresentation.filteredLog(lines, filter: .problems).lines, ["coordinator join failed: timeout"])
    }

    func testDiagnosticsAlwaysOffersExportAndResetAndNamesNoFindingsHonestly() {
        let strings = DiagnosticsPresentation.screenStrings(.empty, appVersion: "1.8.256")
        XCTAssertTrue(strings.contains(DashboardCopy.exportDiagnosticsTitle))
        XCTAssertTrue(strings.contains(DashboardCopy.resetProviderTitle))
        XCTAssertTrue(strings.contains(DiagnosticsPresentation.noFindings))
        XCTAssertTrue(strings.contains("Malibu app: 1.8.256"))
        print("MALIBU_DIAGNOSTICS_RENDER_BEGIN\n" + strings.joined(separator: "\n") + "\nMALIBU_DIAGNOSTICS_RENDER_END")
    }

    @MainActor
    func testSettingsHostsWalletStartupUpdatesAndAbout() {
        var snapshot = AgentSnapshot.empty
        snapshot.localProviderID = "provider"
        let strings = SettingsPresentation.screenStrings(snapshot, appVersion: "1.8.256")
        for needle in ["Payout wallet", "Invites", "Startup & Dock", "Open Malibu at login", "Provider software", "About", "Malibu app: 1.8.256"] {
            XCTAssertTrue(strings.contains(needle), "missing \(needle) in \(strings)")
        }
        XCTAssertFalse(SettingsPresentation.screenStrings(.empty, appVersion: "x").contains("Invites"))
        print("MALIBU_SETTINGS_RENDER_BEGIN\n" + strings.joined(separator: "\n") + "\nMALIBU_SETTINGS_RENDER_END")
    }

    func testPrintsDashboardRenderWithModelCard() throws {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.currentModelID = "qwen3-8b"
        snapshot.thermalState = .nominal
        snapshot.advertisedMaxConcurrency = 1
        let strings = DashboardCopy.defaultPublicStrings(
            snapshot,
            listState: .ready,
            rows: [try Self.row(key: "qwen3-8b", isCurrent: true)]
        )
        assertNoForbiddenCopy(strings)
        print("MALIBU_SHELL_DASHBOARD_RENDER_BEGIN\n" + strings.joined(separator: "\n") + "\nMALIBU_SHELL_DASHBOARD_RENDER_END")
    }

    // MARK: Fixtures

    /// Expected copy with "§" standing for this locale's decimal separator.
    private func d(_ text: String) -> String {
        text.replacingOccurrences(of: "§", with: Locale.current.decimalSeparator ?? ".")
    }

    /// SPEC-044-R004 forbidden earnings-claim copy.
    private func assertNoForbiddenCopy(_ strings: [String], file: StaticString = #filePath, line: UInt = #line) {
        let text = strings.joined(separator: "\n").lowercased()
        for phrase in [
            "per day", "/day", "per hour", "/hour", "per month", "/month", "per week", "daily revenue", "hourly pay",
            "will pay", "potential earnings", "estimated daily", "up to $", "average payout", "projected return",
            "higher-paying", "guaranteed", " earns ",
        ] {
            XCTAssertFalse(text.contains(phrase), "forbidden copy \"\(phrase)\" in:\n\(text)", file: file, line: line)
        }
    }

    static let timestamp: String = {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }()

    static func row(
        key: String,
        isCurrent: Bool = false,
        fit: String = "fits",
        weightsLocal: Bool = true,
        runtimeState: String? = nil,
        estimatedGB: Double = 4.0,
        completion: Double = 0.36,
        demandRank: Int = 7,
        switchable: Bool = false,
        economicsState: String = "trusted",
        catalogPermitted: Bool = true,
        supplyDeficit: Double = 1.5
    ) throws -> MalibuModelRow {
        let json = rowJSON(
            key: key, isCurrent: isCurrent, fit: fit, weightsLocal: weightsLocal, runtimeState: runtimeState,
            estimatedGB: estimatedGB, completion: completion, demandRank: demandRank, switchable: switchable,
            economicsState: economicsState, catalogPermitted: catalogPermitted, supplyDeficit: supplyDeficit
        )
        let decoded = try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.Row.self, from: Data(json.utf8))
        return try XCTUnwrap(MalibuModelRow(economics: decoded, currentModelID: nil, warmSwapAvailable: true))
    }

    static func rowJSON(
        key: String,
        isCurrent: Bool = false,
        fit: String = "fits",
        weightsLocal: Bool = true,
        runtimeState: String? = nil,
        estimatedGB: Double = 4.0,
        completion: Double = 0.36,
        demandRank: Int = 7,
        switchable: Bool = false,
        economicsState: String = "trusted",
        catalogPermitted: Bool = true,
        supplyDeficit: Double = 1.5
    ) -> String {
        let unavailable = #"{"available":false,"requires_confirmation":false,"transaction_kind":null,"transaction_id":null,"action_timeout_seconds":null,"estimated_bytes":null,"unavailable_reason":"action_unavailable"}"#
        let switchAction = switchable
            ? #"{"available":true,"requires_confirmation":true,"transaction_kind":"switch_model","transaction_id":"c23c5d4c-3e4f-47ac-b72d-7f8f172747a0","action_timeout_seconds":120,"estimated_bytes":null,"unavailable_reason":null}"#
            : unavailable
        let state = runtimeState ?? (isCurrent ? "current" : (switchable ? "ready" : "catalog"))
        return """
        {"model_key":"\(key)","served_model_id":"\(key)","display_model_id":"\(key)","action_model_id":"\(key)","is_current":\(isCurrent),"weights_present_locally":\(weightsLocal),"runtime_state":"\(state)","estimated_gb":\(estimatedGB),"fit":"\(fit)","disabled_reason":null,"warning_codes":["admission_state_not_settlement_capable"],"admission":{"state":"catalog_priced","source":"coordinator","coordinator_event_id":"event-1","state_observed_at":"\(timestamp)","catalog_economics_permitted":\(catalogPermitted),"settlement_capable":false},"provider_guidance":{"state_label_key":"byom.admission.catalog_priced","state_meaning_key":"byom.admission.not_earning","next_action":"withdraw","transition_reason_code":null,"earning_path_class":"not_earning_yet_catalog_or_receipt_path_exists"},"rate_card_version":"rates-v1","rate_card_generated_at":"\(timestamp)","rate_card_key":"\(key)","rate_source":"live_signed","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"provider_share_bps":9000,"provider_prompt_payout_usd_per_million_tokens":0.18,"provider_completion_payout_usd_per_million_tokens":\(completion),"economics_state":"\(economicsState)","demand_rank":\(demandRank),"demand_weight":0.65,"ready_provider_count":4,"supply_deficit_score":\(supplyDeficit),"switch":\(switchAction),"prepare":\(unavailable),"evaluate":\(unavailable),"adopt_recommendation":\(unavailable),"cleanup_staging":\(unavailable)}
        """
    }

    static func browseJSON(
        schema: String = "models_browse.v1",
        modelID: String = "mlx-community/Qwen3-8B-4bit",
        fit: String = "fits",
        actionable: Bool = false,
        actionModelID: String = "null",
        extraRowKey: Bool = false,
        extraRootKey: Bool = false
    ) -> String {
        """
        {\(extraRootKey ? #""earnable":true,"# : "")"schema_version":"\(schema)","generated_at":"2026-10-18T00:00:00Z","source":"huggingface_mlx_community","query":"qwen","limit":30,"fits_only":false,"max_gb":null,"ram_gb":32,"rows":[{"model_id":"\(modelID)","display_id":"\(modelID)","action_model_id":\(actionModelID),"source":"huggingface_mlx_community","fit":"\(fit)","estimated_gb":4.6,"actionable":\(actionable)\(extraRowKey ? #","earnable":true"# : "")}]}
        """
    }
}
