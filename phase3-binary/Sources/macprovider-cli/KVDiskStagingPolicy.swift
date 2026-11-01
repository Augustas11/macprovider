import Foundation

/// One read/restore share and one aggregate write share are reserved independently
/// by ConversationCacheMemoryBudget. Explicit operator ceilings may only lower
/// their share. A missing measurement never authorizes adaptive allocation.
enum KVDiskStagingPolicy {
    static let adaptiveHardMax = 4 * 1024 * 1024 * 1024

    static func limit(configured: Int, adaptive: Bool, measured: Int?) -> Int {
        let ceiling = adaptive ? adaptiveHardMax : min(1 << 30, max(0, configured))
        guard let measured else { return adaptive ? 0 : ceiling }
        return min(ceiling, max(0, measured))
    }
}
