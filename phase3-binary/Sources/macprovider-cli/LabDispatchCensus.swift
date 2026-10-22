// Lab-only device timestamps; no instrumentation is present in release builds.
#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import Foundation
import Metal
import MLX
import ObjectiveC

/// Counts compute dispatches per pipeline (by label or function name) by
/// swizzling the concrete compute encoder class. Lab instrumentation only.
enum LabDispatchCensus {
    private struct BufferRecord {
        var kernels: [String] = []
        var capture: Int?
    }
    private struct Interval {
        let start: Double
        let end: Double
        let kernels: [String]
    }
    nonisolated(unsafe) private static var current: [ObjectIdentifier: String] = [:]
    nonisolated(unsafe) private static var names: [ObjectIdentifier: String] = [:]
    nonisolated(unsafe) private static var owners: [ObjectIdentifier: ObjectIdentifier] = [:]
    nonisolated(unsafe) private static var buffers: [ObjectIdentifier: BufferRecord] = [:]
    nonisolated(unsafe) private static var active: Int?
    nonisolated(unsafe) private static var sequence = 0
    nonisolated(unsafe) private static var intervals: [Interval] = []
    nonisolated(unsafe) private static var invalid = 0
    nonisolated(unsafe) private static var failed = 0
    nonisolated(unsafe) private static var orphanDispatches = 0
    nonisolated(unsafe) private static var installFailures: [String] = []
    static let group = DispatchGroup()
    private static let lock = NSLock()

    private static func remember(_ pso: AnyObject?, _ fn: AnyObject?) {
        guard let pso, let fn = fn as? MTLFunction else { return }
        lock.lock()
        names[ObjectIdentifier(pso)] = fn.name
        lock.unlock()
    }

    static func install() throws {
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
        let sampleQueue = device.makeCommandQueue()!
        let defaultBuffer = sampleQueue.makeCommandBuffer()!
        let concurrentBuffer = sampleQueue.makeCommandBuffer()!
        guard let defaultEncoder = defaultBuffer.makeComputeCommandEncoder(),
              let concurrentEncoder = concurrentBuffer.makeComputeCommandEncoder(dispatchType: .concurrent) else {
            throw ValidationError("census cannot sample default and concurrent Metal encoders")
        }
        var encoderClasses: [AnyClass] = []
        var seenClasses = Set<ObjectIdentifier>()
        for encoder in [defaultEncoder, concurrentEncoder] {
            let cls: AnyClass = object_getClass(encoder)!
            if seenClasses.insert(ObjectIdentifier(cls)).inserted { encoderClasses.append(cls) }
            encoder.endEncoding()
        }
        installEncoderHooks(encoderClasses)
        let queue = device.makeCommandQueue()!
        let cbClass: AnyClass = object_getClass(queue.makeCommandBuffer()!)!
        let makeEncoder = NSSelectorFromString("computeCommandEncoder")
        swizzle(cbClass, makeEncoder) { orig in
            let block: @convention(block) (AnyObject) -> Unmanaged<AnyObject>? = { this in
                typealias F = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
                let result = unsafeBitCast(orig, to: F.self)(this, makeEncoder)
                if let encoder = result?.takeUnretainedValue() { own(encoder, buffer: this) }
                return result
            }
            return imp_implementationWithBlock(block)
        }
        let makeTypedEncoder = NSSelectorFromString("computeCommandEncoderWithDispatchType:")
        swizzle(cbClass, makeTypedEncoder) { orig in
            let block: @convention(block) (AnyObject, UInt) -> Unmanaged<AnyObject>? = { this, dispatchType in
                typealias F = @convention(c) (AnyObject, Selector, UInt) -> Unmanaged<AnyObject>?
                let result = unsafeBitCast(orig, to: F.self)(this, makeTypedEncoder, dispatchType)
                if let encoder = result?.takeUnretainedValue() { own(encoder, buffer: this) }
                return result
            }
            return imp_implementationWithBlock(block)
        }
        let commit = #selector(MTLCommandBuffer.commit)
        swizzle(cbClass, commit) { orig in
            let block: @convention(block) (AnyObject) -> Void = { this in
                if let cb = this as? MTLCommandBuffer {
                    lock.lock()
                    let id = ObjectIdentifier(this)
                    let record = buffers.removeValue(forKey: id)
                    let capture = active
                    let retiredEncoders = owners.compactMap { $0.value == id ? $0.key : nil }
                    for encoder in retiredEncoders {
                        owners.removeValue(forKey: encoder)
                        current.removeValue(forKey: encoder)
                    }
                    if let record, record.capture == capture, capture != nil {
                        group.enter()
                        cb.addCompletedHandler { done in
                            lock.lock()
                            if done.status == .completed, done.error == nil,
                               done.gpuStartTime.isFinite, done.gpuEndTime.isFinite,
                               done.gpuStartTime > 0, done.gpuEndTime > done.gpuStartTime {
                                intervals.append(Interval(start: done.gpuStartTime, end: done.gpuEndTime, kernels: record.kernels))
                            } else {
                                invalid += 1
                                if done.status != .completed || done.error != nil { failed += 1 }
                            }
                            lock.unlock()
                            group.leave()
                        }
                    } else if capture != nil {
                        // Committed during capture without observed compute encoder metadata.
                        group.enter()
                        cb.addCompletedHandler { done in
                            lock.lock()
                            if done.status == .completed, done.error == nil,
                               done.gpuStartTime.isFinite, done.gpuEndTime.isFinite,
                               done.gpuStartTime > 0, done.gpuEndTime > done.gpuStartTime {
                                intervals.append(Interval(start: done.gpuStartTime, end: done.gpuEndTime, kernels: []))
                            } else {
                                invalid += 1
                                if done.status != .completed || done.error != nil { failed += 1 }
                            }
                            lock.unlock()
                            group.leave()
                        }
                    }
                    lock.unlock()
                }
                typealias F = @convention(c) (AnyObject, Selector) -> Void
                unsafeBitCast(orig, to: F.self)(this, commit)
            }
            return imp_implementationWithBlock(block)
        }
        guard installFailures.isEmpty else {
            throw ValidationError("census instrumentation unavailable: \(installFailures.joined(separator: ", "))")
        }
    }


    private static func installEncoderHooks(_ classes: [AnyClass]) {
        let setPipeline = #selector(MTLComputeCommandEncoder.setComputePipelineState(_:))
        let d1 = #selector(MTLComputeCommandEncoder.dispatchThreadgroups(_:threadsPerThreadgroup:))
        let d2 = #selector(MTLComputeCommandEncoder.dispatchThreads(_:threadsPerThreadgroup:))
        // Snapshot every implementation before installing any override: two distinct
        // concrete classes may inherit the same method, and must not wrap each other.
        var originals: [(AnyClass, IMP, IMP, IMP)] = []
        for cls in classes {
            guard let pipeline = class_getInstanceMethod(cls, setPipeline),
                  let groups = class_getInstanceMethod(cls, d1),
                  let threads = class_getInstanceMethod(cls, d2) else {
                installFailures.append("compute encoder dispatch methods: \(NSStringFromClass(cls))")
                continue
            }
            originals.append((cls, method_getImplementation(pipeline),
                              method_getImplementation(groups), method_getImplementation(threads)))
        }
        for (cls, pipelineIMP, groupsIMP, threadsIMP) in originals {
            swizzle(cls, setPipeline, original: pipelineIMP) { orig in
                let block: @convention(block) (AnyObject, MTLComputePipelineState) -> Void = { this, pso in
                    lock.lock()
                    current[ObjectIdentifier(this)] = names[ObjectIdentifier(pso)] ?? pso.label ?? "unlabeled"
                    lock.unlock()
                    typealias F = @convention(c) (AnyObject, Selector, MTLComputePipelineState) -> Void
                    unsafeBitCast(orig, to: F.self)(this, #selector(MTLComputeCommandEncoder.setComputePipelineState(_:)), pso)
                }
                return imp_implementationWithBlock(block)
            }
            swizzle(cls, d1, original: groupsIMP) { orig in
                let block: @convention(block) (AnyObject, MTLSize, MTLSize) -> Void = { this, a, b in
                    count(this)
                    typealias F = @convention(c) (AnyObject, Selector, MTLSize, MTLSize) -> Void
                    unsafeBitCast(orig, to: F.self)(this, d1, a, b)
                }
                return imp_implementationWithBlock(block)
            }
            swizzle(cls, d2, original: threadsIMP) { orig in
                let block: @convention(block) (AnyObject, MTLSize, MTLSize) -> Void = { this, a, b in
                    count(this)
                    typealias F = @convention(c) (AnyObject, Selector, MTLSize, MTLSize) -> Void
                    unsafeBitCast(orig, to: F.self)(this, d2, a, b)
                }
                return imp_implementationWithBlock(block)
            }
        }
    }

    private static func own(_ encoder: AnyObject, buffer: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(buffer)
        owners[ObjectIdentifier(encoder)] = id
        if buffers[id] == nil { buffers[id] = BufferRecord(capture: active) }
    }

    private static func count(_ encoder: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        guard let active else { return }
        let id = ObjectIdentifier(encoder)
        guard let owner = owners[id] else { orphanDispatches += 1; return }
        if buffers[owner]?.capture == nil { buffers[owner]?.capture = active }
        buffers[owner]?.kernels.append(current[id] ?? "unknown")
    }

    private static func swizzle(_ cls: AnyClass, _ sel: Selector, original: IMP? = nil, _ make: (IMP) -> IMP) {
        guard let method = class_getInstanceMethod(cls, sel) else {
            installFailures.append(NSStringFromSelector(sel))
            return
        }
        // Add an override to the concrete class rather than mutating an inherited method.
        let replacement = make(original ?? method_getImplementation(method))
        if !class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }

    static func begin() {
        // Flush work outside the measured chunk before assigning its capture id.
        Stream().synchronize()
        group.wait()
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        active = sequence
        intervals = []; invalid = 0; failed = 0; orphanDispatches = 0
    }

    static func finish() -> [String: Any] {
        Stream().synchronize()
        lock.lock()
        invalid += buffers.values.filter { $0.capture == active && !$0.kernels.isEmpty }.count
        active = nil
        lock.unlock()
        group.wait()
        lock.lock(); defer { lock.unlock() }
        var kernels: [String: Double] = [:]
        var single = 0, multiple = 0, unknown = 0
        var multipleSeconds = 0.0, unknownSeconds = 0.0
        for interval in intervals {
            let seconds = interval.end - interval.start
            if interval.kernels.count == 1, let name = interval.kernels.first, name != "unknown", name != "unlabeled" {
                single += 1
                kernels[name, default: 0] += seconds
            } else if interval.kernels.count > 1 {
                multiple += 1; multipleSeconds += seconds
            } else {
                unknown += 1; unknownSeconds += seconds
            }
        }
        var families: [String: Double] = [:]
        for (name, seconds) in kernels {
            let family: String
            if name.contains("glm5next_kda") { family = "kda_named_kernel" }
            else if name.contains("glm5next_dsa") { family = "dsa_named_kernel" }
            else { family = "other_named_kernel" }
            families[family, default: 0] += seconds
        }
        return [
            "valid_command_buffers": intervals.count,
            "invalid_command_buffers": invalid,
            "failed_command_buffers": failed,
            "orphan_dispatches": orphanDispatches,
            "single_dispatch_command_buffers": single,
            "multi_dispatch_command_buffers": multiple,
            "unknown_command_buffers": unknown,
            "multi_dispatch_seconds": multipleSeconds,
            "unknown_seconds": unknownSeconds,
            "gpu_busy_seconds": unionSeconds(intervals.map { ($0.start, $0.end) }),
            "kernel_seconds": kernels,
            "partial_family_seconds": families,
            "valid": invalid == 0 && orphanDispatches == 0 && single > 0,
        ]
    }

    static func unionSeconds(_ intervals: [(Double, Double)]) -> Double {
        var end = -Double.infinity
        var total = 0.0
        for (start, stop) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if start >= end { total += stop - start; end = stop }
            else if stop > end { total += stop - end; end = stop }
        }
        return total
    }
}
#endif
