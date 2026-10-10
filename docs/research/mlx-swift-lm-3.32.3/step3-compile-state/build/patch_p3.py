# Lab-only: repeat the matrix in one process (LAB_REPEAT) with churn between engines (LAB_CHURN_GB).
import sys
p = sys.argv[1] + '/Sources/macprovider-cli/NativeMTPBenchCommand.swift'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old[:60]
    s = s.replace(old, new)
rep("""        if phase != .sustained {
            for cell in policy.matrixCells {
                guard onlyCell == nil || onlyCell == cell.id else { continue }
                try await runCell(
                    cell,
                    writer: writer,
                    completedBlocks: existing.completedMatrixBlocks[cell.id] ?? [],
                    completedWarmups: existing.completedWarmups[cell.id] ?? []
                )
            }
        }""", """        if phase != .sustained {
            let labRepeat = Int(ProcessInfo.processInfo.environment["LAB_REPEAT"] ?? "") ?? 1
            for rep in 0..<labRepeat {
            for cell in policy.matrixCells {
                guard onlyCell == nil || onlyCell == cell.id else { continue }
                Self.labChurn(rep: rep, cell: cell.id)
                try await runCell(
                    cell,
                    writer: writer,
                    completedBlocks: existing.completedMatrixBlocks[cell.id] ?? [],
                    completedWarmups: existing.completedWarmups[cell.id] ?? [],
                    labBlockOffset: rep * 1000
                )
            }
            }
        }""")
rep("""        completedBlocks: Set<Int>,
        completedWarmups: Set<Int>
    ) async throws {
        let fixture = try await fixture(for: cell)
        for warmup in 0..<policy.warmupRuns {
            let block = -1 - warmup
""", """        completedBlocks: Set<Int>,
        completedWarmups: Set<Int>,
        labBlockOffset: Int = 0
    ) async throws {
        let fixture = try await fixture(for: cell)
        for warmup in 0..<policy.warmupRuns {
            let block = -1 - warmup - labBlockOffset
""")
rep("""        for block in 0..<policy.blocks {
            guard !completedBlocks.contains(block) else { continue }
            let prompts = try await makePrompts(runtime: fixture.runtimes.ordinary, cell: cell, block: block)
            let nativeFirst = nativeFirstByBlock[block]""", """        for localBlock in 0..<policy.blocks {
            let block = localBlock + labBlockOffset
            guard !completedBlocks.contains(block) else { continue }
            let prompts = try await makePrompts(runtime: fixture.runtimes.ordinary, cell: cell, block: block)
            let nativeFirst = nativeFirstByBlock[localBlock]""")
rep("""    private func runSustained(""", """    /// LAB: perturb allocator state between engines. LAB_CHURN_GB allocates and
    /// frees that much MLX memory and a burst of small Swift objects.
    private static func labChurn(rep: Int, cell: String) {
        FileHandle.standardError.write("[lab-cell] rep=\\(rep) cell=\\(cell) at=\\(Date().timeIntervalSince1970)\\n".data(using: .utf8)!)
        guard let gb = Int(ProcessInfo.processInfo.environment["LAB_CHURN_GB"] ?? ""), gb > 0 else { return }
        var held: [MLXArray] = []
        for i in 0..<gb {
            let a = MLXArray.ones([256, 1024, 1024], dtype: .float32) * Float(i + rep)
            eval(a)
            held.append(a)
        }
        var junk: [NSObject] = []
        for _ in 0..<(20_000 + rep * 997) { junk.append(NSObject()) }
        junk.removeAll()
        held.removeAll()
        Memory.clearCache()
    }

    private func runSustained(""")
rep('import MacProviderCore\n', 'import MacProviderCore\nimport MLX\n')
open(p, 'w').write(s)
print("patched", p)
