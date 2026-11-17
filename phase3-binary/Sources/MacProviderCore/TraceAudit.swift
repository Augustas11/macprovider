import CryptoKit
import Darwin
import Foundation

// Trace audit lab pilot (campaign #2419). Model-free part: leaf encoding, the
// RFC 6962 Merkle tree, the per-request residual store and the forward
// row -> request -> position map. The MLX capture hook lives in
// `macprovider-cli/TraceAuditLabCapture.swift`; nothing here runs unless the
// lab flag `MACPROVIDER_TRACE_AUDIT_LAB=1` created a store.

// MARK: - Leaf encoding

/// One Merkle leaf of a response trace.
///
/// leaf bytes = "mp.trace.leaf.v1\0" || u32le kind || u32le block || u32le position || payload
///   kind 0: input residual of `block` at `position`, float16 vector (hidden * 2 bytes, LE)
///   kind 1: final residual at `position` (output of the last block, before the final norm), float16
///   kind 2: token pair: u32le input token id || u32le served token id
/// `block` is 0 for kinds 1 and 2. Leaves are ordered by position; within a
/// position: block 0..L-1, final residual, token pair.
public enum TraceAuditLeaf {
    public static let domain: [UInt8] = Array("mp.trace.leaf.v1".utf8) + [0]
    public static let headerByteCount = domain.count + 12
    /// Served token id of every prompt position except the last.
    public static let noServedToken: UInt32 = 0xFFFF_FFFF

    public enum Kind: UInt32, Sendable {
        case blockInput = 0
        case finalResidual = 1
        case tokenPair = 2
    }

    public static func header(kind: Kind, block: Int, position: Int) -> [UInt8] {
        var out = domain
        out.reserveCapacity(headerByteCount)
        appendU32LE(&out, kind.rawValue)
        appendU32LE(&out, UInt32(kind == .blockInput ? block : 0))
        appendU32LE(&out, UInt32(position))
        return out
    }

    public static func tokenPairPayload(input: UInt32, served: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(8)
        appendU32LE(&out, input)
        appendU32LE(&out, served)
        return out
    }

    public static func bytes(kind: Kind, block: Int, position: Int, payload: [UInt8]) -> [UInt8] {
        header(kind: kind, block: block, position: position) + payload
    }

    /// SHA-256(0x00 || leaf bytes), with the payload streamed from `payload`.
    public static func hash(kind: Kind, block: Int, position: Int, payload: UnsafeRawBufferPointer) -> Data {
        var hasher = SHA256()
        hasher.update(data: [0x00])
        hasher.update(data: header(kind: kind, block: block, position: position))
        hasher.update(bufferPointer: payload)
        return Data(hasher.finalize())
    }

    public static func hash(kind: Kind, block: Int, position: Int, payload: [UInt8]) -> Data {
        payload.withUnsafeBytes { hash(kind: kind, block: block, position: position, payload: $0) }
    }

    /// Leaves per position: L block inputs, the final residual, the token pair.
    public static func leavesPerPosition(blocks: Int) -> Int { blocks + 2 }

    /// Index of a leaf in the response's leaf sequence.
    public static func index(kind: Kind, block: Int, position: Int, blocks: Int) -> Int {
        let base = position * leavesPerPosition(blocks: blocks)
        switch kind {
        case .blockInput: return base + block
        case .finalResidual: return base + blocks
        case .tokenPair: return base + blocks + 1
        }
    }

    /// Served token of each committed position: none for prompt positions
    /// before the last; the token sampled from position p's logits otherwise.
    public static func servedToken(position: Int, promptTokenCount: Int, generatedTokens: [Int]) -> UInt32 {
        guard position >= promptTokenCount - 1 else { return noServedToken }
        return UInt32(truncatingIfNeeded: generatedTokens[position - promptTokenCount + 1])
    }

    static func appendU32LE(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }
}

// MARK: - Merkle tree (RFC 6962 / RFC 9162 shape)

/// RFC 6962 Merkle tree hash: MTH of n > 1 leaves splits at k, the largest
/// power of two strictly less than n: SHA-256(0x01 || MTH(D[0:k]) || MTH(D[k:n])).
/// Leaf hash SHA-256(0x00 || leaf). There is no odd-node promotion variant: the
/// split rule alone defines the tree. An empty tree has no root here (a
/// response always has at least one position).
public enum TraceAuditMerkle {
    public static func nodeHash(_ left: Data, _ right: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: [0x01])
        hasher.update(data: left)
        hasher.update(data: right)
        return Data(hasher.finalize())
    }

    static func largestPowerOfTwoBelow(_ n: Int) -> Int {
        precondition(n > 1)
        var k = 1
        while k << 1 < n { k <<= 1 }
        return k
    }

    /// Reference implementation straight from the RFC recursion.
    public static func naiveRoot(_ leafHashes: ArraySlice<Data>) -> Data? {
        switch leafHashes.count {
        case 0: return nil
        case 1: return leafHashes.first
        default:
            let k = largestPowerOfTwoBelow(leafHashes.count)
            let start = leafHashes.startIndex
            return nodeHash(
                naiveRoot(leafHashes[start ..< start + k])!,
                naiveRoot(leafHashes[(start + k)...])!
            )
        }
    }

    /// RFC 9162 section 2.1.3.2 inclusion proof verification.
    public static func verifyInclusion(
        leafHash: Data, index: Int, treeSize: Int, path: [Data], root: Data
    ) -> Bool {
        guard index >= 0, index < treeSize else { return false }
        var fn = index
        var sn = treeSize - 1
        var r = leafHash
        for p in path {
            if sn == 0 { return false }
            if fn & 1 == 1 || fn == sn {
                r = nodeHash(p, r)
                if fn & 1 == 0 {
                    while fn & 1 == 0 && fn != 0 {
                        fn >>= 1
                        sn >>= 1
                    }
                }
            } else {
                r = nodeHash(r, p)
            }
            fn >>= 1
            sn >>= 1
        }
        return sn == 0 && r == root
    }

    /// Level of the subtree over `size` leaves: the smallest h with 2^h >= size.
    /// Every RFC 6962 subtree starts at a multiple of 2^level, so
    /// `(level, lo >> level)` names it uniquely; a leaf is `(0, index)`.
    public static func level(forSize size: Int) -> Int {
        precondition(size > 0)
        var h = 0
        while 1 << h < size { h += 1 }
        return h
    }

    /// FR-31 multiproof check: recomputes the root of a `leafCount` tree from
    /// the opened leaf hashes and the proof nodes. Every node must be used
    /// exactly once and no node may lie over an opened leaf; otherwise nil.
    public static func rootFromMultiproof(
        leafCount: Int, leaves: [Int: Data], nodes: [TraceAuditProofNode]
    ) -> Data? {
        guard leafCount > 0, leaves.keys.allSatisfy({ $0 >= 0 && $0 < leafCount }) else { return nil }
        var byKey: [TraceAuditProofNode.Key: Data] = [:]
        for node in nodes {
            guard byKey.updateValue(node.hash, forKey: node.key) == nil else { return nil }
        }
        let opened = leaves.keys.sorted()
        var used = 0
        func walk(_ lo: Int, _ hi: Int, _ a: Int, _ b: Int) -> Data? {
            if a == b {
                let h = level(forSize: hi - lo)
                guard let hash = byKey[.init(level: h, index: lo >> h)] else { return nil }
                used += 1
                return hash
            }
            if hi - lo == 1 { return leaves[lo] }
            let k = largestPowerOfTwoBelow(hi - lo)
            var m = a
            while m < b && opened[m] < lo + k { m += 1 }
            guard let left = walk(lo, lo + k, a, m), let right = walk(lo + k, hi, m, b) else { return nil }
            return nodeHash(left, right)
        }
        guard let root = walk(0, leafCount, 0, opened.count), used == nodes.count else { return nil }
        return root
    }
}

/// One multiproof node (FR-31): the hash of the subtree named by
/// `(level, index)` (see `TraceAuditMerkle.level(forSize:)`).
public struct TraceAuditProofNode: Sendable, Equatable {
    public struct Key: Hashable, Sendable {
        public let level: Int
        public let index: Int
    }

    public let level: Int
    public let index: Int
    public let hash: Data

    public init(level: Int, index: Int, hash: Data) {
        self.level = level
        self.index = index
        self.hash = hash
    }

    public var key: Key { Key(level: level, index: index) }
}

/// Streaming RFC 6962 root: a stack of perfect subtrees, largest first. Each
/// push merges equal-size neighbours; `root()` folds the stack right to left,
/// which reproduces the largest-power-of-two split. Memory is O(log n).
public struct TraceAuditIncrementalMerkle: Sendable {
    private var stack: [(hash: Data, size: Int)] = []
    public private(set) var count = 0

    public init() {}

    public mutating func append(leafHash: Data) {
        var entry = (hash: leafHash, size: 1)
        while let last = stack.last, last.size == entry.size {
            stack.removeLast()
            entry = (TraceAuditMerkle.nodeHash(last.hash, entry.hash), last.size * 2)
        }
        stack.append(entry)
        count += 1
    }

    public func root() -> Data? {
        guard var acc = stack.last?.hash else { return nil }
        for entry in stack.dropLast().reversed() {
            acc = TraceAuditMerkle.nodeHash(entry.hash, acc)
        }
        return acc
    }
}

/// Whole tree over materialized leaf hashes, for openings (offline). Subtree
/// hashes are memoized, so a path costs O(log n) after the first root.
public final class TraceAuditMerkleTree {
    public let leafHashes: [Data]
    private var memo: [Int: Data] = [:]

    public init(leafHashes: [Data]) {
        self.leafHashes = leafHashes
    }

    public var count: Int { leafHashes.count }

    public func root() -> Data? {
        count == 0 ? nil : subtree(0, count)
    }

    /// RFC 6962 PATH(m, D[n]): sibling hashes from the leaf upwards.
    public func path(_ index: Int) -> [Data] {
        precondition(index >= 0 && index < count)
        var out: [Data] = []
        collectPath(index, 0, count, &out)
        return out
    }

    /// FR-31 multiproof: the minimal set of subtree nodes that, with the opened
    /// leaves, recomputes the root. Each node appears once, left to right.
    public func multiproof(opened: Set<Int>) -> [TraceAuditProofNode] {
        precondition(opened.allSatisfy { $0 >= 0 && $0 < count })
        let sorted = opened.sorted()
        var out: [TraceAuditProofNode] = []
        func walk(_ lo: Int, _ hi: Int, _ a: Int, _ b: Int) {
            if a == b {
                let h = TraceAuditMerkle.level(forSize: hi - lo)
                out.append(TraceAuditProofNode(level: h, index: lo >> h, hash: subtree(lo, hi)))
                return
            }
            if hi - lo == 1 { return }
            let k = TraceAuditMerkle.largestPowerOfTwoBelow(hi - lo)
            var m = a
            while m < b && sorted[m] < lo + k { m += 1 }
            walk(lo, lo + k, a, m)
            walk(lo + k, hi, m, b)
        }
        if count > 0 { walk(0, count, 0, sorted.count) }
        return out
    }

    private func collectPath(_ m: Int, _ lo: Int, _ hi: Int, _ out: inout [Data]) {
        let n = hi - lo
        guard n > 1 else { return }
        let k = TraceAuditMerkle.largestPowerOfTwoBelow(n)
        if m < k {
            collectPath(m, lo, lo + k, &out)
            out.append(subtree(lo + k, hi))
        } else {
            collectPath(m - k, lo + k, hi, &out)
            out.append(subtree(lo, lo + k))
        }
    }

    private func subtree(_ lo: Int, _ hi: Int) -> Data {
        if hi - lo == 1 { return leafHashes[lo] }
        let key = lo &* 0x1_0000_0000 &+ hi
        if let cached = memo[key] { return cached }
        let k = TraceAuditMerkle.largestPowerOfTwoBelow(hi - lo)
        let value = TraceAuditMerkle.nodeHash(subtree(lo, lo + k), subtree(lo + k, hi))
        memo[key] = value
        return value
    }
}

// MARK: - Forward row map

/// One row of a captured forward: batch row `row` carries `tokenCount`
/// consecutive positions of `requestID`, starting at absolute position
/// `startPosition` (the row's committed KV length before this forward).
public struct TraceAuditForwardRow: Sendable, Equatable {
    public let row: Int
    public let requestID: String
    public let startPosition: Int
    public let tokenCount: Int

    public init(row: Int, requestID: String, startPosition: Int, tokenCount: Int) {
        self.row = row
        self.requestID = requestID
        self.startPosition = startPosition
        self.tokenCount = tokenCount
    }

    /// Rows of a `[B, T]` forward whose row b is request `requestIDs[b]` at
    /// committed KV length `committed[b]`, `stepIndex` steps into a lockstep
    /// window (decode: T = 1, one position per step; prefill: stepIndex 0).
    public static func rows(
        requestIDs: [String], committedKVTokenCounts: [Int], tokensPerRow: Int, stepIndex: Int = 0
    ) -> [TraceAuditForwardRow] {
        precondition(requestIDs.count == committedKVTokenCounts.count)
        return requestIDs.indices.map {
            TraceAuditForwardRow(
                row: $0,
                requestID: requestIDs[$0],
                startPosition: committedKVTokenCounts[$0] + stepIndex * tokensPerRow,
                tokenCount: tokensPerRow
            )
        }
    }
}

// MARK: - Request store

/// Closed reasons a request carries instead of a root.
public enum TraceAuditUnavailableReason: String, Sendable, Equatable, Codable {
    /// Positions before the first captured one came from a reused prompt cache.
    case prefixCache = "prefix_cache"
    /// Native MTP verification computed the row's positions.
    case nativeMTP = "native_mtp"
    case quantizedKV = "quantized_kv"
    /// Byte cap exceeded, a write failed, or capture missed positions.
    case storage
    /// SPEC-049 relay-blind / privacy-class request: never captured or stored.
    case privacyClass = "privacy_class"
    /// Architecture outside the calibration record (qwen2, llama) or an
    /// activation dtype other than float16 (SPEC-036 FR-27/FR-31).
    case uncalibrated

    public var marker: String { "trace_unavailable:\(rawValue)" }
}

public enum TraceAuditCommitment: Sendable, Equatable {
    case pending
    case root(Data, positions: Int, leaves: Int)
    case unavailable(TraceAuditUnavailableReason)
    /// The request ended without a response (failure or cancellation before
    /// any token): nothing is committed and its files are gone.
    case discarded
}

public struct TraceAuditStoreConfiguration: Sendable, Equatable {
    public var directory: URL
    public var maxBytesPerRequest: Int
    public var maxTotalBytes: Int
    /// FR-30 audit window: a committed trace is deleted this long after its
    /// commitment (default 10 minutes), if release or its opening did not
    /// delete it first.
    public var windowSeconds: TimeInterval

    public init(directory: URL, maxBytesPerRequest: Int, maxTotalBytes: Int, windowSeconds: TimeInterval) {
        self.directory = directory
        self.maxBytesPerRequest = maxBytesPerRequest
        self.maxTotalBytes = maxTotalBytes
        self.windowSeconds = windowSeconds
    }

    public static let defaultDirectory = "~/Library/Caches/macprovider/trace-audit-lab"

    /// `MACPROVIDER_TRACE_AUDIT_LAB_DIR`, `..._MAX_BYTES_PER_REQUEST`,
    /// `..._MAX_TOTAL_BYTES` (FR-30 default 8 GiB), `..._WINDOW_SECONDS`
    /// (FR-30 default 600). The directory must not lie inside the KV disk
    /// tier directory.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        kvDiskDirectory: String = KVDiskCacheConfig.defaultDirectory
    ) throws -> TraceAuditStoreConfiguration {
        let raw = environment["MACPROVIDER_TRACE_AUDIT_LAB_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultDirectory
        let dir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        let kv = URL(fileURLWithPath: (kvDiskDirectory as NSString).expandingTildeInPath).standardizedFileURL
        if dir.path == kv.path || dir.path.hasPrefix(kv.path + "/") {
            throw TraceAuditStoreError.directoryInsideKVDiskTier(dir.path)
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            environment[key].flatMap(Int.init).map { max(0, $0) } ?? fallback
        }
        return TraceAuditStoreConfiguration(
            directory: dir,
            maxBytesPerRequest: int("MACPROVIDER_TRACE_AUDIT_LAB_MAX_BYTES_PER_REQUEST", 2 << 30),
            maxTotalBytes: int("MACPROVIDER_TRACE_AUDIT_LAB_MAX_TOTAL_BYTES", 8 << 30),
            windowSeconds: TimeInterval(int("MACPROVIDER_TRACE_AUDIT_LAB_WINDOW_SECONDS", 600))
        )
    }
}

public enum TraceAuditStoreError: Error, Equatable, CustomStringConvertible {
    case directoryInsideKVDiskTier(String)
    case io(String)
    case unknownRequest
    case notCommitted

    public var description: String {
        switch self {
        case .directoryInsideKVDiskTier(let path): return "trace audit lab directory lies inside the KV disk tier: \(path)"
        case .io(let what): return "trace audit lab io: \(what)"
        case .unknownRequest: return "trace audit lab: unknown request"
        case .notCommitted: return "trace audit lab: request has no committed root"
        }
    }
}

/// Per-request residual files and roots.
///
/// Files, all mode 0600 in `configuration.directory` (never in the KV disk
/// tier, never logged):
///   <key>.resid   float16 residuals, fixed stride: position p, slot s
///                 (0..L-1 block inputs, L final residual) at byte offset
///                 (p * (L+1) + s) * hidden * 2. Positions are written with
///                 pwrite, so a re-run of a position (a retried prefill
///                 chunk, the overshoot of a lockstep window) overwrites in
///                 place; finalize truncates to the committed positions.
///   <key>.tokens  u32le input, u32le served per committed position
///   <key>.lh      32-byte leaf hashes in leaf order (for openings)
///   <key>.meta.json
/// `<key>` is the hex SHA-256 of the request ID. The root is computed at
/// finalize by streaming the residual file through `TraceAuditIncrementalMerkle`
/// on a background queue, so the capture path itself only copies bytes.
/// On the byte cap the request is marked `storage`, its files are deleted and
/// it gets no root (the marker replaces it).
public final class TraceAuditStore: @unchecked Sendable {
    public let configuration: TraceAuditStoreConfiguration
    private let lock = NSLock()
    private let rootQueue = DispatchQueue(label: "macprovider.trace-audit-lab.root", qos: .utility)
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0

    private final class Entry {
        let requestID: String
        let key: String
        let promptTokens: [Int]
        let createdAt: Date
        /// When the root was resolved; the FR-30 window runs from here.
        var committedAt: Date?
        var fd: Int32 = -1
        var blocks = 0
        var hidden = 0
        var firstStart: Int?
        /// Every position below this was written at least once.
        var contiguousEnd = 0
        var gap = false
        var bytesReserved = 0
        var unavailable: TraceAuditUnavailableReason?
        var commitment: TraceAuditCommitment = .pending
        var finalized = false
        var waiters: [CheckedContinuation<TraceAuditCommitment?, Never>] = []

        init(requestID: String, key: String, promptTokens: [Int], createdAt: Date) {
            self.requestID = requestID
            self.key = key
            self.promptTokens = promptTokens
            self.createdAt = createdAt
        }

        var stride: Int { (blocks + 1) * hidden * 2 }
    }

    public init(configuration: TraceAuditStoreConfiguration, wipeExisting: Bool = true) throws {
        self.configuration = configuration
        let fm = FileManager.default
        try fm.createDirectory(
            at: configuration.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if wipeExisting {
            // A previous process's window ended with it.
            for name in (try? fm.contentsOfDirectory(atPath: configuration.directory.path)) ?? [] {
                try? fm.removeItem(at: configuration.directory.appendingPathComponent(name))
            }
        }
    }

    public static func key(for requestID: String) -> String {
        SHA256.hash(data: Data(requestID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func url(for requestID: String, suffix: String) -> URL {
        configuration.directory.appendingPathComponent("\(Self.key(for: requestID)).\(suffix)")
    }

    // MARK: lifecycle

    /// Starts tracking a request. A second registration of the same ID (a
    /// duplicate waiter, a replay) is ignored.
    public func register(requestID: String, promptTokens: [Int], unavailable: TraceAuditUnavailableReason? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard entries[requestID] == nil else { return }
        let entry = Entry(
            requestID: requestID, key: Self.key(for: requestID),
            promptTokens: promptTokens, createdAt: Date()
        )
        entry.unavailable = unavailable
        entries[requestID] = entry
    }

    public func isCapturing(_ requestID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[requestID] else { return false }
        return entry.unavailable == nil && !entry.finalized
    }

    /// First reason wins. Deletes whatever was stored.
    public func markUnavailable(_ requestID: String, _ reason: TraceAuditUnavailableReason) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[requestID], entry.unavailable == nil, !entry.finalized else { return }
        entry.unavailable = reason
        dropFilesLocked(entry)
    }

    /// Writes `positionCount` positions starting at `startPosition`.
    /// `bytes` is `[position][slot 0...blocks][hidden]` float16.
    public func write(
        requestID: String, startPosition: Int, positionCount: Int,
        blocks: Int, hidden: Int, bytes: UnsafeRawBufferPointer
    ) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[requestID], entry.unavailable == nil, !entry.finalized,
              positionCount > 0, blocks > 0, hidden > 0 else { return }
        if entry.blocks == 0 {
            entry.blocks = blocks
            entry.hidden = hidden
        }
        guard entry.blocks == blocks, entry.hidden == hidden,
              bytes.count == positionCount * entry.stride else {
            failLocked(entry, .storage)
            return
        }
        if entry.firstStart == nil {
            entry.firstStart = startPosition
            if startPosition != 0 {
                // Positions 0..<start were never computed in this request.
                failLocked(entry, .prefixCache)
                return
            }
        }
        if startPosition > entry.contiguousEnd {
            entry.gap = true
        } else {
            entry.contiguousEnd = max(entry.contiguousEnd, startPosition + positionCount)
        }
        let end = (startPosition + positionCount) * entry.stride
        if end > entry.bytesReserved {
            let grow = end - entry.bytesReserved
            // FR-30: under pressure, expired traces go first.
            if totalBytes + grow > configuration.maxTotalBytes { releaseExpiredLocked(now: Date()) }
            guard end <= configuration.maxBytesPerRequest,
                  totalBytes + grow <= configuration.maxTotalBytes else {
                failLocked(entry, .storage)
                return
            }
            entry.bytesReserved = end
            totalBytes += grow
        }
        if entry.fd < 0 {
            let path = url(for: requestID, suffix: "resid").path
            entry.fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            if entry.fd < 0 {
                failLocked(entry, .storage)
                return
            }
        }
        var offset = 0
        while offset < bytes.count {
            let n = pwrite(
                entry.fd, bytes.baseAddress! + offset, bytes.count - offset,
                off_t(startPosition * entry.stride + offset)
            )
            if n <= 0 {
                failLocked(entry, .storage)
                return
            }
            offset += n
        }
    }

    /// The response is final: `generatedTokens` are the raw sampled tokens
    /// (stop tokens included). Commits positions 0 ..< P + G - 1: the prompt
    /// and every generated token that was fed back. Returns at once; the
    /// root is built on a background queue (`awaitCommitment`).
    public func finalize(requestID: String, generatedTokens: [Int], completed: Bool) {
        lock.lock()
        guard let entry = entries[requestID], !entry.finalized else {
            lock.unlock()
            return
        }
        entry.finalized = true
        if entry.fd >= 0 {
            close(entry.fd)
            entry.fd = -1
        }
        if let reason = entry.unavailable {
            resolveLocked(entry, .unavailable(reason))
            lock.unlock()
            purgeExpired()
            return
        }
        guard completed, !generatedTokens.isEmpty, !entry.promptTokens.isEmpty else {
            dropFilesLocked(entry)
            resolveLocked(entry, .discarded)
            lock.unlock()
            return
        }
        let positions = entry.promptTokens.count + generatedTokens.count - 1
        guard !entry.gap, entry.firstStart == 0, entry.contiguousEnd >= positions, entry.blocks > 0 else {
            entry.unavailable = .storage
            dropFilesLocked(entry)
            resolveLocked(entry, .unavailable(.storage))
            lock.unlock()
            return
        }
        let job = RootJob(
            requestID: requestID, key: entry.key, blocks: entry.blocks, hidden: entry.hidden,
            promptTokens: entry.promptTokens, generatedTokens: generatedTokens, positions: positions
        )
        lock.unlock()
        rootQueue.async { [self] in
            let result: TraceAuditCommitment
            do {
                result = try buildRoot(job)
            } catch {
                result = .unavailable(.storage)
            }
            lock.lock()
            if let entry = entries[requestID] {
                if case .unavailable(let reason) = result {
                    entry.unavailable = reason
                    dropFilesLocked(entry)
                }
                resolveLocked(entry, result)
            }
            lock.unlock()
            purgeExpired()
        }
    }

    public func commitment(_ requestID: String) -> TraceAuditCommitment? {
        lock.lock(); defer { lock.unlock() }
        return entries[requestID]?.commitment
    }

    public func awaitCommitment(_ requestID: String) async -> TraceAuditCommitment? {
        await withCheckedContinuation { (continuation: CheckedContinuation<TraceAuditCommitment?, Never>) in
            lock.lock()
            guard let entry = entries[requestID] else {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            if case .pending = entry.commitment {
                entry.waiters.append(continuation)
                lock.unlock()
            } else {
                let value = entry.commitment
                lock.unlock()
                continuation.resume(returning: value)
            }
        }
    }

    /// Deletes a request's files (after its audit window or opening).
    public func release(_ requestID: String) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[requestID] else { return }
        releaseLocked(entry)
    }

    private func releaseLocked(_ entry: Entry) {
        entries[entry.requestID] = nil
        if entry.fd >= 0 { close(entry.fd); entry.fd = -1 }
        dropFilesLocked(entry)
        if case .pending = entry.commitment { resolveLocked(entry, .discarded) }
    }

    /// Window end: delete every trace.
    public func endWindow() {
        lock.lock()
        let ids = Array(entries.keys)
        lock.unlock()
        ids.forEach(release)
    }

    /// Deletes every finalized trace whose window (from its commitment, or
    /// from registration when it got no root) has ended.
    public func purgeExpired(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        releaseExpiredLocked(now: now)
    }

    private func releaseExpiredLocked(now: Date) {
        let expired = entries.values.filter { entry in
            if case .pending = entry.commitment { return false }  // root still being built
            return entry.finalized
                && now.timeIntervalSince(entry.committedAt ?? entry.createdAt) >= configuration.windowSeconds
        }
        expired.forEach(releaseLocked)
    }

    /// Bytes of the residual file of a committed request (for measurement).
    public func residualBytes(_ requestID: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(for: requestID, suffix: "resid").path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    // MARK: private

    private func failLocked(_ entry: Entry, _ reason: TraceAuditUnavailableReason) {
        if entry.unavailable == nil { entry.unavailable = reason }
        dropFilesLocked(entry)
    }

    private func dropFilesLocked(_ entry: Entry) {
        if entry.fd >= 0 { close(entry.fd); entry.fd = -1 }
        for suffix in ["resid", "tokens", "lh", "meta.json"] {
            try? FileManager.default.removeItem(
                at: configuration.directory.appendingPathComponent("\(entry.key).\(suffix)"))
        }
        totalBytes -= entry.bytesReserved
        entry.bytesReserved = 0
    }

    private func resolveLocked(_ entry: Entry, _ commitment: TraceAuditCommitment) {
        entry.commitment = commitment
        if case .root = commitment {
            entry.committedAt = Date()
            // Window end deletes the trace even if nothing else touches the store.
            rootQueue.asyncAfter(deadline: .now() + configuration.windowSeconds) { [weak self] in
                self?.purgeExpired()
            }
        }
        let waiters = entry.waiters
        entry.waiters = []
        waiters.forEach { $0.resume(returning: commitment) }
    }

    private struct RootJob {
        let requestID: String
        let key: String
        let blocks: Int
        let hidden: Int
        let promptTokens: [Int]
        let generatedTokens: [Int]
        let positions: Int
    }

    private func buildRoot(_ job: RootJob) throws -> TraceAuditCommitment {
        let dir = configuration.directory
        let residPath = dir.appendingPathComponent("\(job.key).resid").path
        let stride = (job.blocks + 1) * job.hidden * 2
        let vector = job.hidden * 2
        guard truncate(residPath, off_t(job.positions * stride)) == 0 else {
            throw TraceAuditStoreError.io("truncate")
        }
        let fd = open(residPath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw TraceAuditStoreError.io("open") }
        defer { close(fd) }
        let lhFD = open(dir.appendingPathComponent("\(job.key).lh").path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard lhFD >= 0 else { throw TraceAuditStoreError.io("open lh") }
        defer { close(lhFD) }
        var tokens = [UInt8]()
        tokens.reserveCapacity(job.positions * 8)
        var builder = TraceAuditIncrementalMerkle()
        var buffer = [UInt8](repeating: 0, count: stride)
        var hashes = Data()
        hashes.reserveCapacity((job.blocks + 2) * 32)
        for p in 0 ..< job.positions {
            try buffer.withUnsafeMutableBytes { raw in
                var got = 0
                while got < stride {
                    let n = pread(fd, raw.baseAddress! + got, stride - got, off_t(p * stride + got))
                    guard n > 0 else { throw TraceAuditStoreError.io("pread") }
                    got += n
                }
            }
            hashes.removeAll(keepingCapacity: true)
            buffer.withUnsafeBytes { raw in
                for slot in 0 ... job.blocks {
                    let payload = UnsafeRawBufferPointer(rebasing: raw[slot * vector ..< (slot + 1) * vector])
                    let h = slot < job.blocks
                        ? TraceAuditLeaf.hash(kind: .blockInput, block: slot, position: p, payload: payload)
                        : TraceAuditLeaf.hash(kind: .finalResidual, block: 0, position: p, payload: payload)
                    builder.append(leafHash: h)
                    hashes.append(h)
                }
            }
            let input = UInt32(truncatingIfNeeded: p < job.promptTokens.count
                ? job.promptTokens[p] : job.generatedTokens[p - job.promptTokens.count])
            let served = TraceAuditLeaf.servedToken(
                position: p, promptTokenCount: job.promptTokens.count, generatedTokens: job.generatedTokens)
            let pair = TraceAuditLeaf.tokenPairPayload(input: input, served: served)
            tokens += pair
            let h = TraceAuditLeaf.hash(kind: .tokenPair, block: 0, position: p, payload: pair)
            builder.append(leafHash: h)
            hashes.append(h)
            try hashes.withUnsafeBytes { raw in
                guard Darwin.write(lhFD, raw.baseAddress!, raw.count) == raw.count else {
                    throw TraceAuditStoreError.io("write lh")
                }
            }
        }
        guard let root = builder.root() else { throw TraceAuditStoreError.notCommitted }
        try writePrivate(Data(tokens), to: dir.appendingPathComponent("\(job.key).tokens"))
        let meta: [String: Any] = [
            "schema": "macprovider.trace-audit-lab.meta.v1",
            "request_id": job.requestID,
            "blocks": job.blocks,
            "hidden_size": job.hidden,
            "positions": job.positions,
            "prompt_positions": job.promptTokens.count,
            "generated_tokens": job.generatedTokens.count,
            "leaf_count": builder.count,
            "activation_dtype": "float16",
            "root": root.map { String(format: "%02x", $0) }.joined(),
            "merkle": "rfc6962",
            "leaf_domain": "mp.trace.leaf.v1",
        ]
        try writePrivate(
            JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]),
            to: dir.appendingPathComponent("\(job.key).meta.json")
        )
        return .root(root, positions: job.positions, leaves: builder.count)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TraceAuditStoreError.io("open \(url.lastPathComponent)") }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            guard raw.count == 0 || Darwin.write(fd, raw.baseAddress!, raw.count) == raw.count else {
                throw TraceAuditStoreError.io("write \(url.lastPathComponent)")
            }
        }
    }
}

// MARK: - Draws (SPEC-036 FR-29 step 3)

/// x_i = SHA-256("mp.trace.draw.v1\0" || root || nonce_1 || u32le i), read as a
/// 256-bit big-endian integer. A draw from a range of size m rejects x_i while
/// x_i >= m * floor(2^256 / m) and returns x_i mod m.
public struct TraceAuditDrawStream {
    public static let domain: [UInt8] = Array("mp.trace.draw.v1".utf8) + [0]
    private let prefix: Data
    public private(set) var next: UInt32 = 0

    public init(root: Data, nonce: Data, domain: [UInt8] = TraceAuditDrawStream.domain) {
        self.prefix = Data(domain) + root + nonce
    }

    public mutating func rawDraw() -> [UInt8] {
        var hasher = SHA256()
        hasher.update(data: prefix)
        var i = next
        withUnsafeBytes(of: &i) { raw in
            let le = [raw[0], raw[1], raw[2], raw[3]]
            hasher.update(data: le)
        }
        next += 1
        return Array(hasher.finalize())
    }

    /// Uniform value in 0 ..< m (m >= 1).
    public mutating func draw(below m: Int) -> Int {
        precondition(m >= 1)
        let mu = UInt64(m)
        // 2^256 mod m, from 2^64 mod m applied four times.
        let r64 = (UInt64.max % mu &+ 1) % mu
        var rem: UInt64 = 1 % mu
        for _ in 0 ..< 4 { rem = Self.mulmod(rem, r64, mu) }
        while true {
            let x = rawDraw()
            // threshold = 2^256 - rem; reject x >= threshold.
            if rem != 0 && x[0 ..< 24].allSatisfy({ $0 == 0xFF }) {
                let low = x[24 ..< 32].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                if low > UInt64.max - rem { continue }
            }
            var acc: UInt64 = 0
            for byte in x {
                acc = Self.mulmod(acc, 256, mu)
                acc = (acc + UInt64(byte) % mu) % mu
            }
            return Int(acc)
        }
    }

    static func mulmod(_ a: UInt64, _ b: UInt64, _ m: UInt64) -> UInt64 {
        let product = a.multipliedFullWidth(by: b)
        return m.dividingFullWidth((product.high % m, product.low)).remainder
    }
}

public struct TraceAuditPoint: Sendable, Equatable, Hashable {
    public let block: Int
    public let position: Int

    public init(block: Int, position: Int) {
        self.block = block
        self.position = position
    }
}

public struct TraceAuditChallengePoints: Sendable, Equatable {
    public let blockPoints: [TraceAuditPoint]
    public let promptPoint: TraceAuditPoint
    /// Positions whose served token is bound by output points.
    public let outputPositions: [Int]

    public init(blockPoints: [TraceAuditPoint], promptPoint: TraceAuditPoint, outputPositions: [Int]) {
        self.blockPoints = blockPoints
        self.promptPoint = promptPoint
        self.outputPositions = outputPositions
    }

    /// FR-29 step 3 order: min(k, L * N) block points (redraw duplicates of
    /// earlier block points), one block-0 point over the prompt positions (it
    /// may coincide with a block point), then min(k, n) output points without
    /// repeats over the n emitting positions P-1 ..< N.
    public static func draw(
        root: Data, nonce: Data, blocks: Int, positions: Int, promptPositions: Int,
        blockPoints: Int = 2, outputPoints: Int = 2
    ) -> TraceAuditChallengePoints {
        var stream = TraceAuditDrawStream(root: root, nonce: nonce)
        var points: [TraceAuditPoint] = []
        let wantBlock = min(blockPoints, blocks * positions)
        while points.count < wantBlock {
            let v = stream.draw(below: blocks * positions)
            let point = TraceAuditPoint(block: v / positions, position: v % positions)
            if !points.contains(point) { points.append(point) }
        }
        let prompt = TraceAuditPoint(block: 0, position: stream.draw(below: promptPositions))
        let firstGenerated = promptPositions - 1
        let generated = positions - firstGenerated
        var outputs: [Int] = []
        let wantOutput = min(outputPoints, max(0, generated))
        while outputs.count < wantOutput {
            let p = firstGenerated + stream.draw(below: generated)
            if !outputs.contains(p) { outputs.append(p) }
        }
        return TraceAuditChallengePoints(blockPoints: points, promptPoint: prompt, outputPositions: outputs)
    }
}
