import Foundation
@testable import macprovider_cli
import XCTest

/// Issue #2341: the `served_path` member of the relay `complete` end frame.
final class ServedPathTests: XCTestCase {
    private func completion(
        servedPath: ServedPath?,
        disposition: ContinuousBatchSettlementDisposition = .eligibleOwner,
        content: String = "ok"
    ) -> CompletionResult {
        CompletionResult(
            content: content,
            finishReason: "stop",
            promptTokens: 3,
            completionTokens: 2,
            settlementDisposition: disposition,
            servedPath: servedPath
        )
    }

    private func endFrame(
        _ completion: CompletionResult,
        privacySealed: Bool = false,
        relayBlind: Bool = false
    ) -> [String: Any] {
        var frame: [String: Any] = ["type": "inference_response_end", "status": "complete", "usage": [:] as [String: Any]]
        InferenceRelay.attachServedPath(&frame, completion: completion, privacySealed: privacySealed, relayBlind: relayBlind)
        return frame
    }

    func testPathDecisionTable() {
        // Serial: an MLX completion that no scheduler row labelled.
        XCTAssertEqual(ModelRuntime.servedPathOrSerial(completion(servedPath: nil)), ServedPath(path: .serial, rows: 1))
        // CB with no native-MTP step.
        XCTAssertEqual(
            ServedPath.continuousBatching(decodeSteps: 10, nativeMTPSteps: 0, activeRowSum: 10).path,
            .continuousBatching
        )
        // 49% of the row's decode steps proposed drafts: still batched; 50%: native MTP.
        XCTAssertEqual(
            ServedPath.continuousBatching(decodeSteps: 100, nativeMTPSteps: 49, activeRowSum: 100).path,
            .continuousBatching
        )
        XCTAssertEqual(
            ServedPath.continuousBatching(decodeSteps: 100, nativeMTPSteps: 50, activeRowSum: 100).path,
            .nativeMTP
        )
        XCTAssertEqual(
            ServedPath.continuousBatching(decodeSteps: 3, nativeMTPSteps: 1, activeRowSum: 3).path,
            .continuousBatching
        )
        XCTAssertEqual(
            ServedPath.continuousBatching(decodeSteps: 3, nativeMTPSteps: 2, activeRowSum: 3).path,
            .nativeMTP
        )
        // A batched row keeps its own label through the runtime entry.
        let batched = ServedPath(path: .nativeMTP, rows: 4)
        XCTAssertEqual(ModelRuntime.servedPathOrSerial(completion(servedPath: batched)), batched)
        // Shard group.
        XCTAssertEqual(ServedPath.shardGroup, ServedPath(path: .shardGroup, rows: 1))
        XCTAssertEqual(endFrame(completion(servedPath: .shardGroup))["served_path"] as? NSDictionary,
                       ["path": "shard_group", "rows": 1] as NSDictionary)
        // Replay: no member, even when the runtime entry sees it.
        let replay = completion(servedPath: nil, disposition: .nonSettlingReplay)
        XCTAssertNil(ModelRuntime.servedPathOrSerial(replay))
        XCTAssertNil(ModelRuntime.servedPathOrSerial(completion(servedPath: batched, disposition: .nonSettlingReplay)))
        XCTAssertNil(endFrame(replay)["served_path"])
        // Privacy-class and relay-blind dispatch: no member.
        XCTAssertNil(endFrame(completion(servedPath: batched), privacySealed: true)["served_path"])
        XCTAssertNil(endFrame(completion(servedPath: batched), relayBlind: true)["served_path"])
        // Loopback runtimes never set a served path: no member.
        XCTAssertNil(endFrame(completion(servedPath: nil))["served_path"])
    }

    func testRowMeanRoundsToNearestAndClamps() {
        XCTAssertEqual(ServedPath.continuousBatching(decodeSteps: 8, nativeMTPSteps: 0, activeRowSum: 8).rows, 1)
        // 4 steps at 4 rows, 4 steps alone: 2.5 rounds up.
        XCTAssertEqual(ServedPath.continuousBatching(decodeSteps: 8, nativeMTPSteps: 0, activeRowSum: 20).rows, 3)
        XCTAssertEqual(ServedPath.continuousBatching(decodeSteps: 10, nativeMTPSteps: 0, activeRowSum: 22).rows, 2)
        XCTAssertEqual(ServedPath.continuousBatching(decodeSteps: 3, nativeMTPSteps: 0, activeRowSum: 8).rows, 3)
        XCTAssertEqual(ServedPath.continuousBatching(decodeSteps: 2, nativeMTPSteps: 0, activeRowSum: 1_000).rows, 256)
        XCTAssertEqual(ServedPath(path: .serial, rows: 0).rows, 1)
        XCTAssertEqual(ServedPath(path: .continuousBatching, rows: 900).rows, 256)
        // Zero decode steps: no division, one row.
        XCTAssertEqual(
            ServedPath.continuousBatching(decodeSteps: 0, nativeMTPSteps: 0, activeRowSum: 0),
            ServedPath(path: .continuousBatching, rows: 1)
        )
    }

    func testEndFrameShape() throws {
        let frame = endFrame(completion(servedPath: ServedPath(path: .nativeMTP, rows: 3)))
        let member = try XCTUnwrap(frame["served_path"] as? [String: Any])
        XCTAssertEqual(Set(member.keys), ["path", "rows"])
        XCTAssertEqual(member["path"] as? String, "native_mtp")
        XCTAssertTrue(member["rows"] is Int)
        XCTAssertNil((frame["usage"] as? [String: Any])?["served_path"])
        let data = try JSONSerialization.data(withJSONObject: member, options: [.sortedKeys])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"path":"native_mtp","rows":3}"#)
        let wireNames: [(ServedPath.Path, String)] = [
            (.serial, "serial"), (.continuousBatching, "continuous_batching"),
            (.nativeMTP, "native_mtp"), (.shardGroup, "shard_group"),
        ]
        for (path, name) in wireNames {
            XCTAssertEqual(ServedPath(path: path, rows: 2).wireObject["path"] as? String, name)
        }
    }

    func testCompletionCopyHelpersPreserveServedPath() {
        let path = ServedPath(path: .continuousBatching, rows: 5)
        let base = completion(servedPath: path)
        XCTAssertEqual(base.withModelHashObservedIfMissing("sha256:abc").servedPath, path)
        XCTAssertEqual(base.withContent("other").servedPath, path)
        XCTAssertEqual(base.withToolCalls([ToolCall(id: "c", functionName: "f", arguments: "{}")]).servedPath, path)
        XCTAssertEqual(base.cancelledPrefixUsage(deliveredContent: "o").servedPath, path)
        let marked = completion(servedPath: path, content: "a" + ControlTextShield.markString + "b")
        XCTAssertEqual(marked.strippingControlTextMarks().servedPath, path)
    }

    func testSchedulerResultCopiesServedPathAndEqualityIgnoresIt() {
        var result = ContinuousBatchSchedulerResult(
            requestID: "r",
            conversationKey: "",
            generatedTokens: [1],
            outputTokens: [1],
            promptTokens: 1,
            completionTokens: 1,
            emittedTokens: 1,
            cachedPromptTokens: 0,
            terminalStatus: .length,
            errorCode: nil,
            snapshot: nil,
            settlementDisposition: .eligibleOwner,
            retainedCache: nil
        )
        let path = ServedPath(path: .nativeMTP, rows: 7)
        result.servedPath = path
        XCTAssertEqual(result.withSettlementDisposition(.notEligible).servedPath, path)
        XCTAssertEqual(result.withRetainedCache(nil).servedPath, path)
        var other = result
        other.servedPath = ServedPath(path: .continuousBatching, rows: 2)
        XCTAssertEqual(result, other)
        other.servedPath = nil
        XCTAssertEqual(result, other)
    }
}
