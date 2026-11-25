import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-044-R015: model facts on catalog-economics rows.
final class ModelFactsTests: XCTestCase {
    func testBakedFactsDecodeAndBindEveryBakedCatalogRow() throws {
        let catalog = try Self.catalog()
        let facts = try ModelFacts.decode(Data(ModelFacts.bakedJSON.utf8))
        XCTAssertEqual(facts, ModelFacts.baked)
        // A catalog row without facts is allowed (SPEC-044-R015 item 2); every
        // fact row whose identity matches its catalog row binds.
        var bound = 0
        for (key, fact) in facts.rows {
            guard let entry = catalog.rows[key],
                  entry.modelID == fact.modelID, entry.modelRevision == fact.modelRevision else { continue }
            let row = try XCTUnwrap(facts.row(forCatalogKey: key, catalog: catalog), key)
            XCTAssertEqual(row, fact, key)
            XCTAssertTrue(ModelFacts.contextLengthRange.contains(row.contextLength), key)
            XCTAssertTrue(Set(row.capabilities).isSubset(of: ModelFacts.capabilityValues), key)
            bound += 1
        }
        XCTAssertGreaterThan(bound, 0)
        let vision = try XCTUnwrap(facts.row(forCatalogKey: "mlx-community/qwen2-vl-2b-instruct-4bit", catalog: catalog))
        XCTAssertEqual(vision.capabilities, ["vision"])
        XCTAssertEqual(vision.contextLength, 32_768)
    }

    /// The shipped copy is the reviewed file, byte for byte; regenerate with
    /// `python3 scripts/model-facts.py generate`.
    func testBakedFactsAreTheReviewedFileBytes() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("catalog/autotune/model-facts.json")
        let reviewed = try String(contentsOf: file, encoding: .utf8)
        // A multi-line literal drops the line break before its closing delimiter.
        XCTAssertTrue(reviewed.hasSuffix("\n"))
        XCTAssertEqual(String(reviewed.dropLast()), ModelFacts.bakedJSON)
    }

    func testFactsApplyOnlyWhileTheCatalogRowIdentityMatches() throws {
        var catalog = try Self.catalog()
        let key = try XCTUnwrap(catalog.rows.keys.sorted().first)
        XCTAssertNotNil(ModelFacts.baked.row(forCatalogKey: key, catalog: catalog))
        XCTAssertNotNil(ModelFacts.baked.row(forCatalogKey: key.uppercased(), catalog: catalog))
        var renamed = catalog
        renamed.rows[key]?.modelID = "other/model"
        XCTAssertNil(ModelFacts.baked.row(forCatalogKey: key, catalog: renamed))
        catalog.rows[key]?.modelRevision = String(repeating: "0", count: 40)
        XCTAssertNil(ModelFacts.baked.row(forCatalogKey: key, catalog: catalog))
        XCTAssertNil(ModelFacts.baked.row(forCatalogKey: "not/in-the-catalog", catalog: catalog))
    }

    func testDefaultEnvelopeCarriesNoFactKeys() throws {
        let rows = try Self.encodedRows(Self.projection())
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertNil(row["context_length"])
            XCTAssertNil(row["capabilities"])
        }
    }

    func testModelFactsFlagAddsBothKeysToEveryRow() throws {
        var catalog = try Self.catalog()
        let projection = try Self.projection()
        let drifted = try XCTUnwrap(projection.rows.map(\.modelKey).sorted().last)
        catalog.rows[drifted]?.modelRevision = String(repeating: "0", count: 40)
        let rows = try Self.encodedRows(projection.withModelFacts(.baked, catalog: catalog))
        XCTAssertEqual(rows.count, projection.rows.count)
        for row in rows {
            let key = try XCTUnwrap(row["model_key"] as? String)
            let capabilities = try XCTUnwrap(row["capabilities"] as? [String], key)
            XCTAssertNotNil(row["context_length"], key)
            if key == drifted {
                XCTAssertTrue(row["context_length"] is NSNull, key)
                XCTAssertEqual(capabilities, [], key)
            } else {
                let facts = try XCTUnwrap(ModelFacts.baked.rows[key], key)
                XCTAssertEqual(row["context_length"] as? Int, facts.contextLength, key)
                XCTAssertEqual(capabilities, facts.capabilities, key)
            }
        }
    }

    func testDecodeRejectsMalformedFacts() throws {
        let valid: [String: Any] = [
            "capabilities": ["reasoning", "tools"],
            "context_length": 131_072,
            "context_length_source": "max_position_embeddings",
            "model_id": "org/model",
            "model_revision": String(repeating: "a", count: 40),
        ]
        XCTAssertNoThrow(try ModelFacts.decode(Self.document(valid)))
        let cases: [(String, [String: Any])] = [
            ("unknown capability", valid.merging(["capabilities": ["audio"]]) { $1 }),
            ("unsorted capabilities", valid.merging(["capabilities": ["tools", "reasoning"]]) { $1 }),
            ("duplicate capability", valid.merging(["capabilities": ["tools", "tools"]]) { $1 }),
            ("boolean context", valid.merging(["context_length": true]) { $1 }),
            ("fractional context", valid.merging(["context_length": 1_024.5]) { $1 }),
            ("context too small", valid.merging(["context_length": 512]) { $1 }),
            ("extra key", valid.merging(["license": "mit"]) { $1 }),
            ("missing key", valid.filter { $0.key != "context_length_source" }),
        ]
        for (name, row) in cases {
            XCTAssertThrowsError(try ModelFacts.decode(Self.document(row)), name)
        }
        let duplicate = Data(#"{"schema_version":"macprovider.model-facts.v1","schema_version":"x","rows":{}}"#.utf8)
        XCTAssertThrowsError(try ModelFacts.decode(duplicate))
        let wrongSchema = Data(#"{"schema_version":"macprovider.model-facts.v2","rows":{}}"#.utf8)
        XCTAssertThrowsError(try ModelFacts.decode(wrongSchema))
    }

    // MARK: Fixtures

    private static func catalog() throws -> CandidateCatalog {
        try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
    }

    private static func document(_ row: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema_version": ModelFacts.schemaVersion,
            "rows": ["org/model": row],
        ])
    }

    /// Catalog-only rows for every baked catalog model.
    private static func projection() throws -> ModelCatalogEconomicsWire {
        let demandBytes = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let candidateBytes = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        return ModelCatalogEconomicsBuilder.makeProjection(
            cliVersion: "test",
            cliBuildCommit: "test",
            processLaunchID: "launch-test",
            projectionSequence: 1,
            currentModelID: nil,
            discovery: BYOMDiscoveryWire(
                generatedAt: "2027-01-15T08:00:00Z",
                cliVersion: "test",
                projectionSequence: 1,
                adapters: [],
                candidates: [],
                warnings: []
            ),
            admissionStatuses: [:],
            demand: AutotuneStaticSelection(
                value: try AutotuneStaticInputs.decodeDemandRank(demandBytes),
                selectedBytes: demandBytes,
                warnings: [],
                usedFallback: false,
                signerKeyID: "test"
            ),
            candidateCatalog: AutotuneStaticSelection(
                value: try catalog(),
                selectedBytes: candidateBytes,
                warnings: [],
                usedFallback: false,
                signerKeyID: "test"
            ),
            rateCard: nil
        )
    }

    private static func encodedRows(_ projection: ModelCatalogEconomicsWire) throws -> [[String: Any]] {
        let encoded = try ModelSwitchingWireCodec.encode(projection)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }
}
