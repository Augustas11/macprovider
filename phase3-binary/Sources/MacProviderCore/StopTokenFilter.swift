import Foundation

public struct StopTokenFilter: Sendable {
    public let tokens: [String]

    public init(tokens: [String]) {
        var seen = Set<String>()
        self.tokens = tokens
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }

    public func stripping(from text: String) -> String {
        var output = text
        for token in tokens {
            output = output.replacingOccurrences(of: token, with: "")
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
