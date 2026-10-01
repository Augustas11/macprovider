#!/usr/bin/env python3
"""Compare an upstream watcher snapshot with its checked-in baseline."""

import json
import sys
from pathlib import Path
from typing import Any


BLOCKER_KEYS = (
    "mlx_swift_lm_406_compile_kv_offset",
    "mlx_swift_lm_364_gemma_moe",
    "mlx_swift_lm_312_quantized_cache_ownership",
    "mlx_swift_lm_453_typed_cache_storage",
    "mlx_swift_lm_424_speculative_cache_wrap",
    "mlx_swift_lm_518_remote_package_unsafe_flags",
    "mlx_swift_lm_351_qwen_mtp",
    "mlx_swift_lm_516_mtp_sliding_window",
    "mlx_swift_lm_505_mtp_sliding_window_rewind",
    "mlx_swift_lm_510_mamba_hybrid_rewind",
    "mlx_swift_lm_545_qwen38_mtp",
    "mlx_swift_lm_581_resumable_qwen_mtp",
    "mlx_swift_lm_584_rotating_cache_trim",
    "mlx_swift_lm_598_mtp_norm_double_shift",
    "mlx_swift_lm_620_cache_clear_first_token",
    "mlx_swift_lm_622_exact_rotating_cache_rewinds",
    "mlx_swift_lm_631_gdn_reload_leak",
    "mlx_swift_lm_633_qwen_gdn_epsilon",
    "mlx_swift_lm_645_public_mtp_transactions",
    "mlx_swift_lm_514_max_kv_size_hybrid",
    "mlx_swift_lm_335_modelcontainer_api_break",
)
RELEASE_PIN_KEYS = {
    "mlx_swift_lm_latest": "mlx_swift_lm",
    "mlx_swift_latest": "mlx_swift",
    "swift_transformers_latest": "swift_transformers",
    "swift_jinja_latest": "swift_jinja",
}


def material_changes(
    old: dict[str, Any] | None, new: dict[str, Any]
) -> tuple[bool, str]:
    if old is None:
        return True, "no prior baseline"

    reasons: list[str] = []
    if old.get("macprovider_pins") != new.get("macprovider_pins"):
        reasons.append("resolved production pin graph changed")
    if old.get("native_mtp_immutable_dependency_exception") != new.get(
        "native_mtp_immutable_dependency_exception"
    ):
        reasons.append("native MTP immutable-dependency exception changed")
    for key in BLOCKER_KEYS:
        if key not in old.get("blockers", {}):
            reasons.append(f"{key} added to upstream watch")
            continue
        previous = old["blockers"][key]
        current = new["blockers"][key]
        if previous.get("state") != current.get("state"):
            reasons.append(
                f"{key} state {previous.get('state')} -> {current.get('state')}"
            )
        if current.get("closed_at") and not previous.get("closed_at"):
            reasons.append(f"{key} closed")
        if current.get("merged_at") and not previous.get("merged_at"):
            reasons.append(f"{key} merged")

    for release_key, pin_key in RELEASE_PIN_KEYS.items():
        previous_tag = old["releases"][release_key].get("tag")
        current_tag = new["releases"][release_key].get("tag")
        if current_tag and current_tag != previous_tag:
            pin = new["macprovider_pins"].get(pin_key)
            reasons.append(
                f"{release_key} tag {previous_tag} -> {current_tag} (pin {pin})"
            )

    previous_signal = old.get("implementation_signals", {}).get(
        "kvcache_offset_graph_traceable"
    )
    current_signal = new.get("implementation_signals", {}).get(
        "kvcache_offset_graph_traceable"
    )
    if not previous_signal and current_signal:
        reasons.append("KVCache compile-fix heuristic now true")

    previous_native_mtp_release = old.get("implementation_signals", {}).get(
        "native_mtp_required_merges_in_latest_release"
    )
    current_native_mtp_release = new.get("implementation_signals", {}).get(
        "native_mtp_required_merges_in_latest_release"
    )
    if not previous_native_mtp_release and current_native_mtp_release:
        reasons.append("native MTP required merge commits are in latest mlx-swift-lm release")

    previous_native_mtp_api = old.get("implementation_signals", {}).get(
        "native_mtp_public_row_mapped_transactions_reviewed"
    )
    current_native_mtp_api = new.get("implementation_signals", {}).get(
        "native_mtp_public_row_mapped_transactions_reviewed"
    )
    if not previous_native_mtp_api and current_native_mtp_api:
        reasons.append("native MTP public row-mapped transaction API reviewed ready")

    return bool(reasons), "; ".join(reasons) if reasons else "unchanged"


def merge_snapshot(old: dict[str, Any] | None, new: dict[str, Any]) -> dict[str, Any]:
    """Overlay live fields without discarding reviewed schema-v2 metadata."""
    if old is None:
        return new
    merged = dict(old)
    for key, value in new.items():
        if key in (
            "blockers",
            "releases",
            "trackers",
            "implementation_signals",
            "native_mtp_immutable_dependency_exception",
        ) and isinstance(value, dict):
            reviewed = old.get(key, {})
            merged_rows = dict(reviewed)
            for name, live in value.items():
                previous = reviewed.get(name, {})
                if isinstance(previous, dict) and isinstance(live, dict):
                    merged_rows[name] = {**previous, **live}
                else:
                    merged_rows[name] = live
            merged[key] = merged_rows
        else:
            merged[key] = value
    return merged


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} BASELINE.json", file=sys.stderr)
        return 1
    try:
        new = json.load(sys.stdin)
        try:
            old = json.loads(Path(sys.argv[1]).read_text())
        except FileNotFoundError:
            old = None
        new = merge_snapshot(old, new)
        changed, reason = material_changes(old, new)
        if not changed and old is not None:
            new["last_changed_at"] = old.get("last_changed_at")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"failed to compare upstream watch state: {error}", file=sys.stderr)
        return 1

    print(json.dumps({"changed": changed, "reason": reason, "snapshot": new}, indent=2))
    return 2 if changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
