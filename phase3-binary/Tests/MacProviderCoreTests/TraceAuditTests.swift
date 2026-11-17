import CryptoKit
import XCTest
@testable import MacProviderCore

/// Trace audit lab pilot (#2419, SPEC-036 FR-28/FR-29): leaf encoding, the
/// RFC 6962 tree, draws, and the row -> request -> position map through the
/// residual store under continuous-batching join/leave. No model.
final class TraceAuditTests: XCTestCase {
    // MARK: leaf encoding

    func testLeafBytesLayout() {
        let bytes = TraceAuditLeaf.bytes(kind: .blockInput, block: 3, position: 0x0102_0304, payload: [0xAA, 0xBB])
        XCTAssertEqual(Array(bytes[0 ..< 17]), Array("mp.trace.leaf.v1".utf8) + [0])
        XCTAssertEqual(Array(bytes[17 ..< 21]), [0, 0, 0, 0])
        XCTAssertEqual(Array(bytes[21 ..< 25]), [3, 0, 0, 0])
        XCTAssertEqual(Array(bytes[25 ..< 29]), [0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(Array(bytes[29...]), [0xAA, 0xBB])
        XCTAssertEqual(TraceAuditLeaf.headerByteCount, 29)

        // Kinds 1 and 2 always encode block 0.
        let final = TraceAuditLeaf.header(kind: .finalResidual, block: 27, position: 5)
        XCTAssertEqual(Array(final[17 ..< 25]), [1, 0, 0, 0, 0, 0, 0, 0])
        let pair = TraceAuditLeaf.bytes(kind: .tokenPair, block: 9, position: 1,
                                        payload: TraceAuditLeaf.tokenPairPayload(input: 151_643, served: 0xFFFF_FFFF))
        XCTAssertEqual(Array(pair[17 ..< 25]), [2, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(pair[29...]), [0x5B, 0x50, 0x02, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])

        let expected = Data(SHA256.hash(data: [0x00] + bytes))
        XCTAssertEqual(TraceAuditLeaf.hash(kind: .blockInput, block: 3, position: 0x0102_0304, payload: [0xAA, 0xBB]), expected)
    }

    func testLeafIndexAndServedTokenRule() {
        // i = p * (L + 2) + j
        XCTAssertEqual(TraceAuditLeaf.index(kind: .blockInput, block: 0, position: 0, blocks: 28), 0)
        XCTAssertEqual(TraceAuditLeaf.index(kind: .blockInput, block: 27, position: 2, blocks: 28), 2 * 30 + 27)
        XCTAssertEqual(TraceAuditLeaf.index(kind: .finalResidual, block: 0, position: 2, blocks: 28), 2 * 30 + 28)
        XCTAssertEqual(TraceAuditLeaf.index(kind: .tokenPair, block: 0, position: 2, blocks: 28), 2 * 30 + 29)
        // Prompt of 3, generated [7, 8, 9]: positions 0..4.
        let served = (0 ..< 5).map { TraceAuditLeaf.servedToken(position: $0, promptTokenCount: 3, generatedTokens: [7, 8, 9]) }
        XCTAssertEqual(served, [0xFFFF_FFFF, 0xFFFF_FFFF, 7, 8, 9])
    }

    // MARK: Merkle

    private func leafHashes(_ n: Int, seed: UInt8 = 0) -> [Data] {
        (0 ..< n).map { Data(SHA256.hash(data: [seed, UInt8($0 & 0xFF), UInt8($0 >> 8)])) }
    }

    func testIncrementalRootEqualsRFC6962Recursion() {
        for n in 1 ... 130 {
            let leaves = leafHashes(n)
            var builder = TraceAuditIncrementalMerkle()
            leaves.forEach { builder.append(leafHash: $0) }
            XCTAssertEqual(builder.root(), TraceAuditMerkle.naiveRoot(leaves[...]), "n=\(n)")
            XCTAssertEqual(TraceAuditMerkleTree(leafHashes: leaves).root(), builder.root(), "n=\(n)")
        }
        XCTAssertNil(TraceAuditIncrementalMerkle().root())
    }

    func testThreeLeafShapeIsLeftHeavyWithoutPromotionVariant() {
        let l = leafHashes(3)
        let expected = TraceAuditMerkle.nodeHash(TraceAuditMerkle.nodeHash(l[0], l[1]), l[2])
        XCTAssertEqual(TraceAuditMerkle.naiveRoot(l[...]), expected)
        // Seven leaves: split at 4.
        let s = leafHashes(7)
        let left = TraceAuditMerkle.nodeHash(TraceAuditMerkle.nodeHash(s[0], s[1]), TraceAuditMerkle.nodeHash(s[2], s[3]))
        let right = TraceAuditMerkle.nodeHash(TraceAuditMerkle.nodeHash(s[4], s[5]), s[6])
        XCTAssertEqual(TraceAuditMerkle.naiveRoot(s[...]), TraceAuditMerkle.nodeHash(left, right))
    }

    func testInclusionPathsVerifyAndTamperingFails() {
        for n in [1, 2, 3, 5, 8, 13, 30, 64, 65] {
            let leaves = leafHashes(n, seed: 9)
            let tree = TraceAuditMerkleTree(leafHashes: leaves)
            let root = tree.root()!
            for i in 0 ..< n {
                let path = tree.path(i)
                XCTAssertTrue(TraceAuditMerkle.verifyInclusion(leafHash: leaves[i], index: i, treeSize: n, path: path, root: root), "n=\(n) i=\(i)")
                if n > 1 {
                    XCTAssertFalse(TraceAuditMerkle.verifyInclusion(leafHash: leaves[(i + 1) % n], index: i, treeSize: n, path: path, root: root))
                    var bad = path
                    bad[0] = Data(repeating: 0, count: 32)
                    XCTAssertFalse(TraceAuditMerkle.verifyInclusion(leafHash: leaves[i], index: i, treeSize: n, path: bad, root: root))
                    // A path alone does not bind the tree size (a size-n path can
                    // verify under n + 1), so the size comes from the header; an
                    // index outside the tree is refused.
                    XCTAssertFalse(TraceAuditMerkle.verifyInclusion(leafHash: leaves[i], index: n, treeSize: n, path: path, root: root))
                }
            }
        }
    }

    func testMultiproofRecomputesRootAndRejectsTampering() {
        var rng = SystemRandomNumberGenerator()
        for n in [1, 2, 3, 7, 30, 65, 130] {
            let leaves = leafHashes(n, seed: 4)
            let tree = TraceAuditMerkleTree(leafHashes: leaves)
            let root = tree.root()!
            let subsets: [Set<Int>] = [[0], [n - 1], Set(0 ..< n), Set((0 ..< n).filter { _ in Bool.random(using: &rng) }).union([n / 2])]
            for opened in subsets {
                let nodes = tree.multiproof(opened: opened)
                let open = Dictionary(uniqueKeysWithValues: opened.map { ($0, leaves[$0]) })
                XCTAssertEqual(TraceAuditMerkle.rootFromMultiproof(leafCount: n, leaves: open, nodes: nodes), root, "n=\(n) \(opened.sorted())")
                XCTAssertEqual(Set(nodes.map(\.key)).count, nodes.count, "each node once")
                // Never more nodes than separate inclusion paths would carry.
                XCTAssertLessThanOrEqual(nodes.count, opened.map { tree.path($0).count }.reduce(0, +))
                if opened.count == 1, let i = opened.first {
                    XCTAssertEqual(nodes.map(\.hash).sorted { $0.lexicographicallyPrecedes($1) },
                                   tree.path(i).sorted { $0.lexicographicallyPrecedes($1) })
                }
                guard !nodes.isEmpty else { continue }
                var bad = nodes
                bad[0] = TraceAuditProofNode(level: bad[0].level, index: bad[0].index, hash: Data(repeating: 0, count: 32))
                XCTAssertNotEqual(TraceAuditMerkle.rootFromMultiproof(leafCount: n, leaves: open, nodes: bad), root)
                XCTAssertNil(TraceAuditMerkle.rootFromMultiproof(leafCount: n, leaves: open, nodes: Array(nodes.dropLast())))
                XCTAssertNil(TraceAuditMerkle.rootFromMultiproof(leafCount: n, leaves: open, nodes: nodes + [nodes[0]]))
                var swapped = open
                let first = opened.sorted()[0]
                swapped[first] = Data(repeating: 1, count: 32)
                XCTAssertNotEqual(TraceAuditMerkle.rootFromMultiproof(leafCount: n, leaves: swapped, nodes: nodes), root)
            }
        }
    }

    // MARK: draws

    func testDrawsMatchIndependentBigIntegerReference() {
        // Reference computed with Python integers (x_i read big-endian,
        // rejection at m * floor(2^256 / m)), root = 0x00..1f, nonce = 0x20..3f.
        let points = TraceAuditChallengePoints.draw(
            root: Data(0 ..< 32), nonce: Data(32 ..< 64), blocks: 28, positions: 300, promptPositions: 250)
        XCTAssertEqual(points.blockPoints, [TraceAuditPoint(block: 4, position: 101), TraceAuditPoint(block: 5, position: 196)])
        XCTAssertEqual(points.promptPoint, TraceAuditPoint(block: 0, position: 207))
        XCTAssertEqual(points.outputPositions, [270, 288])
    }

    func testDrawsStayInRangeAndDoNotRepeat() {
        for seed in 0 ..< 50 {
            let points = TraceAuditChallengePoints.draw(
                root: Data(repeating: UInt8(seed), count: 32), nonce: Data(repeating: 7, count: 32),
                blocks: 2, positions: 3, promptPositions: 2, blockPoints: 5, outputPoints: 5)
            XCTAssertEqual(Set(points.blockPoints).count, 5)
            XCTAssertTrue(points.blockPoints.allSatisfy { $0.block < 2 && $0.position < 3 })
            XCTAssertTrue(points.promptPoint.position < 2)
            // Positions carrying a served token: 1, 2.
            XCTAssertEqual(Set(points.outputPositions), [1, 2])
        }
    }

    // MARK: store and the row -> request -> position map

    private let blocks = 2
    private let hidden = 4

    private func tempStore(maxBytesPerRequest: Int = 1 << 30) throws -> TraceAuditStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trace-audit-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try TraceAuditStore(configuration: TraceAuditStoreConfiguration(
            directory: dir, maxBytesPerRequest: maxBytesPerRequest, maxTotalBytes: 1 << 30, windowSeconds: 600))
    }

    /// The residual every (request, position, slot) must end up with.
    private func vector(_ request: String, _ position: Int, _ slot: Int, salt: Int = 0) -> [UInt8] {
        let r = request.unicodeScalars.first!.value
        return (0 ..< hidden).flatMap { e -> [UInt8] in
            let value = Float16(Float(Int(r) * 1000 + position * 10 + slot) / 64 + Float(e) / 8 + Float(salt))
            return withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
        }
    }

    /// One forward through the store, packed exactly as the capture drains
    /// it: rows in batch order, `[position][slot][hidden]` per row. Row r
    /// writes to `tokens[r.requestID]`, the residuals of `as ?? requestID`.
    private func forward(
        _ store: TraceAuditStore, _ tokens: [String: TraceAuditCaptureToken], _ rows: [TraceAuditForwardRow],
        salt: Int = 0, as residualID: String? = nil
    ) {
        for row in rows {
            var bytes: [UInt8] = []
            for t in 0 ..< row.tokenCount {
                for slot in 0 ... blocks { bytes += vector(residualID ?? row.requestID, row.startPosition + t, slot, salt: salt) }
            }
            bytes.withUnsafeBytes {
                store.write(token: tokens[row.requestID]!, startPosition: row.startPosition, positionCount: row.tokenCount,
                            blocks: blocks, hidden: hidden, bytes: $0)
            }
        }
    }

    private func expectedRoot(_ request: String, prompt: [Int], generated: [Int]) -> Data {
        let positions = prompt.count + generated.count - 1
        var builder = TraceAuditIncrementalMerkle()
        var all: [Data] = []
        for p in 0 ..< positions {
            for slot in 0 ... blocks {
                let h = TraceAuditLeaf.hash(kind: slot < blocks ? .blockInput : .finalResidual, block: slot, position: p,
                                            payload: vector(request, p, slot))
                all.append(h)
            }
            let input = p < prompt.count ? prompt[p] : generated[p - prompt.count]
            let served = TraceAuditLeaf.servedToken(position: p, promptTokenCount: prompt.count, generatedTokens: generated)
            all.append(TraceAuditLeaf.hash(kind: .tokenPair, block: 0, position: p,
                                           payload: TraceAuditLeaf.tokenPairPayload(input: UInt32(input), served: served)))
        }
        all.forEach { builder.append(leafHash: $0) }
        XCTAssertEqual(builder.root(), TraceAuditMerkle.naiveRoot(all[...]))
        return builder.root()!
    }

    func testRowsJoinLeaveAndReorderMapToRequestPositions() async throws {
        let store = try tempStore()
        var t: [String: TraceAuditCaptureToken] = [:]
        let promptA = [11, 12, 13, 14, 15], promptB = [21, 22, 23], promptC = [31, 32, 33, 34]
        t["A"] = store.register(requestID: "A", promptTokens: promptA)
        t["B"] = store.register(requestID: "B", promptTokens: promptB)
        t["C"] = store.register(requestID: "C", promptTokens: promptC)

        // Shared [2, 3] prefill: A 0..2, B 0..2.
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["A", "B"], committedKVTokenCounts: [0, 0], tokensPerRow: 3))
        // The same chunk again (serial fallback after a rejected shared forward): overwrites in place.
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["B"], committedKVTokenCounts: [0], tokensPerRow: 3))
        // A's last prompt chunk alone: 3..4.
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["A"], committedKVTokenCounts: [3], tokensPerRow: 2))
        // Decode window of 2 steps over [A, B]: A 5, 6; B 3, 4.
        for step in 0 ..< 2 {
            forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["A", "B"], committedKVTokenCounts: [5, 3], tokensPerRow: 1, stepIndex: step))
        }
        // C joins with its whole prompt.
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["C"], committedKVTokenCounts: [0], tokensPerRow: 4))
        // New session, rows reordered: [B, C, A]: B 5, 6; C 4, 5; A 7, 8.
        for step in 0 ..< 2 {
            forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["B", "C", "A"], committedKVTokenCounts: [5, 4, 7], tokensPerRow: 1, stepIndex: step))
        }
        // A leaves: 4 emitted tokens -> 5 + 4 - 1 = 8 positions; its window
        // overshoot (position 8) is cut.
        let genA = [100, 101, 102, 103]
        store.finalize(token: t["A"]!, generatedTokens: genA, completed: true)
        // [C, B]: C 6; B 7.
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["C", "B"], committedKVTokenCounts: [6, 7], tokensPerRow: 1))
        let genB = [200, 201, 202, 203, 204, 205]  // 3 + 6 - 1 = 8 positions
        let genC = [300, 301, 302, 303]            // 4 + 4 - 1 = 7 positions
        store.finalize(token: t["B"]!, generatedTokens: genB, completed: true)
        store.finalize(token: t["C"]!, generatedTokens: genC, completed: true)

        for (id, prompt, gen) in [("A", promptA, genA), ("B", promptB, genB), ("C", promptC, genC)] {
            let commitment = await store.awaitCommitment(id)
            let positions = prompt.count + gen.count - 1
            XCTAssertEqual(commitment, .root(expectedRoot(id, prompt: prompt, generated: gen),
                                             positions: positions, leaves: positions * (blocks + 2)), id)
            // The residual file holds exactly the committed positions.
            let stored = try Data(contentsOf: store.url(for: id, suffix: "resid"))
            var expected: [UInt8] = []
            for p in 0 ..< positions { for slot in 0 ... blocks { expected += vector(id, p, slot) } }
            XCTAssertEqual([UInt8](stored), expected, id)
            let attributes = try FileManager.default.attributesOfItem(atPath: store.url(for: id, suffix: "resid").path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            // The leaf-hash file reproduces the root.
            let lh = try Data(contentsOf: store.url(for: id, suffix: "lh"))
            let hashes = (0 ..< lh.count / 32).map { lh.subdata(in: $0 * 32 ..< ($0 + 1) * 32) }
            XCTAssertEqual(TraceAuditMerkleTree(leafHashes: hashes).root(), expectedRoot(id, prompt: prompt, generated: gen))
        }
        store.release("A")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: "A", suffix: "resid").path))
    }

    func testMarkersPrefixGapCapPrivacyAndDiscard() async throws {
        let store = try tempStore(maxBytesPerRequest: 3 * (2 + 1) * 4 * 2)  // three positions
        var t: [String: TraceAuditCaptureToken] = [:]
        // First captured position above 0: positions below it came from a cache.
        t["D"] = store.register(requestID: "D", promptTokens: [1, 2, 3, 4])
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["D"], committedKVTokenCounts: [2], tokensPerRow: 2))
        store.finalize(token: t["D"]!, generatedTokens: [9], completed: true)
        // A missed position.
        t["E"] = store.register(requestID: "E", promptTokens: [1, 2])
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["E"], committedKVTokenCounts: [0], tokensPerRow: 1))
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["E"], committedKVTokenCounts: [2], tokensPerRow: 1))
        store.finalize(token: t["E"]!, generatedTokens: [9, 9], completed: true)
        // Over the byte cap.
        t["F"] = store.register(requestID: "F", promptTokens: [1, 2, 3, 4])
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["F"], committedKVTokenCounts: [0], tokensPerRow: 4))
        store.finalize(token: t["F"]!, generatedTokens: [9], completed: true)
        // Privacy class: never stored.
        t["G"] = store.register(requestID: "G", promptTokens: [1, 2], unavailable: .privacyClass)
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["G"], committedKVTokenCounts: [0], tokensPerRow: 2))
        XCTAssertFalse(store.isCapturing(t["G"]!))
        store.finalize(token: t["G"]!, generatedTokens: [9], completed: true)
        // Failed request: nothing committed.
        t["H"] = store.register(requestID: "H", promptTokens: [1, 2])
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["H"], committedKVTokenCounts: [0], tokensPerRow: 2))
        store.finalize(token: t["H"]!, generatedTokens: [], completed: false)

        let d = await store.awaitCommitment("D")
        let e = await store.awaitCommitment("E")
        let f = await store.awaitCommitment("F")
        let g = await store.awaitCommitment("G")
        let h = await store.awaitCommitment("H")
        XCTAssertEqual(d, .unavailable(.prefixCache))
        XCTAssertEqual(e, .unavailable(.storage))
        XCTAssertEqual(f, .unavailable(.storage))
        XCTAssertEqual(g, .unavailable(.privacyClass))
        XCTAssertEqual(h, .discarded)
        for id in ["D", "E", "F", "G", "H"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: id, suffix: "resid").path), id)
        }
        XCTAssertEqual(TraceAuditUnavailableReason.uncalibrated.marker, "trace_unavailable:uncalibrated")
    }

    func testStoreDirectoryMayNotSitInsideTheKVDiskTier() {
        XCTAssertThrowsError(try TraceAuditStoreConfiguration.fromEnvironment(
            ["MACPROVIDER_TRACE_AUDIT_LAB_DIR": "/tmp/kv/trace"], kvDiskDirectory: "/tmp/kv"))
        XCTAssertNoThrow(try TraceAuditStoreConfiguration.fromEnvironment(
            ["MACPROVIDER_TRACE_AUDIT_LAB_DIR": "/tmp/kv-trace"], kvDiskDirectory: "/tmp/kv"))
    }

    func testStartupDeletesLeftoverFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trace-audit-left-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("old.resid"))
        _ = try TraceAuditStore(configuration: TraceAuditStoreConfiguration(
            directory: dir, maxBytesPerRequest: 1, maxTotalBytes: 1, windowSeconds: 1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testFR30DefaultsAndWindowEndDeletesTheTrace() async throws {
        let defaults = try TraceAuditStoreConfiguration.fromEnvironment([:], kvDiskDirectory: "/tmp/kv")
        XCTAssertEqual(defaults.maxTotalBytes, 8 << 30)
        XCTAssertEqual(defaults.windowSeconds, 600)

        let store = try tempStore()
        var t: [String: TraceAuditCaptureToken] = [:]
        t["W"] = store.register(requestID: "W", promptTokens: [1, 2])
        forward(store, t, TraceAuditForwardRow.rows(requestIDs: ["W"], committedKVTokenCounts: [0], tokensPerRow: 2))
        store.finalize(token: t["W"]!, generatedTokens: [5], completed: true)
        let commitment = await store.awaitCommitment("W")
        guard case .some(.root(_, _, _)) = commitment else { return XCTFail("no root: \(String(describing: commitment))") }
        let resid = store.url(for: "W", suffix: "resid").path
        store.purgeExpired(now: Date().addingTimeInterval(599))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resid), "inside the window")
        store.purgeExpired(now: Date().addingTimeInterval(601))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resid), "window ended")
    }

    func testSameRequestIDRegistrationsStayIsolated() async throws {
        let store = try tempStore()
        let prompt = [1, 2, 3]
        // A CB request "S" owns the files; a serial request reusing "S" gets
        // its own, refused entry.
        let cb = store.register(requestID: "S", promptTokens: prompt)
        let serial = store.register(requestID: "S", promptTokens: [7, 7, 7, 7])
        XCTAssertNotEqual(cb, serial)
        XCTAssertTrue(store.isCapturing(cb))
        XCTAssertFalse(store.isCapturing(serial))

        forward(store, ["S": cb], TraceAuditForwardRow.rows(requestIDs: ["S"], committedKVTokenCounts: [0], tokensPerRow: 3))
        // The serial forwards, at its own offsets and with other residuals,
        // do not reach the CB request's file.
        forward(store, ["S": serial], TraceAuditForwardRow.rows(requestIDs: ["S"], committedKVTokenCounts: [0], tokensPerRow: 4),
                as: "Z")
        store.markUnavailable(serial, .quantizedKV)
        XCTAssertTrue(store.isCapturing(cb))
        // The serial finalize resolves only its own entry.
        store.finalize(token: serial, generatedTokens: [9, 9, 9, 9, 9], completed: true)
        XCTAssertTrue(store.isCapturing(cb))
        XCTAssertEqual(store.commitment("S"), .pending)

        forward(store, ["S": cb], TraceAuditForwardRow.rows(requestIDs: ["S"], committedKVTokenCounts: [3], tokensPerRow: 1))
        let generated = [40, 41]
        store.finalize(token: cb, generatedTokens: generated, completed: true)
        let commitment = await store.awaitCommitment("S")
        let positions = prompt.count + generated.count - 1
        XCTAssertEqual(commitment, .root(expectedRoot("S", prompt: prompt, generated: generated),
                                         positions: positions, leaves: positions * (blocks + 2)))
        var expected: [UInt8] = []
        for p in 0 ..< positions { for slot in 0 ... blocks { expected += vector("S", p, slot) } }
        XCTAssertEqual([UInt8](try Data(contentsOf: store.url(for: "S", suffix: "resid"))), expected)

        // While the committed entry is held, a replay of the ID is refused too.
        let replay = store.register(requestID: "S", promptTokens: prompt)
        XCTAssertFalse(store.isCapturing(replay))
        store.finalize(token: replay, generatedTokens: [], completed: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: "S", suffix: "resid").path))
        XCTAssertEqual(store.commitment("S"), commitment)
    }

    func testOnlyTheRegisteringSubmissionFinalizes() async throws {
        let store = try tempStore()
        let prompt = [1, 2]
        let canonical = store.register(requestID: "K", promptTokens: prompt)
        forward(store, ["K": canonical], TraceAuditForwardRow.rows(requestIDs: ["K"], committedKVTokenCounts: [0], tokensPerRow: 2))
        // A duplicate waiter (or a rejected mismatched duplicate) registers,
        // then throws before the canonical row ends.
        let duplicate = store.register(requestID: "K", promptTokens: prompt)
        store.finalize(token: duplicate, generatedTokens: [], completed: false)
        XCTAssertTrue(store.isCapturing(canonical), "the canonical capture survives")
        XCTAssertEqual(store.commitment("K"), .pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: "K", suffix: "resid").path))

        forward(store, ["K": canonical], TraceAuditForwardRow.rows(requestIDs: ["K"], committedKVTokenCounts: [2], tokensPerRow: 1))
        let generated = [5, 6]
        store.finalize(token: canonical, generatedTokens: generated, completed: true)
        let commitment = await store.awaitCommitment("K")
        XCTAssertEqual(commitment, .root(expectedRoot("K", prompt: prompt, generated: generated),
                                         positions: 3, leaves: 3 * (blocks + 2)))
        // Releasing the request removes the owner's files; the refused entry
        // never had any and goes with the window.
        store.release("K")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: "K", suffix: "resid").path))
        XCTAssertNil(store.commitment("K"))
    }
}
