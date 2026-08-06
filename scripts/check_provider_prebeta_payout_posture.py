#!/usr/bin/env python3
"""Validate redacted provider-prebeta payout posture evidence."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "macprovider.provider-prebeta-payout-posture-evidence.v1"
PROVIDER_PREBETA_JOURNEY_ID = "JOURNEY-PROVIDER-PREBETA-ADMISSION"
SPEC016_PAYOUT_JOURNEY_ID = "JOURNEY-SPEC-016-PAYOUT-ADDRESS-REGISTRATION"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SECRET_PATTERNS = (
    re.compile(r"mp-[0-9a-f]{32,}", re.IGNORECASE),
    re.compile(r"0x[0-9a-f]{40}", re.IGNORECASE),
    re.compile(r"\bBearer\s+", re.IGNORECASE),
    re.compile(r"\btoken_hash\b", re.IGNORECASE),
    re.compile(r"\braw_signature\b", re.IGNORECASE),
    re.compile(r"\bprivate_key\b", re.IGNORECASE),
)


def parse_utc(value: Any, field: str, errors: list[str]) -> datetime | None:
    if not isinstance(value, str):
        errors.append(f"{field}: must be an RFC3339 UTC string")
        return None
    text = value
    if not text.endswith("Z"):
        errors.append(f"{field}: must end with Z")
        return None
    body = text[:-1]
    if "." in body:
        prefix, fraction = body.split(".", 1)
        body = f"{prefix}.{fraction[:6]}"
    try:
        return datetime.fromisoformat(body).replace(tzinfo=timezone.utc)
    except ValueError:
        errors.append(f"{field}: invalid UTC timestamp")
        return None


def require_object(value: Any, field: str, errors: list[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        errors.append(f"{field}: must be an object")
        return {}
    return value


def require_sha256(value: Any, field: str, errors: list[str]) -> None:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        errors.append(f"{field}: must be a 64-character lowercase sha256 hex string")


def require_bool(value: Any, expected: bool, field: str, errors: list[str]) -> None:
    if value is not expected:
        errors.append(f"{field}: must be {str(expected).lower()}")


def require_non_negative_int(value: Any, field: str, errors: list[str]) -> None:
    if not isinstance(value, int) or value < 0:
        errors.append(f"{field}: must be a non-negative integer")


def scan_secret_patterns(path: Path, errors: list[str]) -> None:
    payload = path.read_text(encoding="utf-8")
    for pattern in SECRET_PATTERNS:
        if pattern.search(payload):
            errors.append(f"{path}: contains forbidden secret-like pattern {pattern.pattern!r}")


def validate(path: Path, gate: str) -> list[str]:
    errors: list[str] = []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{path}: cannot load JSON: {exc}"]
    if not isinstance(payload, dict):
        return [f"{path}: root must be an object"]

    scan_secret_patterns(path, errors)
    if payload.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version: must equal {SCHEMA_VERSION!r}")
    if payload.get("journey_id") != PROVIDER_PREBETA_JOURNEY_ID:
        errors.append(f"journey_id: must equal {PROVIDER_PREBETA_JOURNEY_ID!r}")
    related = payload.get("related_journeys")
    if not isinstance(related, list) or SPEC016_PAYOUT_JOURNEY_ID not in related:
        errors.append(f"related_journeys: must include {SPEC016_PAYOUT_JOURNEY_ID!r}")

    captured_at = parse_utc(payload.get("captured_at"), "captured_at", errors)
    repository = require_object(payload.get("repository"), "repository", errors)
    if repository.get("name") != "Augustas11/macprovider":
        errors.append("repository.name: must equal 'Augustas11/macprovider'")
    if not isinstance(repository.get("commit"), str) or not COMMIT_RE.fullmatch(repository["commit"]):
        errors.append("repository.commit: must be a 40-character commit SHA")

    provider = require_object(payload.get("provider"), "provider", errors)
    provider_id_hash = provider.get("provider_id_sha256")
    require_sha256(provider_id_hash, "provider.provider_id_sha256", errors)

    payout_config = require_object(payload.get("payout_config"), "payout_config", errors)
    require_bool(payout_config.get("enabled"), True, "payout_config.enabled", errors)
    require_bool(payout_config.get("dev_mode"), False, "payout_config.dev_mode", errors)
    require_bool(payout_config.get("registration_paused"), False, "payout_config.registration_paused", errors)
    for field in (
        "hot_wallet_address_sha256",
        "encrypted_wallet_path_sha256",
        "rpc_url_primary_sha256",
        "rpc_url_secondary_sha256",
    ):
        require_sha256(payout_config.get(field), f"payout_config.{field}", errors)

    address_posture = require_object(payload.get("payout_address_posture"), "payout_address_posture", errors)
    if address_posture.get("provider_payout_address_match_count") != 1:
        errors.append("payout_address_posture.provider_payout_address_match_count: must equal 1")
    match = require_object(address_posture.get("match"), "payout_address_posture.match", errors)
    if match.get("provider_id_sha256") != provider_id_hash:
        errors.append("payout_address_posture.match.provider_id_sha256: must match provider.provider_id_sha256")
    if match.get("chain") != "base-mainnet":
        errors.append("payout_address_posture.match.chain: must equal 'base-mainnet'")
    require_sha256(match.get("address_sha256"), "payout_address_posture.match.address_sha256", errors)
    require_bool(match.get("payout_allowed"), True, "payout_address_posture.match.payout_allowed", errors)
    if match.get("registered_against_hot_wallet_sha256") != payout_config.get("hot_wallet_address_sha256"):
        errors.append(
            "payout_address_posture.match.registered_against_hot_wallet_sha256: "
            "must match payout_config.hot_wallet_address_sha256"
        )
    registered_at = parse_utc(
        match.get("registered_at_utc"),
        "payout_address_posture.match.registered_at_utc",
        errors,
    )
    pending_until = parse_utc(
        match.get("pending_until_utc"),
        "payout_address_posture.match.pending_until_utc",
        errors,
    )
    if captured_at and registered_at and registered_at > captured_at:
        errors.append("payout_address_posture.match.registered_at_utc: must not be after captured_at")
    if registered_at and pending_until and pending_until <= registered_at:
        errors.append("payout_address_posture.match.pending_until_utc: must be after registered_at_utc")

    runner = require_object(payload.get("runner_posture"), "runner_posture", errors)
    runner_state = require_object(runner.get("payout_runner_state"), "runner_posture.payout_runner_state", errors)
    table_counts = require_object(runner.get("table_counts"), "runner_posture.table_counts", errors)
    for field in (
        "ledger_payout_ready",
        "payout_attempts",
        "payout_hot_wallet_funding",
        "payout_reorg_orphans",
        "runtime_flag_audit",
    ):
        require_non_negative_int(table_counts.get(field), f"runner_posture.table_counts.{field}", errors)
    if runner_state.get("last_run_error_text") not in (None, ""):
        errors.append("runner_posture.payout_runner_state.last_run_error_text: must be null or empty")

    journal_counts = require_object(payload.get("journal_event_counts"), "journal_event_counts", errors)
    for field in (
        "payout_runner_lease_conflict",
        "payout_invariant_violation",
        "payout_runner_halted_skipping_cycle",
    ):
        if journal_counts.get(field) != 0:
            errors.append(f"journal_event_counts.{field}: must equal 0")

    result = require_object(payload.get("result"), "result", errors)
    if result.get("status") != "partial-pass-not-promotable":
        errors.append("result.status: must equal 'partial-pass-not-promotable'")
    action = require_object(payload.get("conformance_action"), "conformance_action", errors)
    require_bool(action.get("promoted"), False, "conformance_action.promoted", errors)

    redaction = require_object(payload.get("redaction"), "redaction", errors)
    for field in (
        "secrets_redacted",
        "operator_identity_redacted",
        "local_account_names_redacted",
        "provider_id_redacted",
        "wallet_addresses_redacted",
        "rpc_urls_redacted",
        "token_material_redacted",
        "raw_journal_payloads_redacted",
    ):
        require_bool(redaction.get(field), True, f"redaction.{field}", errors)

    if gate in ("post-cooling-address-eligible", "runner-ready"):
        if captured_at and pending_until and captured_at < pending_until:
            errors.append(
                "payout_address_posture.match.pending_until_utc: cooling window has not cleared "
                f"(captured_at={payload.get('captured_at')}, pending_until_utc={match.get('pending_until_utc')})"
            )
    if gate == "runner-ready":
        require_bool(
            runner_state.get("payout_bootstrap_complete"),
            True,
            "runner_posture.payout_runner_state.payout_bootstrap_complete",
            errors,
        )
        if table_counts.get("payout_hot_wallet_funding", 0) < 1:
            errors.append(
                "runner_posture.table_counts.payout_hot_wallet_funding: "
                "must be at least 1 for runner-ready"
            )

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", help="redacted provider-prebeta payout posture JSON")
    parser.add_argument(
        "--gate",
        choices=("address-onboarded", "post-cooling-address-eligible", "runner-ready"),
        default="address-onboarded",
        help="validation gate to apply",
    )
    args = parser.parse_args(argv)
    errors = validate(Path(args.artifact), args.gate)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"provider-prebeta payout posture gate passed: {args.gate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
