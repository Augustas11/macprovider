import Darwin
import XCTest
@testable import Malibu

/// SPEC-044-R015: capability badges and context length on model rows.
final class ModelFactsBadgesTests: XCTestCase {
    /// Appends the R015 keys to a v1 row JSON object.
    private static func withFacts(_ rowJSON: String, _ facts: String) -> String {
        var json = rowJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        json.removeLast()
        return json + "," + facts + "}"
    }

    private static func catalogRow(key: String, facts: String?) throws -> MalibuModelRow {
        let base = ShellScreensTests.catalogOnlyRowJSON(key: key, modelID: "org/\(key)", downloadBytes: 16_000_000_000)
        let json = facts.map { withFacts(base, $0) } ?? base
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(ShellScreensTests.projectionJSON(rows: [json]).utf8)
        )
        return try XCTUnwrap(try document.validated().rowsForMalibu(currentModelID: nil, warmSwapAvailable: true).first)
    }

    private static func decodeRow(_ json: String) throws -> MalibuModelCatalogEconomicsDocument.Row {
        try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.Row.self, from: Data(json.utf8))
    }

    // MARK: Decode

    func testRowsCarryContextAndCapabilitiesFromTheProjection() throws {
        let row = try Self.catalogRow(key: "qwen", facts: #""context_length":262144,"capabilities":["reasoning","tools"]"#)
        XCTAssertEqual(row.contextLength, 262_144)
        XCTAssertEqual(row.capabilities, [.reasoning, .tools])
    }

    func testRowsWithoutFactsStayValidAndShowNothing() throws {
        let row = try Self.catalogRow(key: "qwen", facts: nil)
        XCTAssertNil(row.contextLength)
        XCTAssertEqual(row.capabilities, [])
        XCTAssertNil(MalibuModelFacts.contextLabel(row))
        XCTAssertNil(MalibuModelFacts.summary(row))
    }

    func testNullContextAndEmptyCapabilitiesAreValid() throws {
        let row = try Self.catalogRow(key: "qwen", facts: #""context_length":null,"capabilities":[]"#)
        XCTAssertNil(row.contextLength)
        XCTAssertEqual(row.capabilities, [])
    }

    func testFactsKeysComeInPairs() {
        let base = ShellScreensTests.rowJSON(key: "qwen")
        XCTAssertNoThrow(try Self.decodeRow(base))
        XCTAssertThrowsError(try Self.decodeRow(Self.withFacts(base, #""context_length":131072"#)))
        XCTAssertThrowsError(try Self.decodeRow(Self.withFacts(base, #""capabilities":["tools"]"#)))
    }

    func testContextOutOfRangeIsRejectedAndUnknownCapabilitiesAreDropped() throws {
        let base = ShellScreensTests.rowJSON(key: "qwen")
        XCTAssertThrowsError(try Self.decodeRow(Self.withFacts(base, #""context_length":512,"capabilities":[]"#)))
        XCTAssertThrowsError(try Self.decodeRow(Self.withFacts(base, #""context_length":33554432,"capabilities":[]"#)))
        XCTAssertThrowsError(try Self.decodeRow(Self.withFacts(base, #""context_length":"128K","capabilities":[]"#)))
        let decoded = try Self.decodeRow(Self.withFacts(base, #""context_length":131072,"capabilities":["audio","vision","tools","vision"]"#))
        XCTAssertEqual(decoded.capabilities, ["tools", "vision"])
        XCTAssertThrowsError(try Self.decodeRow(Self.withFacts(base, #""context_length":131072,"capabilities":["tools"],"license":"mit""#)))
    }

    // MARK: Presentation

    func testContextLabelsUseModelCardUnits() {
        XCTAssertEqual(MalibuModelFacts.contextShort(32_768), "32K")
        XCTAssertEqual(MalibuModelFacts.contextShort(40_960), "40K")
        XCTAssertEqual(MalibuModelFacts.contextShort(131_072), "128K")
        XCTAssertEqual(MalibuModelFacts.contextShort(262_144), "256K")
        XCTAssertEqual(MalibuModelFacts.contextShort(1_048_576), "1M")
        XCTAssertEqual(MalibuModelFacts.contextShort(2_097_152), "2M")
        XCTAssertEqual(MalibuModelFacts.contextShort(100_000), "98K")
    }

    func testRowsAndDetailShowBadgesAndContext() throws {
        let row = try Self.catalogRow(key: "qwen", facts: #""context_length":262144,"capabilities":["reasoning","tools"]"#)
        XCTAssertTrue(DiscoverPresentation.rowMeta(row, hostMemoryGB: 64).hasSuffix(" · 256K context"))
        XCTAssertEqual(MalibuModelFacts.badgeTitles(row), ["Reasoning", "Tools"])
        let label = DiscoverPresentation.rowAccessibilityLabel(row, hostMemoryGB: 64)
        XCTAssertTrue(label.contains("Reasoning, Tools"), label)
        XCTAssertTrue(label.contains("256K context"), label)

        let facts = DiscoverPresentation.detailFacts(row, hostMemoryGB: 64)
        let context = try XCTUnwrap(facts.first { $0.label == "Context" })
        XCTAssertTrue(context.value.hasPrefix("256K tokens"), context.value)
        XCTAssertEqual(facts.first { $0.label == "Capabilities" }?.value, "Reasoning · Tools")
        XCTAssertEqual(facts.first?.label, "Memory")

        let strings = DiscoverPresentation.screenStrings(rows: [row], mode: .browse, fitsOnly: false, hostMemoryGB: 64)
        XCTAssertTrue(strings.contains { $0.contains("[Reasoning] [Tools]") }, strings.joined(separator: "\n"))
        XCTAssertTrue(DiscoverPresentation.bestPickLines(row, hostMemoryGB: 64).contains("Tools"))
    }

    func testRowsWithoutFactsKeepTheirExistingLines() throws {
        let row = try Self.catalogRow(key: "qwen", facts: nil)
        XCTAssertFalse(DiscoverPresentation.rowMeta(row, hostMemoryGB: 64).contains("context"))
        let labels = DiscoverPresentation.detailFacts(row, hostMemoryGB: 64).map(\.label)
        XCTAssertFalse(labels.contains("Context"))
        XCTAssertFalse(labels.contains("Capabilities"))
    }

    func testCapabilityFilterKeepsOnlyMatchingRows() throws {
        let reasoning = try Self.catalogRow(key: "qwen", facts: #""context_length":262144,"capabilities":["reasoning","tools"]"#)
        let vision = try Self.catalogRow(key: "vl", facts: #""context_length":32768,"capabilities":["vision"]"#)
        let plain = try Self.catalogRow(key: "plain", facts: #""context_length":131072,"capabilities":[]"#)
        let rows = [reasoning, vision, plain]
        XCTAssertEqual(DiscoverPresentation.filteredRows(rows, search: "", fitsOnly: false).map(\.modelKey), ["qwen", "vl", "plain"])
        XCTAssertEqual(DiscoverPresentation.filteredRows(rows, search: "", fitsOnly: false, capability: .vision).map(\.modelKey), ["vl"])
        XCTAssertEqual(DiscoverPresentation.filteredRows(rows, search: "", fitsOnly: false, capability: .tools).map(\.modelKey), ["qwen"])
        XCTAssertEqual(
            ModelsHubPresentation.discoveryRows(for: .recommended, rows: rows, search: "", fitsOnly: true, sort: .bestMatch, capability: .reasoning)
                .map(\.modelKey),
            ["qwen"]
        )
        XCTAssertTrue(DiscoverPresentation.offersCapabilityFilter(rows))
        XCTAssertFalse(DiscoverPresentation.offersCapabilityFilter([plain, try Self.catalogRow(key: "old", facts: nil)]))
        // A choice made before a refresh without facts stops filtering once
        // the filter is no longer offered.
        XCTAssertEqual(DiscoverPresentation.activeCapability(.vision, rows: rows), .vision)
        XCTAssertNil(DiscoverPresentation.activeCapability(.vision, rows: [plain]))
    }

    func testUnsupportedRowsShowNoFacts() throws {
        // A local_default row with an admission label fails validate(row:)
        // and is demoted to the unsupported variant.
        let bad = Self.withFacts(
            ShellScreensTests.catalogOnlyRowJSON(key: "qwen", modelID: "org/qwen")
                .replacingOccurrences(of: #""state_label_key":"byom.local.not_offered""#,
                                      with: #""state_label_key":"byom.admission.not_offered""#),
            #""context_length":262144,"capabilities":["tools"]"#
        )
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(ShellScreensTests.projectionJSON(rows: [bad]).utf8)
        )
        let row = try XCTUnwrap(try document.validated().rowsForMalibu(currentModelID: nil, warmSwapAvailable: true).first)
        XCTAssertTrue(row.warningCodes.contains("projection_unsupported"))
        XCTAssertNil(row.contextLength)
        XCTAssertEqual(row.capabilities, [])
    }

    func testOnThisMacStringsCarryTheFacts() throws {
        let row = try Self.catalogRow(key: "qwen", facts: #""context_length":262144,"capabilities":["tools"]"#)
        let strings = ModelsPresentation.screenStrings(rows: [row], listState: .ready)
        XCTAssertTrue(strings.contains { $0.contains(" | Tools, 256K context") }, strings.joined(separator: "\n"))
    }

    // MARK: Negotiation

    func testModelFactsFlagIsSentOnlyWhenAdvertised() {
        let with = ModelManagementStore.catalogEconomicsArguments(configPath: "/c", controlSocketPath: "/s", modelFacts: true)
        let without = ModelManagementStore.catalogEconomicsArguments(configPath: "/c", controlSocketPath: "/s", modelFacts: false)
        XCTAssertEqual(with, ["models", "catalog-economics", "--json", "--model-facts", "--config", "/c", "--ctl-socket-path", "/s"])
        XCTAssertEqual(without, ["models", "catalog-economics", "--json", "--config", "/c", "--ctl-socket-path", "/s"])
    }

    func testModelFactsTierNeedsTheCapabilityAndTheFloorVersion() throws {
        let manifest = MalibuModelCapabilityManifest.checkedIn
        let tier = try XCTUnwrap(manifest.tiers[MalibuModelCapabilityManifest.catalogModelFacts])
        XCTAssertTrue(tier.localStatusCapabilities.contains("model_catalog_model_facts_v1"))
        // SPEC-044-R001: generation values live only in their own tier.
        for value in tier.localStatusCapabilities.union(tier.commandSchemas) {
            XCTAssertFalse(value.hasPrefix("model_catalog_economics"), value)
            XCTAssertFalse(value.hasPrefix("models catalog-economics"), value)
        }
        func peer(version: String, capabilities: Set<String>) -> MalibuModelPeerEvidence {
            MalibuModelPeerEvidence(
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
        let all = tier.localStatusCapabilities.union(tier.commandSchemas).union(tier.controlFrameSchemas)
        let facts = MalibuModelCapabilityManifest.catalogModelFacts
        XCTAssertTrue(manifest.supports(facts, peer: peer(version: tier.firstSupportingBinaryVersion, capabilities: all)))
        XCTAssertFalse(manifest.supports(facts, peer: peer(version: "1.8.300", capabilities: all)))
        XCTAssertFalse(manifest.supports(facts, peer: peer(
            version: tier.firstSupportingBinaryVersion,
            capabilities: all.subtracting(["model_catalog_model_facts_v1"])
        )))
    }
}
