# Lab-only v2 on top of v1: orphaned-entry counter and MLX_LAB_ALIAS (one cache key per input signature).
import sys
p = sys.argv[1] + '/Source/MLX/Transforms+Compile.swift'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)
rep("""    private var labSeen = Set<String>()
""", """    private var labSeen = Set<String>()
    // LAB: threads whose (thread-local) compile cache this instance has entries in.
    private var labThreads = Set<UInt32>()
""")
rep("""    deinit {
        let functionID = id!
""", """    deinit {
        let functionID = id!
        if LabStale.enabled, !labThreads.isEmpty {
            LabStale.recordDeinit(threads: labThreads, on: pthread_mach_thread_np(pthread_self()))
        }
""")
rep("""        let compileStatus = mlx_detail_compile(&compiled, innerClosure, id, shapeless, [], 0)""",
"""        var effectiveID: UInt = id
        if LabStale.alias, !stateInputs.isEmpty {
            let signature = (arguments + stateInputs).map { "\\($0.shape)\\($0.dtype)" }.joined(separator: ",")
            effectiveID = LabStale.aliasID(signature)
        }
        if LabStale.enabled, !stateInputs.isEmpty {
            labThreads.insert(pthread_mach_thread_np(pthread_self()))
        }
        let compileStatus = mlx_detail_compile(&compiled, innerClosure, effectiveID, shapeless, [], 0)""")
rep("""        if LabStale.enabled, !stateInputs.isEmpty {
            let tid""", """        if LabStale.enabled, !LabStale.alias, !stateInputs.isEmpty {
            let tid""")
rep("""enum LabStale {
    static let enabled = ProcessInfo.processInfo.environment["MLX_LAB_STALE"] == "1"
""", """public enum LabStale {
    static let enabled = ProcessInfo.processInfo.environment["MLX_LAB_STALE"] == "1"
    static let alias = ProcessInfo.processInfo.environment["MLX_LAB_ALIAS"] == "1"
    nonisolated(unsafe) private static var aliasIDs: [String: UInt] = [:]
    nonisolated(unsafe) private static var deinits = 0
    nonisolated(unsafe) private static var orphanedEntries = 0

    static func aliasID(_ signature: String) -> UInt {
        lock.withLock {
            if let id = aliasIDs[signature] { return id }
            let id = (UInt(0xA1) << 56) | UInt(aliasIDs.count + 1)
            aliasIDs[signature] = id
            return id
        }
    }

    static func recordDeinit(threads: Set<UInt32>, on thread: UInt32) {
        lock.withLock {
            deinits += 1
            orphanedEntries += threads.subtracting([thread]).count
        }
    }

    /// One line for lab logs.
    public static func summary() -> String {
        lock.withLock {
            "stale_hits=\\(hits) stale_mismatches=\\(mismatches) stateful_deinits=\\(deinits) "
                + "orphaned_thread_entries=\\(orphanedEntries) alias_signatures=\\(aliasIDs.count)"
        }
    }
""")
open(p, 'w').write(s)
print("patched v2", p)
