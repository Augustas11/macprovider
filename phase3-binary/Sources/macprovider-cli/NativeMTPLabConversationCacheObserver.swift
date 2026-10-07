#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation

final class NativeMTPLabConversationCacheObserver: @unchecked Sendable {
    static let eventSource = "native_mtp_lab_conversation_cache_observer_v1"

    struct Event: Equatable, Sendable {
        let eventSource: String
        let requestID: String?
        let monotonicNanoseconds: UInt64
        let surface: String
        let keyPresent: Bool
        let cacheOnly: Bool
        let leaseAllowed: Bool
        let leaseObserved: Bool
        let state: String
        let cachedTokens: Int
        let lcp: Int
        let trimBy: Int
        let retainedHandoff: Bool
        let usableRetainedHandoff: Bool
        let recurrentCheckpointCount: Int

        var payload: [String: Any] {
            [
                "event_source": eventSource,
                "record_type": "conversation_cache_begin",
                "request_id": requestID ?? NSNull(),
                "monotonic_nanoseconds": monotonicNanoseconds,
                "surface": surface,
                "conversation_key_present": keyPresent,
                "conversation_key_cache_only": cacheOnly,
                "conversation_cache_lease_allowed": leaseAllowed,
                "conversation_cache_lease_observed": leaseObserved,
                "conversation_cache_lease": state,
                "conversation_cache_cached_prompt_tokens": cachedTokens,
                "conversation_cache_lcp": lcp,
                "conversation_cache_trim_by": trimBy,
                "conversation_cache_retained_handoff": retainedHandoff,
                "conversation_cache_usable_retained_handoff": usableRetainedHandoff,
                "conversation_cache_recurrent_checkpoint_count": recurrentCheckpointCount,
            ]
        }
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    static func event(
        requestID: String?,
        surface: String,
        keyPresent: Bool,
        cacheOnly: Bool,
        leaseAllowed: Bool,
        lease: ConversationCacheLease?,
        modelHasRecurrentLayers: Bool,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Event {
        let leaseObserved = lease != nil
        let cachedTokens = lease?.cachedPromptTokens ?? 0
        let retainedHandoff = lease.map {
            $0.reusableCache?.retainedPagedKVSequence != nil || $0.recurrentCheckpoint != nil
        } ?? false
        let usableRetainedHandoff = lease.map {
            ModelRuntime.leaseHasUsableRetainedHandoff($0, modelHasRecurrentLayers: modelHasRecurrentLayers)
        } ?? false
        let state: String
        if keyPresent {
            if leaseObserved {
                state = cachedTokens > 0 || retainedHandoff ? "hit" : "miss"
            } else {
                state = leaseAllowed ? "missing" : "not_applicable"
            }
        } else {
            state = "not_applicable"
        }
        return Event(
            eventSource: eventSource,
            requestID: requestID,
            monotonicNanoseconds: monotonicNanoseconds,
            surface: surface,
            keyPresent: keyPresent,
            cacheOnly: keyPresent ? cacheOnly : false,
            leaseAllowed: leaseAllowed,
            leaseObserved: leaseObserved,
            state: state,
            cachedTokens: cachedTokens,
            lcp: lease?.lcp ?? 0,
            trimBy: lease?.trimBy ?? 0,
            retainedHandoff: retainedHandoff,
            usableRetainedHandoff: usableRetainedHandoff,
            recurrentCheckpointCount: lease?.reusableCache?.recurrentCheckpoints.count ?? 0
        )
    }
}
#endif
