import ArgumentParser
import Foundation
import MLX
import MLXLMCommon

/// #1690 benchmark: native MLX perplexity using llama.cpp `llama-perplexity`'s
/// chunking, so the GGUF-vs-native perplexity delta compares like for like on
/// one text file. The text is tokenized once with native
/// `addSpecialTokens:false`. When `--bos-token` is provided, that operator-
/// supplied token is prepended once to the full stream and placed at the first
/// position of every evaluated chunk to mirror llama-perplexity's explicit
/// add_bos path for a chosen tokenizer. No BOS auto-detection or external
/// parity claim is made here. Each chunk runs with a fresh cache. Only the
/// second half of each chunk is scored: logits at positions `ctx/2 ..< ctx-1`
/// predict the next token. The report records token/hash metadata so a tokenizer
/// or policy mismatch is visible rather than silently skewing the delta.
struct MSBPerplexityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msb-perplexity",
        abstract: "Native MLX perplexity with llama-perplexity chunking (#1690 benchmark).",
        shouldDisplay: false
    )

    @Option(help: "HuggingFace model ID or local path. Falls back to MACPROVIDER_MODEL.")
    var model: String?

    @Option(name: .customLong("text-file"), help: "UTF-8 text to score, e.g. wikitext-2-raw wiki.test.raw.")
    var textFile: String

    @Option(help: "Chunk context length in tokens. Must match llama-perplexity -c. Default 512.")
    var ctx: Int = 512

    @Option(name: .customLong("max-chunks"), help: "Cap on scored chunks (llama-perplexity --chunks). Default all.")
    var maxChunks: Int?

    @Option(
        name: .customLong("bos-token"),
        help: "Operator-supplied nonnegative Int32 BOS token for llama-perplexity add_bos compatibility. Default disabled."
    )
    var bosToken: Int?

    @Option(help: "Full output path for the JSON result file. Default: stdout only.")
    var output: String?

    func run() async throws {
        guard let modelID = model ?? ProcessInfo.processInfo.environment["MACPROVIDER_MODEL"],
              !modelID.isEmpty else {
            FileHandle.standardError.write(Data("msb-perplexity: --model is required\n".utf8))
            throw ExitCode(2)
        }
        guard ctx >= 4, maxChunks.map({ $0 >= 1 }) ?? true,
              MSBPerplexityTokenPolicy.validBOSToken(bosToken) else {
            FileHandle.standardError.write(Data(
                "msb-perplexity: --ctx>=4, --max-chunks>=1, and --bos-token in 0...\(Int32.max) required\n".utf8
            ))
            throw ExitCode(2)
        }
        let manualBOS = bosToken
        let text = try String(contentsOfFile: textFile, encoding: .utf8)

        let runtime = try await ModelRuntime(modelID: modelID)
        guard await runtime.isLoaded, let container = await runtime.currentSnapshot().container else {
            FileHandle.standardError.write(Data("msb-perplexity: failed to load model \(modelID)\n".utf8))
            throw ExitCode(1)
        }

        let baseTokens = await container.perform { context in
            context.tokenizer.encode(text: text, addSpecialTokens: false)
        }
        let tokens = MSBPerplexityTokenPolicy.corpusTokens(baseTokens: baseTokens, bosToken: manualBOS)
        let available = tokens.count / ctx
        let chunks = min(available, maxChunks ?? available)
        guard chunks >= 1 else {
            FileHandle.standardError.write(Data(
                "msb-perplexity: \(tokens.count) tokens is shorter than one \(ctx)-token chunk\n".utf8
            ))
            throw ExitCode(1)
        }

        let first = ctx / 2
        let context = ctx
        let chunkWindows = MSBPerplexityTokenPolicy.evaluatedChunks(
            corpusTokens: tokens,
            ctx: context,
            chunks: chunks,
            bosToken: manualBOS
        )
        let scoredTargets = MSBPerplexityTokenPolicy.scoredTargetTokens(chunks: chunkWindows, firstScoredOffset: first)
        let started = Date()
        var totalNLL = 0.0
        var scored = 0
        for chunk in 0..<chunks {
            let window = chunkWindows[chunk]
            let chunkNLL = try await container.perform { ctxt in
                let cache = try ctxt.model.newCache(parameters: nil)
                let input = MLXArray(window.map(Int32.init)).reshaped([1, context])
                let logits = ctxt.model(input, cache: cache)[0, first..<(context - 1), 0...].asType(.float32)
                let targets = MLXArray(window[(first + 1)..<context].map(Int32.init)).reshaped([context - 1 - first, 1])
                let logProbs = logits - logSumExp(logits, axis: -1, keepDims: true)
                let picked = takeAlong(logProbs, targets, axis: -1)
                return -picked.sum().item(Double.self)
            }
            totalNLL += chunkNLL
            scored += context - 1 - first
            let running = exp(totalNLL / Double(scored))
            FileHandle.standardError.write(Data(
                "msb-perplexity: chunk \(chunk + 1)/\(chunks) ppl=\(String(format: "%.4f", running))\n".utf8
            ))
        }

        let report = MSBPerplexityReport(
            schemaVersion: 1,
            modelID: modelID,
            mlxSwiftLMPin: decodeBenchMLXPinTag(),
            textFile: URL(fileURLWithPath: textFile).lastPathComponent,
            textTokens: tokens.count,
            ctx: ctx,
            chunks: chunks,
            scoredTokens: scored,
            perplexity: exp(totalNLL / Double(scored)),
            meanNLL: totalNLL / Double(scored),
            elapsedSeconds: Date().timeIntervalSince(started),
            peakPhysFootprintMB: msbLifetimePeakPhysFootprintMB(pid: getpid()),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            tokenizationMode: MSBPerplexityTokenPolicy.tokenizationMode(bosToken: manualBOS),
            bosToken: manualBOS,
            firstScoredOffset: first,
            corpusTokenSHA256: msbPromptTokenSHA256(tokens),
            evaluatedChunkTokenSHA256: msbPromptTokenSHA256(chunkWindows.flatMap { $0 }),
            scoredTargetTokenSHA256: msbPromptTokenSHA256(scoredTargets)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if let output {
            try json.write(to: URL(fileURLWithPath: output), options: [.atomic])
        }
    }
}

enum MSBPerplexityTokenPolicy {
    static func validBOSToken(_ token: Int?) -> Bool {
        guard let token else { return true }
        return token >= 0 && token <= Int(Int32.max)
    }

    static func corpusTokens(baseTokens: [Int], bosToken: Int?) -> [Int] {
        guard let bosToken else { return baseTokens }
        return [bosToken] + baseTokens
    }

    static func evaluatedChunks(
        corpusTokens: [Int],
        ctx: Int,
        chunks: Int,
        bosToken: Int?
    ) -> [[Int]] {
        guard ctx > 0, chunks > 0 else { return [] }
        let boundedChunks = min(chunks, corpusTokens.count / ctx)
        var out: [[Int]] = []
        out.reserveCapacity(boundedChunks)
        for chunk in 0..<boundedChunks {
            var window = Array(corpusTokens[(chunk * ctx)..<((chunk + 1) * ctx)])
            if let bosToken {
                window[0] = bosToken
            }
            out.append(window)
        }
        return out
    }

    static func scoredTargetTokens(chunks: [[Int]], firstScoredOffset: Int) -> [Int] {
        chunks.flatMap { chunk -> [Int] in
            guard firstScoredOffset + 1 < chunk.count else { return [] }
            return Array(chunk[(firstScoredOffset + 1)..<chunk.count])
        }
    }

    static func tokenizationMode(bosToken: Int?) -> String {
        bosToken == nil
            ? "native_encode_addSpecialTokens_false_no_manual_bos_no_auto_eos"
            : "native_encode_addSpecialTokens_false_manual_bos_no_auto_eos"
    }
}

struct MSBPerplexityReport: Codable, Sendable {
    let schemaVersion: Int
    let modelID: String
    let mlxSwiftLMPin: String
    let textFile: String
    let textTokens: Int
    let ctx: Int
    let chunks: Int
    let scoredTokens: Int
    let perplexity: Double
    let meanNLL: Double
    let elapsedSeconds: Double
    let peakPhysFootprintMB: Int?
    let timestamp: String
    /// Actual tokenizer/policy mode. This is metadata, not an external parity claim.
    var tokenizationMode: String? = nil
    /// Operator-supplied manual BOS token, if any.
    var bosToken: Int? = nil
    /// llama-perplexity first scored offset (`ctx / 2`).
    var firstScoredOffset: Int? = nil
    /// SHA-256 of corpus token IDs after the optional single manual BOS insertion.
    /// Uses `msbPromptTokenSHA256`'s documented little-endian token-id encoding.
    var corpusTokenSHA256: String? = nil
    /// SHA-256 of evaluated chunk token IDs after per-chunk BOS placement.
    /// Uses `msbPromptTokenSHA256`'s documented little-endian token-id encoding.
    var evaluatedChunkTokenSHA256: String? = nil
    /// SHA-256 of scored target token IDs, concatenated across evaluated chunks.
    /// Uses `msbPromptTokenSHA256`'s documented little-endian token-id encoding.
    var scoredTargetTokenSHA256: String? = nil
}
