#!/usr/bin/env python3
"""Print sanitized settlement evidence for recent lab requests.

  evidence.py [--last N] [--request-id ID]

Reads the lab coordinator SQLite DB read-only: the route snapshot's R006/R012
labels, the attempt usage source, the receipt verdict (with the v0.4 receipt
version and pool label status), the ledger credit, and computed finality.
Prints no secrets and no prompt or completion text.
"""
import argparse
import json
import os
import pathlib
import sqlite3

LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-1690-m6"))

SNAPSHOT_KEYS = ("pool_id", "manifest_version", "manifest_core_digest", "runtime_source", "pool_generation",
                 "pool_operator_account_id", "provider_id", "route_snapshot_mode", "model_id", "provider_reported_model_hash",
                 "provider_reported_model_hash_algorithm", "expected_catalog_model_hash", "expected_catalog_model_hash_algorithm",
                 "artifact_id", "artifact_hash_algorithm", "model_admission_catalog_model_key", "model_admission_served_model_ref",
                 "provider_receipt_key_id")


def cols(db, table):
    return [r[1] for r in db.execute(f"PRAGMA table_info({table})")]


def rows(db, table, where, params):
    names = cols(db, table)
    if not names:
        return []
    cur = db.execute(f"SELECT * FROM {table} WHERE {where}", params)
    return [dict(zip(names, r)) for r in cur.fetchall()]


def short(v):
    if isinstance(v, (bytes, bytearray)):
        return f"<{len(v)} bytes>"
    if isinstance(v, str) and len(v) > 200:
        return v[:200] + "..."
    return v


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--last", type=int, default=1)
    p.add_argument("--request-id")
    a = p.parse_args()
    db = sqlite3.connect(f"file:{LAB / 'db' / 'coordinator.db'}?mode=ro", uri=True)
    if a.request_id:
        ids = [a.request_id]
    else:
        ids = [r[0] for r in db.execute("SELECT request_id FROM settlement_route_snapshots ORDER BY rowid DESC LIMIT ?", (a.last,))]
    for rid in reversed(ids):
        print(f"=== request_id={rid}")
        for snap in rows(db, "settlement_route_snapshots", "request_id = ?", (rid,)):
            body = json.loads(snap.get("route_snapshot_json") or "{}")
            print("route_snapshot:", json.dumps({k: body.get(k) for k in SNAPSHOT_KEYS if k in body}, sort_keys=True))
            print("route_snapshot_digest:", snap.get("route_snapshot_digest"), "attempt_n:", snap.get("attempt_n"))
        for t, keep in (("settlement_attempt_outputs", ("attempt_n", "provider_id", "terminal_state", "usage_source", "usage_canonical_json", "output_available")),
                        ("settlement_receipt_verdicts", ("attempt_n", "receipt_present", "receipt_version", "receipt_result", "settlement_outcome", "reason", "receipt_profile", "buyer_debit_outcome", "provider_settlement_outcome", "pool_id", "pool_manifest_version", "pool_label_status", "route_snapshot_mode")),
                        ("ledger_request_credits", ("attempt_n", "stream", "status", "usage_source", "prompt_tokens", "charged_prompt_tokens", "provider_reported_prompt_tokens", "completion_tokens", "estimated_completion_tokens", "gross_credits", "provider_credits", "settled", "quarantined", "quarantine_reason", "settlement_policy_mode"))):
            for r in rows(db, t, "request_id = ?", (rid,)):
                print(f"{t}:", json.dumps({k: short(r[k]) for k in keep if k in r}, sort_keys=True, default=str))
        present = set(cols(db, "settlement_receipt_verdicts"))
        if not present:
            print("settlement_receipt_verdicts: (table absent)")


if __name__ == "__main__":
    main()
