#!/usr/bin/env python3
"""#1690 Pearl-shaped lab e2e: the case matrix for one engine, and the summary.

  pearl_shaped.py cases --engine llamacpp|ollama [--samples 24]
  pearl_shaped.py summary

Runs against a rig that pearl_shaped.sh brought up (Pearl-shaped configs,
gateway pin on, coordinator enforce, provider WS through latency_proxy.py).
Every request carries its own X-Request-ID; its settlement rows come from
matrix.gather (both lab databases) and the coordinator finality endpoint.

Cases (expected outcome is the correct behaviour; a FAIL on a ref without the
fixes is the reproduction):
  paid_short_ns / paid_short_stream  short prompt under a chat template, so the
      engine's prompt exceeds the coordinator bound len(body)/4 (BUG-1):
      expect verified + pool_operator_attested + payable credit and gateway
      debit == finality == ledger charged tokens
  paid_long_ns / paid_long_stream  padded prompt whose engine count stays
      under the bound: the control for BUG-1
  disconnect  buyer closes after a few SSE lines through the 220 ms RTT
      provider path (BUG-2): expect buyer_cancel with a valid, verified
      receipt over the delivered prefix and a prefix debit
  refusals  global+engine, disallowed engine, malformed selector, pool model
      without a pool: expected status/code, no new route snapshot, ledger row
      or engine call
  pause_resume  pause -> 503 pool_unavailable; resume -> 200
  r007_timing  unknown / unauthorized / disabled pool rejections, shuffled,
      evaluated by scripts/measure-pool-rejection-timing-floor.py (BUG-3)

Writes LAB/pearl/<engine>.json. Prompts and completions are never stored.
"""
import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import pathlib
import random
import secrets
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import matrix  # noqa: E402  (same LAB; reuses gather/finality/disconnect_prefix)

LAB = matrix.LAB
OUT = LAB / "pearl"
MODEL = matrix.MODEL
POOL = {"llamacpp": "A", "ollama": "O"}
CLASS = {"llamacpp": "llamacpp_loopback", "ollama": "ollama_loopback"}
OTHER = {"llamacpp": "ollama", "ollama": "llamacpp"}
OTHER_ACCOUNT = "acct-lab-1690-unauth"
# One token-efficient word repeated: the engine counts ~1 token per 12 bytes,
# the coordinator bound counts 1 per 4, so the reported prompt stays under it.
PAD = " information" * 150
WS = (",", ":")


def secret(name):
    return json.loads((LAB / "keys" / "secrets.json").read_text())[name]


def key_of(account):
    return (LAB / "keys" / f"buyer-key-{account}").read_text().strip()


def send(engine, *, content, stream, max_tokens=16, pool=True, select=None, model=None, account=matrix.ACCOUNT,
         disconnect_after=None, pool_id=None):
    """One compact-JSON chat request through the lab gateway. Returns the
    buyer's view (no text)."""
    rid = str(uuid.uuid4())
    body = {"model": model or MODEL, "messages": [{"role": "user", "content": content.replace("{ref}", rid[:8])}],
            "max_tokens": max_tokens}
    if stream:
        body["stream"] = True
        body["stream_options"] = {"include_usage": True}
    raw = json.dumps(body, separators=WS).encode()
    headers = {"Authorization": f"Bearer {key_of(account)}", "Content-Type": "application/json", "X-Request-ID": rid}
    if pool_id or pool:
        headers["X-MacProvider-Pool-Select"] = pool_id or matrix.pool_id(POOL[engine])
    if select is not None:
        headers["X-MacProvider-Engine-Select"] = select
    out = {"rid": rid, "stream": stream, "max_tokens": max_tokens, "body_bytes": len(raw), "bound": len(raw) // 4,
           "behaviour": "disconnect" if disconnect_after else "normal", "engine": engine,
           "route": "pool:" + POOL[engine] if (pool or pool_id) else "global"}
    conn = http.client.HTTPConnection("127.0.0.1", 19110, timeout=600)
    t0 = time.perf_counter()
    conn.request("POST", "/v1/chat/completions", body=raw, headers=headers)
    resp = conn.getresponse()
    out["status"] = resp.status
    out["engine_header"] = resp.getheader("X-MacProvider-Engine")
    text, usage, finish, done, events = "", None, None, False, 0
    if resp.status == 200 and stream:
        while True:
            line = resp.readline()
            if not line:
                break
            line = line.decode(errors="replace").rstrip("\r\n")
            if line == "data: [DONE]":
                done = True
            elif line.startswith("data: "):
                c = json.loads(line[6:])
                for ch in c.get("choices") or []:
                    d = (ch.get("delta") or {}).get("content")
                    if d:
                        text += d
                        events += 1
                    finish = ch.get("finish_reason") or finish
                if c.get("usage"):
                    usage = c["usage"]
                if c.get("error"):
                    out["stream_error"] = c["error"].get("code") if isinstance(c["error"], dict) else str(c["error"])[:60]
                if disconnect_after and events >= disconnect_after:
                    conn.sock.close()
                    out["disconnected_after_events"] = events
                    break
    else:
        data = resp.read()
        if resp.status == 200:
            doc = json.loads(data)
            text = (doc["choices"][0].get("message") or {}).get("content") or ""
            finish = doc["choices"][0].get("finish_reason")
            usage = doc.get("usage")
        else:
            try:
                out["error"] = (json.loads(data).get("error") or {}).get("code")
            except ValueError:
                out["error"] = data[:120].decode(errors="replace")
    out["elapsed_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    conn.close()
    out.update({"finish_reason": finish, "done": done, "content_events": events, "content_len": len(text),
                "content_sha256": hashlib.sha256(text.encode()).hexdigest()[:16] if text else None,
                "received_tokens": None,
                "usage": {k: usage.get(k) for k in ("prompt_tokens", "completion_tokens")} if usage else None})
    return out


def settle(recs, timeout=240):
    """Wait until every request's finality is closed (or timeout); return the
    evidence per request."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if all((matrix.finality(r["rid"]) or {}).get("closed") for r in recs):
            break
        time.sleep(3)
    time.sleep(2)  # the gateway reconciler applies finality on its 5 s tick
    gdeadline = time.time() + 30
    while time.time() < gdeadline:
        g = matrix.gdb()
        active = [r for r in recs if g.execute("SELECT 1 FROM quota_reservations WHERE request_id = ? AND status = 'active'", (r["rid"],)).fetchone()]
        g.close()
        if not active:
            break
        time.sleep(2)
    out = []
    for r in recs:
        ev = matrix.gather(r["rid"])
        ev["finality"] = matrix.finality(r["rid"])
        out.append(ev)
    return out


def debit_of(ev):
    res, use = ev["reservation"], ev["usage_event"]
    if use and res and res["status"] == "settled":
        return [use["prompt_tokens"], use["completion_tokens"]]
    return [0, 0]


def rows_brief(ev):
    """The settlement rows that matter, compact, for the summary."""
    v = ev["verdicts"][-1] if ev["verdicts"] else {}
    a = ev["attempt_outputs"][-1] if ev["attempt_outputs"] else {}
    led = [r for r in ev["ledger"] if r["status"] == 200] or ev["ledger"]
    l = led[-1] if led else {}
    f = ev["finality"] or {}
    return {
        "verdict": {k: v.get(k) for k in ("receipt_result", "settlement_outcome", "reason", "closed")},
        "attempt": {k: a.get(k) for k in ("terminal_state", "usage_source", "billable")},
        "ledger": {k: l.get(k) for k in ("usage_source", "provider_reported_prompt_tokens", "charged_prompt_tokens", "prompt_tokens",
                                         "completion_tokens", "provider_credits", "payable", "quarantined", "quarantine_reason")},
        "finality": {k: f.get(k) for k in ("closed", "mode", "outcome", "reason", "token_source", "prompt_tokens", "completion_tokens")},
        "gateway_debit": debit_of(ev),
        "gateway_reservation": (ev["reservation"] or {}).get("status"),
    }


def paid_checks(rec, ev):
    """(ok, failed-check names, rows) for a paid 200 request."""
    rows = rows_brief(ev)
    fails = []
    if rec["status"] != 200:
        fails.append(f"http_{rec['status']}")
    if rec["stream"] and not (rec.get("done") and rec.get("finish_reason") and not rec.get("stream_error")):
        fails.append("stream_incomplete")
    v = rows["verdict"]
    if not (v.get("closed") == 1 and v.get("receipt_result") == "valid" and v.get("settlement_outcome") == "verified"):
        fails.append(f"verdict={v.get('settlement_outcome')}/{v.get('reason')}")
    if rows["attempt"].get("usage_source") != "pool_operator_attested":
        fails.append(f"usage_source={rows['attempt'].get('usage_source')}")
    if not any(r["payable"] and (r["provider_credits"] or 0) > 0 for r in ev["ledger"]):
        fails.append("no_payable_credit")
    f, l = rows["finality"], rows["ledger"]
    fin = [f.get("prompt_tokens"), f.get("completion_tokens")] if f.get("outcome") == "verified" else [0, 0]
    led = [l.get("charged_prompt_tokens") if l.get("charged_prompt_tokens") is not None else l.get("prompt_tokens"), l.get("completion_tokens")]
    if not (rows["gateway_debit"] == fin == led):
        fails.append(f"debit{rows['gateway_debit']}/finality{fin}/ledger{led}")
    return not fails, fails, rows


def annotate(rec, rows):
    """Name the production bug a failure matches, from observed values only."""
    reason = rows["verdict"].get("reason") or ""
    l = rows["ledger"]
    rep, chg = l.get("provider_reported_prompt_tokens"), l.get("charged_prompt_tokens")
    notes = []
    if rep is not None and chg is not None and rep > chg:
        notes.append(f"reported prompt {rep} > bound-clamped {chg}")
    if "usage_mismatch" in reason:
        notes.append("BUG-1 usage_mismatch")
    if "output_hash_mismatch" in reason:
        notes.append("BUG-2 output_hash_mismatch")
    return "; ".join(notes)


RESULTS = []


def result(engine, case, expected, ok, actual, recs=(), rows=(), error=None):
    status = "ERROR" if error else ("PASS" if ok else "FAIL")
    entry = {"engine": engine, "case": case, "expected": expected, "status": status, "actual": actual,
             "request_ids": [r["rid"] for r in recs], "rows": list(rows), "error": error}
    RESULTS.append(entry)
    print(f"{status} [{engine}] {case}: {actual if not error else error}", flush=True)


def case_paid(engine, case, content, stream, n=2):
    recs = [send(engine, content=content, stream=stream, select=engine) for _ in range(n)]
    evs = settle(recs)
    allok, actual, rows = True, [], []
    for rec, ev in zip(recs, evs):
        ok, fails, r = paid_checks(rec, ev)
        allok &= ok
        r["buyer_usage"] = rec.get("usage")
        r["coordinator_bound_estimate"] = rec["bound"]
        r["status"] = rec["status"]
        rows.append(r)
        actual.append(("ok" if ok else ",".join(fails)) + (f" [{annotate(rec, r)}]" if annotate(rec, r) else ""))
    result(engine, case, "200; verified/valid receipt; pool_operator_attested; payable credit; debit==finality==ledger",
           allok, " | ".join(actual), recs, rows)


def case_disconnect(engine, repeat=2):
    content = "Write a long story about a lighthouse keeper in a storm. Ignore the padding that follows:" + PAD + " ({ref})"
    recs, rows, actual, allok = [], [], [], True
    for _ in range(repeat):
        recs.append(send(engine, content=content, stream=True, max_tokens=400, select=engine, disconnect_after=3))
    evs = settle(recs)
    for rec, ev in zip(recs, evs):
        debit = debit_of(ev)
        payable = [r for r in ev["ledger"] if r["payable"] and r["provider_credits"] > 0]
        if rec["status"] == 200 and rec.get("content_events"):
            ok, obs = matrix.disconnect_prefix(rec, ev, debit, payable)
        else:
            ok, obs = False, {"status": rec["status"], "content_events": rec.get("content_events")}
        r = rows_brief(ev)
        r["disconnect"] = obs
        rows.append(r)
        allok &= ok
        note = annotate(rec, r)
        actual.append(f"{r['attempt'].get('terminal_state')}/{r['verdict'].get('settlement_outcome')}/{r['verdict'].get('reason')} "
                      f"debit={debit} prefix={obs.get('verified_prefix_billable')} events={rec.get('content_events')}" + (f" [{note}]" if note else ""))
    result(engine, "disconnect_220ms_rtt", "buyer_cancel; valid+verified receipt over the delivered prefix; 0 < debit <= prefix < max_tokens",
           allok, " | ".join(actual), recs, rows)


def counts():
    c = matrix.cdb()
    snaps = c.execute("SELECT COUNT(*) FROM settlement_route_snapshots").fetchone()[0]
    led = c.execute("SELECT COUNT(*) FROM ledger_request_credits").fetchone()[0]
    c.close()
    tap = LAB / "logs" / "upstream-usage.jsonl"
    return snaps, led, len(tap.read_text().splitlines()) if tap.exists() else 0


def case_refusals(engine):
    pid = matrix.pool_id(POOL[engine])
    tries = [
        ("global+engine", dict(pool=False, select=engine), 503, "engine_unavailable"),
        ("disallowed_engine", dict(select=OTHER[engine]), 503, "engine_unavailable"),
        ("malformed_selector", dict(select=engine.upper()), 400, "invalid_engine_selection"),
        ("pool_model_without_pool", dict(pool=False, model=f"pool/{pid}/lab-model"), 404, "model_not_found"),
    ]
    for name, kw, want_status, want_code in tries:
        before = counts()
        recs = [send(engine, content="Hi ({ref})", stream=s, **kw) for s in (False, True)]
        time.sleep(1)
        after = counts()
        ok = all(r["status"] == want_status and r.get("error") == want_code for r in recs) and after == before
        actual = f"{[(r['status'], r.get('error')) for r in recs]} new snapshots/ledger/engine calls={[a - b for a, b in zip(after, before)]}"
        result(engine, f"refusal:{name}", f"{want_status} {want_code}; no snapshot/ledger row/engine call", ok, actual, recs)


def admin(method, path, body):
    req = urllib.request.Request("http://127.0.0.1:19102" + path, method=method, data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {secret('operator_key')}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read() or b"{}")


def lifecycle(pid, action):
    op = f"op-pearl-{action}-{uuid.uuid4().hex[:12]}"
    if action == "pause":
        return admin("POST", f"/admin/trust-pools/pools/{pid}/lifecycle", {"operation_id": op, "lifecycle": "paused", "reason": "lab-pearl-shaped"})
    return admin("POST", f"/admin/trust-pools/pools/{pid}/promote", {"operation_id": op, "reason": "lab-pearl-shaped"})


def ensure_other_account():
    """A second active gateway account with no pool authorization (the R007
    unauthorized class). Inserted like seed_gateway.py, while the gateway runs."""
    out = LAB / "keys" / f"buyer-key-{OTHER_ACCOUNT}"
    if out.exists():
        return
    now = datetime.now(timezone.utc).isoformat()
    key = "mp_" + base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    digest = hmac.new(secret("key_hash_secret").encode(), key.encode(), hashlib.sha256).digest()
    with sqlite3.connect(LAB / "db" / "gateway.db", timeout=10) as db:
        db.execute("INSERT OR IGNORE INTO accounts(account_id, status, quota_class, concurrency_class, created_at) VALUES(?, 'active', 'default', 'default', ?)",
                   (OTHER_ACCOUNT, now))
        db.execute("INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at) VALUES(?, ?, ?, ?, 'active', ?)",
                   ("key_" + secrets.token_hex(16), OTHER_ACCOUNT, digest, key[:12], now))
    out.write_text(key + "\n")
    out.chmod(0o600)


def probe(account, pool_id):
    """One timed pool rejection: (ms, status, code)."""
    raw = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": "timing-floor-probe"}], "max_tokens": 1}, separators=WS).encode()
    conn = http.client.HTTPConnection("127.0.0.1", 19110, timeout=30)
    conn.connect()
    t0 = time.perf_counter()
    conn.request("POST", "/v1/chat/completions", body=raw, headers={
        "Authorization": f"Bearer {key_of(account)}", "Content-Type": "application/json", "X-MacProvider-Pool-Select": pool_id})
    resp = conn.getresponse()
    data = resp.read()
    ms = (time.perf_counter() - t0) * 1000.0
    conn.close()
    try:
        code = (json.loads(data).get("error") or {}).get("code")
    except ValueError:
        code = None
    return ms, resp.status, code


def case_pause_r007(engine, samples):
    pid = matrix.pool_id(POOL[engine])
    status, doc = lifecycle(pid, "pause")
    if status not in (200, 202):
        result(engine, "pause", "503 pool_unavailable while paused", False, "", error=f"pause admin -> {status} {json.dumps(doc)[:300]}")
        return
    rec, deadline = None, time.time() + 60
    while time.time() < deadline:
        rec = send(engine, content="Hi ({ref})", stream=False, select=engine)
        if rec["status"] != 200:
            break
        time.sleep(2)
    result(engine, "pause", "503 pool_unavailable", rec["status"] == 503 and rec.get("error") == "pool_unavailable",
           f"{rec['status']} {rec.get('error')}", [rec])
    # R007: the three rejection classes while the pool is paused.
    ensure_other_account()
    unknown = base64.urlsafe_b64encode(secrets.token_bytes(16)).rstrip(b"=").decode()
    classes = {"unknown": (matrix.ACCOUNT, unknown), "unauthorized": (OTHER_ACCOUNT, pid), "disabled": (matrix.ACCOUNT, pid)}
    for name, (acct, p) in classes.items():  # warm every path once (connections, projection refresh)
        probe(acct, p)
    order = [name for name in classes for _ in range(samples)]
    random.shuffle(order)
    measured, bad = {k: [] for k in classes}, []
    for name in order:
        ms, st, code = probe(*classes[name])
        if st != 503 or code != "pool_unavailable":
            bad.append((name, st, code))
        measured[name].append(round(ms, 3))
    OUT.mkdir(parents=True, exist_ok=True)
    sj = OUT / f"r007-samples-{engine}.json"
    sj.write_text(json.dumps(measured))
    proc = subprocess.run([sys.executable, str(HERE.parent.parent / "measure-pool-rejection-timing-floor.py"), "--samples-json", str(sj)],
                          capture_output=True, text=True)
    p50 = {k: round(sorted(v)[len(v) // 2], 1) for k, v in measured.items()}
    try:
        ev = json.loads(proc.stdout)
        within = ev["within_r007_bounds"]
        t = ev["pool_rejection_timing"]
        actual = (f"p50 unknown/unauthorized/disabled={p50['unknown']}/{p50['unauthorized']}/{p50['disabled']} ms; "
                  f"p95 delta={t['p95_delta_ms']:.1f} ms; p99 delta={t['p99_delta_ms']:.1f} ms; MWU p={t['mann_whitney_p_value']:.2g}; "
                  f"within_r007_bounds={within}")
    except (ValueError, KeyError):
        within = False
        actual = f"p50={p50}; evaluator exit {proc.returncode}: {(proc.stderr or proc.stdout).strip()[:300]}"
    if bad:
        actual += f"; non-pool_unavailable answers: {bad[:6]}"
    result(engine, "r007_timing", f"{samples}/class shuffled; every answer 503 pool_unavailable; within SPEC-043-R007 bounds",
           within and not bad, actual, rows=[{"samples_json": str(sj), "evaluator_exit": proc.returncode}])
    status, doc = lifecycle(pid, "resume")
    if status not in (200, 202):
        result(engine, "resume", "200 after resume", False, "", error=f"promote admin -> {status} {json.dumps(doc)[:300]}")
        return
    deadline = time.time() + 90
    while time.time() < deadline:
        rec = send(engine, content="Hi ({ref})", stream=False, select=engine)
        if rec["status"] == 200:
            break
        time.sleep(3)
    result(engine, "resume", "200", rec["status"] == 200, f"{rec['status']} {rec.get('error')}", [rec])


def cmd_cases(a):
    e = a.engine
    pad = "Reply with one word. Ignore the padding:" + PAD + " ({ref})"
    steps = [
        ("paid_short_ns", lambda: case_paid(e, "paid_short_ns", "Hi ({ref})", False)),
        ("paid_short_stream", lambda: case_paid(e, "paid_short_stream", "Hi ({ref})", True)),
        ("paid_long_ns(control)", lambda: case_paid(e, "paid_long_ns(control)", pad, False)),
        ("paid_long_stream(control)", lambda: case_paid(e, "paid_long_stream(control)", pad, True)),
        ("disconnect_220ms_rtt", lambda: case_disconnect(e)),
        ("refusals", lambda: case_refusals(e)),
        ("pause_resume_r007", lambda: case_pause_r007(e, a.samples)),
    ]
    for name, step in steps:
        try:
            step()
        except Exception as err:  # a harness error is recorded, never counted as a pass
            result(e, name, "", False, "", error=f"{type(err).__name__}: {err}")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{e}.json").write_text(json.dumps(RESULTS, indent=1, sort_keys=True, default=str))


def cmd_summary(a):
    rows = []
    for f in sorted(OUT.glob("*.json")):
        if f.name.startswith("r007-"):
            continue
        rows += json.loads(f.read_text())
    meta = OUT / "run-meta.json"
    if meta.exists():
        m = json.loads(meta.read_text())
        print(f"ref {m.get('ref')} | harness {m.get('harness')} | started {m.get('started')} | LAB {LAB}\n")
    print("| Engine | Case | Expected | Actual | Result | Request ids |")
    print("|---|---|---|---|---|---|")
    for r in rows:
        actual = (r["actual"] or r["error"] or "").replace("|", "/")
        print(f"| {r['engine']} | {r['case']} | {r['expected']} | {actual} | {r['status']} | {' '.join(x[:8] for x in r['request_ids'])} |")
    print("\nSettlement rows per request (verdict / attempt / ledger / finality / gateway debit):")
    for r in rows:
        for rid, row in zip(r["request_ids"], r["rows"] or [None] * len(r["request_ids"])):
            if row:
                print(f"- {r['engine']} {r['case']} {rid}: {json.dumps(row, sort_keys=True, default=str)}")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cases")
    c.add_argument("--engine", required=True, choices=sorted(POOL))
    c.add_argument("--samples", type=int, default=24)
    sub.add_parser("summary")
    a = p.parse_args()
    {"cases": cmd_cases, "summary": cmd_summary}[a.cmd](a)


if __name__ == "__main__":
    main()
