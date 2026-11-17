#if DEBUG || MACPROVIDER_LAB_HARNESS
import Darwin
import Foundation
import MacProviderCore
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Trace audit lab pilot (campaign #2419): residual-stream capture on the
/// continuous-batching path and the serial route.
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
///
/// Forwards: the CB backend opens each forward explicitly with its row map
/// (`beginForward`). The serial route cannot wrap the forwards its
/// `TokenIterator` runs, so a serial request binds itself to the threads that
/// build its forwards (`TraceAuditLabSerialRequest.attach` / `bindThread`):
/// on a bound thread the block-0 hook opens a one-row forward at the KV
/// cache's offset (the row's committed length before the forward, which a
/// speculative trim rewinds) and the last block's down projection closes it.
/// A re-run position overwrites in place; positions past the response are cut
/// at finalize.
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
    fileprivate let thread: mach_port_t
    fileprivate init(runtime: TraceAuditLabRuntime, thread: mach_port_t) {
        self.runtime = runtime
        self.thread = thread
    }
    func end() { runtime.endForward(thread: thread) }
}

/// One scheduler submission's registration. Only the submission holding it
/// finalizes the entry, so a duplicate waiter or a rejected duplicate cannot
/// end the canonical request's capture.
struct TraceAuditLabSubmission {
    fileprivate let token: TraceAuditCaptureToken
    fileprivate let key: TraceAuditLabRuntime.BackendRequest
}

final class TraceAuditLabRuntime: @unchecked Sendable {
    let store: TraceAuditStore
    private let lock = NSLock()
    private var installations: [ObjectIdentifier: Installation] = [:]
    /// Open CB forwards, per calling Mach thread, so backends forwarding on
    /// different threads at once each keep their own.
    private var collectors: [mach_port_t: Collector] = [:]
    /// The token a backend's rows write to: the first live registration of
    /// that request ID on that backend. A serial request with the same ID, or
    /// the same ID on another backend, holds a different token.
    private var backendTokens: [BackendRequest: TraceAuditCaptureToken] = [:]
    private var pending: [PendingForward] = []
    /// The measurement command turns capture off per block (hooks removed).
    private var enabled = true

    private struct Installation {
        let blocks: Int
        let originals: [(String, Module)]
        let module: Module
    }

    fileprivate struct BackendRequest: Hashable {
        let backend: ObjectIdentifier
        let requestID: String
    }

    private final class Collector {
        let rows: [TraceAuditForwardRow]
        /// `tokens[i]` is the store entry of `rows[i]`.
        let tokens: [TraceAuditCaptureToken]
        let batchRows: Int
        let blocks: Int
        var inputs: [MLXArray?]
        var finalMid: MLXArray?
        var finalUpdate: MLXArray?

        init(rows: [TraceAuditForwardRow], tokens: [TraceAuditCaptureToken], batchRows: Int, blocks: Int) {
            self.rows = rows
            self.tokens = tokens
            self.batchRows = batchRows
            self.blocks = blocks
            self.inputs = Array(repeating: nil, count: blocks)
        }

        func store(slot: Int, _ x: MLXArray) {
            switch slot {
            case TraceAuditCaptureNorm.finalMidSlot: finalMid = x
            case TraceAuditCaptureNorm.finalUpdateSlot: finalUpdate = x
            default: if slot >= 0 && slot < blocks { inputs[slot] = x }
            }
        }
    }

    private struct SerialBinding {
        let request: TraceAuditLabSerialRequest
        let token: TraceAuditCaptureToken
        let cache: [KVCache]
        let blocks: Int
    }

    /// Serial bindings and their open forwards, per Mach thread.
    private var serialBindings: [mach_port_t: SerialBinding] = [:]
    private var serialForwards: [mach_port_t: (Collector, TraceAuditLabSerialRequest)] = [:]
    /// Serial requests by their `RequestTimeline`, so the speculative path
    /// (which gets the timeline, not the request) finds its request.
    private var serialRequests: [ObjectIdentifier: TraceAuditLabSerialRequest] = [:]

    fileprivate struct PendingForward {
        /// `[rows, T, blocks + 1, hidden]` float16, rows = `rows` in order.
        let array: MLXArray
        let rows: [TraceAuditForwardRow]
        let tokens: [TraceAuditCaptureToken]
    }

    init(store: TraceAuditStore) {
        self.store = store
    }

    // MARK: request lifecycle (scheduler)

    func register(_ request: ContinuousBatchSchedulerRequest, backend: AnyObject) -> TraceAuditLabSubmission {
        let reason: TraceAuditUnavailableReason?
        if request.ingestProvenance == .privacy {
            reason = .privacyClass
        } else if request.cachedPromptTokens > 0 || request.retainedPagedKVSequence != nil
                    || request.promptSnapshotCache != nil {
            reason = .prefixCache
        } else {
            reason = nil
        }
        let token = store.register(requestID: request.id, promptTokens: request.promptTokens, unavailable: reason)
        let key = BackendRequest(backend: ObjectIdentifier(backend), requestID: request.id)
        lock.lock()
        // A duplicate on the same backend keeps the first submission's token.
        if backendTokens[key] == nil { backendTokens[key] = token }
        lock.unlock()
        return TraceAuditLabSubmission(token: token, key: key)
    }

    func finalize(_ submission: TraceAuditLabSubmission, result: ContinuousBatchSchedulerResult?) {
        lock.lock()
        if backendTokens[submission.key] == submission.token { backendTokens[submission.key] = nil }
        lock.unlock()
        if result?.finalDecodePath == .nativeMTP {
            store.markUnavailable(submission.token, .nativeMTP)
        }
        let completed = result.map { $0.terminalStatus == .stop || $0.terminalStatus == .length } ?? false
        store.finalize(
            token: submission.token,
            generatedTokens: result?.generatedTokens ?? [],
            completed: completed
        )
    }

    func markNativeMTP<S: Sequence>(backend: AnyObject, _ requestIDs: S) where S.Element == String {
        let tokens = self.tokens(backend: backend, requestIDs: requestIDs)
        for token in tokens.compactMap({ $0 }) { store.markUnavailable(token, .nativeMTP) }
    }

    private func tokens<S: Sequence>(backend: AnyObject, requestIDs: S) -> [TraceAuditCaptureToken?]
    where S.Element == String {
        let id = ObjectIdentifier(backend)
        lock.lock(); defer { lock.unlock() }
        return requestIDs.map { backendTokens[BackendRequest(backend: id, requestID: $0)] }
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
    func beginForward(
        model: any LanguageModel, backend: AnyObject, rows: [TraceAuditForwardRow]
    ) -> TraceAuditLabForward? {
        var wanted: [TraceAuditForwardRow] = []
        var wantedTokens: [TraceAuditCaptureToken] = []
        for (row, token) in zip(rows, tokens(backend: backend, requestIDs: rows.map(\.requestID))) {
            guard let token, store.isCapturing(token) else { continue }
            wanted.append(row)
            wantedTokens.append(token)
        }
        guard !wanted.isEmpty, isEnabled else { return nil }
        let blocks: Int?
        do {
            blocks = try install(model)
        } catch {
            blocks = nil
        }
        guard let blocks else {
            // Not a qwen2/llama model, or the hooks could not be installed.
            for token in wantedTokens { store.markUnavailable(token, .uncalibrated) }
            return nil
        }
        let thread = pthread_mach_thread_np(pthread_self())
        lock.lock()
        defer { lock.unlock() }
        collectors[thread] = Collector(rows: wanted, tokens: wantedTokens, batchRows: rows.count, blocks: blocks)
        return TraceAuditLabForward(runtime: self, thread: thread)
    }

    fileprivate func record(slot: Int, _ x: MLXArray) {
        var closed: (Collector, TraceAuditLabSerialRequest)?
        let thread = pthread_mach_thread_np(pthread_self())
        lock.lock()
        if let collector = collectors[thread] {
            collector.store(slot: slot, x)
            lock.unlock()
            return
        }
        guard let binding = serialBindings[thread] else {
            lock.unlock()
            return
        }
        if slot == 0 {
            let row = TraceAuditForwardRow(
                row: 0, requestID: binding.request.requestID,
                startPosition: binding.cache.first?.offset ?? 0, tokenCount: x.ndim == 3 ? x.dim(1) : 0)
            serialForwards[thread] = (
                Collector(rows: [row], tokens: [binding.token], batchRows: 1, blocks: binding.blocks), binding.request
            )
        }
        if let open = serialForwards[thread] {
            open.0.store(slot: slot, x)
            if slot == TraceAuditCaptureNorm.finalUpdateSlot {
                serialForwards[thread] = nil
                closed = open
            }
        }
        lock.unlock()
        if let closed, let packed = pack(closed.0) {
            closed.1.enqueue(packed)
        }
    }

    fileprivate func endForward(thread: mach_port_t) {
        lock.lock()
        let done = collectors.removeValue(forKey: thread)
        lock.unlock()
        guard let done, let packed = pack(done) else { return }
        lock.lock()
        pending.append(packed)
        lock.unlock()
        drain(keepingNewest: 1)
    }

    /// Stacks one closed forward to `[rows, T, L+1, H]` and queues its
    /// evaluation; nil (with the rows marked) when it cannot be committed.
    private func pack(_ done: Collector) -> PendingForward? {
        let tokens = done.rows.first?.tokenCount ?? 0
        guard let finalMid = done.finalMid, let finalUpdate = done.finalUpdate,
              done.inputs.allSatisfy({ $0 != nil }),
              let first = done.inputs.first ?? nil,
              first.ndim == 3, first.dim(0) == done.batchRows, first.dim(1) == tokens else {
            for token in done.tokens { store.markUnavailable(token, .storage) }
            return nil
        }
        // Same float16 addition the last block performs (`h + r`).
        let final = finalMid + finalUpdate
        var packed = MLX.stacked(done.inputs.map { $0! } + [final], axis: 2)
        if done.rows.count != done.batchRows {
            packed = packed.take(MLXArray(done.rows.map { Int32($0.row) }), axis: 0)
        }
        guard packed.dtype == .float16 else {
            // The calibration record covers float16 activations only.
            for token in done.tokens { store.markUnavailable(token, .uncalibrated) }
            return nil
        }
        asyncEval(packed)
        return PendingForward(array: packed, rows: done.rows, tokens: done.tokens)
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
            write(next)
        }
    }

    fileprivate func write(_ next: PendingForward) {
        let shape = next.array.shape
        let positions = shape[1]
        let blocks = shape[2] - 1
        let hidden = shape[3]
        let rowBytes = positions * (blocks + 1) * hidden * 2
        let data = next.array.asData(access: .copy).data
        data.withUnsafeBytes { raw in
            for (index, row) in next.rows.enumerated() {
                store.write(
                    token: next.tokens[index], startPosition: row.startPosition, positionCount: positions,
                    blocks: blocks, hidden: hidden,
                    bytes: UnsafeRawBufferPointer(rebasing: raw[index * rowBytes ..< (index + 1) * rowBytes])
                )
            }
        }
    }

    // MARK: serial route

    /// The serial request for `requestID`, or nil when capture is off. Nothing
    /// is registered until a forward path attaches, so a request the serial
    /// entry hands to the CB scheduler is registered by the scheduler only.
    func serialRequest(
        requestID: String?, promptTokens: [Int32], privacy: Bool, timeline: AnyObject
    ) -> TraceAuditLabSerialRequest? {
        guard isEnabled else { return nil }
        let request = TraceAuditLabSerialRequest(
            requestID: requestID ?? "serial-\(UUID().uuidString)", promptTokens: promptTokens.map(Int.init),
            privacy: privacy, timelineKey: ObjectIdentifier(timeline), runtime: self)
        lock.lock()
        serialRequests[request.timelineKey] = request
        lock.unlock()
        return request
    }

    func serialRequest(for timeline: AnyObject) -> TraceAuditLabSerialRequest? {
        lock.lock(); defer { lock.unlock() }
        return serialRequests[ObjectIdentifier(timeline)]
    }

    fileprivate func bindSerial(
        _ request: TraceAuditLabSerialRequest, token: TraceAuditCaptureToken, cache: [KVCache], blocks: Int
    ) {
        lock.lock()
        serialBindings[pthread_mach_thread_np(pthread_self())] = SerialBinding(
            request: request, token: token, cache: cache, blocks: blocks)
        lock.unlock()
    }

    fileprivate func unbindSerial(_ request: TraceAuditLabSerialRequest, allThreads: Bool) {
        lock.lock()
        let threads = allThreads
            ? Array(serialBindings.filter { $0.value.request === request }.keys)
            : [pthread_mach_thread_np(pthread_self())]
        for thread in threads where serialBindings[thread]?.request === request {
            serialBindings[thread] = nil
            serialForwards[thread] = nil
        }
        if allThreads { serialRequests[request.timelineKey] = nil }
        lock.unlock()
    }
}

/// One request on the serial route (complete, stream, and the draft-model
/// speculative path). Registered on the first `attach`, which keeps the
/// store token; finalized by
/// `finish` with the returned tokens, or by `close` as not completed.
///
/// The serial generate loop drops the stop token (mlx-swift-lm
/// `runSynchronousGenerationLoop` breaks before appending it, and the
/// speculative loop discards it), so `n` counts the returned tokens and the
/// position whose logits produced the stop token is not committed.
final class TraceAuditLabSerialRequest: @unchecked Sendable {
    let requestID: String
    fileprivate let timelineKey: ObjectIdentifier
    private let promptTokens: [Int]
    private let privacy: Bool
    private unowned let runtime: TraceAuditLabRuntime
    private let lock = NSLock()
    /// This request's own store entry, set by the first `attach`. Writes,
    /// markers and finalize name it, never the bare request ID.
    private var token: TraceAuditCaptureToken?
    private var finished = false
    private var model: (any LanguageModel)?
    private var cache: [KVCache] = []
    private var blocks: Int?
    private var pending: [TraceAuditLabRuntime.PendingForward] = []

    fileprivate init(
        requestID: String, promptTokens: [Int], privacy: Bool, timelineKey: ObjectIdentifier,
        runtime: TraceAuditLabRuntime
    ) {
        self.requestID = requestID
        self.promptTokens = promptTokens
        self.privacy = privacy
        self.timelineKey = timelineKey
        self.runtime = runtime
    }

    /// Registers the request (first call), applies the markers known here and
    /// binds the calling thread to `cache`. Call before the path's first
    /// forward and again whenever the path replaces its cache array.
    func attach(model: any LanguageModel, cache: [KVCache], quantizedKV: Bool, prefixReused: Bool) {
        let store = runtime.store
        lock.lock()
        let token = self.token ?? store.register(
            requestID: requestID, promptTokens: promptTokens, unavailable: privacy ? .privacyClass : nil)
        self.token = token
        self.model = model
        self.cache = cache
        lock.unlock()
        if quantizedKV { store.markUnavailable(token, .quantizedKV) }
        if prefixReused { store.markUnavailable(token, .prefixCache) }
        guard store.isCapturing(token) else { return }
        let hooked: Int?
        do {
            hooked = try runtime.install(model)
        } catch {
            hooked = nil
        }
        guard let hooked else {
            store.markUnavailable(token, .uncalibrated)
            return
        }
        lock.lock()
        blocks = hooked
        lock.unlock()
        runtime.bindSerial(self, token: token, cache: cache, blocks: hooked)
    }

    /// Binds another thread (the decode executor) to the attached cache.
    func bindThread() {
        lock.lock()
        let (cache, blocks, token) = (self.cache, self.blocks, self.token)
        lock.unlock()
        guard let blocks, let token, runtime.store.isCapturing(token) else { return }
        runtime.bindSerial(self, token: token, cache: cache, blocks: blocks)
    }

    /// Idempotent: a thread not bound to this request is left as it is, so a
    /// `defer` may repeat an explicit unbind.
    func unbindThread() {
        runtime.unbindSerial(self, allThreads: false)
        drain(keepingNewest: 0)
    }

    fileprivate func enqueue(_ forward: TraceAuditLabRuntime.PendingForward) {
        lock.lock()
        pending.append(forward)
        lock.unlock()
        drain(keepingNewest: 1)
    }

    private func drain(keepingNewest keep: Int) {
        while true {
            lock.lock()
            guard pending.count > keep else {
                lock.unlock()
                return
            }
            let next = pending.removeFirst()
            lock.unlock()
            runtime.write(next)
        }
    }

    /// The response was produced: commit through the returned tokens.
    func finish(generatedTokens: [Int]) {
        lock.lock()
        let open = finished ? nil : token
        finished = true
        lock.unlock()
        guard let open else { return }
        drain(keepingNewest: 0)
        runtime.store.finalize(token: open, generatedTokens: generatedTokens, completed: true)
    }

    /// End of the request scope: unbinds every thread and finalizes a
    /// request that produced no response as not completed.
    func close() {
        runtime.unbindSerial(self, allThreads: true)
        lock.lock()
        let open = finished ? nil : token
        finished = true
        lock.unlock()
        drain(keepingNewest: 0)
        if let open {
            runtime.store.finalize(token: open, generatedTokens: [], completed: false)
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
