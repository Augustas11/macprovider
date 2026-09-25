#!/usr/bin/env python3
"""#1690 e2e matrix: buyer requests through the lab gateway, then settlement
invariants across the gateway and coordinator databases.

  matrix.py send --label L --engine E [--route pool:NAME|global] [--select SEL]
                 [--shapes plain,tool,long,cap] [--behaviours normal,disconnect,slow,early_close,abort]
  matrix.py selection --label L --engine E [--pools A,M,O]
  matrix.py settle --label L [--timeout S] [--expect-refund] [--allow-hold]

send records one JSON line per request in LAB/e2e/requests.jsonl (the buyer's
view: status, error code, X-MacProvider-Engine, content length and sha256 but
never text, tool calls, finish reason, visible usage, events received). A
request carries its own X-Request-ID, so every row in both databases is found
by that id.

settle waits until no reservation of the label is active, then checks, per
request:
  no_hold             the gateway reservation is settled or refunded, not held
  debit_eq_settled    buyer debit (usage_events) equals the coordinator's
                      settled tokens: finality tokens when finality is closed
                      and verified; zero when it is closed and not verified;
                      the ledger's charged tokens when finality is legacy
  credit_has_evidence a payable provider credit on a loopback runtime (or any
                      enforce credit) has a closed verified verdict with a
                      valid receipt
  credit_implies_debit a payable provider credit means the buyer was debited
  no_undelivered_bill billed completion never exceeds what the engine
                      generated, and an aborted request bills nothing
  delivered_not_free  a fully read 200 with output is debited
  buyer_usage_eq_debit the usage the buyer saw equals its debit
and writes LAB/e2e/results/<label>.json plus PASS/FAIL lines. Prompts and
completions are never written anywhere.
"""
import argparse
import hashlib
import http.client
import json
import os
import pathlib
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.request
import uuid

LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-1690-m6/e2e"))
STATE = LAB / "e2e"
REQS = STATE / "requests.jsonl"
MODEL = os.environ.get("E2E_MODEL", "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
ACCOUNT = "acct-lab-1690-buyer"
ENGINE_CLASS = {"native": "mlx_cache", "llamacpp": "llamacpp_loopback", "mlxlm": "mlxlm_loopback", "ollama": "ollama_loopback"}
POOL_ALLOW = {"A": "llamacpp_loopback", "M": "mlxlm_loopback", "O": "ollama_loopback", "NO": "mlx_cache"}
TOOLS = [{"type": "function", "function": {"name": "get_weather", "description": "Get the current weather for a city.",
                                           "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
SHAPES = {
    "plain": {"prompt": "Name three colors.", "max_tokens": 32},
    "tool": {"prompt": "What is the weather in Paris right now? Use the get_weather tool.", "max_tokens": 96, "tools": True},
    "long": {"prompt": "Write a detailed story of about 600 words about a lighthouse keeper and a storm.", "max_tokens": 700},
    "cap": {"prompt": "Write a detailed story of about 600 words about a lighthouse keeper and a storm.", "max_tokens": 8},
}
# Shapes a behaviour runs on, and whether it streams.
BEHAVIOURS = {
    "normal": [("plain", False), ("plain", True), ("tool", False), ("tool", True), ("long", False), ("long", True), ("cap", False), ("cap", True)],
    "disconnect": [("long", True)],
    "slow": [("plain", True), ("long", True)],
    "early_close": [("long", False)],
    "abort": [("long", False)],
}


def secret(name):
    return json.loads((LAB / "keys" / "secrets.json").read_text())[name]


def buyer_key():
    return (LAB / "keys" / f"buyer-key-{ACCOUNT}").read_text().strip()


def pool_id(name):
    return (LAB / "pools" / name / "pool_id").read_text().strip()


def one(label, engine, route, select, shape, stream, behaviour, extra_headers=None):
    rid = str(uuid.uuid4())
    spec = SHAPES[shape]
    headers = {"Authorization": f"Bearer {buyer_key()}", "Content-Type": "application/json", "X-Request-ID": rid}
    if route.startswith("pool:"):
        headers["X-MacProvider-Pool-Select"] = pool_id(route[5:])
    body = {"model": MODEL, "messages": [{"role": "user", "content": f"{spec['prompt']} (ref {rid[:8]})"}], "max_tokens": spec["max_tokens"]}
    if spec.get("tools"):
        body["tools"] = TOOLS
    if stream:
        body["stream"] = True
        body["stream_options"] = {"include_usage": True}
    out = {"label": label, "rid": rid, "engine": engine, "route": route, "select": select, "shape": shape, "stream": stream,
           "behaviour": behaviour, "max_tokens": spec["max_tokens"], "ts": time.time()}
    conn = http.client.HTTPConnection("127.0.0.1", 19110, timeout=600)
    conn.connect()
    if behaviour == "slow":
        conn.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
    conn.putrequest("POST", "/v1/chat/completions", skip_accept_encoding=True)
    for k, v in headers.items():
        conn.putheader(k, v)
    for v in select if isinstance(select, list) else ([select] if select is not None else []):
        conn.putheader("X-MacProvider-Engine-Select", v)
    for k, v in (extra_headers or {}).items():
        conn.putheader(k, v)
    raw = json.dumps(body).encode()
    conn.putheader("Content-Length", str(len(raw)))
    conn.endheaders(raw)
    t0 = time.time()
    if behaviour == "abort":
        time.sleep(0.5)
        conn.sock.close()
        out.update({"status": None, "aborted_after_s": 0.5})
        return out
    resp = conn.getresponse()
    out["status"] = resp.status
    out["engine_header"] = resp.getheader("X-MacProvider-Engine")
    out["echo_request_id"] = resp.getheader("X-Request-ID")
    out["headers_after_s"] = round(time.time() - t0, 2)
    if behaviour == "early_close":
        conn.sock.close()
        return out
    text, tool_calls, finish, usage, events, content_events, done = "", {}, None, None, 0, 0, False
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
                events += 1
                if c.get("error"):
                    out["stream_error"] = (c["error"] or {}).get("code") if isinstance(c["error"], dict) else str(c["error"])[:60]
                for ch in c.get("choices") or []:
                    d = ch.get("delta") or {}
                    if d.get("content"):
                        text += d["content"]
                        content_events += 1
                    for tc in d.get("tool_calls") or []:
                        slot = tool_calls.setdefault(tc.get("index", 0), {"name": "", "args": ""})
                        fn = tc.get("function") or {}
                        slot["name"] += fn.get("name") or ""
                        slot["args"] += fn.get("arguments") or ""
                        content_events += 1
                    finish = ch.get("finish_reason") or finish
                if c.get("usage"):
                    usage = c["usage"]
                if behaviour == "disconnect" and content_events >= 4:
                    conn.sock.close()
                    out["disconnected_after_events"] = content_events
                    break
            if behaviour == "slow":
                time.sleep(0.05)
    else:
        data = resp.read()
        if resp.status == 200:
            doc = json.loads(data)
            msg = doc["choices"][0].get("message") or {}
            text = msg.get("content") or ""
            for i, tc in enumerate(msg.get("tool_calls") or []):
                tool_calls[i] = {"name": (tc.get("function") or {}).get("name"), "args": (tc.get("function") or {}).get("arguments")}
            finish = doc["choices"][0].get("finish_reason")
            usage = doc.get("usage")
        else:
            try:
                out["error"] = (json.loads(data).get("error") or {}).get("code")
            except ValueError:
                out["error"] = data[:120].decode(errors="replace")
    conn.close()
    out.update({"elapsed_s": round(time.time() - t0, 2), "finish_reason": finish, "done": done, "events": events,
                "content_events": content_events, "content_len": len(text),
                "content_sha256": hashlib.sha256(text.encode()).hexdigest()[:16] if text else None,
                "tool_calls": [{"name": v["name"], "args_valid_json": valid_json(v["args"])} for v in tool_calls.values()],
                "usage": {k: usage.get(k) for k in ("prompt_tokens", "completion_tokens")} if usage else None})
    return out


def valid_json(s):
    try:
        json.loads(s or "")
        return True
    except ValueError:
        return False


def append(rec):
    STATE.mkdir(parents=True, exist_ok=True)
    with open(REQS, "a") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")
    brief = {k: rec.get(k) for k in ("route", "select", "shape", "stream", "behaviour", "status", "error", "engine_header", "finish_reason", "usage")}
    print(json.dumps(brief), flush=True)


def cmd_send(a):
    shapes = set(a.shapes.split(",")) if a.shapes else None
    for behaviour in a.behaviours.split(","):
        for shape, stream in BEHAVIOURS[behaviour]:
            if shapes and shape not in shapes:
                continue
            if a.stream_only and not stream:
                continue
            flag = LAB / "run" / "slow-stream"
            slow_tap = behaviour == "disconnect" and a.engine != "native"
            if slow_tap:
                flag.touch()
            try:
                append(one(a.label, a.engine, a.route, a.select, shape, stream, behaviour))
            finally:
                if slow_tap and flag.exists():
                    flag.unlink()


def expected_selection(engine, route, select):
    """(status, error, served_class) the SPEC-006-R016 / SPEC-042-R014 rules predict."""
    member = ENGINE_CLASS[engine]
    if isinstance(select, list) and len(set(select)) > 1:
        return 400, "invalid_engine_selection", None
    sel = select[0] if isinstance(select, list) else select
    if sel is not None and sel.strip() != "" and sel not in ENGINE_CLASS:
        return 400, "invalid_engine_selection", None
    if sel is not None and sel.strip() == "":
        sel = None
    want = ENGINE_CLASS[sel] if sel else None
    if route == "global":
        if want and want != "mlx_cache":
            return 503, "engine_unavailable", None
        if member == "mlx_cache":
            return 200, None, "mlx_cache"
        return 503, "engine_unavailable" if want else "byom_non_settlement_unavailable", None
    allowed = {"mlx_cache", POOL_ALLOW[route[5:]]}
    if want:
        if want == member and member in allowed:
            return 200, None, member
        return 503, "engine_unavailable", None
    if member in allowed:
        return 200, None, member
    return 503, None, None


def cmd_selection(a):
    selectors = [None, "native", "llamacpp", "mlxlm", "ollama", "LLAMACPP", "vllm", ["native", "llamacpp"], ""]
    routes = ["global"] + [f"pool:{p}" for p in a.pools.split(",") if (LAB / "pools" / p / "pool_id").exists()]
    results = []
    for route in routes:
        for sel in selectors:
            rec = one(a.label, a.engine, route, sel, "plain", False, "normal")
            rec["expected"] = dict(zip(("status", "error", "engine"), expected_selection(a.engine, route, sel)))
            append(rec)
            results.append(rec)
    fails = 0
    for r in results:
        e = r["expected"]
        ok = r["status"] == e["status"] and (e["error"] is None or r.get("error") == e["error"]) and (e["engine"] is None or r.get("engine_header") == e["engine"])
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'} [selection:{a.label}] {r['route']} select={r['select']!r}: got {r['status']} {r.get('error')} {r.get('engine_header')} want {e}", flush=True)
    return fails


def gdb():
    return sqlite3.connect(f"file:{LAB / 'db' / 'gateway.db'}?mode=ro", uri=True, timeout=10)


def cdb():
    return sqlite3.connect(f"file:{LAB / 'db' / 'coordinator.db'}?mode=ro", uri=True, timeout=10)


def rows(con, sql, params):
    cur = con.execute(sql, params)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def finality(rid):
    req = urllib.request.Request(f"http://127.0.0.1:19102/internal/settlement/finality?account_id={ACCOUNT}&request_id={rid}",
                                 headers={"Authorization": f"Bearer {secret('gateway_service_token')}"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=10))
    except urllib.error.HTTPError as err:
        return {"http_status": err.code}


def gather(rid):
    """Both databases' rows for one gateway request id. The coordinator keys
    its rows by its own internal request id; request_log maps the gateway's
    X-Request-ID (external_request_id) to every internal id, retries included."""
    g, c = gdb(), cdb()
    res = rows(g, "SELECT status, settled_tokens, reserved_tokens, settlement_hold FROM quota_reservations WHERE request_id = ?", (rid,))
    use = rows(g, "SELECT prompt_tokens, completion_tokens, total_tokens, token_source, outcome FROM usage_events WHERE request_id = ?", (rid,))
    log = rows(c, "SELECT request_id, attempt_n, status, error_code, pool_id, prompt_tokens, completion_tokens, estimated_completion_tokens FROM request_log WHERE external_request_id = ? ORDER BY id", (rid,))
    ids = sorted({r["request_id"] for r in log} | {rid})
    q = ",".join("?" * len(ids))
    led = rows(c, f"SELECT id, request_id, attempt_n, provider_id, status, stream, prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source, gross_credits, provider_credits, quarantined, quarantine_reason, settlement_policy_mode FROM ledger_request_credits WHERE request_id IN ({q}) ORDER BY id", ids)
    pay = {r[0] for r in c.execute(f"SELECT id FROM spec022_payable_request_credits WHERE request_id IN ({q})", ids)}
    for r in led:
        r["payable"] = r["id"] in pay
    # An older coordinator (mixed-version runs) lacks the #1690 columns.
    have = {r[1] for r in c.execute("PRAGMA table_info(settlement_receipt_verdicts)")}
    vcols = [x for x in ("request_id", "attempt_n", "receipt_present", "receipt_version", "receipt_result", "settlement_outcome",
                         "reason", "closed", "pool_label_status", "route_snapshot_mode") if x in have]
    ver = rows(c, f"SELECT {', '.join(vcols)} FROM settlement_receipt_verdicts WHERE request_id IN ({q}) ORDER BY id", ids)
    snap = []
    for r in rows(c, f"SELECT request_id, attempt_n, route_snapshot_json FROM settlement_route_snapshots WHERE request_id IN ({q}) ORDER BY id", ids):
        s = json.loads(r["route_snapshot_json"] or "{}")
        snap.append({"request_id": r["request_id"], "attempt_n": r["attempt_n"], **{k: s.get(k) for k in ("pool_id", "runtime_source", "route_snapshot_mode", "manifest_version")}})
    sao = []
    for r in rows(c, f"SELECT request_id, attempt_n, terminal_state, usage_source, usage_canonical_json FROM settlement_attempt_outputs WHERE request_id IN ({q}) ORDER BY id", ids):
        u = json.loads(r["usage_canonical_json"] or "{}")
        sao.append({"request_id": r["request_id"], "attempt_n": r["attempt_n"], "terminal_state": r["terminal_state"], "usage_source": r["usage_source"],
                    "billable": [u.get("billable_input_tokens"), u.get("billable_output_tokens")], "delivered_output_bytes": u.get("delivered_output_bytes")})
    return {"reservation": res[0] if res else None, "usage_event": use[0] if use else None, "request_log": log, "ledger": led,
            "verdicts": ver, "snapshots": snap, "attempt_outputs": sao}


def upstream_for(rec):
    """The usage tap line whose content sha matches (external engines only)."""
    path = LAB / "logs" / "upstream-usage.jsonl"
    if not path.exists() or not rec.get("content_sha256"):
        return None
    for line in path.read_text().splitlines():
        u = json.loads(line)
        if u.get("content_sha256") == rec["content_sha256"]:
            return u.get("usage")
    return None


def evaluate(rec, ev, expect_refund=False):
    """Return a list of (check, ok, observed)."""
    out = []
    res, use, fin = ev["reservation"], ev["usage_event"], ev["finality"]
    debit = (use["prompt_tokens"], use["completion_tokens"]) if use and res and res["status"] == "settled" else (0, 0)
    if res is None and use is None:
        out.append(("no_hold", True, "no reservation (refused before reservation)"))
    else:
        out.append(("no_hold", res is not None and res["status"] in ("settled", "refunded") and res["settlement_hold"] == 0,
                    {"reservation": res}))
    payable = [r for r in ev["ledger"] if r["payable"] and r["provider_credits"] > 0]
    ok_rows = [r for r in ev["ledger"] if r["status"] == 200]
    fmode = fin.get("mode") if fin else None
    if fin and fin.get("closed") and fmode in ("enforce", "observe"):
        if fin.get("outcome") == "verified":
            want = (fin.get("prompt_tokens"), fin.get("completion_tokens"))
        else:
            want = (0, 0)
        basis = f"finality {fmode}/{fin.get('outcome')}"
    elif ok_rows:
        r = ok_rows[-1]
        cp = r["charged_prompt_tokens"] if r["charged_prompt_tokens"] is not None else r["prompt_tokens"]
        want = (cp or 0, r["completion_tokens"] or 0)
        basis = f"ledger {r['usage_source']} (finality {fmode or fin})"
    else:
        want = (0, 0)
        basis = f"no 200 attempt (finality {fin})"
    out.append(("debit_eq_settled", tuple(debit) == tuple(want), {"debit": debit, "settled": want, "basis": basis,
                                                                  "gateway": {"status": (res or {}).get("status"), "token_source": (use or {}).get("token_source"), "outcome": (use or {}).get("outcome")}}))
    loop = {(s["request_id"], s["attempt_n"]): s.get("runtime_source") for s in ev["snapshots"]}
    bad = []
    for r in payable:
        key = (r["request_id"], r["attempt_n"])
        v = [x for x in ev["verdicts"] if (x["request_id"], x["attempt_n"]) == key]
        needs = r["settlement_policy_mode"] == "enforce" or (loop.get(key) not in (None, "", "mlx_cache"))
        if needs and not any(x["closed"] == 1 and x["settlement_outcome"] == "verified" and x["receipt_result"] == "valid" for x in v):
            bad.append({"ledger": r, "verdicts": v, "runtime_source": loop.get(key)})
    out.append(("credit_has_evidence", not bad, bad or f"{len(payable)} payable credit(s) {[r['provider_credits'] for r in payable]}"))
    out.append(("credit_implies_debit", not payable or sum(debit) > 0, {"payable_credits": [r["provider_credits"] for r in payable], "debit": debit}))
    gen = upstream_for(rec)
    billed_c = debit[1]
    ok = True
    why = {"billed_completion": billed_c, "max_tokens": rec["max_tokens"], "engine_generated": gen}
    if billed_c > rec["max_tokens"]:
        ok = False
    if gen and billed_c > (gen.get("completion_tokens") or 0):
        ok = False
    if rec["behaviour"] == "abort" and sum(debit) > 0:
        ok = False
        why["note"] = "aborted before response headers but debited"
    if rec["behaviour"] == "disconnect":
        why["received_events"] = rec.get("content_events")
        if billed_c >= rec["max_tokens"]:
            ok = False
            why["note"] = "disconnected stream billed the full max_tokens"
    out.append(("no_undelivered_bill", ok, why))
    delivered = rec.get("status") == 200 and rec["behaviour"] in ("normal", "slow") and (rec.get("content_len") or rec.get("tool_calls"))
    if rec.get("status") == 200 and rec["behaviour"] in ("normal", "slow"):
        complete = bool(rec.get("finish_reason")) and (not rec["stream"] or (rec.get("done") and not rec.get("stream_error")))
        out.append(("stream_complete", complete, {"finish": rec.get("finish_reason"), "done": rec.get("done"), "stream_error": rec.get("stream_error"),
                                                  "content_events": rec.get("content_events"), "max_tokens": rec["max_tokens"]}))
    if delivered:
        out.append(("delivered_not_free", sum(debit) > 0 or expect_refund, {"debit": debit, "finish": rec.get("finish_reason"), "expect_refund": expect_refund}))
    if rec["behaviour"] == "disconnect" and (rec.get("content_events") or 0) > 0:
        out.append(("delivered_not_free", sum(debit) > 0 or expect_refund, {"debit": debit, "received_events": rec.get("content_events"), "note": "partial stream"}))
    if delivered and rec.get("usage"):
        seen = (rec["usage"]["prompt_tokens"], rec["usage"]["completion_tokens"])
        name = "buyer_usage_eq_debit"
        # F1: the coordinator's independent prompt bound (hotpath.go
        # boundProviderReportedPromptTokens) charges fewer prompt tokens than
        # the engine reported and the buyer saw. Named so it is counted apart.
        if seen != tuple(debit) and seen[1] == debit[1] and any(
                (r["provider_reported_prompt_tokens"] or 0) == seen[0] and (r["charged_prompt_tokens"] or 0) == debit[0] < seen[0] for r in ok_rows):
            name = "buyer_usage_eq_debit[F1-prompt-bound]"
        out.append((name, seen == tuple(debit) or expect_refund, {"buyer_saw": seen, "debit": debit}))
    return out


def cmd_settle(a):
    recs = [json.loads(l) for l in REQS.read_text().splitlines() if l.strip()]
    recs = [r for r in recs if r["label"] == a.label]
    rids = [r["rid"] for r in recs]
    deadline = time.time() + a.timeout
    while True:
        g = gdb()
        active = [rid for rid in rids if g.execute("SELECT 1 FROM quota_reservations WHERE request_id = ? AND status = 'active'", (rid,)).fetchone()]
        g.close()
        if not active or time.time() > deadline:
            break
        time.sleep(5)
    waited = round(a.timeout - (deadline - time.time()), 1)
    results, fails = [], 0
    for rec in recs:
        ev = gather(rec["rid"])
        ev["finality"] = finality(rec["rid"])
        checks = evaluate(rec, ev, a.expect_refund)
        if a.allow_hold:
            checks = [c for c in checks if c[0] != "no_hold"] + [("no_hold(info)", True, [c for c in checks if c[0] == "no_hold"][0][2])]
        results.append({"request": rec, "evidence": ev, "checks": [{"check": c, "ok": ok, "observed": o} for c, ok, o in checks]})
        for c, ok, o in checks:
            if not ok:
                fails += 1
                print(f"FAIL [{a.label}] {rec['route']} {rec['shape']}/{'s' if rec['stream'] else 'ns'}/{rec['behaviour']} {c}: {json.dumps(o, default=str)[:900]}", flush=True)
    total = sum(len(r["checks"]) for r in results)
    out = STATE / "results" / f"{a.label}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"label": a.label, "waited_s": waited, "still_active": active, "results": results}, indent=1, sort_keys=True, default=str))
    print(f"{'PASS' if not fails else 'FAIL'} [{a.label}] {len(recs)} requests, {total - fails}/{total} checks, waited {waited}s, active {len(active)} -> {out}", flush=True)
    return fails


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send")
    s.add_argument("--label", required=True)
    s.add_argument("--engine", required=True, choices=sorted(ENGINE_CLASS))
    s.add_argument("--route", default="global")
    s.add_argument("--select")
    s.add_argument("--shapes")
    s.add_argument("--behaviours", default="normal,disconnect,slow,early_close,abort")
    s.add_argument("--stream-only", action="store_true")
    e = sub.add_parser("selection")
    e.add_argument("--label", required=True)
    e.add_argument("--engine", required=True, choices=sorted(ENGINE_CLASS))
    e.add_argument("--pools", default="A,M,O")
    t = sub.add_parser("settle")
    t.add_argument("--label", required=True)
    t.add_argument("--timeout", type=int, default=420)
    t.add_argument("--expect-refund", action="store_true")
    t.add_argument("--allow-hold", action="store_true")
    a = p.parse_args()
    if a.cmd == "send":
        cmd_send(a)
        return 0
    return 1 if {"selection": cmd_selection, "settle": cmd_settle}[a.cmd](a) else 0


if __name__ == "__main__":
    sys.exit(main())
