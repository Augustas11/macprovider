#if DEBUG || MACPROVIDER_LAB_HARNESS
import CoreFoundation
import CryptoKit
import Foundation
import MacProviderCore

/// Frozen inputs only. Counts do not establish parity, realized prompt sizes,
/// native admission, terminal coverage, or an acceptance verdict.
struct NativeMTPAcceptanceCorpus: Sendable {
    static let schema = "macprovider.native-mtp-acceptance-corpus.v1"

    enum Stratum: String, CaseIterable, Sendable {
        case short
        case onePointFiveK = "1.5k"
        case fourK = "4k"
        case eightK = "8k"
        case nearBoundary = "near_boundary"
    }

    struct Case: Sendable {
        let id: String
        let stratum: Stratum
        let expectedNative: Bool
        let request: ChatCompletionRequest
        let rawRequestData: Data
    }

    enum ValidationError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let reason): "invalid acceptance corpus: \(reason)" }
        }
    }

    let modelID: String
    let maxPromptTokens: Int
    let qualifiedSlots: Int
    let maxNativeActiveRows: Int
    let proposalDepth: Int
    let minimumComparedPositions: Int
    let digestSHA256: String
    let cases: [Case]

    static func load(from url: URL) throws -> Self {
        try load(data: Data(contentsOf: url))
    }

    static func load(data: Data) throws -> Self {
        guard data.count <= 64 * 1_024 * 1_024 else { throw invalid("size exceeds bound") }
        let object: [String: Any]
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(data)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw invalid("expected object")
            }
            object = parsed
        } catch { throw invalid("malformed or duplicate-key JSON") }
        try keys(object, exactly: [
            "schema", "model_id", "max_prompt_tokens", "qualified_slots",
            "max_native_active_rows", "proposal_depth", "minimum_compared_positions", "cases",
        ])
        guard object["schema"] as? String == schema else { throw invalid("schema") }
        guard let modelID = object["model_id"] as? String,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("model_id")
        }
        let maxPromptTokens = try integer(object, "max_prompt_tokens", in: 4096...4096)
        let qualifiedSlots = try integer(object, "qualified_slots", in: 4...4)
        let maxNativeActiveRows = try integer(object, "max_native_active_rows", in: 1...1)
        let proposalDepth = try integer(object, "proposal_depth", in: 1...2)
        let minimumComparedPositions = try integer(object, "minimum_compared_positions", in: 6_400...102_400)
        guard let inputs = object["cases"] as? [[String: Any]], (200...400).contains(inputs.count) else {
            throw invalid("cases must contain 200...400 objects")
        }
        var seen = Set<String>()
        var counts: [Stratum: Int] = [:]
        var nativePositionBudget = 0
        let cases = try inputs.enumerated().map { index, input -> Case in
            try keys(input, exactly: ["id", "stratum", "expected_native", "request"])
            guard let id = input["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  seen.insert(id).inserted else { throw invalid("case \(index) id") }
            guard let name = input["stratum"] as? String, let stratum = Stratum(rawValue: name) else {
                throw invalid("case \(index) stratum")
            }
            let expectedNative = try boolean(input, "expected_native")
            guard stratum != .eightK || !expectedNative else {
                throw invalid("8k exceeds the signed prompt cap and must expect ordinary")
            }
            guard let raw = input["request"] as? [String: Any], raw["model"] as? String == modelID,
                  raw["diagnostic_eligibility_bypass"] == nil else {
                throw invalid("case \(index) request model or diagnostic bypass")
            }
            guard try boolean(raw, "stream") == false else { throw invalid("case \(index) must be nonstreaming") }
            let rawRequestData = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            let request: ChatCompletionRequest
            do {
                request = try ChatCompletionRequest.parse(data: rawRequestData).withRequestID(id)
            } catch { throw invalid("case \(index) rejected by production request parser") }
            guard let maxTokens = request.maxTokens, (1...256).contains(maxTokens) else {
                throw invalid("case \(index) requires a completion limit within 1...256")
            }
            counts[stratum, default: 0] += 1
            if expectedNative { nativePositionBudget += maxTokens }
            return Case(id: id, stratum: stratum, expectedNative: expectedNative,
                        request: request, rawRequestData: rawRequestData)
        }
        guard Stratum.allCases.allSatisfy({ counts[$0, default: 0] >= 20 }) else {
            throw invalid("each stratum requires at least 20 cases")
        }
        guard nativePositionBudget >= minimumComparedPositions else {
            throw invalid("native completion budgets cannot reach minimum_compared_positions")
        }
        return Self(
            modelID: modelID, maxPromptTokens: maxPromptTokens, qualifiedSlots: qualifiedSlots,
            maxNativeActiveRows: maxNativeActiveRows, proposalDepth: proposalDepth,
            minimumComparedPositions: minimumComparedPositions,
            digestSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), cases: cases)
    }

    private static func invalid(_ reason: String) -> ValidationError { .invalid(reason) }

    private static func keys(_ object: [String: Any], exactly expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw invalid("missing or unknown fields") }
    }

    private static func integer(_ object: [String: Any], _ key: String, in range: ClosedRange<Int>) throws -> Int {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(exactly: number.doubleValue), range.contains(value) else { throw invalid(key) }
        return value
    }

    private static func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw invalid(key)
        }
        return number.boolValue
    }
}
#endif
