import Foundation

/// Exact names from a single verified catalog row, never billing normalization.
enum RelayBlindCatalogModels {
    static func groups(_ models: [String]) -> [[String]] {
        Array(Set(models.map { names($0).sorted() }))
            .sorted { $0.lexicographicallyPrecedes($1) }
    }

    private static let signedNames: [String: [String]] = {
        guard let catalog = try? AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(
            Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        ) else { return [:] }
        var result: [String: [String]] = [:]
        for (key, row) in catalog.rows {
            for name in [key, row.modelID] {
                result[name] = names(name, catalog: catalog)
            }
        }
        return result
    }()

    static func names(_ value: String) -> [String] {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return [] }
        return signedNames[model] ?? [model]
    }

    static func names(_ value: String, catalog: CandidateCatalog?) -> [String] {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return [] }
        guard let catalog else { return [model] }
        let matches = catalog.rows.filter { $0.key == model || $0.value.modelID == model }
        guard matches.count == 1, let entry = matches.first,
              let revision = entry.value.modelRevision,
              revision.count == 40,
              revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              let hash = entry.value.modelSHA256,
              hash.count == 64,
              hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else { return [model] }
        let names = [entry.key, entry.value.modelID]
        guard names.allSatisfy({ name in
            catalog.rows.filter { $0.key == name || $0.value.modelID == name }.count == 1
        }) else { return [model] }
        // The existing advertised name stays first: callers use it as the
        // coordinator's provider-model identity, distinct from buyer aliases.
        var result = [model]
        for name in names where !result.contains(name) {
            result.append(name)
        }
        return result
    }
}
