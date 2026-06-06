import Foundation

public enum SupportedModelsValidationError: Error, CustomStringConvertible, Equatable {
    case modelMissing
    case modelNotInCatalog(model: String, catalog: [String])
    case entryTooLong(entry: String, byteCount: Int)
    case catalogTooLarge(count: Int)

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
        }
    }
}

public enum SupportedModels {
    public static let maxEntryByteLength = 256
    public static let maxCatalogEntries = 64

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

    public static func validate(
        model: String,
        supportedModels: [String]?
    ) throws -> [String] {
        guard !model.isEmpty else {
            throw SupportedModelsValidationError.modelMissing
        }

        let catalog = supportedModels?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard !catalog.isEmpty else {
            return [model]
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

        let foldedModel = model.lowercased(with: nil)
        let containsModel = catalog.contains { entry in
            entry.lowercased(with: nil) == foldedModel
        }
        guard containsModel else {
            throw SupportedModelsValidationError.modelNotInCatalog(model: model, catalog: catalog)
        }

        return catalog
    }
}
