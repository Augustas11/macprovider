#!/usr/bin/env python3
"""Admit the exact Build 1 private Qwen tuple in the isolated staging rig."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request


LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-build1-private-staging"))
WT = pathlib.Path(os.environ["WT"])
MODEL_ID = os.environ["LAB_MLX_ID"]
HF_CACHE = pathlib.Path(os.environ["BUILD1_PRIVATE_HF_CACHE"])
PROVIDER_ID = "lab-1690-m6-provider"
ADMIN = "http://127.0.0.1:19102/admin/model-admission/decisions"


def post(url: str, token: str, body: dict) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:600]
        raise RuntimeError(f"staging admission request failed with HTTP {error.code}: {detail}") from error
    if not isinstance(payload, dict):
        raise RuntimeError("staging admission response was not an object")
    return payload


def write_evidence(name: str, payload: dict) -> None:
    path = LAB / "logs" / name
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)


def run_cli(*arguments: str) -> dict:
    cli = WT / "scripts" / "lab" / "1690-m6" / "cli.sh"
    command = [str(cli), *arguments]
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        raise RuntimeError(f"models command failed: {completed.stderr.strip()[:600]}")
    payload = json.loads(completed.stdout)
    if not isinstance(payload, dict):
        raise RuntimeError("models command response was not an object")
    return payload


def candidate_arguments() -> list[str]:
    return [
        "--config", str(LAB / "provider" / "config.yaml"),
        "--coordinator-url", "http://127.0.0.1:19102",
        "--mlx-cache-dir", str(HF_CACHE / "hub"),
        "--skip-ollama", "--skip-openai-compatible", "--skip-lmstudio", "--skip-llamacpp",
    ]


def require_exact_candidate(status: dict) -> None:
    if (
        status.get("provider_id") != PROVIDER_ID
        or status.get("served_model_ref") != MODEL_ID
        or status.get("catalog_model_key") != os.environ["LAB_ROW_KEY"]
    ):
        raise RuntimeError("models admission did not bind the exact private-Qwen tuple")


def current_status() -> dict:
    status = run_cli("models", "admission", "status", MODEL_ID, "--json", *candidate_arguments())
    require_exact_candidate(status)
    return status


def main() -> None:
    status = current_status()
    if status.get("admission_state") in {"not_offered", "offerable", "withdrawn", "revoked", "offer_rejected"}:
        status = run_cli("models", "offer", MODEL_ID, "--yes", "--json", *candidate_arguments())
        require_exact_candidate(status)
        write_evidence("build1-private-offer.json", status)

    for _ in range(40):
        if status.get("admission_state") not in {"offer_submitted", "sandbox_probe_only"}:
            break
        time.sleep(0.5)
        status = current_status()
    if status.get("admission_state") not in {"network_admitted_unsettled", "catalog_priced", "settlement_capable"}:
        raise RuntimeError(f"private candidate stopped at {status.get('admission_state')!r}")
    write_evidence("build1-private-admission-current.json", status)

    secrets = json.loads((LAB / "keys" / "secrets.json").read_text(encoding="utf-8"))
    candidate_id = status["candidate_id"]
    nonce = str(time.time_ns())
    if status.get("admission_state") == "network_admitted_unsettled":
        priced = post(ADMIN, secrets["operator_lab_a"], {
            "schema": "model_admission_decision_request.v1",
            "provider_id": PROVIDER_ID,
            "candidate_id": candidate_id,
            "next_state": "catalog_priced",
            "reason_code": "operator_lab_pool_priced",
            "expected_coordinator_event_id": status["coordinator_event_id"],
            "idempotency_key": f"build1-private-priced-{nonce}",
        })
        if priced.get("admission_state") != "catalog_priced":
            raise RuntimeError("private candidate did not reach catalog_priced")
        write_evidence("build1-private-catalog-priced.json", priced)
    else:
        priced = status

    if priced.get("admission_state") == "settlement_capable":
        approved = priced
    else:
        priced_head = priced["coordinator_event_id"]
        proposed = post(ADMIN, secrets["operator_lab_a"], {
            "schema": "model_admission_decision_request.v1",
            "provider_id": PROVIDER_ID,
            "candidate_id": candidate_id,
            "next_state": "settlement_capable",
            "reason_code": "operator_settlement",
            "expected_coordinator_event_id": priced_head,
            "idempotency_key": f"build1-private-settle-{nonce}",
        })
        pending_id = proposed.get("pending_decision_id")
        if proposed.get("admission_state") != "catalog_priced" or not isinstance(pending_id, str):
            raise RuntimeError("private settlement proposal did not enter dual-control pending state")
        write_evidence("build1-private-settlement-proposed.json", proposed)

        approved = post(f"{ADMIN}/{pending_id}/approve", secrets["operator_lab_b"], {
            "schema": "model_admission_decision_approve_request.v1",
            "provider_id": PROVIDER_ID,
            "candidate_id": candidate_id,
            "pending_decision_id": pending_id,
            "expected_coordinator_event_id": priced_head,
            "idempotency_key": f"build1-private-approve-{nonce}",
        })
    if approved.get("admission_state") != "settlement_capable":
        raise RuntimeError("private candidate did not reach settlement_capable")
    write_evidence("build1-private-settlement-capable.json", approved)
    print(json.dumps({
        "schema": "build1_private_staging_admission.v1",
        "provider_id": PROVIDER_ID,
        "candidate_id": candidate_id,
        "coordinator_event_id": approved.get("coordinator_event_id"),
        "state": approved.get("admission_state"),
        "bound_member": approved.get("bound_member"),
    }, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"build1-private-staging admit: {error}", file=sys.stderr)
        raise SystemExit(1)
