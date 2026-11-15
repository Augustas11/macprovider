import Foundation

public enum SupportedModelsValidationError: Error, CustomStringConvertible, Equatable {
    case modelMissing
    case modelNotInCatalog(model: String, catalog: [String])
    case entryTooLong(entry: String, byteCount: Int)
    case catalogTooLarge(count: Int)
    case warmModelsRequireModel
    case warmModelNotInCatalog(model: String, catalog: [String])

    public var description: String {
        switch self {
        case .modelMissing:
            return "--supported-models requires --model to be set"
        case let .modelNotInCatalog(model, _):
            return "--model \(model) not in --supported-models"
        case let .entryTooLong(entry, byteCount):
            return "--supported-models entry exceeds 256 UTF-8 bytes: \(entry) (\(byteCount) bytes)"
        case let .catalogTooLarge(count):
            return "--supported-models exceeds 64 entries (got \(count))"
        case .warmModelsRequireModel:
            return "--warm-models requires --model to be set"
        case let .warmModelNotInCatalog(model, _):
            return "--warm-models \(model) not in --supported-models"
        }
    }
}

public enum SupportedModels {
    public static let maxEntryByteLength = 256
    public static let maxCatalogEntries = 64

    /// The SPEC-010 fold of a model id: Unicode NFC, then lowercase. The one
    /// comparison key for model ids in config validation, the warm-set table,
    /// the wire and request routing; the coordinator folds the same way.
    public static func foldedModelID(_ modelID: String) -> String {
        modelID.precomposedStringWithCanonicalMapping.lowercased(with: nil)
    }

    public static func parseCSV(_ raw: String?) -> [String]? {
        guard let raw else {
            return nil
        }
        let entries = raw
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return entries.isEmpty ? nil : entries
    }

    /// SPEC-001-R017: every warm model must be in the catalog; with no
    /// catalog the effective one is the primary followed by `warmModels`.
    public static func validate(
        model: String,
        supportedModels: [String]?,
        warmModels: [String] = []
    ) throws -> [String] {
        guard !model.isEmpty else {
            throw warmModels.isEmpty
                ? SupportedModelsValidationError.modelMissing
                : SupportedModelsValidationError.warmModelsRequireModel
        }

        var catalog = supportedModels?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard !catalog.isEmpty || !warmModels.isEmpty else {
            return [model]
        }
        if catalog.isEmpty {
            catalog = [model] + warmModels
        }

        for entry in catalog {
            let byteCount = entry.utf8.count
            if byteCount > maxEntryByteLength {
                throw SupportedModelsValidationError.entryTooLong(entry: entry, byteCount: byteCount)
            }
        }

        if catalog.count > maxCatalogEntries {
            throw SupportedModelsValidationError.catalogTooLarge(count: catalog.count)
        }

        let foldedModel = foldedModelID(model)
        let containsModel = catalog.contains { entry in
            foldedModelID(entry) == foldedModel
        }
        guard containsModel else {
            throw SupportedModelsValidationError.modelNotInCatalog(model: model, catalog: catalog)
        }
        let foldedCatalog = Set(catalog.map(foldedModelID))
        if let missing = warmModels.first(where: { !foldedCatalog.contains(foldedModelID($0)) }) {
            throw SupportedModelsValidationError.warmModelNotInCatalog(model: missing, catalog: catalog)
        }

        return catalog
    }
}
