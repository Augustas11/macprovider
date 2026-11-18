#!/usr/bin/env python3
"""Continuous-batching route of a parity-grid serve: warm-up gate and ROUTE record (stdlib only).

usage: route_status.py gate --port PORT --serve-err FILE [--pid PID] [--stall-s 1200] [--poll-s 10]
       route_status.py record --status STATUS.json --serve-err FILE --grid GRID.json
                              --phase start|end [--expect batched|any]
       route_status.py native-mtp --status STATUS.json --grid GRID.json
                              --phase start|end [--expect on|any]

Why a gate. A `serve --no-join` lab serve has no catalog trust, so it never loads the
signed continuous-batching policy (serve.err `event=continuous_batching_policy
action=resolved status=absent_empty_off_fallback`): no provisional grant from a signed
entry, and a manual `continuous_batching_accepted_tuples` entry only adds coverage (the
cached-turns grant), never authorization. Batching turns on only when the on-device
self-check (SPEC-038 FR-CB10, ContinuousBatchingSelfCheck.swift) grants it; a live
provider reaches the same state after its provisional grant. The check runs once the
serve has had no inference work for 10 s. Under traffic it waits for an admission hold
and yields when a request waits 20 s behind its probe or its probe waits longer than the
drain bound behind requests (`admission_hold_end ... reason=buyer_wait_bound` /
`residency_wait_bound`, then `deferred reason=cancelled`), so a grid that starts at once
keeps it from ever deciding. The decision is stored in cb-self-check.json next to the
serve config and applied at the next start of the same binary, model, Metal library, OS
build and hardware.

gate: polls /v1/status every --poll-s seconds and sends no inference request, until the
self-check has a verdict and the served slots (status capacity.max_concurrency) equal
the verdict's served_slots, or until no self-check can run for this serve (the loaded
tuple cannot batch, the serial-only small-row route, a draft model, the emergency off,
or an autotune child, which has no served-slot plan). A progress line is printed at
every change. The only bound is --stall-s seconds without any change in the status's
self-check report, served slots or the serve's self-check log lines. Exit 0 when done,
4 when stalled, 5 when the serve exited.

record: prints `ROUTE batching=<active|serial> slots=<n> reason=<...> ...` for a status
snapshot and stores the same fields in GRID.json under route.<phase>. With --expect
batched a serial route prints `ROUTE_FAIL ...` and exits 10.

native-mtp: prints `NATIVE_MTP enabled=<bool> mode=<...> ...` for a status snapshot and stores
the native_mtp object in GRID.json under native_mtp.<phase>. With --expect on, a serve whose
native_mtp is not enabled, is in mode off or (phase end) never proposed a token prints
`NATIVE_MTP_FAIL ...` and exits 11: the cells are not native-MTP cells.
"""
import argparse
import http.client
import json
import os
import re
import sys
import time

UNDECIDED = ("pending", "deferred")
# event=served_slots action=applied reasons after which no self-check runs in this process.
NO_CHECK = {"cb_unavailable_for_loaded_tuple", "draft_model", "emergency_off", "small_m_route_serial_only"}
# A verdict whose served slots never reach the status within this many seconds ends the gate anyway.
APPLY_GRACE_S = 120


def served_slots_events(err_text):
    """[(action, fields)] of every `event=served_slots` line, in order."""
    return [(m.group(1), dict(re.findall(r"(\w+)=(\S+)", m.group(2))))
            for m in re.finditer(r"event=served_slots action=(\w+)([^\n]*)", err_text or "")]


def decided(decision):
    return bool(decision) and decision not in UNDECIDED and not decision.startswith("prior_grant")


def self_check_state(status, err_text):
    """('decided' | 'none' | 'pending' | 'applying', reason) for one status snapshot."""
    cb = status.get("continuous_batching") or {}
    sc = cb.get("self_check") or {}
    decision = sc.get("decision")
    if decided(decision):
        slots = (status.get("capacity") or {}).get("max_concurrency")
        if sc.get("served_slots") is not None and slots != sc.get("served_slots"):
            return "applying", f"{decision} served_slots={sc.get('served_slots')} status_slots={slots}"
        return "decided", decision
    events = served_slots_events(err_text)
    applied = [f.get("reason") for action, f in events if action == "applied"]
    if cb.get("small_m_route") == "serial_only":
        return "none", "small_m_route_serial_only"
    if applied and applied[-1] in NO_CHECK:
        return "none", applied[-1]
    if not any(action == "planned" for action, _ in events) and status.get("model_loaded") is True:
        return "none", "no_served_slots_plan"
    return "pending", decision or (applied[-1] if applied else "self_check_not_started")


def route(status, err_text=""):
    """The batching state a status snapshot shows."""
    cb = status.get("continuous_batching") or {}
    sc = cb.get("self_check") or {}
    policy = cb.get("policy") or {}
    slots = (status.get("capacity") or {}).get("max_concurrency")
    active = cb.get("active") is True and isinstance(slots, int) and slots > 1
    state, why = self_check_state(status, err_text)
    if sc.get("decision"):
        reason = f"self_check_{sc['decision']}"
    elif state == "none":
        reason = why
    else:
        reason = policy.get("decision_reason") or why
    return {
        "batching": "active" if active else "serial",
        "slots": slots,
        "reason": reason,
        "mode": cb.get("mode"),
        "active": cb.get("active"),
        "self_check": sc.get("decision"),
        "verified_k": sc.get("verified_k"),
        "self_check_served_slots": sc.get("served_slots"),
        "small_m_route": cb.get("small_m_route"),
        "policy_decision": policy.get("decision_reason"),
        "max_observed_batch_depth": (cb.get("scheduler") or {}).get("max_observed_batch_depth"),
    }


def route_line(r, phase):
    return (f"ROUTE batching={r['batching']} slots={r['slots']} reason={r['reason']} phase={phase} "
            f"mode={r['mode']} self_check={r['self_check']} verified_k={r['verified_k']} "
            f"small_m_route={r['small_m_route']} max_observed_batch_depth={r['max_observed_batch_depth']}")


def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def fetch_status(port, timeout=5):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request("GET", "/v1/status")
        resp = conn.getresponse()
        return json.loads(resp.read()) if resp.status == 200 else None
    except (OSError, ValueError, http.client.HTTPException):
        return None
    finally:
        conn.close()


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def gate(port, err_path, pid=None, stall_s=1200.0, poll_s=10.0, fetch=fetch_status,
         clock=time.monotonic, sleep=time.sleep, out=print):
    start = last_change = clock()
    last_sig = None
    applying_since = None
    while True:
        if pid and not pid_alive(pid):
            out("CB_WARMUP_FAIL serve exited during the warm-up")
            return 5
        status = fetch(port)
        err = read_text(err_path)
        events = [x for x in err.splitlines() if "event=cb_self_check" in x]
        state, why = ("pending", "status_unavailable") if status is None else self_check_state(status, err)
        waited = int(clock() - start)
        if state in ("decided", "none"):
            out(f"CB_WARMUP_DONE state={state} reason={why} waited_s={waited}")
            return 0
        if state == "applying":
            applying_since = applying_since if applying_since is not None else clock()
            if clock() - applying_since >= APPLY_GRACE_S:
                out(f"CB_WARMUP_DONE state=decided reason={why} waited_s={waited} "
                    f"(served slots not equal to the verdict after {APPLY_GRACE_S}s; ROUTE shows what serves)")
                return 0
        else:
            applying_since = None
        cb = (status or {}).get("continuous_batching") or {}
        sig = (json.dumps(cb.get("self_check"), sort_keys=True),
               ((status or {}).get("capacity") or {}).get("max_concurrency"), len(events), state)
        if sig != last_sig:
            last_sig, last_change = sig, clock()
            last = events[-1].strip()[:240] if events else "-"
            out(f"CB_WARMUP waited_s={waited} state={state} reason={why} self_check_events={len(events)} last={last}")
        elif clock() - last_change >= stall_s:
            out(f"CB_WARMUP_STALL no self-check progress for {int(stall_s)}s state={state} reason={why} "
                f"waited_s={waited}")
            return 4
        sleep(poll_s)


def record(status_path, err_path, grid_path, phase, expect="any", out=print):
    with open(status_path) as f:
        status = json.load(f)
    r = route(status, read_text(err_path))
    with open(grid_path) as f:
        grid = json.load(f)
    grid.setdefault("route", {})[phase] = r
    with open(grid_path, "w") as f:
        json.dump(grid, f, indent=2)
        f.write("\n")
    out(route_line(r, phase))
    if expect == "batched" and r["batching"] != "active":
        out(f"ROUTE_FAIL phase={phase} production batches this model but the serve was {r['batching']} "
            f"(slots={r['slots']} reason={r['reason']}): its multi-row cells are not the production route")
        return 10
    return 0


def record_native_mtp(status_path, grid_path, phase, expect="any", out=print):
    with open(status_path) as f:
        nm = json.load(f).get("native_mtp")
    nm = nm if isinstance(nm, dict) else {}
    with open(grid_path) as f:
        grid = json.load(f)
    grid.setdefault("native_mtp", {})[phase] = nm
    with open(grid_path, "w") as f:
        json.dump(grid, f, indent=2)
        f.write("\n")
    out(f"NATIVE_MTP phase={phase} enabled={nm.get('enabled')} mode={nm.get('mode')} family={nm.get('family')} "
        f"proposal_depth={nm.get('proposal_depth')} proposed_tokens={nm.get('proposed_tokens')} "
        f"accepted_tokens={nm.get('accepted_tokens')} last_reason={nm.get('last_reason')}")
    if expect != "on":
        return 0
    why = None
    if nm.get("enabled") is not True or nm.get("mode") in (None, "off"):
        why = f"native MTP is not on (enabled={nm.get('enabled')} mode={nm.get('mode')} last_reason={nm.get('last_reason')})"
    elif phase == "end" and not (nm.get("proposed_tokens") or 0) > 0:
        why = f"native MTP proposed no token during the grid (last_reason={nm.get('last_reason')})"
    if why:
        out(f"NATIVE_MTP_FAIL phase={phase} {why}: its cells are not native-MTP cells")
        return 11
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gate")
    g.add_argument("--port", type=int, required=True)
    g.add_argument("--serve-err", required=True)
    g.add_argument("--pid", type=int)
    g.add_argument("--stall-s", type=float, default=1200.0)
    g.add_argument("--poll-s", type=float, default=10.0)
    r = sub.add_parser("record")
    r.add_argument("--status", required=True)
    r.add_argument("--serve-err", required=True)
    r.add_argument("--grid", required=True)
    r.add_argument("--phase", required=True, choices=("start", "end"))
    r.add_argument("--expect", default="any", choices=("batched", "any"))
    m = sub.add_parser("native-mtp")
    m.add_argument("--status", required=True)
    m.add_argument("--grid", required=True)
    m.add_argument("--phase", required=True, choices=("start", "end"))
    m.add_argument("--expect", default="any", choices=("on", "any"))
    a = ap.parse_args(argv)
    if a.cmd == "native-mtp":
        return record_native_mtp(a.status, a.grid, a.phase, a.expect)
    if a.cmd == "gate":
        return gate(a.port, a.serve_err, a.pid, a.stall_s, a.poll_s, out=lambda s: print(s, flush=True))
    return record(a.status, a.serve_err, a.grid, a.phase, a.expect)


if __name__ == "__main__":
    sys.exit(main())
