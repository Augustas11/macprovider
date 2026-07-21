import ArgumentParser
import Foundation
import MacProviderCore

struct Spec028BenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "performance-check",
        abstract: "Compare speculative-decoding performance with the baseline path."
    )

    @Option(name: .customLong("fixture"), help: "Test fixture JSON path. May be repeated. Defaults to the supported 16 GB profile.")
    var fixturePaths: [String] = []

    @Option(help: "Target model local snapshot path. Overrides each fixture target model load path.")
    var target: String?

    @Option(help: "Draft model local snapshot path. Overrides each fixture draft model load path.")
    var draft: String?

    @Option(help: "Speculative draft tokens per verification round.")
    var numDraftTokens: Int = 3

    @Option(help: "Maximum prompt context tokens.")
    var maxContextTokens: Int = ProviderCapacity.draftContextCapForCurrentHost()

    @Option(help: "Number of baseline samples per fixture.")
    var baselineRuns: Int = 3

    @Option(help: "Number of speculative samples per fixture.")
    var specRuns: Int = 3

    @Option(help: "Sustained speculative window in seconds. Use 0 to skip.")
    var sustainedSeconds: Double = 0

    @Option(help: "Trailing sustained window in seconds for sustained ratio reporting.")
    var lastWindowSeconds: Double = 30

    @Option(help: "Minimum median speculative/baseline TPS ratio for a positive recommendation.")
    var recommendRatioFloor: Double = 1.15

    @Option(help: "Maximum allowed p95 latency multiplier for a positive recommendation.")
    var maxP95LatencyRatio: Double = 1.0

    @Option(help: "Maximum allowed p95 TTFT multiplier for a positive recommendation.")
    var maxP95TTFTRatio: Double = 1.0

    @Option(help: "Minimum speculative accepted/drafted token rate for a positive recommendation.")
    var recommendAcceptanceFloor: Double = 0.30

    @Flag(help: "Emit one compact JSON object per fixture instead of a single pretty-printed report.")
    var jsonl = false

    mutating func validate() throws {
        guard baselineRuns > 0 else {
            throw ValidationError("--baseline-runs must be > 0")
        }
        guard specRuns > 0 else {
            throw ValidationError("--spec-runs must be > 0")
        }
        guard sustainedSeconds >= 0 else {
            throw ValidationError("--sustained-seconds must be >= 0")
        }
        guard lastWindowSeconds > 0 else {
            throw ValidationError("--last-window-seconds must be > 0")
        }
        guard numDraftTokens >= 1 && numDraftTokens <= 16 else {
            throw ValidationError("--num-draft-tokens must be in 1...16")
        }
        guard recommendRatioFloor > 0 else {
            throw ValidationError("--recommend-ratio-floor must be > 0")
        }
        guard maxP95LatencyRatio > 0 else {
            throw ValidationError("--max-p95-latency-ratio must be > 0")
        }
        guard maxP95TTFTRatio > 0 else {
            throw ValidationError("--max-p95-ttft-ratio must be > 0")
        }
        guard recommendAcceptanceFloor >= 0 && recommendAcceptanceFloor <= 1 else {
            throw ValidationError("--recommend-acceptance-floor must be in 0...1")
        }
    }

    mutating func run() async throws {
        let fixtures = try loadFixtures()
        var results: [Spec028BenchmarkFixtureResult] = []
        for fixture in fixtures {
            results.append(try await benchmark(fixture: fixture))
            if jsonl, let latest = results.last {
                try Self.emit(latest, pretty: false)
            }
        }
        guard !jsonl else { return }
        try Self.emit(
            Spec028BenchmarkReport(
                benchmark: "SPEC-028",
                generatedAtUnixSeconds: Date().timeIntervalSince1970,
                host: HostEvidence.current(),
                binaryVersion: CoordinatorClient.binaryVersion,
                fixtures: results
            ),
            pretty: true
        )
    }

    private func loadFixtures() throws -> [Spec028CanaryFixture] {
        if fixturePaths.isEmpty {
            return [try Spec028CanaryFixture.load(path: nil)]
        }
        return try fixturePaths.map { path in
            try Spec028CanaryFixture.load(
                path: path,
                defaultResourceName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                defaultFixturePath: path,
                label: "SPEC-028 benchmark"
            )
        }
    }

    private func benchmark(fixture: Spec028CanaryFixture) async throws -> Spec028BenchmarkFixtureResult {
        let targetLoadPath = target ?? fixture.targetModel
        let draftLoadPath = draft ?? fixture.draftModel
        let runtime = try await ModelRuntime(
            modelID: fixture.targetModel,
            modelLoadPath: targetLoadPath,
            draftModelID: fixture.draftModel,
            draftModelLoadPath: draftLoadPath,
            numDraftTokens: numDraftTokens,
            maxContextTokensOverride: maxContextTokens,
            maxBatch: 1,
            warmSwapEnabled: false
        )
        let baselineRequest = try fixture.request(forceTokenIterator: true)
        let specRequest = try fixture.request(forceTokenIterator: false)
        var baselineSamples: [Spec028BenchmarkSample] = []
        var specSamples: [Spec028BenchmarkSample] = []
        var sustainedSamples: [Spec028BenchmarkSample] = []

        for _ in 0..<baselineRuns {
            baselineSamples.append(try await Self.measure(runtime: runtime, request: baselineRequest, phase: "baseline"))
        }
        for _ in 0..<specRuns {
            specSamples.append(try await Self.measure(runtime: runtime, request: specRequest, phase: "spec"))
        }

        let sustainedStartedAt = Date()
        let sustainedDeadline = sustainedStartedAt.addingTimeInterval(sustainedSeconds)
        while Date() < sustainedDeadline {
            sustainedSamples.append(try await Self.measure(runtime: runtime, request: specRequest, phase: "sustained"))
        }
        let sustainedEndedAt = Date()
        let evaluation = try Spec028BenchmarkEvaluation.evaluate(
            baselineSamples: baselineSamples,
            specSamples: specSamples,
            sustainedSamples: sustainedSamples,
            sustainedEndedAt: sustainedEndedAt,
            lastWindowSeconds: lastWindowSeconds,
            recommendRatioFloor: recommendRatioFloor,
            maxP95LatencyRatio: maxP95LatencyRatio,
            maxP95TTFTRatio: maxP95TTFTRatio,
            recommendAcceptanceFloor: recommendAcceptanceFloor
        )
        return Spec028BenchmarkFixtureResult(
            fixtureID: fixture.fixtureID,
            targetModel: fixture.targetModel,
            draftModel: fixture.draftModel,
            targetLoadPath: Self.evidenceModelRef(targetLoadPath),
            draftLoadPath: Self.evidenceModelRef(draftLoadPath),
            numDraftTokens: numDraftTokens,
            maxContextTokens: maxContextTokens,
            request: Spec028BenchmarkRequestSummary(
                stream: specRequest.stream,
                temperature: specRequest.temperature,
                topP: specRequest.topP,
                maxTokens: specRequest.maxTokens
            ),
            evaluation: evaluation,
            baselineSamples: baselineSamples,
            specSamples: specSamples,
            sustainedSamples: sustainedSamples
        )
    }

    private static func measure(
        runtime: ModelRuntime,
        request: ChatCompletionRequest,
        phase: String
    ) async throws -> Spec028BenchmarkSample {
        let startedAt = Date()
        let chunkCounter = Spec028BenchmarkLockedCounter()
        let completion: CompletionResult
        if request.stream {
            let handle = try await runtime.acquireRequestHandle(request)
            do {
                try await runtime.preflight(request, with: handle)
                completion = try await runtime.stream(request, with: handle) { chunk in
                    switch chunk {
                    case .content, .toolCallDelta:
                        chunkCounter.increment()
                    }
                }
                await runtime.unregisterInFlight(handle.registrationID)
            } catch {
                await runtime.unregisterInFlight(handle.registrationID)
                throw error
            }
        } else {
            completion = try await runtime.complete(request)
        }
        let endedAt = Date()
        let elapsed = max(endedAt.timeIntervalSince(startedAt), 0.001)
        return Spec028BenchmarkSample(
            phase: phase,
            promptTokens: completion.promptTokens,
            completionTokens: completion.completionTokens,
            elapsedSeconds: elapsed,
            tokensPerSecond: Double(completion.completionTokens) / elapsed,
            ttftMilliseconds: completion.ttftMilliseconds,
            draftedTokens: completion.specDecodeDraftedTokens,
            acceptedTokens: completion.specDecodeAcceptedTokens,
            streamedChunks: chunkCounter.value,
            endedAtUnixSeconds: endedAt.timeIntervalSince1970,
            thermalState: ProcessInfo.processInfo.thermalState.label
        )
    }

    private static func emit<T: Encodable>(_ value: T, pretty: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func evidenceModelRef(_ value: String) -> String {
        ProviderStatus.publicSpecDecodeDraftModelID(value) ?? "unknown"
    }
}

/// Compatibility entry point for existing automation. Hidden from routine help so
/// provider-facing surfaces use the public `performance-check` name.
struct LegacySpec028BenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spec028-benchmark",
        shouldDisplay: false
    )

    @OptionGroup var command: Spec028BenchmarkCommand

    mutating func validate() throws {
        try command.validate()
    }

    mutating func run() async throws {
        try await command.run()
    }
}

struct Spec028BenchmarkEvaluation: Encodable, Equatable {
    let baselineMedianTPS: Double
    let specMedianTPS: Double
    let tpsRatio: Double
    let baselineP95LatencyMS: Double
    let specP95LatencyMS: Double
    let p95LatencyRatio: Double
    let baselineP95TTFTMS: Double?
    let specP95TTFTMS: Double?
    let ttftP95Ratio: Double?
    let acceptanceRate: Double?
    let sustainedMedianTPS: Double?
    let sustainedRatio: Double?
    let recommendEnable: Bool
    let recommendationReasons: [String]

    static func evaluate(
        baselineSamples: [Spec028BenchmarkSample],
        specSamples: [Spec028BenchmarkSample],
        sustainedSamples: [Spec028BenchmarkSample],
        sustainedEndedAt: Date,
        lastWindowSeconds: Double,
        recommendRatioFloor: Double,
        maxP95LatencyRatio: Double,
        maxP95TTFTRatio: Double,
        recommendAcceptanceFloor: Double
    ) throws -> Spec028BenchmarkEvaluation {
        guard let baselineMedianTPS = median(baselineSamples.map(\.tokensPerSecond)), baselineMedianTPS > 0 else {
            throw ValidationError("SPEC-028 benchmark baseline did not produce throughput samples")
        }
        guard let specMedianTPS = median(specSamples.map(\.tokensPerSecond)) else {
            throw ValidationError("SPEC-028 benchmark speculative run did not produce throughput samples")
        }
        let baselineLatencyP95 = percentile95(baselineSamples.map { $0.elapsedSeconds * 1_000 })
        let specLatencyP95 = percentile95(specSamples.map { $0.elapsedSeconds * 1_000 })
        guard let baselineLatencyP95, baselineLatencyP95 > 0, let specLatencyP95 else {
            throw ValidationError("SPEC-028 benchmark did not produce latency samples")
        }

        let baselineTTFTP95 = percentile95(baselineSamples.compactMap(\.ttftMilliseconds).map(Double.init))
        let specTTFTP95 = percentile95(specSamples.compactMap(\.ttftMilliseconds).map(Double.init))
        let ttftRatio = Self.ratio(numerator: specTTFTP95, denominator: baselineTTFTP95)
        let drafted = specSamples.reduce(0) { $0 + $1.draftedTokens }
        let accepted = specSamples.reduce(0) { $0 + $1.acceptedTokens }
        let acceptanceRate = drafted > 0 ? Double(accepted) / Double(drafted) : nil
        let lastWindowStart = sustainedEndedAt.timeIntervalSince1970 - lastWindowSeconds
        let lastWindowSamples = sustainedSamples.filter { $0.endedAtUnixSeconds >= lastWindowStart }
        let sustainedMedian = median(lastWindowSamples.map(\.tokensPerSecond))
        let sustainedRatio = sustainedMedian.map { $0 / baselineMedianTPS }
        let tpsRatio = specMedianTPS / baselineMedianTPS
        let p95LatencyRatio = specLatencyP95 / baselineLatencyP95

        var reasons: [String] = []
        if tpsRatio < recommendRatioFloor {
            reasons.append(String(format: "TPS ratio %.3f < %.3f", tpsRatio, recommendRatioFloor))
        }
        if p95LatencyRatio > maxP95LatencyRatio {
            reasons.append(String(format: "p95 latency ratio %.3f > %.3f", p95LatencyRatio, maxP95LatencyRatio))
        }
        if let ttftRatio {
            if ttftRatio > maxP95TTFTRatio {
                reasons.append(String(format: "p95 TTFT ratio %.3f > %.3f", ttftRatio, maxP95TTFTRatio))
            }
        } else {
            reasons.append("p95 TTFT ratio unavailable")
        }
        if acceptanceRate == nil || acceptanceRate! < recommendAcceptanceFloor {
            reasons.append(String(format: "acceptance %.3f < %.3f", acceptanceRate ?? 0, recommendAcceptanceFloor))
        }
        if let sustainedRatio, sustainedRatio < recommendRatioFloor {
            reasons.append(String(format: "sustained TPS ratio %.3f < %.3f", sustainedRatio, recommendRatioFloor))
        }

        return Spec028BenchmarkEvaluation(
            baselineMedianTPS: baselineMedianTPS,
            specMedianTPS: specMedianTPS,
            tpsRatio: tpsRatio,
            baselineP95LatencyMS: baselineLatencyP95,
            specP95LatencyMS: specLatencyP95,
            p95LatencyRatio: p95LatencyRatio,
            baselineP95TTFTMS: baselineTTFTP95,
            specP95TTFTMS: specTTFTP95,
            ttftP95Ratio: ttftRatio,
            acceptanceRate: acceptanceRate,
            sustainedMedianTPS: sustainedMedian,
            sustainedRatio: sustainedRatio,
            recommendEnable: reasons.isEmpty,
            recommendationReasons: reasons
        )
    }

    private static func ratio(numerator: Double?, denominator: Double?) -> Double? {
        guard let numerator, let denominator, denominator > 0 else {
            return nil
        }
        return numerator / denominator
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private static func percentile95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[min(rank, sorted.count - 1)]
    }
}

struct Spec028BenchmarkSample: Encodable, Equatable {
    let phase: String
    let promptTokens: Int
    let completionTokens: Int
    let elapsedSeconds: Double
    let tokensPerSecond: Double
    let ttftMilliseconds: Int64?
    let draftedTokens: Int
    let acceptedTokens: Int
    let streamedChunks: Int
    let endedAtUnixSeconds: Double
    let thermalState: String
}

private struct Spec028BenchmarkReport: Encodable {
    let benchmark: String
    let generatedAtUnixSeconds: Double
    let host: HostEvidence
    let binaryVersion: String
    let fixtures: [Spec028BenchmarkFixtureResult]
}

private struct Spec028BenchmarkFixtureResult: Encodable {
    let fixtureID: String
    let targetModel: String
    let draftModel: String
    let targetLoadPath: String
    let draftLoadPath: String
    let numDraftTokens: Int
    let maxContextTokens: Int
    let request: Spec028BenchmarkRequestSummary
    let evaluation: Spec028BenchmarkEvaluation
    let baselineSamples: [Spec028BenchmarkSample]
    let specSamples: [Spec028BenchmarkSample]
    let sustainedSamples: [Spec028BenchmarkSample]
}

private struct Spec028BenchmarkRequestSummary: Encodable {
    let stream: Bool
    let temperature: Double
    let topP: Double
    let maxTokens: Int?
}

private final class Spec028BenchmarkLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
