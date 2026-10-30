import CryptoKit
import Foundation
import MacProviderCore
import MLX
import MLXLMCommon

/// A request owns its cursor; only immutable compiled languages are shared.
/// Processor callbacks cannot throw, so a failure permits only EOS and is
/// rethrown by the serving path before any held output is released.
final class GrammarConstraintState: @unchecked Sendable, Equatable {
    static func == (lhs: GrammarConstraintState, rhs: GrammarConstraintState) -> Bool { lhs === rhs }

    var fingerprint: String { compiled.fingerprint }
    private let compiled: Compiled
    private let lock = NSLock()
    private var state: Int
    private var reasoning: Bool
    private var reasoningTail: [UInt8] = []
    private var failure: APIError?
    private static let close = Array("</think>".utf8)
    private let reasoningProductivePrefixes: Set<Int>
    /// SPEC-018 §3.14: when `</think>` is a control token, only that token
    /// ends reasoning; the same text in ordinary tokens stays reasoning.
    private let closeTokenID: Int?

    private final class Compiled: @unchecked Sendable {
        private static let maskByteBudget = 8_000_000
        private static let maskEntryBytes = 32
        let automaton: GrammarAutomaton
        let table: GrammarTokenTable
        let productiveStates: Set<Int>
        let tokens: [Int: [UInt8]]
        let eos: Set<Int>
        let fingerprint: String
        private let lock = NSLock()
        private var masks: [Int: [Int: Int]] = [:]
        private var maskBytes = 0

        init(grammar: ByteGrammar, tokens: [Int: [UInt8]], eos: Set<Int>) throws {
            automaton = try grammar.compile()
            // Any reachable mask is a subset of this admitted ID union. Bound
            // it before inference so later states cannot exceed the cache budget.
            table = try GrammarTokenTable(tokens: tokens, eosTokenIDs: eos,
                limits: .init(maxTokens: Self.maskByteBudget / Self.maskEntryBytes))
            productiveStates = try table.productiveStates(automaton: automaton)
            self.tokens = tokens
            self.eos = eos
            var hash = SHA256()
            func append(_ text: String) { hash.update(data: Data(text.utf8)) }
            func language(_ grammar: ByteGrammar) {
                switch grammar {
                case .literal(let text): append("l\(text.utf8.count):"); append(text)
                case .bytes(let bytes): append("b\(bytes.count):"); hash.update(data: Data(bytes.sorted()))
                case .sequence(let children): append("s\(children.count)["); children.forEach(language); append("]")
                case .choice(let children): append("c\(children.count)["); children.forEach(language); append("]")
                case .zeroOrMore(let child): append("z["); language(child); append("]")
                case .optional(let child): append("o["); language(child); append("]")
                }
            }
            language(grammar)
            for id in tokens.keys.sorted() {
                let bytes = tokens[id]!
                append("t\(id):\(bytes.count):")
                hash.update(data: Data(bytes))
            }
            append("e\(eos.sorted())")
            fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
            _ = try allowed(automaton.initialState)
        }

        /// The close marker is a small prefix automaton. A closing token must
        /// also leave a token-productive answer prefix, including merged pieces.
        func reasoningProductivePrefixes() throws -> Set<Int> {
            let close = GrammarConstraintState.close
            let pieces = tokens.filter { !eos.contains($0.key) }.map(\.value)
            let singletonBytes = Set(pieces.compactMap { $0.count == 1 ? $0[0] : nil })
            if Set(close).isSubset(of: singletonBytes) { return Set(0..<close.count) }
            let work = pieces.reduce(0) { $0 + $1.count + close.count }
            guard work <= 8_000_000 / close.count else {
                throw Self.error("Reasoning-close token reachability exceeds work limit")
            }
            var reverse = [[Int]](repeating: [], count: close.count)
            var productive = Set<Int>()
            for prefix in 0..<close.count {
                for bytes in pieces {
                    let next = GrammarConstraintState.reasoningTransition(prefix: prefix, bytes: bytes)
                    if let suffix = next.suffix {
                        if let answer = automaton.transition(state: automaton.initialState, bytes: suffix),
                           productiveStates.contains(answer) { productive.insert(prefix) }
                    } else { reverse[next.prefix].append(prefix) }
                }
            }
            var queue = Array(productive)
            var index = 0
            while index < queue.count {
                let current = queue[index]; index += 1
                for predecessor in reverse[current] where productive.insert(predecessor).inserted {
                    queue.append(predecessor)
                }
            }
            guard productive.contains(0) else { throw Self.error("Tokenizer cannot close reasoning before constrained output") }
            return productive
        }

        func allowed(_ state: Int) throws -> [Int: Int] {
            lock.lock()
            defer { lock.unlock() }
            if let mask = masks[state] { return mask }
            let mask = try table.allowedTokens(state: state, automaton: automaton).filter { productiveStates.contains($0.value) }
            guard !mask.isEmpty else { throw Self.error("Tokenizer cannot continue this output grammar") }
            // Evict derived masks rather than rejecting a valid long request.
            let cost = mask.count * Self.maskEntryBytes
            guard cost <= Self.maskByteBudget else { throw Self.error("Output grammar token mask exceeds memory limit") }
            if maskBytes + cost > Self.maskByteBudget { masks.removeAll(); maskBytes = 0 }
            masks[state] = mask
            maskBytes += cost
            return mask
        }

        static func error(_ message: String) -> APIError {
            APIError(status: 400, message: message, code: "unsupported_output_grammar", param: "response_format")
        }
    }

    private struct CacheKey: Hashable {
        let tokenizer: String
        let grammar: ByteGrammar
        let eos: Set<Int>
    }
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [CacheKey: Compiled] = [:]
    }
    private static let cache = Cache()

    init(grammar: ByteGrammar, tokens: [Int: [UInt8]], eosTokenIDs: Set<Int>, reasoningOpen: Bool = false,
         closeTokenID: Int? = nil) throws {
        compiled = try Compiled(grammar: grammar, tokens: tokens, eos: eosTokenIDs)
        self.closeTokenID = closeTokenID
        reasoningProductivePrefixes = reasoningOpen && closeTokenID == nil ? try compiled.reasoningProductivePrefixes() : []
        state = compiled.automaton.initialState
        reasoning = reasoningOpen
    }

    private init(compiled: Compiled, reasoningOpen: Bool, closeTokenID: Int?) throws {
        self.compiled = compiled
        self.closeTokenID = closeTokenID
        reasoningProductivePrefixes = reasoningOpen && closeTokenID == nil ? try compiled.reasoningProductivePrefixes() : []
        state = compiled.automaton.initialState
        reasoning = reasoningOpen
    }

    static func isRequired(_ request: ChatCompletionRequest) -> Bool {
        if case .text = request.responseFormat {
            return (try? ToolSelectionPolicy.selection(request.promptSource.toolChoice).requiresCall) == true
        }
        return true
    }

    static func prepare(request: ChatCompletionRequest, tokenizer: any MLXLMCommon.Tokenizer,
                        configuration: ModelConfiguration, eosTokenIDs: Set<Int>) throws -> GrammarConstraintState? {
        do {
            return try prepareChecked(request: request, tokenizer: tokenizer, configuration: configuration, eosTokenIDs: eosTokenIDs)
        } catch let error as APIError { throw error }
        catch { throw Compiled.error("Unable to prepare the local tokenizer for constrained output") }
    }

    private static func prepareChecked(request: ChatCompletionRequest, tokenizer: any MLXLMCommon.Tokenizer,
                                       configuration: ModelConfiguration, eosTokenIDs: Set<Int>) throws -> GrammarConstraintState? {
        guard isRequired(request), let language = try GrammarTemplates.grammar(for: request, traits: request.outputTraits) else { return nil }
        let grammar = ByteGrammar.sequence([.zeroOrMore(.bytes(Set(" \t\r\n".utf8))), language])
        let directory: URL
        switch configuration.tokenizerSource {
        case .directory(let url)?: directory = url
        case .id?: throw Compiled.error("Constrained output requires a resolved local tokenizer")
        case nil:
            guard case .directory(let url) = configuration.id else { throw Compiled.error("Constrained output requires a resolved local tokenizer") }
            directory = url
        }
        let url = directory.appendingPathComponent("tokenizer.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 32_000_000 else {
            throw Compiled.error("Tokenizer exceeds constrained output byte limit")
        }
        let data = try Data(contentsOf: url)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = CacheKey(tokenizer: fingerprint, grammar: grammar, eos: eosTokenIDs)
        let closeTokenID = ControlTokenTable.of(tokenizer)?.idsByText["</think>"]
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let compiled = cache.entries[key] {
            return try GrammarConstraintState(compiled: compiled, reasoningOpen: request.outputTraits.reasoningOpen, closeTokenID: closeTokenID)
        }
        let pieces = try vocabulary(data: data, tokenizer: tokenizer)
        let compiled = try Compiled(grammar: grammar, tokens: pieces, eos: eosTokenIDs)
        // A small bounded cache; model/tokenizer identity includes the full file.
        if cache.entries.count >= 2 { cache.entries.removeAll() }
        cache.entries[key] = compiled
        return try GrammarConstraintState(compiled: compiled, reasoningOpen: request.outputTraits.reasoningOpen, closeTokenID: closeTokenID)
    }

    /// Read actual vocabulary IDs, including holes and raw added/special tokens.
    /// Decoder convention comes from tokenizer metadata, never a Unicode guess.
    static func vocabulary(data: Data, tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int: [UInt8]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any] else { throw Compiled.error("Invalid tokenizer vocabulary") }
        func decoderTypes(_ value: Any?) -> Set<String> {
            guard let node = value as? [String: Any] else { return [] }
            return Set([node["type"] as? String].compactMap { $0 }).union(
                (node["decoders"] as? [Any] ?? []).reduce(into: Set<String>()) { $0.formUnion(decoderTypes($1)) })
        }
        let types = decoderTypes(root["decoder"])
        let supportedTypes: Set<String> = ["Sequence", "ByteLevel", "ByteFallback", "Fuse", "Metaspace", "Replace", "Strip"]
        guard types.isSubset(of: supportedTypes),
              !(types.contains("ByteLevel") && !types.isDisjoint(with: ["ByteFallback", "Metaspace", "Replace", "Strip"])) else {
            throw Compiled.error("Unsupported tokenizer decoder transform")
        }
        func validTransforms(_ value: Any?) -> Bool {
            guard let node = value as? [String: Any], let type = node["type"] as? String else { return false }
            if type == "Replace" {
                guard let pattern = node["pattern"] as? [String: String], pattern == ["String": "▁"], node["content"] as? String == " " else { return false }
            }
            if type == "Strip" {
                guard node["content"] as? String == " ", node["stop"] as? Int == 0 else { return false }
            }
            if type == "Metaspace" {
                guard node["replacement"] as? String == "▁",
                      ["always", "first", "never"].contains(node["prepend_scheme"] as? String ?? "always") else { return false }
            }
            return (node["decoders"] as? [Any] ?? []).allSatisfy(validTransforms)
        }
        guard validTransforms(root["decoder"]) else { throw Compiled.error("Unsupported tokenizer decoder transform") }
        let encoding: GrammarTokenEncoding
        if types.contains("ByteLevel") { encoding = .byteLevel }
        else if types.contains("ByteFallback") || types.contains("Metaspace") { encoding = .sentencePiece }
        else { throw Compiled.error("Tokenizer decoder is unsupported for constrained output") }
        var result: [Int: [UInt8]] = [:]
        func add(_ piece: String, _ id: Int, raw: Bool = false) throws {
            guard id >= 0, id < 300_000, result.count < 300_000 else { throw Compiled.error("Tokenizer vocabulary exceeds limit") }
            // Use only IDs visible to the loaded tokenizer. Reserved holes stay masked.
            guard tokenizer.convertIdToToken(id) != nil else { return }
            let bytes = raw ? Array(piece.utf8) : try GrammarTokenBytes.decode(piece: piece, encoding: encoding)
            if !bytes.isEmpty { result[id] = bytes }
        }
        let vocabulary: [(String, Int)]
        if let vocab = model["vocab"] as? [String: Int] {
            vocabulary = vocab.map { ($0.key, $0.value) }
        } else if let vocab = model["vocab"] as? [[Any]] {
            vocabulary = try vocab.enumerated().map { id, entry in
                guard let piece = entry.first as? String else { throw Compiled.error("Invalid tokenizer piece") }
                return (piece, id)
            }
        } else { throw Compiled.error("Unsupported tokenizer vocabulary") }
        var addedByID: [Int: String] = [:]
        var addedByPiece: [String: Int] = [:]
        for added in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let piece = added["content"] as? String, let id = added["id"] as? Int,
                  id >= 0, id < 300_000,
                  addedByID[id].map({ $0 == piece }) ?? true,
                  addedByPiece[piece].map({ $0 == id }) ?? true else {
                throw Compiled.error("Conflicting or invalid added tokenizer piece")
            }
            addedByID[id] = piece
            addedByPiece[piece] = id
        }
        // Registered added tokens use their literal bytes even when also in
        // the base vocabulary (DeepSeek's BOS/EOS/pad are such entries).
        // Validate every mapping before decoding, so aliases cannot overwrite IDs.
        for (piece, id) in vocabulary {
            guard addedByID[id].map({ $0 == piece }) ?? true,
                  addedByPiece[piece].map({ $0 == id }) ?? true else {
                throw Compiled.error("Conflicting added tokenizer piece")
            }
        }
        for (piece, id) in vocabulary { try add(piece, id, raw: addedByID[id] == piece) }
        for (id, piece) in addedByID { try add(piece, id, raw: true) }
        return result
    }

    private static func reasoningTransition(prefix: Int, bytes: [UInt8]) -> (prefix: Int, suffix: [UInt8]?) {
        let combined = Array(close.prefix(prefix)) + bytes
        if combined.count >= close.count {
            for index in 0...(combined.count - close.count) where Array(combined[index..<index + close.count]) == close {
                return (0, Array(combined.dropFirst(index + close.count)))
            }
        }
        for count in stride(from: min(close.count - 1, combined.count), through: 1, by: -1) {
            if combined.suffix(count).elementsEqual(close.prefix(count)) { return (count, nil) }
        }
        return (0, nil)
    }

    private func next(_ token: Int, _ bytes: [UInt8]) -> (state: Int, reasoning: Bool, tail: [UInt8])? {
        if reasoning, let closeTokenID {
            return token == closeTokenID ? (state, false, []) : (state, true, [])
        }
        guard reasoning else {
            return compiled.automaton.transition(state: state, bytes: bytes).flatMap {
                compiled.productiveStates.contains($0) ? ($0, false, []) : nil
            }
        }
        let next = Self.reasoningTransition(prefix: reasoningTail.count, bytes: bytes)
        if let suffix = next.suffix {
            return compiled.automaton.transition(state: state, bytes: suffix).flatMap {
                compiled.productiveStates.contains($0) ? ($0, false, []) : nil
            }
        }
        guard reasoningProductivePrefixes.contains(next.prefix) else { return nil }
        return (state, true, Array(Self.close.prefix(next.prefix)))
    }

    func mask(logits: MLXArray) -> MLXArray {
        lock.lock()
        defer { lock.unlock() }
        let vocab = logits.dim(-1)
        var allowed: [Int] = []
        do {
            if failure != nil { allowed = Array(compiled.eos) }
            else if reasoning {
                allowed = compiled.tokens.compactMap { id, bytes in
                    !compiled.eos.contains(id) && next(id, bytes) != nil ? id : nil
                }
            } else { allowed = Array(try compiled.allowed(state).keys) }
        } catch { failure = error as? APIError ?? Compiled.error("Output grammar mask failed"); allowed = Array(compiled.eos) }
        var values = [Float](repeating: -.infinity, count: vocab)
        for id in allowed where id >= 0 && id < vocab { values[id] = 0 }
        if !values.contains(0) { failure = Compiled.error("No legal output token in model vocabulary") }
        // An all-nonfinite allowed set must still select a legal token. Preserve
        // finite model logits exactly, sanitize only nonfinite constrained logits.
        let legal = MLXArray(values) .== 0
        return MLX.where(legal, MLX.where(isFinite(logits), logits, MLXArray(Float(0))), MLXArray(-Float.infinity)).asType(logits.dtype)
    }

    func didSample(token: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        if compiled.eos.contains(token) {
            if !reasoning, compiled.automaton.accepting(state: state) { return }
            if !reasoning, let bytes = compiled.tokens[token],
               let terminal = compiled.automaton.transition(state: state, bytes: bytes),
               compiled.automaton.accepting(state: terminal) {
                state = terminal
                return
            }
            failure = Compiled.error("Output stopped before grammar acceptance")
            return
        }
        guard let bytes = compiled.tokens[token], let next = next(token, bytes) else {
            failure = Compiled.error("Decoder selected an illegal output token")
            return
        }
        state = next.state; reasoning = next.reasoning; reasoningTail = next.tail
    }

    func validate() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
    }
}

struct GrammarLogitProcessor: LogitProcessor {
    let constraint: GrammarConstraintState
    mutating func prompt(_ prompt: MLXArray) {}
    func process(logits: MLXArray) -> MLXArray { constraint.mask(logits: logits) }
    mutating func didSample(token: MLXArray) { constraint.didSample(token: token.item(Int.self)) }
}
