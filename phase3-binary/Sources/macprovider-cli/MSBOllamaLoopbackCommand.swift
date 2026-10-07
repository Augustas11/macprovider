import ArgumentParser
import CryptoKit
import CoreFoundation
import Foundation

/// #1690 benchmark: Ollama loopback throughput against the MSB prompt/decode
/// shape. This is measurement-only evidence: no coordinator join, no receipt,
/// no buyer billing, and no claim that Ollama and native MLX used identical
/// token IDs. The run qualifies only when Ollama itself reports exactly the
/// expected prompt and eval counts for every request.
struct MSBOllamaLoopbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msb-ollama-loopback",
        abstract: "Measure an Ollama loopback model with #1690 MSB-shaped prompts.",
        shouldDisplay: false
    )

    @Option(help: "Ollama base URL. Loopback HTTP origin only. Default http://127.0.0.1:11434.")
    var endpoint: String = "http://127.0.0.1:11434"

    @Option(help: "Ollama model name passed to /api/generate.")
    var model: String

    @Option(name: .customLong("expected-gguf-sha256"), help: "Required macprovider.gguf-file.v1 digest of the Ollama model blob.")
    var expectedGGUFSHA256: String

    @Option(name: .customLong("ollama-models-root"), help: "Optional Ollama models root. Defaults to OLLAMA_MODELS or ~/.ollama/models.")
    var ollamaModelsRoot: String?

    @Option(
        name: .customLong("prompt-file"),
        parsing: .upToNextOption,
        help: "UTF-8 prompt files to send. If omitted, deterministic MSB text is generated. File contents are never reported."
    )
    var promptFiles: [String] = []

    @Option(
        name: .customLong("concurrency"),
        parsing: .upToNextOption,
        help: "Concurrent request counts to measure. Default 1 4 8."
    )
    var concurrency: [Int] = [1, 4, 8]

    @Option(name: .customLong("prompt-tokens"), help: "Required Ollama prompt_eval_count. Default 1024.")
    var promptTokens: Int = 1024

    @Option(
        name: .customLong("decode-tokens"),
        help: "Timed decode tokens per request, excluding the TTFT-boundary token. Default 256."
    )
    var decodeTokens: Int = 256

    @Option(help: "Timed runs per concurrency level after one warmup. Default 5.")
    var runs: Int = 5

    @Flag(name: .customLong("capability-aware"), help: "Accept capability-aware Ollama count ranges and report them as operator benchmark evidence only.")
    var capabilityAware: Bool = false

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
        guard (1...MSBOllamaLoopbackBounds.maxPromptTokens).contains(promptTokens),
              (1...MSBOllamaLoopbackBounds.maxDecodeTokens).contains(decodeTokens),
              (1...MSBOllamaLoopbackBounds.maxRuns).contains(runs),
              !concurrency.isEmpty,
              concurrency.allSatisfy({ (1...MSBOllamaLoopbackBounds.maxConcurrency).contains($0) }) else {
            FileHandle.standardError.write(Data((
                "msb-ollama-loopback: --prompt-tokens 1...\(MSBOllamaLoopbackBounds.maxPromptTokens), " +
                "--decode-tokens 1...\(MSBOllamaLoopbackBounds.maxDecodeTokens), --runs 1...\(MSBOllamaLoopbackBounds.maxRuns), " +
                "--concurrency values 1...\(MSBOllamaLoopbackBounds.maxConcurrency) required\n"
            ).utf8))
            throw ExitCode(2)
        }
        guard let base = msbLoopbackEndpointURL(endpoint) else {
            FileHandle.standardError.write(Data(
                "msb-ollama-loopback: --endpoint must be an http origin on 127.0.0.1 or [::1] with a port\n".utf8
            ))
            throw ExitCode(2)
        }
        guard expectedGGUFSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            FileHandle.standardError.write(Data("msb-ollama-loopback: --expected-gguf-sha256 must be 64 lowercase hex characters\n".utf8))
            throw ExitCode(2)
        }

        let artifactRoot = ollamaModelsRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? BYOMOllamaModelStore.defaultRoot()
        let resolver = BYOMArtifactDigestResolver(
            store: BYOMOllamaModelStore(root: artifactRoot),
            cache: BYOMArtifactDigestCache(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macprovider-msb-ollama-digests.json"))
        )
        let evidence = try resolver.computeEvidence(forOllamaModel: model)
        guard evidence.digest == expectedGGUFSHA256 else {
            FileHandle.standardError.write(Data("msb-ollama-loopback: Ollama GGUF digest does not match --expected-gguf-sha256\n".utf8))
            throw ExitCode(1)
        }

        let maxConcurrency = concurrency.max() ?? 1
        let prompts = try Self.loadPrompts(promptFiles: promptFiles, count: maxConcurrency, targetTokens: promptTokens)
        let promptHashes = prompts.map { msbOllamaSHA256Hex(Data($0.utf8)) }
        let client = MSBOllamaLoopbackClient(base: base)
        let expectedEval = decodeTokens + 1
        let qualificationMode: MSBOllamaLoopbackQualificationMode = capabilityAware ? .capabilityAware : .strictExact

        var levels: [MSBOllamaLoopbackLevelReport] = []
        let requestedCanonicalProfile = concurrency == [1, 4, 8] && promptTokens == 1024 && decodeTokens == 256 && runs == 5
        let canonicalProfile = requestedCanonicalProfile && !capabilityAware
        for level in concurrency {
            let rowPrompts = Array(prompts.prefix(level))
            _ = try await runRound(client: client, prompts: rowPrompts, expectedEval: expectedEval, mode: qualificationMode)
            var aggregateRuns: [Double] = []
            var endToEndEvalRuns: [Double] = []
            var perRowRuns: [Double] = []
            var ttfts: [Double] = []
            var measuredSamples: [MSBOllamaLoopbackRequestSample] = []
            for _ in 0..<runs {
                let samples = try await runRound(client: client, prompts: rowPrompts, expectedEval: expectedEval, mode: qualificationMode)
                measuredSamples.append(contentsOf: samples)
                let summary = try msbOllamaLoopbackSummarizeRound(samples)
                aggregateRuns.append(summary.aggregateTokensPerSecond)
                endToEndEvalRuns.append(summary.endToEndEvalTokensPerSecond)
                perRowRuns.append(summary.perRowTokensPerSecondP50)
                ttfts.append(contentsOf: summary.ttftSeconds)
            }
            levels.append(MSBOllamaLoopbackLevelReport(
                concurrency: level,
                aggregateTPSRuns: aggregateRuns,
                aggregateTPSp50: decodeBenchPercentileTPS(aggregateRuns, p: 0.5),
                aggregateCVPct: msbLoopbackCVPct(aggregateRuns),
                perRowTPSp50: decodeBenchPercentileTPS(perRowRuns, p: 0.5),
                endToEndEvalTPSRuns: endToEndEvalRuns,
                endToEndEvalTPSp50: decodeBenchPercentileTPS(endToEndEvalRuns, p: 0.5),
                ttftSecondsP50: decodeBenchPercentileTPS(ttfts, p: 0.5),
                ttftSecondsP95: decodeBenchPercentileTPS(ttfts, p: 0.95),
                ttftSamples: ttfts.count,
                promptCacheVerification: msbOllamaPromptCacheVerification(measuredSamples),
                requestSamples: measuredSamples.map(MSBOllamaLoopbackRequestReport.init(sample:))
            ))
        }

        try resolver.validateCurrent(evidence, forOllamaModel: model)
        let report = MSBOllamaLoopbackReport(
            schemaVersion: 1,
            runtime: "ollama_loopback",
            originClass: "loopback_http",
            modelNameSHA256: msbOllamaSHA256Hex(Data(model.utf8)),
            artifactHashAlgorithm: ModelArtifactIdentity.ggufFileV1,
            artifactSHA256: evidence.digest,
            promptTokensPerRow: promptTokens,
            evalTokensPerRow: expectedEval,
            timedDecodeTokensPerRow: decodeTokens,
            runs: runs,
            promptSHA256: promptHashes,
            levels: levels,
            countSource: "ollama_reported_operator_benchmark_only",
            operatorBenchmarkMode: capabilityAware ? "capability_aware" : "strict_exact_counts",
            requestedCanonical1690Profile: requestedCanonicalProfile,
            strictM0Qualified: false,
            forcedDecodeTokensExact: false,
            promptCacheDisabled: false,
            nativeIdenticalTokenSequences: false,
            runtimePerplexityEvidence: false,
            canonical1690Profile: canonicalProfile,
            billingEvidence: false,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        let json = try MSBOllamaLoopbackReport.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))

        guard !stdoutOnly else { return }
        let fileURL: URL
        if let output {
            fileURL = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            fileURL = dir.appendingPathComponent("msb-ollama-loopback-\(ts).json")
        }
        try json.write(to: fileURL, options: [.atomic])
        FileHandle.standardError.write(Data("msb-ollama-loopback: wrote \(fileURL.path)\n".utf8))
    }

    private static func loadPrompts(promptFiles: [String], count: Int, targetTokens: Int) throws -> [String] {
        if !promptFiles.isEmpty {
            let loaded = try promptFiles.map { try String(contentsOfFile: $0, encoding: .utf8) }
            guard loaded.count == 1 || loaded.count >= count else {
                FileHandle.standardError.write(Data(
                    "msb-ollama-loopback: provide either one --prompt-file or at least the maximum concurrency count\n".utf8
                ))
                throw ExitCode(2)
            }
            return (0..<count).map { loaded[min($0, loaded.count - 1)] }
        }
        return (0..<count).map { MSBThroughputCommand.buildPromptText(index: $0, targetTokens: targetTokens) }
    }

    private func runRound(
        client: MSBOllamaLoopbackClient,
        prompts: [String],
        expectedEval: Int,
        mode: MSBOllamaLoopbackQualificationMode
    ) async throws -> [MSBOllamaLoopbackRequestSample] {
        let samples = try await withThrowingTaskGroup(of: MSBOllamaLoopbackRequestSample.self) { group in
            for prompt in prompts {
                group.addTask {
                    try await client.generate(model: model, prompt: prompt, expectedEval: expectedEval)
                }
            }
            var out: [MSBOllamaLoopbackRequestSample] = []
            for try await sample in group { out.append(sample) }
            return out
        }
        for sample in samples {
            try msbOllamaRequireQualifiedCounts(sample, promptTokens: promptTokens, evalTokens: expectedEval, mode: mode)
        }
        return samples
    }
}

enum MSBOllamaLoopbackBounds {
    static let maxStreamLineBytes = 1024 * 1024
    static let maxStreamTotalBytes = 256 * 1024 * 1024
    static let maxPromptTokens = 262_144
    static let maxDecodeTokens = 131_072
    static let maxConcurrency = 256
    static let maxRuns = 1_000
}

struct MSBOllamaLoopbackRequestSample: Sendable, Equatable {
    let requestStartedAt: Date
    let firstTokenAt: Date
    let endedAt: Date
    let evalCount: Int
    let promptEvalCount: Int
    let promptEvalCachedCount: Int?
    let doneReason: String?
}

enum MSBOllamaLoopbackQualificationMode: Sendable, Equatable {
    case strictExact
    case capabilityAware
}

func msbOllamaRequireQualifiedCounts(
    _ sample: MSBOllamaLoopbackRequestSample,
    promptTokens: Int,
    evalTokens: Int,
    mode: MSBOllamaLoopbackQualificationMode = .strictExact
) throws {
    try msbOllamaValidateSampleTimings(sample)
    guard sample.promptEvalCount == promptTokens else {
        FileHandle.standardError.write(Data(
            "msb-ollama-loopback: prompt_eval_count \(sample.promptEvalCount)/\(promptTokens); prompt is not qualified\n".utf8
        ))
        throw ExitCode(1)
    }
    guard sample.promptEvalCachedCount.map({ (0...promptTokens).contains($0) }) ?? true else {
        FileHandle.standardError.write(Data(
            "msb-ollama-loopback: prompt_eval_cached_count \(sample.promptEvalCachedCount ?? 0); cached prompt eval count is outside 0...\(promptTokens)\n".utf8
        ))
        throw ExitCode(1)
    }

    switch mode {
    case .strictExact:
        guard sample.evalCount == evalTokens else {
            FileHandle.standardError.write(Data(
                "msb-ollama-loopback: eval_count \(sample.evalCount)/\(evalTokens); generation is not qualified\n".utf8
            ))
            throw ExitCode(1)
        }
        guard (sample.promptEvalCachedCount ?? 0) == 0 else {
            FileHandle.standardError.write(Data(
                "msb-ollama-loopback: prompt_eval_cached_count \(sample.promptEvalCachedCount ?? 0); cached prompt eval is not qualified\n".utf8
            ))
            throw ExitCode(1)
        }
    case .capabilityAware:
        guard (2...evalTokens).contains(sample.evalCount) else {
            FileHandle.standardError.write(Data(
                "msb-ollama-loopback: eval_count \(sample.evalCount) outside capability-aware range 2...\(evalTokens); generation is not qualified\n".utf8
            ))
            throw ExitCode(1)
        }
    }

    if let doneReason = sample.doneReason,
       doneReason != "stop",
       doneReason != "length" {
        FileHandle.standardError.write(Data(
            "msb-ollama-loopback: done_reason \(doneReason); generation is not qualified\n".utf8
        ))
        throw ExitCode(1)
    }
}

func msbOllamaValidateSampleTimings(_ sample: MSBOllamaLoopbackRequestSample) throws {
    let ttft = sample.firstTokenAt.timeIntervalSince(sample.requestStartedAt)
    let decodeDuration = sample.endedAt.timeIntervalSince(sample.firstTokenAt)
    let requestDuration = sample.endedAt.timeIntervalSince(sample.requestStartedAt)
    guard ttft.isFinite, decodeDuration.isFinite, requestDuration.isFinite,
          ttft >= 0, decodeDuration > 0, requestDuration > 0 else {
        FileHandle.standardError.write(Data(
            "msb-ollama-loopback: non-finite or invalid stream timing; generation is not qualified\n".utf8
        ))
        throw ExitCode(1)
    }
}

enum MSBOllamaStreamEvent: Equatable {
    case token
    case final(evalCount: Int?, promptEvalCount: Int?, promptEvalCachedCount: Int?, doneReason: String?)
}

enum MSBOllamaLoopbackError: Error, CustomStringConvertible {
    case http(Int)
    case server(String)
    case malformed(String)

    var description: String {
        switch self {
        case .http(let status): return "Ollama /api/generate returned HTTP \(status)"
        case .server(let message): return "Ollama error: \(message)"
        case .malformed(let what): return "Ollama returned malformed \(what)"
        }
    }
}

func msbOllamaParseStreamLine(_ line: String) throws -> MSBOllamaStreamEvent? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
        throw MSBOllamaLoopbackError.malformed("stream event")
    }
    if let error = object["error"] {
        throw MSBOllamaLoopbackError.server(String(describing: error))
    }
    guard let done = object["done"] as? NSNumber,
          CFGetTypeID(done) == CFBooleanGetTypeID() else {
        throw MSBOllamaLoopbackError.malformed("done")
    }
    if let response = object["response"], !(response is String) {
        throw MSBOllamaLoopbackError.malformed("response")
    }
    if done.boolValue {
        var doneReason: String?
        if let value = object["done_reason"] {
            guard let reason = value as? String else {
                throw MSBOllamaLoopbackError.malformed("done_reason")
            }
            doneReason = reason
        }
        return .final(
            evalCount: try msbOllamaOptionalCounter(object, key: "eval_count"),
            promptEvalCount: try msbOllamaOptionalCounter(object, key: "prompt_eval_count"),
            promptEvalCachedCount: try msbOllamaOptionalCounter(object, key: "prompt_eval_cached_count"),
            doneReason: doneReason
        )
    }
    if let response = object["response"] as? String, !response.isEmpty {
        return .token
    }
    if object["response"] is String { return nil }
    throw MSBOllamaLoopbackError.malformed("stream event")
}

private func msbOllamaOptionalCounter(_ object: [String: Any], key: String) throws -> Int? {
    guard let value = object[key] else { return nil }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          let count = Int(exactly: number.doubleValue) else {
        throw MSBOllamaLoopbackError.malformed(key)
    }
    return count
}

struct MSBOllamaLoopbackClient: Sendable {
    let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 64
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }

    func generate(model: String, prompt: String, expectedEval: Int) async throws -> MSBOllamaLoopbackRequestSample {
        var request = URLRequest(url: base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "raw": true,
            "stream": true,
            "options": [
                "temperature": 0,
                "num_predict": expectedEval,
            ],
        ] as [String: Any])
        let startedAt = Date()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MSBOllamaLoopbackError.malformed("response")
        }
        guard http.statusCode == 200 else { throw MSBOllamaLoopbackError.http(http.statusCode) }

        var firstTokenAt: Date?
        var final: (evalCount: Int?, promptEvalCount: Int?, promptEvalCachedCount: Int?, doneReason: String?)?
        var splitter = LoopbackLineSplitter(
            maxLineBytes: MSBOllamaLoopbackBounds.maxStreamLineBytes,
            maxTotalBytes: MSBOllamaLoopbackBounds.maxStreamTotalBytes
        )
        for try await byte in bytes {
            guard let line = try splitter.append(byte) else { continue }
            switch try msbOllamaParseStreamLine(line) {
            case .token:
                if final != nil { throw MSBOllamaLoopbackError.malformed("stream (token after done)") }
                if firstTokenAt == nil { firstTokenAt = Date() }
            case .final(let evalCount, let promptEvalCount, let promptEvalCachedCount, let doneReason):
                guard final == nil else { throw MSBOllamaLoopbackError.malformed("stream (duplicate done event)") }
                final = (evalCount, promptEvalCount, promptEvalCachedCount, doneReason)
            case nil:
                continue
            }
        }
        if final == nil, let last = splitter.finish(),
           case .final(let evalCount, let promptEvalCount, let promptEvalCachedCount, let doneReason) = try msbOllamaParseStreamLine(last) {
            final = (evalCount, promptEvalCount, promptEvalCachedCount, doneReason)
        }
        let endedAt = Date()
        guard let firstTokenAt, let final, let evalCount = final.evalCount, let promptEvalCount = final.promptEvalCount else {
            throw MSBOllamaLoopbackError.malformed("stream (missing token, final counts, or done event)")
        }
        return MSBOllamaLoopbackRequestSample(
            requestStartedAt: startedAt,
            firstTokenAt: firstTokenAt,
            endedAt: endedAt,
            evalCount: evalCount,
            promptEvalCount: promptEvalCount,
            promptEvalCachedCount: final.promptEvalCachedCount,
            doneReason: final.doneReason
        )
    }
}

struct MSBOllamaLoopbackRoundSummary: Sendable, Equatable {
    let aggregateTokensPerSecond: Double
    let endToEndEvalTokensPerSecond: Double
    let perRowTokensPerSecondP50: Double
    let ttftSeconds: [Double]
}

func msbOllamaLoopbackSummarizeRound(_ samples: [MSBOllamaLoopbackRequestSample]) throws -> MSBOllamaLoopbackRoundSummary {
    for sample in samples {
        try msbOllamaValidateSampleTimings(sample)
    }
    let inputs = samples.map {
        MSBAggregateThroughputInput(
            decodedTokens: max($0.evalCount - 1, 0),
            decodeStartedAt: $0.firstTokenAt,
            decodeEndedAt: $0.endedAt
        )
    }
    let aggregate = try msbAggregateThroughput(inputs)
    let totalEvalCount = samples.reduce(0) { $0 + $1.evalCount }
    let requestStartedAt = samples.map(\.requestStartedAt).min() ?? Date(timeIntervalSinceReferenceDate: 0)
    let endedAt = samples.map(\.endedAt).max() ?? requestStartedAt
    let requestWindow = endedAt.timeIntervalSince(requestStartedAt)
    let perRow = inputs.map {
        Double($0.decodedTokens) / max($0.decodeEndedAt.timeIntervalSince($0.decodeStartedAt), 0.000_001)
    }
    return MSBOllamaLoopbackRoundSummary(
        aggregateTokensPerSecond: aggregate.aggregateTokensPerSecond,
        endToEndEvalTokensPerSecond: Double(totalEvalCount) / requestWindow,
        perRowTokensPerSecondP50: decodeBenchPercentileTPS(perRow, p: 0.5),
        ttftSeconds: samples.map { max($0.firstTokenAt.timeIntervalSince($0.requestStartedAt), 0) }
    )
}

func msbOllamaPromptCacheVerification(_ samples: [MSBOllamaLoopbackRequestSample]) -> String {
    let reported = samples.filter { $0.promptEvalCachedCount != nil }
    guard !reported.isEmpty else { return "not_reported_by_ollama" }
    let hasCached = reported.contains { ($0.promptEvalCachedCount ?? 0) > 0 }
    if reported.count == samples.count {
        return hasCached ? "reported_cached_prompt_eval" : "reported_zero"
    }
    return hasCached ? "mixed_reported_cached_and_not_reported" : "mixed_reported_zero_and_not_reported"
}

struct MSBOllamaLoopbackLevelReport: Codable, Sendable, Equatable {
    let concurrency: Int
    let aggregateTPSRuns: [Double]
    let aggregateTPSp50: Double
    let aggregateCVPct: Double
    let perRowTPSp50: Double
    var endToEndEvalTPSRuns: [Double]?
    var endToEndEvalTPSp50: Double?
    let ttftSecondsP50: Double
    let ttftSecondsP95: Double
    let ttftSamples: Int
    let promptCacheVerification: String
    var requestSamples: [MSBOllamaLoopbackRequestReport]?
}

struct MSBOllamaLoopbackRequestReport: Codable, Sendable, Equatable {
    let evalCount: Int?
    let promptEvalCount: Int?
    let promptEvalCachedCount: Int?
    let doneReason: String?
    let ttftSeconds: Double?
    let requestSeconds: Double?

    init(
        evalCount: Int?,
        promptEvalCount: Int?,
        promptEvalCachedCount: Int?,
        doneReason: String?,
        ttftSeconds: Double?,
        requestSeconds: Double?
    ) {
        self.evalCount = evalCount
        self.promptEvalCount = promptEvalCount
        self.promptEvalCachedCount = promptEvalCachedCount
        self.doneReason = doneReason
        self.ttftSeconds = ttftSeconds
        self.requestSeconds = requestSeconds
    }

    init(sample: MSBOllamaLoopbackRequestSample) {
        self.init(
            evalCount: sample.evalCount,
            promptEvalCount: sample.promptEvalCount,
            promptEvalCachedCount: sample.promptEvalCachedCount,
            doneReason: sample.doneReason,
            ttftSeconds: sample.firstTokenAt.timeIntervalSince(sample.requestStartedAt),
            requestSeconds: sample.endedAt.timeIntervalSince(sample.requestStartedAt)
        )
    }

    enum CodingKeys: String, CodingKey {
        case evalCount
        case promptEvalCount
        case promptEvalCachedCount
        case doneReason
        case ttftSeconds
        case requestSeconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(evalCount, forKey: .evalCount)
        try container.encodeIfPresent(promptEvalCount, forKey: .promptEvalCount)
        if let promptEvalCachedCount {
            try container.encode(promptEvalCachedCount, forKey: .promptEvalCachedCount)
        } else {
            try container.encodeNil(forKey: .promptEvalCachedCount)
        }
        try container.encodeIfPresent(doneReason, forKey: .doneReason)
        try container.encodeIfPresent(ttftSeconds, forKey: .ttftSeconds)
        try container.encodeIfPresent(requestSeconds, forKey: .requestSeconds)
    }
}

struct MSBOllamaLoopbackReport: Codable, Sendable {
    let schemaVersion: Int
    let runtime: String
    let originClass: String
    let modelNameSHA256: String
    let artifactHashAlgorithm: String
    let artifactSHA256: String
    let promptTokensPerRow: Int
    let evalTokensPerRow: Int
    let timedDecodeTokensPerRow: Int
    let runs: Int
    let promptSHA256: [String]
    let levels: [MSBOllamaLoopbackLevelReport]
    let countSource: String
    var operatorBenchmarkMode: String?
    var requestedCanonical1690Profile: Bool?
    var strictM0Qualified: Bool?
    var forcedDecodeTokensExact: Bool?
    var promptCacheDisabled: Bool?
    let nativeIdenticalTokenSequences: Bool
    var runtimePerplexityEvidence: Bool?
    let canonical1690Profile: Bool
    let billingEvidence: Bool
    let timestamp: String

    static func encode(_ report: MSBOllamaLoopbackReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}

func msbOllamaSHA256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
