# Lab-only: stale compile-cache hit detector for mlx-swift CompiledFunction.
import sys
p = sys.argv[1] + '/Source/MLX/Transforms+Compile.swift'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old[:60]
    s = s.replace(old, new)

rep("""    let shapeless: Bool

    init(""", """    let shapeless: Bool

    // LAB: (thread, argument signature) pairs this instance has run on.
    private var labSeen = Set<String>()

    init(""")
rep("""        let stateInputs = inputs.flatMap { $0.innerState() }
        let argumentsCount = arguments.count
""", """        let stateInputs = inputs.flatMap { $0.innerState() }
        let argumentsCount = arguments.count
        var labTraced = false
""")
rep("""        func inner(tracers: [MLXArray]) -> [MLXArray] {
""", """        func inner(tracers: [MLXArray]) -> [MLXArray] {
            labTraced = true
""")
rep("""        let resultLength = resultsPlusStateOutput.count - stateOutput.count
        let results = Array(resultsPlusStateOutput.prefix(resultLength))
        return results
""", """        let resultLength = resultsPlusStateOutput.count - stateOutput.count
        let results = Array(resultsPlusStateOutput.prefix(resultLength))

        if LabStale.enabled, !stateInputs.isEmpty {
            let tid = pthread_mach_thread_np(pthread_self())
            let key = "\\(tid)|" + arguments.map { "\\($0.shape)\\($0.dtype)" }.joined(separator: ",")
                + "|\\(stateInputs.count)"
            let seen = labSeen.contains(key)
            labSeen.insert(key)
            if !labTraced && !seen {
                // This instance never traced on this thread with this signature,
                // yet MLX found a cache entry: an entry left by a freed function
                // whose address this instance reuses. Compare against a fresh
                // trace under a never-used id.
                let freshID = LabStale.nextFreshID()
                var fresh = mlx_closure_new()
                _ = mlx_detail_compile(&fresh, innerClosure, freshID, shapeless, [], 0)
                var freshVector = mlx_vector_array_new()
                _ = mlx_closure_apply(&freshVector, fresh, innerInputsVector)
                let freshResults = Array(mlx_vector_array_values(freshVector).prefix(resultLength))
                mlx_vector_array_free(freshVector)
                mlx_closure_free(fresh)
                var cache = mlx_compile_cache_new()
                mlx_detail_compile_cache(&cache)
                mlx_detail_compile_erase(cache, freshID)
                mlx_compile_cache_free(cache)
                eval(results + freshResults)
                var equal = true
                var maxDiff: Float = 0
                for (a, b) in zip(results, freshResults) {
                    if a.shape != b.shape || a.dtype != b.dtype { equal = false; continue }
                    if !arrayEqual(a, b).item(Bool.self) {
                        equal = false
                        let d = abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
                        maxDiff = max(maxDiff, d)
                    }
                }
                let (hits, bad) = LabStale.record(equal)
                FileHandle.standardError.write(
                    ("[lab-stale] STALE_HIT \\(equal ? "EQUAL" : "MISMATCH") id=0x\\(String(id!, radix: 16)) "
                        + "tid=\\(tid) args=\\(arguments.count) arg0=\\(arguments.first?.shape ?? []) "
                        + "state=\\(stateInputs.count) outputs=\\(results.count) maxAbsDiff=\\(maxDiff) "
                        + "hits=\\(hits) mismatches=\\(bad) at=\\(Date().timeIntervalSince1970)\\n").data(using: .utf8)!)
            }
        }
        return results
""")
s += """

/// LAB: counters for the stale compile-cache detector (MLX_LAB_STALE=1).
enum LabStale {
    static let enabled = ProcessInfo.processInfo.environment["MLX_LAB_STALE"] == "1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hits = 0
    nonisolated(unsafe) private static var mismatches = 0
    nonisolated(unsafe) private static var counter: UInt = 0

    static func nextFreshID() -> UInt {
        lock.withLock {
            counter += 1
            return (UInt(0xF1) << 56) | counter
        }
    }

    static func record(_ equal: Bool) -> (Int, Int) {
        lock.withLock {
            hits += 1
            if !equal { mismatches += 1 }
            return (hits, mismatches)
        }
    }
}
"""
open(p, 'w').write(s)
print("patched", p)
