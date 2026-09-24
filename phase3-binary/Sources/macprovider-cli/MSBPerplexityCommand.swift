import ArgumentParser
import Foundation
import MLX
import MLXLMCommon

/// #1690 benchmark: native MLX perplexity using llama.cpp `llama-perplexity`'s
/// chunking, so the GGUF-vs-native perplexity delta compares like for like on
/// one text file. The text is tokenized once without special tokens. It is
/// split into `--ctx`-token chunks, and each chunk runs with a fresh cache.
/// Only the second half of each chunk is scored: logits at positions
/// `ctx/2 ..< ctx-1` predict the next token. That matches llama-perplexity's
/// default `first = n_ctx/2` for vocabularies without an auto-BOS (Qwen). The
/// report records the token count, so a tokenizer mismatch between the two
/// sides is visible rather than silently skewing the delta.
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

    @Option(help: "Full output path for the JSON result file. Default: stdout only.")
    var output: String?

    func run() async throws {
        guard let modelID = model ?? ProcessInfo.processInfo.environment["MACPROVIDER_MODEL"],
              !modelID.isEmpty else {
            FileHandle.standardError.write(Data("msb-perplexity: --model is required\n".utf8))
            throw ExitCode(2)
        }
        guard ctx >= 4, maxChunks.map({ $0 >= 1 }) ?? true else {
            FileHandle.standardError.write(Data("msb-perplexity: --ctx>=4 and --max-chunks>=1 required\n".utf8))
            throw ExitCode(2)
        }
        let text = try String(contentsOfFile: textFile, encoding: .utf8)

        let runtime = try await ModelRuntime(modelID: modelID)
        guard await runtime.isLoaded, let container = await runtime.currentSnapshot().container else {
            FileHandle.standardError.write(Data("msb-perplexity: failed to load model \(modelID)\n".utf8))
            throw ExitCode(1)
        }

        let tokens = await container.perform { context in
            context.tokenizer.encode(text: text, addSpecialTokens: false)
        }
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
        let started = Date()
        var totalNLL = 0.0
        var scored = 0
        for chunk in 0..<chunks {
            let window = Array(tokens[(chunk * context)..<((chunk + 1) * context)])
            let chunkNLL = await container.perform { ctxt in
                let cache = ctxt.model.newCache(parameters: nil)
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
            timestamp: ISO8601DateFormatter().string(from: Date())
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
}
