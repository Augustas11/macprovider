import Foundation
import Metal
import ObjectiveC

/// Counts compute dispatches per pipeline (by label or function name) by
/// swizzling the concrete compute encoder class. Lab instrumentation only.
enum DispatchCensus {
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    nonisolated(unsafe) static var current: [ObjectIdentifier: String] = [:]
    nonisolated(unsafe) static var enabled = false
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
        guard enabled else { return }
        lock.lock()
        counts[current[ObjectIdentifier(encoder)] ?? "unknown", default: 0] += 1
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

    static func report(steps: Int) {
        let total = counts.values.reduce(0, +)
        print(String(format: "census: %d dispatches over %d steps = %.1f per step", total, steps, Double(total) / Double(steps)))
        for (name, n) in counts.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %7.1f  %@", Double(n) / Double(steps), name))
        }
    }
}
