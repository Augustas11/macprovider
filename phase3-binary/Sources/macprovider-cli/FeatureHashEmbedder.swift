import Foundation

/// Hashes text into a fixed vector. No model is loaded and nothing leaves the process.
enum FeatureHashFailure: Error, Equatable {
    case invalid
    case limit
}

enum FeatureHashEmbedder {
    static let dimension = 64
    static let maxInputs = 16
    static let maxInputBytes = 8192
    static let defaultModel = "local-hash"

    struct Request: Equatable {
        var model: String
        var inputs: [String]
    }

    static func parse(_ data: Data) throws -> Request {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeatureHashFailure.invalid
        }
        let inputs: [String]
        if let text = object["input"] as? String {
            inputs = [text]
        } else if let list = object["input"] as? [Any] {
            guard !list.isEmpty else { throw FeatureHashFailure.invalid }
            guard list.count <= maxInputs else { throw FeatureHashFailure.limit }
            var parsed: [String] = []
            parsed.reserveCapacity(list.count)
            for item in list {
                guard let text = item as? String else { throw FeatureHashFailure.invalid }
                parsed.append(text)
            }
            inputs = parsed
        } else {
            throw FeatureHashFailure.invalid
        }
        guard inputs.count <= maxInputs else { throw FeatureHashFailure.limit }
        for text in inputs {
            if text.contains("\0") { throw FeatureHashFailure.invalid }
            if text.utf8.count > maxInputBytes { throw FeatureHashFailure.limit }
        }
        return Request(model: modelName(object["model"]), inputs: inputs)
    }

    static func embed(_ text: String) -> [Double] {
        var bins = [Double](repeating: 0, count: dimension)
        var counted = 0
        for feature in features(of: text) {
            let hash = fnv1a(feature)
            let index = Int((hash >> 1) % UInt64(dimension))
            bins[index] += (hash & 1) == 0 ? 1 : -1
            counted += 1
        }
        guard counted > 0 else { return bins }
        var sum = 0.0
        for value in bins { sum += value * value }
        let norm = sum.squareRoot()
        guard norm > 0 else { return [Double](repeating: 0, count: dimension) }
        return bins.map { $0 / norm }
    }

    static func response(for request: Request) -> [String: Any] {
        let rows: [[String: Any]] = request.inputs.enumerated().map { index, text in
            ["object": "embedding", "index": index, "embedding": embed(text)]
        }
        let tokens = request.inputs.reduce(0) { $0 + ($1.utf8.count + 3) / 4 }
        return [
            "object": "list",
            "data": rows,
            "model": request.model,
            "usage": ["prompt_tokens": tokens, "total_tokens": tokens],
        ]
    }

    /// Echo a short model name. Anything else stays the local default; the warm model is not consulted.
    private static func modelName(_ raw: Any?) -> String {
        guard let text = raw as? String, (1...64).contains(text.utf8.count), !text.contains("\0"),
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return defaultModel }
        return text
    }

    private static func features(of text: String) -> [String] {
        let folded = text.lowercased()
        var found: [String] = []
        var word = ""
        for character in folded {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                if word.count >= 2 { found.append(word) }
                word = ""
            }
        }
        if word.count >= 2 { found.append(word) }
        let characters = Array(folded)
        if characters.count >= 3 {
            for index in 0...(characters.count - 3) {
                found.append(String(characters[index...index + 2]))
            }
        }
        return found
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
