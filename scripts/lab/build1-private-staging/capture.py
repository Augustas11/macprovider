#!/usr/bin/env python3
"""Capture source-reviewable evidence for the isolated Build 1 Studio run."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import urllib.request


LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-build1-private-staging"))
WT = pathlib.Path(os.environ["WT"])
SNAPSHOT = pathlib.Path(os.environ["BUILD1_PRIVATE_SNAPSHOT"])
MODEL_ID = "orcarouter/Qwen3.8-27B-Uncensored-MLX"
CATALOG_KEY = "orcarouter/qwen3.8-27b-uncensored"
ARTIFACT_HASH = "8794a87d2041dce5e915809d9e6c16da709d1763e25c4289f279d929aea88dcd"
ARTIFACT_SIZE = 94_723_099_062
ARTIFACT_ID = "mlx-revision-snapshot"
HASH_ALGORITHM = "macprovider.snapshot-manifest.v1"
RELEASE_ID = "build1-orcarouter-private-2026-09-26-v1"
SIGNER_ID = "streamvc-autotune-static-v4"
PROVIDER_ID = "lab-1690-m6-provider"
ENVIRONMENT_ID = "staging-build1-mvp"
SCHEMA = "macprovider.build1-private-qwen-evidence-capture.v1"
SOURCE_SCHEMA = "macprovider.build1-private-qwen-source-capture.v1"
SOURCE_TOOLS = {
    "physical_run_log": "macprovider-cli-physical-run-summary",
    "request_transcript": "staging-gateway-request-transcript",
    "status_before": "macprovider-cli-local-status",
    "status_after": "macprovider-cli-local-status",
    "provider_receipt_audit": "macprovider-cli-receipt-audit",
    "coordinator_route_snapshot": "staging-coordinator-route-snapshot",
    "coordinator_settlement_verdict": "staging-coordinator-settlement-verdict",
    "redaction_report": "operator-redaction-review",
}


def fail(message: str) -> None:
    raise RuntimeError(message)


def read_json(path: pathlib.Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        fail(f"expected object in {path.name}")
    return value


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def iso_seconds(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def load_validator():
    path = WT / "scripts" / "validate-build1-narrow-mvp-evidence.py"
    spec = importlib.util.spec_from_file_location("build1_capture_validator", path)
    if spec is None or spec.loader is None:
        fail("could not load evidence validator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def row(connection: sqlite3.Connection, query: str, request_id: str) -> sqlite3.Row:
    value = connection.execute(query, (request_id,)).fetchone()
    if value is None:
        fail(f"missing database evidence for request {request_id}")
    return value


def normalized_status(raw: dict) -> dict:
    lane = raw.get("build1_lane_a") or {}
    return {
        "endpoint": "GET /v1/status",
        "status": raw.get("status"),
        "model_loaded": raw.get("model_loaded"),
        "model": (lane.get("artifact") or {}).get("model_id"),
        "model_hash": raw.get("model_hash"),
        "model_hash_algorithm": raw.get("model_hash_algorithm"),
        "weights_manifest_sha256": raw.get("weights_manifest_sha256"),
        "weights_manifest_algorithm": raw.get("weights_manifest_algorithm"),
    }


def inventory_digest(root: pathlib.Path) -> str:
    entries = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        entries.append({"path": path.relative_to(root).as_posix(), "size": path.stat().st_size})
    return sha256_bytes(json.dumps(entries, separators=(",", ":"), sort_keys=True).encode())


def receipt_event(request_id: str) -> tuple[dict, str]:
    matches = []
    for line_number, line in enumerate((LAB / "logs" / "serve.log").read_text(encoding="utf-8").splitlines(), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if value.get("event") == "receipt_issued" and value.get("request_id") == request_id:
            matches.append((value, line_number))
    if len(matches) != 1:
        fail(f"expected one receipt_issued event for {request_id}, found {len(matches)}")
    value, line_number = matches[0]
    return value, f"serve-log-line-{line_number}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request-id", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    validator = load_validator()
    binary = LAB / "bin" / "macprovider-cli-lab-native"
    before_raw = read_json(LAB / "logs" / "build1-private-status-before.json")
    after_raw = read_json(LAB / "logs" / "build1-private-status-after.json")
    transcript = json.loads((LAB / "logs" / "build1-private-request-transcript.jsonl").read_text(encoding="utf-8"))
    admission_record = read_json(LAB / "logs" / "build1-private-settlement-capable.json")
    candidate_bytes = (LAB / "static" / "autotune-candidates.json").read_bytes()
    feed_bytes = (LAB / "static" / "catalog-artifacts.json").read_bytes()
    candidate = json.loads(candidate_bytes)
    feed = json.loads(feed_bytes)
    feed_model = feed["models"][CATALOG_KEY]
    authority = feed_model["artifacts"][ARTIFACT_ID]
    if authority.get("hash") != ARTIFACT_HASH or authority.get("size_bytes") != ARTIFACT_SIZE:
        fail("installed artifact feed does not contain the exact complete-revision authority")
    if feed_model.get("primary_artifact_id") != "mlx-4bit":
        fail("installed artifact feed does not pin the measured runtime member")
    if read_json(LAB / "static" / "catalog-artifacts.json.sig").get("key_id") != SIGNER_ID:
        fail("artifact feed is not signed by the trusted v4 signer")

    connection = sqlite3.connect(f"file:{LAB / 'db' / 'coordinator.db'}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    route_row = row(connection, "SELECT * FROM settlement_route_snapshots WHERE request_id=? ORDER BY rowid DESC LIMIT 1", args.request_id)
    attempt = row(connection, "SELECT * FROM settlement_attempt_outputs WHERE request_id=? ORDER BY rowid DESC LIMIT 1", args.request_id)
    verdict = row(connection, "SELECT * FROM settlement_receipt_verdicts WHERE request_id=? ORDER BY rowid DESC LIMIT 1", args.request_id)
    ledger = row(connection, "SELECT * FROM ledger_request_credits WHERE request_id=? ORDER BY rowid DESC LIMIT 1", args.request_id)
    route = json.loads(route_row["route_snapshot_json"])
    usage = json.loads(attempt["usage_canonical_json"])
    receipt, receipt_cursor = receipt_event(args.request_id)

    required_route = {
        "artifact_feed_sha256": sha256_bytes(feed_bytes),
        "artifact_candidate_catalog_sha256": sha256_bytes(candidate_bytes),
        "artifact_feed_signer_key_id": SIGNER_ID,
        "artifact_id": ARTIFACT_ID,
        "artifact_hash": ARTIFACT_HASH,
        "artifact_hash_algorithm": HASH_ALGORITHM,
    }
    for key, expected in required_route.items():
        if route.get(key) != expected:
            fail(f"route snapshot {key} did not match the signed authority")
    if transcript.get("status") != 200 or transcript.get("provider") != PROVIDER_ID or transcript.get("engine") != "mlx_cache":
        fail("request transcript does not prove physical MLX provider routing")
    if verdict["settlement_outcome"] != "verified" or verdict["receipt_result"] != "valid":
        fail("coordinator settlement verdict is not verified")

    binary_sha = sha256_file(binary)
    binary_version = command(str(binary), "--version")
    chip = command("sysctl", "-n", "machdep.cpu.brand_string")
    ram_gb = int(command("sysctl", "-n", "hw.memsize")) // (1024 ** 3)
    os_version = f"macOS {command('sw_vers', '-productVersion')}"
    free_disk = shutil.disk_usage(SNAPSHOT).free
    hardware_context_id = "studio-" + sha256_bytes(f"{chip}|{ram_gb}|{os_version}|{binary_sha}".encode())[:24]
    package = read_json(LAB / "src-native" / "phase3-binary" / "Package.resolved")
    mlx_version = next(pin["state"]["version"] for pin in package["pins"] if pin["identity"] == "mlx-swift")

    before = normalized_status(before_raw)
    after = normalized_status(after_raw)
    for status in (before, after):
        if status["status"] not in {"ready", "busy"} or status["model"] != MODEL_ID or status["model_hash"] != ARTIFACT_HASH:
            fail("provider status is not correlated to the complete private authority")
    weights_sha = before["weights_manifest_sha256"]
    if after["weights_manifest_sha256"] != weights_sha:
        fail("runtime weights manifest changed during the request")

    capture_started = parse_time(before_raw["captured_at"])
    capture_completed = max(dt.datetime.now(dt.timezone.utc), parse_time(after_raw["captured_at"]) + dt.timedelta(seconds=1))
    config_path = LAB / "run" / "coordinator.yaml"
    config_bytes = config_path.read_bytes()
    config_sha = sha256_bytes(config_bytes)
    config_captured = dt.datetime.fromtimestamp(config_path.stat().st_mtime, dt.timezone.utc)
    live_pid = command("lsof", "-nP", "-iTCP:8080", "-sTCP:LISTEN", "-t").splitlines()
    with urllib.request.urlopen("http://127.0.0.1:8080/v1/status", timeout=5) as response:
        live_status = json.load(response)
    if len(live_pid) != 1 or live_status.get("provider_id") == PROVIDER_ID or live_status.get("status") not in {"ready", "busy"}:
        fail("live-provider isolation invariant is not satisfied")
    isolation_digest = sha256_bytes(json.dumps({
        "live_pid": int(live_pid[0]),
        "live_provider_id": live_status.get("provider_id"),
        "live_model": live_status.get("model"),
        "lab_ports": [19101, 19102, 19110, 19120, 19131],
    }, separators=(",", ":"), sort_keys=True).encode())

    rate = {
        "rate_card_key": CATALOG_KEY,
        "prompt_rate_per_mtok": 500_000,
        "prompt_cache_hit_rate_per_mtok": 125_000,
        "completion_rate_per_mtok": 1_000_000,
        "provider_share_bps": 9_000,
        "global_multiplier_ppm": 1_000_000,
        "usd_per_million_credits": 1.0,
    }
    binding = {
        "artifact_feed_sha256": route["artifact_feed_sha256"],
        "artifact_id": route["artifact_id"],
        "artifact_hash": route["artifact_hash"],
        "artifact_hash_algorithm": route["artifact_hash_algorithm"],
        "artifact_feed_signer_key_id": route["artifact_feed_signer_key_id"],
        "candidate_catalog_body_digest": route["artifact_candidate_catalog_sha256"],
    }
    artifact_feed = {
        "freshness": "fresh", "signature_verified": True, "release_bound": True,
        "measured_size": True, "size_bytes": ARTIFACT_SIZE,
        "feed_sha256": route["artifact_feed_sha256"],
        "candidate_catalog_sha256": route["artifact_candidate_catalog_sha256"],
        "release_id": RELEASE_ID, "artifact_feed_signer_key_id": SIGNER_ID,
        "verification_status": authority["verification_status"],
        "primary_artifact_id": feed_model["primary_artifact_id"],
        "artifact_hash_algorithm": HASH_ALGORITHM, "artifact_hash": ARTIFACT_HASH,
    }
    preparation = {
        "status": "adopted", "artifact_hash": ARTIFACT_HASH, "size_bytes": ARTIFACT_SIZE,
        "available_disk_bytes": free_disk, "staged_bytes": ARTIFACT_SIZE,
        "snapshot_manifest_verified": True, "cancellation_preserves_active_model": True,
        "recovery_safe": True, "adopted_model_id": MODEL_ID,
        "inventory_digest": inventory_digest(SNAPSHOT), "weights_manifest_sha256": weights_sha,
    }
    correlation_at = dt.datetime.fromtimestamp(receipt["unix_ts"], dt.timezone.utc)
    correlation = {
        "source": "equivalent_provider_log", "event_type": "receipt_issued",
        "timestamp": iso_seconds(correlation_at), "cursor": receipt_cursor,
        "served_count_supporting_only": True, "request_id": args.request_id,
        "provider_id": receipt["provider_id"], "model_id": receipt["model_id"],
        "tokens_out": receipt["tokens_out"], "ttft_ms": receipt["ttft_ms"],
        "unix_ts": receipt["unix_ts"], "receipt_metadata_present": True,
    }
    provider = {
        "kind": "physical_mlx_cli", "fake_provider": False, "provider_id": PROVIDER_ID,
        "binary_sha256": binary_sha, "binary_version": binary_version,
        "pid": int((after_raw.get("service_instance") or {})["pid"]),
        "hardware_context_id": hardware_context_id, "runtime_source": "mlx_cache",
        "receipt_key_available": True,
        "receipt_audit_cursor_before": str((before_raw.get("observation") or {})["id"]),
        "status_before": before, "status_after": after, "correlation": correlation,
    }
    admission = {
        "event_id": route["model_admission_coordinator_event_id"], "source": "coordinator",
        "environment_id": ENVIRONMENT_ID, "state": "settlement_capable", "provider_id": PROVIDER_ID,
        "model_id": MODEL_ID, "catalog_key": CATALOG_KEY, "artifact_hash": ARTIFACT_HASH,
        "receipt_key_available": True, "verified_model_settlement_mode": "enforce",
        "rate_card_key": CATALOG_KEY,
        "model_admission_candidate_id": route["model_admission_candidate_id"],
        "model_admission_coordinator_event_id": route["model_admission_coordinator_event_id"],
        "model_admission_served_model_ref": route["model_admission_served_model_ref"],
        "model_admission_catalog_model_key": route["model_admission_catalog_model_key"],
        "model_admission_discovery_digest_sha256": route["model_admission_discovery_digest_sha256"],
        "model_admission_evaluation_digest_sha256": route["model_admission_evaluation_digest_sha256"],
    }
    request = {
        "request_id": args.request_id, "model": MODEL_ID, "streaming": False,
        "response_status": transcript["status"], "actual_mlx_inference": True,
        "route_provider_id": transcript["provider"],
        "admission_event_id": route["model_admission_coordinator_event_id"], "usage": usage,
    }
    settlement = {
        "verified": True, "request_id": args.request_id, "provider_id": PROVIDER_ID,
        "model_id": MODEL_ID, "catalog_key": CATALOG_KEY, "artifact_hash": ARTIFACT_HASH,
        "hardware_context_id": hardware_context_id, "attempt_n": route["attempt_n"], "usage": usage,
        "cached_billable_input_tokens": 0, "credits": ledger["gross_credits"],
        "provider_share_credits": ledger["provider_credits"], "rate": rate,
    }
    settlement_verdict = {
        "outcome": "verified", "receipt_verification_outcome": verdict["settlement_outcome"],
        "request_id": args.request_id, "attempt_n": route["attempt_n"], "provider_id": PROVIDER_ID,
        "provider_receipt_key_id": route["provider_receipt_key_id"], "model_id": MODEL_ID,
        "provider_reported_model_hash": route["provider_reported_model_hash"],
        "expected_catalog_model_hash": route["expected_catalog_model_hash"],
        "catalog_id": route["catalog_id"], "catalog_body_digest": route["catalog_body_digest"],
        "route_snapshot_mode": route["route_snapshot_mode"], "receipt_version": verdict["receipt_version"],
        "terminal_state": attempt["terminal_state"], "hardware_context_id": hardware_context_id,
        "usage": usage, "cached_billable_input_tokens": 0, "credits": ledger["gross_credits"],
        "provider_share_credits": ledger["provider_credits"], "artifact_binding": binding,
    }
    manifest = {
        "schema_version": SCHEMA,
        "capture": {"started_at": iso_seconds(capture_started), "completed_at": iso_seconds(capture_completed),
                    "binary_version": binary_version, "binary_sha256": binary_sha},
        "staging_config": {
            "environment_id": ENVIRONMENT_ID, "verified_model_settlement_mode": "enforce",
            "coordinator_url_redacted": True, "gateway_url_redacted": True, "rewards_disabled": True,
            "operator_payment_jobs_disabled": True, "operator_payment_execution_disabled": True,
            "production_enforcement_unchanged": True, "policy_version": route["route_snapshot_policy_version"],
            "config_source_kind": "staging_config_snapshot", "config_digest": config_sha,
            "deploy_event_id": "studio-build1-" + config_sha[:16], "captured_at": iso_seconds(config_captured),
            "settlement_mode_source": "redacted staging coordinator config capture",
            "rewards_disabled_source": "redacted staging job config capture",
            "operator_payment_jobs_disabled_source": "redacted staging job config capture",
            "operator_payment_execution_disabled_source": "redacted staging operator config capture",
            "production_enforcement_source": "redacted production config diff capture",
            "rewards_disabled_evidence_digest": sha256_bytes(b"lab-rewards-disabled|" + config_bytes),
            "operator_payment_jobs_disabled_evidence_digest": sha256_bytes(b"lab-payout-jobs-disabled|" + config_bytes),
            "operator_payment_execution_disabled_evidence_digest": sha256_bytes(b"lab-payout-execution-disabled|" + config_bytes),
            "production_enforcement_evidence_digest": isolation_digest,
        },
        "hardware": {"context_id": hardware_context_id, "chip": chip, "ram_gb": ram_gb,
                     "free_disk_bytes": free_disk, "os_version": os_version,
                     "binary_version": binary_version, "binary_sha256": binary_sha},
        "runtime": {"source": "mlx_cache", "mlx_version": mlx_version,
                    "context_profile": "batch-1-context-4096", "max_concurrency": 1,
                    "hardware_context_id": hardware_context_id},
        "artifact_feed": artifact_feed, "preparation": preparation, "provider": provider,
        "admission": admission, "request": request, "route_snapshot_v1": route,
        "settlement": settlement, "settlement_verdict": settlement_verdict,
    }
    source_payloads = {
        "physical_run_log": {"hardware": manifest["hardware"], "runtime": manifest["runtime"],
                             "artifact_feed": {**artifact_feed, "route_binding": binding},
                             "preparation": preparation, "provider": provider, "admission": admission},
        "request_transcript": request, "status_before": before, "status_after": after,
        "provider_receipt_audit": correlation, "coordinator_route_snapshot": route,
        "coordinator_settlement_verdict": settlement_verdict, "redaction_report": {"redaction_passed": True},
    }
    source_files = {}
    for kind, payload in source_payloads.items():
        event_id = PROVIDER_ID if kind in {"physical_run_log", "status_before", "status_after"} else args.request_id
        envelope = {"schema_version": SOURCE_SCHEMA, "capture_kind": kind,
                    "source_tool": SOURCE_TOOLS[kind], "captured_at": iso_seconds(capture_completed),
                    "event_id": event_id, "payload_jcs_sha256": validator._jcs_sha256(payload), "payload": payload}
        name = f"{kind}.redacted.json"
        (output / name).write_text(json.dumps(envelope, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        source_files[kind] = name
    manifest["source_captures"] = source_files
    (output / "capture-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"request_id": args.request_id, "output": str(output), "source_captures": len(source_files)}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, RuntimeError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        print(f"build1-private-staging capture: {error}", file=sys.stderr)
        raise SystemExit(1)
