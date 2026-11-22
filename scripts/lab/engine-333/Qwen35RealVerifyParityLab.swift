import Foundation
import MLX
import MLXLMCommon
import MLXNN
import XCTest

@testable import MLXLLM

/// Lab tool, skipped unless QWEN35_VERIFY_MODEL_DIR is set: on a real Qwen3.5-family
/// checkpoint, greedy one-token decode (path A) against teacher-forced verify steps
/// of QWEN35_VERIFY_WIDTH tokens with the MTP emit flag and a recurrent checkpoint
/// after the first column (path B), as native-MTP verification runs them. Every
/// verify column must reproduce path A's logits bit for bit. It also prints path A's greedy
/// tokens, so two engine builds can be compared token for token on the same prompt.
/// Not part of the fork: scripts/lab/engine-333/studio-diag.sh copies it into a checkout.
final class Qwen35RealVerifyParityLab: XCTestCase {
    private struct NoTokenizerLoader: TokenizerLoader {
        func load(from directory: URL) async throws -> any Tokenizer { NoTokenizer() }
    }

    private struct NoTokenizer: Tokenizer {
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(
            messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] { [] }
    }

    func testVerifyColumnsMatchSequentialDecode() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["QWEN35_VERIFY_MODEL_DIR"] else {
            throw XCTSkip("QWEN35_VERIFY_MODEL_DIR is not set")
        }
        let width = Int(env["QWEN35_VERIFY_WIDTH"] ?? "") ?? 3
        let steps = Int(env["QWEN35_VERIFY_STEPS"] ?? "") ?? 48
        let checkpoint = (env["QWEN35_VERIFY_CHECKPOINT"] ?? "1") == "1"
        let context = try await LLMModelFactory.shared.load(
            from: URL(fileURLWithPath: dir), using: NoTokenizerLoader())
        let model = context.model
        if (env["QWEN35_VERIFY_PREPARE"] ?? "1") == "1" { try model.prepare() }

        func run(_ tokens: [Int32], _ cache: [KVCache], _ state: LMOutput.State?) -> MLXArray {
            let input = LMInput.Text(tokens: MLXArray(tokens).reshaped(1, tokens.count))
            let logits = model(input, cache: cache, state: state).logits.asType(.float32)
            eval(logits)
            return logits
        }
        func top(_ row: MLXArray) -> Int32 { argMax(row).item(Int32.self) }

        let prompt = (0 ..< 120).map { Int32(1000 + ($0 * 7919) % 40000) }
        let cacheA = try model.newCache(parameters: nil)
        let cacheB = try model.newCache(parameters: nil)
        let prefillA = run(prompt, cacheA, nil)
        let prefillB = run(prompt, cacheB, nil)
        let prefillDiff = (prefillA[0, -1] .!= prefillB[0, -1]).asType(.int32).sum().item(Int.self)
        print("VERIFY prefill last-row bitdiff=\(prefillDiff)")

        var tokens: [Int32] = []
        var logitsA: [MLXArray] = []
        var next = top(prefillA[0, -1])
        for _ in 0 ..< steps {
            tokens.append(next)
            let row = run([next], cacheA, nil)[0, 0]
            logitsA.append(row)
            next = top(row)
        }

        print("VERIFY tokens=\(tokens.map(String.init).joined(separator: ","))")

        var bitMismatchColumns = 0
        var argmaxMismatches = 0
        var i = 0
        while i + width <= steps {
            var state = LMOutput.State()
            state[mtpEmitFlagKey] = true
            if checkpoint, width > 1 { state[mtpCacheCheckpointIndexKey] = 1 }
            let out = run(Array(tokens[i ..< i + width]), cacheB, state)
            for entry in cacheB { (entry as? MambaCache)?.discardSpeculativeCheckpoint() }
            for j in 0 ..< width {
                let a = logitsA[i + j]
                let b = out[0, j]
                let diff = (a .!= b).asType(.int32).sum().item(Int.self)
                let maxAbs = abs(a - b).max().item(Float.self)
                let ta = top(a)
                let tb = top(b)
                if diff > 0 { bitMismatchColumns += 1 }
                if ta != tb { argmaxMismatches += 1 }
                print("VERIFY pos=\(i + j) col=\(j) bitdiff=\(diff) maxabs=\(maxAbs) top_a=\(ta) top_b=\(tb)")
            }
            i += width
        }
        print("VERIFY summary width=\(width) checkpoint=\(checkpoint) columns=\(i) bit_mismatch_columns=\(bitMismatchColumns) argmax_mismatches=\(argmaxMismatches)")
        XCTAssertEqual(argmaxMismatches, 0)
        XCTAssertEqual(bitMismatchColumns, 0)
    }
}
