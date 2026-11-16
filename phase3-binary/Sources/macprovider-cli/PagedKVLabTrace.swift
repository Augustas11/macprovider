#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MacProviderCore
import MLXLMCommon

/// Lab only (issue #2396). With `MACPROVIDER_LAB_PAGED_KV_TRACE=1`, every CB
/// row's paged-KV bookkeeping is logged at session build/shrink, window
/// commit, finish and the record guard, one `pkvtrace {json}` stderr line per
/// event. Request ids, counts and block ids only; never prompt or completion
/// content. Absent from release builds; off unless the variable is set.
enum PagedKVLabTrace {
    static let enabled = ProcessInfo.processInfo.environment["MACPROVIDER_LAB_PAGED_KV_TRACE"] == "1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var window = 0
    nonisolated(unsafe) private static var sequence = 0

    /// Starts a decode window (one `performDecode` call) and returns its number.
    static func beginWindow() -> Int {
        lock.lock()
        defer { lock.unlock() }
        window += 1
        return window
    }

    static func emit(_ event: String, _ fields: [String: Any]) {
        guard enabled else { return }
        lock.lock()
        sequence += 1
        var record = fields
        record["ev"] = event
        record["seq"] = sequence
        if record["window"] == nil { record["window"] = window }
        lock.unlock()
        record["t_ms"] = DispatchTime.now().uptimeNanoseconds / 1_000_000
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        var line = Data("pkvtrace ".utf8)
        line.append(data)
        line.append(0x0A)
        try? FileHandle.standardError.write(contentsOf: line)
    }

    static func table(_ table: PagedKVBlockTable) -> [String: Any] {
        let blocks = table.physicalBlocks
        var fields: [String: Any] = [
            "logical": table.logicalTokenCount,
            "tail_valid": table.tailValidTokenCount,
            "block_size": table.blockSizeTokens,
            "blocks_len": blocks.count,
            "blocks_first": blocks.first ?? -1,
            "blocks_last": blocks.last ?? -1,
            // FNV-1a over the ids: equal hashes mean an unchanged table.
            "blocks_hash": String(format: "%016llx", blocks.reduce(UInt64(0xcbf2_9ce4_8422_2325)) {
                ($0 ^ UInt64(bitPattern: Int64($1))) &* 0x0000_0100_0000_01B3
            }),
        ]
        if blocks.count <= 64 { fields["blocks"] = blocks }
        return fields
    }

    /// One row: layer-0 values plus whether every paged layer agrees with them.
    static func row(
        requestID: String,
        index: Int?,
        caches: [KVCache],
        binding: PagedKVStorageBinding?
    ) -> [String: Any] {
        let paged = caches.compactMap { $0 as? PagedKVCache }
        var fields: [String: Any] = ["rid": requestID, "paged_layers": paged.count]
        if let index { fields["row"] = index }
        if let binding {
            fields["handle"] = String(binding.handle.handleID.uuidString.prefix(8))
            fields["row_generation"] = binding.rowGeneration
            fields["table"] = table(binding.currentTable)
        }
        guard let first = paged.first else { return fields }
        let slot = first.labBatchSlot
        fields["offset"] = first.offset
        fields["stored"] = first.storedTokens
        fields["stored_blocks"] = PagedKVBlockLayout.blockCount(tokens: first.storedTokens, blockSizeTokens: first.blockSizeTokens)
        fields["capacity"] = first.bufferCapacityTokens
        fields["mutations"] = first.mutationCount
        fields["attached"] = slot != nil
        fields["batch_row"] = slot?.row ?? -1
        fields["row_storage"] = slot.map { String(UInt(bitPattern: $0.storage.hashValue), radix: 16) } ?? ""
        let agree = paged.allSatisfy {
            $0.offset == first.offset && $0.storedTokens == first.storedTokens
                && $0.labBatchSlot?.row == slot?.row && $0.labBatchSlot?.storage == slot?.storage
        }
        fields["layers_agree"] = agree
        if !agree {
            fields["offset_by_layer"] = paged.map(\.offset)
            fields["stored_by_layer"] = paged.map(\.storedTokens)
            fields["batch_row_by_layer"] = paged.map { $0.labBatchSlot?.row ?? -1 }
        }
        return fields
    }
}
#endif
