#!/usr/bin/env python3
"""Continuous-batching activation gate for catalog releases and CLI promotion.

A catalog release carries a signed continuous-batching policy. A provider CLI
batches in production only while that policy authorizes its exact runtime
tuple (model, tokenizer, chat template, cache class, kv dtype, MoE dispatch,
hardware class, metallib, kernel, provider CLI version and live executable
cdhash). Activating a release whose policy no longer authorizes a tuple that
providers are batching on silently drops them to serial serving.

Subcommands (exit 0 pass, 1 refusal to judge, 4 at-risk, 5 capacity drop):

  preflight  /poolz + incoming policy (+ live policy) -> which active tuples
             the incoming policy would de-authorize. Precise for providers
             that report `continuous_batching` on /poolz; for the rest (or a
             coordinator that predates the field) it falls back to the static
             live->incoming policy diff for the models they serve.
  snapshot   /poolz -> CB-active provider count and aggregate free slots.
  compare    two snapshots -> exit 5 when CB-active providers or free slots
             dropped beyond the tolerance.

Everything printed is content-free: provider ids, model ids, counts and
reason codes only. Shared by deploy-pearl-vps.sh, the Pearl updater and the
catalog-content lane (shipped through scripts/catalog-verifier-bundle.txt).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys

SCHEMA = "macprovider.cb-activation-gate.v1"
POLICY_SCHEMA = "macprovider.continuous-batching-policy.v1"
MAX_JSON_BYTES = 16 * 1024 * 1024
# The provider CLI accepts a policy generated at most this far in the future.
MAX_CLOCK_SKEW = _dt.timedelta(minutes=10)
# Authorization the gate can reason about: the coordinator-served signed
# policy. Other sources (baked empty-off) are unaffected by an activation.
COORDINATOR_SOURCE = "coordinator"
SUMMARY_ACTIVE_KEY = "continuous_batching_active"
SUMMARY_REPORTING_KEY = "continuous_batching_reporting"
IDENTITY_FIELDS = (
    "model_id",
    "model_sha256",
    "tokenizer_sha256",
    "chat_template_sha256",
    "cache_class",
    "kv_dtype",
    "requires_moe",
    "hardware_class",
    "metallib_sha256",
    "kernel_identifier",
    "provider_cli_version",
    "live_executable_cdhash",
)
SAFE_TEXT = re.compile(r"[\x21-\x7e]{1,256}")


class GateError(Exception):
    """The gate cannot judge: malformed or unreadable input (fail closed)."""


def _load(path: str) -> object:
    try:
        with open(path, "rb") as fh:
            data = fh.read(MAX_JSON_BYTES + 1)
    except OSError as exc:
        raise GateError(f"cannot read {path}: {exc.strerror}") from exc
    if len(data) > MAX_JSON_BYTES:
        raise GateError(f"{path} is too large")
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise GateError(f"{path} is not JSON") from exc


def _parse_ts(value: object, label: str) -> _dt.datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise GateError(f"{label} must be an RFC3339 UTC timestamp")
    try:
        return _dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=_dt.timezone.utc)
    except ValueError as exc:
        raise GateError(f"{label} must be an RFC3339 UTC timestamp") from exc


def _text(value: object, label: str) -> str:
    if not isinstance(value, str) or SAFE_TEXT.fullmatch(value) is None:
        raise GateError(f"{label} must be a short printable string")
    return value


def _opt_text(value: object, label: str) -> str | None:
    return None if value is None else _text(value, label)


def policy_identities(policy: object, now: _dt.datetime) -> set[tuple]:
    """Runtime identities the policy authorizes at `now` (rollout != off).

    The tuple_sha256 binds the release id and timestamps, so it changes on
    every release; identities compare the fields the CLI matches instead.
    An expired or future-dated policy authorizes nothing, as on the CLI.
    """
    if not isinstance(policy, dict) or policy.get("schema_version") != POLICY_SCHEMA:
        raise GateError("continuous-batching policy has the wrong schema_version")
    entries = policy.get("entries")
    if not isinstance(entries, list):
        raise GateError("continuous-batching policy entries must be a list")
    generated = _parse_ts(policy.get("generated_at"), "policy generated_at")
    expires = _parse_ts(policy.get("expires_at"), "policy expires_at")
    out: set[tuple] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise GateError(f"policy entries[{index}] is not an object")
        rollout = entry.get("rollout")
        if rollout not in ("off", "canary", "on"):
            raise GateError(f"policy entries[{index}].rollout is invalid")
        provenance = entry.get("provenance")
        if not isinstance(provenance, dict):
            raise GateError(f"policy entries[{index}].provenance is not an object")
        if not isinstance(entry.get("requires_moe"), bool):
            raise GateError(f"policy entries[{index}].requires_moe must be a bool")
        identity = tuple(
            entry["requires_moe"] if field == "requires_moe" else _text(
                provenance.get(field) if field in ("provider_cli_version", "live_executable_cdhash") else entry.get(field),
                f"policy entries[{index}].{field}",
            )
            for field in IDENTITY_FIELDS
        )
        if rollout != "off":
            out.add(identity)
    if generated > now + MAX_CLOCK_SKEW or not now < expires:
        return set()
    return out


def _runtime_identity(raw: object, label: str) -> tuple | None:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise GateError(f"{label} is not an object")
    if not isinstance(raw.get("requires_moe"), bool):
        raise GateError(f"{label}.requires_moe must be a bool")
    return tuple(
        raw["requires_moe"] if field == "requires_moe" else _opt_text(raw.get(field), f"{label}.{field}")
        for field in IDENTITY_FIELDS
    )


def pool_snapshot(poolz: object) -> dict:
    if not isinstance(poolz, dict) or not isinstance(poolz.get("pool"), list):
        raise GateError("/poolz has no pool list")
    summary = poolz.get("summary")
    if not isinstance(summary, dict):
        raise GateError("/poolz has no summary")
    reports = SUMMARY_ACTIVE_KEY in summary and SUMMARY_REPORTING_KEY in summary
    providers = []
    seen: set[str] = set()
    for row in poolz["pool"]:
        if not isinstance(row, dict):
            raise GateError("/poolz pool row is not an object")
        pid = _text(row.get("provider_id"), "/poolz provider_id")
        if pid in seen:
            raise GateError("/poolz lists a provider twice")
        seen.add(pid)
        cb_raw = row.get("continuous_batching")
        cb = None
        if cb_raw is not None:
            if not isinstance(cb_raw, dict) or not isinstance(cb_raw.get("active"), bool):
                raise GateError(f"/poolz continuous_batching for {pid} is malformed")
            cb = {
                "active": cb_raw["active"],
                "authorization_source": _opt_text(cb_raw.get("authorization_source"), "authorization_source"),
                "identity": _runtime_identity(cb_raw.get("runtime_tuple"), f"{pid} runtime_tuple"),
            }
        slots_free = row.get("slots_free", 0)
        if type(slots_free) is not int or slots_free < 0:
            raise GateError(f"/poolz slots_free for {pid} is malformed")
        model_id = row.get("model_id")
        providers.append({
            "provider_id": pid,
            "model_id": model_id if isinstance(model_id, str) else "",
            "ready": row.get("state") == "ready" and row.get("routing_eligible") is True,
            "slots_free": slots_free,
            "cb": cb,
        })
    return {
        "coordinator_reports_cb": reports,
        "providers": providers,
        "cb_active_ids": sorted(p["provider_id"] for p in providers if p["cb"] and p["cb"]["active"]),
        "providers_reporting": sum(1 for p in providers if p["cb"] is not None),
        "free_slots": sum(p["slots_free"] for p in providers if p["ready"]),
        "ready": sum(1 for p in providers if p["ready"]),
    }


def _summary(identity: tuple) -> dict:
    return {"model_id": identity[0], "hardware_class": identity[7], "provider_cli_version": identity[10]}


def preflight(poolz: object, incoming: object, live: object | None, now: _dt.datetime) -> dict:
    snap = pool_snapshot(poolz)
    incoming_ids = policy_identities(incoming, now)
    live_ids = policy_identities(live, now) if live is not None else set()
    at_risk: list[dict] = []
    unreported = [p for p in snap["providers"] if p["cb"] is None]
    for p in snap["providers"]:
        cb = p["cb"]
        if cb is None or not cb["active"] or cb["authorization_source"] != COORDINATOR_SOURCE:
            continue
        if cb["identity"] is None:
            at_risk.append({"kind": "active_tuple_unreported", "provider_id": p["provider_id"], "model_id": p["model_id"]})
        elif cb["identity"] not in incoming_ids:
            at_risk.append({"kind": "active_tuple_deauthorized", "provider_id": p["provider_id"], **_summary(cb["identity"])})
    dropped = sorted(live_ids - incoming_ids, key=repr)
    for identity in dropped:
        exposed = sorted(p["provider_id"] for p in unreported if p["model_id"].lower() == str(identity[0]).lower())
        if exposed:
            at_risk.append({"kind": "live_tuple_dropped", "providers": exposed, **_summary(identity)})
    warnings = []
    if not snap["coordinator_reports_cb"]:
        warnings.append("coordinator predates continuous_batching reporting; only the live->incoming policy diff was checked")
    if unreported:
        warnings.append(f"{len(unreported)} provider(s) do not report continuous_batching; judged by the policy diff only")
    return {
        "schema": SCHEMA,
        "coordinator_reports_cb": snap["coordinator_reports_cb"],
        "providers_total": len(snap["providers"]),
        "providers_reporting": snap["providers_reporting"],
        "cb_active": len(snap["cb_active_ids"]),
        "free_slots": snap["free_slots"],
        "incoming_authorized_tuples": len(incoming_ids),
        "live_authorized_tuples": len(live_ids),
        "dropped_tuples": [_summary(i) for i in dropped],
        "at_risk": at_risk,
        "warnings": warnings,
    }


def snapshot_record(poolz: object) -> dict:
    snap = pool_snapshot(poolz)
    return {
        "schema": SCHEMA,
        "coordinator_reports_cb": snap["coordinator_reports_cb"],
        "cb_active_ids": snap["cb_active_ids"],
        "providers_reporting": snap["providers_reporting"],
        "free_slots": snap["free_slots"],
        "ready": snap["ready"],
    }


def _snapshot_from(obj: object, label: str) -> dict:
    if not isinstance(obj, dict) or obj.get("schema") != SCHEMA:
        raise GateError(f"{label} is not a {SCHEMA} snapshot")
    ids = obj.get("cb_active_ids")
    if not isinstance(ids, list) or not all(isinstance(i, str) for i in ids):
        raise GateError(f"{label} cb_active_ids is malformed")
    for key in ("free_slots", "ready"):
        if type(obj.get(key)) is not int or obj[key] < 0:
            raise GateError(f"{label} {key} is malformed")
    if not isinstance(obj.get("coordinator_reports_cb"), bool):
        raise GateError(f"{label} coordinator_reports_cb is malformed")
    return obj


def compare(before: object, after: object, *, max_cb_drop: int, max_free_drop_pct: int, free_slack: int) -> dict:
    b = _snapshot_from(before, "before snapshot")
    a = _snapshot_from(after, "after snapshot")
    failures = []
    lost = sorted(set(b["cb_active_ids"]) - set(a["cb_active_ids"]))
    cb_judged = b["coordinator_reports_cb"] and a["coordinator_reports_cb"]
    if cb_judged and len(b["cb_active_ids"]) - len(a["cb_active_ids"]) > max_cb_drop:
        failures.append("cb_active_dropped")
    floor = b["free_slots"] * (100 - max_free_drop_pct) // 100 - free_slack
    if a["free_slots"] < floor:
        failures.append("free_slots_dropped")
    return {
        "schema": SCHEMA,
        "cb_judged": cb_judged,
        "cb_active_before": len(b["cb_active_ids"]),
        "cb_active_after": len(a["cb_active_ids"]),
        "cb_lost_providers": lost,
        "free_slots_before": b["free_slots"],
        "free_slots_after": a["free_slots"],
        "free_slots_floor": max(floor, 0),
        "failures": failures,
    }


def _now(raw: str | None) -> _dt.datetime:
    if raw is None:
        return _dt.datetime.now(_dt.timezone.utc)
    return _parse_ts(raw, "--now")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("preflight", help="exit 4 if the incoming policy de-authorizes an active tuple")
    p.add_argument("--poolz-json", required=True)
    p.add_argument("--incoming-policy-json", required=True)
    p.add_argument("--live-policy-json", help="the live release's policy; omit when no release is live")
    p.add_argument("--now", help=argparse.SUPPRESS)
    p = sub.add_parser("snapshot", help="CB-active providers and free slots from /poolz")
    p.add_argument("--poolz-json", required=True)
    p = sub.add_parser("compare", help="exit 5 if CB-active providers or free slots dropped")
    p.add_argument("--before", required=True)
    p.add_argument("--after", required=True)
    p.add_argument("--max-cb-active-drop", type=int, default=0)
    p.add_argument("--max-free-slots-drop-pct", type=int, default=25)
    p.add_argument("--free-slots-slack", type=int, default=2)
    args = parser.parse_args(argv)
    try:
        if args.cmd == "preflight":
            live = _load(args.live_policy_json) if args.live_policy_json else None
            result = preflight(_load(args.poolz_json), _load(args.incoming_policy_json), live, _now(args.now))
            for warning in result["warnings"]:
                print(f"cb_activation_gate: WARNING: {warning}", file=sys.stderr)
            print(json.dumps(result, sort_keys=True))
            return 4 if result["at_risk"] else 0
        if args.cmd == "snapshot":
            print(json.dumps(snapshot_record(_load(args.poolz_json)), sort_keys=True))
            return 0
        for value in (args.max_cb_active_drop, args.max_free_slots_drop_pct, args.free_slots_slack):
            if value < 0 or value > 100:
                raise GateError("tolerances must be between 0 and 100")
        result = compare(
            _load(args.before),
            _load(args.after),
            max_cb_drop=args.max_cb_active_drop,
            max_free_drop_pct=args.max_free_slots_drop_pct,
            free_slack=args.free_slots_slack,
        )
        print(json.dumps(result, sort_keys=True))
        return 5 if result["failures"] else 0
    except GateError as exc:
        print(f"cb_activation_gate: refusing: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
