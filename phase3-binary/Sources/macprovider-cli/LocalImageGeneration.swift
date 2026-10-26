import Foundation
import MacProviderCore
import MacProviderImageGen

struct LocalImageRequest: Decodable, Sendable {
    let prompt: String
    let size: String
    let steps: Int
    let seed: UInt64
    enum CodingKeys: String, CodingKey { case prompt, size, steps, seed, n, response_format }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        size = try c.decodeIfPresent(String.self, forKey: .size) ?? "512x512"
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 4
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? UInt64.random(in: 0...UInt64.max)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 4000,
              ["512x512", "1024x1024"].contains(size), (1...4).contains(steps),
              try c.decodeIfPresent(Int.self, forKey: .n) ?? 1 == 1,
              try c.decodeIfPresent(String.self, forKey: .response_format) ?? "b64_json" == "b64_json"
        else { throw APIError(status: 400, message: "Use a prompt of 1–4000 characters, size 512x512 or 1024x1024, 1–4 steps, n=1 and response_format=b64_json.", code: "invalid_image_request") }
    }
    var pixels: Int { size == "1024x1024" ? 1024 : 512 }
}

enum LocalImageState: String, Sendable, CaseIterable {
    case idle, downloading, holdingCustomers = "holding_customers", generating, warm, restoring
    case recoveryRequired = "recovery_required"
}

struct LocalImageMemoryDecision: Equatable, Sendable {
    let quantized: Bool
    let requiresHold: Bool
    let unavailableReason: String?
    static func evaluate(physicalBytes: UInt64, availableBytes: UInt64, pixels: Int) -> Self {
        let quantized = physicalBytes <= 16 * 1_073_741_824
        let required = UInt64(((pixels == 1024 ? 13.3 : quantized ? 7.4 : 10.2) + 1.5) * 1_000_000_000)
        let reason: String?
        if pixels == 1024 && physicalBytes < 32 * 1_073_741_824 {
            reason = "1024x1024 requires at least 32 GB of physical memory."
        } else if physicalBytes < required {
            reason = "Not enough unified memory for image generation and its 1.5 GB safety margin."
        } else { reason = nil }
        return Self(quantized: quantized, requiresHold: availableBytes < required, unavailableReason: reason)
    }
}

protocol LocalImageBackend: Sendable {
    func prepare(quantized: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func generate(_ request: LocalImageRequest) async throws -> Data
    func unload() async
}

struct LocalSDXLBackend: LocalImageBackend {
    let backend: SDXLTurboBackend
    func prepare(quantized: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await backend.prepare(quantized: quantized) { value in progress(value.completedBytes, value.totalBytes) }
    }
    func generate(_ request: LocalImageRequest) async throws -> Data {
        try await backend.generate(prompt: request.prompt, size: request.pixels, steps: request.steps, seed: request.seed)
    }
    func unload() async { await backend.unload() }
}

struct LocalCreativeLifecycle: Sendable {
    let pause: @Sendable () async throws -> Void
    let drain: @Sendable () async throws -> Void
    let unloadLanguage: @Sendable () async throws -> Void
    let restoreLanguage: @Sendable () async throws -> Void
    let resume: @Sendable () async -> Void
    var languageRestoredAfterRelease: @Sendable () async -> Void = {}
}

/// Owns both the single-flight slot and the creative hold, shared by every HTTP channel.
/// Cleanup runs in a fresh task so request cancellation cannot interrupt restoration.
actor LocalImageGeneration {
    static let capability = "local_image_generation_v1"
    let backend: any LocalImageBackend
    let lifecycle: LocalCreativeLifecycle
    let physicalBytes: UInt64
    let availableBytes: @Sendable () -> UInt64
    let recoveryNanoseconds: UInt64
    let warmNanoseconds: UInt64
    private(set) var state: LocalImageState = .idle
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var operation: Task<Data, Error>?
    private var operationID: UUID?
    private var cancellationRequested = false
    #if DEBUG
    func cancellationRequestedForTest() -> Bool { cancellationRequested }
    var completionBarrierForTest: (@Sendable () async -> Void)?
    func setCompletionBarrierForTest(_ barrier: @escaping @Sendable () async -> Void) {
        completionBarrierForTest = barrier
    }
    #endif
    private var warmTimer: Task<Void, Never>?
    private var held = false
    private var languageUnloaded = false
    private var restoring = false
    private var lastError: String?

    init(backend: any LocalImageBackend, lifecycle: LocalCreativeLifecycle,
         physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
         availableBytes: @escaping @Sendable () -> UInt64 = {
             UInt64(max(0, NativeMTPRoundSystemMemoryProbe.system.sample()?.availableBytes ?? 0))
         }, warmNanoseconds: UInt64 = 120_000_000_000,
         recoveryNanoseconds: UInt64 = 5_000_000_000) {
        self.backend = backend; self.lifecycle = lifecycle; self.physicalBytes = physicalBytes
        self.availableBytes = availableBytes; self.warmNanoseconds = warmNanoseconds
        self.recoveryNanoseconds = recoveryNanoseconds
    }

    func status() -> [String: Any] {
        let decision = LocalImageMemoryDecision.evaluate(physicalBytes: physicalBytes, availableBytes: availableBytes(), pixels: 512)
        return ["state": state.rawValue, "progress": totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0,
                "downloaded_bytes": completedBytes, "total_bytes": totalBytes,
                "available": decision.unavailableReason == nil, "unavailable_reason": decision.unavailableReason as Any? ?? NSNull(),
                "physical_memory_bytes": physicalBytes, "last_error": lastError as Any? ?? NSNull()]
    }

    func generate(_ request: LocalImageRequest, operationID: UUID = UUID()) async throws -> Data {
        guard operation == nil, !restoring, !languageUnloaded || held else {
            throw APIError(status: 429, message: "Image generation is busy. Wait for the current image or restoration to finish.", code: "image_generation_busy")
        }
        let decision = LocalImageMemoryDecision.evaluate(physicalBytes: physicalBytes, availableBytes: availableBytes(), pixels: request.pixels)
        if let reason = decision.unavailableReason { throw APIError(status: 400, message: reason, code: "image_memory_unavailable") }
        warmTimer?.cancel(); warmTimer = nil
        lastError = nil
        cancellationRequested = false
        let task = Task { try await self.perform(request, decision: decision) }
        operation = task
        self.operationID = operationID
        do {
            let data = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            #if DEBUG
            await completionBarrierForTest?()
            #endif
            try Task.checkCancellation()
            guard !cancellationRequested else { throw CancellationError() }
            operation = nil
            state = .warm
            warmTimer = Task { [weak self, warmNanoseconds] in
                do { try await Task.sleep(nanoseconds: warmNanoseconds) } catch { return }
                await self?.restore()
            }
            return data
        } catch {
            lastError = error is CancellationError ? "Image generation cancelled." : String(describing: error)
            await Task.detached { await self.restoreCleanup() }.value
            operation = nil
            self.operationID = nil
            throw error
        }
    }

    private func perform(_ request: LocalImageRequest, decision: LocalImageMemoryDecision) async throws -> Data {
        try Task.checkCancellation()
        if decision.requiresHold && !held {
            state = .holdingCustomers
            held = true
            try await lifecycle.pause()
            try await lifecycle.drain()
            try Task.checkCancellation()
            languageUnloaded = true
            try await lifecycle.unloadLanguage()
        }
        state = .downloading
        try await backend.prepare(quantized: decision.quantized) { [weak self] done, total in
            Task { await self?.downloadProgress(done, total) }
        }
        try Task.checkCancellation()
        state = .generating
        let result = try await backend.generate(request)
        try Task.checkCancellation()
        return result
    }
    private func downloadProgress(_ done: Int64, _ total: Int64) {
        guard state == .downloading else { return }
        completedBytes = done; totalBytes = total
    }
    /// A late disconnect or Stop belongs only to its request, including its warm lease.
    func cancel(operationID: UUID) async {
        guard self.operationID == operationID else { return }
        cancellationRequested = true
        if let operation {
            operation.cancel()
            _ = try? await operation.value
            while self.operationID == operationID && self.operation != nil {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        // Completion may have won the child-task race. Restore its warm lease
        // after the owner releases the slot, without touching a successor.
        if self.operationID == operationID { await restore() }
    }
    func cancel() async {
        if let operationID { await cancel(operationID: operationID) }
        else { await restore() }
    }
    func restore() async {
        guard operation == nil, !restoring else { return }
        guard state != .recoveryRequired || held || languageUnloaded else { return }
        // Claim ownership before yielding to the cancellation-independent task;
        // otherwise a new image could start before cleanup reaches this actor.
        restoring = true
        await Task.detached { await self.restoreCleanup(alreadyClaimed: true) }.value
    }
    private func restoreCleanup(alreadyClaimed: Bool = false) async {
        guard alreadyClaimed || !restoring else { return }
        guard state != .recoveryRequired || held || languageUnloaded else { return }
        restoring = true; state = .restoring
        warmTimer?.cancel(); warmTimer = nil
        await backend.unload()
        if languageUnloaded {
            for attempt in 0..<3 {
                do {
                    try await lifecycle.restoreLanguage()
                    languageUnloaded = false
                    // The original release may already have registered an unloaded,
                    // unavailable session. Recovery needs its own authenticated reconnect.
                    if !held { await lifecycle.languageRestoredAfterRelease() }
                    break
                }
                catch {
                    lastError = "Could not reload the language model: \(error)"
                    if attempt < 2 { try? await Task.sleep(nanoseconds: 250_000_000) }
                }
            }
        }
        if held { await lifecycle.resume(); held = false }
        state = languageUnloaded ? .recoveryRequired : .idle
        operationID = nil
        restoring = false
        if languageUnloaded {
            // Keep the saved runtime identity and retry without operator warm swap.
            // Images remain fenced until the base language model is serving again.
            warmTimer = Task { [weak self, recoveryNanoseconds] in
                do { try await Task.sleep(nanoseconds: recoveryNanoseconds) } catch { return }
                await self?.restore()
            }
        }
    }
}
