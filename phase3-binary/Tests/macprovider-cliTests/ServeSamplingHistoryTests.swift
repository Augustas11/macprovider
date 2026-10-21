import MLX
import MLXLMCommon
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ServeSamplingHistoryTests: XCTestCase {
    private func requireMetal() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    func testColdAndReusedSuffixProcessorsUseCompletePromptHistory() throws {
        try requireMetal()
        // Token 0 falls outside the 20-token window, while token 1 is repeated.
        let prompt = [0] + Array(repeating: 1, count: 18) + [2, 3]
        let generation = ModelRuntime.serveGenerationConfiguration(
            parameters: GenerateParameters(topK: 20, repetitionPenalty: 2),
            completePromptTokenIDs: prompt)
        XCTAssertNil(generation.parameters.repetitionPenalty)
        XCTAssertEqual(generation.parameters.topK, 20)
        var cold = try XCTUnwrap(generation.components.logitProcessor(parameters: generation.parameters))
        var reused = try XCTUnwrap(generation.components.logitProcessor(parameters: generation.parameters))
        cold.prompt(MLXArray(prompt))
        reused.prompt(MLXArray([3]))
        let logits = MLXArray([Float(8), 8, -8, 4, 6]).reshaped(1, 5)
        let expected: [Float] = [8, 4, -16, 2, 6]
        XCTAssertEqual(cold.process(logits: logits).asArray(Float.self), expected)
        XCTAssertEqual(reused.process(logits: logits).asArray(Float.self), expected)
        // Advancing one request must not advance a second factory instance.
        cold.didSample(token: MLXArray([4]))
        XCTAssertEqual(cold.process(logits: logits).asArray(Float.self), [8, 4, -16, 2, 3])
        XCTAssertEqual(reused.process(logits: logits).asArray(Float.self), expected)
    }

    func testPromptResetAndProcessorCopiesAreIndependent() throws {
        try requireMetal()
        let generation = ModelRuntime.serveGenerationConfiguration(
            parameters: GenerateParameters(repetitionPenalty: 2), completePromptTokenIDs: [1])
        var first = try XCTUnwrap(generation.components.logitProcessor(parameters: generation.parameters))
        first.prompt(MLXArray([1]))
        var copy = first.copy()
        first.didSample(token: MLXArray([2]))
        let logits = MLXArray([Float(8), 8, 8]).reshaped(1, 3)
        XCTAssertEqual(first.process(logits: logits).asArray(Float.self), [8, 4, 4])
        XCTAssertEqual(copy.process(logits: logits).asArray(Float.self), [8, 4, 8])
        copy.prompt(MLXArray([2]))
        XCTAssertEqual(copy.process(logits: logits).asArray(Float.self), [8, 4, 8])
    }

    func testGeneratedTokensEvictTheCompletePromptWindow() throws {
        try requireMetal()
        let generation = ModelRuntime.serveGenerationConfiguration(
            parameters: GenerateParameters(repetitionPenalty: 2),
            completePromptTokenIDs: Array(repeating: 1, count: 25))
        var processor = try XCTUnwrap(generation.components.logitProcessor(parameters: generation.parameters))
        processor.prompt(MLXArray([1]))
        let logits = MLXArray([Float(8), 8, -8, 8]).reshaped(1, 4)
        for _ in 0..<19 { processor.didSample(token: MLXArray([2])) }
        XCTAssertEqual(processor.process(logits: logits).asArray(Float.self), [8, 4, -16, 8])
        processor.didSample(token: MLXArray([2]))
        XCTAssertEqual(processor.process(logits: logits).asArray(Float.self), [8, 8, -16, 8])
        // More than 20 generated entries evict earlier generated tokens too.
        for _ in 0..<21 { processor.didSample(token: MLXArray([3])) }
        XCTAssertEqual(processor.process(logits: logits).asArray(Float.self), [8, 8, -8, 4])
    }

    func testDefaultAndIdentityPenaltyDoNotInstallAProcessorOrChangeCachePolicy() {
        for penalty: Float? in [nil, 1] {
            let parameters = GenerateParameters(
                maxTokens: 13, maxKVSize: 128, kvBits: 4, temperature: 0.7,
                topP: 0.8, topK: 20, repetitionPenalty: penalty,
                prefill: .legacyRemainder(stepSize: 17), seed: 42)
            let generation = ModelRuntime.serveGenerationConfiguration(
                parameters: parameters, completePromptTokenIDs: [1, 2])
            XCTAssertNil(generation.components.logitProcessorFactory)
            XCTAssertEqual(generation.parameters.repetitionPenalty, penalty)
            XCTAssertEqual(generation.parameters.maxKVSize, 128)
            XCTAssertEqual(generation.parameters.kvBits, 4)
            XCTAssertEqual(generation.parameters.maxTokens, 13)
            XCTAssertEqual(generation.parameters.topK, 20)
            XCTAssertEqual(generation.parameters.seed, 42)
            XCTAssertEqual(generation.parameters.prefill.stepSize, 17)
        }
    }

    func testActivePenaltyCopiesRetainPrefillAndCachePolicyWithoutDoublePenalty() {
        let parameters = GenerateParameters(
            maxTokens: 13, maxKVSize: 128, kvBits: 4, temperature: 0.7,
            topP: 0.8, topK: 20, repetitionPenalty: 1.05,
            prefill: .legacyRemainder(stepSize: 17), seed: 42)
        let generation = ModelRuntime.serveGenerationConfiguration(
            parameters: parameters, completePromptTokenIDs: [1, 2])
        XCTAssertNil(generation.parameters.repetitionPenalty)
        XCTAssertNotNil(generation.components.logitProcessorFactory)
        XCTAssertEqual(generation.parameters.maxKVSize, parameters.maxKVSize)
        XCTAssertEqual(generation.parameters.kvBits, parameters.kvBits)
        XCTAssertEqual(generation.parameters.maxTokens, parameters.maxTokens)
        XCTAssertEqual(generation.parameters.temperature, parameters.temperature)
        XCTAssertEqual(generation.parameters.topP, parameters.topP)
        XCTAssertEqual(generation.parameters.topK, parameters.topK)
        XCTAssertEqual(generation.parameters.seed, parameters.seed)
        XCTAssertEqual(generation.parameters.prefill.stepSize, parameters.prefill.stepSize)
    }

    func testUpstreamDisabledPenaltyConfigurationsDoNotInstallAProcessor() {
        for parameters in [
            GenerateParameters(repetitionPenalty: 0),
            GenerateParameters(repetitionPenalty: 2, repetitionContextSize: 0),
            GenerateParameters(repetitionPenalty: 2, repetitionContextSize: -1),
        ] {
            let generation = ModelRuntime.serveGenerationConfiguration(
                parameters: parameters, completePromptTokenIDs: [1, 2])
            XCTAssertNil(generation.components.logitProcessorFactory)
            XCTAssertEqual(generation.parameters.repetitionPenalty, parameters.repetitionPenalty)
            XCTAssertEqual(generation.parameters.repetitionContextSize, parameters.repetitionContextSize)
        }
    }

    func testExtremePenaltyFactorsKeepFiniteLogitsFiniteInEveryServingDType() throws {
        try requireMetal()
        for dtype in [DType.float32, .float16, .bfloat16] {
            let maximum = Float(try XCTUnwrap(dtype.finfo).max)
            for penalty in [Float.leastNonzeroMagnitude, Float.greatestFiniteMagnitude] {
                var processor = ModelRuntime.CompletePromptRepetitionProcessor(
                    promptTokenIDs: [0, 1, 2, 3, 4, 5], penalty: penalty, contextSize: 20)
                processor.prompt(MLXArray([0]))
                let logits = MLXArray([maximum, -maximum, 0, 1, -1, Float.infinity,
                                       -Float.infinity, Float(7)]).asType(dtype).reshaped(1, 8)
                let result = processor.process(logits: logits).asType(.float32).asArray(Float.self)
                XCTAssertTrue(result.prefix(5).allSatisfy(\.isFinite), "dtype=\(dtype), factor=\(penalty)")
                XCTAssertEqual(result[2], 0)
                XCTAssertEqual(result[5], .infinity)
                XCTAssertEqual(result[6], -.infinity)
                XCTAssertEqual(result[7], 7) // Outside the history remains unchanged.
                if penalty == .leastNonzeroMagnitude {
                    XCTAssertEqual(result[0], maximum)
                    XCTAssertEqual(result[3], maximum)
                } else {
                    XCTAssertEqual(result[1], -maximum)
                    XCTAssertEqual(result[4], -maximum)
                }
            }
        }
    }

    func testNarrowFactorUsesWideArithmeticBeforeFiniteOutputCast() throws {
        try requireMetal()
        // Rounding this factor to Float16 would produce zero and incorrectly
        // saturate a quotient whose actual result is comfortably representable.
        let penalty: Float = 1e-9
        let logits = MLXArray([Float(0.001), -0.001, 0]).asType(.float16).reshaped(1, 3)
        var processor = ModelRuntime.CompletePromptRepetitionProcessor(
            promptTokenIDs: [0, 1, 2], penalty: penalty, contextSize: 20)
        processor.prompt(MLXArray([2]))
        let result = processor.process(logits: logits).asType(.float32).asArray(Float.self)
        XCTAssertEqual(result[0], Float(Float16.greatestFiniteMagnitude))
        XCTAssertEqual(result[1], 0)
        XCTAssertEqual(result[2], 0)
        let tiny = MLXArray([Float(0.00000011920928955078125)]).asType(.float16).reshaped(1, 1)
        var tinyProcessor = ModelRuntime.CompletePromptRepetitionProcessor(
            promptTokenIDs: [0], penalty: penalty, contextSize: 20)
        tinyProcessor.prompt(MLXArray([0]))
        let quotient = tinyProcessor.process(logits: tiny).asType(.float32).item(Float.self)
        XCTAssertEqual(quotient, Float(Float16(tiny.asType(.float32).item(Float.self) / penalty)))
        XCTAssertLessThan(quotient, 1000)
    }

    func testNormalRangePenaltyMatchesPinnedProcessorExactly() throws {
        try requireMetal()
        for dtype in [DType.float32, .float16, .bfloat16] {
            for penalty: Float in [0.5, 1.05, 2] {
                var safe = ModelRuntime.CompletePromptRepetitionProcessor(
                    promptTokenIDs: [0, 1, 1, 2], penalty: penalty, contextSize: 20)
                var pinned = RepetitionContext(repetitionPenalty: penalty, repetitionContextSize: 20)
                safe.prompt(MLXArray([2]))
                pinned.prompt(MLXArray([0, 1, 1, 2]))
                let logits = MLXArray([Float(-8), 4, 0, 7]).asType(dtype).reshaped(1, 4)
                XCTAssertEqual(
                    safe.process(logits: logits).asType(.float32).asArray(Float.self),
                    pinned.process(logits: logits).asType(.float32).asArray(Float.self))
            }
        }
    }
}
