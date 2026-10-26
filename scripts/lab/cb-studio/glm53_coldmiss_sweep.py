#!/usr/bin/env python3
"""Issue #2153 cold-miss campaign driver (isolated loopback lab only).

Cold-miss cost of the SPEC-024-R005 resume-boundary chunk plan on GLM-5.3-Flash
CB rows, against an isolated loopback lab serve.

Per cell (prompt tokens L, earlier assistant turns T, rows R):
  split  keyed, fresh conversation key: a cold miss on the #2145 plan (one
         chunk end per earlier `<|assistant|>` plus the snapshot position).
  plain  the same prompt unkeyed: no resume boundaries, no snapshot (the
         plain chunk plan, ceil(L / 2048) balanced chunks).
  warm   the next turn of the split conversation, same key: resumes the
         snapshot the split request published (the warm baseline).
R = 1, 4 (four conversations at once, all cold) or 4j (one measured cold
row joining three unkeyed rows that are already decoding).

Each request streams; the client records TTFT as the first chunk carrying
generated text (the serve sends an empty role chunk at admission, which is
not a token). The serve log (MACPROVIDER_CB_TRACE=1, and on the #2153 lab
build MACPROVIDER_LAB_PREFILL_PHASES=1) gives the server-side TTFT, every
prefill chunk of every request and the decode windows interleaved between
them; `analyze` joins both by request id.

Subcommands (stdlib only; run with `python3 -I`):
  plan       cells of a leg and their time estimate (offline)
  selftest   builds every body of a leg with a nominal calibration and checks
             structure, ordering and boundary counts (offline)
  calibrate  tokens per filler line and template overhead, plus the resume
             token id and boundary-count check through /v1/apply-template
  run        one leg, priority order, stops before a cell that would cross
             --deadline-unix; appends one JSON line per request
  analyze    joins run lines with the serve log; writes the per-cell table,
             the per-chunk cost fit and the phase breakdown
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import random
import re
import statistics
import sys
import threading
import time
import urllib.request

MODEL = "zai-org/glm-5.3-flash"
CHUNK = 2048  # pagedMLAPromptChunkTokens (ServeDecodePath.swift)
LCP_THRESHOLD = 32  # ConversationCache.lcpThreshold
REPLY_TOKENS = 60  # earlier assistant turn length (approx.)
FINAL_USER_TOKENS = 150
WARM_EXTRA = "Thanks. Now check the remaining entries in the same way and report anything unusual."

LEGS = {
    # After-only cells: reuse the recorded baseline; do not repeat its sweep.
    "after": [
        (8192, 30, "1", 1), (8192, 0, "4", 1), (8192, 30, "4", 1),
        (32768, 30, "1", 1), (32768, 30, "4", 1), (32768, 30, "4j", 1),
    ],
    # Leg A: the core question at 8k/32k, 1 and 4 rows, and the joined case.
    "A": [
        *[(8192, t, "1", 2) for t in (0, 1, 3, 10, 30)],
        *[(8192, t, "4", 1) for t in (0, 1, 3, 10, 30)],
        *[(32768, t, "1", 1) for t in (0, 1, 3, 10, 30)],
        *[(32768, t, "4j", 1) for t in (0, 10, 30)],
    ],
    # Leg B: long prompts and the 4-row 32k cells.
    "B": [
        *[(65536, t, "1", 1) for t in (0, 3, 10, 30)],
        *[(32768, t, "4", 1) for t in (0, 10, 30)],
        *[(32768, t, "1", 1, 1) for t in (1, 3, 10)],  # second repetition (rep index 1)
    ],
}


# ---------------------------------------------------------------- prompts

WORDS = (
    "anchor beacon buoy channel chart current depth dock ebb fathom harbor hull "
    "jetty keel knot ledger lamp log mooring north pier pilot quay reef rope "
    "signal sounding south starboard tide vessel watch wharf wind east west "
    "inspect record verify compare report status entry value error offset"
).split()


def filler_line(rng: random.Random) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(12)) + f" {rng.randrange(10**6):06d}.\n"


def filler(tokens: float, per_line: float, seed: str) -> str:
    rng = random.Random(seed)
    return "".join(filler_line(rng) for _ in range(max(1, round(tokens / per_line))))


PREFIX_TOKENS = 6  # "Tool output N:" / "Checked block N." per message (approx.)


def conversation(length: int, turns: int, row: int, cal: dict, tag: str) -> list[dict]:
    """A deterministic agent-like conversation of about `length` prompt
    tokens with exactly `turns` earlier assistant turns, ending in a user
    message (the generation prompt adds the last `<|assistant|>`). Filler is
    whole lines; a running carry keeps the total on target across messages."""
    per_line, overhead = cal["tokens_per_line"], cal["message_overhead_tokens"]
    wanted = emitted = 0.0

    def text(tokens: float, seed: str) -> str:
        nonlocal wanted, emitted
        wanted += tokens
        lines = max(1, round((wanted - emitted) / per_line))
        emitted += lines * per_line
        rng = random.Random(seed)
        return "".join(filler_line(rng) for _ in range(lines))

    system_tokens = min(6000, length // 4)
    messages = [{"role": "system", "content": (
        f"You are a careful operations agent for harbor log {tag}-{row}. Use the logs below.\n"
        + text(system_tokens - 20, f"{tag}-{row}-system"))}]
    budget = (length - system_tokens - FINAL_USER_TOKENS - cal["template_tokens"]
              - (overhead + PREFIX_TOKENS) * (1 + 2 * turns))
    if turns:
        per_round = budget / turns
        for turn in range(turns):
            messages.append({"role": "user", "content": (
                f"Tool output {turn}:\n" + text(max(16, per_round - REPLY_TOKENS), f"{tag}-{row}-u{turn}"))})
            messages.append({"role": "assistant", "content": (
                f"Checked block {turn}. " + text(REPLY_TOKENS, f"{tag}-{row}-a{turn}").strip())})
        final = text(FINAL_USER_TOKENS, f"{tag}-{row}-final")
    else:
        final = text(max(16, budget) + FINAL_USER_TOKENS, f"{tag}-{row}-final")
    messages.append({"role": "user", "content": "Latest tool output:\n" + final + "Summarize what changed."})
    return messages


def warm_next_turn(messages: list[dict], cal: dict, tag: str, row: int) -> list[dict]:
    reply = "Summary: " + filler(REPLY_TOKENS, cal["tokens_per_line"], f"{tag}-{row}-warm").strip()
    return messages + [{"role": "assistant", "content": reply}, {"role": "user", "content": WARM_EXTRA}]


def body(messages: list[dict], max_tokens: int) -> dict:
    return {
        "model": MODEL, "messages": messages, "max_tokens": max_tokens, "temperature": 0,
        "stream": True, "stream_options": {"include_usage": True},
    }


# ---------------------------------------------------------------- HTTP

def post_json(port: int, path: str, payload: dict, timeout: float = 60) -> dict:
    # The token utilities require `model` and cap the body at 64 KiB.
    payload = {"model": MODEL, **payload}
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def stream(port: int, payload: dict, request_id: str, key: str | None, timeout: float,
           stop: threading.Event | None = None, first_token: threading.Event | None = None) -> dict:
    headers = {"Content-Type": "application/json", "X-Request-ID": request_id}
    if key:
        headers["X-MacProvider-Provider-Conversation"] = key
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions", data=json.dumps(payload).encode(),
        headers=headers, method="POST")
    record = {"request_id": request_id, "keyed": bool(key), "error": None, "usage": None,
              "ttft_s": None, "first_byte_s": None, "chunks": 0}
    started = time.monotonic()
    record["start_unix"] = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for raw in response:
                now = time.monotonic() - started
                if record["first_byte_s"] is None:
                    record["first_byte_s"] = now
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:") or line == "data: [DONE]":
                    continue
                chunk = json.loads(line[5:])
                if chunk.get("usage"):
                    record["usage"] = chunk["usage"]
                for choice in chunk.get("choices") or []:
                    delta = choice.get("delta") or {}
                    if any(delta.get(k) for k in ("content", "reasoning_content", "tool_calls")):
                        record["chunks"] += 1
                        if record["ttft_s"] is None:
                            record["ttft_s"] = now
                            if first_token:
                                first_token.set()
                    if choice.get("finish_reason"):
                        record["finish_reason"] = choice["finish_reason"]
                if stop is not None and stop.is_set():
                    record["stopped_early"] = True
                    break
    except Exception as error:  # recorded, never raised: one failed request must not end the leg
        record["error"] = f"{type(error).__name__}: {error}"
    record["wall_s"] = time.monotonic() - started
    return record


# ---------------------------------------------------------------- plan

def estimate_s(length: int, rows: str, rate: float) -> float:
    one = length / rate + 5
    cold = {"1": one, "4": 4 * one, "4j": one * 1.3}[rows]
    plain = cold
    warm = 10 if rows != "4" else 25
    return cold + plain + warm


def cmd_plan(args) -> int:
    total = 0.0
    for length, turns, rows, reps, *_ in LEGS[args.leg]:
        est = reps * estimate_s(length, rows, args.prefill_rate)
        total += est
        print(f"L={length:>6} T={turns:>2} rows={rows:<2} reps={reps} est={est:7.0f}s cumulative={total/60:6.1f}min")
    print(f"leg {args.leg}: {len(LEGS[args.leg])} cells, about {total/60:.0f} min at {args.prefill_rate:.0f} prompt tok/s")
    return 0


def cmd_selftest(args) -> int:
    cal = {"tokens_per_line": 21.0, "message_overhead_tokens": 4, "template_tokens": 8}
    failures = []
    for length, turns, rows, reps, *_ in LEGS[args.leg]:
        for row in range(4 if rows == "4" else 1):
            messages = conversation(length, turns, row, cal, "selftest")
            roles = [m["role"] for m in messages]
            if roles[0] != "system" or roles[-1] != "user" or roles.count("assistant") != turns:
                failures.append(f"L={length} T={turns}: roles {roles[:4]}...")
            if any(a == b for a, b in zip(roles[1:], roles[2:])):
                failures.append(f"L={length} T={turns}: roles do not alternate")
            approx = sum(len(m["content"]) for m in messages) / 4.4  # rough chars per token
            if not 0.6 * length < approx < 1.6 * length:
                failures.append(f"L={length} T={turns}: about {approx:.0f} tokens")
            warm = warm_next_turn(messages, cal, "selftest", row)
            if warm[: len(messages)] != messages or [m["role"] for m in warm[-2:]] != ["assistant", "user"]:
                failures.append(f"L={length} T={turns}: warm turn does not extend the cold prompt")
            if conversation(length, turns, row, cal, "selftest") != messages:
                failures.append(f"L={length} T={turns}: not deterministic")
            json.dumps(body(messages, 16))
    print(json.dumps({"leg": args.leg, "failures": failures, "passed": not failures}, indent=1))
    return 0 if not failures else 1


# ---------------------------------------------------------------- calibrate

def cmd_calibrate(args) -> int:
    lines = filler(4000, 20.0, "calibration")
    count = len(lines.splitlines())
    tokens = post_json(args.port, "/v1/tokenize", {"text": lines})["tokens"]
    per_line = len(tokens) / count
    marker = post_json(args.port, "/v1/tokenize", {"text": "<|assistant|>"})["tokens"]
    if len(marker) != 1:
        print(json.dumps({"error": "<|assistant|> is not one token", "tokens": marker}))
        return 1
    resume = marker[0]
    sys_text, user_text = "Short system note.", "Short user note."
    one = post_json(args.port, "/v1/apply-template", {"messages": [
        {"role": "system", "content": sys_text}, {"role": "user", "content": user_text}]})["tokens"]
    content = sum(len(post_json(args.port, "/v1/tokenize", {"text": t})["tokens"]) for t in (sys_text, user_text))
    overhead_total = len(one) - content
    cal = {"tokens_per_line": per_line, "message_overhead_tokens": max(1, overhead_total // 3),
           "template_tokens": overhead_total, "resume_token_id": resume}
    # Boundary check: a short conversation built by the same code must carry
    # exactly T + 1 resume tokens (T earlier turns plus the generation prompt),
    # every one at or above the reuse threshold.
    checks = {}
    for turns in (0, 1, 3, 10, 30):
        ids = post_json(args.port, "/v1/apply-template", {"messages": conversation(
            8000, turns, 0, cal, "calcheck")})["tokens"]
        positions = [i for i, t in enumerate(ids) if t == resume]
        checks[str(turns)] = {"tokens": len(ids), "resume_markers": len(positions),
                              "ok": len(positions) == turns + 1 and all(p >= LCP_THRESHOLD for p in positions)}
    cal["boundary_checks"] = checks
    cal["passed"] = all(c["ok"] for c in checks.values())
    json.dump(cal, sys.stdout, indent=1)
    print()
    return 0 if cal["passed"] else 1


# ---------------------------------------------------------------- run

def run_cell(args, cal, length, turns, rows, rep, out) -> None:
    tag = f"{args.run_id}-L{length}-T{turns}-R{rows}-p{rep}"
    n = 4 if rows == "4" else 1
    convs = [conversation(length, turns, row, cal, tag) for row in range(n)]
    timeout = max(300.0, 4 * n * length / args.prefill_rate)
    order = ("split", "warm", "plain") if rep % 2 == 0 else ("plain", "split", "warm")

    def emit(mode, rec, row):
        rec.update({"cell": tag, "L": length, "T": turns, "rows": rows, "rep": rep, "mode": mode, "row": row})
        out.write(json.dumps(rec) + "\n")
        out.flush()

    for mode in order:
        if rows == "4j":
            # Three unkeyed short rows decoding first, then one measured cold row.
            stop, started = threading.Event(), [threading.Event() for _ in range(3)]
            bg_body = body([{"role": "user", "content": filler(400, cal["tokens_per_line"], f"{tag}-bg")
                             + "Write a long, detailed report."}], 4096)
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                bgs = [pool.submit(stream, args.port, bg_body, f"{tag}-{mode}-bg{i}", None, timeout, stop, started[i])
                       for i in range(3)]
                for event in started:
                    event.wait(timeout=120)
                rec = measured(args, convs[0], tag, mode, 0, timeout, cal)
                stop.set()
                rec["background"] = [f.result() for f in bgs]
            emit(mode, rec, 0)
        else:
            with concurrent.futures.ThreadPoolExecutor(max_workers=n) as pool:
                futures = [pool.submit(measured, args, convs[row], tag, mode, row, timeout, cal) for row in range(n)]
                for row, future in enumerate(futures):
                    emit(mode, future.result(), row)


def measured(args, messages, tag, mode, row, timeout, cal) -> dict:
    key = f"conv:{tag}-r{row}" if mode in ("split", "warm") else None
    if mode == "warm":
        messages = warm_next_turn(messages, cal, tag, row)
    return stream(args.port, body(messages, args.max_tokens), f"{tag}-{mode}-r{row}", key, timeout)


def cmd_run(args) -> int:
    cal = json.load(open(args.calibration))
    if not cal.get("passed"):
        print("refusing: calibration did not pass", file=sys.stderr)
        return 3
    cells = LEGS[args.leg]
    done = 0
    with open(args.out, "a", encoding="utf-8") as out:
        for length, turns, rows, reps, *first in cells:
            for rep in range(first[0] if first else 0, (first[0] if first else 0) + reps):
                remaining = args.deadline_unix - time.time()
                if estimate_s(length, rows, args.prefill_rate) * 1.5 > remaining:
                    print(f"skip L={length} T={turns} rows={rows} rep={rep}: {remaining:.0f}s left", file=sys.stderr)
                    continue
                t0 = time.time()
                run_cell(args, cal, length, turns, rows, rep, out)
                done += 1
                print(f"cell L={length} T={turns} rows={rows} rep={rep} took {time.time()-t0:.0f}s", file=sys.stderr)
    print(json.dumps({"leg": args.leg, "cells_run": done}))
    return 0 if done else 1


# ---------------------------------------------------------------- analyze

TRACE = re.compile(r"^cbtrace t=(\d+) rid=(\S+) ev=(.*)$")
PHASE = re.compile(r"^\[lab-prefill-phase\] t_ms=(\d+) (.*)$")
KV = re.compile(r"(\w+)=(\S+)")


def cmd_retention(args) -> int:
    """Pressure beyond the old entry cap, then test the old TTL gap or restart.

    Run seed before the after cells, memory after them (>900s), and disk after
    restarting the isolated serve with the same encrypted tier. Server disk_hit
    telemetry is required separately: cached tokens alone cannot prove residency.
    """
    from pathlib import Path
    state_path = Path(args.state)
    if args.phase == "seed":
        cal = json.load(open(args.calibration))
        if not cal.get("passed"):
            return 3
        tag = args.run_id
        messages = conversation(8192, 30, 0, cal, tag)
        key = f"conv:kvs-synth:{tag}"
        rec = stream(args.port, body(messages, 16), f"{tag}-seed", key, 300)
        state = {"tag": tag, "key": key, "seed_unix": time.time(),
                 "messages": warm_next_turn(messages, cal, tag, 0)}
        state_path.write_text(json.dumps(state))
        print(json.dumps({"phase": "seed", **rec}), flush=True)
        if rec["error"] or not rec["usage"]:
            return 1
        # Nine other conversations exceed the old eight-entry limit. They use
        # ordinary keyed hot retention; only the seed needs disk persistence.
        for i in range(9):
            pressure = [{"role": "system", "content": "Review the supplied entries carefully. " * 32},
                        {"role": "user", "content": f"Entry {i}: report its status in one sentence."}]
            rec = stream(args.port, body(pressure, 4), f"{tag}-pressure-{i}",
                         f"conv:{tag}-pressure-{i}", 120)
            print(json.dumps({"phase": "pressure", **rec}), flush=True)
            if rec["error"] or not rec["usage"]:
                return 1
        return 0
    state = json.loads(state_path.read_text())
    gap = time.time() - state["seed_unix"]
    if args.phase == "memory" and gap <= 900:
        print(json.dumps({"error": "old TTL gap has not elapsed", "gap_s": gap}))
        return 3
    rec = stream(args.port, body(state["messages"], 16),
                 f"{state['tag']}-{args.phase}", state["key"], 300)
    usage = rec.get("usage") or {}
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
    cached = max(cached, usage.get("cached_prompt_tokens", 0))
    print(json.dumps({"phase": args.phase, "gap_s": gap, "cached": cached, **rec}), flush=True)
    return 0 if not rec["error"] and cached > 0 else 1


def ols(rows: list[tuple[list[float], float]]) -> list[float] | None:
    """Least squares by the normal equations (small k, stdlib only)."""
    if not rows:
        return None
    k = len(rows[0][0])
    a = [[sum(x[i] * x[j] for x, _ in rows) for j in range(k)] for i in range(k)]
    b = [sum(x[i] * y for x, y in rows) for i in range(k)]
    for col in range(k):  # Gauss-Jordan with partial pivoting
        pivot = max(range(col, k), key=lambda r: abs(a[r][col]))
        if abs(a[pivot][col]) < 1e-12:
            return None
        a[col], a[pivot], b[col], b[pivot] = a[pivot], a[col], b[pivot], b[col]
        for r in range(k):
            if r != col:
                f = a[r][col] / a[col][col]
                a[r] = [x - f * y for x, y in zip(a[r], a[col])]
                b[r] -= f * b[col]
    return [b[i] / a[i][i] for i in range(k)]


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def cmd_analyze(args) -> int:
    runs = [json.loads(l) for l in open(args.runs, encoding="utf-8") if l.strip()]
    by_rid = {r["request_id"]: r for r in runs}
    submit, active, complete = {}, {}, {}
    chunks: dict[str, list[dict]] = {}
    decode_hops: list[tuple[int, int]] = []  # (end t_ms, ms)
    pending_group = None
    phases_row, phases_sched = [], []
    with open(args.serve_log, encoding="utf-8", errors="replace") as log:
        for line in log:
            m = TRACE.match(line.strip())
            if m:
                t, rid, ev = int(m[1]), m[2], m[3]
                if ev.startswith("sch_submit") or ev == "http_task_start":
                    submit[rid] = min(t, submit.get(rid, t))
                elif ev == "sch_active":
                    active.setdefault(rid, t)
                elif ev.startswith("sch_complete"):
                    complete[rid] = t
                elif ev.startswith("prefill_group_begin"):
                    f = dict(KV.findall(ev))
                    pending_group = (f["ids"].split(","), [int(x) for x in f["offsets"].split(",")],
                                     [int(x) for x in f["chunks"].split(",")])
                elif ev.startswith("hop_prefill") and pending_group:
                    f = dict(KV.findall(ev))
                    ids, offsets, sizes = pending_group
                    for rid_, off, size in zip(ids, offsets, sizes):
                        chunks.setdefault(rid_, []).append({"t": t, "offset": off, "tokens": size,
                                                            "group_rows": len(ids), "group_ms": int(f["ms"]),
                                                            "decode_rows": int(f.get("decode_rows", 0))})
                    pending_group = None
                elif ev.startswith("hop_decode"):
                    f = dict(KV.findall(ev))
                    decode_hops.append((t, int(f["ms"])))
                continue
            m = PHASE.match(line.strip())
            if m:
                f = dict(KV.findall(m[2]))
                f["t_ms"] = int(m[1])
                (phases_row if f.get("scope") == "row" else phases_sched if f.get("scope") == "scheduler" else []).append(f)

    for rec in runs:
        rid = rec["request_id"]
        rec["server_ttft_ms"] = active[rid] - submit[rid] if rid in active and rid in submit else None
        cs = chunks.get(rid, [])
        rec["prefill_chunks"] = len(cs)
        if cs and rid in submit:
            lo, hi = submit[rid], max(c["t"] for c in cs)
            rec["interleaved_decode_ms"] = sum(ms for t, ms in decode_hops if lo <= t <= hi)
        usage = rec.get("usage") or {}
        rec["prompt_tokens"] = usage.get("prompt_tokens")
        rec["cached_prompt_tokens"] = usage.get("cached_prompt_tokens")

    cells = {}
    for rec in runs:
        cells.setdefault((rec["L"], rec["T"], rec["rows"]), {}).setdefault(rec["mode"], []).append(rec)
    table, checks = [], {}
    for (length, turns, rows), modes in sorted(cells.items(), key=lambda kv: (kv[0][0], str(kv[0][2]), kv[0][1])):
        row = {"L": length, "T": turns, "rows": rows}
        for mode, recs in modes.items():
            row[mode] = {
                "n": len(recs),
                "client_ttft_s_median": median(r["ttft_s"] for r in recs),
                "server_ttft_ms_median": median(r["server_ttft_ms"] for r in recs),
                "wall_s_median": median(r["wall_s"] for r in recs),
                "prefill_chunks_median": median(r["prefill_chunks"] for r in recs),
                "interleaved_decode_ms_median": median(r.get("interleaved_decode_ms") for r in recs),
                "prompt_tokens_median": median(r["prompt_tokens"] for r in recs),
                "cached_prompt_tokens_min": min((r["cached_prompt_tokens"] or 0) for r in recs),
                "errors": sum(1 for r in recs if r["error"]),
            }
        s, p = row.get("split"), row.get("plain")
        if s and p and s["server_ttft_ms_median"] and p["server_ttft_ms_median"]:
            row["split_minus_plain_ttft_ms"] = s["server_ttft_ms_median"] - p["server_ttft_ms_median"]
            row["extra_chunks"] = (s["prefill_chunks_median"] or 0) - (p["prefill_chunks_median"] or 0)
            if turns:
                row["ms_per_boundary"] = row["split_minus_plain_ttft_ms"] / (turns + 1)
        label = f"L{length}.T{turns}.R{rows}"
        if "warm" in row:
            checks[f"{label}.warm_hit"] = row["warm"]["cached_prompt_tokens_min"] > 0
        for mode in ("split", "plain"):
            if mode in row:
                checks[f"{label}.{mode}_cold"] = row[mode]["cached_prompt_tokens_min"] == 0
                checks[f"{label}.{mode}_no_errors"] = row[mode]["errors"] == 0
                pt = row[mode]["prompt_tokens_median"] or 0
                checks[f"{label}.{mode}_length_within_5pct"] = abs(pt - length) <= 0.05 * length
        table.append(row)

    # Per-chunk cost: ms = a + b * tokens + c * tokens * offset / 1e6, over
    # solo prefill chunks (one row in the forward).
    solo = [c for cs in chunks.values() for c in cs if c["group_rows"] == 1]
    fit = ols([([1.0, c["tokens"], c["tokens"] * c["offset"] / 1e6], c["group_ms"]) for c in solo])
    small = [c for c in solo if c["tokens"] <= 64]
    phase_keys = ("state_us", "build_us", "sample_us", "seed_us", "eval_us", "set_us")
    def phase_summary(recs):
        return {k: median(int(r[k]) for r in recs if k in r) for k in phase_keys} | {"n": len(recs)}
    nonfinal = [r for r in phases_row if r.get("final") == "false"]
    phase = {
        "row_all_nonfinal": phase_summary(nonfinal),
        "row_nonfinal_tokens_le_64": phase_summary([r for r in nonfinal if int(r["tokens"]) <= 64]),
        "row_nonfinal_tokens_ge_1024": phase_summary([r for r in nonfinal if int(r["tokens"]) >= 1024]),
        "row_phase_fit_us": {k: ols([([1.0, int(r["tokens"]), int(r["tokens"]) * int(r["offset"]) / 1e6], int(r[k]))
                                      for r in nonfinal if k in r]) for k in phase_keys},
        "scheduler_prep_us_median": median(int(r["prep_us"]) for r in phases_sched),
    }
    report = {
        "schema": "macprovider.glm53-coldmiss-2153.v1",
        "cells": table,
        "chunk_cost_fit_ms": {"intercept_ms": fit[0], "per_token_ms": fit[1], "per_token_per_mtoken_offset_ms": fit[2],
                              "n": len(solo)} if fit else None,
        "small_chunk_ms_median": median(c["group_ms"] for c in small),
        "phases": phase,
        "checks": checks,
        "failed_checks": sorted(k for k, v in checks.items() if not v),
        "passed": bool(checks) and all(checks.values()),
    }
    json.dump(report, sys.stdout, indent=1, sort_keys=True)
    print()
    return 0 if report["passed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "selftest"):
        p = sub.add_parser(name)
        p.add_argument("--leg", choices=sorted(LEGS), required=True)
        p.add_argument("--prefill-rate", type=float, default=270.0)
    p = sub.add_parser("calibrate")
    p.add_argument("--port", type=int, required=True)
    p = sub.add_parser("run")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--leg", choices=sorted(LEGS), required=True)
    p.add_argument("--calibration", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--deadline-unix", type=float, required=True)
    p.add_argument("--max-tokens", type=int, default=16)
    p.add_argument("--prefill-rate", type=float, default=270.0)
    p = sub.add_parser("retention")
    p.add_argument("--phase", choices=("seed", "memory", "disk"), required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--calibration")
    p.add_argument("--run-id", default="2153-retention")
    p.set_defaults(func=cmd_retention)
    p = sub.add_parser("analyze")
    p.add_argument("--runs", required=True)
    p.add_argument("--serve-log", required=True)
    args = parser.parse_args()
    return {"plan": cmd_plan, "selftest": cmd_selftest, "calibrate": cmd_calibrate,
            "run": cmd_run, "retention": cmd_retention, "analyze": cmd_analyze}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
