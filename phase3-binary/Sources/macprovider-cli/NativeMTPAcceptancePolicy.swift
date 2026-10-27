import CoreFoundation
import CryptoKit
import Foundation

/// Identity binding for the frozen correctness corpus; never an R015 verdict.
struct NativeMTPAcceptancePolicy: Sendable {
    static let schema = "macprovider.native-mtp-acceptance-policy.v1"

    enum ValidationError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let reason): "invalid acceptance policy: \(reason)" }
        }
    }

    let modelID: String
    let targetSHA256: String
    let mtpSHA256: String
    let tokenizerSHA256: String
    let hwModel: String
    let chip: String
    let ramGB: Int
    let osBuild: String
    let xcodeBuildVersion: String
    let swiftVersion: String
    let providerCommit: String
    let mlxForkRevision: String
    let quantization: String
    let cacheMode: String
    let corpusSHA256: String
    let digestSHA256: String

    var policyJSON: [String: Any] {
        [
            "schema": Self.schema, "model_id": modelID, "target_sha256": targetSHA256,
            "mtp_sha256": mtpSHA256, "tokenizer_sha256": tokenizerSHA256,
            "hw_model": hwModel, "chip": chip, "ram_gb": ramGB, "os_build": osBuild,
            "xcode_build_version": xcodeBuildVersion, "swift_version": swiftVersion,
            "provider_commit": providerCommit, "mlx_fork_revision": mlxForkRevision,
            "quantization": quantization, "cache_mode": cacheMode, "corpus_sha256": corpusSHA256,
        ]
    }

    static func load(from url: URL) throws -> Self {
        try load(data: Data(contentsOf: url))
    }

    static func load(data: Data) throws -> Self {
        guard data.count <= 64 * 1_024 else { throw invalid("size exceeds bound") }
        let object: [String: Any]
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(data)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw invalid("expected object")
            }
            object = parsed
        } catch { throw invalid("malformed or duplicate-key JSON") }
        let keys: Set<String> = [
            "schema", "model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256",
            "hw_model", "chip", "ram_gb", "os_build", "xcode_build_version", "swift_version",
            "provider_commit", "mlx_fork_revision", "quantization", "cache_mode", "corpus_sha256",
        ]
        guard Set(object.keys) == keys else { throw invalid("missing or unknown fields") }
        guard try string(object, "schema") == schema else { throw invalid("schema") }
        let hwModel = try string(object, "hw_model")
        let quantization = try string(object, "quantization")
        let cacheMode = try string(object, "cache_mode")
        guard hwModel == "Mac15,14" else { throw invalid("hw_model") }
        guard quantization == "4bit" else { throw invalid("quantization") }
        guard cacheMode == "paged_kv_mixed" else { throw invalid("cache_mode") }
        guard let number = object["ram_gb"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let ramGB = Int(exactly: number.doubleValue), ramGB > 0, ramGB <= 16_384 else {
            throw invalid("ram_gb")
        }
        return try Self(
            modelID: string(object, "model_id"), targetSHA256: hex(object, "target_sha256", count: 64),
            mtpSHA256: hex(object, "mtp_sha256", count: 64),
            tokenizerSHA256: hex(object, "tokenizer_sha256", count: 64),
            hwModel: hwModel, chip: string(object, "chip"), ramGB: ramGB,
            osBuild: string(object, "os_build"), xcodeBuildVersion: string(object, "xcode_build_version"),
            swiftVersion: string(object, "swift_version"), providerCommit: hex(object, "provider_commit", count: 40),
            mlxForkRevision: hex(object, "mlx_fork_revision", count: 40),
            quantization: quantization, cacheMode: cacheMode,
            corpusSHA256: hex(object, "corpus_sha256", count: 64),
            digestSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    func validate(
        corpus: NativeMTPAcceptanceCorpus, environment: NativeMTPBenchEnvironment,
        targetSHA256: String, mtpSHA256: String, tokenizerSHA256: String
    ) throws {
        let expected: [(String, AnyHashable, AnyHashable)] = [
            ("model_id", modelID, corpus.modelID),
            ("target_sha256", self.targetSHA256, targetSHA256),
            ("mtp_sha256", self.mtpSHA256, mtpSHA256),
            ("tokenizer_sha256", self.tokenizerSHA256, tokenizerSHA256),
            ("hw_model", hwModel, environment.hwModel), ("chip", chip, environment.chip),
            ("ram_gb", ramGB, environment.ramGB), ("os_build", osBuild, environment.osBuild),
            ("xcode_build_version", xcodeBuildVersion, environment.xcodeBuildVersion),
            ("swift_version", swiftVersion, environment.swiftVersion),
            ("provider_commit", providerCommit, environment.providerCommit),
            ("mlx_fork_revision", mlxForkRevision, NativeMTPHardwareE2ERunner.upstreamRevision),
            ("corpus_sha256", corpusSHA256, corpus.digestSHA256),
        ]
        for (field, frozen, observed) in expected where frozen != observed {
            throw Self.invalid("\(field) mismatch")
        }
    }

    private static func string(_ object: [String: Any], _ field: String) throws -> String {
        guard let value = object[field] as? String, !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines), value.utf8.count <= 4_096 else {
            throw invalid(field)
        }
        return value
    }

    private static func hex(_ object: [String: Any], _ field: String, count: Int) throws -> String {
        let value = try string(object, field)
        guard value.utf8.count == count,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw invalid(field)
        }
        return value
    }

    private static func invalid(_ reason: String) -> ValidationError { .invalid(reason) }
}
