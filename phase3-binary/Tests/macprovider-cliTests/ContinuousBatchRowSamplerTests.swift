@testable import macprovider_cli
import MacProviderCore
import MLX
import MLXLMCommon
import XCTest

final class ContinuousBatchRowSamplerTests: XCTestCase {
    override func invokeTest() {
        Device.withDefaultDevice(Device(.cpu)) {
            XCTAssertEqual(Device.defaultDevice().deviceType, .cpu)
            super.invokeTest()
        }
    }

    override class func setUp() {
        super.setUp()
        // Construct directly: Device.cpu resolves Swift's stream defaults first.
        Device.setDefault(device: Device(.cpu))
    }

    // MARK: - Pure seed derivation (no Metal)

    func testRequestSeedIsStablePerRequestIDAndDistinctAcrossIDs() {
        let a = ContinuousBatchRowSampler.requestSeed(requestID: "req-a")
        XCTAssertEqual(a, ContinuousBatchRowSampler.requestSeed(requestID: "req-a"),
                       "a replay of the same request ID must reproduce the same sampling stream")
        let seeds = Set((0 ..< 1000).map { ContinuousBatchRowSampler.requestSeed(requestID: "req-\($0)") })
        XCTAssertEqual(seeds.count, 1000, "concurrent requests must not share a sampler seed")
    }

    func testStepSeedsDoNotRepeatAcrossStepsOrRequests() {
        var seen = Set<UInt64>()
        for request in 0 ..< 64 {
            for step in 0 ..< 256 {
                seen.insert(ContinuousBatchRowSampler.stepSeed(samplerSeed: request, samplerStep: step))
            }
        }
        XCTAssertEqual(seen.count, 64 * 256)
        XCTAssertEqual(
            ContinuousBatchRowSampler.stepSeed(samplerSeed: 7, samplerStep: 3),
            ContinuousBatchRowSampler.stepSeed(samplerSeed: 7, samplerStep: 3)
        )
    }

    func testSupportsOnlyParametersTheSerialPathAccepts() {
        XCTAssertTrue(ContinuousBatchRowSampler.supports(temperature: 0, topP: 1))
        XCTAssertTrue(ContinuousBatchRowSampler.supports(temperature: 0.7, topP: 0.9))
        XCTAssertTrue(ContinuousBatchRowSampler.supports(temperature: 2, topP: 0))
        XCTAssertFalse(ContinuousBatchRowSampler.supports(temperature: -0.1, topP: 1))
        XCTAssertFalse(ContinuousBatchRowSampler.supports(temperature: .nan, topP: 1))
        XCTAssertFalse(ContinuousBatchRowSampler.supports(temperature: 0.7, topP: 1.1))
        XCTAssertFalse(ContinuousBatchRowSampler.supports(temperature: 0.7, topP: .infinity))
    }

    // MARK: - MLX sampling on CPU (still needs the Metal library to load)

    private func requireMetal() throws {
        // Under `swift test` Bundle.main is Xcode's xctest runner; MLX loads
        // the metallib colocated with this test bundle's binary.
        let tests = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(bundleURL: tests.resourceURL, executableURL: tests.executableURL)
        else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private func row(_ temperature: Double, _ topP: Double = 1, seed: Int = 1, step: Int = 0) -> ContinuousBatchRowSampler.Row {
        .init(temperature: temperature, topP: topP, samplerSeed: seed, samplerStep: step)
    }

    func testGreedyRowsMatchArgmaxExactly() throws {
        try requireMetal()
        let logits = MLXArray([0.1, 3.0, 0.2, -1.0, 2.0, 5.0] as [Float]).reshaped([2, 3])
        let tokens = ContinuousBatchRowSampler.sample(logits: logits, rows: [row(0), row(0)]).asArray(Int.self)
        XCTAssertEqual(tokens, [1, 2])
    }

    func testUnconstrainedSamplingPreservesLogitsAndLogProbabilities() throws {
        try requireMetal()
        Device.withDefaultDevice(.cpu) {
            let values: [Float] = [0.25, -1, 3, 0.75, 2, -0.5]
            let logits = MLXArray(values).reshaped([2, 3])
            let before = log(softmax(logits, axis: -1)).asArray(Float.self)
            _ = ContinuousBatchRowSampler.sample(
                logits: logits,
                rows: [row(0), row(0.7, 0.9, seed: 42, step: 3)]
            ).asArray(Int.self)
            XCTAssertEqual(logits.asArray(Float.self), values)
            XCTAssertEqual(log(softmax(logits, axis: -1)).asArray(Float.self), before)
        }
    }

    func testMixedConstrainedRowsAdvanceOnceAndPreserveSeededNeighborsOnCPU() throws {
        try requireMetal()
        try Device.withDefaultDevice(.cpu) {
            for (temperature, topP) in [(0.0, 1.0), (0.7, 0.01), (1.2, 0.9)] {
                let constraint = try GrammarConstraintState(
                    grammar: .literal("ab"),
                    tokens: [0: [97], 1: [98], 2: [120], 3: []], eosTokenIDs: [3]
                )
                // The illegal token wins before masking, even with a tiny nucleus.
                let values: [Float] = [-2, -3, 20, 5, 0.25, 1.25, -0.5, 2]
                let logits = MLXArray(values).reshaped([2, 4])
                let originalLogProbs = log(softmax(logits, axis: -1)).asArray(Float.self)
                for (step, expected) in [0, 1, 3].enumerated() {
                    let neighbor = row(0.8, 0.9, seed: 79, step: step)
                    let alone = ContinuousBatchRowSampler.sample(
                        logits: logits[1..<2], rows: [neighbor]
                    ).asArray(Int.self)
                    let together = ContinuousBatchRowSampler.sample(logits: logits, rows: [
                        .init(temperature: temperature, topP: topP, samplerSeed: 42,
                              samplerStep: step, grammarConstraint: constraint), neighbor
                    ]).asArray(Int.self)
                    XCTAssertEqual(together, [expected, alone[0]])
                    XCTAssertNoThrow(try constraint.validate())
                    XCTAssertEqual(logits.asArray(Float.self), values)
                    XCTAssertEqual(log(softmax(logits, axis: -1)).asArray(Float.self), originalLogProbs)
                }
            }
        }
    }

    func testUnconstrainedSeededTokensMatchSerialOnCPU() throws {
        try requireMetal()
        Device.withDefaultDevice(.cpu) {
            let logits = MLXArray([0.25, -1, 3, 0.75] as [Float]).reshaped([1, 4])
            for (temperature, topP) in [(0.0, 1.0), (0.7, 1.0), (1.2, 0.9)] {
                for step in 0..<8 {
                    let actual = ContinuousBatchRowSampler.sample(
                        logits: logits, rows: [row(temperature, topP, seed: 42, step: step)]
                    ).asArray(Int.self)
                    let expected = GenerateParameters(
                        temperature: Float(temperature), topP: Float(topP),
                        seed: ContinuousBatchRowSampler.stepSeed(samplerSeed: 42, samplerStep: step)
                    ).sampler().sample(logits: logits).asArray(Int.self)
                    XCTAssertEqual(actual, expected)
                }
            }
        }
    }

    func testGrammarRequestCannotEnterNativeMTP() throws {
        let constraint = try GrammarConstraintState(
            grammar: .literal("a"), tokens: [0: [97], 1: []], eosTokenIDs: [1]
        )
        let request = ContinuousBatchSchedulerRequest(
            id: "grammar-native", conversationKey: "", promptTokens: [0], maxOutputTokens: 2,
            grammarConstraint: constraint, decodePath: .nativeMTP, nativeMTPIntegrityProbe: true
        )
        XCTAssertEqual(request.decodePath, .ordinary)
        XCTAssertFalse(request.nativeMTPIntegrityProbe)
        XCTAssertNil(request.nativeMTPTupleFence)
        XCTAssertTrue(request.grammarConstraint === constraint)
    }

    /// A sampled row draws exactly what the serial path's own sampler draws for
    /// the same parameters and seed: same algorithm, row-local randomness.
    func testSampledRowEqualsSerialSamplerWithTheSameSeed() throws {
        try requireMetal()
        let vocab = 32
        let values = (0 ..< vocab).map { Float(sin(Double($0)) * 3) }
        let logits = MLXArray(values).reshaped([1, vocab])
        for (temperature, topP) in [(0.7, 1.0), (1.0, 0.9), (0.3, 0.5)] {
            for step in 0 ..< 20 {
                let batched = ContinuousBatchRowSampler.sample(
                    logits: logits, rows: [row(temperature, topP, seed: 42, step: step)]
                ).asArray(Int.self)
                let serial = GenerateParameters(
                    temperature: Float(temperature),
                    topP: Float(topP),
                    seed: ContinuousBatchRowSampler.stepSeed(samplerSeed: 42, samplerStep: step)
                ).sampler().sample(logits: logits).asArray(Int.self)
                XCTAssertEqual(batched, serial, "t=\(temperature) p=\(topP) step=\(step)")
            }
        }
    }

    /// A row's token depends only on its own logits and seed: the same row
    /// samples the same token whatever its batch neighbours are.
    func testRowTokenIsIndependentOfOtherRows() throws {
        try requireMetal()
        let vocab = 16
        let mine = (0 ..< vocab).map { Float(cos(Double($0))) }
        let other = (0 ..< vocab).map { Float(Double($0) / 4) }
        let alone = ContinuousBatchRowSampler.sample(
            logits: MLXArray(mine).reshaped([1, vocab]), rows: [row(0.9, 0.95, seed: 5, step: 3)]
        ).asArray(Int.self)
        let inBatch = ContinuousBatchRowSampler.sample(
            logits: MLXArray(other + mine + other).reshaped([3, vocab]),
            rows: [row(1.2, seed: 99, step: 0), row(0.9, 0.95, seed: 5, step: 3), row(0)]
        ).asArray(Int.self)
        XCTAssertEqual(inBatch[1], alone[0])
    }

    /// A tiny nucleus leaves only the argmax, so a sampled row must equal greedy.
    func testTinyTopPCollapsesToArgmax() throws {
        try requireMetal()
        let logits = MLXArray([0.1, 4.0, 0.2, 1.0] as [Float]).reshaped([1, 4])
        for step in 0 ..< 10 {
            let token = ContinuousBatchRowSampler.sample(
                logits: logits, rows: [row(1.0, 0.01, seed: step, step: step)]
            ).asArray(Int.self)
            XCTAssertEqual(token, [1])
        }
    }
}
