import Foundation

public struct StopTokenFilter: Sendable {
    public let tokens: [String]
    public let maxTokenLength: Int

    public init(tokens: [String]) {
        var seen = Set<String>()
        self.tokens = tokens
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
        self.maxTokenLength = self.tokens.map(\.count).max() ?? 0

        var byteTokens = [[UInt8]]()
        var firstBytes = [Bool](repeating: false, count: 256)
        var slowTokens = [String]()
        for token in self.tokens {
            let bytes = Array(token.utf8)
            if bytes.allSatisfy(Self.isByteExactASCII) {
                byteTokens.append(bytes)
                firstBytes[Int(bytes[0])] = true
            } else {
                slowTokens.append(token)
            }
        }
        self.byteTokens = byteTokens
        self.firstBytes = firstBytes
        self.slowTokens = slowTokens
    }

    /// Tokens made only of ASCII bytes that no other Unicode scalar is
    /// canonically equivalent to. Such a token can occur in a text only where
    /// its exact bytes occur, so a byte scan can rule it out.
    private let byteTokens: [[UInt8]]
    private let firstBytes: [Bool]
    /// Every other token; always checked with the string search.
    private let slowTokens: [String]

    /// False for non-ASCII bytes and for `K`, `;` and `` ` ``: U+212A, U+037E
    /// and U+1FEF compare equal to those three as Swift Characters, so their
    /// bytes in a text do not have to match the token's.
    static func isByteExactASCII(_ byte: UInt8) -> Bool {
        byte < 0x80 && byte != UInt8(ascii: "K") && byte != UInt8(ascii: ";") && byte != UInt8(ascii: "`")
    }

    /// True when some stop token may occur in `text`. Never false when one
    /// does. One pass over the bytes for the byte-exact tokens, so a streaming
    /// caller that re-filters the growing text for every generated token does
    /// not run one string search per stop token per call (a Llama 3.1
    /// tokenizer has 256 of them).
    func mayContainToken(_ text: String) -> Bool {
        if tokens.isEmpty { return false }
        for token in slowTokens where text.contains(token) {
            return true
        }
        if byteTokens.isEmpty { return false }
        var contiguous = text
        contiguous.makeContiguousUTF8()
        return contiguous.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            let count = bytes.count
            var index = 0
            while index < count {
                if firstBytes[Int(bytes[index])] {
                    for token in byteTokens where token.count <= count - index {
                        var offset = 0
                        while offset < token.count, bytes[index + offset] == token[offset] {
                            offset += 1
                        }
                        if offset == token.count { return true }
                    }
                }
                index += 1
            }
            return false
        } ?? true
    }

    public func stripping(from text: String) -> String {
        stripping(from: text, joiner: "")
    }

    /// Removes the stop tokens' text. Where a removal joins text on both
    /// sides, `joiner` goes between them, so two fragments around a removed
    /// token never read as one marker; removals at either end leave nothing.
    public func stripping(from text: String, joiner: String) -> String {
        guard mayContainToken(text) else { return text }
        return strippingEveryToken(from: text, joiner: joiner)
    }

    /// The full removal: one string search per stop token.
    func strippingEveryToken(from text: String, joiner: String) -> String {
        var output = text
        for token in tokens {
            guard output.contains(token) else { continue }
            if joiner.isEmpty {
                output = output.replacingOccurrences(of: token, with: "")
                continue
            }
            let parts = output.components(separatedBy: token)
            var joined = ""
            for (index, part) in parts.enumerated() {
                if index > 0, !joined.isEmpty, parts[index...].contains(where: { !$0.isEmpty }) {
                    joined += joiner
                }
                joined += part
            }
            output = joined
        }
        return output
    }
}

public enum StopTokenConfigExtractor {
    public static func extract(fromTokenizerConfigAt url: URL) throws -> StopTokenFilter {
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let dict = raw as? [String: Any] else {
            return StopTokenFilter(tokens: [])
        }

        var tokens = [String]()
        collectToken(dict["eos_token"], into: &tokens)
        collectToken(dict["bos_token"], into: &tokens)

        if let decoder = dict["added_tokens_decoder"] as? [String: Any] {
            for value in decoder.values {
                guard let tokenObject = value as? [String: Any],
                      tokenObject["special"] as? Bool == true
                else {
                    continue
                }
                collectToken(tokenObject, into: &tokens)
            }
        }

        return StopTokenFilter(tokens: tokens)
    }

    private static func collectToken(_ raw: Any?, into tokens: inout [String]) {
        switch raw {
        case let token as String:
            tokens.append(token)
        case let tokenObject as [String: Any]:
            collectToken(tokenObject["content"], into: &tokens)
            collectToken(tokenObject["token"], into: &tokens)
        case let tokenList as [Any]:
            for token in tokenList {
                collectToken(token, into: &tokens)
            }
        default:
            break
        }
    }
}
