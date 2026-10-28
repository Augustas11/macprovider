@testable import macprovider_cli

// Cache behavior fixtures need stable headroom even on busy, low-memory CI
// runners. Memory-pressure tests pass their own bounded or unavailable probe.
func conversationCacheTestMemoryBudget() -> ConversationCacheMemoryBudget {
    ConversationCacheMemoryBudget(probe: .init(identity: "conversation-cache-fixture") {
        let gib = 1024 * 1024 * 1024
        return NativeMTPRoundSystemMemorySample(availableBytes: 48 * gib, physicalBytes: 64 * gib)
    })
}

func makeConversationCacheForTest(
    config: ConversationCache.Config = .fromEnvironment(),
    coldTier: (any ConversationColdTier)? = nil,
    memoryBudget: ConversationCacheMemoryBudget = conversationCacheTestMemoryBudget()
) -> ConversationCache {
    ConversationCache(config: config, coldTier: coldTier, memoryBudget: memoryBudget)
}
