import Foundation
import Metal
import ObjectiveC

/// Counts compute dispatches per pipeline (by label or function name) by
/// swizzling the concrete compute encoder class. Lab instrumentation only.
enum DispatchCensus {
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    nonisolated(unsafe) static var current: [ObjectIdentifier: String] = [:]
    nonisolated(unsafe) static var enabled = false
    /// Buffer bytes bound for the next dispatch, per encoder (index -> bytes).
    nonisolated(unsafe) static var bound: [ObjectIdentifier: [Int: Int]] = [:]
    /// Bound bytes per kernel name (an upper bound of bytes moved; a gather
    /// kernel binds whole expert tensors but reads only the routed rows).
    nonisolated(unsafe) static var bytes: [String: Int] = [:]
    /// Kernels dispatched since the last command-buffer commit (one stream).
    nonisolated(unsafe) static var pending: [String] = []
    /// GPU time per kernel name from command buffers that hold one kernel.
    nonisolated(unsafe) static var gpuTime: [String: Double] = [:]
    nonisolated(unsafe) static var gpuCount: [String: Int] = [:]
    /// (gpuStart, gpuEnd) of every committed command buffer while enabled.
    nonisolated(unsafe) static var intervals: [(Double, Double)] = []
    nonisolated(unsafe) static var timing = false
    static let group = DispatchGroup()
    static let lock = NSLock()

    nonisolated(unsafe) static var names: [ObjectIdentifier: String] = [:]

    private static func remember(_ pso: AnyObject?, _ fn: AnyObject?) {
        guard let pso, let fn = fn as? MTLFunction else { return }
        lock.lock()
        names[ObjectIdentifier(pso)] = fn.name
        lock.unlock()
    }

    static func install() {
        let device = MTLCreateSystemDefaultDevice()!
        let dcls: AnyClass = object_getClass(device)!
        let s1 = NSSelectorFromString("newComputePipelineStateWithFunction:error:")
        swizzle(dcls, s1) { orig in
            let block: @convention(block) (AnyObject, AnyObject, UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>? = { this, fn, err in
                typealias F = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
                let r = unsafeBitCast(orig, to: F.self)(this, s1, fn, err)
                remember(r?.takeUnretainedValue(), fn)
                return r
            }
            return imp_implementationWithBlock(block)
        }
        let s2 = NSSelectorFromString("newComputePipelineStateWithDescriptor:options:reflection:error:")
        swizzle(dcls, s2) { orig in
            let block: @convention(block) (AnyObject, AnyObject, UInt, UnsafeMutableRawPointer?, UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>? = { this, desc, o, refl, err in
                typealias F = @convention(c) (AnyObject, Selector, AnyObject, UInt, UnsafeMutableRawPointer?, UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
                let r = unsafeBitCast(orig, to: F.self)(this, s2, desc, o, refl, err)
                remember(r?.takeUnretainedValue(), (desc as? MTLComputePipelineDescriptor)?.computeFunction)
                return r
            }
            return imp_implementationWithBlock(block)
        }
        let s3 = NSSelectorFromString("newComputePipelineStateWithFunction:options:reflection:error:")
        swizzle(dcls, s3) { orig in
            let block: @convention(block) (AnyObject, AnyObject, UInt, UnsafeMutableRawPointer?, UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>? = { this, fn, o, refl, err in
                typealias F = @convention(c) (AnyObject, Selector, AnyObject, UInt, UnsafeMutableRawPointer?, UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
                let r = unsafeBitCast(orig, to: F.self)(this, s3, fn, o, refl, err)
                remember(r?.takeUnretainedValue(), fn)
                return r
            }
            return imp_implementationWithBlock(block)
        }
        let encoder = device.makeCommandQueue()!.makeCommandBuffer()!.makeComputeCommandEncoder()!
        let cls: AnyClass = object_getClass(encoder)!
        encoder.endEncoding()

        swizzle(cls, #selector(MTLComputeCommandEncoder.setComputePipelineState(_:))) { orig in
            let block: @convention(block) (AnyObject, MTLComputePipelineState) -> Void = { this, pso in
                if enabled {
                    lock.lock()
                    current[ObjectIdentifier(this)] = names[ObjectIdentifier(pso)] ?? pso.label ?? "unlabeled"
                    lock.unlock()
                }
                typealias F = @convention(c) (AnyObject, Selector, MTLComputePipelineState) -> Void
                unsafeBitCast(orig, to: F.self)(this, #selector(MTLComputeCommandEncoder.setComputePipelineState(_:)), pso)
            }
            return imp_implementationWithBlock(block)
        }
        let d1 = #selector(MTLComputeCommandEncoder.dispatchThreadgroups(_:threadsPerThreadgroup:))
        swizzle(cls, d1) { orig in
            let block: @convention(block) (AnyObject, MTLSize, MTLSize) -> Void = { this, a, b in
                count(this)
                typealias F = @convention(c) (AnyObject, Selector, MTLSize, MTLSize) -> Void
                unsafeBitCast(orig, to: F.self)(this, d1, a, b)
            }
            return imp_implementationWithBlock(block)
        }
        let sb = NSSelectorFromString("setBuffer:offset:atIndex:")
        swizzle(cls, sb) { orig in
            let block: @convention(block) (AnyObject, MTLBuffer?, Int, Int) -> Void = { this, buffer, offset, index in
                lock.lock()
                bound[ObjectIdentifier(this), default: [:]][index] = buffer.map { $0.length - offset } ?? 0
                lock.unlock()
                typealias F = @convention(c) (AnyObject, Selector, MTLBuffer?, Int, Int) -> Void
                unsafeBitCast(orig, to: F.self)(this, sb, buffer, offset, index)
            }
            return imp_implementationWithBlock(block)
        }
        let queue = device.makeCommandQueue()!
        let cbClass: AnyClass = object_getClass(queue.makeCommandBuffer()!)!
        let commit = #selector(MTLCommandBuffer.commit)
        swizzle(cbClass, commit) { orig in
            let block: @convention(block) (AnyObject) -> Void = { this in
                if enabled || timing, let cb = this as? MTLCommandBuffer {
                    lock.lock()
                    let kernels = pending
                    pending = []
                    lock.unlock()
                    group.enter()
                    cb.addCompletedHandler { done in
                        lock.lock()
                        intervals.append((done.gpuStartTime, done.gpuEndTime))
                        if kernels.count == 1 {
                            gpuTime[kernels[0], default: 0] += done.gpuEndTime - done.gpuStartTime
                            gpuCount[kernels[0], default: 0] += 1
                        }
                        lock.unlock()
                        group.leave()
                    }
                }
                typealias F = @convention(c) (AnyObject, Selector) -> Void
                unsafeBitCast(orig, to: F.self)(this, commit)
            }
            return imp_implementationWithBlock(block)
        }
        let d2 = #selector(MTLComputeCommandEncoder.dispatchThreads(_:threadsPerThreadgroup:))
        swizzle(cls, d2) { orig in
            let block: @convention(block) (AnyObject, MTLSize, MTLSize) -> Void = { this, a, b in
                count(this)
                typealias F = @convention(c) (AnyObject, Selector, MTLSize, MTLSize) -> Void
                unsafeBitCast(orig, to: F.self)(this, d2, a, b)
            }
            return imp_implementationWithBlock(block)
        }
    }

    private static func count(_ encoder: AnyObject) {
        lock.lock()
        let id = ObjectIdentifier(encoder)
        let total = bound[id]?.values.reduce(0, +) ?? 0
        bound[id] = [:]
        if enabled {
            let name = current[id] ?? "unknown"
            counts[name, default: 0] += 1
            bytes[name, default: 0] += total
            pending.append(name)
        }
        lock.unlock()
    }

    private static func swizzle(_ cls: AnyClass, _ sel: Selector, _ make: (IMP) -> IMP) {
        guard let method = class_getInstanceMethod(cls, sel) else {
            print("census: no method \(sel) on \(cls)")
            return
        }
        let orig = method_getImplementation(method)
        method_setImplementation(method, make(orig))
    }

    static func reset() {
        lock.lock()
        counts = [:]; bytes = [:]; pending = []; gpuTime = [:]; gpuCount = [:]; intervals = []
        lock.unlock()
    }

    /// Kernel family for the per-family table.
    static func family(_ name: String) -> String {
        let rules: [(String, String)] = [
            ("glm5next_moe", "moe_fused"), ("glm5next_router", "moe_router"),
            ("gather_qmv", "moe_gather_qmv"), ("glm5next_multi_qmv", "kda_multi_qmv"),
            ("glm5next_kda", "kda_kernel"), ("glm5next_hc", "hc"), ("glm5next_dsa", "dsa_select"),
            ("qmv_fast", "qmv_fast"), ("qmv_quad", "qmv_quad"), ("affine_qmv", "qmv_other"),
            ("steel", "gemm"), ("sdpa", "sdpa"), ("softmax", "softmax"), ("rms", "rmsnorm"),
            ("copy", "copy"), ("gather", "gather"), ("reduce", "reduce"), ("arg", "arg"),
            ("dequantize", "dequantize"),
        ]
        for (needle, label) in rules where name.contains(needle) { return label }
        return "elementwise/other"
    }

    /// Per-kernel and per-family GPU time (from one-kernel command buffers),
    /// bound bytes and implied bandwidth, per decode step.
    static func gpuReport(steps: Int) {
        let n = Double(steps)
        var fam: [String: (Double, Int, Int)] = [:]
        print("gpu:  us/step  n/step   MB/step     GB/s  kernel")
        for (name, t) in gpuTime.sorted(by: { $0.value > $1.value }) {
            let us = t * 1e6 / n
            let mb = Double(bytes[name] ?? 0) / 1e6 / n
            let cnt = counts[name] ?? 0
            print(String(format: "gpu: %8.1f %7.1f %9.2f %8.1f  %@", us, Double(cnt) / n, mb, us > 0 ? mb / us * 1e3 : 0, String(name.prefix(110))))
            let f = family(name)
            let prev = fam[f] ?? (0, 0, 0)
            fam[f] = (prev.0 + us, prev.1 + cnt, prev.2 + (bytes[name] ?? 0))
        }
        let total = fam.values.reduce(0) { $0 + $1.0 }
        print(String(format: "family: total kernel GPU time %.2f ms/step", total / 1e3))
        for (f, v) in fam.sorted(by: { $0.value.0 > $1.value.0 }) {
            let mb = Double(v.2) / 1e6 / n
            print(String(format: "family: %8.1f us %5.1f%%  n=%6.1f  %8.2f MB  %7.1f GB/s  %@", v.0, v.0 / total * 100, Double(v.1) / n, mb, v.0 > 0 ? mb / v.0 * 1e3 : 0, f))
        }
    }

    /// GPU busy time (union of command-buffer intervals) per step.
    static func busyPerStep(steps: Int) -> Double {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var busy = 0.0
        var end = -Double.infinity
        for (a, b) in sorted {
            if a >= end { busy += b - a; end = b } else if b > end { busy += b - end; end = b }
        }
        return busy / Double(steps)
    }

    static func report(steps: Int) {
        let total = counts.values.reduce(0, +)
        print(String(format: "census: %d dispatches over %d steps = %.1f per step", total, steps, Double(total) / Double(steps)))
        for (name, n) in counts.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %7.1f  %@", Double(n) / Double(steps), name))
        }
    }
}
