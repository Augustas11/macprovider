import CryptoKit
import Foundation

/// SPEC-018-R011 (v0.3.21, #2467): the reasoning of assistant turns this
/// provider generated, so a later request whose client dropped that
/// reasoning renders the same prompt as one that sent it back.
///
/// Templates such as Inkling 2's replay every earlier assistant turn's
/// reasoning. A client that keeps only `content` and `tool_calls` then shows
/// the model a history it never wrote, and the prompt no longer matches the
/// conversation cache past that turn.
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
/// - Bounds: entry count, total bytes, a per-entry cap and an idle TTL, with
///   least-recently-used eviction. Memory only; nothing is persisted, logged
///   or sent anywhere. Purged with the conversation cache.
public final class AssistantReasoningHistory: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        public var maxEntries: Int
        /// Sum of the stored reasoning UTF-8 bytes plus `entryOverheadBytes`
        /// per entry.
        public var maxBytes: Int
        /// A turn whose reasoning is larger is not stored.
        public var maxEntryBytes: Int
        public var ttlSeconds: TimeInterval

        public init(maxEntries: Int, maxBytes: Int, maxEntryBytes: Int, ttlSeconds: TimeInterval) {
            self.maxEntries = max(0, maxEntries)
            self.maxBytes = max(0, maxBytes)
            self.maxEntryBytes = max(0, maxEntryBytes)
            self.ttlSeconds = ttlSeconds
        }

        /// 4096 turns, 32 MiB, 1 MiB per turn, 72 h idle (the conversation
        /// cache's default TTL).
        public static let standard = Limits(
            maxEntries: 4096, maxBytes: 32 << 20, maxEntryBytes: 1 << 20, ttlSeconds: 72 * 3600)
    }

    public struct Restore: Sendable {
        public let messages: [ChatMessage]
        /// Assistant turns that got reasoning back.
        public let turns: Int
        /// UTF-8 bytes of the reasoning put back.
        public let bytes: Int
    }

    /// Key bytes and bookkeeping charged per entry.
    public static let entryOverheadBytes = 128

    /// The serving process's store.
    public static let shared = AssistantReasoningHistory()

    private struct Entry {
        let reasoning: String
        /// `H(conversation key)`, for `purge(conversationKey:)`.
        let keyDigest: SHA256.Digest
        let bytes: Int
        var lastUse: UInt64
        var usedAt: Date
    }

    private let lock = NSLock()
    private let limits: Limits
    private let now: @Sendable () -> Date
    private var entries: [SHA256.Digest: Entry] = [:]
    private var totalBytes = 0
    private var tick: UInt64 = 0

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

    /// Stores the reasoning of a turn generated for a request whose messages
    /// were `prefix`. No-op without reasoning or a conversation key.
    public func record(
        model: String,
        conversationKey: String?,
        prefix: [ChatMessage],
        content: String?,
        toolCalls: [ToolCall]?,
        reasoning: String?
    ) {
        guard let reasoning, !reasoning.isEmpty,
              let scope = Self.scope(model: model, conversationKey: conversationKey) else { return }
        let bytes = reasoning.utf8.count + Self.entryOverheadBytes
        guard bytes <= limits.maxEntryBytes, bytes <= limits.maxBytes, limits.maxEntries > 0 else { return }
        var hasher = SHA256()
        for message in prefix { Self.feed(&hasher, message) }
        let key = Self.turnKey(scope: scope.digest, prefix: hasher.finalize(),
                               content: content, toolCalls: toolCalls)
        let at = now()
        lock.lock()
        defer { lock.unlock() }
        sweepExpired(at: at)
        if let old = entries.removeValue(forKey: key) { totalBytes -= old.bytes }
        tick += 1
        entries[key] = Entry(reasoning: reasoning, keyDigest: scope.keyDigest, bytes: bytes, lastUse: tick, usedAt: at)
        totalBytes += bytes
        while entries.count > limits.maxEntries || totalBytes > limits.maxBytes {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            entries.removeValue(forKey: oldest.key)
            totalBytes -= oldest.value.bytes
        }
    }

    /// `messages` with recorded reasoning put back on assistant turns that
    /// arrived without any, or nil when no turn was restored.
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
        for candidate in candidates {
            guard var entry = entries[candidate.key] else { continue }
            if at.timeIntervalSince(entry.usedAt) > limits.ttlSeconds {
                entries.removeValue(forKey: candidate.key)
                totalBytes -= entry.bytes
                continue
            }
            tick += 1
            entry.lastUse = tick
            entry.usedAt = at
            entries[candidate.key] = entry
            let message = messages[candidate.index]
            restored[candidate.index] = ChatMessage(
                role: .assistant, content: message.content, toolCallID: message.toolCallID,
                toolCalls: message.toolCalls, reasoningContent: entry.reasoning)
            turns += 1
            bytes += entry.reasoning.utf8.count
        }
        return turns == 0 ? nil : Restore(messages: restored, turns: turns, bytes: bytes)
    }

    /// Drops every entry of a conversation key, for every model.
    public func purge(conversationKey: String) {
        let key = Self.normalizedKey(conversationKey)
        guard !key.isEmpty else { return }
        let keyDigest = SHA256.hash(data: Data(key.utf8))
        lock.lock()
        defer { lock.unlock() }
        let doomed = entries.filter { $0.value.keyDigest == keyDigest }
        for (digest, entry) in doomed {
            entries.removeValue(forKey: digest)
            totalBytes -= entry.bytes
        }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        totalBytes = 0
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

    /// Caller holds `lock`.
    private func sweepExpired(at date: Date) {
        let expired = entries.filter { date.timeIntervalSince($0.value.usedAt) > limits.ttlSeconds }
        for (digest, entry) in expired {
            entries.removeValue(forKey: digest)
            totalBytes -= entry.bytes
        }
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
