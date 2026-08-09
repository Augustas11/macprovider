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
    for key in BLOCKER_KEYS:
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

    return bool(reasons), "; ".join(reasons) if reasons else "unchanged"


def merge_snapshot(old: dict[str, Any] | None, new: dict[str, Any]) -> dict[str, Any]:
    """Overlay live fields without discarding reviewed schema-v2 metadata."""
    if old is None:
        return new
    merged = dict(old)
    for key, value in new.items():
        if key in ("blockers", "releases") and isinstance(value, dict):
            reviewed = old.get(key, {})
            merged_rows = dict(reviewed)
            for name, live in value.items():
                merged_rows[name] = {**reviewed.get(name, {}), **live}
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
        changed, reason = material_changes(old, new)
        new = merge_snapshot(old, new)
        if not changed and old is not None:
            new["last_changed_at"] = old.get("last_changed_at")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"failed to compare upstream watch state: {error}", file=sys.stderr)
        return 1

    print(json.dumps({"changed": changed, "reason": reason, "snapshot": new}, indent=2))
    return 2 if changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
