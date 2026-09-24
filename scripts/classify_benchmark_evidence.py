#!/usr/bin/env python3
"""Classify one account-scoped buyer request using durable coordinator/gateway rows."""

import argparse
from contextlib import closing
import hashlib
import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path


def open_readonly(path):
    db = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    return db


def one(db, sql, args):
    return db.execute(sql, args).fetchone()


def parse_utc(timestamp):
    created = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    return created


def age_seconds(timestamp, now):
    created = parse_utc(timestamp)
    return max(0, (now - created).total_seconds())


def evidence_scopes(account_id):
    account_digest = hashlib.sha256(("spec015-account-scope-v1:" + account_id.strip()).encode()).hexdigest()
    account_scope = "acct_sha256:" + account_digest
    receipt_scope = hashlib.sha256(("settlement_receipt_account_scope_v1:" + account_scope).encode()).hexdigest()
    return account_scope, receipt_scope


def classify(coordinator, gateway, account_id, external_request_id, journal=None, now=None, expected_provider_id=None):
    now = now or datetime.now(timezone.utc)
    account_scope, receipt_scope = evidence_scopes(account_id)
    requests = coordinator.execute(
        """SELECT request_id, attempt_n, ts_utc, status, provider_assigned_id, provider_header, model
             FROM request_log
            WHERE account_id = ? AND external_request_id = ? AND status = 200
              AND provider_assigned_id IS NOT NULL
            ORDER BY id""",
        (account_id, external_request_id),
    ).fetchall()
    if not requests:
        raise ValueError("no successful provider-bound request for account and request id")

    usage = one(gateway, "SELECT outcome, prompt_tokens, completion_tokens FROM usage_events WHERE account_id = ? AND request_id = ?", (account_id, external_request_id))
    quota = one(gateway, "SELECT status, settled_tokens, settlement_hold FROM quota_reservations WHERE account_id = ? AND request_id = ?", (account_id, external_request_id))
    attempts = []
    for request in requests:
        internal_id, attempt_n = request["request_id"], request["attempt_n"]
        credit = one(coordinator, """SELECT provider_id, provider_assigned_id, quarantine_reason, quarantined,
                                              prompt_tokens, charged_prompt_tokens,
                                              provider_reported_prompt_tokens, completion_tokens
                                      FROM ledger_request_credits
                                     WHERE settlement_account_scope_hash = ? AND request_id = ? AND attempt_n = ?
                                     ORDER BY id DESC LIMIT 1""", (receipt_scope, internal_id, attempt_n))
        credit_count = one(coordinator, """SELECT COUNT(DISTINCT provider_id) AS providers
                                             FROM ledger_request_credits
                                            WHERE settlement_account_scope_hash = ? AND request_id = ? AND attempt_n = ?""", (receipt_scope, internal_id, attempt_n))["providers"]
        age = age_seconds(request["ts_utc"], now)
        reasons, pending = [], []
        usage_accounting_split = None
        provider_id = credit["provider_id"] if credit else ""
        key = (internal_id, attempt_n, provider_id)
        if not credit:
            (pending if age < 300 else reasons).append("provider_credit_missing")
        elif credit_count != 1:
            reasons.append("multiple_provider_credits")
        elif credit["quarantined"]:
            reasons.append("provider_credit_quarantined:" + (credit["quarantine_reason"] or "unspecified"))
        elif credit["provider_assigned_id"] != request["provider_assigned_id"]:
            reasons.append("provider_assignment_mismatch")
        if not expected_provider_id and not request["provider_header"]:
            reasons.append("expected_provider_missing")
        if expected_provider_id and credit and credit["provider_id"] != expected_provider_id:
            reasons.append("expected_provider_mismatch")
        if request["provider_header"] and credit and credit["provider_id"] != request["provider_header"]:
            reasons.append("provider_pin_mismatch")
        if expected_provider_id and request["provider_header"] and request["provider_header"] != expected_provider_id:
            reasons.append("expected_provider_pin_mismatch")
        route = one(coordinator, """SELECT pending_deadline_seconds, request_start_ts_unix_ms, route_snapshot_digest,
                                            provider_reported_model_hash, expected_catalog_model_hash, model_id, spec008_hash_status
                                     FROM settlement_route_snapshots
                                    WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?""", (account_scope, *key))
        output = one(coordinator, """SELECT terminal_state, usage_canonical_json FROM settlement_attempt_outputs
                                      WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?""", (account_scope, *key))
        verdict = one(coordinator, """SELECT settlement_outcome, closed, reason, pending_deadline_unix_ms, route_snapshot_digest
                                       FROM settlement_receipt_verdicts
                                      WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?""", (receipt_scope, *key))
        audit = one(coordinator, """SELECT COUNT(*) AS rows,
                                           SUM(CASE WHEN poisoned_at_utc IS NOT NULL THEN 1 ELSE 0 END) AS poisoned,
                                           SUM(CASE WHEN drained_at_utc IS NULL AND poisoned_at_utc IS NULL THEN 1 ELSE 0 END) AS pending
                                      FROM settlement_receipt_audit_outbox
                                     WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?""", (receipt_scope, *key))
        journal_route = None
        if journal and not route:
                journal_route = one(journal, """SELECT mirrored_at_utc FROM settlement_route_snapshot_journal
                                           WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?""", (account_scope, *key))
        deadline = (
            datetime.fromtimestamp((route["request_start_ts_unix_ms"] + route["pending_deadline_seconds"] * 1000) / 1000, timezone.utc)
            if route else parse_utc(request["ts_utc"]) + timedelta(seconds=300)
        )
        if not route:
            if journal_route:
                (pending if age < 300 else reasons).append(
                    "route_snapshot_mirror_pending" if age < 300 else "route_snapshot_mirror_stalled"
                )
            elif credit and credit["quarantine_reason"] == "route_snapshot_store_pressure":
                reasons.append("route_snapshot_store_pressure")
            elif age < 300:
                pending.append("route_snapshot_pending")
            else:
                reasons.append("route_snapshot_missing")
        elif route["provider_reported_model_hash"] != route["expected_catalog_model_hash"]:
            reasons.append("route_snapshot_model_hash_mismatch")
        elif route["model_id"] != request["model"] or route["spec008_hash_status"] != "hash_verified":
            reasons.append("route_snapshot_model_unverified")
        if not output:
            if credit and credit["quarantine_reason"] == "settlement_attempt_output_missing":
                reasons.append("settlement_attempt_output_missing")
            elif age < 300:
                pending.append("settlement_attempt_output_pending")
            else:
                reasons.append("settlement_attempt_output_missing")
        elif output["terminal_state"] != "normal_done":
            reasons.append("settlement_output_not_successful")
        elif credit:
            settled_usage = json.loads(output["usage_canonical_json"])
            charged_prompt = credit["charged_prompt_tokens"]
            if charged_prompt is None:
                charged_prompt = credit["prompt_tokens"]
            charged_completion = credit["completion_tokens"]
            observed_prompt = credit["provider_reported_prompt_tokens"]
            if observed_prompt is None:
                observed_prompt = charged_prompt
            if charged_prompt is None or charged_completion is None:
                reasons.append("charged_usage_missing")
            elif (credit["prompt_tokens"] is not None and
                  credit["prompt_tokens"] != charged_prompt):
                reasons.append("ledger_charged_prompt_mismatch")
            elif usage and (charged_prompt != usage["prompt_tokens"] or
                            charged_completion != usage["completion_tokens"]):
                reasons.append("gateway_coordinator_usage_mismatch")
            if observed_prompt is None or charged_completion is None:
                reasons.append("provider_observed_usage_missing")
            elif charged_prompt is not None and charged_prompt > observed_prompt:
                reasons.append("charged_prompt_exceeds_provider_observed")
            elif (settled_usage["billable_input_tokens"] != observed_prompt or
                  settled_usage["billable_output_tokens"] != charged_completion):
                reasons.append("receipt_observed_usage_mismatch")
            elif charged_prompt is not None and charged_prompt < observed_prompt:
                usage_accounting_split = {
                    "provider_observed_prompt_tokens": observed_prompt,
                    "charged_prompt_tokens": charged_prompt,
                    "reason": "bounded_prompt_billing",
                }
        if verdict:
            if route and verdict["route_snapshot_digest"] != route["route_snapshot_digest"]:
                reasons.append("receipt_route_digest_mismatch")
            if verdict["settlement_outcome"] != "verified" or not verdict["closed"]:
                if not verdict["closed"] and now.timestamp() * 1000 < verdict["pending_deadline_unix_ms"]:
                    pending.append("receipt_verdict_pending")
                else:
                    reasons.append("receipt_verdict_" + verdict["settlement_outcome"])
        elif route and output and now < deadline:
            pending.append("receipt_verdict_pending")
        elif not route or not output:
            reasons.append("receipt_verdict_blocked_by_missing_evidence")
        else:
            reasons.append("receipt_verdict_missing")
        attempts.append({
            "internal_request_id": internal_id,
            "attempt_n": attempt_n,
            "provider_id": provider_id,
            "route_snapshot": bool(route),
            "settlement_output": bool(output),
            "receipt_verdict": verdict["settlement_outcome"] if verdict else None,
            "receipt_audit_outbox": "poisoned" if audit["poisoned"] else "pending" if audit["pending"] else "drained" if audit["rows"] else "none",
            "usage_accounting_split": usage_accounting_split,
            "missing": sorted(set(reasons)),
            "pending": sorted(set(pending)),
        })

    gateway_missing, gateway_pending = [], []
    request_age = min(age_seconds(row["ts_utc"], now) for row in requests)
    if not usage:
        (gateway_pending if request_age < 300 else gateway_missing).append("gateway_usage_missing")
    elif usage["outcome"] not in ("ok", "spec022_verified"):
        gateway_missing.append("gateway_usage_not_successful")
    if not quota or quota["status"] != "settled":
        reason = "gateway_quota_" + (quota["status"] if quota else "missing")
        (gateway_pending if request_age < 300 and quota and quota["status"] == "active" else gateway_missing).append(reason)
    elif quota["settlement_hold"]:
        gateway_missing.append("gateway_quota_hold_not_cleared")
    elif usage and quota["settled_tokens"] != usage["prompt_tokens"] + usage["completion_tokens"]:
        gateway_missing.append("gateway_quota_usage_mismatch")
    all_missing = sorted(set(gateway_missing).union(*(a["missing"] for a in attempts)))
    all_pending = sorted(set(gateway_pending).union(*(a["pending"] for a in attempts)))
    classification = "incomplete" if all_missing else "pending" if all_pending else "complete"
    return {
        "classification": classification,
        "external_request_id": external_request_id,
        "missing": all_missing,
        "pending": all_pending,
        "gateway_usage": usage["outcome"] if usage else None,
        "gateway_quota": quota["status"] if quota else None,
        "gateway_usage_tokens": usage["prompt_tokens"] + usage["completion_tokens"] if usage else None,
        "gateway_settled_tokens": quota["settled_tokens"] if quota else None,
        "gateway_settlement_hold": quota["settlement_hold"] if quota else None,
        "attempts": attempts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coordinator-db", required=True)
    parser.add_argument("--gateway-db", required=True)
    parser.add_argument("--route-journal-db")
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--request-id", required=True, help="buyer-visible X-Request-ID")
    parser.add_argument("--expected-provider-id", help="benchmark target provider ID; required for complete classification when the coordinator has no provider pin header")
    args = parser.parse_args()
    with closing(open_readonly(args.coordinator_db)) as coordinator, closing(open_readonly(args.gateway_db)) as gateway:
        if args.route_journal_db:
            with closing(open_readonly(args.route_journal_db)) as journal:
                result = classify(coordinator, gateway, args.account_id, args.request_id, journal, expected_provider_id=args.expected_provider_id)
        else:
            result = classify(coordinator, gateway, args.account_id, args.request_id, expected_provider_id=args.expected_provider_id)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
