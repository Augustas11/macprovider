import CryptoKit
import Foundation

/// SPEC-018-R011 (v0.3.22, #2467): the reasoning of Inkling 2 assistant turns
/// this provider generated, so a later request whose client dropped that
/// reasoning renders the history the model wrote.
///
/// Inkling 2's template replays every earlier assistant turn's reasoning. A
/// client that keeps only `content` and `tool_calls` then shows the model a
/// history it never wrote, and the prompt no longer matches the conversation
/// cache past that turn. Other families keep their own history handling
/// (SPEC-018-R008); the runtime records and restores only for `.inkling2`.
///
/// - Scope: one entry per generated turn, keyed by the request model, the
///   conversation key, the conversation before the turn and the turn's own
///   content and calls. Requests without a conversation key are neither
///   recorded nor restored, so one buyer's reasoning can never reach another
///   buyer's prompt (conversation keys are account-scoped).
/// - Key text: reasoning and tool-call IDs are left out (clients drop or
///   rewrite them); assistant content is compared trimmed and a null content
///   equals ""; call arguments compare as canonical JSON (sorted keys), so a
///   client that re-encodes them still matches.
/// - Value: the turn's reasoning as one string. The reasoning split joins the
///   bodies of several thinking frames without a separator, so a turn the
///   model wrote as two or more thinking frames is restored as one frame.
/// - Bounds: entry count, total bytes, a per-conversation share of the total
///   bytes, a per-entry reasoning cap, a per-request restore cap and an idle
///   TTL, with least-recently-used eviction in amortized constant time.
///   Memory only; nothing is persisted, logged or sent anywhere.
/// - Purges: `purge(conversationKey:)` and `removeAll()` drop the entries and
///   advance a per-key generation or the global epoch. A turn records only
///   under the `Fence` its request saw when it was rendered, so a turn whose
///   request rendered before a purge never writes after it.
public final class AssistantReasoningHistory: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        public var maxEntries: Int
        /// Sum of the stored reasoning UTF-8 bytes plus `entryOverheadBytes`
        /// per entry.
        public var maxBytes: Int
        /// A turn whose reasoning has more UTF-8 bytes is not stored.
        public var maxEntryBytes: Int
        /// UTF-8 bytes of reasoning one request gets back, newest turns first.
        public var maxRestoreBytes: Int
        public var ttlSeconds: TimeInterval

        public init(
            maxEntries: Int, maxBytes: Int, maxEntryBytes: Int,
            maxRestoreBytes: Int = 256 << 10, ttlSeconds: TimeInterval
        ) {
            self.maxEntries = max(0, maxEntries)
            self.maxBytes = max(0, maxBytes)
            self.maxEntryBytes = max(0, maxEntryBytes)
            self.maxRestoreBytes = max(0, maxRestoreBytes)
            self.ttlSeconds = ttlSeconds.isNaN ? 0 : max(0, ttlSeconds)
        }

        /// The bytes one conversation key may hold: an eighth of the total,
        /// so one conversation never evicts every other one.
        public var maxConversationBytes: Int { maxBytes / 8 }

        /// 4096 turns, 32 MiB (4 MiB per conversation), 1 MiB of reasoning
        /// per turn, 256 KiB restored per request, 72 h idle (the
        /// conversation cache's default TTL).
        public static let standard = Limits(
            maxEntries: 4096, maxBytes: 32 << 20, maxEntryBytes: 1 << 20,
            maxRestoreBytes: 256 << 10, ttlSeconds: 72 * 3600)
    }

    public struct Restore: Sendable {
        public let messages: [ChatMessage]
        /// Assistant turns that got reasoning back.
        public let turns: Int
        /// UTF-8 bytes of the reasoning put back.
        public let bytes: Int
    }

    /// The purge state a request saw when it was rendered.
    public struct Fence: Sendable, Equatable {
        fileprivate let epoch: UInt64
        fileprivate let generation: UInt64
    }

    /// Key bytes and bookkeeping charged per entry.
    public static let entryOverheadBytes = 128
    /// Conversation keys whose purge generation is tracked; past it the
    /// table is cleared and the epoch advances, which fences every key.
    static let maxTrackedPurges = 65_536

    private struct Entry {
        let reasoning: String
        /// `H(conversation key)`: the conversation the entry belongs to.
        let conversation: SHA256.Digest
        let bytes: Int
        var lastUse: UInt64
        var usedAt: Date
    }

    /// One use of an entry, oldest first. A ticket whose tick is not the
    /// entry's `lastUse` is stale and skipped.
    private struct Ticket {
        let tick: UInt64
        let key: SHA256.Digest
    }

    private struct TicketQueue {
        private var items: [Ticket] = []
        private var head = 0

        var pending: Int { items.count - head }

        var first: Ticket? { head < items.count ? items[head] : nil }

        mutating func append(_ ticket: Ticket) {
            items.append(ticket)
        }

        mutating func dropFirst() {
            head += 1
            if head >= 64, head * 2 >= items.count {
                items.removeFirst(head)
                head = 0
            }
        }

        mutating func reset(_ tickets: [Ticket]) {
            items = tickets
            head = 0
        }
    }

    private struct Conversation {
        var bytes = 0
        var members: Set<SHA256.Digest> = []
        var queue = TicketQueue()
    }

    private let lock = NSLock()
    private let limits: Limits
    private let now: @Sendable () -> Date
    private var entries: [SHA256.Digest: Entry] = [:]
    private var conversations: [SHA256.Digest: Conversation] = [:]
    private var queue = TicketQueue()
    private var totalBytes = 0
    private var tick: UInt64 = 0
    private var epoch: UInt64 = 0
    private var purgeGenerations: [SHA256.Digest: UInt64] = [:]

    public init(limits: Limits = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.now = now
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    /// Bytes held for one conversation key, across models.
    func conversationByteCount(conversationKey: String) -> Int {
        let key = Self.normalizedKey(conversationKey)
        let digest = SHA256.hash(data: Data(key.utf8))
        lock.lock()
        defer { lock.unlock() }
        return conversations[digest]?.bytes ?? 0
    }

    /// The purge state now, for a request about to render. A request without
    /// a conversation key gets the epoch alone (it never records).
    public func fence(conversationKey: String?) -> Fence {
        var digest: SHA256.Digest?
        if let conversationKey {
            let key = Self.normalizedKey(conversationKey)
            if !key.isEmpty { digest = SHA256.hash(data: Data(key.utf8)) }
        }
        lock.lock()
        defer { lock.unlock() }
        return Fence(epoch: epoch, generation: digest.flatMap { purgeGenerations[$0] } ?? 0)
    }

    /// Stores the reasoning of a turn generated for a request whose messages
    /// were `prefix`. No-op without reasoning or a conversation key, or when
    /// the key was purged (or everything removed) since `fence`.
    public func record(
        model: String,
        conversationKey: String?,
        prefix: [ChatMessage],
        content: String?,
        toolCalls: [ToolCall]?,
        reasoning: String?,
        fence: Fence
    ) {
        guard let reasoning, !reasoning.isEmpty,
              let scope = Self.scope(model: model, conversationKey: conversationKey) else { return }
        let reasoningBytes = reasoning.utf8.count
        let bytes = reasoningBytes + Self.entryOverheadBytes
        guard limits.maxEntries > 0, reasoningBytes <= limits.maxEntryBytes,
              bytes <= limits.maxConversationBytes, bytes <= limits.maxBytes else { return }
        var hasher = SHA256()
        for message in prefix { Self.feed(&hasher, message) }
        let key = Self.turnKey(scope: scope.digest, prefix: hasher.finalize(),
                               content: content, toolCalls: toolCalls)
        let at = now()
        lock.lock()
        defer { lock.unlock() }
        guard fence.epoch == epoch,
              fence.generation == purgeGenerations[scope.keyDigest] ?? 0 else { return }
        sweepExpired(at: at)
        if entries[key] != nil { remove(key) }
        tick += 1
        entries[key] = Entry(reasoning: reasoning, conversation: scope.keyDigest, bytes: bytes, lastUse: tick, usedAt: at)
        totalBytes += bytes
        var conversation = conversations.removeValue(forKey: scope.keyDigest) ?? Conversation()
        conversation.bytes += bytes
        conversation.members.insert(key)
        conversation.queue.append(Ticket(tick: tick, key: key))
        conversations[scope.keyDigest] = conversation
        queue.append(Ticket(tick: tick, key: key))
        compactQueues(conversation: scope.keyDigest)
        // The new entry is the conversation's newest and fits its share, so
        // eviction stops before it.
        while (conversations[scope.keyDigest]?.bytes ?? 0) > limits.maxConversationBytes,
              let oldest = oldestInConversation(scope.keyDigest) {
            remove(oldest)
        }
        while entries.count > limits.maxEntries || totalBytes > limits.maxBytes,
              let oldest = Self.oldestLive(&queue, entries: entries) {
            remove(oldest)
        }
    }

    /// `messages` with recorded reasoning put back on assistant turns that
    /// arrived without any, or nil when no turn was restored. Newest turns
    /// are restored first; the first turn that would take the request past
    /// `maxRestoreBytes` ends the restore, so older turns stay as sent.
    public func restoring(_ messages: [ChatMessage], model: String, conversationKey: String?) -> Restore? {
        guard messages.contains(where: Self.lacksReasoning),
              let scope = Self.scope(model: model, conversationKey: conversationKey)?.digest else { return nil }
        lock.lock()
        let empty = entries.isEmpty
        lock.unlock()
        if empty { return nil }

        // Hash outside the lock: one pass, the prefix digest of turn i is
        // the hash of messages[0..<i].
        var candidates: [(index: Int, key: SHA256.Digest)] = []
        var hasher = SHA256()
        for (index, message) in messages.enumerated() {
            if Self.lacksReasoning(message) {
                let prefix = hasher
                candidates.append((index, Self.turnKey(scope: scope, prefix: prefix.finalize(),
                                                       content: message.content, toolCalls: message.toolCalls)))
            }
            Self.feed(&hasher, message)
        }

        let at = now()
        var restored = messages
        var turns = 0
        var bytes = 0
        lock.lock()
        defer { lock.unlock() }
        for candidate in candidates.reversed() {
            guard let entry = entries[candidate.key] else { continue }
            if at.timeIntervalSince(entry.usedAt) > limits.ttlSeconds {
                remove(candidate.key)
                continue
            }
            let size = entry.reasoning.utf8.count
            if bytes + size > limits.maxRestoreBytes { break }
            touch(candidate.key, at: at)
            let message = messages[candidate.index]
            restored[candidate.index] = ChatMessage(
                role: .assistant, content: message.content, toolCallID: message.toolCallID,
                toolCalls: message.toolCalls, reasoningContent: entry.reasoning)
            turns += 1
            bytes += size
        }
        return turns == 0 ? nil : Restore(messages: restored, turns: turns, bytes: bytes)
    }

    /// Drops every entry of a conversation key, for every model, and fences
    /// out records of requests rendered before now.
    public func purge(conversationKey: String) {
        let key = Self.normalizedKey(conversationKey)
        guard !key.isEmpty else { return }
        let keyDigest = SHA256.hash(data: Data(key.utf8))
        lock.lock()
        defer { lock.unlock() }
        if purgeGenerations[keyDigest] == nil, purgeGenerations.count >= Self.maxTrackedPurges {
            purgeGenerations.removeAll()
            epoch &+= 1
        }
        purgeGenerations[keyDigest, default: 0] &+= 1
        for member in conversations[keyDigest]?.members ?? [] {
            remove(member)
        }
    }

    /// Drops every entry and fences out records of every request rendered
    /// before now.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        epoch &+= 1
        purgeGenerations.removeAll()
        entries.removeAll()
        conversations.removeAll()
        queue.reset([])
        totalBytes = 0
    }

    // MARK: - Bookkeeping (caller holds `lock`)

    private func remove(_ key: SHA256.Digest) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        guard var conversation = conversations.removeValue(forKey: entry.conversation) else { return }
        conversation.bytes -= entry.bytes
        conversation.members.remove(key)
        if !conversation.members.isEmpty {
            conversations[entry.conversation] = conversation
        }
    }

    private func touch(_ key: SHA256.Digest, at date: Date) {
        guard var entry = entries[key] else { return }
        tick += 1
        entry.lastUse = tick
        entry.usedAt = date
        entries[key] = entry
        queue.append(Ticket(tick: tick, key: key))
        conversations[entry.conversation]?.queue.append(Ticket(tick: tick, key: key))
        compactQueues(conversation: entry.conversation)
    }

    /// Rebuilds a queue once stale tickets outnumber live entries, so the
    /// queues stay linear in the entry count.
    private func compactQueues(conversation digest: SHA256.Digest) {
        if queue.pending > 2 * entries.count + 64 {
            queue.reset(Self.tickets(entries.keys, entries: entries))
        }
        if let conversation = conversations[digest],
           conversation.queue.pending > 2 * conversation.members.count + 16 {
            conversations[digest]?.queue.reset(Self.tickets(conversation.members, entries: entries))
        }
    }

    private static func tickets<Keys: Sequence>(_ keys: Keys, entries: [SHA256.Digest: Entry]) -> [Ticket]
        where Keys.Element == SHA256.Digest {
        keys.compactMap { key in entries[key].map { Ticket(tick: $0.lastUse, key: key) } }
            .sorted { $0.tick < $1.tick }
    }

    /// The least recently used live entry of `queue`; stale tickets ahead of
    /// it are dropped.
    private static func oldestLive(_ queue: inout TicketQueue, entries: [SHA256.Digest: Entry]) -> SHA256.Digest? {
        while let ticket = queue.first {
            if entries[ticket.key]?.lastUse == ticket.tick { return ticket.key }
            queue.dropFirst()
        }
        return nil
    }

    private func oldestInConversation(_ digest: SHA256.Digest) -> SHA256.Digest? {
        // Taken out of the table while it changes, so its queue is not copied.
        guard var conversation = conversations.removeValue(forKey: digest) else { return nil }
        let oldest = Self.oldestLive(&conversation.queue, entries: entries)
        conversations[digest] = conversation
        return oldest
    }

    /// Entries idle past the TTL, least recently used first.
    private func sweepExpired(at date: Date) {
        while let oldest = Self.oldestLive(&queue, entries: entries),
              let entry = entries[oldest],
              date.timeIntervalSince(entry.usedAt) > limits.ttlSeconds {
            remove(oldest)
        }
    }

    // MARK: - Keys

    private static func lacksReasoning(_ message: ChatMessage) -> Bool {
        message.role == .assistant && (message.reasoningContent ?? "").isEmpty
    }

    private static func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `H(key)` and the per-model scope `H(H(key) ‖ model)` of a
    /// conversation key; nil without a key. Keys compare trimmed, as the
    /// conversation cache keys them.
    private static func scope(model: String, conversationKey: String?) -> Scope? {
        guard let conversationKey else { return nil }
        let key = normalizedKey(conversationKey)
        guard !key.isEmpty else { return nil }
        let keyDigest = SHA256.hash(data: Data(key.utf8))
        var hasher = SHA256()
        hasher.update(data: Data(keyDigest))
        feed(&hasher, model)
        return Scope(keyDigest: keyDigest, digest: hasher.finalize())
    }

    private struct Scope {
        let keyDigest: SHA256.Digest
        let digest: SHA256.Digest
    }

    private static func turnKey(
        scope: SHA256.Digest, prefix: SHA256.Digest, content: String?, toolCalls: [ToolCall]?
    ) -> SHA256.Digest {
        var hasher = SHA256()
        hasher.update(data: Data(scope))
        hasher.update(data: Data(prefix))
        feed(&hasher, ChatMessage(role: .assistant, content: content, toolCalls: toolCalls))
        return hasher.finalize()
    }

    /// Length-prefixed fields of a message, without reasoning and IDs.
    private static func feed(_ hasher: inout SHA256, _ message: ChatMessage) {
        feed(&hasher, message.role.rawValue)
        let content = message.content ?? ""
        feed(&hasher, message.role == .assistant ? content.trimmingCharacters(in: .whitespacesAndNewlines) : content)
        let calls = message.toolCalls ?? []
        feed(&hasher, String(calls.count))
        for call in calls {
            feed(&hasher, call.functionName)
            feed(&hasher, canonicalArguments(call.arguments))
        }
    }

    private static func feed(_ hasher: inout SHA256, _ text: String) {
        let bytes = Data(text.utf8)
        withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: bytes)
    }

    static func canonicalArguments(_ arguments: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8), options: [.fragmentsAllowed]),
              let value = try? JSONValue.parse(object),
              let canonical = try? value.deterministicJSONString() else { return arguments }
        return canonical
    }
}

/// SPEC-018-R011: one request's use of the serving runtime's reasoning
/// history. `RequestOutputState` holds it, so every copy of the request and
/// every render of its prompt (preflight, thinking probe, serving) shares one
/// lookup: the store is read once per request, and serving renders the
/// restore the first render chose.
public final class ReasoningHistoryRequestState: @unchecked Sendable {
    private struct Lookup {
        let model: String
        let conversationKey: String?
        let messageCount: Int
        let restore: AssistantReasoningHistory.Restore?
        let fence: AssistantReasoningHistory.Fence
    }

    private let lock = NSLock()
    private var store: AssistantReasoningHistory?
    private var lookup: Lookup?
    private var withdrawn = false
    private var restoredTokens = 0
    private var restoredTokensClaimed = false
    private var reported = false

    public init() {}

    /// The store of the runtime serving the request.
    public func attach(_ store: AssistantReasoningHistory) {
        lock.lock()
        defer { lock.unlock() }
        guard self.store !== store else { return }
        self.store = store
        lookup = nil
        restoredTokens = 0
    }

    /// The restore for the request's messages: looked up (with the purge
    /// fence) on the first call and returned unchanged after. Nil without a
    /// store, once withdrawn, or when no turn was restored.
    public func restore(
        _ messages: [ChatMessage], model: String, conversationKey: String?
    ) -> AssistantReasoningHistory.Restore? {
        lock.lock()
        defer { lock.unlock() }
        guard let store, !withdrawn else { return nil }
        if let lookup, lookup.model == model, lookup.conversationKey == conversationKey,
           lookup.messageCount == messages.count {
            return lookup.restore
        }
        let fence = store.fence(conversationKey: conversationKey)
        let restore = store.restoring(messages, model: model, conversationKey: conversationKey)
        lookup = Lookup(model: model, conversationKey: conversationKey, messageCount: messages.count,
                        restore: restore, fence: fence)
        return restore
    }

    /// True while the request renders a restore.
    public var isRestoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !withdrawn && lookup?.restore != nil
    }

    /// The request renders as sent from now on (its restored prompt is over
    /// the context limit).
    public func withdraw() {
        lock.lock()
        defer { lock.unlock() }
        withdrawn = true
        restoredTokens = 0
    }

    public var isWithdrawn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return withdrawn
    }

    /// Prompt tokens the restore added; reported usage leaves them out.
    public var restoredPromptTokens: Int {
        lock.lock()
        defer { lock.unlock() }
        return restoredTokens
    }

    /// The restored prompt tokens to leave out of reported usage, once per
    /// request: a nested completion path that finishes the same request
    /// again gets zero, so usage is never reduced twice.
    public func claimRestoredPromptTokens() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if restoredTokensClaimed { return 0 }
        restoredTokensClaimed = true
        return restoredTokens
    }

    public func noteRestoredPromptTokens(_ tokens: Int) {
        lock.lock()
        defer { lock.unlock() }
        restoredTokens = withdrawn ? 0 : max(0, tokens)
    }

    /// True once per request, for the one log line.
    public func claimReport() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if reported { return false }
        reported = true
        return true
    }

    /// The store and the fence of the request's render, to record the turn
    /// it generated; nil when the request never looked the store up.
    public func recordTarget() -> (store: AssistantReasoningHistory, fence: AssistantReasoningHistory.Fence)? {
        lock.lock()
        defer { lock.unlock() }
        guard let store, let lookup else { return nil }
        return (store, lookup.fence)
    }
}
