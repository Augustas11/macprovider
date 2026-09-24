import ArgumentParser
import Darwin
import Foundation

/// #1690 benchmark: an external llama.cpp `llama-server` on loopback, driven
/// with the `msb-throughput` workload so both JSON reports compare on one
/// catalog key. Same prompt corpus (`MSBThroughputCommand.buildPromptText`,
/// row index = prompt index), same prompt length (the server's own tokenizer,
/// truncated), forced decode length (`ignore_eos`), temperature 0, and no
/// prompt cache. The aggregate is `msbAggregateThroughput` over per-request
/// decode windows (first streamed token to last), the definition native
/// batched rows use, and the first token is excluded as in native runs.
///
/// Measurement only: loopback endpoints only, never joins a coordinator, and
/// never touches a serving provider.
struct MSBLoopbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msb-loopback",
        abstract: "Measure an external llama-server on loopback against the msb-throughput workload (#1690).",
        discussion: """
            Start llama-server on 127.0.0.1 with --parallel >= the largest
            --concurrency value (the run refuses to queue requests behind too
            few slots). Pass --server-pid to report the server's lifetime peak
            phys footprint. Compare against msb-throughput on the same model.
            """,
        shouldDisplay: false
    )

    @Option(help: "llama-server base URL. Loopback hosts only. Default http://127.0.0.1:8181.")
    var endpoint: String = "http://127.0.0.1:8181"

    @Option(
        name: .customLong("server-pid"),
        help: "llama-server pid; enables the server peak phys-footprint field."
    )
    var serverPID: Int32?

    @Option(
        name: .customLong("concurrency"),
        parsing: .upToNextOption,
        help: "Concurrent request counts to measure. Default 1 4 8."
    )
    var concurrency: [Int] = [1, 4, 8]

    @Option(name: .customLong("prompt-tokens"), help: "Prompt tokens per request. Default 1024.")
    var promptTokens: Int = 1024

    @Option(
        name: .customLong("decode-tokens"),
        help: "Timed decode tokens per request (excludes the TTFT-boundary token). Default 256."
    )
    var decodeTokens: Int = 256

    @Option(help: "Timed runs per concurrency level (after one warmup). Default 5.")
    var runs: Int = 5

    @Option(help: "Free-form label recorded in the report, e.g. the GGUF quant.")
    var label: String?

    @Flag(name: .customLong("stdout-only"), help: "Print JSON to stdout only; do not write a file.")
    var stdoutOnly: Bool = false

    @Option(help: "Full output path for the JSON result file.")
    var output: String?

    @Option(
        name: .customLong("output-dir"),
        help: "Output directory for the auto-named JSON result. Default 'state/perf'."
    )
    var outputDir: String = "state/perf"

    func run() async throws {
        guard promptTokens >= 2, decodeTokens >= 1, runs >= 1,
              !concurrency.isEmpty, concurrency.allSatisfy({ $0 >= 1 }) else {
            FileHandle.standardError.write(Data(
                "msb-loopback: --prompt-tokens>=2, --decode-tokens>=1, --runs>=1, --concurrency values>=1 required\n".utf8
            ))
            throw ExitCode(2)
        }
        guard let base = msbLoopbackEndpointURL(endpoint) else {
            FileHandle.standardError.write(Data(
                "msb-loopback: --endpoint must be http://127.0.0.1, localhost, or [::1]\n".utf8
            ))
            throw ExitCode(2)
        }
        let client = MSBLoopbackClient(base: base)
        let props = try await client.props()
        let maxConcurrency = concurrency.max() ?? 1
        if let slots = props.totalSlots, maxConcurrency > slots {
            FileHandle.standardError.write(Data(
                "msb-loopback: server has \(slots) slots but --concurrency asks for \(maxConcurrency); restart llama-server with --parallel \(maxConcurrency)\n".utf8
            ))
            throw ExitCode(2)
        }

        var prompts: [[Int]] = []
        for index in 0..<maxConcurrency {
            let text = MSBThroughputCommand.buildPromptText(index: index, targetTokens: promptTokens)
            var tokens = try await client.tokenize(text, addSpecial: true)
            // Same deterministic extension as native `buildDistinctPrompts`, so
            // both sides score an identical token sequence.
            var salt = 0
            while tokens.count < promptTokens, salt < 10_000 {
                let corpus = MSBThroughputCommand.corpus
                tokens += try await client.tokenize(
                    " \(index)-\(salt) " + corpus[(index + salt) % corpus.count], addSpecial: false
                )
                salt += 1
            }
            guard tokens.count >= promptTokens else {
                FileHandle.standardError.write(Data(
                    "msb-loopback: prompt \(index) tokenized to \(tokens.count) < \(promptTokens) tokens\n".utf8
                ))
                throw ExitCode(1)
            }
            prompts.append(Array(tokens.prefix(promptTokens)))
        }

        var levels: [MSBLoopbackLevelReport] = []
        for c in concurrency {
            let rowPrompts = Array(prompts.prefix(c))
            _ = try await runRound(client: client, prompts: rowPrompts) // warmup
            var aggregateRuns: [Double] = []
            var perRowRuns: [Double] = []
            var ttfts: [Double] = []
            for _ in 0..<runs {
                let samples = try await runRound(client: client, prompts: rowPrompts)
                let summary = try msbLoopbackSummarizeRound(samples)
                aggregateRuns.append(summary.aggregateTokensPerSecond)
                perRowRuns.append(summary.perRowTokensPerSecondP50)
                ttfts.append(contentsOf: summary.ttftSeconds)
            }
            let level = MSBLoopbackLevelReport(
                concurrency: c,
                aggregateTPSRuns: aggregateRuns,
                aggregateTPSp50: decodeBenchPercentileTPS(aggregateRuns, p: 0.5),
                aggregateCVPct: msbLoopbackCVPct(aggregateRuns),
                perRowTPSp50: decodeBenchPercentileTPS(perRowRuns, p: 0.5),
                ttftSecondsP50: decodeBenchPercentileTPS(ttfts, p: 0.5),
                ttftSecondsP95: decodeBenchPercentileTPS(ttfts, p: 0.95),
                ttftSamples: ttfts.count
            )
            levels.append(level)
            FileHandle.standardError.write(Data((
                "msb-loopback: c=\(c) aggregate_tps_p50=\(decodeBenchFormatTPS(level.aggregateTPSp50)) " +
                "per_row_tps_p50=\(decodeBenchFormatTPS(level.perRowTPSp50)) " +
                "ttft_p50=\(String(format: "%.3f", level.ttftSecondsP50))s " +
                "ttft_p95=\(String(format: "%.3f", level.ttftSecondsP95))s " +
                "cv=\(String(format: "%.1f", level.aggregateCVPct))%\n"
            ).utf8))
        }

        let report = MSBLoopbackReport(
            schemaVersion: 1,
            runtime: "llama-server",
            endpoint: base.absoluteString,
            label: label,
            serverModelPath: props.modelPath,
            serverBuildInfo: props.buildInfo,
            serverTotalSlots: props.totalSlots,
            promptTokensPerRow: promptTokens,
            decodeTokensPerRow: decodeTokens,
            runs: runs,
            levels: levels,
            serverPeakPhysFootprintMB: serverPID.flatMap { msbLifetimePeakPhysFootprintMB(pid: $0) },
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))

        guard !stdoutOnly else { return }
        let fileURL: URL
        if let explicitPath = output {
            fileURL = URL(fileURLWithPath: explicitPath)
            let parent = fileURL.deletingLastPathComponent()
            if parent.path != "/" {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
        } else {
            let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tsFormatter = ISO8601DateFormatter()
            tsFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
            let ts = tsFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let tag = decodeBenchSanitizeFilenameComponent(
                label ?? props.modelPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "model"
            )
            fileURL = dir.appendingPathComponent("msb-loopback-llama-server-\(tag)-\(ts).json")
        }
        try json.write(to: fileURL, options: [.atomic])
        FileHandle.standardError.write(Data("msb-loopback: wrote \(fileURL.path)\n".utf8))
    }

    private func runRound(client: MSBLoopbackClient, prompts: [[Int]]) async throws -> [MSBLoopbackRequestSample] {
        let nPredict = decodeTokens + 1
        let expectedPrompt = promptTokens
        let samples = try await withThrowingTaskGroup(of: MSBLoopbackRequestSample.self) { group in
            for prompt in prompts {
                group.addTask { try await client.complete(prompt: prompt, nPredict: nPredict) }
            }
            var out: [MSBLoopbackRequestSample] = []
            for try await sample in group { out.append(sample) }
            return out
        }
        for sample in samples {
            // A short or long count means the server ignored ignore_eos, hit a
            // context limit, or reused a cached prefix; the round is not
            // comparable to the native workload.
            guard sample.predictedTokens == nPredict,
                  sample.promptTokens == nil || sample.promptTokens == expectedPrompt else {
                FileHandle.standardError.write(Data((
                    "msb-loopback: request generated \(sample.predictedTokens)/\(nPredict) tokens, " +
                    "evaluated \(sample.promptTokens.map(String.init) ?? "?")/\(expectedPrompt) prompt tokens\n"
                ).utf8))
                throw ExitCode(1)
            }
        }
        return samples
    }
}

// MARK: - Loopback client

/// Accepts only http loopback endpoints so the harness cannot be pointed at a
/// remote runtime (#1690 non-goal).
func msbLoopbackEndpointURL(_ raw: String) -> URL? {
    guard let components = URLComponents(string: raw),
          components.scheme == "http",
          let host = components.host?.lowercased(),
          ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
          let url = components.url else {
        return nil
    }
    return url
}

struct MSBLoopbackServerProps: Sendable, Equatable {
    let modelPath: String?
    let buildInfo: String?
    let totalSlots: Int?
}

struct MSBLoopbackRequestSample: Sendable, Equatable {
    let requestStartedAt: Date
    let firstTokenAt: Date
    let endedAt: Date
    let predictedTokens: Int
    let promptTokens: Int?
}

enum MSBLoopbackStreamEvent: Equatable {
    case token
    case final(predictedTokens: Int?, promptTokens: Int?)
}

enum MSBLoopbackError: Error, CustomStringConvertible {
    case http(Int, String)
    case server(String)
    case malformed(String)

    var description: String {
        switch self {
        case .http(let status, let path): return "llama-server \(path) returned HTTP \(status)"
        case .server(let message): return "llama-server error: \(message)"
        case .malformed(let what): return "llama-server returned malformed \(what)"
        }
    }
}

/// Parses one line of llama-server's `/completion` SSE stream. Non-data lines
/// return nil. Every partial event carries one sampled token; the `stop` event
/// carries the server's own counts.
func msbLoopbackParseStreamLine(_ line: String) throws -> MSBLoopbackStreamEvent? {
    guard line.hasPrefix("data:") else { return nil }
    let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    guard !payload.isEmpty, payload != "[DONE]" else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
        throw MSBLoopbackError.malformed("stream event")
    }
    if let error = object["error"] {
        let message = (error as? [String: Any])?["message"] as? String ?? String(describing: error)
        throw MSBLoopbackError.server(message)
    }
    guard (object["stop"] as? Bool) == true else { return .token }
    let timings = object["timings"] as? [String: Any]
    let predicted = (object["tokens_predicted"] as? Int) ?? (timings?["predicted_n"] as? Int)
    let prompt = (timings?["prompt_n"] as? Int) ?? (object["tokens_evaluated"] as? Int)
    return .final(predictedTokens: predicted, promptTokens: prompt)
}

struct MSBLoopbackClient: Sendable {
    let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 64
        self.session = URLSession(configuration: config)
    }

    func props() async throws -> MSBLoopbackServerProps {
        let object = try await getJSON("props")
        return MSBLoopbackServerProps(
            modelPath: object["model_path"] as? String,
            buildInfo: object["build_info"] as? String,
            totalSlots: object["total_slots"] as? Int
        )
    }

    func tokenize(_ text: String, addSpecial: Bool) async throws -> [Int] {
        let object = try await postJSON("tokenize", body: ["content": text, "add_special": addSpecial])
        guard let tokens = object["tokens"] as? [Int] else {
            throw MSBLoopbackError.malformed("tokenize response")
        }
        return tokens
    }

    func complete(prompt: [Int], nPredict: Int) async throws -> MSBLoopbackRequestSample {
        var request = URLRequest(url: base.appendingPathComponent("completion"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt,
            "n_predict": nPredict,
            "ignore_eos": true,
            "temperature": 0,
            "cache_prompt": false,
            "stream": true,
        ] as [String: Any])
        let startedAt = Date()
        let (bytes, response) = try await session.bytes(for: request)
        try Self.checkStatus(response, path: "/completion")
        var firstTokenAt: Date?
        var streamedTokens = 0
        var final: (predicted: Int?, prompt: Int?)?
        for try await line in bytes.lines {
            switch try msbLoopbackParseStreamLine(line) {
            case .token:
                if firstTokenAt == nil { firstTokenAt = Date() }
                streamedTokens += 1
            case .final(let predicted, let prompt):
                final = (predicted, prompt)
            case nil:
                continue
            }
            if final != nil { break }
        }
        let endedAt = Date()
        guard let final, let firstTokenAt else {
            throw MSBLoopbackError.malformed("stream (no tokens or no stop event)")
        }
        return MSBLoopbackRequestSample(
            requestStartedAt: startedAt,
            firstTokenAt: firstTokenAt,
            endedAt: endedAt,
            predictedTokens: final.predicted ?? streamedTokens,
            promptTokens: final.prompt
        )
    }

    private func getJSON(_ path: String) async throws -> [String: Any] {
        let (data, response) = try await session.data(from: base.appendingPathComponent(path))
        try Self.checkStatus(response, path: "/" + path)
        return try Self.decodeObject(data, what: path)
    }

    private func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, path: "/" + path)
        return try Self.decodeObject(data, what: path)
    }

    private static func checkStatus(_ response: URLResponse, path: String) throws {
        guard let http = response as? HTTPURLResponse else { throw MSBLoopbackError.malformed(path) }
        guard http.statusCode == 200 else { throw MSBLoopbackError.http(http.statusCode, path) }
    }

    private static func decodeObject(_ data: Data, what: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MSBLoopbackError.malformed(what)
        }
        return object
    }
}

// MARK: - Summaries

struct MSBLoopbackRoundSummary: Sendable, Equatable {
    let aggregateTokensPerSecond: Double
    let perRowTokensPerSecondP50: Double
    let ttftSeconds: [Double]
}

/// Decode window per request starts at the first streamed token, so the
/// TTFT-boundary token is excluded exactly as native batched rows exclude it.
func msbLoopbackSummarizeRound(_ samples: [MSBLoopbackRequestSample]) throws -> MSBLoopbackRoundSummary {
    let inputs = samples.map {
        MSBAggregateThroughputInput(
            decodedTokens: max($0.predictedTokens - 1, 0),
            decodeStartedAt: $0.firstTokenAt,
            decodeEndedAt: $0.endedAt
        )
    }
    let aggregate = try msbAggregateThroughput(inputs)
    let perRow = inputs.map {
        Double($0.decodedTokens) / max($0.decodeEndedAt.timeIntervalSince($0.decodeStartedAt), 0.000_001)
    }
    return MSBLoopbackRoundSummary(
        aggregateTokensPerSecond: aggregate.aggregateTokensPerSecond,
        perRowTokensPerSecondP50: decodeBenchPercentileTPS(perRow, p: 0.5),
        ttftSeconds: samples.map { max($0.firstTokenAt.timeIntervalSince($0.requestStartedAt), 0) }
    )
}

func msbLoopbackCVPct(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    guard mean > 0 else { return 0 }
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
    return (variance.squareRoot() / mean) * 100.0
}

/// Lifetime max phys footprint of `pid` in MiB. Phys footprint counts Metal
/// and other unified-memory allocations that RSS misses, so native and
/// llama-server memory high-water compare on one measure.
func msbLifetimePeakPhysFootprintMB(pid: pid_t) -> Int? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard rc == 0 else { return nil }
    return Int(info.ri_lifetime_max_phys_footprint / 1_048_576)
}

// MARK: - Wire schema

struct MSBLoopbackLevelReport: Codable, Sendable, Equatable {
    let concurrency: Int
    let aggregateTPSRuns: [Double]
    let aggregateTPSp50: Double
    let aggregateCVPct: Double
    let perRowTPSp50: Double
    let ttftSecondsP50: Double
    let ttftSecondsP95: Double
    let ttftSamples: Int
}

struct MSBLoopbackReport: Codable, Sendable {
    let schemaVersion: Int
    let runtime: String
    let endpoint: String
    let label: String?
    let serverModelPath: String?
    let serverBuildInfo: String?
    let serverTotalSlots: Int?
    let promptTokensPerRow: Int
    let decodeTokensPerRow: Int
    let runs: Int
    let levels: [MSBLoopbackLevelReport]
    let serverPeakPhysFootprintMB: Int?
    let timestamp: String
}
