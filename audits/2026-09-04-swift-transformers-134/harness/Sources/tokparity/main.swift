import Foundation
import Tokenizers
import Hub

// tokparity: load a local tokenizer folder, encode a fixed corpus, emit token IDs.
//
// Usage: tokparity <modelFolder> <corpusJson> <outJson>
// Corpus JSON: [ { "name": ..., "category": ..., "text": ... }, ... ]
// Output JSON: { "transformersVersion": ..., "model": ..., "rows": [ { name, category,
//                byteCount, tokenIds, decoded, decodeRoundTrips } ] }

struct CorpusEntry: Codable { let name: String; let category: String; let text: String }
struct ResultRow: Codable {
    let name: String
    let category: String
    let byteCount: Int
    let tokenIds: [Int]
    let decoded: String
    let decodeRoundTrips: Bool
}
struct Output: Codable {
    let transformersVersion: String
    let model: String
    let rows: [ResultRow]
}

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: tokparity <modelFolder> <corpusJson> <outJson>\n".data(using: .utf8)!)
    exit(2)
}
let modelFolder = URL(fileURLWithPath: args[1])
let corpusURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])
let version = ProcessInfo.processInfo.environment["TOKPARITY_TRANSFORMERS_VERSION"] ?? "unknown"

let corpus = try JSONDecoder().decode([CorpusEntry].self, from: Data(contentsOf: corpusURL))

func run() async throws {
    let tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder)
    // Long-input latency probe (#966 checklist): concatenate the corpus into a
    // ~large input and time repeated encodes. Emitted to stderr; does not affect
    // the token-ID output used for parity.
    let longInput = String(repeating: corpus.map { $0.text }.joined(separator: "\n"), count: 200)
    let iters = 20
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<iters {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = tokenizer.encode(text: longInput)
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        best = min(best, dt)
    }
    let bytes = longInput.utf8.count
    FileHandle.standardError.write("LATENCY \(version) \(modelFolder.lastPathComponent): \(bytes) bytes, best \(String(format: "%.2f", best)) ms over \(iters) iters\n".data(using: .utf8)!)
    var rows: [ResultRow] = []
    for entry in corpus {
        let ids = tokenizer.encode(text: entry.text)
        let decoded = tokenizer.decode(tokens: ids)
        // Round-trip check ignores special-token markup the decoder may add.
        let roundTrips = decoded.contains(entry.text) || decoded == entry.text
        rows.append(ResultRow(
            name: entry.name,
            category: entry.category,
            byteCount: entry.text.utf8.count,
            tokenIds: ids,
            decoded: decoded,
            decodeRoundTrips: roundTrips
        ))
    }
    let out = Output(transformersVersion: version, model: modelFolder.lastPathComponent, rows: rows)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(out).write(to: outURL)
    FileHandle.standardError.write("wrote \(rows.count) rows -> \(outURL.path)\n".data(using: .utf8)!)
}

try await run()
