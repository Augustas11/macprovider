import Foundation
import MacProviderCore

/// One request's hold on the warm member that serves it (SPEC-001-R016), as
/// `HTTPServer` and `InferenceRelay` see it. Taken before the runtime's
/// request handle and released at the request's terminal point; `release()`
/// is idempotent and a lease dropped without it is released when freed.
final class WarmServingLease: @unchecked Sendable {
    /// The member's table id.
    let modelID: String
    /// The member was the primary when the lease was taken.
    let primary: Bool
    let runtime: any ModelRuntimeServing
    /// The `ProviderStatus` key the request is counted under
    /// (`WarmModelTable.memberKey`), for the primary too: a promotion moves
    /// the primary role, never a request's member.
    let memberKey: String
    private let onRelease: @Sendable () -> Void

    init(
        modelID: String, primary: Bool, runtime: any ModelRuntimeServing, memberKey: String,
        onRelease: @escaping @Sendable () -> Void
    ) {
        self.modelID = modelID
        self.primary = primary
        self.runtime = runtime
        self.memberKey = memberKey
        self.onRelease = onRelease
    }

    func release() { onRelease() }

    /// Whether the request runs on `boot`, the runtime the process started
    /// with, which keeps serving under its boot identity (configured id,
    /// catalog alias, swap-aware validation) whether or not it is still the
    /// primary. Any other member serves under its own id.
    func runsOn(_ boot: any ModelRuntimeServing) -> Bool { runtime === boot }
}

/// The routing face of a warm set, free of the table's runtime type.
protocol WarmModelRouting: AnyObject, Sendable {
    /// R016 `served_model_id` routing; throws `WarmModelTableError.notLoaded`.
    func servingLease(servedModelID: String?) throws -> WarmServingLease
    /// R016 loopback local routing by the body `model`, else the primary.
    func servingLeaseLocal(bodyModel: String?) throws -> WarmServingLease
    /// The member views, readable without awaiting.
    var views: WarmModelViewCell { get }
    /// The current primary's runtime (SPEC-011 R-3.10.3 moves it): what the
    /// top-level status, handshake and heartbeat fields describe.
    func primaryServingRuntime() -> (any ModelRuntimeServing)?
    /// The runtime of the member `memberKey` names. The wire reads the
    /// primary's runtime through the member key the provider status holds,
    /// so the top-level fields and `warm_models` agree on the primary at
    /// every instant of a promotion.
    func servingRuntime(memberKey: String) -> (any ModelRuntimeServing)?
}

extension WarmModelTable: WarmModelRouting where Runtime: ModelRuntimeServing {
    func servingLease(servedModelID: String?) throws -> WarmServingLease {
        Self.serving(try lease(servedModelID: servedModelID))
    }

    func servingLeaseLocal(bodyModel: String?) throws -> WarmServingLease {
        Self.serving(try leaseLocal(bodyModel: bodyModel))
    }

    func primaryServingRuntime() -> (any ModelRuntimeServing)? { primaryRuntime() }

    func servingRuntime(memberKey: String) -> (any ModelRuntimeServing)? { runtime(memberKey: memberKey) }

    private static func serving(_ lease: WarmModelLease<Runtime>) -> WarmServingLease {
        WarmServingLease(
            modelID: lease.modelID, primary: lease.primary, runtime: lease.runtime,
            memberKey: memberKey(token: lease.token)
        ) { lease.release() }
    }
}

enum WarmModelRoute {
    /// `X-MacProvider-Served-Model`: the HTTP-forwarded `served_model_id`.
    static let servedModelHeaderName = "X-MacProvider-Served-Model"

    /// R016: the served id names no `warm` member. Nothing ran and nothing
    /// settles, so the coordinator may send the request elsewhere.
    static let notLoadedError = APIError(
        status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded", retryable: true
    )

    /// Leases the member a coordinator dispatch names. A blank id is absent
    /// (the primary). An id that is no member but names the primary as this
    /// provider advertises it outside the warm set (`primaryNames`: the boot
    /// model and its catalog alias) is the primary. Anything else not `warm`
    /// throws `notLoadedError`.
    static func lease(
        _ router: any WarmModelRouting,
        servedModelID: String?,
        primaryNames: [String?]
    ) throws -> WarmServingLease {
        let trimmed = servedModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let served = trimmed?.isEmpty == false ? trimmed : nil
        do {
            return try router.servingLease(servedModelID: served)
        } catch {
            guard let served, primaryNames.contains(where: { $0.map(key) == key(served) }) else {
                throw notLoadedError
            }
            do {
                return try router.servingLease(servedModelID: nil)
            } catch {
                throw notLoadedError
            }
        }
    }

    /// A loopback local request: the member named by the body `model`, else
    /// the primary.
    static func leaseLocal(_ router: any WarmModelRouting, bodyModel: String?) throws -> WarmServingLease {
        do {
            return try router.servingLeaseLocal(bodyModel: bodyModel)
        } catch {
            throw notLoadedError
        }
    }

    private static func key(_ modelID: String) -> String {
        SupportedModels.foldedModelID(modelID.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
