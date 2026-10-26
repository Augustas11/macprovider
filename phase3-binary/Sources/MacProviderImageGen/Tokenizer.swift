// Copyright © 2024 Apple Inc.

import Foundation

struct Bigram: Hashable {
    let a: String
    let b: String

    init(_ s: String) {
        let pieces = s.split(separator: " ")
        precondition(pieces.count == 2, "BPEPair expected two pieces for '\(s)'")
        self.a = String(pieces[0])
        self.b = String(pieces[1])
    }

    init(_ a: String, _ b: String) {
        self.a = a
        self.b = b
    }

    init(_ v: (String, String)) {
        self.a = v.0
        self.b = v.1
    }
}

/// A CLIP tokenizer.
///
/// Ported from:
///
/// - https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/tokenizer.py
/// - https://github.com/huggingface/transformers/blob/main/src/transformers/models/clip/tokenization_clip.py
///
/// Ideally this would be a tokenizer from `swift-transformers` but this is too special purpose to be representable in
/// what exists there (at time of writing).
class CLIPTokenizer {

    /// CLIP's reversible byte alphabet keeps UTF-8 bytes out of BPE's
    /// whitespace/control characters. Vocabulary entries use this alphabet,
    /// rather than the original Unicode characters of the prompt.
    private static let byteAlphabet: [String] = {
        let literalBytes = Set(Array(33...126) + Array(161...172) + Array(174...255))
        var nextScalar = 256
        return (0...255).map { byte in
            if literalBytes.contains(byte) { return String(UnicodeScalar(byte)!) }
            defer { nextScalar += 1 }
            return String(UnicodeScalar(nextScalar)!)
        }
    }()

    let pattern =
        #/<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+/#
    let bpeRanks: [Bigram: Int]
    let vocabulary: [String: Int]

    let bos = "<|startoftext|>"
    let eos = "<|endoftext|>"

    let bosToken: Int
    let eosToken: Int

    var cache = [String: [String]]()

    init(merges: [String], vocabulary: [String: Int]) {
        self.bpeRanks = Dictionary(
            uniqueKeysWithValues:
                merges
                .map { Bigram($0) }
                .enumerated()
                .map { ($0.element, $0.offset) })

        self.vocabulary = vocabulary
        self.cache[bos] = [bos]
        self.cache[eos] = [eos]
        self.bosToken = vocabulary[bos]!
        self.eosToken = vocabulary[eos]!
    }

    func bpe(text: String) -> [String] {
        if let result = cache[text] {
            return result
        }

        precondition(!text.isEmpty)

        let scalars = text.unicodeScalars.map { String($0) }
        var unigrams = Array(scalars.dropLast()) + ["\(scalars.last!)</w>"]
        var uniqueBigrams = Set(zip(unigrams, unigrams.dropFirst()).map { Bigram($0) })

        // In every iteration try to merge the two most likely bigrams. If none
        // was merged we are done

        while !uniqueBigrams.isEmpty {
            let (bigram, _) =
                uniqueBigrams
                .map { ($0, bpeRanks[$0] ?? Int.max) }
                .min { $0.1 < $1.1 }!

            if bpeRanks[bigram] == nil {
                break
            }

            var newUnigrams = [String]()
            var skip = false

            for (a, b) in zip(unigrams, unigrams.dropFirst()) {
                if skip {
                    skip = false
                    continue
                }

                if Bigram(a, b) == bigram {
                    newUnigrams.append(a + b)
                    skip = true
                } else {
                    newUnigrams.append(a)
                }
            }

            if !skip, let last = unigrams.last {
                newUnigrams.append(last)
            }

            unigrams = newUnigrams
            uniqueBigrams = Set(zip(unigrams, unigrams.dropFirst()).map { Bigram($0) })
        }

        cache[text] = unigrams

        return unigrams
    }

    public func tokenize(text: String) -> [Int32] {
        let clean = text.precomposedStringWithCanonicalMapping.lowercased().replacing(#/\s+/#, with: " ")
        let tokens = clean.matches(of: pattern).map { $0.description }

        // Split the tokens according to the byte-pair merge file
        let bpeTokens = tokens.flatMap { token in
            bpe(text: token.utf8.map { Self.byteAlphabet[Int($0)] }.joined())
        }

        // Map to token ids and return
        // SDXL CLIP encoders have 77 position embeddings. Keep the final EOS
        // even when a valid HTTP prompt produces more than 75 content tokens.
        let result = [bosToken] + bpeTokens.map { vocabulary[$0] ?? eosToken }.prefix(75) + [eosToken]

        return result.map { Int32($0) }
    }
}
