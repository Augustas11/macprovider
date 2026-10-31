import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-001-R015: a tool call held whole still shows decode progress, and the
/// progress carries no bytes, so the buyer-visible stream is unchanged.
final class HeldToolCallProgressTests: XCTestCase {
    private final class SteppedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_000)

        func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return now
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            now = now.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private struct Run {
        var visible: [String] = []
        var progressSteps: [Int] = []
        var finalCalls: [String] = []
    }

    private let reasoning = "Look it up."
    private let call = "<tool_call>lookup<arg_key>city</arg_key><arg_value>Vilnius, the capital of Lithuania</arg_value>"
        + "<arg_key>units</arg_key><arg_value>metric</arg_value></tool_call>"

    private func run(secondsPerStep: TimeInterval) throws -> Run {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "Jundot/GLM-5.3-Flash-oQ4e-mtp",
            "messages": [["role": "user", "content": "go"]],
            "tools": [["type": "function", "function": [
                "name": "lookup",
                "parameters": ["type": "object", "properties": [
                    "city": ["type": "string"], "units": ["type": "string"],
                ]],
            ]]],
        ]))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .glm, reasoningOpen: true))
        let output = reasoning + "</think>" + call
        let clock = SteppedClock()
        var emitter = SerialStreamingTextEmitter(
            request: request,
            heldProgress: HeldOutputProgress(clock: { clock.read() })
        )
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var result = Run()
        func record(_ chunk: StreamChunk, step: Int) {
            switch chunk {
            case .reasoning(let text): result.visible.append("reasoning:\(text)")
            case .content(let text): result.visible.append("content:\(text)")
            case .toolCallDelta(let delta):
                result.visible.append("tool:\(delta.functionName ?? ""):\(delta.arguments ?? "")")
            case .progress: result.progressSteps.append(step)
            }
        }
        for end in 1...output.count {
            clock.advance(secondsPerStep)
            _ = emitter.step(
                candidate: (String(output.prefix(end)), false),
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: { record($0, step: end) }
            )
        }
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 40, toolCallPrefill: nil
        )
        try emitter.finish(
            finalText: output, parsed: parsed, structuredAccumulator: accumulator, idleState: idle,
            onChunk: { record($0, step: output.count + 1) }
        )
        for delta in try StreamedToolCallArgs().finalDeltas(for: emitter.reconciledToolCalls).flatMap({ $0 }) {
            var stable = delta
            stable.removeValue(forKey: "id")
            let data = try JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys])
            result.finalCalls.append(String(decoding: data, as: UTF8.self))
        }
        return result
    }

    func testHeldToolCallSendsProgressAndLeavesTheCallBytesUnchanged() throws {
        let slow = try run(secondsPerStep: 0.4)
        let fast = try run(secondsPerStep: 0)

        XCTAssertFalse(slow.progressSteps.isEmpty, "a held call generating for seconds must show progress")
        XCTAssertTrue(fast.progressSteps.isEmpty, "a call generated within a second needs no progress")
        // Progress starts only once the call is held, never during reasoning.
        let holdStart = reasoning.count + "</think>".count + 1
        XCTAssertGreaterThan(try XCTUnwrap(slow.progressSteps.first), holdStart)
        // At most one signal per second of decode (0.4 s per step).
        for (earlier, later) in zip(slow.progressSteps, slow.progressSteps.dropFirst()) {
            XCTAssertGreaterThanOrEqual(Double(later - earlier) * 0.4, HeldOutputProgress.interval - 1e-9)
        }
        // Buyer-visible output and the canonical whole call are byte-identical.
        XCTAssertEqual(slow.visible, fast.visible)
        XCTAssertEqual(slow.finalCalls, fast.finalCalls)
        XCTAssertFalse(slow.finalCalls.isEmpty)
        XCTAssertTrue(slow.finalCalls.joined().contains(#"{\"city\":\"Vilnius, the capital of Lithuania\",\"units\":\"metric\"}"#))
    }

    func testRelayBatcherNeverTurnsProgressIntoAFrame() {
        var frames: [String] = []
        let lock = NSLock()
        let batcher = RelayStreamBatcher(
            streamInterval: 1,
            deltaFrame: { delta in "data: \(delta.keys.sorted())\n\n" },
            enqueueFrame: { frame in
                lock.lock()
                frames.append(frame)
                lock.unlock()
                return true
            }
        )
        batcher.accept(.progress)
        batcher.accept(.content("hi"))
        batcher.accept(.progress)
        batcher.flushContent()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(batcher.everyFrameDelivered(sent: 1))
        XCTAssertEqual(batcher.deliveredContent(sent: 1), "hi")
    }

    func testVisibleOutputRestartsTheHoldClock() {
        let clock = SteppedClock()
        let progress = HeldOutputProgress(clock: { clock.read() })
        XCTAssertFalse(progress.heldStep())
        clock.advance(1.5)
        XCTAssertTrue(progress.heldStep())
        clock.advance(0.5)
        XCTAssertFalse(progress.heldStep())
        progress.visibleOutput()
        clock.advance(5)
        XCTAssertFalse(progress.heldStep(), "a new hold starts its own clock")
        clock.advance(1)
        XCTAssertTrue(progress.heldStep())
    }
}
