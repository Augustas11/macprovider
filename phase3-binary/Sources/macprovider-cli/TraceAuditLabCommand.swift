#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import Foundation
import MacProviderCore
import MLX
import MLXLLM
import MLXLMCommon

/// `macprovider-cli trace-audit-lab` (lab builds only, #2419).
struct TraceAuditLabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trace-audit-lab",
        abstract: "Trace audit pilot lab: openings and the capture overhead measurement.",
        shouldDisplay: false,
        subcommands: [TraceAuditLabOpenCommand.self, TraceAuditLabMeasureCommand.self]
    )
}

struct TraceAuditLabOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Write a trace_opening_v1 file for a committed request (FR-29 draws from --nonce-hex, or --point)."
    )

    @Option(help: "Trace store directory holding <key>.resid/.tokens/.lh/.meta.json.")
    var labDir: String
    @Option(help: "Request ID of the committed response.")
    var requestId: String
    @Option(help: "Local model directory (config.json + safetensors).")
    var model: String
    @Option(help: "nonce_1 as 64 hex chars; the points are drawn by the FR-29 rule.")
    var nonceHex: String?
    @Option(help: "Explicit block point block:position (repeatable); used instead of draws.")
    var point: [String] = []
    @Option(help: "Output opening file.")
    var out: String

    func run() async throws {
        let dir = URL(fileURLWithPath: labDir)
        let committed = try TraceAuditLabOpening.loadCommitted(directory: dir, requestID: requestId)
        let points: TraceAuditChallengePoints
        if let nonceHex {
            guard let nonce = traceAuditHexData(nonceHex), nonce.count == 32,
                  let root = traceAuditHexData(committed.root) else { throw ValidationError("--nonce-hex must be 32 bytes") }
            points = TraceAuditChallengePoints.draw(
                root: root, nonce: nonce, blocks: committed.blocks,
                positions: committed.positions, promptPositions: committed.promptPositions)
        } else {
            let parsed = try point.map { raw -> TraceAuditPoint in
                let parts = raw.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { throw ValidationError("--point is block:position") }
                return TraceAuditPoint(block: parts[0], position: parts[1])
            }
            guard !parsed.isEmpty else { throw ValidationError("give --nonce-hex or --point") }
            points = TraceAuditChallengePoints(
                blockPoints: parsed, promptPoint: TraceAuditPoint(block: 0, position: 0), outputPositions: [])
        }
        let source = try TraceAuditLabWeightSource(modelDirectory: URL(fileURLWithPath: model))
        let facts = try TraceAuditLabOpening.write(
            directory: dir, requestID: requestId, points: points, source: source,
            to: URL(fileURLWithPath: out), nonceHex: nonceHex)
        let data = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

/// The capture overhead and opening measurement (one exclusive slot). Modes
/// rotate cell by cell (off/on, then on/off) so drift does not favour one
/// mode; "off" removes the hooks, so it is the stock forward.
struct TraceAuditLabMeasureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "measure",
        abstract: "Capture off vs on through the real CB scheduler, storage, openings, markers."
    )

    @Option(help: "Local model directory (the opening reloads its weights).")
    var model: String
    @Option(help: "Output JSON path.")
    var out: String
    @Option(help: "Directory for the opening files and their manifest (the verifier reads them).")
    var openingsDir: String
    @Option(help: "Comma-separated concurrency levels.")
    var concurrency: String = "1,4,8"
    @Option(help: "Rounds per concurrency; each round runs both modes.")
    var rounds: Int = 4
    @Option(help: "Prompt tokens per request in the timing cells.")
    var promptTokens: Int = 1024
    @Option(help: "Generated tokens per request in the timing cells.")
    var decodeTokens: Int = 128
    @Option(help: "Prompt tokens of the long request (positions must stay <= 4096).")
    var longPromptTokens: Int = 4090
    @Option(help: "Block points to verify in total (5 per FR-29 challenge: 2 block, 1 prompt, 2 output).")
    var points: Int = 50
    @Option(help: "MLX freed-buffer cache limit in MiB.")
    var mlxCacheLimitMB: Int?
    @Option(help: "Refuse the timed cells when the 1-minute load average is above this.")
    var maxLoadAverage: Double = 4

    /// 1-, 5- and 15-minute load averages (empty when unavailable).
    static func loadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? values : []
    }

    struct Timing {
        var submitted = Date()
        var first: Date?
        var done = Date()
    }

    final class FirstToken: @unchecked Sendable {
        private let lock = NSLock()
        private var at: Date?
        func note() { lock.lock(); if at == nil { at = Date() }; lock.unlock() }
        var value: Date? { lock.lock(); defer { lock.unlock() }; return at }
    }

    final class ReplayAuthority: ContinuousBatchSchedulerReplayAuthority, @unchecked Sendable {
        func claim(_ key: ContinuousBatchSchedulerReplayKey) throws -> ContinuousBatchSchedulerReplayClaim { .claimed }
        func release(_ key: ContinuousBatchSchedulerReplayKey) {}
    }

    func run() async throws {
        try SmallMRoute.requireRowInvariant(entry: "trace-audit-lab measure")
        guard let lab = TraceAuditLab.active else {
            throw ValidationError("set MACPROVIDER_TRACE_AUDIT_LAB=1 (and MACPROVIDER_TRACE_AUDIT_LAB_DIR)")
        }
        let levels = concurrency.split(separator: ",").compactMap { Int($0) }.filter { $0 >= 1 }
        guard !levels.isEmpty, rounds >= 1, longPromptTokens + 6 <= 4096 else {
            throw ValidationError("bad --concurrency/--rounds/--long-prompt-tokens")
        }
        let openingsURL = URL(fileURLWithPath: openingsDir)
        try FileManager.default.createDirectory(at: openingsURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let runtime = try await ModelRuntime(modelID: model, mlxCacheLimitMB: mlxCacheLimitMB)
        guard await runtime.isLoaded, let container = await runtime.currentSnapshot().container else {
            throw ValidationError("model did not load")
        }
        let topology = try await container.perform { context -> ([PagedKVSharedForwardBackend.CacheKind], PagedKVRecurrentStateLayout, Int?)? in
            guard let kinds = PagedKVSharedForwardBackend.CacheKind.kinds(from: try context.model.newCache(parameters: nil)) else {
                return nil
            }
            let blocks = try lab.install(context.model)
            return (kinds, MSBThroughputCommand.labRecurrentStateLayout(model: context.model, cacheKinds: kinds), blocks)
        }
        guard let (cacheKinds, layout, hookedBlocks) = topology, let hookedBlocks else {
            throw ValidationError("model is not a qwen2/llama paged-attention model: trace capture unsupported")
        }
        let maxRows = max(levels.max()!, 4)
        let scheduler = try makeScheduler(container: container, cacheKinds: cacheKinds, layout: layout, maxRows: maxRows)
        let prompts: [[Int]] = await container.perform { context in
            (0 ..< maxRows).map { MSBThroughputCommand.buildPromptTokens(context: context, index: $0, tokens: promptTokens) }
        }
        let shortPrompts: [[Int]] = await container.perform { context in
            (0 ..< 4).map { MSBThroughputCommand.buildPromptTokens(context: context, index: 100 + $0, tokens: 512) }
        }
        let longPrompt: [Int] = await container.perform { context in
            MSBThroughputCommand.buildPromptTokens(context: context, index: 200, tokens: longPromptTokens)
        }

        func setMode(_ on: Bool) async throws {
            try await container.perform { context in try lab.setEnabled(on, model: context.model) }
        }

        func runCell(_ cellPrompts: [[Int]], decode: Int, tag: String, conversationKey: String = "")
            async throws -> [(ContinuousBatchSchedulerRequest, ContinuousBatchSchedulerResult, Timing)] {
            try await withThrowingTaskGroup(of: (Int, ContinuousBatchSchedulerRequest, ContinuousBatchSchedulerResult, Timing).self) { group in
                for (index, prompt) in cellPrompts.enumerated() {
                    group.addTask {
                        let request = ContinuousBatchSchedulerRequest(
                            id: "trace-lab-\(tag)-\(index)-\(UUID().uuidString)",
                            conversationKey: conversationKey,
                            promptTokens: prompt,
                            maxOutputTokens: decode,
                            temperature: 0,
                            topP: 1
                        )
                        let first = FirstToken()
                        var timing = Timing()
                        let result = try await scheduler.submit(request, tokenSink: { _ in first.note() })
                        timing.done = Date()
                        timing.first = first.value
                        return (index, request, result, timing)
                    }
                }
                var out: [(Int, ContinuousBatchSchedulerRequest, ContinuousBatchSchedulerResult, Timing)] = []
                for try await item in group { out.append(item) }
                return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2, $0.3) }
            }
        }

        func commitmentJSON(_ c: TraceAuditCommitment?) -> [String: Any] {
            switch c {
            case .root(let root, let positions, let leaves)?:
                return ["root": root.map { String(format: "%02x", $0) }.joined(), "positions": positions, "leaf_count": leaves]
            case .unavailable(let reason)?: return ["unavailable": reason.rawValue]
            case .discarded?: return ["discarded": true]
            case .pending?, nil: return ["missing": true]
            }
        }

        // Warm-up, capture off.
        try await setMode(false)
        _ = try await runCell(Array(prompts.prefix(1)), decode: 8, tag: "warm")

        // 1. Overhead cells. A loaded Mac gives no timing.
        // The model load and warm-up raise the 1-minute average themselves;
        // give it up to 3 minutes to settle before refusing.
        var loadAtStart = Self.loadAverages()
        for _ in 0 ..< 18 {
            guard let oneMinute = loadAtStart.first, oneMinute > maxLoadAverage else { break }
            try await Task.sleep(nanoseconds: 10_000_000_000)
            loadAtStart = Self.loadAverages()
        }
        FileHandle.standardError.write(Data("trace-audit-lab: load average at start \(loadAtStart)\n".utf8))
        if let oneMinute = loadAtStart.first, oneMinute > maxLoadAverage {
            throw ValidationError("load average \(oneMinute) is above \(maxLoadAverage): timed cells refused")
        }
        var cells: [[String: Any]] = []
        var loadByMode: [String: [[Double]]] = ["off": [], "on": []]
        var bytesPerPosition: [Double] = []
        for level in levels {
            for round in 0 ..< rounds {
                for on in (round % 2 == 0 ? [false, true] : [true, false]) {
                    try await setMode(on)
                    let load = Self.loadAverages()
                    loadByMode[on ? "on" : "off", default: []].append(load)
                    let rows = try await runCell(Array(prompts.prefix(level)), decode: decodeTokens, tag: "c\(level)r\(round)\(on ? "on" : "off")")
                    let submitted = rows.map(\.2.submitted).min()!
                    let firsts = rows.compactMap(\.2.first)
                    let firstMax = firsts.max() ?? submitted
                    let firstMin = firsts.min() ?? submitted
                    let doneMax = rows.map(\.2.done).max()!
                    let prefillTokens = rows.reduce(0) { $0 + $1.0.promptTokens.count }
                    let decodeTokensTotal = rows.reduce(0) { $0 + max(0, $1.1.generatedTokens.count - 1) }
                    var cell: [String: Any] = [
                        "concurrency": level, "round": round, "capture": on, "load_average_start": load,
                        "prefill_tok_s": Double(prefillTokens) / max(1e-9, firstMax.timeIntervalSince(submitted)),
                        "decode_tok_s": Double(decodeTokensTotal) / max(1e-9, doneMax.timeIntervalSince(firstMin)),
                        "ttft_s": firsts.map { $0.timeIntervalSince(submitted) },
                        "terminals": rows.map { $0.1.terminalStatus.rawValue },
                    ]
                    if on {
                        var rootSeconds: [Double] = []
                        var outcomes: [[String: Any]] = []
                        for (request, _, timing) in rows {
                            let c = await lab.store.awaitCommitment(request.id)
                            rootSeconds.append(Date().timeIntervalSince(timing.done))
                            outcomes.append(commitmentJSON(c))
                            if case .root(_, let positions, _)? = c, let bytes = lab.store.residualBytes(request.id) {
                                bytesPerPosition.append(Double(bytes) / Double(positions))
                            }
                            lab.store.release(request.id)
                        }
                        cell["root_ready_after_response_s"] = rootSeconds
                        cell["commitments"] = outcomes
                    }
                    cells.append(cell)
                    FileHandle.standardError.write(Data("trace-audit-lab: cell c=\(level) round=\(round) capture=\(on) done\n".utf8))
                }
            }
        }

        // 2. Verification set and long request (capture on, kept until openings are written).
        try await setMode(true)
        let shortRows = try await runCell(shortPrompts, decode: 64, tag: "verify")
        let longRows = try await runCell([longPrompt], decode: 6, tag: "long")
        var committed: [(ContinuousBatchSchedulerRequest, ContinuousBatchSchedulerResult)] = []
        var verifyOutcomes: [[String: Any]] = []
        for (request, result, _) in shortRows + longRows {
            let c = await lab.store.awaitCommitment(request.id)
            verifyOutcomes.append(commitmentJSON(c))
            if case .root? = c { committed.append((request, result)) }
        }
        let source = try TraceAuditLabWeightSource(modelDirectory: URL(fileURLWithPath: model))
        let storeDir = lab.store.configuration.directory

        // 3. Fixed openings at p = 100 / 1000 / 4000 on the long request.
        var fixed: [[String: Any]] = []
        if let (longRequest, _) = committed.first(where: { $0.0.promptTokens.count == longPrompt.count }) {
            let mid = hookedBlocks / 2
            for p in [100, 1000, 4000] {
                let file = openingsURL.appendingPathComponent("fixed-p\(p).bin")
                let points = TraceAuditChallengePoints(
                    blockPoints: [TraceAuditPoint(block: mid, position: p)],
                    promptPoint: TraceAuditPoint(block: 0, position: min(p, longPrompt.count - 1)),
                    outputPositions: [])
                var facts = try TraceAuditLabOpening.write(
                    directory: storeDir, requestID: longRequest.id, points: points, source: source, to: file)
                facts["file"] = file.lastPathComponent
                fixed.append(facts)
            }
        }

        // 4. Drawn challenges for the verifier (5 points each).
        var manifest: [[String: Any]] = []
        let challenges = max(1, (points + 4) / 5)
        for index in 0 ..< challenges where !committed.isEmpty {
            let (request, result) = committed[index % committed.count]
            let meta = try TraceAuditLabOpening.loadCommitted(directory: storeDir, requestID: request.id)
            var nonce = Data(count: 32)
            for i in 0 ..< 32 { nonce[i] = UInt8.random(in: 0 ... 255) }
            let drawn = TraceAuditChallengePoints.draw(
                root: traceAuditHexData(meta.root)!, nonce: nonce, blocks: meta.blocks,
                positions: meta.positions, promptPositions: meta.promptPositions)
            let file = openingsURL.appendingPathComponent("challenge-\(index).bin")
            let nonceHex = nonce.map { String(format: "%02x", $0) }.joined()
            var facts = try TraceAuditLabOpening.write(
                directory: storeDir, requestID: request.id, points: drawn, source: source, to: file, nonceHex: nonceHex)
            facts["file"] = file.lastPathComponent
            facts["request_id"] = request.id
            facts["nonce_1"] = nonceHex
            facts["prompt_tokens"] = request.promptTokens
            facts["generated_tokens"] = result.generatedTokens
            manifest.append(facts)
        }
        let manifestData = try JSONSerialization.data(
            withJSONObject: ["model": model, "openings": manifest], options: [.sortedKeys])
        try manifestData.write(to: openingsURL.appendingPathComponent("manifest.json"))
        for (request, _) in committed { lab.store.release(request.id) }

        // 5. Prompt-cache hit: a second turn that reuses the first turn's retained paged KV.
        var prefixCase: [String: Any] = [:]
        do {
            let first = try await runCell([shortPrompts[0]], decode: 16, tag: "pc1", conversationKey: "trace-lab-pc")
            let (_, firstResult, _) = first[0]
            if let retained = firstResult.retainedCache {
                let turn2 = shortPrompts[0] + firstResult.generatedTokens + Array(shortPrompts[1].prefix(32))
                let request = ContinuousBatchSchedulerRequest(
                    id: "trace-lab-pc2-\(UUID().uuidString)", conversationKey: "trace-lab-pc",
                    promptTokens: turn2, maxOutputTokens: 16, temperature: 0, topP: 1,
                    cachedPromptTokens: retained.retainedSequence.logicalTokenCount,
                    retainedPagedKVSequence: retained.retainedSequence
                )
                let result = try await scheduler.submit(request)
                prefixCase = [
                    "exercised": true,
                    "cached_prompt_tokens": retained.retainedSequence.logicalTokenCount,
                    "terminal": result.terminalStatus.rawValue,
                    "commitment": commitmentJSON(await lab.store.awaitCommitment(request.id)),
                ]
                lab.store.release(request.id)
            } else {
                prefixCase = ["exercised": false, "reason": "the harness scheduler retained no cache for turn 1"]
            }
            lab.store.release(first[0].0.id)
        } catch {
            prefixCase = ["exercised": false, "reason": "\(error)"]
        }
        lab.store.endWindow()

        let report: [String: Any] = [
            "schema": "macprovider.trace-audit-lab.measure.v1",
            "model": model,
            "blocks": hookedBlocks,
            "prompt_tokens": promptTokens, "decode_tokens": decodeTokens, "rounds": rounds,
            "load_average_at_start": loadAtStart,
            "load_average_by_mode": loadByMode,
            "cells": cells,
            "bytes_per_position_measured": bytesPerPosition,
            "verification_set_commitments": verifyOutcomes,
            "fixed_openings": fixed,
            "challenges": manifest.map { ($0 as NSDictionary).mutableCopy() as! NSMutableDictionary }.map {
                $0.removeObject(forKey: "prompt_tokens"); $0.removeObject(forKey: "generated_tokens"); return $0
            },
            "prompt_cache_case": prefixCase,
            "native_mtp_case": [
                "exercised": false,
                "reason": "this command builds the ordinary CB backend without a drafter; Qwen2.5 has no MTP head. A native-MTP row is marked native_mtp at prefill/propose/verify (unit-tested path, not this run).",
            ],
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: out))
    }

    private func makeScheduler(
        container: ModelContainer, cacheKinds: [PagedKVSharedForwardBackend.CacheKind],
        layout: PagedKVRecurrentStateLayout, maxRows: Int
    ) throws -> ContinuousBatchScheduler {
        let blockSize = PagedKVConfig.defaultBlockSizeTokens
        let maxBlocks = PagedKVConfig(blockSizeTokens: blockSize)
            .sizedToCover(contextTokens: ProviderCapacity.defaultContextTokensForCurrentHost()).maxPhysicalBlocks
        let sha = String(repeating: "a", count: 64)
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: blockSize, maxPhysicalBlocks: maxBlocks, modelID: "trace-audit-lab",
            modelSHA256: sha, tokenizerSHA256: sha, chatTemplateSHA256: sha,
            supportedModelFamilies: ["qwen", "llama"], allowedCacheClasses: ["KVCacheSimple"],
            supportsMoEDispatch: true, hardwareClass: "apple-silicon-harness", metallibSHA256: sha,
            kernelIdentifier: "msb_scheduler_lockstep_v1", parityLabel: "harness-v1"
        )
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID, modelSHA256: sha, tokenizerSHA256: sha, chatTemplateSHA256: sha,
            cacheClass: "KVCacheSimple", kvDType: .fp16, requiresMoE: false,
            hardwareClass: "apple-silicon-harness", metallibSHA256: sha,
            kernelIdentifier: descriptor.kernelIdentifier, parityLabel: descriptor.parityLabel, poolEpoch: 1
        )
        let backend = PagedKVSharedForwardBackend(
            container: container, blockSizeTokens: blockSize, maxPhysicalBlocks: maxBlocks, poolEpoch: 1,
            layerCount: cacheKinds.count, cacheKinds: cacheKinds, recurrentStateLayout: layout, compiledDecode: false
        )
        let chunk = ContinuousBatchSchedulerConfiguration.defaultPromptChunkTokens
        return ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: descriptor, tuple: tuple, moePromotionEvidenceAvailable: true,
                maxActiveRows: maxRows, decodeHeadroomTokens: 1,
                maxPrefillRowsPerIteration: min(maxRows, ContinuousBatchSchedulerConfiguration.defaultPrefillRowsPerIteration),
                maxPrefillTokensPerIteration: ContinuousBatchSchedulerConfiguration.defaultPrefillTokensPerIteration,
                maxPromptChunkTokens: chunk, referencePrefillStepSize: nil, serialPrefillStride: false,
                snapshot: ContinuousBatchSchedulerSnapshot(modelID: descriptor.modelID, modelSHA256: sha, weightsGeneration: 1),
                maxDecodeLockstepWindow: ModelRuntime.servePathDecodeLockstepWindow(cacheKinds: cacheKinds),
                maxDecodeStepsWhilePrefilling: ModelRuntime.decodeStepsWhilePrefilling(promptChunkTokens: chunk)
            ),
            allocator: try PagedKVBlockAllocator(blockSizeTokens: blockSize, maxPhysicalBlocks: maxBlocks),
            backend: backend,
            replayAuthority: ReplayAuthority()
        )
    }
}

private func traceAuditHexData(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var out = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}
#endif
