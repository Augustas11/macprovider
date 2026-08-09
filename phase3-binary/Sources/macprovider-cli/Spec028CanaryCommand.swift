import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

struct Spec028CanaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hardware-check",
        abstract: "Run the supported-Mac model readiness checks."
    )

    enum HardwareProfile: String, CaseIterable, ExpressibleByArgument {
        case supported16GB = "supported-16gb"
        case supported8GB = "supported-8gb"

        init?(argument: String) {
            switch argument {
            case Self.supported16GB.rawValue, "ac10": self = .supported16GB
            case Self.supported8GB.rawValue, "ac11": self = .supported8GB
            default: return nil
            }
        }
    }

    @Argument(help: "Hardware profile to check: supported-16gb or supported-8gb.")
    var kind: HardwareProfile = .supported16GB

    @Option(help: "Target model ID or local snapshot path. Defaults to the 16 GB test target.")
    var target: String?

    @Option(help: "Draft model ID or local snapshot path. Defaults to the 16 GB test draft.")
    var draft: String?

    @Option(help: "Speculative draft tokens. Default: 3.")
    var numDraftTokens: Int = 3

    @Option(help: "Maximum prompt context tokens. Defaults to the 16 GB draft cap.")
    var maxContextTokens: Int = ProviderCapacity.draftContextCap(forPhysicalMemoryGB: 16)

    @Option(help: "Number of warm baseline runs. Default: 5.")
    var baselineRuns: Int = 5

    @Option(help: "Number of warm speculative runs. Default: 5.")
    var specRuns: Int = 5

    @Option(help: "Sustained speculative window in seconds. Default: 300.")
    var sustainedSeconds: Double = 300

    @Option(help: "Trailing sustained window in seconds. Default: 60.")
    var lastWindowSeconds: Double = 60

    @Option(help: "Median speculative TPS / baseline TPS floor. Default: 1.4.")
    var ratioFloor: Double = 1.4

    @Option(help: "Trailing sustained TPS / baseline TPS floor. Default: 1.2.")
    var sustainedRatioFloor: Double = 1.2

    @Option(help: "Speculative accepted/drafted token floor. Default: 0.30.")
    var acceptanceFloor: Double = 0.30

    @Option(help: "Override the test fixture path.")
    var fixturePath: String?

    @Flag(help: "Allow running the 16 GB profile on other Apple Silicon for diagnostics only.")
    var allowNon16GBHost = false

    @Flag(help: "Allow running the 8 GB profile on other Apple Silicon for diagnostics only.")
    var allowNon8GBHost = false

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
        case .supported16GB:
            try await runAC10()
        case .supported8GB:
            try await runAC11()
        }
    }

    private func runAC10() async throws {
        let host = HostEvidence.current()
        if !allowNon16GBHost {
            guard host.isAppleSilicon16GB else {
                throw ValidationError("The 16 GB hardware check requires an M4 Mac with 16 GB memory. Re-run on supported hardware, or pass --allow-non16-gb-host for diagnostics only.")
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
            // Diagnostic-only validation path; production serve stays fail-closed.
            speculativeCacheWrapValidated: true,
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
        let acceptanceHardware = host.isAppleSilicon16GB && !allowNon16GBHost
        let finalEvaluation = evaluation.addingFailureReasons(
            acceptanceHardware ? [] : ["AC-10 acceptance hardware must be M4 16 GB"]
        )
        let result = Spec028CanaryResult(
            canary: "AC-10",
            fixtureID: fixture.fixtureID,
            targetModel: fixture.targetModel,
            draftModel: fixture.draftModel,
            targetLoadPath: Self.evidenceModelRef(targetLoadPath),
            draftLoadPath: Self.evidenceModelRef(draftLoadPath),
            numDraftTokens: numDraftTokens,
            maxContextTokens: maxContextTokens,
            host: host,
            acceptance: finalEvaluation,
            baselineSamples: baselineSamples,
            specSamples: specSamples,
            sustainedSamples: sustainedSamples,
            acceptanceHardware: acceptanceHardware
        )
        try Self.emit(result)
        guard finalEvaluation.passed else {
            throw ValidationError("The 16 GB hardware check failed. See the generated diagnostic report for details.")
        }
    }

    private func runAC11() async throws {
        let host = HostEvidence.current()
        if !allowNon8GBHost {
            guard host.isAppleSilicon8GB else {
                throw ValidationError("The 8 GB hardware check requires an M1 Mac with 8 GB memory. Re-run on supported hardware, or pass --allow-non8-gb-host for diagnostics only.")
            }
        }

        let shortChat = try Spec028CanaryFixture.load(
            path: nil,
            defaultResourceName: "small-air-short-chat",
            defaultFixturePath: "Tests/Fixtures/spec028/small-air-short-chat.json",
            label: "AC-11 short_chat"
        )
        let streamingCheck = try Spec028CanaryFixture.load(
            path: nil,
            defaultResourceName: "small-air-streaming-check",
            defaultFixturePath: "Tests/Fixtures/spec028/small-air-streaming-check.json",
            label: "AC-11 streaming_check"
        )
        guard shortChat.targetModel == streamingCheck.targetModel,
              shortChat.draftModel == streamingCheck.draftModel else {
            throw ValidationError("AC-11 fixtures must use the same target and draft models")
        }

        let targetLoadPath = target ?? shortChat.targetModel
        let draftLoadPath = draft ?? shortChat.draftModel
        let targetProvenance = try Self.localArtifactProvenance(targetLoadPath)
        let draftProvenance = try Self.localArtifactProvenance(draftLoadPath)
        let runtime = try await ModelRuntime(
            modelID: shortChat.targetModel,
            modelLoadPath: targetLoadPath,
            draftModelID: shortChat.draftModel,
            draftModelLoadPath: draftLoadPath,
            numDraftTokens: numDraftTokens,
            // Diagnostic-only validation path; production serve stays fail-closed.
            speculativeCacheWrapValidated: true,
            maxContextTokensOverride: ac11MaxContextTokens(),
            maxBatch: 1,
            warmSwapEnabled: false
        )

        let shortChatResult = try await Self.runAC11Fixture(runtime: runtime, fixture: shortChat, mode: "short_chat")
        let streamingCheckResult = try await Self.runAC11Fixture(runtime: runtime, fixture: streamingCheck, mode: "streaming_check")
        let fixtures = [shortChatResult, streamingCheckResult]
        let evaluation = Spec028AC11Evaluation.evaluate(fixtures: fixtures)
        let acceptanceHardware = host.isAppleSilicon8GB && !allowNon8GBHost
        let overridesAreArtifactBound = (target == nil || targetProvenance != nil)
            && (draft == nil || draftProvenance != nil)
        let finalEvaluation = evaluation.addingFailureReasons(
            (acceptanceHardware ? [] : ["AC-11 acceptance hardware must be M1 8 GB"])
                + (overridesAreArtifactBound ? [] : ["AC-11 local override paths require artifact-bound snapshot provenance"])
        )
        let result = Spec028AC11Result(
            canary: "AC-11",
            targetModel: shortChat.targetModel,
            draftModel: shortChat.draftModel,
            targetLoadPath: Self.evidenceModelRef(targetLoadPath),
            draftLoadPath: Self.evidenceModelRef(draftLoadPath),
            targetArtifactSHA256: targetProvenance?.artifactSHA256,
            draftArtifactSHA256: draftProvenance?.artifactSHA256,
            numDraftTokens: numDraftTokens,
            maxContextTokens: ac11MaxContextTokens(),
            host: host,
            acceptance: finalEvaluation,
            fixtures: fixtures,
            acceptanceHardware: acceptanceHardware && overridesAreArtifactBound
        )
        try Self.emit(result)
        guard finalEvaluation.passed else {
            throw ValidationError("AC-11 failed: \(finalEvaluation.failureReasons.joined(separator: "; "))")
        }
    }

    private func ac11MaxContextTokens() -> Int {
        let ac10Default = ProviderCapacity.draftContextCap(forPhysicalMemoryGB: 16)
        let ac11Default = ProviderCapacity.draftContextCap(forPhysicalMemoryGB: 8)
        return maxContextTokens == ac10Default ? ac11Default : maxContextTokens
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

    private static func localArtifactProvenance(_ value: String) throws -> Spec028LocalArtifactProvenance? {
        let expanded = (value as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard url.path == expanded, expanded.hasPrefix("/") else {
            return nil
        }
        do {
            return Spec028LocalArtifactProvenance(
                artifactSHA256: try ModelArtifactVerifier.canonicalArtifactHash(directory: url)
            )
        } catch {
            throw ValidationError("AC-11 local snapshot override is not artifact-bound: \(evidenceModelRef(value))")
        }
    }

    private static func runAC11Fixture(
        runtime: ModelRuntime,
        fixture: Spec028CanaryFixture,
        mode: String
    ) async throws -> Spec028AC11FixtureResult {
        let request = try fixture.request(forceTokenIterator: false)
        let startedAt = Date()
        let completion: CompletionResult
        let chunkCounter = LockedCounter()
        if request.stream {
            let handle = try await runtime.acquireRequestHandle(request)
            do {
                try await runtime.preflight(request, with: handle)
                completion = try await runtime.stream(request, with: handle) { chunk in
                    switch chunk {
                    case .content:
                        chunkCounter.increment()
                    case .toolCallDelta:
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
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let drafted = completion.specDecodeDraftedTokens
        let accepted = completion.specDecodeAcceptedTokens
        return Spec028AC11FixtureResult(
            fixtureID: fixture.fixtureID,
            mode: mode,
            temperature: request.temperature,
            streamed: request.stream,
            promptTokens: completion.promptTokens,
            completionTokens: completion.completionTokens,
            elapsedSeconds: elapsed,
            draftedTokens: drafted,
            acceptedTokens: accepted,
            acceptanceRate: drafted > 0 ? Double(accepted) / Double(drafted) : nil,
            chunks: chunkCounter.value,
            thermalState: ProcessInfo.processInfo.thermalState.label
        )
    }

    private static func emit<T: Encodable>(_ result: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func evidenceModelRef(_ value: String) -> String {
        ProviderStatus.publicSpecDecodeDraftModelID(value) ?? "unknown"
    }
}

/// Compatibility entry point for existing automation. Hidden from routine help so
/// provider-facing surfaces use the public `hardware-check` name.
struct LegacySpec028CanaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spec028-canary",
        shouldDisplay: false
    )

    @OptionGroup var command: Spec028CanaryCommand

    mutating func validate() throws {
        try command.validate()
    }

    mutating func run() async throws {
        try await command.run()
    }
}

struct Spec028CanaryFixture {
    static let bundledPath = "Tests/Fixtures/spec028/spec028-code-iso8601-v1.json"

    let fixtureID: String
    let targetModel: String
    let draftModel: String
    let requestBody: [String: Any]

    static func load(path: String?) throws -> Spec028CanaryFixture {
        try load(
            path: path,
            defaultResourceName: "spec028-code-iso8601-v1",
            defaultFixturePath: bundledPath,
            label: "AC-10"
        )
    }

    static func load(
        path: String?,
        defaultResourceName: String,
        defaultFixturePath: String,
        label: String
    ) throws -> Spec028CanaryFixture {
        let url: URL
        if let path {
            url = URL(fileURLWithPath: path)
        } else {
            let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let direct = cwdURL.appendingPathComponent(defaultFixturePath)
            let parent = cwdURL.appendingPathComponent("phase3-binary/\(defaultFixturePath)")
            url = Bundle.module.url(
                forResource: defaultResourceName,
                withExtension: "json",
                subdirectory: "spec028"
            ) ?? (FileManager.default.fileExists(atPath: direct.path) ? direct : parent)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ValidationError("could not read \(label) fixture \(defaultResourceName).json")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fixtureID = root["fixture_id"] as? String,
              let targetModel = root["target_model"] as? String,
              let draftModel = root["draft_model"] as? String,
              let requestBody = root["request"] as? [String: Any]
        else {
            throw ValidationError("invalid \(label) fixture \(defaultResourceName).json")
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

    func addingFailureReasons(_ reasons: [String]) -> Spec028CanaryEvaluation {
        let combined = failureReasons + reasons
        return Spec028CanaryEvaluation(
            baselineMedianTPS: baselineMedianTPS,
            specMedianTPS: specMedianTPS,
            ratio: ratio,
            acceptanceRate: acceptanceRate,
            sustainedLastWindowMedianTPS: sustainedLastWindowMedianTPS,
            sustainedLastWindowRatio: sustainedLastWindowRatio,
            ratioFloor: ratioFloor,
            sustainedRatioFloor: sustainedRatioFloor,
            acceptanceFloor: acceptanceFloor,
            passed: combined.isEmpty,
            failureReasons: combined
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

struct Spec028AC11Evaluation: Encodable, Equatable {
    let passed: Bool
    let failureReasons: [String]

    static func evaluate(fixtures: [Spec028AC11FixtureResult]) -> Spec028AC11Evaluation {
        var failures: [String] = []
        let observedModes = Set(fixtures.map(\.mode))
        for requiredMode in ["short_chat", "streaming_check"] where !observedModes.contains(requiredMode) {
            failures.append("\(requiredMode) fixture did not run")
        }

        for fixture in fixtures {
            if fixture.temperature != 0 {
                failures.append("\(fixture.mode) temperature \(fixture.temperature) != 0")
            }
            if fixture.completionTokens <= 0 {
                failures.append("\(fixture.mode) produced no completion tokens")
            }
            if fixture.draftedTokens <= 0 {
                failures.append("\(fixture.mode) produced no drafted tokens")
            }
            if fixture.acceptedTokens <= 0 {
                failures.append("\(fixture.mode) accepted no drafted tokens")
            }
            if fixture.streamed && fixture.chunks <= 0 {
                failures.append("\(fixture.mode) streamed no chunks")
            }
        }

        return Spec028AC11Evaluation(
            passed: failures.isEmpty,
            failureReasons: failures
        )
    }

    func addingFailureReasons(_ reasons: [String]) -> Spec028AC11Evaluation {
        let combined = failureReasons + reasons
        return Spec028AC11Evaluation(
            passed: combined.isEmpty,
            failureReasons: combined
        )
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

private struct Spec028AC11Result: Encodable {
    let canary: String
    let targetModel: String
    let draftModel: String
    let targetLoadPath: String
    let draftLoadPath: String
    let targetArtifactSHA256: String?
    let draftArtifactSHA256: String?
    let numDraftTokens: Int
    let maxContextTokens: Int
    let host: HostEvidence
    let acceptance: Spec028AC11Evaluation
    let fixtures: [Spec028AC11FixtureResult]
    let acceptanceHardware: Bool
}

private struct Spec028LocalArtifactProvenance: Encodable, Equatable {
    let artifactSHA256: String
}

struct Spec028AC11FixtureResult: Encodable, Equatable {
    let fixtureID: String
    let mode: String
    let temperature: Double
    let streamed: Bool
    let promptTokens: Int
    let completionTokens: Int
    let elapsedSeconds: Double
    let draftedTokens: Int
    let acceptedTokens: Int
    let acceptanceRate: Double?
    let chunks: Int
    let thermalState: String
}

private final class LockedCounter: @unchecked Sendable {
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

struct HostEvidence: Encodable, Equatable {
    let machine: String
    let chip: String
    let hardwareModel: String
    let memoryGB: Int

    var isAppleSilicon16GB: Bool {
        machine == "arm64" && chip == "apple_m4" && memoryGB == 16
    }

    var isAppleSilicon8GB: Bool {
        machine == "arm64" && chip == "apple_m1" && memoryGB == 8
    }

    static func current() -> HostEvidence {
        HostEvidence(
            machine: unameMachine(),
            chip: chipBrand(),
            hardwareModel: hardwareModelBucket(machine: unameMachine(), chip: chipBrand()),
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
        return chipFamily(from: sysctlString("machdep.cpu.brand_string"))
        #else
        return "non_apple_silicon"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(validatingCString: buffer)
    }

    private static func hardwareModelBucket(machine: String, chip: String) -> String {
        guard machine == "arm64", chip.hasPrefix("apple_") else {
            return "non_apple_silicon"
        }
        let memoryGB = Int((ProcessInfo.processInfo.physicalMemory + 1_073_741_823) / 1_073_741_824)
        return "apple_silicon_\(memoryGB)gb"
    }

    private static func chipFamily(from raw: String?) -> String {
        let value = raw?.lowercased() ?? ""
        if value.contains("m1") { return "apple_m1" }
        if value.contains("m2") { return "apple_m2" }
        if value.contains("m3") { return "apple_m3" }
        if value.contains("m4") { return "apple_m4" }
        if value.contains("m5") { return "apple_m5" }
        #if arch(arm64)
        return "apple_silicon"
        #else
        return "non_apple_silicon"
        #endif
    }
}
