#!/usr/bin/env python3
"""Run the #1690 M6 cases against a rig that `rig.sh up` started.

  cases.py [--only CASE ...] [--spoof-binary PATH]

Each case prints PASS or FAIL lines with the observed values and writes its
sanitized captures to LAB/captures/. Cases: paid, omitted_usage, global,
fail_closed_pools, spoof, future_manifest, disputed, active_window,
generation_bump, concurrency, reconcile, and the #1690 M7 engine-selection cases
engine_llamacpp_pool, engine_llamacpp_global, engine_native_pool,
engine_ollama_pool, engine_absent, engine_invalid. omitted_usage and reconcile also run
`coordinator pool-rollback-preflight` (exit 3 while a pool attempt can still
settle, 0 once every pool verdict is closed).
`spoof` needs a lab-only CLI that honours LAB_SPOOF_RUNTIME_SOURCE (see the
evidence doc); it is skipped without --spoof-binary. It restarts serve for the
spoof runs and restores the normal lab CLI afterwards.
"""
import argparse
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import time
import urllib.request

LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-1690-m6"))
HERE = pathlib.Path(__file__).resolve().parent
CAPTURES = LAB / "captures"
RESULTS = []


def secret(name):
    return json.loads((LAB / "keys" / "secrets.json").read_text())[name]


def check(case, ok, what, observed):
    line = f"{'PASS' if ok else 'FAIL'} [{case}] {what}: {observed}"
    RESULTS.append(line)
    print(line, flush=True)


def buyer(*args):
    out = subprocess.run([sys.executable, str(HERE / "buyer.py"), *args], check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def db():
    return sqlite3.connect(f"file:{LAB / 'db' / 'coordinator.db'}?mode=ro", uri=True)


def snapshots_count():
    return db().execute("SELECT COUNT(*) FROM settlement_route_snapshots").fetchone()[0]


def upstream_lines():
    path = LAB / "logs" / "upstream-usage.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def last_attempts(n):
    """The last n requests' settlement rows, newest last."""
    con = db()
    ids = [r[0] for r in con.execute("SELECT request_id FROM settlement_route_snapshots ORDER BY id DESC LIMIT ?", (n,))][::-1]
    out = []
    for rid in ids:
        snap = json.loads(con.execute("SELECT route_snapshot_json FROM settlement_route_snapshots WHERE request_id = ? ORDER BY id DESC LIMIT 1", (rid,)).fetchone()[0])
        sao = con.execute("SELECT usage_source, usage_canonical_json, terminal_state FROM settlement_attempt_outputs WHERE request_id = ? ORDER BY id DESC LIMIT 1", (rid,)).fetchone()
        ver = con.execute("SELECT receipt_version, receipt_result, settlement_outcome, reason, pool_label_status FROM settlement_receipt_verdicts WHERE request_id = ? ORDER BY id DESC LIMIT 1", (rid,)).fetchone()
        led = con.execute("SELECT usage_source, prompt_tokens, completion_tokens, provider_credits, quarantined, quarantine_reason FROM ledger_request_credits WHERE request_id = ? ORDER BY id DESC LIMIT 1", (rid,)).fetchone()
        usage = json.loads(sao[1]) if sao else {}
        out.append({
            "request_id": rid,
            "snapshot": {k: snap.get(k) for k in ("pool_id", "manifest_version", "manifest_core_digest", "runtime_source", "pool_generation", "pool_operator_account_id", "route_snapshot_mode")},
            "usage_source": sao[0] if sao else None, "terminal_state": sao[2] if sao else None,
            "billable": (usage.get("billable_input_tokens"), usage.get("billable_output_tokens")),
            "receipt_version": ver[0] if ver else None, "receipt_result": ver[1] if ver else None,
            "settlement_outcome": ver[2] if ver else None, "reason": ver[3] if ver else None, "pool_label_status": ver[4] if ver else None,
            "ledger": dict(zip(("usage_source", "prompt_tokens", "completion_tokens", "provider_credits", "quarantined", "quarantine_reason"), led)) if led else None,
        })
    return out


def finality(request_id):
    req = urllib.request.Request(f"http://127.0.0.1:19102/internal/settlement/finality?account_id=acct-lab-1690-buyer&request_id={request_id}",
                                 headers={"Authorization": f"Bearer {secret('gateway_service_token')}"})
    return json.load(urllib.request.urlopen(req))


def save(name, doc):
    CAPTURES.mkdir(parents=True, exist_ok=True)
    (CAPTURES / f"{name}.json").write_text(json.dumps(doc, indent=2, sort_keys=True))


def pool(name, *args):
    subprocess.run([sys.executable, str(HERE / "pool_setup.py"), *args], check=True, capture_output=True, text=True)


def ensure_pool(name, *create_args):
    if not (LAB / "pools" / name / "pool_id").exists():
        pool(name, "create", name, *create_args)


def wait_settled(n, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows = last_attempts(n)
        if all(r["settlement_outcome"] for r in rows):
            return rows
        time.sleep(1)
    return last_attempts(n)


def case_paid():
    before = len(upstream_lines())
    served = buyer("--pool", "A", "--n", "2") + buyer("--pool", "A", "--stream", "--n", "2")
    rows = wait_settled(4)
    upstream = upstream_lines()[before:]
    save("paid", {"buyer": served, "attempts": rows, "upstream": upstream, "finality": [finality(r["request_id"]) for r in rows]})
    for r in rows:
        s = r["snapshot"]
        check("paid", s["pool_id"] and s["runtime_source"] == "llamacpp_loopback" and s["pool_generation"] and s["pool_operator_account_id"],
              "route snapshot R012 labels", s)
        check("paid", r["receipt_version"] == "4" and r["receipt_result"] == "valid" and r["settlement_outcome"] == "verified",
              "CLI v0.4 receipt verified", (r["receipt_version"], r["receipt_result"], r["settlement_outcome"], r["pool_label_status"]))
        check("paid", r["usage_source"] == "pool_operator_attested" and (r["ledger"] or {}).get("provider_credits", 0) > 0,
              "attested usage and ledger credit", (r["usage_source"], r["billable"], r["ledger"]))
        f = finality(r["request_id"])
        check("paid", f.get("token_source") == "pool_operator_attested", "finality token_source", f.get("token_source"))
    up = sorted((u["usage"]["prompt_tokens"], u["usage"]["completion_tokens"]) for u in upstream if u.get("usage"))
    attested = sorted(r["billable"] for r in rows)
    check("paid", [tuple(x) for x in attested] == up, "attested usage == llama-server usage", {"attested": attested, "upstream": up})
    check("paid", all(x["status"] == 200 for x in served) and all(x.get("stream_intact", True) is not False for x in served),
          "stream and non-stream served", [(x["stream"], x["status"], x.get("finish_reason")) for x in served])


def engine_refused(case, served, before, snaps, status, code, what):
    check(case, all(x["status"] == status and x.get("error") == code for x in served)
          and len(upstream_lines()) == before and snapshots_count() == snaps,
          what, {"buyer": [(x["stream"], x["status"], x.get("error"), x.get("engine")) for x in served],
                 "upstream_calls": len(upstream_lines()) - before, "new_snapshots": snapshots_count() - snaps})


def case_engine_llamacpp_pool():
    # SPEC-006-R016 / SPEC-042-R014: engine=llamacpp on pool A (v2 allowlist
    # llamacpp_loopback) is served by the llama.cpp member, discloses the
    # class, and settles exactly like an unselected pool request.
    before = len(upstream_lines())
    served = buyer("--pool", "A", "--engine", "llamacpp", "--n", "1") + buyer("--pool", "A", "--engine", "llamacpp", "--stream", "--n", "1")
    rows = wait_settled(2)
    upstream = upstream_lines()[before:]
    save("engine_llamacpp_pool", {"buyer": served, "attempts": rows, "upstream": upstream, "finality": [finality(r["request_id"]) for r in rows]})
    check("engine_llamacpp_pool", all(x["status"] == 200 and x.get("engine") == "llamacpp_loopback" and x.get("stream_intact", True) is not False for x in served),
          "served, X-MacProvider-Engine disclosed", [(x["stream"], x["status"], x.get("engine"), x.get("finish_reason")) for x in served])
    for r in rows:
        check("engine_llamacpp_pool", r["snapshot"]["runtime_source"] == "llamacpp_loopback" and r["snapshot"]["pool_id"],
              "route snapshot runtime_source", r["snapshot"])
        check("engine_llamacpp_pool", r["usage_source"] == "pool_operator_attested" and r["receipt_result"] == "valid"
              and r["settlement_outcome"] == "verified" and (r["ledger"] or {}).get("provider_credits", 0) > 0,
              "pool_operator_attested, verified receipt, ledger credit",
              (r["usage_source"], r["receipt_result"], r["settlement_outcome"], r["billable"], (r["ledger"] or {}).get("provider_credits")))
        check("engine_llamacpp_pool", finality(r["request_id"]).get("token_source") == "pool_operator_attested", "finality token_source",
              finality(r["request_id"]).get("token_source"))
    up = sorted((u["usage"]["prompt_tokens"], u["usage"]["completion_tokens"]) for u in upstream if u.get("usage"))
    check("engine_llamacpp_pool", sorted(tuple(r["billable"]) for r in rows) == [tuple(x) for x in up],
          "attested usage == llama-server usage", {"attested": sorted(r["billable"] for r in rows), "upstream": up})


def case_engine_llamacpp_global():
    before, snaps = len(upstream_lines()), snapshots_count()
    served = buyer("--engine", "llamacpp", "--n", "1") + buyer("--engine", "llamacpp", "--stream", "--n", "1")
    save("engine_llamacpp_global", {"buyer": served})
    engine_refused("engine_llamacpp_global", served, before, snaps, 503, "engine_unavailable",
                   "engine=llamacpp on a global route refused before dispatch")


def case_engine_native_pool():
    before, snaps = len(upstream_lines()), snapshots_count()
    served = buyer("--pool", "A", "--engine", "native", "--n", "1") + buyer("--pool", "A", "--engine", "native", "--stream", "--n", "1")
    save("engine_native_pool", {"buyer": served})
    engine_refused("engine_native_pool", served, before, snaps, 503, "engine_unavailable",
                   "engine=native on a pool whose only member is llama.cpp refused, not served by llama.cpp")


def case_engine_ollama_pool():
    before, snaps = len(upstream_lines()), snapshots_count()
    served = buyer("--pool", "A", "--engine", "ollama", "--n", "1") + buyer("--pool", "A", "--engine", "ollama", "--stream", "--n", "1")
    save("engine_ollama_pool", {"buyer": served})
    engine_refused("engine_ollama_pool", served, before, snaps, 503, "engine_unavailable",
                   "engine=ollama on a pool that allowlists only llamacpp refused")


def case_engine_absent():
    before, snaps = len(upstream_lines()), snapshots_count()
    pool_served = buyer("--pool", "A", "--n", "1")
    rows = wait_settled(1)
    mid, mid_snaps = len(upstream_lines()), snapshots_count()
    global_served = buyer("--n", "1")
    save("engine_absent", {"pool": pool_served, "attempts": rows, "global": global_served})
    check("engine_absent", pool_served[0]["status"] == 200 and pool_served[0].get("engine") == "llamacpp_loopback"
          and rows[0]["usage_source"] == "pool_operator_attested" and mid == before + 1 and mid_snaps == snaps + 1,
          "no header on pool A: served as before, class still disclosed",
          (pool_served[0]["status"], pool_served[0].get("engine"), rows[0]["usage_source"], rows[0]["settlement_outcome"]))
    check("engine_absent", global_served[0]["status"] == 503 and global_served[0].get("error") == "byom_non_settlement_unavailable"
          and len(upstream_lines()) == mid and snapshots_count() == mid_snaps,
          "no header on a global route: unchanged M6 case 2 refusal", (global_served[0]["status"], global_served[0].get("error")))


def case_engine_invalid():
    before, snaps = len(upstream_lines()), snapshots_count()
    served = buyer("--pool", "A", "--engine", "LLAMACPP", "--n", "1") + buyer("--pool", "A", "--engine", "vllm", "--n", "1")
    save("engine_invalid", {"buyer": served})
    engine_refused("engine_invalid", served, before, snaps, 400, "invalid_engine_selection", "unknown selector rejected")


def rollback_preflight():
    proc = subprocess.run([str(LAB / "bin" / "coordinator"), "pool-rollback-preflight", "--config", str(LAB / "run" / "coordinator.yaml")],
                          capture_output=True, text=True)
    return proc.returncode, json.loads(proc.stdout) if proc.stdout.strip() else proc.stderr.strip()


def case_omitted_usage():
    flag = LAB / "run" / "strip-usage"
    flag.touch()
    try:
        served = buyer("--pool", "A", "--n", "1") + buyer("--pool", "A", "--stream", "--n", "1")
    finally:
        flag.unlink()
    rows = last_attempts(2)
    save("omitted_usage", {"buyer": served, "attempts": rows})
    for r in rows:
        check("omitted_usage", r["usage_source"] != "pool_operator_attested" and r["billable"] == (0, 0)
              and (r["ledger"] or {}).get("provider_credits", 0) == 0,
              "upstream without usage is not billable", (r["usage_source"], r["billable"], r["terminal_state"], r["reason"], r["ledger"]))
    code, doc = rollback_preflight()
    save("rollback_preflight_inflight", {"exit": code, "result": doc})
    check("omitted_usage", code == 3, "pool-rollback-preflight blocks while a pool attempt can still settle", {"exit": code, "result": doc})


def case_global():
    before, snaps = len(upstream_lines()), snapshots_count()
    served = buyer("--n", "1") + buyer("--stream", "--n", "1")
    save("global", {"buyer": served})
    check("global", all(x["status"] == 503 for x in served) and len(upstream_lines()) == before and snapshots_count() == snaps,
          "member on a global route gets no paid routing", [(x["status"], x.get("error")) for x in served])


def case_fail_closed_pools():
    ensure_pool("B", "--encoding", "1")
    ensure_pool("C", "--encoding", "2", "--runtime-allowlist", "ollama_loopback")
    ensure_pool("E", "--encoding", "2")
    time.sleep(2)
    before, snaps = len(upstream_lines()), snapshots_count()
    served = []
    for p in ("B", "C", "E"):
        served += buyer("--pool", p, "--n", "1") + buyer("--pool", p, "--stream", "--n", "1")
    save("fail_closed_pools", {"buyer": served})
    check("fail_closed_pools", all(x["status"] == 503 for x in served) and len(upstream_lines()) == before and snapshots_count() == snaps,
          "v1 core / runtime not allowlisted / empty v2 allowlist fail closed", [(x["pool"], x["status"], x.get("error")) for x in served])


def serve_restart(binary, env=None):
    e = dict(os.environ, **(env or {}))
    subprocess.run([str(HERE / "serve.sh"), "start", binary], check=True, env=e, capture_output=True, text=True)
    time.sleep(2)


def poolz():
    req = urllib.request.Request("http://127.0.0.1:19102/poolz", headers={"Authorization": f"Bearer {secret('operator_key')}"})
    return json.load(urllib.request.urlopen(req))["pool"]


def case_spoof(spoof_binary):
    if not spoof_binary:
        check("spoof", True, "skipped", "no --spoof-binary")
        return
    ensure_pool("C", "--encoding", "2", "--runtime-allowlist", "ollama_loopback")
    try:
        for spoof in ("ollama_loopback", "none"):
            serve_restart(spoof_binary, {"LAB_SPOOF_RUNTIME_SOURCE": spoof})
            session = [{k: p.get(k) for k in ("runtime_source", "hash_status", "catalog_admission_mode")} for p in poolz()]
            before, snaps = len(upstream_lines()), snapshots_count()
            served = buyer("--pool", "A", "--n", "1") + buyer("--pool", "C", "--n", "1") + buyer("--n", "1")
            save(f"spoof_{spoof}", {"session": session, "buyer": served})
            check("spoof", all(x["status"] == 503 for x in served) and len(upstream_lines()) == before and snapshots_count() == snaps,
                  f"hello runtime_source={spoof} vs signed offer llamacpp_loopback drops the session", {"session": session, "status": [x["status"] for x in served]})
    finally:
        serve_restart(str(LAB / "bin" / "macprovider-cli-lab"))


def inflight_then(pool_name, action):
    flag = LAB / "run" / "slow-stream"
    flag.touch()
    proc = subprocess.Popen([sys.executable, str(HERE / "buyer.py"), "--pool", pool_name, "--stream", "--n", "1", "--max-tokens", "300"],
                            stdout=subprocess.PIPE, text=True)
    try:
        time.sleep(4)
        action()
        out = proc.communicate(timeout=300)[0]
    finally:
        if flag.exists():
            flag.unlink()
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def case_future_manifest():
    # The final-audit fix: routing and settlement use the policy window that is
    # active now, not the highest accepted one. Manifest v2 on pool F starts
    # when v1 ends (30 days out), so accepting it mid-flight changes nothing.
    ensure_pool("F", "--encoding", "2", "--runtime-allowlist", "llamacpp_loopback")
    served = inflight_then("F", lambda: pool("F", "manifest", "F", "--encoding", "2", "--runtime-allowlist", "llamacpp_loopback"))
    served += buyer("--pool", "F", "--n", "1")
    rows = wait_settled(2)
    save("future_manifest", {"buyer": served, "attempts": rows})
    for r in rows:
        check("future_manifest", r["snapshot"]["manifest_version"] == 1 and r["pool_label_status"] == "verified"
              and r["usage_source"] == "pool_operator_attested" and (r["ledger"] or {}).get("provider_credits", 0) > 0,
              "accepted v2 with a future window does not take effect early",
              (r["snapshot"]["manifest_version"], r["pool_label_status"], r["usage_source"], r["settlement_outcome"]))


def case_disputed():
    # Pool G's v1 window is 45 s and v2 (same allowlist) starts when it ends.
    # A ~30 s slowed stream started 12 s before the boundary crosses it.
    window = 45
    t0 = time.time()
    ensure_pool("G", "--encoding", "2", "--runtime-allowlist", "llamacpp_loopback", "--window-seconds", str(window))
    pool("G", "manifest", "G", "--encoding", "2", "--runtime-allowlist", "llamacpp_loopback", "--window-seconds", "3600")
    time.sleep(max(0, t0 + window - 12 - 4 - time.time()))
    served = inflight_then("G", lambda: None)
    time.sleep(3)
    rows = last_attempts(1)
    save("disputed", {"buyer": served, "attempts": rows, "finality": finality(rows[0]["request_id"])})
    r = rows[0]
    check("disputed", r["pool_label_status"] == "label_disputed" and r["usage_source"] == "byte_estimated" and r["billable"] == (0, 0)
          and (r["ledger"] or {}).get("provider_credits", 0) == 0,
          "active manifest changed mid-flight -> byte_estimated, zero billable",
          (r["snapshot"]["manifest_version"], r["pool_label_status"], r["usage_source"], r["settlement_outcome"], r["ledger"]))


def case_active_window():
    # Pool D: v1 allowlists llamacpp_loopback for 90 s; v2 with an empty
    # allowlist is accepted at once but starts when v1 ends. v1 keeps serving
    # until its window ends; afterwards v2 fails closed.
    window = 90
    t0 = time.time()
    ensure_pool("D", "--encoding", "2", "--runtime-allowlist", "llamacpp_loopback", "--window-seconds", str(window))
    pool("D", "manifest", "D", "--encoding", "2", "--window-seconds", "3600")
    time.sleep(2)
    early = buyer("--pool", "D", "--n", "1") + buyer("--pool", "D", "--stream", "--n", "1")
    rows = wait_settled(2)
    early_elapsed = round(time.time() - t0, 1)
    time.sleep(max(0, t0 + window + 5 - time.time()))
    before, snaps = len(upstream_lines()), snapshots_count()
    late = buyer("--pool", "D", "--n", "1") + buyer("--pool", "D", "--stream", "--n", "1")
    save("active_window", {"early": early, "early_attempts": rows, "late": late, "early_elapsed_s": early_elapsed})
    check("active_window", all(x["status"] == 200 for x in early) and all(r["snapshot"]["manifest_version"] == 1
          and r["usage_source"] == "pool_operator_attested" and r["pool_label_status"] == "verified" for r in rows),
          f"v1 still active {early_elapsed}s after v2 (future window) was accepted: serves attested",
          [(r["snapshot"]["manifest_version"], r["pool_label_status"], r["usage_source"]) for r in rows])
    check("active_window", all(x["status"] == 503 for x in late) and len(upstream_lines()) == before and snapshots_count() == snaps,
          "after v1 ends, active v2 (empty allowlist) fails closed", [(x["status"], x.get("error")) for x in late])


def case_generation_bump():
    served = inflight_then("A", lambda: pool("A", "event", "A", "member_admitted", "--provider-id", f"lab-dummy-{int(time.time())}"))
    time.sleep(3)
    rows = last_attempts(1)
    save("generation_bump", {"buyer": served, "attempts": rows})
    r = rows[0]
    check("generation_bump", r["usage_source"] == "pool_operator_attested" and r["pool_label_status"] == "verified",
          "membership change (generation bump, same manifest) mid-flight stays attested", (r["snapshot"]["pool_generation"], r["pool_label_status"], r["usage_source"]))


def case_concurrency():
    before = len(upstream_lines())
    served = []
    for _ in range(3):
        served += buyer("--pool", "A", "--stream", "--n", "4", "--concurrency", "4", "--max-tokens", "300")
    upstream = upstream_lines()[before:]
    b = sorted((x["content_sha256"], x["usage"]["prompt_tokens"], x["usage"]["completion_tokens"]) for x in served if x["status"] == 200)
    u = sorted((x["content_sha256"], x["usage"]["prompt_tokens"], x["usage"]["completion_tokens"]) for x in upstream if x.get("usage"))
    rows = wait_settled(len(served))
    save("concurrency", {"buyer": served, "upstream": upstream, "attempts": rows})
    check("concurrency", len(served) == 12 and all(x["status"] == 200 and x["stream_intact"] for x in served),
          "12 streams (4 concurrent) complete", sum(1 for x in served if x["status"] == 200))
    check("concurrency", b == u, "buyer content+usage == llama-server content+usage", f"{len(b)} of {len(u)} match" if b == u else {"buyer": b, "upstream": u})
    check("concurrency", all(r["usage_source"] == "pool_operator_attested" and r["receipt_result"] == "valid" for r in rows),
          "all settled attested with valid receipts", sum(r["receipt_result"] == "valid" for r in rows))


def case_reconcile():
    # A missing-receipt attempt (case omitted_usage) stays pending until the
    # coordinator's 300 s deadline quarantines it, so wait past that.
    g = sqlite3.connect(f"file:{LAB / 'db' / 'gateway.db'}?mode=ro", uri=True)
    deadline = time.time() + 360
    while True:
        held = g.execute("SELECT COUNT(*) FROM quota_reservations WHERE status = 'active' AND settlement_hold = 1").fetchone()[0]
        if held == 0 or time.time() > deadline:
            break
        time.sleep(10)
    sources = g.execute("SELECT token_source, outcome, COUNT(*) FROM usage_events GROUP BY 1, 2").fetchall()
    save("reconcile", {"held_active": held, "usage_events": sources})
    check("reconcile", held == 0 and any(s[0] == "pool_operator_attested" for s in sources),
          "gateway settled pool_operator_attested finality (no stuck holds)", {"held_active": held, "usage_events": sources})
    before_code, before_doc = rollback_preflight()
    # A gateway retry of a 502 opens a new coordinator attempt that the gateway
    # refunds at once and never asks finality for. The coordinator's expiry
    # sweeper (one pass a minute) must close it after its pending deadline with
    # no buyer-side read; wait for that instead of nudging finality.
    last_deadline = db().execute(
        "SELECT MAX(pending_deadline_unix_ms) FROM settlement_receipt_verdicts WHERE pool_id IS NOT NULL AND pool_id != '' "
        "AND closed != 1").fetchone()[0] or 0
    deadline = max(time.time(), last_deadline / 1000) + 150
    code, doc = before_code, before_doc
    while code != 0 and time.time() < deadline:
        time.sleep(10)
        code, doc = rollback_preflight()
    save("rollback_preflight_after", {"before_sweep": {"exit": before_code, "result": before_doc},
                                      "last_open_pending_deadline_unix_ms": last_deadline, "exit": code, "result": doc})
    check("reconcile", code == 0, "pool-rollback-preflight clears once every pool verdict is closed", {"exit": code, "result": doc})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--only", nargs="*")
    p.add_argument("--spoof-binary")
    a = p.parse_args()
    cases = {"paid": case_paid, "omitted_usage": case_omitted_usage, "global": case_global, "fail_closed_pools": case_fail_closed_pools,
             "spoof": lambda: case_spoof(a.spoof_binary), "future_manifest": case_future_manifest, "disputed": case_disputed,
             "active_window": case_active_window, "generation_bump": case_generation_bump,
             "concurrency": case_concurrency, "reconcile": case_reconcile,
             "engine_llamacpp_pool": case_engine_llamacpp_pool, "engine_llamacpp_global": case_engine_llamacpp_global,
             "engine_native_pool": case_engine_native_pool, "engine_ollama_pool": case_engine_ollama_pool,
             "engine_absent": case_engine_absent, "engine_invalid": case_engine_invalid}
    for name, fn in cases.items():
        if not a.only or name in a.only:
            fn()
    CAPTURES.mkdir(parents=True, exist_ok=True)
    (CAPTURES / "results.txt").write_text("\n".join(RESULTS) + "\n")
    sys.exit(1 if any(line.startswith("FAIL") for line in RESULTS) else 0)


if __name__ == "__main__":
    main()
