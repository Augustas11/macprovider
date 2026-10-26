#!/usr/bin/env python3
"""Adapt actual isolated LAB records into canonical steps 04–10, never a full journey.

The input artifacts remain private. Output retains check names and byte identities,
not raw prompts, tensors, errors or paths. Final redaction review is still required.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
HEX = re.compile(r"[0-9a-f]{64}\Z")
RAW_IDS = {
    "04": "step-04-serial-token-oracle", "05": "step-05-cache-state-boundary",
    "06": "step-06-streaming-stop", "07": "step-07-08-mixed-multirow-capacity",
    "08": "step-08-capacity-and-depth-zero", "09": "step-09-cancellation", "10": "step-10-warm-swap",
}
CANON = dict(RAW_IDS, **{"07": "step-07-mixed-multirow"})
BASE = {
    "04": {"acceptance_all_and_none_observed", "partial_acceptance_tuple_inapplicable"} | {f"greedy-{i}.token_ids_equal" for i in range(3)},
    "05": {f"{row}.{name}" for row in ("journey-reject-all-0", "journey-boundary-0", "journey-boundary-1") for name in
        ("parity", "state_probe_tokens_equal", "state_probe_terminal_equal", "aligned_prefix_cache_digest_comparison", "independent_drafter_recomputation_observed")},
    "06": {"stop_terminal_observed", "length_terminal_observed", "eos_terminal_observed",
        "stop_round_boundary.spans_multiple_native_finalize_rounds", "early_consumer_stop.cancelled_not_completed",
        "postoutput_fault.failed_not_completed", "postoutput_fault.after_visible_output", "postoutput_fault.counter_incremented", "postoutput_fault.hook_fired"},
    "07": {"mixed_paths_in_one_batch", "depth_zero_hold_observed", "holds_resolved", "batch_depth_reached_qualified_slots", "slots_unchanged", "prompt_cap.parity", "prompt_cap.selected_ordinary"},
    "08": {"advertised_slots_unchanged", "pre_admission_capacity_withdrawn", "pre_admission_ordinary_capacity_selection", "pre_admission_ordinary_parity", "pre_admission_capacity_restored"},
    "09": {"terminal_observer_installed", "cache_observer_installed", "cancelled_stream_no_hot_persistence", "cancelled_not_completed", "scheduler_released_row", "follow_up_parity", "follow_up_native"},
    "10": {"old_request_started_before_swap", "old_request_start_native_enabled", "old_request_observed_inflight_at_swap", "old_request_served_old_tuple", "old_request_parity", "old_request_native_counters_bound", "same_runtime_alias_differs", "same_runtime_identity_published", "same_runtime_native_disabled", "new_request_no_native_counters", "new_request_not_native_admitted"},
}
CANON_CHECKS = {
    "04": ("exact_greedy_token_parity",), "05": ("exact_transaction_rewind",),
    "06": ("streaming_and_terminal_parity", "no_post_output_path_switch"),
    "07": ("mixed_multirow_isolation", "no_cross_row_state_bleed"),
    "08": ("capacity_bound", "no_memory_overcommit"),
    "09": ("cancellation_release", "cache_persistence_exclusion"), "10": ("warm_swap_tuple_isolation",),
}

class Refusal(ValueError):
    pass

def require(condition, message):
    if not condition:
        raise Refusal(message)

def strict(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(Refusal("nonfinite JSON")))

def sha(data):
    return hashlib.sha256(data).hexdigest()

def module(root, name, path):
    spec = importlib.util.spec_from_file_location(name, root / path)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value

def required_checks(number, entry):
    checks = set(BASE[number])
    if number == "07":
        for row in range(entry["qualified_slots"]):
            checks |= {f"journey-mixed-{row}.parity", f"journey-mixed-{row}.ordinary_control_reproducible"}
        if entry["request_feature_profile"] == "native_mtp_sampled_text_v1":
            for control in ("sampled", "tools", "history", "reasoning"):
                prefix = f"journey-profile-{control}"
                checks |= {f"{prefix}.native_admitted", f"{prefix}.mixed_width", f"{prefix}.profile_parity"}
                checks |= {f"{prefix}-peer-{row}.profile_parity" for row in range(1, entry["qualified_slots"])}
    if number == "08":
        for name in ("depth-zero", "depth-zero-exhausted", "before-output-exhausted"):
            prefix = f"journey-budget-{name}"
            checks |= {f"{prefix}.{key}" for key in ("observer_installed", "native_admitted", "injection_reached", "higher_depth_refused", "no_overcommit", "exactly_one_terminal", "row_released")}
            checks |= {f"{prefix}.{key}" for key in (("depth_zero_admitted", "ordinary_parity") if name == "depth-zero" else ("depth_zero_refused", "bounded_capacity_failure", "no_persistent_payload"))}
            checks.add(f"{prefix}." + ("pre_output_failure_emitted_zero" if name == "before-output-exhausted" else "fault_after_stickiness"))
    if number == "09":
        for name in ("after-proposal", "after-verify", "before-finalize", "0"):
            prefix = f"journey-cancel-{name}"
            checks |= {f"{prefix}.{key}" for key in ("exactly_one_terminal", "no_persistent_payload", "native_cache_lease_excluded")}
            if name != "0":
                checks |= {f"{prefix}.{key}" for key in ("native_admitted", "trap_fired", "cancelled_not_completed", "no_later_native_phase_after_cancel", "pre_post_abort_cache_and_drafter_stable", "after_abort_fresh_drafter_recomputation", "scheduler_released_row")}
    return checks

def adapt_record(document, data_sha, entry, tuple_sha, sidecar_sha):
    require(document.get("schema") == "macprovider.native-mtp-journey-hardware-result.v1", "hardware schema")
    require(document.get("evidence_class") == "lab_isolated_no_join" and document.get("lab_binary_release_candidate") is False, "LAB provenance")
    require(document.get("signed_policy_inputs") is True, "ephemeral fixture policy is not signed-policy evidence")
    require(document.get("journey_complete") is False, "LAB record must not claim a full journey")
    require(document.get("admission_tuple_sha256") == tuple_sha and document.get("admission_sidecar_sha256") == sidecar_sha, "signed tuple binding")
    for observed, key in (("policy_source_commit", "source_commit"), ("policy_binary_sha256", "reproducible_build_sha256"), ("policy_cdhash", "live_executable_cdhash"), ("lab_decode_path_digest", "decode_path_digest"), ("lab_metallib_sha256", "metallib_sha256"), ("model_id", "model_key"), ("mtp_sha256", "artifact_hash"), ("tokenizer_sha256", "tokenizer_sha256"), ("qualified_slots", "qualified_slots"), ("max_native_active_rows", "max_native_active_rows"), ("max_prompt_tokens", "max_prompt_tokens"), ("request_feature_profile", "request_feature_profile")):
        require(document.get(observed) == entry.get(key), f"LAB tuple differs: {observed}")
    require(document.get("target_sha256") == entry["ordinary_baseline"]["artifact_hash"], "LAB target differs")
    require(isinstance(document.get("lab_binary_sha256"), str) and HEX.fullmatch(document["lab_binary_sha256"]), "actual LAB binary hash missing")
    steps = document.get("steps")
    require(isinstance(steps, list), "raw steps missing")
    output = {}
    for number, raw_id in RAW_IDS.items():
        matches = [step for step in steps if isinstance(step, dict) and step.get("step_id") == raw_id]
        require(len(matches) <= 1, "duplicate raw step")
        if not matches:
            continue
        step = matches[0]
        checks = step.get("checks")
        require(step.get("status") == "pass" and step.get("uncovered_contract") == [], f"raw step incomplete: {raw_id}")
        require(isinstance(checks, dict) and bool(checks) and all(type(value) is bool and value for value in checks.values()), f"raw step checks failed: {raw_id}")
        require(required_checks(number, entry) <= checks.keys(), f"raw step required observations missing: {raw_id}")
        output[CANON[number]] = {
            "schema_version": "macprovider.native-mtp-journey-step.v1", "step_id": CANON[number],
            "status": "pass", "checks": {key: True for key in CANON_CHECKS[number]},
            "details": {"evidence_class": "lab_isolated_no_join", "lab_binary_release_candidate": False,
                "lab_binary_sha256": document["lab_binary_sha256"], "lab_decode_path_digest": document["lab_decode_path_digest"],
                "lab_metallib_sha256": document["lab_metallib_sha256"], "signed_policy_tuple_sha256": tuple_sha,
                "raw_result_sha256": data_sha, "raw_step_id": raw_id,
                "observed_checks": {key: checks[key] for key in sorted(required_checks(number, entry))}},
        }
    return output

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, default=ROOT)
    p.add_argument("--raw", type=Path, action="append", required=True)
    p.add_argument("--sidecar", type=Path, required=True)
    p.add_argument("--entry-index", type=int, required=True)
    p.add_argument("--acceptance-result", type=Path)
    p.add_argument("--acceptance-policy", type=Path)
    p.add_argument("--acceptance-corpus", type=Path)
    p.add_argument("--output-dir", type=Path, required=True)
    args = p.parse_args()
    evidence = module(args.root, "journey_evidence", "scripts/native_mtp_journey_evidence.py")
    sidecar = args.sidecar.read_bytes()
    entry, tuple_sha = evidence.validated_sidecar_entry(sidecar, args.entry_index)
    output = {}
    for path in args.raw:
        data = path.read_bytes()
        for key, value in adapt_record(strict(data), sha(data), entry, tuple_sha, sha(sidecar)).items():
            require(key not in output, "duplicate canonical step across hardware records")
            output[key] = value
    require(output, "no complete LAB steps")
    if "step-04-serial-token-oracle" in output and entry["request_feature_profile"] == "native_mtp_sampled_text_v1":
        require(all((args.acceptance_result, args.acceptance_policy, args.acceptance_corpus)), "sampled step04 requires actual frozen R005 records")
        core = module(args.root, "binding_bundle", "scripts/native_mtp_binding_bundle.py")
        result, policy, corpus = (path.read_bytes() for path in (args.acceptance_result, args.acceptance_policy, args.acceptance_corpus))
        require(strict(policy).get("provider_commit") == entry["source_commit"], "R005 current-source binding or an explicit separately validated source-reuse adapter is required")
        core.validate_acceptance(strict(result), strict(policy), strict(corpus), entry, policy_sha=sha(policy), corpus_sha=sha(corpus))
        output["step-04-serial-token-oracle"]["details"]["r005_result_sha256"] = sha(result)
        output["step-04-serial-token-oracle"]["details"]["r005_policy_sha256"] = sha(policy)
        output["step-04-serial-token-oracle"]["details"]["r005_corpus_sha256"] = sha(corpus)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for key, value in output.items():
        path = args.output_dir / (key + ".json")
        require(not path.exists(), "step output exists; immutable proof is never overwritten")
        with path.open("x") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
    print(json.dumps({"adapted_steps": sorted(output), "journey_complete": False}))

if __name__ == "__main__":
    try:
        main()
    except (Refusal, ValueError, OSError) as exc:
        raise SystemExit("refused: " + str(exc))
