import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import MLXLMCommon

// Lab-only: compiled out of plain release builds, command type and
// registration included, so a production binary carries no lab surface.
#if DEBUG || MACPROVIDER_LAB_HARNESS
struct NativeMTPBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "native-mtp-bench",
        abstract: "Run the hidden SPEC-048-R015 native MTP throughput bench.",
        shouldDisplay: false
    )

    @Option(name: .customLong("root"), help: "Fixture root containing target/ and mtp/ snapshot directories.")
    var root: String

    @Option(name: .customLong("model-id"), help: "Model ID bound into requests/runtime.")
    var modelID: String = nativeMTPHardwareDefaultModelID

    @Option(name: .customLong("policy"), help: "Frozen preregistration policy JSON.")
    var policyPath: String

    @Option(name: .customLong("out"), help: "Output JSONL path.")
    var outPath: String

    @Option(name: .customLong("only-cell"), help: "Optional cell id for resumable matrix runs.")
    var onlyCell: String?

    @Option(name: .customLong("provider-commit"), help: "Provider git commit for the header.")
    var providerCommit: String

    @Option(
        name: .customLong("phase"),
        help: "all (default): matrix cells then the sustained window; matrix: matrix cells only; sustained: the sustained window only, reusing the matrix records already in --out."
    )
    var phase: NativeMTPBenchPhase = .all

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            FileHandle.standardError.write(Data("native-mtp-bench: set MACPROVIDER_NATIVE_MTP_E2E=1 on the Mac Studio\n".utf8))
            throw ExitCode(2)
        }
        try NativeMTPHardwareE2ERunner.requireStudioHost()
        guard providerCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw ValidationError("--provider-commit must be lowercase 40-hex")
        }
        let bench = try await NativeMTPBenchRunner(
            rootPath: root,
            modelID: modelID,
            policyPath: policyPath,
            outPath: outPath,
            onlyCell: onlyCell,
            providerCommit: providerCommit,
            phase: phase
        )
        try await bench.run()
    }
}

/// SPEC-048-R015 bench phases. The sustained window is a separate phase on the
/// same frozen policy and --out: it never re-runs the sustained cell's matrix
/// blocks, which the analyzer pairs with the sustained records.
enum NativeMTPBenchPhase: String, ExpressibleByArgument, Sendable {
    case all
    case matrix
    case sustained
}

private final class NativeMTPBenchRunner {
    private let root: URL
    private let modelID: String
    private let policyURL: URL
    private let outURL: URL
    private let onlyCell: String?
    private let providerCommit: String
    private let phase: NativeMTPBenchPhase
    private let policy: NativeMTPBenchPolicy
    private let policySHA256: String
    /// The native runtime's scheduler load-gate recorder for the current
    /// cell fixture (SPEC-048-R015 gated-cell evidence).
    private var nativeLoadGateRecorder: NativeMTPLoadGateRecorder?

    init(
        rootPath: String,
        modelID: String,
        policyPath: String,
        outPath: String,
        onlyCell: String?,
        providerCommit: String,
        phase: NativeMTPBenchPhase
    ) async throws {
        self.root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        self.modelID = modelID
        self.policyURL = URL(fileURLWithPath: (policyPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        self.outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        self.onlyCell = onlyCell
        self.providerCommit = providerCommit
        self.phase = phase
        self.policySHA256 = try Self.sha256(of: self.policyURL)
        self.policy = try NativeMTPBenchPolicy.load(from: self.policyURL)
    }

    func run() async throws {
        if let onlyCell, policy.cell(id: onlyCell) == nil {
            throw NativeMTPBenchError.invalidPolicy("--only-cell does not identify a policy matrix cell")
        }
        if phase == .sustained {
            guard policy.sustainedSeconds > 0 else {
                throw NativeMTPBenchError.invalidPolicy("--phase sustained needs sustained_seconds > 0")
            }
            if let onlyCell, onlyCell != policy.sustainedCellID {
                throw NativeMTPBenchError.invalidPolicy("--phase sustained runs only sustained_cell_id")
            }
        }
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = root.appendingPathComponent("mtp", isDirectory: true)
        try Self.requireDirectory(targetDirectory)
        try Self.requireDirectory(mtpDirectory)
        let targetIdentity = try MLXSnapshotIdentity.compute(directory: targetDirectory)
        let mtpIdentity = try MLXSnapshotIdentity.compute(directory: mtpDirectory)
        let tokenizerSHA = try Self.sha256(of: targetDirectory.appendingPathComponent("tokenizer.json"))
        try policy.validateObserved(modelID: modelID, targetSHA256: targetIdentity.digest, mtpSHA256: mtpIdentity.digest, tokenizerSHA256: tokenizerSHA)
        let environment = NativeMTPBenchEnvironment.capture(providerCommit: providerCommit)
        try policy.validateObserved(environment: environment)

        let parent = outURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let existing = try NativeMTPExistingEvidence.loadIfPresent(
            url: outURL,
            policySHA256: policySHA256,
            providerCommit: providerCommit,
            modelID: modelID,
            targetSHA256: targetIdentity.digest,
            mtpSHA256: mtpIdentity.digest,
            tokenizerSHA256: tokenizerSHA,
            environment: environment
        )
        if existing.hasRecords, onlyCell == nil, phase != .sustained {
            throw NativeMTPBenchError.assertionFailed(
                "refusing to append a full matrix to non-empty --out; use --only-cell to resume"
            )
        }
        let writer = try NativeMTPJSONLWriter(url: outURL, append: existing.hasRecords)
        defer { try? writer.close() }

        if !existing.hasRecords {
            var header = baseHeader(
                targetIdentity: targetIdentity,
                mtpIdentity: mtpIdentity,
                tokenizerSHA256: tokenizerSHA,
                environment: environment
            )
            header["unavailable_metrics"] = []
            try writer.write(header)
        }

        if phase != .sustained {
            for cell in policy.matrixCells {
                guard onlyCell == nil || onlyCell == cell.id else { continue }
                try await runCell(
                    cell,
                    writer: writer,
                    completedBlocks: existing.completedMatrixBlocks[cell.id] ?? [],
                    completedWarmups: existing.completedWarmups[cell.id] ?? []
                )
            }
        }
        if phase != .matrix, policy.sustainedSeconds > 0, onlyCell == nil || onlyCell == policy.sustainedCellID {
            try await runSustained(
                writer: writer,
                completedSeconds: existing.sustainedSeconds[policy.sustainedCellID] ?? 0,
                startingBlock: existing.nextSustainedBlock[policy.sustainedCellID] ?? 0
            )
        }
    }

    private func runCell(
        _ cell: NativeMTPBenchCell,
        writer: NativeMTPJSONLWriter,
        completedBlocks: Set<Int>,
        completedWarmups: Set<Int>
    ) async throws {
        let fixture = try await fixture(for: cell)
        for warmup in 0..<policy.warmupRuns {
            let block = -1 - warmup
            guard !completedWarmups.contains(block) else { continue }
            let prompts = try await makePrompts(container: fixture.runtimes.targetContainer, cell: cell, block: block)
            _ = try await runPath(.ordinary, cell: cell, block: block, order: 0, prompts: prompts, runtime: fixture.runtimes.ordinary, fixture: fixture, writer: writer, warmup: true)
            _ = try await runPath(.nativeMTP, cell: cell, block: block, order: 1, prompts: prompts, runtime: fixture.runtimes.native, fixture: fixture, writer: writer, warmup: true)
        }
        let nativeFirstByBlock = NativeMTPBenchPolicy.nativeFirstOrder(seed: policy.seed, cell: cell, blocks: policy.blocks)
        for block in 0..<policy.blocks {
            guard !completedBlocks.contains(block) else { continue }
            let prompts = try await makePrompts(container: fixture.runtimes.targetContainer, cell: cell, block: block)
            let nativeFirst = nativeFirstByBlock[block]
            var ordinaryResult: NativeMTPBenchRunResult?
            var nativeResult: NativeMTPBenchRunResult?
            for order in 0..<2 {
                let runNative = nativeFirst ? order == 0 : order == 1
                if runNative {
                    nativeResult = try await runPath(.nativeMTP, cell: cell, block: block, order: order, prompts: prompts, runtime: fixture.runtimes.native, fixture: fixture, writer: nil, warmup: false)
                } else {
                    ordinaryResult = try await runPath(.ordinary, cell: cell, block: block, order: order, prompts: prompts, runtime: fixture.runtimes.ordinary, fixture: fixture, writer: nil, warmup: false)
                }
            }
            guard var ordinary = ordinaryResult, var native = nativeResult else {
                throw NativeMTPBenchError.assertionFailed("missing paired block result")
            }
            let mismatch = parityMismatch(ordinary: ordinary, native: native)
            ordinary.parityMismatch = mismatch
            native.parityMismatch = mismatch
            try writer.write(ordinary.record(policySHA256: policySHA256, sustained: false, warmup: false))
            try writer.write(native.record(policySHA256: policySHA256, sustained: false, warmup: false))
        }
    }

    private func runSustained(
        writer: NativeMTPJSONLWriter,
        completedSeconds: Double,
        startingBlock: Int
    ) async throws {
        guard let cell = policy.cell(id: policy.sustainedCellID) else {
            throw NativeMTPBenchError.invalidPolicy("sustained_cell_id does not identify a matrix cell")
        }
        let fixture = try await fixture(for: cell)
        let remainingSeconds = max(0, Double(policy.sustainedSeconds) - completedSeconds)
        let windowStarted = Date()
        let deadline = Date().addingTimeInterval(remainingSeconds)
        var block = startingBlock
        while Date() < deadline {
            let prompts = try await makePrompts(container: fixture.runtimes.targetContainer, cell: cell, block: 10_000 + block)
            let nativeFirst = block.isMultiple(of: 2)
            var ordinaryResult: NativeMTPBenchRunResult?
            var nativeResult: NativeMTPBenchRunResult?
            for order in 0..<2 {
                let runNative = nativeFirst ? order == 0 : order == 1
                if runNative {
                    nativeResult = try await runPath(.nativeMTP, cell: cell, block: block, order: order, prompts: prompts, runtime: fixture.runtimes.native, fixture: fixture, writer: nil, warmup: false)
                } else {
                    ordinaryResult = try await runPath(.ordinary, cell: cell, block: block, order: order, prompts: prompts, runtime: fixture.runtimes.ordinary, fixture: fixture, writer: nil, warmup: false)
                }
            }
            guard var ordinary = ordinaryResult, var native = nativeResult else {
                throw NativeMTPBenchError.assertionFailed("missing sustained pair")
            }
            let mismatch = parityMismatch(ordinary: ordinary, native: native)
            ordinary.parityMismatch = mismatch
            native.parityMismatch = mismatch
            let elapsed = completedSeconds + Date().timeIntervalSince(windowStarted)
            try writer.write(ordinary.record(
                policySHA256: policySHA256,
                sustained: true,
                warmup: false,
                sustainedWindowElapsedSeconds: elapsed
            ))
            try writer.write(native.record(
                policySHA256: policySHA256,
                sustained: true,
                warmup: false,
                sustainedWindowElapsedSeconds: elapsed
            ))
            block += 1
        }
    }

    private func fixture(for cell: NativeMTPBenchCell) async throws -> NativeMTPHardwareRuntimeFixture {
        // SPEC-023-R024 qualifies 2...8 slots, so a one-slot cell runs one
        // concurrent request against the smallest qualified two-slot runtime;
        // the ordinary and native runtimes share that shape.
        let qualifiedSlots = policy.qualifiedSlots(for: cell)
        let maxBlocks = NativeMTPHardwareE2ERunner.sizedMaxPhysicalBlocks(
            slots: qualifiedSlots,
            promptTokens: cell.promptTokens,
            outputTokens: cell.maxTokens
        )
        let runner = NativeMTPHardwareE2ERunner(
            rootPath: root.path,
            modelID: modelID,
            maxBatch: qualifiedSlots,
            maxNativeActiveRows: policy.maxNativeActiveRows(for: cell),
            maxPromptTokens: policy.maximumPromptTokens ?? 1_048_576,
            maxPhysicalBlocks: maxBlocks
        )
        let fixture = try await runner.loadRuntimeFixture(
            maxContextTokens: cell.promptTokens + cell.maxTokens + 256,
            ordinaryAdmissionRecorder: nil,
            nativeAdmissionRecorder: NativeMTPHardwareAdmissionRecorder()
        )
        let recorder = NativeMTPLoadGateRecorder()
        guard await fixture.runtimes.native.installLabNativeMTPLoadGateRecorder(recorder) else {
            throw NativeMTPBenchError.assertionFailed("native runtime has no continuous-batch scheduler")
        }
        nativeLoadGateRecorder = recorder
        return fixture
    }

    private func runPath(
        _ path: NativeMTPBenchPath,
        cell: NativeMTPBenchCell,
        block: Int,
        order: Int,
        prompts: [String],
        runtime: ModelRuntime,
        fixture: NativeMTPHardwareRuntimeFixture,
        writer: NativeMTPJSONLWriter?,
        warmup: Bool
    ) async throws -> NativeMTPBenchRunResult {
        let statusBefore = await runtime.currentSnapshot().nativeMTPStatus
        let memorySampler = NativeMTPMemorySampler()
        memorySampler.start()
        let started = Date()
        let thermalStart = ProcessInfo.processInfo.thermalState.label
        let modelID = self.modelID
        let temperature = policy.temperature
        let arrivalIntervalNanoseconds = UInt64(policy.arrivalIntervalMS) * 1_000_000
        let results = try await withThrowingTaskGroup(of: NativeMTPBenchRequestResult.self) { group in
            for (index, prompt) in prompts.enumerated() {
                group.addTask {
                    if arrivalIntervalNanoseconds > 0, index > 0 {
                        try await Task.sleep(nanoseconds: UInt64(index) * arrivalIntervalNanoseconds)
                    }
                    // Both paths use the same request ID (separate runtimes),
                    // so a sampled row draws the same seeded stream on each.
                    let requestID = "\(cell.id)-b\(block)-r\(index)"
                    let request = try Self.makeRequest(
                        modelID: modelID,
                        requestID: requestID,
                        prompt: prompt,
                        maxTokens: cell.maxTokens,
                        temperature: temperature
                    )
                    return try await Self.runStreamingRequest(request, runtime: runtime)
                }
            }
            var values: [NativeMTPBenchRequestResult] = []
            for try await value in group {
                values.append(value)
            }
            return values.sorted { $0.requestID < $1.requestID }
        }
        let ended = Date()
        memorySampler.stop()
        let statusAfter = await runtime.currentSnapshot().nativeMTPStatus
        let statusDelta = NativeMTPStatusDelta(before: statusBefore, after: statusAfter)
        let wall = max(ended.timeIntervalSince(started), 0.000_001)
        let committed = results.reduce(0) { $0 + $1.completion.completionTokens }
        let decodeTimings = results.map { result in
            let startOffset = result.startedAt.timeIntervalSince(started)
            return NativeMTPBenchDecodeTiming(
                completionTokens: result.completion.completionTokens,
                firstTokenOffset: result.ttftSeconds.map { startOffset + $0 },
                endOffset: startOffset + result.wallSeconds
            )
        }
        let ttfts = results.compactMap(\.ttftSeconds)
        let allGaps = results.flatMap(\.interTokenGaps)
        let peakFootprint = memorySampler.peakPhysFootprintBytes
        let admissions = path == .nativeMTP
            ? fixture.nativeAdmissionRecorder?.requestSnapshot().filter { item in
                item.requestID.map { Set(results.map(\.requestID)).contains($0) } ?? false
            } ?? []
            : []
        // A SPEC-048-R007 load-gate downgrade is the policy working, not a
        // fallback; every other non-native admission still fails the run.
        let loadGateDowngrades = admissions.filter {
            $0.admission.effectivePath != .nativeMTP
                && $0.admission.selection.nativeMTPReason == .capacityAboveNativeBound
        }.count
        var run = NativeMTPBenchRunResult(
            cell: cell,
            blockIndex: block,
            path: path,
            orderPosition: order,
            wallSeconds: wall,
            requests: results,
            committedCompletionTokens: committed,
            aggregateTPS: Double(committed) / wall,
            perRequestTPS: results.map { Double($0.completion.completionTokens) / max($0.wallSeconds, 0.000_001) },
            aggregateDecodeTPS: NativeMTPBenchDecodeThroughput.aggregate(decodeTimings),
            perRequestDecodeTPS: results.map {
                NativeMTPBenchDecodeThroughput.perRequest(
                    completionTokens: $0.completion.completionTokens,
                    ttftSeconds: $0.ttftSeconds,
                    wallSeconds: $0.wallSeconds
                )
            },
            ttftP50: percentile(ttfts, 0.50),
            ttftP95: percentile(ttfts, 0.95),
            interTokenGapP50: percentile(allGaps, 0.50),
            interTokenGapP95: percentile(allGaps, 0.95),
            rawInterTokenGaps: results.map(\.interTokenGaps),
            finishReasons: results.map(\.completion.finishReason),
            capacityRejections: Int(statusDelta.capacityRejections),
            fallbacks: Int(statusDelta.preoutputFallbacks + statusDelta.postoutputFailures),
            errors: 0,
            nativeAdmissions: admissions.filter { $0.admission.effectivePath == .nativeMTP }.count,
            nativeRequests: path == .nativeMTP ? results.count : 0,
            nonNativeAdmissions: admissions.filter { $0.admission.effectivePath != .nativeMTP }.count - loadGateDowngrades,
            loadGateDowngrades: loadGateDowngrades,
            missingNativeAdmissions: path == .nativeMTP ? max(0, results.count - admissions.count) : 0,
            effectivePaths: admissions.map {
                [
                    "request_id": $0.requestID ?? "",
                    "effective_path": $0.admission.effectivePath.rawValue,
                    "selector_reason": $0.admission.selection.nativeMTPReason?.rawValue ?? "",
                    "other_active_rows": $0.otherActiveRows,
                ] as [String: Any]
            },
            statusDelta: statusDelta,
            loadGate: path == .nativeMTP
                ? nativeLoadGateRecorder?.summary(requestIDs: Set(results.map(\.requestID)))
                : nil,
            targetForwardsPerCommittedToken: path == .nativeMTP && committed > 0
                ? Double(statusDelta.targetForwards) / Double(committed)
                : nil,
            peakPhysFootprintBytes: peakFootprint,
            minAvailableMemoryBytes: memorySampler.minAvailableBytes,
            minAvailableMemoryFraction: memorySampler.minAvailableFraction,
            thermalStart: thermalStart,
            thermalEnd: ProcessInfo.processInfo.thermalState.label,
            parityMismatch: false
        )
        if path == .nativeMTP, run.nonNativeAdmissions > 0 || run.missingNativeAdmissions > 0 {
            run.errors += 1
        }
        if let writer {
            try writer.write(run.record(policySHA256: policySHA256, sustained: false, warmup: warmup))
        }
        return run
    }

    private func makePrompts(container: ModelContainer, cell: NativeMTPBenchCell, block: Int) async throws -> [String] {
        try await container.perform { context in
            try (0..<cell.slots).map { row in
                var salt = 0
                var text = "Native MTP R015 deterministic prompt cell \(cell.id) block \(block) row \(row)."
                var encoded = context.tokenizer.encode(text: text, addSpecialTokens: true)
                while encoded.count < cell.promptTokens {
                    text += " measurement-\(block)-\(row)-\(salt) throughput parity tokens"
                    encoded = context.tokenizer.encode(text: text, addSpecialTokens: true)
                    salt += 1
                }
                let lower = Int(floor(Double(cell.promptTokens) * 0.98))
                let upper = Int(ceil(Double(cell.promptTokens) * 1.02))
                guard (lower...upper).contains(encoded.count) else {
                    throw NativeMTPBenchError.assertionFailed("prompt token count \(encoded.count) outside ±2% of \(cell.promptTokens)")
                }
                return text
            }
        }
    }

    private func parityMismatch(ordinary: NativeMTPBenchRunResult, native: NativeMTPBenchRunResult) -> Bool {
        guard ordinary.requests.count == native.requests.count else { return true }
        for (lhs, rhs) in zip(ordinary.requests, native.requests) {
            if lhs.completion.content != rhs.completion.content { return true }
            if lhs.completion.completionTokens != rhs.completion.completionTokens { return true }
        }
        return false
    }

    private func baseHeader(
        targetIdentity: MLXSnapshotIdentity,
        mtpIdentity: MLXSnapshotIdentity,
        tokenizerSHA256: String,
        environment: NativeMTPBenchEnvironment
    ) -> [String: Any] {
        return [
            "schema": "macprovider.native-mtp-r015-run.v1",
            "record_type": "header",
            "machine": [
                "hw_model": environment.hwModel,
                "chip": environment.chip,
                "ram_gb": environment.ramGB,
                "os_version": environment.osVersion,
                "os_build": environment.osBuild,
            ],
            "xcode_build_version": environment.xcodeBuildVersion,
            "swift_version": environment.swiftVersion,
            "provider_commit": providerCommit,
            "mlx_fork_revision": NativeMTPHardwareE2ERunner.upstreamRevision,
            "model_id": modelID,
            "target_sha256": targetIdentity.digest,
            "mtp_sha256": mtpIdentity.digest,
            "tokenizer_sha256": tokenizerSHA256,
            "policy_sha256": policySHA256,
            "exploratory": policy.exploratory,
            "max_native_active_rows": policy.maxNativeActiveRows.map { $0 as Any } ?? NSNull(),
            "qualified_slots": policy.qualifiedSlots.map { $0 as Any } ?? NSNull(),
            "maximum_prompt_tokens": policy.maximumPromptTokens.map { $0 as Any } ?? NSNull(),
            "temperature": policy.temperature,
            "arrival_interval_ms": policy.arrivalIntervalMS,
            // 2: run records carry decode-only throughput (SPEC-048-R015).
            // 3: effective_paths carry each admission's other_active_rows.
            // 4: native runs carry the scheduler's gated_* load-gate evidence.
            "run_metrics_version": 4,
        ]
    }

    private static func makeRequest(
        modelID: String,
        requestID: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double
    ) throws -> ChatCompletionRequest {
        let object: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": 1.0,
            "stream": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ChatCompletionRequest.parse(data: data).withRequestID(requestID)
    }

    private static func runStreamingRequest(_ request: ChatCompletionRequest, runtime: ModelRuntime) async throws -> NativeMTPBenchRequestResult {
        guard let requestID = request.requestID else {
            throw NativeMTPBenchError.assertionFailed("request missing id")
        }
        let start = Date()
        let handle = try await runtime.acquireRequestHandle(request)
        let chunks = NativeMTPChunkTimeRecorder()
        let completion: CompletionResult
        do {
            completion = try await runtime.stream(request, with: handle) { chunk in
                if case .content(let text) = chunk, !text.isEmpty {
                    chunks.append(Date())
                }
            }
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        await runtime.unregisterInFlight(handle.registrationID)
        let end = Date()
        let chunkTimes = chunks.snapshot()
        let gaps = zip(chunkTimes.dropFirst(), chunkTimes).map { $0.timeIntervalSince($1) }
        return NativeMTPBenchRequestResult(
            requestID: requestID,
            startedAt: start,
            completion: completion,
            wallSeconds: end.timeIntervalSince(start),
            ttftSeconds: chunkTimes.first?.timeIntervalSince(start),
            interTokenGaps: gaps
        )
    }

    private static func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeMTPBenchError.missingDirectory(url.path)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

struct NativeMTPBenchEnvironment {
    let hwModel: String
    let chip: String
    let ramGB: Int
    let osVersion: String
    let osBuild: String
    let xcodeBuildVersion: String
    let swiftVersion: String
    let providerCommit: String

    static func capture(providerCommit: String) -> NativeMTPBenchEnvironment {
        let machine = MachineFingerprinter().sample()
        let xcode = commandOutput("/usr/bin/xcodebuild", ["-version"])
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("Build version ") }
            .map { String($0.dropFirst("Build version ".count)) } ?? "unknown"
        let swift = commandOutput("/usr/bin/xcrun", ["swift", "--version"])
            .split(whereSeparator: \.isNewline)
            .first.map(String.init) ?? "unknown"
        return NativeMTPBenchEnvironment(
            hwModel: sysctlString("hw.model") ?? "unknown",
            chip: machine.chip,
            ramGB: machine.ramGB,
            osVersion: machine.osVersion,
            osBuild: sysctlString("kern.osversion") ?? "unknown",
            xcodeBuildVersion: xcode,
            swiftVersion: swift,
            providerCommit: providerCommit
        )
    }

    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } catch {
            return ""
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

private enum NativeMTPBenchPath: String {
    case ordinary
    case nativeMTP = "native_mtp"
}

struct NativeMTPBenchCell: Sendable, Equatable {
    let slots: Int
    let promptTokens: Int
    let maxTokens: Int
    var id: String { "s\(slots)-p\(promptTokens)-o\(maxTokens)" }

    init(slots: Int, promptTokens: Int, maxTokens: Int) {
        self.slots = slots
        self.promptTokens = promptTokens
        self.maxTokens = maxTokens
    }

    /// Parses an exact canonical `s<slots>-p<prompt>-o<output>` id.
    init?(id: String) {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].first == "s", parts[1].first == "p", parts[2].first == "o",
              let slots = Int(parts[0].dropFirst()),
              let prompt = Int(parts[1].dropFirst()),
              let output = Int(parts[2].dropFirst()),
              slots > 0, prompt > 0, output > 0 else {
            return nil
        }
        self.init(slots: slots, promptTokens: prompt, maxTokens: output)
        guard self.id == id else { return nil }
    }
}

private struct NativeMTPBenchRequestResult: Sendable {
    let requestID: String
    let startedAt: Date
    let completion: CompletionResult
    let wallSeconds: TimeInterval
    let ttftSeconds: TimeInterval?
    let interTokenGaps: [TimeInterval]

    var contentSHA256: String {
        SHA256.hash(data: Data(completion.content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct NativeMTPBenchRunResult {
    let cell: NativeMTPBenchCell
    let blockIndex: Int
    let path: NativeMTPBenchPath
    let orderPosition: Int
    let wallSeconds: TimeInterval
    let requests: [NativeMTPBenchRequestResult]
    let committedCompletionTokens: Int
    let aggregateTPS: Double
    let perRequestTPS: [Double]
    let aggregateDecodeTPS: Double?
    let perRequestDecodeTPS: [Double?]
    let ttftP50: Double?
    let ttftP95: Double?
    let interTokenGapP50: Double?
    let interTokenGapP95: Double?
    let rawInterTokenGaps: [[Double]]
    let finishReasons: [String]
    let capacityRejections: Int
    let fallbacks: Int
    var errors: Int
    let nativeAdmissions: Int
    let nativeRequests: Int
    var nonNativeAdmissions: Int
    let loadGateDowngrades: Int
    let missingNativeAdmissions: Int
    let effectivePaths: [[String: Any]]
    let statusDelta: NativeMTPStatusDelta
    /// Scheduler in-flight load-gate evidence; nil on the ordinary path.
    let loadGate: NativeMTPLoadGateRecorder.Summary?
    let targetForwardsPerCommittedToken: Double?
    let peakPhysFootprintBytes: UInt64?
    let minAvailableMemoryBytes: UInt64?
    let minAvailableMemoryFraction: Double?
    let thermalStart: String
    let thermalEnd: String
    var parityMismatch: Bool

    func record(
        policySHA256: String,
        sustained: Bool,
        warmup: Bool,
        sustainedWindowElapsedSeconds: Double? = nil
    ) -> [String: Any] {
        [
            "schema": "macprovider.native-mtp-r015-run.v1",
            "record_type": "run",
            "policy_sha256": policySHA256,
            "cell_id": cell.id,
            "slots": cell.slots,
            "prompt_tokens": cell.promptTokens,
            "max_tokens": cell.maxTokens,
            "block_index": blockIndex,
            "path": path.rawValue,
            "order_position": orderPosition,
            "warmup": warmup,
            "sustained": sustained,
            "sustained_window_elapsed_seconds": sustainedWindowElapsedSeconds as Any,
            "requests": requests.count,
            "wall_seconds": wallSeconds,
            "committed_completion_tokens": committedCompletionTokens,
            "aggregate_committed_tps": aggregateTPS,
            "per_request_tps": perRequestTPS,
            "aggregate_decode_tps": aggregateDecodeTPS.map { $0 as Any } ?? NSNull(),
            "per_request_decode_tps": perRequestDecodeTPS.map { $0.map { $0 as Any } ?? NSNull() },
            "per_request_ttft_seconds": requests.map { request in
                request.ttftSeconds.map { $0 as Any } ?? NSNull()
            },
            "request_metrics": requests.indices.map { index in
                let request = requests[index]
                return [
                    "request_id": request.requestID,
                    "content_sha256": request.contentSHA256,
                    "completion_tokens": request.completion.completionTokens,
                    "committed_tps": perRequestTPS[index],
                    "decode_tps": perRequestDecodeTPS[index].map { $0 as Any } ?? NSNull(),
                    "ttft_seconds": request.ttftSeconds.map { $0 as Any } ?? NSNull(),
                    "inter_token_gaps_seconds": request.interTokenGaps,
                    "finish_reason": request.completion.finishReason,
                ] as [String: Any]
            },
            "ttft_p50_seconds": ttftP50 as Any,
            "ttft_p95_seconds": ttftP95 as Any,
            "inter_token_gap_p50_seconds": interTokenGapP50 as Any,
            "inter_token_gap_p95_seconds": interTokenGapP95 as Any,
            "raw_inter_token_gaps_seconds": rawInterTokenGaps,
            "finish_reasons": finishReasons,
            "capacity_rejections": capacityRejections,
            "fallbacks": fallbacks,
            "errors": errors,
            "native_admissions": nativeAdmissions,
            "native_requests": nativeRequests,
            "non_native_admissions": nonNativeAdmissions,
            "load_gate_downgrades": loadGateDowngrades,
            "missing_native_admissions": missingNativeAdmissions,
            "effective_paths": effectivePaths,
            "mtp_proposed_tokens": statusDelta.proposedTokens,
            "mtp_accepted_tokens": statusDelta.acceptedTokens,
            "mtp_rejected_tokens": statusDelta.rejectedTokens,
            "mtp_accepted_by_position": statusDelta.acceptedByPosition,
            "target_forwards": statusDelta.targetForwards,
            "mtp_forwards": statusDelta.mtpForwards,
            "target_forwards_per_committed_token": targetForwardsPerCommittedToken as Any,
            "peak_phys_footprint_bytes": peakPhysFootprintBytes as Any,
            "min_available_memory_bytes": minAvailableMemoryBytes as Any,
            "min_available_memory_fraction": minAvailableMemoryFraction as Any,
            "thermal_state_start": thermalStart,
            "thermal_state_end": thermalEnd,
            "parity_mismatch": parityMismatch,
            "gated_depth_zero_rounds": loadGate.map { $0.depthZeroRounds as Any } ?? NSNull(),
            "gated_hold_episodes": loadGate.map { $0.holdEpisodes as Any } ?? NSNull(),
            "gated_depth_restorations": loadGate.map { $0.depthRestorations as Any } ?? NSNull(),
            "gated_held_finishes_clean": loadGate.map { $0.heldFinishesClean as Any } ?? NSNull(),
            "gated_held_unresolved": loadGate.map { $0.heldUnresolved as Any } ?? NSNull(),
        ]
    }
}

/// One request's decode timing, with offsets from the start of its run.
struct NativeMTPBenchDecodeTiming: Sendable, Equatable {
    let completionTokens: Int
    let firstTokenOffset: TimeInterval?
    let endOffset: TimeInterval
}

/// SPEC-048-R015 decode-only throughput. Prefill (time to first token) is the
/// same work on both paths, so it is excluded here and gated separately as
/// TTFT; end-to-end throughput stays reported as `aggregate_committed_tps`.
/// Every undefined case returns nil so the analyzer fails the record closed
/// instead of reading a defaulted value.
enum NativeMTPBenchDecodeThroughput {
    /// (completion tokens - 1) / (request wall - TTFT).
    static func perRequest(completionTokens: Int, ttftSeconds: TimeInterval?, wallSeconds: TimeInterval) -> Double? {
        guard let ttftSeconds, completionTokens >= 2 else { return nil }
        let window = wallSeconds - ttftSeconds
        guard window > 0, window.isFinite else { return nil }
        return Double(completionTokens - 1) / window
    }

    /// Sum of every request's tokens after its first, over the run's decode
    /// window: earliest first token to latest completion. With concurrent or
    /// staggered rows this window also covers other rows' prefills, which is
    /// the same overlap on both paths. One slot reduces to `perRequest`.
    static func aggregate(_ timings: [NativeMTPBenchDecodeTiming]) -> Double? {
        guard !timings.isEmpty else { return nil }
        var firstToken = TimeInterval.infinity
        var decodeTokens = 0
        for timing in timings {
            guard let offset = timing.firstTokenOffset, timing.completionTokens >= 1 else { return nil }
            firstToken = min(firstToken, offset)
            decodeTokens += timing.completionTokens - 1
        }
        let window = (timings.map(\.endOffset).max() ?? 0) - firstToken
        guard decodeTokens > 0, window > 0, window.isFinite else { return nil }
        return Double(decodeTokens) / window
    }
}

private struct NativeMTPStatusDelta {
    let proposedTokens: UInt64
    let acceptedTokens: UInt64
    let rejectedTokens: UInt64
    let acceptedByPosition: [UInt64]
    let targetForwards: UInt64
    let mtpForwards: UInt64
    let preoutputFallbacks: UInt64
    let postoutputFailures: UInt64
    let capacityRejections: UInt64

    init(before: NativeMTPStatusSnapshot, after: NativeMTPStatusSnapshot) {
        self.proposedTokens = after.proposedTokens &- before.proposedTokens
        self.acceptedTokens = after.acceptedTokens &- before.acceptedTokens
        self.rejectedTokens = after.rejectedTokens &- before.rejectedTokens
        self.acceptedByPosition = zip(after.acceptedByPosition, before.acceptedByPosition).map { $0 &- $1 }
        self.targetForwards = after.targetForwards &- before.targetForwards
        self.mtpForwards = after.mtpForwards &- before.mtpForwards
        self.preoutputFallbacks = after.preoutputFallbacks &- before.preoutputFallbacks
        self.postoutputFailures = after.postoutputFailures &- before.postoutputFailures
        self.capacityRejections = after.capacityRejections &- before.capacityRejections
    }
}

private final class NativeMTPChunkTimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date] = []

    func append(_ value: Date) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Date] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class NativeMTPMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var sampledMinAvailableBytes: UInt64?
    private var sampledMinAvailableFraction: Double?
    private var sampledPeakPhysFootprintBytes: UInt64?

    var minAvailableBytes: UInt64? { locked { sampledMinAvailableBytes } }
    var minAvailableFraction: Double? { locked { sampledMinAvailableFraction } }
    var peakPhysFootprintBytes: UInt64? { locked { sampledPeakPhysFootprintBytes } }

    func start() {
        recordSample()
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled { self.recordSample() }
            }
        }
    }

    func stop() {
        task?.cancel()
        recordSample()
    }

    private func recordSample() {
        guard let sample = Self.sample() else { return }
        let footprint = NativeMTPBenchRunner.physFootprintBytes()
        lock.lock()
        sampledMinAvailableBytes = min(sampledMinAvailableBytes ?? sample.availableBytes, sample.availableBytes)
        sampledMinAvailableFraction = min(sampledMinAvailableFraction ?? sample.fraction, sample.fraction)
        if footprint > 0 {
            sampledPeakPhysFootprintBytes = max(sampledPeakPhysFootprintBytes ?? footprint, footprint)
        }
        lock.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    deinit {
        task?.cancel()
    }

    private static func sample() -> (availableBytes: UInt64, fraction: Double)? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        let available = pages * UInt64(pageSize)
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0, memsize > 0 else {
            return (available, 0)
        }
        return (available, Double(available) / Double(memsize))
    }
}

struct NativeMTPBenchPolicy {
    /// SPEC-048-R015 native-eligible prompt strata (tokens, realized within
    /// ±2%) before the tuple's signed prompt cap is applied.
    static let nativeEligiblePromptStrata: [Int] = [1536, 4096]
    /// SPEC-048-R015 mandatory fixed short and long output budgets.
    static let mandatoryMaxTokens: Set<Int> = [128, 512]
    /// SPEC-048-R015 gated and sustained cells run at this prompt and output.
    static let gatedPromptTokens = 1536
    static let gatedMaxTokens = 512
    static let minimumSustainedSeconds = 1800

    /// SPEC-048-R015 native-eligible prompt strata for a tuple whose signed
    /// SPEC-023-R024 `max_prompt_tokens` is `cap`: 1536 and 4096 at or below
    /// the cap, plus the cap itself.
    static func mandatoryPromptTokens(cap: Int) -> [Int] {
        Array(Set(nativeEligiblePromptStrata.filter { $0 <= cap } + [cap])).sorted()
    }

    /// SPEC-048-R015 gated cells: slot counts bound + 1 and qualified_slots at
    /// the gated prompt/output (one cell when those coincide; none when the
    /// bound covers every slot).
    static func mandatoryGatedCellIDs(bound: Int, qualifiedSlots: Int) -> [String] {
        guard bound < qualifiedSlots else { return [] }
        return Array(Set([bound + 1, qualifiedSlots])).sorted().map {
            NativeMTPBenchCell(slots: $0, promptTokens: gatedPromptTokens, maxTokens: gatedMaxTokens).id
        }
    }

    let slots: [Int]
    let promptTokens: [Int]
    let maxTokens: [Int]
    /// Cells measured outside the native-eligible cross product (policy
    /// `gated_cells`), in policy order.
    let gatedCells: [NativeMTPBenchCell]
    /// The tuple's signed SPEC-023-R024 `max_prompt_tokens`. Required for an
    /// admission policy; it caps the native-eligible prompt strata.
    let maximumPromptTokens: Int?
    let warmupRuns: Int
    let blocks: Int
    let seed: Int
    let sustainedSeconds: Int
    let sustainedCellID: String
    let memorySafetyMarginBytes: UInt64
    let thresholds: [String: Any]
    let modelID: String
    let targetSHA256: String
    let mtpSHA256: String
    let tokenizerSHA256: String
    let hwModel: String
    let chip: String
    let ramGB: Int
    let osBuild: String
    let xcodeBuildVersion: String
    let swiftVersion: String
    let providerCommit: String
    let mlxForkRevision: String
    /// The tuple's advertised `qualified_slots` (SPEC-023-R024, 2...8).
    /// Required for an admission policy, whose matrix must cover every slot
    /// count from one up to it.
    let qualifiedSlots: Int?
    /// SPEC-048-R007 bound signed into the bench sidecar. Required for an
    /// admission policy; absent in a pilot means the bound equals each cell's
    /// qualified slot count (gate never engages).
    let maxNativeActiveRows: Int?
    /// Request temperature for every row of both paths (default greedy). A
    /// sampled row's seed derives from its request ID, which both paths
    /// share, so seeded parity is still a token-identity comparison.
    let temperature: Double
    /// Staggered arrival: row `i` of a block starts `i *` this many
    /// milliseconds after the block, so load crosses the native active-row
    /// bound mid-flight. Zero submits every row at once.
    let arrivalIntervalMS: Int
    /// Exploratory policies relax the R015 minimums for pilots; every record is
    /// stamped `exploratory` and the analyzer refuses an admission verdict.
    let exploratory: Bool

    static func load(from url: URL) throws -> NativeMTPBenchPolicy {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeMTPBenchError.invalidPolicy("policy must be a JSON object")
        }
        let allowed: Set<String> = [
            "schema", "model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256",
            "slots", "prompt_tokens", "max_tokens", "warmup_runs", "blocks", "seed",
            "sustained_seconds", "sustained_cell_id", "memory_safety_margin_bytes", "thresholds",
            "hw_model", "chip", "ram_gb", "os_build", "xcode_build_version", "swift_version",
            "provider_commit", "mlx_fork_revision", "quantization", "cache_mode", "proposal_depth",
            "run_order", "prompt_corpus", "exclusion_rules", "confidence_method",
            "max_native_active_rows", "qualified_slots", "temperature", "arrival_interval_ms",
            "gated_cells", "maximum_prompt_tokens",
        ]
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw NativeMTPBenchError.invalidPolicy("unknown keys: \(unknown.sorted())") }
        let exploratory: Bool
        switch object["schema"] as? String {
        case "macprovider.native-mtp-r015-policy.v1":
            exploratory = false
        case "macprovider.native-mtp-exploratory-policy.v1":
            exploratory = true
        default:
            throw NativeMTPBenchError.invalidPolicy("bad schema")
        }
        let thresholds = try dictionary(object, "thresholds")
        try requireThresholds(thresholds)
        let policy = NativeMTPBenchPolicy(
            slots: try slotCounts(object, "slots"),
            promptTokens: try positiveIntArray(object, "prompt_tokens"),
            maxTokens: try positiveIntArray(object, "max_tokens"),
            gatedCells: try gatedCellList(object, "gated_cells"),
            maximumPromptTokens: object["maximum_prompt_tokens"] == nil
                ? nil
                : try intAtLeast(object, "maximum_prompt_tokens", 1),
            warmupRuns: try nonnegativeInt(object, "warmup_runs"),
            blocks: try intAtLeast(object, "blocks", exploratory ? 2 : 10),
            seed: try nonnegativeInt(object, "seed"),
            sustainedSeconds: try intAtLeast(object, "sustained_seconds", exploratory ? 0 : minimumSustainedSeconds),
            sustainedCellID: try string(object, "sustained_cell_id"),
            memorySafetyMarginBytes: UInt64(try nonnegativeInt(object, "memory_safety_margin_bytes")),
            thresholds: thresholds,
            modelID: try string(object, "model_id"),
            targetSHA256: try hex64(object, "target_sha256"),
            mtpSHA256: try hex64(object, "mtp_sha256"),
            tokenizerSHA256: try hex64(object, "tokenizer_sha256"),
            hwModel: try string(object, "hw_model"),
            chip: try string(object, "chip"),
            ramGB: try intAtLeast(object, "ram_gb", 1),
            osBuild: try string(object, "os_build"),
            xcodeBuildVersion: try string(object, "xcode_build_version"),
            swiftVersion: try string(object, "swift_version"),
            providerCommit: try hex40(object, "provider_commit"),
            mlxForkRevision: try hex40(object, "mlx_fork_revision"),
            qualifiedSlots: object["qualified_slots"] == nil
                ? nil
                : try intAtLeast(object, "qualified_slots", 2),
            maxNativeActiveRows: object["max_native_active_rows"] == nil
                ? nil
                : try intAtLeast(object, "max_native_active_rows", 1),
            temperature: try samplingTemperature(object, "temperature"),
            arrivalIntervalMS: object["arrival_interval_ms"] == nil
                ? 0
                : try nonnegativeInt(object, "arrival_interval_ms"),
            exploratory: exploratory
        )
        try policy.validateMatrix()
        let fixedMethodology: [String: AnyHashable] = [
            "quantization": "4bit",
            "cache_mode": "paged_kv_mixed",
            "proposal_depth": 1,
            "run_order": "seeded_random_counterbalanced",
            "prompt_corpus": "deterministic_synthetic_unique_v1",
            "exclusion_rules": "none",
            "confidence_method": "paired_block_bootstrap_holm_v1",
        ]
        for (key, expected) in fixedMethodology {
            guard let actual = object[key] as? AnyHashable, actual == expected else {
                throw NativeMTPBenchError.invalidPolicy("\(key) must equal \(expected)")
            }
        }
        guard policy.cell(id: policy.sustainedCellID) != nil else {
            throw NativeMTPBenchError.invalidPolicy("sustained_cell_id must match a matrix cell")
        }
        return policy
    }

    /// SPEC-048-R015 preregistered, counterbalanced run order: per cell, half
    /// the blocks (rounded up) run native first, shuffled by a Fisher-Yates
    /// permutation seeded from the frozen policy seed and the cell. The
    /// analyzer recomputes this exactly (scripts/native_mtp_r015_analyze.py
    /// `_native_first_order`) and rejects any block run in another order.
    static func nativeFirstOrder(seed: Int, cell: NativeMTPBenchCell, blocks: Int) -> [Bool] {
        guard blocks > 0 else { return [] }
        var order = (0..<blocks).map { $0 < (blocks + 1) / 2 }
        var value = UInt64(truncatingIfNeeded: seed)
        for component in [cell.slots, cell.promptTokens, cell.maxTokens] {
            value ^= UInt64(truncatingIfNeeded: component) &+ 0x9e3779b97f4a7c15 &+ (value << 6) &+ (value >> 2)
        }
        var rng = SeededRandom(seed: value)
        for index in stride(from: blocks - 1, to: 0, by: -1) {
            let swapIndex = Int(rng.next() % UInt64(index + 1))
            order.swapAt(index, swapIndex)
        }
        return order
    }

    func qualifiedSlots(for cell: NativeMTPBenchCell) -> Int {
        max(2, cell.slots)
    }

    /// The runtime bound for one cell. A cell's runtime is qualified at its
    /// own slot count, and a signed bound may not exceed that; a cell at or
    /// below the policy bound never engages the gate either way.
    func maxNativeActiveRows(for cell: NativeMTPBenchCell) -> Int? {
        maxNativeActiveRows.map { min($0, qualifiedSlots(for: cell)) }
    }

    /// Every measured cell: the native-eligible cross product of `slots`,
    /// `prompt_tokens`, and `max_tokens`, then the policy's `gated_cells`.
    var matrixCells: [NativeMTPBenchCell] {
        var cells: [NativeMTPBenchCell] = []
        for slots in slots {
            for prompt in promptTokens {
                for output in maxTokens {
                    cells.append(NativeMTPBenchCell(slots: slots, promptTokens: prompt, maxTokens: output))
                }
            }
        }
        return cells + gatedCells
    }

    /// SPEC-048-R015 / R007: an admission policy measures exactly the
    /// mandatory matrix before any measurement, so a reduced or substituted
    /// matrix can never be analyzed to PASS. Native-eligible cells are every
    /// slot count from one to the bound at every capped prompt stratum and
    /// both output budgets; gated cells are bound + 1 and qualified_slots at
    /// the gated prompt/output; the sustained window runs at qualified_slots.
    func validateMatrix() throws {
        if let qualifiedSlots, qualifiedSlots > 8 {
            throw NativeMTPBenchError.invalidPolicy("qualified_slots must be within 2...8")
        }
        let cells = matrixCells
        guard Set(cells.map(\.id)).count == cells.count else {
            throw NativeMTPBenchError.invalidPolicy("gated_cells duplicate a matrix cell")
        }
        let maximumSlots = qualifiedSlots ?? max(2, cells.map(\.slots).max() ?? 2)
        if let qualifiedSlots, let over = cells.first(where: { $0.slots > qualifiedSlots }) {
            throw NativeMTPBenchError.invalidPolicy("cell \(over.id) exceeds qualified_slots \(qualifiedSlots)")
        }
        if let bound = maxNativeActiveRows, bound > maximumSlots {
            throw NativeMTPBenchError.invalidPolicy(
                "max_native_active_rows \(bound) exceeds qualified slots \(maximumSlots)"
            )
        }
        guard !exploratory else { return }
        guard let qualifiedSlots else {
            throw NativeMTPBenchError.invalidPolicy("qualified_slots is required")
        }
        guard let bound = maxNativeActiveRows else {
            throw NativeMTPBenchError.invalidPolicy("max_native_active_rows is required")
        }
        guard let cap = maximumPromptTokens else {
            throw NativeMTPBenchError.invalidPolicy("maximum_prompt_tokens is required")
        }
        guard cap >= Self.gatedPromptTokens else {
            throw NativeMTPBenchError.invalidPolicy("maximum_prompt_tokens must be >= \(Self.gatedPromptTokens)")
        }
        // A gated cell must exercise the in-flight hold: the first request
        // admits native before later arrivals cross the bound.
        if cells.contains(where: { $0.slots > bound }), arrivalIntervalMS <= 0 {
            throw NativeMTPBenchError.invalidPolicy("arrival_interval_ms must be > 0 when a cell exceeds max_native_active_rows")
        }
        guard slots.sorted() == Array(1...bound) else {
            throw NativeMTPBenchError.invalidPolicy("slots must be exactly 1...\(bound) (max_native_active_rows)")
        }
        let expectedPrompts = Self.mandatoryPromptTokens(cap: cap)
        guard promptTokens.sorted() == expectedPrompts else {
            throw NativeMTPBenchError.invalidPolicy("prompt_tokens must be exactly \(expectedPrompts) for maximum_prompt_tokens \(cap)")
        }
        guard Set(maxTokens) == Self.mandatoryMaxTokens else {
            throw NativeMTPBenchError.invalidPolicy("max_tokens must be exactly \(Self.mandatoryMaxTokens.sorted())")
        }
        let expectedGated = Self.mandatoryGatedCellIDs(bound: bound, qualifiedSlots: qualifiedSlots)
        guard gatedCells.map(\.id).sorted() == expectedGated else {
            throw NativeMTPBenchError.invalidPolicy("gated_cells must be exactly \(expectedGated)")
        }
        let expectedSustained = NativeMTPBenchCell(
            slots: qualifiedSlots,
            promptTokens: Self.gatedPromptTokens,
            maxTokens: Self.gatedMaxTokens
        ).id
        guard sustainedCellID == expectedSustained else {
            throw NativeMTPBenchError.invalidPolicy("sustained_cell_id must be \(expectedSustained)")
        }
    }

    func validateObserved(modelID observedModelID: String, targetSHA256 observedTarget: String, mtpSHA256 observedMTP: String, tokenizerSHA256 observedTokenizer: String) throws {
        guard modelID == observedModelID else { throw NativeMTPBenchError.invalidPolicy("model_id mismatch") }
        guard targetSHA256 == observedTarget else { throw NativeMTPBenchError.invalidPolicy("target_sha256 mismatch") }
        guard mtpSHA256 == observedMTP else { throw NativeMTPBenchError.invalidPolicy("mtp_sha256 mismatch") }
        guard tokenizerSHA256 == observedTokenizer else { throw NativeMTPBenchError.invalidPolicy("tokenizer_sha256 mismatch") }
    }

    func validateObserved(environment: NativeMTPBenchEnvironment) throws {
        let expected: [(String, AnyHashable, AnyHashable)] = [
            ("hw_model", hwModel, environment.hwModel),
            ("chip", chip, environment.chip),
            ("ram_gb", ramGB, environment.ramGB),
            ("os_build", osBuild, environment.osBuild),
            ("xcode_build_version", xcodeBuildVersion, environment.xcodeBuildVersion),
            ("swift_version", swiftVersion, environment.swiftVersion),
            ("provider_commit", providerCommit, environment.providerCommit),
            ("mlx_fork_revision", mlxForkRevision, NativeMTPHardwareE2ERunner.upstreamRevision),
        ]
        for (key, frozen, observed) in expected where frozen != observed {
            throw NativeMTPBenchError.invalidPolicy("\(key) mismatch: frozen=\(frozen) observed=\(observed)")
        }
    }

    func cell(id: String) -> NativeMTPBenchCell? {
        matrixCells.first { $0.id == id }
    }

    private static func requireThresholds(_ thresholds: [String: Any]) throws {
        let expected: [String: Double] = [
            "throughput_lower_bound_min": 0.15,
            "ttft_p95_upper_bound_max": 0.10,
            "itl_p95_upper_bound_max": 0.0,
            "rejection_increase_max_pp": 1.0,
            "min_available_memory_fraction": 0.10,
            "bootstrap_draws": 10000,
            "alpha": 0.05,
            // SPEC-048-R015 gated cells (slots above max_native_active_rows):
            // non-inferiority to ordinary at the mixed-load margins.
            "gated_throughput_lower_bound_min": -0.05,
            "gated_ttft_p95_upper_bound_max": 0.05,
            "gated_itl_p95_upper_bound_max": 0.05,
        ]
        guard Set(thresholds.keys) == Set(expected.keys) else {
            throw NativeMTPBenchError.invalidPolicy("threshold keys mismatch")
        }
        for (key, value) in expected {
            guard let actual = thresholds[key] as? NSNumber,
                  abs(actual.doubleValue - value) < 0.000_000_1 else {
                throw NativeMTPBenchError.invalidPolicy("threshold \(key) mismatch")
            }
        }
    }

    private static func hex40(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key)
        guard value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw NativeMTPBenchError.invalidPolicy("\(key) must be lowercase 40-hex")
        }
        return value
    }
}

private struct NativeMTPExistingEvidence {
    let hasRecords: Bool
    let completedMatrixBlocks: [String: Set<Int>]
    let completedWarmups: [String: Set<Int>]
    let sustainedSeconds: [String: Double]
    let nextSustainedBlock: [String: Int]

    static func loadIfPresent(
        url: URL,
        policySHA256: String,
        providerCommit: String,
        modelID: String,
        targetSHA256: String,
        mtpSHA256: String,
        tokenizerSHA256: String,
        environment: NativeMTPBenchEnvironment
    ) throws -> NativeMTPExistingEvidence {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return empty
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return empty }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let first = lines.first,
              let header = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              header["schema"] as? String == "macprovider.native-mtp-r015-run.v1",
              header["record_type"] as? String == "header" else {
            throw NativeMTPBenchError.assertionFailed("existing --out has no valid header")
        }
        let expected: [String: String] = [
            "policy_sha256": policySHA256,
            "provider_commit": providerCommit,
            "model_id": modelID,
            "target_sha256": targetSHA256,
            "mtp_sha256": mtpSHA256,
            "tokenizer_sha256": tokenizerSHA256,
        ]
        for (key, value) in expected where header[key] as? String != value {
            throw NativeMTPBenchError.assertionFailed("existing --out \(key) mismatch")
        }
        guard let machine = header["machine"] as? [String: Any],
              machine["hw_model"] as? String == environment.hwModel,
              machine["chip"] as? String == environment.chip,
              (machine["ram_gb"] as? NSNumber)?.intValue == environment.ramGB,
              machine["os_build"] as? String == environment.osBuild,
              header["xcode_build_version"] as? String == environment.xcodeBuildVersion,
              header["swift_version"] as? String == environment.swiftVersion,
              header["mlx_fork_revision"] as? String == NativeMTPHardwareE2ERunner.upstreamRevision else {
            throw NativeMTPBenchError.assertionFailed("existing --out frozen environment mismatch")
        }

        var pathsByMatrixBlock: [String: [Int: Set<String>]] = [:]
        var pathsByWarmup: [String: [Int: Set<String>]] = [:]
        var pathsBySustainedBlock: [String: [Int: Set<String>]] = [:]
        var sustainedSeconds: [String: Double] = [:]
        var nextSustainedBlock: [String: Int] = [:]
        var seen: Set<String> = []
        for (offset, line) in lines.dropFirst().enumerated() {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["schema"] as? String == "macprovider.native-mtp-r015-run.v1",
                  record["record_type"] as? String == "run",
                  record["policy_sha256"] as? String == policySHA256,
                  let cellID = record["cell_id"] as? String,
                  let blockNumber = record["block_index"] as? NSNumber,
                  let path = record["path"] as? String,
                  path == "ordinary" || path == "native_mtp",
                  let sustained = record["sustained"] as? Bool,
                  let warmup = record["warmup"] as? Bool else {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out line \(offset + 2) is not a valid run record"
                )
            }
            let block = blockNumber.intValue
            let recordKey = "\(cellID)|\(block)|\(path)|\(sustained)|\(warmup)"
            guard seen.insert(recordKey).inserted else {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out contains duplicate run \(recordKey)"
                )
            }
            if sustained {
                pathsBySustainedBlock[cellID, default: [:]][block, default: []].insert(path)
                let elapsed = (record["sustained_window_elapsed_seconds"] as? NSNumber)?.doubleValue
                if let elapsed {
                    sustainedSeconds[cellID] = max(sustainedSeconds[cellID] ?? 0, elapsed)
                } else {
                    sustainedSeconds[cellID, default: 0] += (record["wall_seconds"] as? NSNumber)?.doubleValue ?? 0
                }
                nextSustainedBlock[cellID] = max(nextSustainedBlock[cellID] ?? 0, block + 1)
            } else if warmup {
                pathsByWarmup[cellID, default: [:]][block, default: []].insert(path)
            } else {
                pathsByMatrixBlock[cellID, default: [:]][block, default: []].insert(path)
            }
        }
        var completed: [String: Set<Int>] = [:]
        for (cellID, blocks) in pathsByMatrixBlock {
            if let partial = blocks.first(where: { _, paths in
                !(paths.contains("ordinary") && paths.contains("native_mtp"))
            }) {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out contains partial matrix block \(cellID)/\(partial.key)"
                )
            }
            completed[cellID] = Set(blocks.compactMap { block, paths in
                paths.contains("ordinary") && paths.contains("native_mtp") ? block : nil
            })
        }
        var completedWarmups: [String: Set<Int>] = [:]
        for (cellID, blocks) in pathsByWarmup {
            if let partial = blocks.first(where: { _, paths in
                !(paths.contains("ordinary") && paths.contains("native_mtp"))
            }) {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out contains partial warmup block \(cellID)/\(partial.key)"
                )
            }
            completedWarmups[cellID] = Set(blocks.keys)
        }
        for (cellID, blocks) in pathsBySustainedBlock {
            if let partial = blocks.first(where: { _, paths in
                !(paths.contains("ordinary") && paths.contains("native_mtp"))
            }) {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out contains partial sustained block \(cellID)/\(partial.key)"
                )
            }
        }
        return NativeMTPExistingEvidence(
            hasRecords: true,
            completedMatrixBlocks: completed,
            completedWarmups: completedWarmups,
            sustainedSeconds: sustainedSeconds,
            nextSustainedBlock: nextSustainedBlock
        )
    }

    private static var empty: NativeMTPExistingEvidence {
        NativeMTPExistingEvidence(
            hasRecords: false,
            completedMatrixBlocks: [:],
            completedWarmups: [:],
            sustainedSeconds: [:],
            nextSustainedBlock: [:]
        )
    }
}

private final class NativeMTPJSONLWriter {
    private let handle: FileHandle

    init(url: URL, append: Bool) throws {
        if !append {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw NativeMTPBenchError.assertionFailed("could not create --out")
            }
        }
        self.handle = try FileHandle(forWritingTo: url)
        if append { try handle.seekToEnd() }
    }

    func write(_ object: [String: Any]) throws {
        let normalized = object.mapValues { value -> Any in
            if let optional = value as? OptionalProtocol, optional.isNil { return NSNull() }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .withoutEscapingSlashes])
        handle.write(data)
        handle.write(Data("\n".utf8))
        try handle.synchronize()
    }

    func close() throws {
        try handle.close()
    }
}

private protocol OptionalProtocol {
    var isNil: Bool { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
}

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9e3779b97f4a7c15 : seed }
    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

private func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let ordered = values.sorted()
    if ordered.count == 1 { return ordered[0] }
    let position = Double(ordered.count - 1) * p
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    if lower == upper { return ordered[lower] }
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - Double(lower))
}

private func string(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        throw NativeMTPBenchError.invalidPolicy("missing string \(key)")
    }
    return value
}

private func hex64(_ object: [String: Any], _ key: String) throws -> String {
    let value = try string(object, key)
    guard value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be lowercase 64-hex")
    }
    return value
}

private func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] {
    guard let value = object[key] as? [String: Any] else {
        throw NativeMTPBenchError.invalidPolicy("missing dictionary \(key)")
    }
    return value
}

private func samplingTemperature(_ object: [String: Any], _ key: String) throws -> Double {
    guard let raw = object[key] else { return 0 }
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, (0.0 ... 2.0).contains(number.doubleValue) else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be a number in 0...2")
    }
    return number.doubleValue
}

private func positiveIntArray(_ object: [String: Any], _ key: String) throws -> [Int] {
    guard let values = object[key] as? [NSNumber], !values.isEmpty else {
        throw NativeMTPBenchError.invalidPolicy("missing int array \(key)")
    }
    let ints = try values.map { try exactInt($0, key: key) }
    guard ints.allSatisfy({ $0 > 0 }) else {
        throw NativeMTPBenchError.invalidPolicy("\(key) entries must be positive")
    }
    guard Set(ints).count == ints.count else {
        throw NativeMTPBenchError.invalidPolicy("\(key) entries must be unique")
    }
    return ints
}

private func nonnegativeInt(_ object: [String: Any], _ key: String) throws -> Int {
    guard let number = object[key] as? NSNumber else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be nonnegative int")
    }
    let value = try exactInt(number, key: key)
    guard value >= 0 else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be nonnegative int")
    }
    return value
}

private func exactInt(_ number: NSNumber, key: String) throws -> Int {
    let type = String(cString: number.objCType)
    let value = number.doubleValue
    guard type != "c", value.isFinite, value.rounded() == value,
          value >= Double(Int.min), value <= Double(Int.max) else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must contain JSON integers")
    }
    return Int(value)
}

private func slotCounts(_ object: [String: Any], _ key: String) throws -> [Int] {
    let values = try positiveIntArray(object, key)
    // One concurrent request is measured on a two-slot qualified runtime
    // (SPEC-023-R024 admits qualified_slots 2...8 only).
    guard values.allSatisfy({ (1...8).contains($0) }) else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be within 1...8")
    }
    return values
}

private func gatedCellList(_ object: [String: Any], _ key: String) throws -> [NativeMTPBenchCell] {
    guard let raw = object[key] else { return [] }
    guard let ids = raw as? [String] else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be an array of cell ids")
    }
    return try ids.map { id in
        guard let cell = NativeMTPBenchCell(id: id), (1...8).contains(cell.slots) else {
            throw NativeMTPBenchError.invalidPolicy("\(key) entry \(id) is not a cell id within 1...8 slots")
        }
        return cell
    }
}

private func intAtLeast(_ object: [String: Any], _ key: String, _ minimum: Int) throws -> Int {
    let value = try nonnegativeInt(object, key)
    guard value >= minimum else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be >= \(minimum)")
    }
    return value
}

enum NativeMTPBenchError: Error, CustomStringConvertible {
    case missingDirectory(String)
    case invalidPolicy(String)
    case assertionFailed(String)

    var description: String {
        switch self {
        case .missingDirectory(let path): return "missing directory: \(path)"
        case .invalidPolicy(let message): return "invalid policy: \(message)"
        case .assertionFailed(let message): return "assertion failed: \(message)"
        }
    }
}
#endif
