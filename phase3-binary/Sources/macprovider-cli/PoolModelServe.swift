import Foundation
import MacProviderCore

/// #1816: serving a model a Trusted Pool creator signed into the pool
/// manifest (SPEC-042-R015) under its `pool/<pool_id>/<slug>` id.
///
/// The configured `pool_model_id` does two local things and nothing else:
/// it is accepted as a request alias, so pool-route requests naming the
/// entry reach the runtime, and it lets a native MLX model with no signed
/// catalog row connect after its own artifact hash verifies, so the
/// coordinator can match that hash against the pool entry. It is never a
/// catalog identity: the hello keeps the served model id, receipts still
/// bind the coordinator's expected artifact hash, and the coordinator alone
/// decides membership, binding, and routing. Without it, global behaviour
/// is unchanged.
enum PoolModelServe {
    enum ConfigError: Error, Equatable, CustomStringConvertible {
        case invalidPoolModelID
        case conflictsWithCatalogIdentity

        var description: String {
            switch self {
            case .invalidPoolModelID:
                return "pool_model_id must be pool/<22-character pool id>/<slug> as signed in the pool manifest"
            case .conflictsWithCatalogIdentity:
                return "pool_model_id serves an uncatalogued pool entry; remove model_catalog_key and model_catalog_model_id, or remove pool_model_id to serve the catalog row"
            }
        }
    }

    /// The validated `pool_model_id`, nil when none is configured.
    static func validatedPoolModelID(_ config: AppConfig) throws -> String? {
        guard let raw = config.poolModelID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard raw.utf8.count <= 91,
              raw.range(of: BYOMAdmissionStatusWire.poolModelIDPattern, options: .regularExpression) != nil else {
            throw ConfigError.invalidPoolModelID
        }
        let hasCatalogIdentity = [config.modelCatalogKey, config.modelCatalogModelID].contains { value in
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard !hasCatalogIdentity else {
            throw ConfigError.conflictsWithCatalogIdentity
        }
        return raw
    }

    /// The single request alias serve accepts besides the served model id:
    /// the catalog id when one is configured, else the pool model id.
    static func requestAlias(catalogModelID: String?, poolModelID: String?) -> String? {
        let catalog = catalogModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let catalog, !catalog.isEmpty { return catalog }
        let pool = poolModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pool, !pool.isEmpty { return pool }
        return nil
    }
}
