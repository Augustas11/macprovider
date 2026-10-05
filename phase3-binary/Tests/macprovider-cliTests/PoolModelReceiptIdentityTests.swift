import XCTest
@testable import macprovider_cli

/// SPEC-022-R013.3 (#1816 freeze R1 SECURITY M3): a pool_manifest attempt's
/// receipt identity is the pool-scoped `pool_model_id`, while the relayed
/// body names the provider-local served label carried as
/// `execution_model_id`.
final class PoolModelReceiptIdentityTests: XCTestCase {
    private static func wire(modelID: String, execution: Any?) -> [String: Any] {
        var wire = ReceiptEligibilityFixtures.settlementMetadataWire(
            requestID: "req-pool-model",
            providerID: "provider-a",
            modelID: modelID,
            receiptKeyID: "ed25519-sha256:" + String(repeating: "0", count: 64),
            expectedModelHash: String(repeating: "a", count: 64)
        )
        if let execution {
            wire["execution_model_id"] = execution
        }
        return wire
    }

    func testAbsentExecutionLabelServesTheReceiptIdentity() throws {
        let metadata = try XCTUnwrap(SettlementReceiptMetadata(wire: Self.wire(modelID: "mlx-community/Fixture-Model", execution: nil)))
        XCTAssertNil(metadata.executionModelID)
        XCTAssertEqual(metadata.servedModelID, "mlx-community/Fixture-Model")
    }

    func testPoolModelSignsPoolIDAndServesTheExecutionLabel() throws {
        let poolModelID = "pool/QpsclmzwdJaWJTk3zowcXQ/creator-gguf"
        let metadata = try XCTUnwrap(SettlementReceiptMetadata(wire: Self.wire(modelID: poolModelID, execution: "creator-gguf")))
        XCTAssertEqual(metadata.modelID, poolModelID)
        XCTAssertEqual(metadata.servedModelID, "creator-gguf")
    }

    func testExecutionLabelOutsideAPoolModelIsMalformed() {
        XCTAssertNil(SettlementReceiptMetadata(wire: Self.wire(modelID: "mlx-community/Fixture-Model", execution: "other-model")))
        XCTAssertNil(SettlementReceiptMetadata(wire: Self.wire(modelID: "pool/QpsclmzwdJaWJTk3zowcXQ/x", execution: "")))
        XCTAssertNil(SettlementReceiptMetadata(wire: Self.wire(modelID: "pool/QpsclmzwdJaWJTk3zowcXQ/x", execution: 7)))
    }
}
