#if DEBUG || MACPROVIDER_LAB_HARNESS
import Darwin
import Foundation
import MacProviderCore
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Trace audit lab pilot (campaign #2419): residual-stream capture on the
/// continuous-batching path.
///
/// Compiled only into DEBUG and MACPROVIDER_LAB_HARNESS builds, and inside
/// those only active with `MACPROVIDER_TRACE_AUDIT_LAB=1`. Release builds
/// carry none of it.
///
/// Hook: no mlx-swift-lm change. `Module.update(modules:)` swaps, on a loaded
/// Qwen2 or Llama model, every block's `input_layernorm` (its input is the
/// block's input residual) and the last block's `post_attention_layernorm`
/// and `mlp.down_proj` (their input / output give the final residual as
/// `h + mlp(...)`, the same float16 addition the block performs) for
/// subclasses that call the stock implementation and, while a capture
/// forward is open on the calling thread, keep a reference to the array.
/// The math and kernels are the stock ones; only references are kept.
enum TraceAuditLab {
    static let environmentKey = "MACPROVIDER_TRACE_AUDIT_LAB"
    static let requested = ProcessInfo.processInfo.environment[environmentKey] == "1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var runtime: TraceAuditLabRuntime?
    nonisolated(unsafe) private static var created = false

    /// The lab runtime, or nil when the flag is off (one Bool read).
    static var active: TraceAuditLabRuntime? {
        guard requested else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if !created {
            created = true
            do {
                runtime = TraceAuditLabRuntime(store: try TraceAuditStore(configuration: .fromEnvironment()))
                FileHandle.standardError.write(Data("trace-audit-lab: capture enabled\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("trace-audit-lab: disabled: \(error)\n".utf8))
            }
        }
        return runtime
    }
}

/// One open capture forward; `end()` right after the model call returns.
final class TraceAuditLabForward {
    fileprivate let runtime: TraceAuditLabRuntime
    fileprivate init(runtime: TraceAuditLabRuntime) { self.runtime = runtime }
    func end() { runtime.endForward() }
}

final class TraceAuditLabRuntime: @unchecked Sendable {
    let store: TraceAuditStore
    private let lock = NSLock()
    private var installations: [ObjectIdentifier: Installation] = [:]
    private var collector: Collector?
    private var pending: [PendingForward] = []
    /// The measurement command turns capture off per block (hooks removed).
    private var enabled = true

    private struct Installation {
        let blocks: Int
        let originals: [(String, Module)]
        let module: Module
    }

    private final class Collector {
        let owner: pthread_t
        let rows: [TraceAuditForwardRow]
        let batchRows: Int
        let blocks: Int
        var inputs: [MLXArray?]
        var finalMid: MLXArray?
        var finalUpdate: MLXArray?

        init(owner: pthread_t, rows: [TraceAuditForwardRow], batchRows: Int, blocks: Int) {
            self.owner = owner
            self.rows = rows
            self.batchRows = batchRows
            self.blocks = blocks
            self.inputs = Array(repeating: nil, count: blocks)
        }
    }

    private struct PendingForward {
        /// `[rows, T, blocks + 1, hidden]` float16, rows = `rows` in order.
        let array: MLXArray
        let rows: [TraceAuditForwardRow]
    }

    init(store: TraceAuditStore) {
        self.store = store
    }

    // MARK: request lifecycle (scheduler)

    func register(_ request: ContinuousBatchSchedulerRequest) {
        let reason: TraceAuditUnavailableReason?
        if request.ingestProvenance == .privacy {
            reason = .privacyClass
        } else if request.cachedPromptTokens > 0 || request.retainedPagedKVSequence != nil
                    || request.promptSnapshotCache != nil {
            reason = .prefixCache
        } else {
            reason = nil
        }
        store.register(requestID: request.id, promptTokens: request.promptTokens, unavailable: reason)
    }

    func finalize(_ request: ContinuousBatchSchedulerRequest, result: ContinuousBatchSchedulerResult?) {
        if result?.finalDecodePath == .nativeMTP {
            store.markUnavailable(request.id, .nativeMTP)
        }
        let completed = result.map { $0.terminalStatus == .stop || $0.terminalStatus == .length } ?? false
        store.finalize(
            requestID: request.id,
            generatedTokens: result?.generatedTokens ?? [],
            completed: completed
        )
    }

    func markNativeMTP<S: Sequence>(_ requestIDs: S) where S.Element == String {
        for id in requestIDs { store.markUnavailable(id, .nativeMTP) }
    }

    // MARK: hooks

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    /// Install (enabled) or remove (disabled) the hooks on `model`. Call on
    /// the model's thread (inside `container.perform`).
    func setEnabled(_ on: Bool, model: any LanguageModel) throws {
        lock.lock()
        enabled = on
        lock.unlock()
        if on {
            _ = try install(model)
        } else {
            try uninstall(model)
        }
    }

    /// Number of blocks hooked, or nil for an unsupported model.
    @discardableResult
    func install(_ model: any LanguageModel) throws -> Int? {
        let id = ObjectIdentifier(model)
        lock.lock()
        if let existing = installations[id] {
            lock.unlock()
            return existing.blocks
        }
        lock.unlock()
        guard model is Qwen2Model || model is LlamaModel else { return nil }
        let named = Dictionary(model.namedModules(), uniquingKeysWith: { first, _ in first })
        var prefix: String?
        var blocks = 0
        while true {
            let candidates = named.keys.filter { $0.hasSuffix("layers.\(blocks).input_layernorm") }
            guard let key = candidates.first, candidates.count == 1 else { break }
            let p = String(key.dropLast("layers.\(blocks).input_layernorm".count))
            if prefix == nil { prefix = p }
            guard prefix == p else { break }
            blocks += 1
        }
        guard let prefix, blocks > 0 else { return nil }
        let last = "\(prefix)layers.\(blocks - 1)"
        guard let midNorm = named["\(last).post_attention_layernorm"] as? RMSNorm,
              let down = named["\(last).mlp.down_proj"] as? Linear else { return nil }
        var originals: [(String, Module)] = []
        var replacements: [(String, Module)] = []
        for block in 0 ..< blocks {
            let key = "\(prefix)layers.\(block).input_layernorm"
            guard let norm = named[key] as? RMSNorm else { return nil }
            originals.append((key, norm))
            replacements.append((key, TraceAuditCaptureNorm(norm, slot: block, runtime: self)))
        }
        originals.append(("\(last).post_attention_layernorm", midNorm))
        replacements.append((
            "\(last).post_attention_layernorm",
            TraceAuditCaptureNorm(midNorm, slot: TraceAuditCaptureNorm.finalMidSlot, runtime: self)
        ))
        originals.append(("\(last).mlp.down_proj", down))
        if let quantized = down as? QuantizedLinear {
            replacements.append(("\(last).mlp.down_proj", TraceAuditCaptureQuantizedLinear(quantized, runtime: self)))
        } else {
            replacements.append(("\(last).mlp.down_proj", TraceAuditCaptureLinear(down, runtime: self)))
        }
        _ = try model.update(modules: ModuleChildren.unflattened(replacements), verify: .none)
        lock.lock()
        installations[id] = Installation(blocks: blocks, originals: originals, module: model)
        lock.unlock()
        return blocks
    }

    func uninstall(_ model: any LanguageModel) throws {
        lock.lock()
        let installation = installations.removeValue(forKey: ObjectIdentifier(model))
        lock.unlock()
        guard let installation else { return }
        _ = try model.update(modules: ModuleChildren.unflattened(installation.originals), verify: .none)
    }

    // MARK: forwards

    /// Opens a capture for one model call over `rows`. Nil (no capture) when
    /// no row is being captured, capture is off, or the model is unsupported.
    func beginForward(model: any LanguageModel, rows: [TraceAuditForwardRow]) -> TraceAuditLabForward? {
        let wanted = rows.filter { store.isCapturing($0.requestID) }
        guard !wanted.isEmpty, isEnabled else { return nil }
        let blocks: Int?
        do {
            blocks = try install(model)
        } catch {
            blocks = nil
        }
        guard let blocks else {
            // Not a qwen2/llama model, or the hooks could not be installed.
            for row in wanted { store.markUnavailable(row.requestID, .uncalibrated) }
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        collector = Collector(owner: pthread_self(), rows: wanted, batchRows: rows.count, blocks: blocks)
        return TraceAuditLabForward(runtime: self)
    }

    fileprivate func record(slot: Int, _ x: MLXArray) {
        lock.lock()
        defer { lock.unlock() }
        guard let collector, pthread_equal(collector.owner, pthread_self()) != 0 else { return }
        switch slot {
        case TraceAuditCaptureNorm.finalMidSlot: collector.finalMid = x
        case TraceAuditCaptureNorm.finalUpdateSlot: collector.finalUpdate = x
        default: if slot >= 0 && slot < collector.blocks { collector.inputs[slot] = x }
        }
    }

    fileprivate func endForward() {
        lock.lock()
        let done = collector
        collector = nil
        lock.unlock()
        guard let done else { return }
        let tokens = done.rows.first?.tokenCount ?? 0
        guard let finalMid = done.finalMid, let finalUpdate = done.finalUpdate,
              done.inputs.allSatisfy({ $0 != nil }),
              let first = done.inputs.first ?? nil,
              first.ndim == 3, first.dim(0) == done.batchRows, first.dim(1) == tokens else {
            for row in done.rows { store.markUnavailable(row.requestID, .storage) }
            return
        }
        // Same float16 addition the last block performs (`h + r`).
        let final = finalMid + finalUpdate
        var packed = MLX.stacked(done.inputs.map { $0! } + [final], axis: 2)
        if done.rows.count != done.batchRows {
            packed = packed.take(MLXArray(done.rows.map { Int32($0.row) }), axis: 0)
        }
        guard packed.dtype == .float16 else {
            // The calibration record covers float16 activations only.
            for row in done.rows { store.markUnavailable(row.requestID, .uncalibrated) }
            return
        }
        asyncEval(packed)
        lock.lock()
        pending.append(PendingForward(array: packed, rows: done.rows))
        lock.unlock()
        drain(keepingNewest: 1)
    }

    /// Copies evaluated captures to the store. Call on the model's thread;
    /// every backend operation ends with `drainAll()` so a request's data is
    /// on disk before the scheduler finalizes it.
    func drainAll() { drain(keepingNewest: 0) }

    private func drain(keepingNewest keep: Int) {
        while true {
            lock.lock()
            guard pending.count > keep else {
                lock.unlock()
                return
            }
            let next = pending.removeFirst()
            lock.unlock()
            let shape = next.array.shape
            let positions = shape[1]
            let blocks = shape[2] - 1
            let hidden = shape[3]
            let rowBytes = positions * (blocks + 1) * hidden * 2
            let data = next.array.asData(access: .copy).data
            data.withUnsafeBytes { raw in
                for (index, row) in next.rows.enumerated() {
                    store.write(
                        requestID: row.requestID, startPosition: row.startPosition, positionCount: positions,
                        blocks: blocks, hidden: hidden,
                        bytes: UnsafeRawBufferPointer(rebasing: raw[index * rowBytes ..< (index + 1) * rowBytes])
                    )
                }
            }
        }
    }
}

// MARK: - Hook modules

final class TraceAuditCaptureNorm: RMSNorm {
    static let finalMidSlot = -1
    static let finalUpdateSlot = -2
    let slot: Int
    private weak var runtime: TraceAuditLabRuntime?

    init(_ original: RMSNorm, slot: Int, runtime: TraceAuditLabRuntime) {
        self.slot = slot
        self.runtime = runtime
        super.init(dimensions: original.weight.dim(0), eps: original.eps)
        // Share the loaded weight array; the stock kernel then sees identical inputs.
        _ = update(parameters: ModuleParameters.unflattened(["weight": original.weight]))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        runtime?.record(slot: slot, x)
        return super.callAsFunction(x)
    }
}

final class TraceAuditCaptureQuantizedLinear: QuantizedLinear {
    private weak var runtime: TraceAuditLabRuntime?

    init(_ original: QuantizedLinear, runtime: TraceAuditLabRuntime) {
        self.runtime = runtime
        super.init(
            weight: original.weight, bias: original.bias, scales: original.scales, biases: original.biases,
            groupSize: original.groupSize, bits: original.bits, mode: original.mode,
            globalScale: original.globalScale, referencePrefill: original.referencePrefill
        )
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let y = super.callAsFunction(x)
        runtime?.record(slot: TraceAuditCaptureNorm.finalUpdateSlot, y)
        return y
    }
}

final class TraceAuditCaptureLinear: Linear {
    private weak var runtime: TraceAuditLabRuntime?

    init(_ original: Linear, runtime: TraceAuditLabRuntime) {
        self.runtime = runtime
        super.init(weight: original.weight, bias: original.bias, referencePrefill: original.referencePrefill)
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let y = super.callAsFunction(x)
        runtime?.record(slot: TraceAuditCaptureNorm.finalUpdateSlot, y)
        return y
    }
}
#endif
