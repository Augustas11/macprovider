import Foundation

enum AutotuneStaticSchemaKind {
    case candidateCatalog
    case demandRank
}

enum AutotuneStrictJSON {
    static func rejectDuplicateKeys(_ data: Data) throws {
        var scanner = JSONDuplicateKeyScanner(data: data)
        try scanner.validate()
    }

    static func validate(_ data: Data, kind: AutotuneStaticSchemaKind) throws {
        try rejectDuplicateKeys(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutotuneRecommendError.invalidStaticJSON("top-level value must be an object")
        }
        switch kind {
        case .candidateCatalog:
            try validateCandidate(object)
        case .demandRank:
            try validateDemand(object)
        }
    }

    private static func validateCandidate(_ object: [String: Any]) throws {
        try exactKeys(
            object,
            allowed: ["version", "generated_at", "source", "policy_version", "rows"],
            required: ["version", "generated_at", "source", "policy_version", "rows"],
            label: "candidate catalog"
        )
        guard let rows = object["rows"] as? [String: Any] else {
            throw AutotuneRecommendError.invalidStaticJSON("candidate catalog rows")
        }
        let allowed = Set([
            "model_id", "model_revision", "model_sha256", "min_ram_gb", "min_bandwidth_tier",
            "bench_gate", "runtime_status", "notes", "draft_candidates", "workload_profiles",
        ])
        let required = Set(["model_id", "min_ram_gb", "min_bandwidth_tier", "bench_gate", "runtime_status"])
        for (key, rawRow) in rows {
            guard let row = rawRow as? [String: Any] else {
                throw AutotuneRecommendError.invalidStaticJSON("candidate row \(key)")
            }
            try exactKeys(row, allowed: allowed, required: required, label: "candidate row \(key)")
            guard let gate = row["bench_gate"] as? [String: Any] else {
                throw AutotuneRecommendError.invalidStaticJSON("candidate row \(key) bench_gate")
            }
            try exactKeys(
                gate,
                allowed: ["min_sustained_tps", "max_4k_ttft_ms", "provenance"],
                required: ["min_sustained_tps", "max_4k_ttft_ms", "provenance"],
                label: "candidate row \(key) bench_gate"
            )
            guard let rawProvenance = gate["provenance"] else {
                throw AutotuneRecommendError.invalidStaticJSON("candidate row \(key) bench_gate provenance")
            }
            guard let provenance = rawProvenance as? [String: Any] else {
                throw AutotuneRecommendError.invalidStaticJSON("candidate row \(key) bench_gate provenance")
            }
            try exactKeys(
                provenance,
                allowed: ["source", "hardware", "measured_at", "notes"],
                required: ["source"],
                label: "candidate row \(key) bench_gate provenance"
            )
            for optionalField in ["hardware", "measured_at", "notes"] where provenance.keys.contains(optionalField) {
                guard let value = provenance[optionalField] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw AutotuneRecommendError.invalidStaticJSON("candidate row \(key) bench_gate provenance \(optionalField)")
                }
            }
        }
    }

    private static func validateDemand(_ object: [String: Any]) throws {
        try exactKeys(
            object,
            allowed: [
                "version", "generated_at", "source", "policy_version", "cold_start_floor",
                "diversification_band", "rows",
            ],
            required: [
                "version", "generated_at", "source", "policy_version", "cold_start_floor",
                "diversification_band", "rows",
            ],
            label: "demand rank"
        )
        guard let rows = object["rows"] as? [String: Any] else {
            throw AutotuneRecommendError.invalidStaticJSON("demand rank rows")
        }
        let allowed = Set([
            "demand_weight", "rank", "recommendable", "min_provider_target", "ready_provider_count",
            "supply_deficit_multiplier", "min_dwell_hours",
        ])
        let required = Set(["demand_weight", "rank", "recommendable", "min_provider_target"])
        for (key, rawRow) in rows {
            guard let row = rawRow as? [String: Any] else {
                throw AutotuneRecommendError.invalidStaticJSON("demand row \(key)")
            }
            try exactKeys(row, allowed: allowed, required: required, label: "demand row \(key)")
        }
    }

    private static func exactKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        required: Set<String>,
        label: String
    ) throws {
        let actual = Set(object.keys)
        guard actual.isSubset(of: allowed), required.isSubset(of: actual) else {
            throw AutotuneRecommendError.invalidStaticJSON("\(label) fields")
        }
    }
}

private struct JSONDuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw invalid("trailing bytes") }
    }

    private mutating func parseValue() throws {
        guard index < bytes.count else { throw invalid("unexpected end") }
        switch bytes[index] {
        case 0x7B: try parseObject()
        case 0x5B: try parseArray()
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral("true")
        case 0x66: try consumeLiteral("false")
        case 0x6E: try consumeLiteral("null")
        default: try parseNumber()
        }
    }

    private mutating func parseObject() throws {
        index += 1
        skipWhitespace()
        var keys = Set<String>()
        if consume(0x7D) { return }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else { throw invalid("object key") }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw invalid("duplicate object key \(key)") }
            skipWhitespace()
            guard consume(0x3A) else { throw invalid("object colon") }
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw invalid("object separator") }
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw invalid("array separator") }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
                continue
            }
            if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let token = Data(bytes[start ..< index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
                    throw invalid("string")
                }
                return decoded
            } else if byte < 0x20 {
                throw invalid("control character")
            }
        }
        throw invalid("unterminated string")
    }

    private mutating func parseNumber() throws {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw invalid("number") }
        let token = Data(bytes[start ..< index])
        guard (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) is NSNumber else {
            throw invalid("number")
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index ..< index + expected.count]) == expected
        else { throw invalid("literal") }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func invalid(_ reason: String) -> AutotuneRecommendError {
        .invalidStaticJSON(reason)
    }
}
