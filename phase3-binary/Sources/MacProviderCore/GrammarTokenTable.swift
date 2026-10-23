import Foundation

public struct GrammarTokenTableLimits: Sendable {
    public var maxTokens: Int
    public var maxBytes: Int
    public var maxScanBytes: Int
    public init(maxTokens: Int = 300_000, maxBytes: Int = 32_000_000, maxScanBytes: Int = 32_000_000) {
        self.maxTokens = maxTokens; self.maxBytes = maxBytes; self.maxScanBytes = maxScanBytes
    }
}

/// Exact tokenizer byte pieces, including pieces that split a UTF-8 scalar.
/// The owner may cache returned masks by (automaton identity, state).
public struct GrammarTokenTable: Sendable {
    private let tokens: [Int: [UInt8]]
    private let eosTokenIDs: Set<Int>
    private let limits: GrammarTokenTableLimits
    public init(tokens: [Int: [UInt8]], eosTokenIDs: Set<Int>, limits: GrammarTokenTableLimits = .init()) throws {
        guard limits.maxTokens > 0, limits.maxBytes > 0, limits.maxScanBytes > 0,
              tokens.count <= limits.maxTokens, eosTokenIDs.subtracting(tokens.keys).count <= limits.maxTokens - tokens.count,
              tokens.keys.allSatisfy({ $0 >= 0 }), eosTokenIDs.allSatisfy({ $0 >= 0 }) else {
            throw unsupportedGrammar("Output grammar tokenizer limit exceeded")
        }
        var bytes = 0
        for (id, piece) in tokens {
            guard eosTokenIDs.contains(id) || !piece.isEmpty,
                  piece.count <= limits.maxBytes - bytes else {
                throw unsupportedGrammar("Output grammar tokenizer byte limit exceeded or empty token")
            }
            bytes += piece.count
        }
        self.tokens = tokens; self.eosTokenIDs = eosTokenIDs; self.limits = limits
    }
    /// EOS preserves the accepting state. All other tokens must consume a valid byte path.
    public func allowedTokens(state: Int, automaton: GrammarAutomaton) throws -> [Int: Int] {
        guard state >= 0, state < automaton.stateCount else {
            throw unsupportedGrammar("Invalid output grammar state")
        }
        var result: [Int: Int] = [:], scanned = 0
        for (id, bytes) in tokens where !eosTokenIDs.contains(id) {
            guard bytes.count <= limits.maxScanBytes - scanned else {
                throw unsupportedGrammar("Output grammar token mask budget exceeded")
            }
            scanned += bytes.count
            if let next = automaton.transition(state: state, bytes: bytes) { result[id] = next }
        }
        if automaton.accepting(state: state) {
            for id in eosTokenIDs { result[id] = state }
        }
        return result
    }
}

public enum GrammarTokenEncoding: Sendable {
    case byteLevel
    case sentencePiece
    case raw
}

public enum GrammarTokenBytes {
    /// Decoder mode comes from tokenizer metadata, never guessed from token text.
    public static func decode(piece: String, encoding: GrammarTokenEncoding) throws -> [UInt8] {
        switch encoding {
        case .raw: return Array(piece.utf8)
        case .sentencePiece:
            let chars = Array(piece.utf8)
            if chars.count == 6, chars[0] == 60, chars[1] == 48, chars[2] == 120, chars[5] == 62,
               let value = UInt8(String(decoding: chars[3...4], as: UTF8.self), radix: 16) {
                return [value]
            }
            return Array(piece.replacingOccurrences(of: "▁", with: " ").utf8)
        case .byteLevel:
            var result: [UInt8] = []
            for scalar in piece.unicodeScalars {
                guard let byte = byteLevelInverse[scalar.value] else {
                    throw unsupportedGrammar("Tokenizer piece is outside the byte-level alphabet")
                }
                result.append(byte)
            }
            return result
        }
    }

    // GPT-2's reversible bytes_to_unicode alphabet, including nonprinting bytes.
    private static let byteLevelInverse: [UInt32: UInt8] = {
        let visible = Array(33...126) + Array(161...172) + Array(174...255)
        let visibleSet = Set(visible)
        var result: [UInt32: UInt8] = [:], extra = 0
        for byte in 0...255 {
            let scalar: Int
            if visibleSet.contains(byte) { scalar = byte }
            else { scalar = 256 + extra; extra += 1 }
            result[UInt32(scalar)] = UInt8(byte)
        }
        return result
    }()
}
