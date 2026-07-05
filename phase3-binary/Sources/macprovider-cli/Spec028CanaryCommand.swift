import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

struct Spec028CanaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spec028-canary",
        abstract: "Run SPEC-028 hardware acceptance canaries."
    )

    enum CanaryKind: String, ExpressibleByArgument {
        case ac10
    }

    @Argument(help: "Canary to run. Currently: ac10.")
    var kind: CanaryKind = .ac10

    @Option(help: "Target model ID or local snapshot path. Defaults to the AC-10 fixture target.")
    var target: String?

    @Option(help: "Draft model ID or local snapshot path. Defaults to the AC-10 fixture draft.")
    var draft: String?

    @Option(help: "Speculative draft tokens. AC-10 default: 3.")
    var numDraftTokens: Int = 3

    @Option(help: "Maximum prompt context tokens. Defaults to the 16 GB draft cap.")
    var maxContextTokens: Int = ProviderCapacity.draftContextCap(forPhysicalMemoryGB: 16)

    @Option(help: "Number of warm baseline runs. AC-10 default: 5.")
    var baselineRuns: Int = 5

    @Option(help: "Number of warm speculative runs. AC-10 default: 5.")
    var specRuns: Int = 5

    @Option(help: "Sustained speculative window in seconds. AC-10 default: 300.")
    var sustainedSeconds: Double = 300

    @Option(help: "Trailing sustained window in seconds. AC-10 default: 60.")
    var lastWindowSeconds: Double = 60

    @Option(help: "Median speculative TPS / baseline TPS floor. AC-10 default: 1.4.")
    var ratioFloor: Double = 1.4

    @Option(help: "Trailing sustained TPS / baseline TPS floor. AC-10 default: 1.2.")
    var sustainedRatioFloor: Double = 1.2

    @Option(help: "Speculative accepted/drafted token floor. AC-10 default: 0.30.")
    var acceptanceFloor: Double = 0.30

    @Option(help: "Override AC-10 fixture path.")
    var fixturePath: String?

    @Flag(help: "Allow running on non-16 GB Apple Silicon for diagnostics. Evidence does not satisfy AC-10.")
    var allowNon16GBHost = false

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
    }

    mutating func run() async throws {
        switch kind {
        case .ac10:
            try await runAC10()
        }
    }

    private func runAC10() async throws {
        let host = HostEvidence.current()
        if !allowNon16GBHost {
            guard host.isAppleSilicon16GB else {
                throw ValidationError("AC-10 requires 16 GB Apple Silicon; host=\(host.machine) chip=\(host.chip) memory_gb=\(host.memoryGB). Re-run only on air5/equivalent 16 GB hardware, or pass --allow-non16-gb-host for non-acceptance diagnostics.")
            }
        }

        let fixture = try Spec028CanaryFixture.load(path: fixturePath)
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
        var baselineSamples: [Spec028CanarySample] = []
        var specSamples: [Spec028CanarySample] = []
        var sustainedSamples: [Spec028CanarySample] = []

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

        let evaluation = try Spec028CanaryEvaluation.evaluate(
            baselineSamples: baselineSamples,
            specSamples: specSamples,
            sustainedSamples: sustainedSamples,
            sustainedEndedAt: sustainedEndedAt,
            lastWindowSeconds: lastWindowSeconds,
            ratioFloor: ratioFloor,
            sustainedRatioFloor: sustainedRatioFloor,
            acceptanceFloor: acceptanceFloor
        )
        let result = Spec028CanaryResult(
            canary: "AC-10",
            fixtureID: fixture.fixtureID,
            targetModel: fixture.targetModel,
            draftModel: fixture.draftModel,
            targetLoadPath: targetLoadPath,
            draftLoadPath: draftLoadPath,
            numDraftTokens: numDraftTokens,
            maxContextTokens: maxContextTokens,
            host: host,
            acceptance: evaluation,
            baselineSamples: baselineSamples,
            specSamples: specSamples,
            sustainedSamples: sustainedSamples,
            acceptanceHardware: host.isAppleSilicon16GB && !allowNon16GBHost
        )
        try Self.emit(result)
        guard evaluation.passed else {
            throw ValidationError("AC-10 failed: \(evaluation.failureReasons.joined(separator: "; "))")
        }
    }

    private static func measure(
        runtime: ModelRuntime,
        request: ChatCompletionRequest,
        phase: String
    ) async throws -> Spec028CanarySample {
        let startedAt = Date()
        let completion = try await runtime.complete(request)
        let endedAt = Date()
        let elapsed = max(endedAt.timeIntervalSince(startedAt), 0.001)
        let tps = Double(completion.completionTokens) / elapsed
        return Spec028CanarySample(
            phase: phase,
            generatedTokens: completion.completionTokens,
            elapsedSeconds: elapsed,
            tokensPerSecond: tps,
            draftedTokens: completion.specDecodeDraftedTokens,
            acceptedTokens: completion.specDecodeAcceptedTokens,
            endedAtUnixSeconds: endedAt.timeIntervalSince1970,
            thermalState: ProcessInfo.processInfo.thermalState.label
        )
    }

    private static func emit(_ result: Spec028CanaryResult) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct Spec028CanaryFixture {
    static let bundledPath = "Tests/Fixtures/spec028/spec028-code-iso8601-v1.json"

    let fixtureID: String
    let targetModel: String
    let draftModel: String
    let requestBody: [String: Any]

    static func load(path: String?) throws -> Spec028CanaryFixture {
        let url: URL
        if let path {
            url = URL(fileURLWithPath: path)
        } else {
            let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let direct = cwdURL.appendingPathComponent(bundledPath)
            let parent = cwdURL.appendingPathComponent("phase3-binary/\(bundledPath)")
            if FileManager.default.fileExists(atPath: direct.path) {
                url = direct
            } else {
                url = parent
            }
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fixtureID = root["fixture_id"] as? String,
              let targetModel = root["target_model"] as? String,
              let draftModel = root["draft_model"] as? String,
              let requestBody = root["request"] as? [String: Any]
        else {
            throw ValidationError("invalid AC-10 fixture: \(url.path)")
        }
        return Spec028CanaryFixture(
            fixtureID: fixtureID,
            targetModel: targetModel,
            draftModel: draftModel,
            requestBody: requestBody
        )
    }

    func request(forceTokenIterator: Bool) throws -> ChatCompletionRequest {
        var body = requestBody
        body["model"] = targetModel
        if forceTokenIterator {
            // AC-10 baseline keeps prompt and generation parameters identical
            // while denying the speculative route through the FR-5 allowlist.
            body["logprobs"] = true
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try ChatCompletionRequest.parse(data: data)
    }
}

struct Spec028CanaryEvaluation: Encodable, Equatable {
    let baselineMedianTPS: Double
    let specMedianTPS: Double
    let ratio: Double
    let acceptanceRate: Double?
    let sustainedLastWindowMedianTPS: Double?
    let sustainedLastWindowRatio: Double?
    let ratioFloor: Double
    let sustainedRatioFloor: Double
    let acceptanceFloor: Double
    let passed: Bool
    let failureReasons: [String]

    static func evaluate(
        baselineSamples: [Spec028CanarySample],
        specSamples: [Spec028CanarySample],
        sustainedSamples: [Spec028CanarySample],
        sustainedEndedAt: Date,
        lastWindowSeconds: Double,
        ratioFloor: Double,
        sustainedRatioFloor: Double,
        acceptanceFloor: Double
    ) throws -> Spec028CanaryEvaluation {
        guard let baselineMedian = median(baselineSamples.map(\.tokensPerSecond)), baselineMedian > 0 else {
            throw ValidationError("AC-10 baseline did not produce throughput samples")
        }
        guard let specMedian = median(specSamples.map(\.tokensPerSecond)) else {
            throw ValidationError("AC-10 spec run did not produce throughput samples")
        }
        let drafted = specSamples.reduce(0) { $0 + $1.draftedTokens }
        let accepted = specSamples.reduce(0) { $0 + $1.acceptedTokens }
        let acceptanceRate = drafted > 0 ? Double(accepted) / Double(drafted) : nil
        let ratio = specMedian / baselineMedian
        let lastWindowStart = sustainedEndedAt.timeIntervalSince1970 - lastWindowSeconds
        let lastWindowSamples = sustainedSamples.filter { $0.endedAtUnixSeconds >= lastWindowStart }
        let sustainedMedian = median(lastWindowSamples.map(\.tokensPerSecond))
        let sustainedRatio = sustainedMedian.map { $0 / baselineMedian }

        var failures: [String] = []
        if ratio < ratioFloor {
            failures.append(String(format: "spec ratio %.3f < %.3f", ratio, ratioFloor))
        }
        if acceptanceRate == nil || acceptanceRate! < acceptanceFloor {
            failures.append(String(format: "acceptance %.3f < %.3f", acceptanceRate ?? 0, acceptanceFloor))
        }
        if sustainedSamples.isEmpty {
            failures.append("sustained window produced no samples")
        } else if sustainedRatio == nil || sustainedRatio! < sustainedRatioFloor {
            failures.append(String(format: "sustained ratio %.3f < %.3f", sustainedRatio ?? 0, sustainedRatioFloor))
        }

        return Spec028CanaryEvaluation(
            baselineMedianTPS: baselineMedian,
            specMedianTPS: specMedian,
            ratio: ratio,
            acceptanceRate: acceptanceRate,
            sustainedLastWindowMedianTPS: sustainedMedian,
            sustainedLastWindowRatio: sustainedRatio,
            ratioFloor: ratioFloor,
            sustainedRatioFloor: sustainedRatioFloor,
            acceptanceFloor: acceptanceFloor,
            passed: failures.isEmpty,
            failureReasons: failures
        )
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
}

struct Spec028CanarySample: Encodable, Equatable {
    let phase: String
    let generatedTokens: Int
    let elapsedSeconds: Double
    let tokensPerSecond: Double
    let draftedTokens: Int
    let acceptedTokens: Int
    let endedAtUnixSeconds: Double
    let thermalState: String
}

private struct Spec028CanaryResult: Encodable {
    let canary: String
    let fixtureID: String
    let targetModel: String
    let draftModel: String
    let targetLoadPath: String
    let draftLoadPath: String
    let numDraftTokens: Int
    let maxContextTokens: Int
    let host: HostEvidence
    let acceptance: Spec028CanaryEvaluation
    let baselineSamples: [Spec028CanarySample]
    let specSamples: [Spec028CanarySample]
    let sustainedSamples: [Spec028CanarySample]
    let acceptanceHardware: Bool
}

struct HostEvidence: Encodable, Equatable {
    let machine: String
    let chip: String
    let memoryGB: Int

    var isAppleSilicon16GB: Bool {
        machine == "arm64" && chip.contains("Apple") && memoryGB == 16
    }

    static func current() -> HostEvidence {
        HostEvidence(
            machine: unameMachine(),
            chip: chipBrand(),
            memoryGB: Int((ProcessInfo.processInfo.physicalMemory + 1_073_741_823) / 1_073_741_824)
        )
    }

    private static func unameMachine() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "unknown"
            }
        }
    }

    private static func chipBrand() -> String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "unknown"
        #endif
    }
}
