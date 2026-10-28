import Foundation
import CoreFoundation

/// Genuine native-profile diagnostic preflight. SPEC-030-R021 and SPEC-036-R018
/// forbid native TV/integrity pass without independent execution attestation.
/// A provider_inconclusive result is emitted before measurement, never a
/// synthesized distribution or a claim that a native decode actually ran.
enum NativePathProbeProtocol {
    static let compute = "compute_integrity_probe_v1"
    static let reason = "inconclusive:native_path_untrusted"
    static let profiles = [LosslessnessProbeProtocol.version, compute]

    struct Request {
        let profile: String
        let payload: [String: Any]
        let digest: String
        var probeID: String { payload["probe_id"] as! String }
    }
    static func digest(profile: String, kind: String, payload: [String: Any]) throws -> String {
        if profile == compute {
            return try LosslessnessProbeProtocol.digest(payload: [
                "type": profile + "." + kind, "schema_version": profile + "." + kind, "payload": payload,
            ])
        }
        return try LosslessnessProbeProtocol.digest(payload: payload)
    }
    static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= Double(Int32.max),
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        return value.intValue
    }
    static func boolean(_ value: Any?, _ expected: Bool) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue == expected
    }
    static func sha(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func keys(_ value: [String: Any], _ expected: String) -> Bool {
        Set(value.keys) == Set(expected.split(separator: " ").map(String.init))
    }
    static func decode(_ outer: [String: Any], profile: String, now: Date = Date()) throws -> Request {
        guard profiles.contains(profile), outer["type"] as? String == profile + ".request",
              let p = outer["payload"] as? [String: Any],
              let expected = outer["probe_request_digest"] as? String,
              try digest(profile: profile, kind: "request", payload: p) == expected,
              let generation = integer(p["target_generation"]), generation > 0,
              sha(p["native_mtp_runtime_tuple_sha256"]),
              let expiryText = p["expires_at"] as? String, let expiry = date(expiryText),
              expiry > now, expiry.timeIntervalSince(now) <= 61,
              let sampler = p["sampling_profile"] as? [String: Any], keys(sampler, "temperature top_p"),
              let temperature = sampler["temperature"] as? NSNumber, CFGetTypeID(temperature) != CFBooleanGetTypeID(),
              let topP = sampler["top_p"] as? NSNumber, CFGetTypeID(topP) != CFBooleanGetTypeID(),
              temperature.doubleValue.isFinite, (0...2).contains(temperature.doubleValue),
              topP.doubleValue.isFinite, topP.doubleValue > 0, topP.doubleValue <= 1 else { throw LosslessnessProbeError.invalidPayload }
        for key in ["probe_id", "model_id", "target_model_hash", "tokenizer_identity", "corpus_version", "threshold_version"] {
            guard let value = p[key] as? String, !value.isEmpty, value.utf8.count <= 256 else { throw LosslessnessProbeError.invalidPayload }
        }
        if profile == LosslessnessProbeProtocol.version {
            guard keys(outer, "type probe_id probe_request_digest payload"), outer["probe_id"] as? String == p["probe_id"] as? String,
                  keys(p, "probe_version probe_id probe_nonce expires_at model_id target_model_hash target_generation tokenizer_identity sampling_profile corpus_version threshold_version prompts measurement_positions requested_k support_selection max_prompts max_stochastic_positions timeout_ms decode_path native_mtp_runtime_tuple_sha256"),
                  p["probe_version"] as? String == profile, p["decode_path"] as? String == "native_mtp",
                  let nonce = p["probe_nonce"] as? String, !nonce.isEmpty,
                  p["support_selection"] as? String == LosslessnessProbeProtocol.supportSelection,
                  let k = integer(p["requested_k"]), k == 64 || k == 256,
                  let mp = integer(p["max_prompts"]), (1...4).contains(mp),
                  let ms = integer(p["max_stochastic_positions"]), (1...8).contains(ms),
                  integer(p["timeout_ms"]) == 60_000,
                  let prompts = p["prompts"] as? [[String: Any]], (1...mp).contains(prompts.count),
                  let positions = p["measurement_positions"] as? [Any], (1...ms).contains(positions.count) else { throw LosslessnessProbeError.invalidPayload }
            var seen = Set<Int>()
            for position in positions { guard let n = integer(position), seen.insert(n).inserted else { throw LosslessnessProbeError.invalidPayload } }
            for q in prompts {
                guard keys(q, "prompt_id prompt coordinator_owned buyer_origin"), let id = q["prompt_id"] as? String, !id.isEmpty,
                      let text = q["prompt"] as? String, text.utf8.count <= 4096,
                      boolean(q["coordinator_owned"], true), boolean(q["buyer_origin"], false) else { throw LosslessnessProbeError.invalidPayload }
            }
        } else {
            guard keys(outer, "type schema_version payload probe_request_digest"), outer["schema_version"] as? String == profile + ".request",
                  keys(p, "schema_version probe_id nonce expires_at model_id target_model_hash tokenizer_identity sampler_stage target_generation sampling_profile corpus_version threshold_version hardware_runtime_class support_selection normalization_basis k positions expected_decode_path native_mtp_runtime_tuple_sha256"),
                  p["schema_version"] as? String == profile + ".request", p["expected_decode_path"] as? String == "native_mtp",
                  let nonce = p["nonce"] as? String, !nonce.isEmpty,
                  p["support_selection"] as? String == "compute_integrity_support_selection_v1", p["normalization_basis"] as? String == "full_distribution",
                  p["sampler_stage"] as? String == "post_sampler_probabilities", let hardware = p["hardware_runtime_class"] as? String, !hardware.isEmpty,
                  integer(p["k"]) == 64, let positions = p["positions"] as? [[String: Any]], (1...8).contains(positions.count) else { throw LosslessnessProbeError.invalidPayload }
            var prompts: [String: String] = [:], refs: [String: String] = [:], seen = Set<String>()
            for q in positions {
                guard keys(q, "prompt_id prompt_ref position_index token_prefix_digest context_hash"), let id = q["prompt_id"] as? String, !id.isEmpty,
                      let ref = q["prompt_ref"] as? String, ref == "synthetic:native-path-binding-v1", ref.utf8.count <= 256,
                      let position = integer(q["position_index"]), seen.insert(id + ":" + String(position)).inserted,
                      prompts[id] == nil || prompts[id] == ref, refs[ref] == nil || refs[ref] == id else { throw LosslessnessProbeError.invalidPayload }
                for key in ["token_prefix_digest", "context_hash"] {
                    guard let s = q[key] as? String, s.hasPrefix("sha256:"), sha(String(s.dropFirst(7))) else { throw LosslessnessProbeError.invalidPayload }
                }
                prompts[id] = ref; refs[ref] = id
            }
            guard prompts.count <= 4 else { throw LosslessnessProbeError.invalidPayload }
        }
        return Request(profile: profile, payload: p, digest: expected)
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func result(_ request: Request, actual: [String: Any]) throws -> [String: Any] {
        let p = request.payload
        var out: [String: Any] = [
            "probe_id": request.probeID, "probe_request_digest": request.digest,
            "result_kind": "provider_inconclusive", "provider_reason_code": reason,
            "expected_decode_path": "native_mtp", "actual_decode_path": NSNull(),
            "native_mtp_runtime_tuple_sha256": p["native_mtp_runtime_tuple_sha256"]!,
            "actual_native_mtp_runtime_tuple_sha256": actual["native_mtp_runtime_tuple_sha256"] ?? NSNull(),
            "fallback_used": false, "identity_unavailable_reason": "native_execution_binding_unavailable",
        ]
        for key in ["model_id", "target_model_hash", "target_generation", "tokenizer_identity"] { out[key] = actual[key] ?? NSNull() }
        if request.profile == compute {
            out["schema_version"] = compute + ".result"; out["nonce"] = p["nonce"]
            for key in ["sampling_profile", "corpus_version", "threshold_version", "support_selection", "normalization_basis", "sampler_stage"] { out[key] = p[key] }
            // No measurement ran, so no covered hardware class was established.
            out["hardware_runtime_class"] = NSNull()
        } else { out["probe_nonce"] = p["probe_nonce"] }
        var envelope: [String: Any] = ["type": request.profile + ".result", "payload": out, "probe_request_digest": request.digest,
                                      "probe_result_digest": try digest(profile: request.profile, kind: "result", payload: out)]
        if request.profile == compute { envelope["schema_version"] = compute + ".result" } else { envelope["probe_id"] = request.probeID }
        return envelope
    }
}
