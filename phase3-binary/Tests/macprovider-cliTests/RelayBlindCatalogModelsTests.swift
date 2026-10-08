import Foundation
import XCTest
@testable import macprovider_cli

final class RelayBlindCatalogModelsTests: XCTestCase {
    private let catalogKey = "qwen/qwen3.6-35b-a3b"
    private let artifactID = "mlx-community/Qwen3.6-35B-A3B-4bit"

    private func catalog() throws -> CandidateCatalog {
        try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(
            Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        )
    }

    func testPublishedQwenNamesPreserveProviderWireIdentity() throws {
        let signed = try catalog()
        XCTAssertEqual(RelayBlindCatalogModels.names(artifactID, catalog: signed), [artifactID, catalogKey])
        XCTAssertEqual(RelayBlindCatalogModels.names(catalogKey, catalog: signed), [catalogKey, artifactID])
        XCTAssertEqual(modelIDAliasList(" \(artifactID)\n"), [artifactID, catalogKey])
        XCTAssertEqual(modelIDAliasList(nil), [])
        XCTAssertEqual(modelIDAliasList(" \n"), [])
    }

    func testNoExpansionForUnknownOrMerelyBillingEquivalentNames() throws {
        let signed = try catalog()
        for model in ["qwen3.6-35b-a3b", "mlx-community/Qwen3.6-35B-A3B-8bit", "pool:my-model"] {
            XCTAssertEqual(RelayBlindCatalogModels.names(model, catalog: signed), [model])
        }
        XCTAssertEqual(RelayBlindCatalogModels.names(artifactID, catalog: nil), [artifactID])
    }

    func testAmbiguousAndUnpinnedRowsDoNotExpandScope() throws {
        var signed = try catalog()
        let row = try XCTUnwrap(signed.rows[catalogKey])
        signed.rows["other/row"] = row
        XCTAssertEqual(RelayBlindCatalogModels.names(artifactID, catalog: signed), [artifactID])
        signed.rows.removeValue(forKey: "other/row")
        signed.rows[catalogKey]?.modelRevision = nil
        XCTAssertEqual(RelayBlindCatalogModels.names(artifactID, catalog: signed), [artifactID])
        signed.rows[catalogKey]?.modelRevision = row.modelRevision
        signed.rows[catalogKey]?.modelSHA256 = "invalid"
        XCTAssertEqual(RelayBlindCatalogModels.names(artifactID, catalog: signed), [artifactID])
    }

    func testBothNamesAreActuallySignedAsSeparateKeyScopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = try RelayBlindKeyManager(directory: root, models: RelayBlindCatalogModels.names(artifactID))
        let records = try keys.currentRecords()
        XCTAssertEqual(Set(records.flatMap(\.models)), Set([catalogKey, artifactID]))
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.models.count == 1 })
        XCTAssertEqual(Set(records.map(\.kid)).count, 2)
    }

    func testCounterpartCollisionCannotCrossCatalogRows() throws {
        var signed = try catalog()
        var conflicting = try XCTUnwrap(signed.rows[catalogKey])
        conflicting.modelID = catalogKey
        signed.rows["other/row"] = conflicting
        XCTAssertEqual(RelayBlindCatalogModels.names(artifactID, catalog: signed), [artifactID])
    }
}
