import XCTest
@testable import MacProviderCore

/// Issue #2084 slice 5: the head's bounded replay buffer (SPEC-051-R022).
final class ShardReplayBufferTests: XCTestCase {
    private func activation(request: UInt64, step: UInt32, bytes: Int = 8, flags: ShardFrameFlags = []) -> ShardStageFrame {
        ShardStageFrame(
            header: ShardStageFrameHeader(
                kind: .activation, dtype: .float32, groupEpoch: 1, requestID: request, tokenStep: step,
                shape: [1, UInt32(bytes / 4), 1], flags: flags),
            payload: Data(repeating: UInt8(step), count: bytes))
    }

    func testReplayMarksDeliveredStepsFillOnlyAndKeepsTheNextOne() throws {
        var buffer = ShardReplayBuffer(capacityBytes: 1024)
        buffer.append(activation(request: 2, step: 0, flags: .fillOnly))  // prefill chunk 1
        buffer.append(activation(request: 2, step: 0))                    // last prefill chunk -> token 0
        buffer.append(activation(request: 2, step: 1))                    // token 0 -> token 1
        buffer.append(activation(request: 2, step: 2))                    // token 1 -> token 2 (in flight)
        let plan = try buffer.replayPlan(requestID: 2, deliveredTokens: 2)
        XCTAssertEqual(plan.map(\.header.tokenStep), [0, 0, 1, 2])
        XCTAssertEqual(plan.map { $0.header.flags.contains(.fillOnly) }, [true, true, true, false])
        XCTAssertEqual(plan.map(\.payload), [Data(repeating: 0, count: 8), Data(repeating: 0, count: 8),
                                             Data(repeating: 1, count: 8), Data(repeating: 2, count: 8)])
        // Lost during prefill, nothing delivered: the last chunk asks for token 0 again.
        var prefilling = ShardReplayBuffer(capacityBytes: 1024)
        prefilling.append(activation(request: 6, step: 0, flags: .fillOnly))
        prefilling.append(activation(request: 6, step: 0))
        XCTAssertEqual(try prefilling.replayPlan(requestID: 6, deliveredTokens: 0).map { $0.header.flags.contains(.fillOnly) }, [true, false])
        XCTAssertThrowsError(try buffer.replayPlan(requestID: 2, deliveredTokens: 1)) { error in
            XCTAssertEqual(error as? ShardReplayError, .frameAhead(requestID: 2, tokenStep: 2, delivered: 1))
        }
    }

    func testCapacityIsBoundedAndOverflowMakesARequestNotReplayable() {
        var buffer = ShardReplayBuffer(capacityBytes: 20)
        buffer.append(activation(request: 2, step: 0))
        buffer.append(activation(request: 4, step: 0))
        XCTAssertEqual(buffer.usedBytes, 16)
        buffer.append(activation(request: 2, step: 1))
        XCTAssertFalse(buffer.isReplayable(2))
        XCTAssertTrue(buffer.isReplayable(4))
        XCTAssertEqual(buffer.usedBytes, 8, "the overflowed request's frames are released")
        buffer.append(activation(request: 2, step: 2))
        XCTAssertEqual(buffer.usedBytes, 8, "an overflowed request is not buffered again")
        XCTAssertEqual(buffer.requestIDs, [2, 4])
        XCTAssertThrowsError(try buffer.replayPlan(requestID: 2, deliveredTokens: 2)) { error in
            XCTAssertEqual(error as? ShardReplayError, .notReplayable(requestID: 2))
        }
        buffer.remove(requestID: 2)
        buffer.remove(requestID: 4)
        XCTAssertEqual(buffer.usedBytes, 0)
        XCTAssertEqual(buffer.requestIDs, [])
    }

    func testControlFramesReplayAsSentBeforeTheActivations() throws {
        var buffer = ShardReplayBuffer(capacityBytes: 1024)
        let control = ShardStageFrame(
            header: ShardStageFrameHeader(kind: .control, groupEpoch: 1, requestID: 3),
            payload: Data(#"{"op":"open","temperature":0,"top_p":1}"#.utf8))
        buffer.append(control)
        buffer.append(activation(request: 3, step: 0))
        buffer.append(activation(request: 3, step: 1))
        let plan = try buffer.replayPlan(requestID: 3, deliveredTokens: 1)
        XCTAssertEqual(plan.map(\.header.kind), [.control, .activation, .activation])
        XCTAssertEqual(plan[0], control, "a control frame is never flagged fill-only")
        XCTAssertEqual(plan.map { $0.header.flags.contains(.fillOnly) }, [false, true, false])
        for frame in plan { XCTAssertNoThrow(try ShardStageFrameCodec.encode(frame)) }
    }
}
