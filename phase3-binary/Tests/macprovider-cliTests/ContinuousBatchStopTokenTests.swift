import MLXLMCommon
@testable import macprovider_cli
import XCTest

final class ContinuousBatchStopTokenTests: XCTestCase {
    func testTrailingModelStopIsDroppedOnlyWhenTheRowStoppedOnIt() {
        let stops: Set<Int> = [151645, 151643]

        XCTAssertEqual(
            ModelRuntime.droppingTrailingModelStop([10, 11, 151645], terminalStatus: .stop, modelStopTokenIDs: stops),
            [10, 11],
            "an end-of-turn token ends the row and is neither shown nor billed, as on the serial path"
        )
        XCTAssertEqual(
            ModelRuntime.droppingTrailingModelStop([10, 11, 12], terminalStatus: .stop, modelStopTokenIDs: stops),
            [10, 11, 12],
            "a buyer stop sequence keeps the existing accounting"
        )
        XCTAssertEqual(
            ModelRuntime.droppingTrailingModelStop([10, 151645], terminalStatus: .length, modelStopTokenIDs: stops),
            [10, 151645],
            "a length-terminated row did not stop on the model token"
        )
        XCTAssertEqual(
            ModelRuntime.droppingTrailingModelStop([], terminalStatus: .stop, modelStopTokenIDs: stops),
            []
        )
    }

    func testSerialHybridCacheIsNotPublishedAfterNaturalModelStop() {
        XCTAssertFalse(
            ModelRuntime.serialHybridCacheCanPublishTerminalCheckpoint(
                cache: [MambaCache()],
                terminalModelStopStripped: true
            ),
            "MLX advances recurrent state through EOS before returning; the canonical cache drops EOS"
        )
        XCTAssertTrue(
            ModelRuntime.serialHybridCacheCanPublishTerminalCheckpoint(
                cache: [MambaCache()],
                terminalModelStopStripped: false
            )
        )
        XCTAssertTrue(
            ModelRuntime.serialHybridCacheCanPublishTerminalCheckpoint(
                cache: [KVCacheSimple()],
                terminalModelStopStripped: true
            )
        )
    }

    func testSerialTerminalModelStopIgnoresBuyerFinishReasonRewrites() {
        XCTAssertTrue(ModelRuntime.serialTerminalModelStopStripped(
            rawLengthFinish: false,
            hitStop: false,
            parsedHitStop: false,
            harmonyTerminalFinish: false,
            stoppedBySerialToolCall: false
        ))
        XCTAssertFalse(ModelRuntime.serialTerminalModelStopStripped(
            rawLengthFinish: true,
            hitStop: false,
            parsedHitStop: false,
            harmonyTerminalFinish: false,
            stoppedBySerialToolCall: false
        ))
        XCTAssertFalse(ModelRuntime.serialTerminalModelStopStripped(
            rawLengthFinish: false,
            hitStop: false,
            parsedHitStop: false,
            harmonyTerminalFinish: false,
            stoppedBySerialToolCall: true
        ))
        XCTAssertFalse(ModelRuntime.serialTerminalModelStopStripped(
            rawLengthFinish: false,
            hitStop: true,
            parsedHitStop: false,
            harmonyTerminalFinish: false,
            stoppedBySerialToolCall: false
        ))
    }
}
