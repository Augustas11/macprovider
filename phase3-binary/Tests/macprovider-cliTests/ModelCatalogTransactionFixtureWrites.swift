import Foundation
@testable import macprovider_cli

/// Explicit fixture construction, outside the production mutation API. Runtime
/// owners must use provenance-bearing receipts and the bound-success publisher.
extension ModelCatalogTransactionStore {
    // These compatibility queries belong to fixture inspection, not runtime
    // receipt capture. Do not include test assertions in public-path counters.
    func loadActiveIndexLocked() throws -> ModelTransactionActiveIndex {
        let directory = try retentionDirectory()
        var fixture = self; fixture.retentionBoundary = { _ in }
        return try fixture.decodeActiveIndex(directory.read("active.json", maxBytes: Self.indexLimit),
            format: directory.read("format.json", maxBytes: 4_096))
    }
    func activeSnapshotLocked() throws -> [String] { try loadActiveIndexLocked().entries.map(\.id) }
    func isActiveLocked(_ id: String) throws -> Bool {
        try loadActiveIndexLocked().entries.contains { $0.id == id && $0.phase == "active" }
    }
    func write(_ record: ModelCatalogTransactionRecord) throws {
        if let selector = record.selector {
            let index = try loadActiveIndexLocked()
            guard index.entries.contains(where: { $0.id == selector.transactionID && $0.phase == "active" }) else {
                throw ModelCatalogTransactionError.invalidTransaction
            }
            let current = try load(selector.transactionID, target: selector.target, cleanup: selector.kind == "cleanup_staging")
            guard current.selector == selector else { throw ModelCatalogTransactionError.invalidTransaction }
        }
        let suffix = record.kind == "cleanup_staging" ? ".cleanup" : ".json"
        try writePrivate(JSONEncoder().encode(record), to: root.appendingPathComponent(record.transactionID + suffix))
    }
}
