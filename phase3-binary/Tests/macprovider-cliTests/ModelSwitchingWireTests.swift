import Darwin
import XCTest
@testable import macprovider_cli

final class ModelSwitchingWireTests: XCTestCase {
    func testPrintJSONWritesLineTerminatedFrameDirectlyToStdout() throws {
        let pipeFDs = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { pipeFDs.deallocate() }
        XCTAssertEqual(pipe(pipeFDs), 0)
        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]
        let originalStdout = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(originalStdout, 0)
        var writeFDOpen = true
        defer {
            close(readFD)
            if writeFDOpen {
                close(writeFD)
            }
            close(originalStdout)
        }

        XCTAssertEqual(dup2(writeFD, STDOUT_FILENO), STDOUT_FILENO)
        defer {
            _ = dup2(originalStdout, STDOUT_FILENO)
        }

        try ModelSwitchingWireCodec.printJSON(ModelRecommendationCheckEventWire(
            type: "accepted",
            checkID: "check-1",
            candidateModelID: nil,
            isolatedCacheRoot: nil,
            stagingOwner: "cli",
            phase: nil,
            elapsedMS: 0,
            cancellable: false,
            downloadBytesWritten: nil,
            downloadBytesTotal: nil,
            reason: nil,
            stagingDiscarded: nil,
            installedOnly: true
        ))

        XCTAssertEqual(dup2(originalStdout, STDOUT_FILENO), STDOUT_FILENO)
        close(writeFD)
        writeFDOpen = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(readFD, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        let output = String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
        XCTAssertTrue(output.hasSuffix("\n"), output)
        XCTAssertTrue(output.contains(#""schema_version":"model_recommendation_check_event.v1""#), output)
    }

    func testActionIDsUseTheSupportedModelLengthAndControlCharacterBoundary() {
        XCTAssertTrue(ModelSwitchingWireCodec.safeID(String(repeating: "a", count: 256)))
        XCTAssertFalse(ModelSwitchingWireCodec.safeID(String(repeating: "a", count: 257)))
        XCTAssertFalse(ModelSwitchingWireCodec.safeID("model\nname"))
        XCTAssertFalse(ModelSwitchingWireCodec.safeID("model\u{009B}name"))
    }

    func testModelListWireUsesStableSnakeCaseSchema() throws {
        let wire = ModelsListWire(
            generatedAt: "2026-08-08T00:00:00.000Z",
            source: "control_socket",
            warmSwapAvailable: true,
            currentModelID: "old-model",
            rows: [ModelsListWire.Row(
                modelID: "old-model",
                displayID: "old-model",
                actionModelID: "old-model",
                state: "warm",
                weightsPresentLocally: true,
                source: "status_response",
                fit: "fits",
                estimatedGB: 4
            )]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(wire).utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? String, "models_list.v1")
        XCTAssertEqual(object["warm_swap_available"] as? Bool, true)
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["weights_present_locally"] as? Bool, true)
        XCTAssertEqual(rows.first?["action_model_id"] as? String, "old-model")
    }

    func testNullableListFieldsArePresentAsNull() throws {
        let wire = ModelsListWire(
            generatedAt: "2026-08-08T00:00:00.000Z",
            source: "config_fallback",
            warmSwapAvailable: false,
            currentModelID: nil,
            rows: [ModelsListWire.Row(
                modelID: "org/model",
                displayID: "org/model",
                actionModelID: "org/model",
                state: "idle",
                weightsPresentLocally: false,
                source: "config_fallback",
                fit: nil,
                estimatedGB: nil
            )]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(wire).utf8)) as? [String: Any]
        )
        XCTAssertTrue(object.keys.contains("current_model_id"))
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.first?.keys.contains("fit") == true)
        XCTAssertTrue(rows.first?.keys.contains("estimated_gb") == true)
    }

    func testBrowseContractAlwaysIncludesAdvisoryNulls() throws {
        let wire = ModelsBrowseWire(
            generatedAt: "2026-08-08T00:00:00.000Z",
            query: nil,
            limit: 30,
            fitsOnly: false,
            maxGB: nil,
            ramGB: 16,
            rows: [ModelsBrowseWire.Row(
                modelID: "mlx-community/model",
                displayID: "mlx-community/model",
                actionModelID: nil,
                source: "huggingface_mlx_community",
                fit: "unknown",
                estimatedGB: nil,
                actionable: false
            )]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(wire).utf8)) as? [String: Any]
        )
        XCTAssertTrue(object.keys.contains("query"))
        XCTAssertTrue(object.keys.contains("max_gb"))
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.first?.keys.contains("action_model_id") == true)
        XCTAssertTrue(rows.first?.keys.contains("estimated_gb") == true)
    }

    func testRecommendationCheckAndAdoptionFramesUseExpectedSchemas() throws {
        let check = ModelRecommendationCheckEventWire(
            type: "accepted",
            checkID: "check-1",
            candidateModelID: "hf/model",
            isolatedCacheRoot: "redacted",
            stagingOwner: "cli",
            phase: nil,
            elapsedMS: 0,
            cancellable: false,
            downloadBytesWritten: nil,
            downloadBytesTotal: nil,
            reason: nil,
            stagingDiscarded: nil,
            installedOnly: true
        )
        let checkObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(check).utf8)) as? [String: Any]
        )
        XCTAssertEqual(checkObject["schema_version"] as? String, "model_recommendation_check_event.v1")
        XCTAssertEqual(checkObject["check_id"] as? String, "check-1")
        XCTAssertEqual(checkObject["installed_only"] as? Bool, true)
        XCTAssertEqual(checkObject["cancellable"] as? Bool, false)

        let completed = ModelRecommendationCheckEventWire(
            type: "completed",
            checkID: "check-1",
            candidateModelID: "hf/model",
            isolatedCacheRoot: nil,
            stagingOwner: nil,
            phase: "completed",
            elapsedMS: 2,
            cancellable: false,
            downloadBytesWritten: nil,
            downloadBytesTotal: nil,
            reason: nil,
            stagingDiscarded: true,
            installedOnly: true
        )
        let completedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(completed).utf8)) as? [String: Any]
        )
        XCTAssertEqual(completedObject["schema_version"] as? String, "model_recommendation_check_event.v1")
        XCTAssertEqual(completedObject["type"] as? String, "completed")
        XCTAssertEqual(completedObject["phase"] as? String, "completed")
        XCTAssertEqual(completedObject["staging_discarded"] as? Bool, true)

        let adoption = ModelAdoptionEventWire(
            type: "failed",
            transactionID: "tx-1",
            targetModelID: "hf/model",
            fromModelID: "hf/current",
            phase: "switch_loading",
            elapsedMS: 1,
            cancellable: false,
            downloadBytesWritten: nil,
            downloadBytesTotal: nil,
            reason: "switch_failed",
            rollbackState: "rolled_back",
            incumbentModelID: "hf/current",
            configSHA256: nil,
            backupPath: nil
        )
        let adoptionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(adoption).utf8)) as? [String: Any]
        )
        XCTAssertEqual(adoptionObject["schema_version"] as? String, "model_adoption_event.v1")
        XCTAssertEqual(adoptionObject["transaction_id"] as? String, "tx-1")
        XCTAssertEqual(adoptionObject["rollback_state"] as? String, "rolled_back")
    }
}
