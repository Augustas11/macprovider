#!/usr/bin/env python3
"""Summarize #1690 e2e results (LAB/e2e/results/*.json) as markdown.

  summarize.py [--prefix R1] [--lab DIR]

One row per label: requests, HTTP statuses, checks passed/total, and every
failed check tagged with the finding it matches (E2E-Fn, see the evidence
doc) or UNCLASSIFIED. A failure is classified by its check name and the
observed values only, never by guessing.
"""
import argparse
import collections
import json
import os
import pathlib


def classify(req, check, obs, ev=None):
    o = obs if isinstance(obs, dict) else {}
    reasons = {v.get("reason") for v in (ev or {}).get("verdicts", [])}
    fin = (ev or {}).get("finality") or {}
    # Post-fix (#1690 bench 97b22eb3) designed outcomes, counted apart:
    # F4 fix bills a disconnected buyer only what reached it while finality
    # keeps the gateway-delivered count; F5 fix closes a verified receipt on
    # a quarantined credit as zero_settled and refunds both sides.
    if check == "debit_eq_settled" and req["behaviour"] == "disconnect" and o.get("basis", "").startswith("finality") \
            and (o.get("gateway") or {}).get("status") == "settled" and o["debit"][1] < o["settled"][1]:
        return "E2E-F4-fixed(by-design gap)"
    if fin.get("reason") == "verified_receipt_credit_quarantined" and check in ("delivered_not_free", "buyer_usage_eq_debit"):
        return "E2E-F5-fixed(zero_settled refund)"
    if "output_hash_mismatch" in reasons and req["engine"] == "native" and req["shape"] == "long" and check in ("delivered_not_free", "buyer_usage_eq_debit"):
        return "E2E-F13(new: native long output_hash_mismatch)"
    if "rotate" in req["label"] and "missing_receipt_deadline_elapsed" in reasons and check in ("delivered_not_free", "buyer_usage_eq_debit"):
        return "E2E-F9"
    if "output_hash_mismatch" in reasons and check in ("delivered_not_free", "buyer_usage_eq_debit", "stream_complete"):
        return "E2E-F6"
    basis = str(o.get("basis", ""))
    if check == "debit_eq_settled" and ("finality observe" in basis or "(finality observe)" in basis):
        return "E2E-F8"
    if check == "debit_eq_settled" and basis.startswith("finality enforce") and (o.get("gateway") or {}).get("token_source") == "provider_reported":
        return "E2E-F7"
    if check.startswith("buyer_usage_eq_debit[F1"):
        return "E2E-F1"
    if check == "stream_complete" and o.get("stream_error") == "stream_output_exceeded":
        return "E2E-F2"
    if check == "stream_complete" and o.get("stream_error") == "stream_malformed":
        return "E2E-F6"
    if check == "delivered_not_free" and req["shape"] == "long" and req["stream"] and req["behaviour"] in ("normal", "slow"):
        return "E2E-F2"
    if check == "delivered_not_free" and o.get("note") == "partial stream":
        return "E2E-F3"
    if check == "no_undelivered_bill" and req["behaviour"] == "disconnect":
        return "E2E-F4"
    if req["shape"] == "tool" and req["engine"] == "native" and check in ("no_hold", "debit_eq_settled", "delivered_not_free", "buyer_usage_eq_debit"):
        return "E2E-F5" if not req["stream"] else "E2E-F6"
    return "UNCLASSIFIED"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--prefix", default="")
    p.add_argument("--lab", default=os.environ.get("LAB", "/Users/a1/lab-1690-m6/e2e"))
    a = p.parse_args()
    files = sorted(pathlib.Path(a.lab, "e2e", "results").glob(f"{a.prefix}*.json"))
    print("| Label | Requests | HTTP status | Checks passed | Failed checks by finding | Still held |")
    print("|---|---|---|---|---|---|")
    unclassified = []
    for f in files:
        d = json.loads(f.read_text())
        res = d["results"]
        statuses = collections.Counter(str(r["request"].get("status")) for r in res)
        total = sum(len(r["checks"]) for r in res)
        failed = [(r["request"], c, r["evidence"]) for r in res for c in r["checks"] if not c["ok"]]
        tags = collections.Counter(classify(q, c["check"], c["observed"], e) for q, c, e in failed)
        for q, c, e in failed:
            if classify(q, c["check"], c["observed"], e) == "UNCLASSIFIED":
                unclassified.append((d["label"], q["route"], q["shape"], q["stream"], q["behaviour"], c["check"], json.dumps(c["observed"], default=str)[:300]))
        st = " ".join(f"{k}x{v}" for k, v in sorted(statuses.items()))
        tg = ", ".join(f"{k} x{v}" for k, v in sorted(tags.items())) or "none"
        print(f"| {d['label']} | {len(res)} | {st} | {total - len(failed)}/{total} | {tg} | {len(d.get('still_active') or [])} |")
    if unclassified:
        print("\nUNCLASSIFIED failures:")
        for u in unclassified:
            print("-", " | ".join(str(x) for x in u))


if __name__ == "__main__":
    main()
