#!/usr/bin/env python3
"""#1816 e2e pool-model oracle. Runs the shared #1690 oracle (I1-I4, I6,
EXPECT) for the run, then checks every pool-model request against the entry
the harness signed, computing the expected credits INDEPENDENTLY of the
coordinator: the entry rates come from --rates (what the creator signed), the
tokens from --tokens (what the fake provider reports), and the multiplier and
provider share from the live coordinator config, through the SPEC-005 formula
(RoundHalfEven; docs/runbooks/pool-scoped-model-admission.md section 3):

  base     = P*prompt_rate + C*completion_rate        (no cached prompt)
  gross    = rhe(base * multiplier_ppm, 10^12)
  provider = rhe(gross * share_bps, 10^4)

Per SETTLED request (P5 one payable ledger row; P6 gross/provider credits equal
the expectation; P7 ledger rates equal the entry; P8 gateway debit = P+C and
token_source; P9 settlement_attempt_outputs.usage_source; P10 verdict
verified + pool_label_status verified; P11 route snapshot
expected_model_hash_source=pool_manifest, pool_model_id, runtime_source,
completion rate; P12 ledger usage_source provider_reported (#1750 contract)).
--zero-credit: every request must end with no positive provider credit and no
debit (revocation cases). --refused: every request must be non-200 with no
reservation debit, no ledger credit and no route snapshot (refusal cases).
"""
import argparse, json, sqlite3, subprocess, sys, yaml

ap = argparse.ArgumentParser()
ap.add_argument("--base-oracle", required=True)
ap.add_argument("--prefix", required=True)
ap.add_argument("--load", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--allow", default="I5")
ap.add_argument("--expect", default="")
ap.add_argument("--pool-model-id")
ap.add_argument("--rates", help="prompt,cache_hit,completion credits per Mtok of the signed entry")
ap.add_argument("--tokens", default="8,20", help="prompt,completion tokens the fake reports for a completed response")
ap.add_argument("--usage-source", help="expected settlement_attempt_outputs.usage_source")
ap.add_argument("--token-source", help="expected gateway usage_events.token_source")
ap.add_argument("--runtime-source", default=None, help="expected snapshot runtime_source ('null' for native)")
ap.add_argument("--provider", help="expected credited provider id (comma list allowed)")
ap.add_argument("--zero-credit", action="store_true")
ap.add_argument("--refused", action="store_true")
ap.add_argument("--min-settled", type=int, default=0, help="at least this many settled requests")
a = ap.parse_args()

GW, CO = "/var/lib/macprovider/gateway.db", "/var/lib/macprovider/request-log.sqlite"
base_out = a.out.replace(".pool-oracle.json", ".oracle.json")
cmd = ["python3", a.base_oracle, "--allow", a.allow, "--prefix", a.prefix, "--load", a.load, "--out", base_out]
if a.expect:
    cmd += ["--expect", a.expect]
base = subprocess.run(cmd, capture_output=True, text=True)
report = json.load(open(base_out))
fails = [f for f in report["failures"] if f["inv"] not in set(a.allow.split(","))]
if a.refused:
    # A refusal may never reach a reservation (no gateway row at all).
    fails = [f for f in fails if f["inv"] != "NONE"]
    for l in open(a.load):
        r = json.loads(l)
        if r.get("run") == a.prefix and r.get("status") == 200:
            fails.append({"inv": "R1", "rid": r["rid"], "msg": "refusal case answered 200"})


def fail(inv, rid, msg):
    fails.append({"inv": inv, "rid": rid, "msg": msg})


def rhe(n, d):
    q, r = divmod(n, d)
    return q + (1 if 2 * r > d or (2 * r == d and q % 2) else 0)


cfg = yaml.safe_load(open("/opt/macprovider/coordinator.yaml"))
rew = cfg.get("rewards") or {}
mult_ppm = round(float(rew.get("global_multiplier", 1.0)) * 1e6)
share_bps = round(float(rew.get("provider_share", 0.9)) * 1e4)
P, C = (int(x) for x in a.tokens.split(","))
rates = [int(x) for x in a.rates.split(",")] if a.rates else None
exp_gross = exp_prov = None
if rates:
    exp_gross = rhe((P * rates[0] + C * rates[2]) * mult_ppm, 10 ** 12)
    exp_prov = rhe(exp_gross * share_bps, 10 ** 4)

co = sqlite3.connect("file:%s?mode=ro" % CO, uri=True, timeout=10)
co.row_factory = sqlite3.Row
gw = sqlite3.connect("file:%s?mode=ro" % GW, uri=True, timeout=10)
gw.row_factory = sqlite3.Row
providers = set(a.provider.split(",")) if a.provider else None
settled = 0
for row in report["rows"]:
    rid, cids = row["rid"], row["coord_ids"]
    q = ",".join("?" * len(cids)) or "''"
    credits = [dict(r) for r in co.execute("SELECT l.*, (p.id IS NOT NULL) AS is_payable FROM ledger_request_credits l LEFT JOIN spec022_payable_request_credits p ON p.id = l.id WHERE l.request_id IN (%s)" % q, cids)]
    snaps = [json.loads(r[0]) for r in co.execute("SELECT route_snapshot_json FROM settlement_route_snapshots WHERE request_id IN (%s)" % q, cids)]
    saos = [dict(r) for r in co.execute("SELECT * FROM settlement_attempt_outputs WHERE request_id IN (%s)" % q, cids)]
    verdicts = [dict(r) for r in co.execute("SELECT * FROM settlement_receipt_verdicts WHERE request_id IN (%s)" % q, cids)]
    use = [dict(r) for r in gw.execute("SELECT * FROM usage_events WHERE request_id = ?", (rid,))]
    payable = [c for c in credits if c["is_payable"] and (c["provider_credits"] or 0) > 0]
    row["pool"] = {"credits": [{k: c.get(k) for k in ("provider_id", "attempt_n", "gross_credits", "provider_credits", "prompt_rate_per_mtok",
                                                     "completion_rate_per_mtok", "charged_prompt_tokens", "completion_tokens", "usage_source",
                                                     "quarantined", "quarantine_reason", "is_payable")} for c in credits],
                   "snapshots": [{k: s.get(k) for k in ("expected_model_hash_source", "pool_id", "pool_model_id", "runtime_source",
                                                        "manifest_version", "manifest_core_digest", "pool_model_prompt_rate_per_mtok",
                                                        "pool_model_completion_rate_per_mtok")} for s in snaps],
                   "attempt_outputs": [{k: s.get(k) for k in ("usage_source", "terminal_state")} for s in saos],
                   "verdicts": [{k: v.get(k) for k in ("settlement_outcome", "receipt_result", "pool_label_status", "reason", "closed")} for v in verdicts],
                   "usage": [{k: u.get(k) for k in ("prompt_tokens", "completion_tokens", "total_tokens", "token_source")} for u in use]}
    if a.refused:
        if row["debit_tokens"] or payable or snaps:
            fail("R2", rid, "refusal left debit=%s payable=%d snapshots=%d" % (row["debit_tokens"], len(payable), len(snaps)))
        continue
    if a.zero_credit:
        if payable:
            fail("Z1", rid, "revoked in flight but payable provider credit %s" % [(c["provider_id"], c["provider_credits"]) for c in payable])
        if row["debit_tokens"]:
            fail("Z2", rid, "revoked in flight but buyer debited %s" % row["debit_tokens"])
        continue
    for s in snaps:
        if a.pool_model_id and s.get("pool_model_id") != a.pool_model_id:
            fail("P11", rid, "snapshot pool_model_id %s" % s.get("pool_model_id"))
        if s.get("expected_model_hash_source") != "pool_manifest":
            fail("P11", rid, "snapshot expected_model_hash_source %s" % s.get("expected_model_hash_source"))
        if a.runtime_source is not None:
            want = None if a.runtime_source == "null" else a.runtime_source
            if s.get("runtime_source") != want:
                fail("P11", rid, "snapshot runtime_source %r, want %r" % (s.get("runtime_source"), want))
        if rates and s.get("pool_model_completion_rate_per_mtok") != rates[2]:
            fail("P11", rid, "snapshot completion rate %s != entry %s" % (s.get("pool_model_completion_rate_per_mtok"), rates[2]))
    if row["res_status"] != "settled":
        continue
    settled += 1
    if len(payable) != 1:
        fail("P5", rid, "settled with %d payable credits" % len(payable))
        continue
    c = payable[0]
    if providers and c["provider_id"] not in providers:
        fail("P5", rid, "credited %s, want one of %s" % (c["provider_id"], sorted(providers)))
    if rates:
        if c["gross_credits"] != exp_gross or c["provider_credits"] != exp_prov:
            fail("P6", rid, "gross/provider %s/%s != expected %s/%s (P=%d C=%d rates=%s mult=%d share=%d)"
                 % (c["gross_credits"], c["provider_credits"], exp_gross, exp_prov, P, C, rates, mult_ppm, share_bps))
        if c["prompt_rate_per_mtok"] != rates[0] or c["completion_rate_per_mtok"] != rates[2]:
            fail("P7", rid, "ledger rates %s/%s != entry %s/%s" % (c["prompt_rate_per_mtok"], c["completion_rate_per_mtok"], rates[0], rates[2]))
    if row["debit_tokens"] != P + C or any((u["prompt_tokens"], u["completion_tokens"]) != (P, C) for u in use):
        fail("P8", rid, "gateway debit %s (%s) != %d+%d" % (row["debit_tokens"], [(u["prompt_tokens"], u["completion_tokens"]) for u in use], P, C))
    if a.token_source and any(u["token_source"] != a.token_source for u in use):
        fail("P8", rid, "token_source %s != %s" % ([u["token_source"] for u in use], a.token_source))
    if a.usage_source and not any(s["usage_source"] == a.usage_source for s in saos if s["usage_source"]):
        fail("P9", rid, "attempt output usage_source %s != %s" % ([s["usage_source"] for s in saos], a.usage_source))
    if not any(v["settlement_outcome"] == "verified" and v["pool_label_status"] == "verified" for v in verdicts):
        fail("P10", rid, "no verified verdict with pool_label_status verified: %s" % [(v["settlement_outcome"], v["pool_label_status"]) for v in verdicts])
    if c["usage_source"] not in ("provider_reported", "byte_estimated"):
        fail("P12", rid, "ledger usage_source %s (contract: provider_reported)" % c["usage_source"])
if settled < a.min_settled:
    fail("P0", a.prefix, "only %d settled pool requests, want >= %d" % (settled, a.min_settled))
report["pool_failures"] = fails
report["expected"] = {"gross": exp_gross, "provider": exp_prov, "P": P, "C": C, "rates": rates, "mult_ppm": mult_ppm, "share_bps": share_bps}
json.dump(report, open(a.out, "w"), indent=1, sort_keys=True, default=str)
print(json.dumps({"prefix": a.prefix, "sent": report["sent"], "summary": report["summary"], "settled": settled,
                  "expected_gross_provider": [exp_gross, exp_prov], "ok": not fails}, sort_keys=True))
for f in fails[:30]:
    print("  %s %s %s" % (f["inv"], f["rid"], f["msg"][:400]))
sys.exit(0 if not fails else 1)
