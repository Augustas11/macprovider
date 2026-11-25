import Foundation

/// SPEC-044-R015 model facts: a catalog model's declared context window and
/// the network capabilities Malibu shows as row badges.
///
/// The source is `phase3-binary/catalog/autotune/model-facts.json`, embedded
/// verbatim by `scripts/model-facts.py` (`ModelFacts.generated.swift`). It is
/// separate from the candidate catalog because that feed's row schema is
/// closed in every released CLI. A facts row applies only while its
/// `model_id` and `model_revision` equal the selected candidate catalog row,
/// so a catalog row whose artifact changed shows no facts rather than stale
/// ones.
struct ModelFacts: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let modelID: String
        let modelRevision: String
        let contextLength: Int
        let capabilities: [String]
    }

    static let schemaVersion = "macprovider.model-facts.v1"
    /// Closed, sorted capability values (SPEC-044-R015).
    static let capabilityValues = ["reasoning", "tools", "vision"]
    static let contextLengthRange = 1_024...16_777_216

    let rows: [String: Row]

    /// The embedded facts. A malformed copy yields no facts, never a failed
    /// projection: facts are display-only.
    static let baked: ModelFacts = (try? decode(Data(bakedJSON.utf8))) ?? ModelFacts(rows: [:])

    enum DecodeError: Error, Equatable {
        case invalid(String)
    }

    static func decode(_ data: Data) throws -> ModelFacts {
        try AutotuneStrictJSON.rejectDuplicateKeys(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schema_version", "rows"],
              root["schema_version"] as? String == schemaVersion,
              let rawRows = root["rows"] as? [String: Any]
        else {
            throw DecodeError.invalid("model facts envelope")
        }
        let rowKeys: Set<String> = ["capabilities", "context_length", "context_length_source", "model_id", "model_revision"]
        var rows: [String: Row] = [:]
        for (key, rawRow) in rawRows {
            guard let row = rawRow as? [String: Any], Set(row.keys) == rowKeys,
                  let modelID = row["model_id"] as? String, !modelID.isEmpty,
                  let modelRevision = row["model_revision"] as? String, !modelRevision.isEmpty,
                  row["context_length_source"] is String,
                  let lengthNumber = row["context_length"] as? NSNumber,
                  CFGetTypeID(lengthNumber) != CFBooleanGetTypeID(),
                  let contextLength = Int(exactly: lengthNumber.doubleValue),
                  Double(contextLength) == lengthNumber.doubleValue,
                  contextLengthRange.contains(contextLength),
                  let capabilities = row["capabilities"] as? [String],
                  capabilities == Array(Set(capabilities)).sorted(),
                  Set(capabilities).isSubset(of: capabilityValues)
            else {
                throw DecodeError.invalid("model facts row \(key)")
            }
            rows[key] = Row(
                modelID: modelID,
                modelRevision: modelRevision,
                contextLength: contextLength,
                capabilities: capabilities
            )
        }
        return ModelFacts(rows: rows)
    }

    /// The facts for a signed catalog key, only when bound to the selected
    /// catalog row by model id and revision.
    func row(forCatalogKey key: String, catalog: CandidateCatalog) -> Row? {
        guard let catalogKey = Self.matchingKey(key, in: catalog),
              let catalogRow = catalog.rows[catalogKey],
              let facts = rows[catalogKey],
              facts.modelID == catalogRow.modelID,
              facts.modelRevision == catalogRow.modelRevision
        else {
            return nil
        }
        return facts
    }

    private static func matchingKey(_ key: String, in catalog: CandidateCatalog) -> String? {
        if catalog.rows[key] != nil { return key }
        let lowered = key.lowercased()
        let matches = catalog.rows.keys.filter { $0.lowercased() == lowered }
        return matches.count == 1 ? matches.first : nil
    }
}

extension ModelCatalogEconomicsWire {
    /// SPEC-044-R015: the projection with `context_length` and `capabilities`
    /// on every row. Only `models catalog-economics --model-facts` emits them;
    /// without the flag the v1 envelope is byte-for-byte unchanged, so a
    /// Malibu build with the closed v1 row decoder keeps working.
    func withModelFacts(_ facts: ModelFacts, catalog: CandidateCatalog) -> ModelCatalogEconomicsWire {
        let rows = rows.map { row -> Row in
            var copy = row
            let bound = facts.row(forCatalogKey: row.modelKey, catalog: catalog)
            copy.modelFacts = ModelFactsWire(
                contextLength: bound?.contextLength,
                capabilities: bound?.capabilities ?? []
            )
            return copy
        }
        return ModelCatalogEconomicsWire(
            generatedAt: generatedAt,
            projectionSequence: projectionSequence,
            source: source,
            rows: rows,
            warnings: warnings
        )
    }
}

/// The two SPEC-044-R015 row fields: nullable `context_length` and a sorted
/// `capabilities` array, empty when the row has no bound facts.
struct ModelFactsWire: Equatable, Sendable {
    let contextLength: Int?
    let capabilities: [String]
}
