#!/usr/bin/env python3
"""#1690 e2e ledger oracle: join the gateway SQLite (buyer side) with the
coordinator SQLite (provider side) for every request whose client
X-Request-ID starts with --prefix, and check the invariants:

  I1 terminal     no quota_reservations row left 'active' and none with
                  settlement_hold=1 (after the reconciler drained)
  I2 debit shape  'settled' => one usage_events row whose total_tokens ==
                  settled_tokens; 'refunded'/'expired' => no positive debit
  I3 buyer==prov  buyer debit tokens == tokens of the provider's PAYABLE
                  credits (spec022_payable_request_credits) for the request
                  (a debit with nothing payable = buyer charged without
                  provider evidence; payable with no debit = provider paid
                  for what the buyer was refunded)
  I4 evidence     under enforce: every payable credit has a closed verified
                  verdict + attempt output (the view guarantees it; we check
                  that no payable credit carries mode legacy/observe while the
                  coordinator runs enforce, i.e. payable WITHOUT evidence)
  I5 no open      no settlement_receipt_verdicts row left closed=0 past its
                  pending deadline
Prints a JSON report; exit 1 when any invariant fails. --expect lets a
scenario assert per-kind outcomes, e.g. --expect ns=settled,ns_dc=refunded.
"""
import argparse, json, sqlite3, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--prefix", required=True, help="run label (reporting)")
ap.add_argument("--load", required=True, help="loadgen jsonl of the run: request ids and kinds")
ap.add_argument("--gw", default="/var/lib/macprovider/gateway.db")
ap.add_argument("--coord", default="/var/lib/macprovider/request-log.sqlite")
ap.add_argument("--mode", default="enforce", help="coordinator settlement mode in force")
ap.add_argument("--expect", default="", help="kind=status[,..] expected reservation status per kind")
ap.add_argument("--allow", default="", help="comma list of invariant ids to report but not fail")
ap.add_argument("--out")
a = ap.parse_args()


def ro(path):
    c = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=10)
    c.row_factory = sqlite3.Row
    return c


def cols(c, table):
    return {r[1] for r in c.execute("PRAGMA table_info(%s)" % table)}


gw, co = ro(a.gw), ro(a.coord)
kinds, http = {}, {}
for l in open(a.load):
    d = json.loads(l)
    if d.get("run") == a.prefix:
        kinds[d["rid"]] = d["kind"]
        http[d["rid"]] = d.get("status")
qm = ",".join("?" * len(kinds)) or "''"
res = {r["request_id"]: dict(r) for r in gw.execute("SELECT * FROM quota_reservations WHERE request_id IN (%s)" % qm, list(kinds))}
use = {}
for r in gw.execute("SELECT * FROM usage_events WHERE request_id IN (%s)" % qm, list(kinds)):
    use.setdefault(r["request_id"], []).append(dict(r))
ids = sorted(res.keys() | use.keys())
missing_res = [k for k in kinds if k not in res]
# client id -> coordinator request ids
ext = {}
if "external_request_id" in cols(co, "request_log"):
    for r in co.execute("SELECT DISTINCT external_request_id, request_id FROM request_log WHERE external_request_id IN (%s)" % qm, list(kinds)):
        ext.setdefault(r[0], set()).add(r[1])
payable_ids = {r[0] for r in co.execute("SELECT id FROM spec022_payable_request_credits")}
now_ms = int(time.time() * 1000)
rows, fails = [], []


def fail(inv, rid, msg):
    fails.append({"inv": inv, "rid": rid, "msg": msg})


expect = dict(p.split("=") for p in a.expect.split(",") if p)
for rid in ids:
    kind = kinds.get(rid, "?")
    r = res.get(rid, {})
    u = use.get(rid, [])
    debit = sum(x["total_tokens"] for x in u)
    cids = set(ext.get(rid, set()))
    credits, verdicts, saos = [], [], []
    for cid in cids:
        for c in co.execute("SELECT * FROM ledger_request_credits WHERE request_id = ?", (cid,)):
            d = dict(c); d["payable"] = d["id"] in payable_ids; credits.append(d)
        for v in co.execute("SELECT request_id, attempt_n, provider_id, settlement_outcome, receipt_result, reason, closed, pending_deadline_unix_ms, route_snapshot_mode FROM settlement_receipt_verdicts WHERE request_id = ?", (cid,)):
            verdicts.append(dict(v))
        for s in co.execute("SELECT request_id, attempt_n, provider_id, terminal_state, usage_source, output_prefix_end_byte FROM settlement_attempt_outputs WHERE request_id = ?", (cid,)):
            saos.append(dict(s))
    pay_tokens = sum((c["charged_prompt_tokens"] if c["charged_prompt_tokens"] is not None else (c["prompt_tokens"] or 0)) + (c["completion_tokens"] or 0)
                     for c in credits if c["payable"])
    row = {"rid": rid, "kind": kind, "http": http.get(rid), "coord_ids": sorted(cids),
           "res_status": r.get("status"), "hold": r.get("settlement_hold"), "reserved": r.get("reserved_tokens"),
           "settled_tokens": r.get("settled_tokens"), "debit_tokens": debit,
           "token_source": ",".join(sorted({x["token_source"] for x in u})), "usage_outcome": ",".join(sorted({x["outcome"] for x in u})),
           "credits": [{k: c[k] for k in ("attempt_n", "provider_id", "status", "stream", "prompt_tokens", "charged_prompt_tokens", "completion_tokens", "usage_source", "gross_credits", "provider_credits", "quarantined", "quarantine_reason", "settlement_policy_mode", "recovery_source", "payable")} for c in credits],
           "payable_tokens": pay_tokens, "verdicts": verdicts, "attempt_outputs": saos}
    rows.append(row)
    if r:
        if r["status"] == "active":
            fail("I1", rid, "reservation still active (hold=%s)" % r["settlement_hold"])
        if r["settlement_hold"] == 1:
            fail("I1", rid, "settlement_hold=1 left")
        if r["status"] == "settled" and debit != r["settled_tokens"]:
            fail("I2", rid, "settled_tokens=%s but usage_events total=%s" % (r["settled_tokens"], debit))
        if r["status"] in ("refunded", "expired") and debit > 0:
            fail("I2", rid, "%s reservation but a debit of %s tokens" % (r["status"], debit))
    if r.get("status") in ("settled", "refunded", "expired") or not r:
        if debit > 0 and pay_tokens == 0:
            fail("I3", rid, "buyer debited %s tokens, provider has no payable credit (%s)" % (debit, [(c["quarantined"], c["quarantine_reason"], c["settlement_policy_mode"]) for c in credits]))
        elif debit == 0 and pay_tokens > 0:
            fail("I3", rid, "provider payable %s tokens, buyer not debited (res=%s)" % (pay_tokens, r.get("status")))
        elif debit != pay_tokens:
            fail("I3", rid, "buyer debit %s != provider payable %s" % (debit, pay_tokens))
    if a.mode == "enforce":
        for c in credits:
            if c["payable"] and c["settlement_policy_mode"] != "enforce" and c["status"] == 200:
                fail("I4", rid, "payable %s-mode credit without enforce evidence (attempt %s)" % (c["settlement_policy_mode"], c["attempt_n"]))
    for v in verdicts:
        if v["closed"] == 0 and v["pending_deadline_unix_ms"] < now_ms:
            fail("I5", rid, "verdict open past its deadline (%s)" % v["reason"])
    # I6: a buyer who received a non-200 (and did not hang up) must not be debited
    if isinstance(http.get(rid), int) and http.get(rid) != 200 and debit > 0:
        fail("I6", rid, "buyer got HTTP %s but was debited %s tokens (%s)" % (http.get(rid), debit, row["token_source"]))
    if kind in expect and r.get("status") != expect[kind]:
        fail("EXPECT", rid, "kind %s expected reservation %s, got %s" % (kind, expect[kind], r.get("status")))

if not rows:
    fail("NONE", a.prefix, "no gateway rows for this run (traffic never reached the gateway)")
allow = set(x for x in a.allow.split(",") if x)
blocking = [f for f in fails if f["inv"] not in allow]
summary = {}
for row in rows:
    k = "%s:%s:debit=%s:pay=%s" % (row["kind"], row["res_status"], row["debit_tokens"], row["payable_tokens"])
    summary[k] = summary.get(k, 0) + 1
report = {"prefix": a.prefix, "requests": len(rows), "sent": len(kinds), "no_reservation": [kinds[k] for k in missing_res], "summary": summary,
          "holds_active": gw.execute("SELECT COUNT(*) FROM quota_reservations WHERE status='active' AND settlement_hold=1").fetchone()[0],
          "failures": fails, "ok": not blocking, "rows": rows}
text = json.dumps(report, indent=1, sort_keys=True, default=str)
if a.out:
    open(a.out, "w").write(text)
print(json.dumps({k: report[k] for k in ("prefix", "sent", "requests", "no_reservation", "summary", "holds_active", "ok")}, sort_keys=True))
for f in fails[:40]:
    print("  %s %s %s" % (f["inv"], f["rid"], f["msg"]))
sys.exit(0 if not blocking else 1)
