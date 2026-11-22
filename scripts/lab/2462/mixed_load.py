#!/usr/bin/env python3
"""#2462 workload against one loopback serve: native-admitted and ordinary rows (stdlib only).

usage: mixed_load.py --port P --model ID --label A1 --out rows.jsonl
                     [--trials 6] [--ctx 1000] [--ord-rows 2] [--ord-out 512] [--nat-out 1024]
                     [--cells ord1,nat1,mix,mix_late] [--late-after 128]
                     [--ordinary-field x_lab_2462_ordinary]

How a request becomes native or ordinary (NativeMTP.swift `NativeMTPDecodeSelector.reason`):
a greedy text request with only admitted top-level keys is native-eligible on a serve whose
native-MTP tuple is admitted. An ordinary row carries one extra top-level key
(--ordinary-field), which is not in `admittedTopLevelKeys`, so the selector returns
`unknown_request_field` and the row decodes ordinary. The request parser accepts and ignores
the key: nothing else about the row changes (same prompt rendering, temperature 0, same
sampler, no conversation key, no cache lease). This is a property of the request, so it holds
at any arrival order and at one row, where the active-row cap cannot apply.
A native row is admitted only when no other request is in flight (`resolvingActiveRows`,
signed max_native_active_rows = 1), so a `mix` trial sends the native row first and starts the
ordinary rows only after its first streamed token. On a `mixed` serve (SPEC-038 v0.3.63) those
ordinary rows are admitted on row_invariant (reason native_active), so the step is one forward
per decode kind, as on a process-wide row_invariant serve.

Cells, each trial in this order, one trial of every cell before the next trial:
  ord1  every ordinary prompt alone, one after another (1-row ordinary; on a `mixed` serve this
        is the 1-row stock-order serial reference of the `mix` ordinary rows: same prompts, same
        max_tokens);
  nat1  the native prompt alone (1-row native);
  mix   the native prompt, then --ord-rows ordinary prompts at once while it decodes;
  mix_late  --ord-rows ordinary prompts at once, then the native prompt (no ordinary field) once
        every ordinary row has streamed --late-after content/reasoning chunks (each chunk is at
        least one token). With the signed max_native_active_rows = 1 that late request is
        admitted ordinary (capacity_above_native_bound) on the route the in-flight rows hold;
        its native admissions are recorded, not assumed. Role `late`.
Native prompt: prompts.build_messages(ctx, 0); ordinary prompt j: build_messages(ctx, j), j >= 1.
Every prompt asks for a long story, so rows normally stop at max_tokens (finish=length).

Each trial waits for an idle serve (no active decode row, nothing waiting, no in-flight route
request) and records the /v1/status native_mtp counter change over the trial. A `mix` trial
also samples /v1/status every --poll-s seconds and records the peak active decode rows and,
on a `mixed` serve, the peak `small_m_route_requests` per route; every trial on a `mixed` serve
records the `small_m_route_admissions` change (admissions per reason) over the trial.

Output: one JSON line per row (kind=row) and per trial (kind=trial). Exit 0 when every request
returned a usage frame and no error, else 1.
"""
import argparse
import hashlib
import http.client
import json
import os
import sys
import threading
import time
import uuid

sys.path.insert(0, os.environ.get("PARITY_GRID_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "parity-grid")))
import prompts  # noqa: E402
from provider_client import consume_stream, native_mtp_delta, native_mtp_of, row_record  # noqa: E402


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


def cb_of(status):
    cb = (status or {}).get("continuous_batching")
    return cb if isinstance(cb, dict) else {}


def busy(status):
    """True while the serve has a decode row, a waiting request or an in-flight route request."""
    if status is None:
        return True
    sch = cb_of(status).get("scheduler") or {}
    routes = cb_of(status).get("small_m_route_requests") or {}
    return bool(sch.get("active_decode_rows") or sch.get("waiting_count") or any(routes.values()))


def wait_idle(port, poll_s, settle_s=1.0):
    """Waits for an idle serve; the only bound is the serve answering (a dead serve raises)."""
    misses = 0
    while True:
        st = fetch_status(port)
        if st is None:
            misses += 1
            if misses >= 60:
                raise RuntimeError("serve stopped answering /v1/status")
        elif not busy(st):
            time.sleep(settle_s)
            if not busy(fetch_status(port)):
                return
        else:
            misses = 0
        time.sleep(poll_s)


def first_token_marker(lines, event, reached=None, after=0):
    """Passes SSE lines through; sets `event` at the first content or reasoning delta and
    `reached` (if given) at the `after`-th one."""
    chunks = 0
    for raw in lines:
        if (not event.is_set() or (reached is not None and not reached.is_set())) \
                and raw.startswith(b"data:") and b"[DONE]" not in raw:
            try:
                obj = json.loads(raw[5:].strip())
                for ch in obj.get("choices") or []:
                    d = ch.get("delta") or {}
                    if d.get("content") or d.get("reasoning_content"):
                        chunks += 1
                        event.set()
                        if reached is not None and chunks >= after:
                            reached.set()
            except ValueError:
                pass
        yield raw


def run_request(port, model, messages, max_tokens, extra=None, first=None, timeout=3600, reached=None, after=0):
    """One streamed request. `first` and `reached` are always set when it returns."""
    try:
        return _run_request(port, model, messages, max_tokens, extra, first, timeout, reached, after)
    finally:
        if reached is not None:
            reached.set()


def _run_request(port, model, messages, max_tokens, extra, first, timeout, reached, after):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": 0,
            "stream": True, "stream_options": {"include_usage": True}, **(extra or {})}
    first = first or threading.Event()
    t0 = time.perf_counter()
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        # The provider batches only requests that carry a stable id.
        conn.request("POST", "/v1/chat/completions", body=json.dumps(body).encode(),
                     headers={"Content-Type": "application/json", "Accept": "text/event-stream",
                              "X-Request-ID": uuid.uuid4().hex})
        resp = conn.getresponse()
        if resp.status != 200:
            first.set()
            return {"error": f"http {resp.status}: {resp.read(2000).decode('utf-8', 'replace')}",
                    "t0": t0, "t_end": time.perf_counter()}
        result = consume_stream(first_token_marker(iter(resp.readline, b""), first, reached, after))
    except (OSError, http.client.HTTPException) as exc:
        first.set()
        return {"error": f"{type(exc).__name__}: {exc}", "t0": t0, "t_end": time.perf_counter()}
    finally:
        conn.close()
    first.set()
    result["t0"] = t0
    result["t_end"] = time.perf_counter()
    return result


def record(res, base, cell_t0):
    r = row_record(res, base, cell_t0=cell_t0)
    tf, tl = r.pop("_t_first"), r.pop("_t_last")
    r["t_first_offset_s"] = round(tf - cell_t0, 4) if tf is not None else None
    r["t_last_offset_s"] = round(tl - cell_t0, 4) if tl is not None else None
    # Identity of the whole output: content and reasoning together.
    r["output_sha256"] = hashlib.sha256((r.get("text", "") + "\x00" + r.get("reasoning_text", "")).encode()).hexdigest()
    return r


class Poller(threading.Thread):
    """Peak scheduler rows and per-route in-flight requests while a trial runs."""

    def __init__(self, port, poll_s):
        super().__init__(daemon=True)
        self.port, self.poll_s = port, poll_s
        self.stop = threading.Event()
        self.peak_rows = 0
        self.peak_routes = {}
        self.samples = 0

    def run(self):
        while not self.stop.is_set():
            cb = cb_of(fetch_status(self.port, timeout=2))
            if cb:
                self.samples += 1
                self.peak_rows = max(self.peak_rows, (cb.get("scheduler") or {}).get("active_decode_rows") or 0)
                for k, v in (cb.get("small_m_route_requests") or {}).items():
                    self.peak_routes[k] = max(self.peak_routes.get(k, 0), v or 0)
            self.stop.wait(self.poll_s)


def overlap_share(row, other):
    """Share of `row`'s decode span during which `other` was also decoding."""
    a, b = row.get("t_first_offset_s"), row.get("t_last_offset_s")
    o_start, o_end = other.get("t_first_offset_s"), other.get("t_last_offset_s")
    if a is None or b is None or o_end is None or b <= a:
        return None
    start = a if o_start is None else max(a, o_start)
    return round(max(0.0, min(b, o_end) - start) / (b - a), 4)


def admissions_delta(before, after):
    """Change of `small_m_route_admissions` per reason; None when either read lacks it."""
    b, a = cb_of(before).get("small_m_route_admissions"), cb_of(after).get("small_m_route_admissions")
    if not isinstance(b, dict) or not isinstance(a, dict):
        return None
    return {k: (a.get(k) or 0) - (b.get(k) or 0) for k in sorted(set(a) | set(b))}


def trial(args, cell, t, out):
    wait_idle(args.port, args.poll_s)
    before = fetch_status(args.port)
    base = {"label": args.label, "cell": cell, "trial": t, "ctx_target": args.ctx}
    ordinary_extra = {args.ordinary_field: "2462"}
    rows = []
    poller = None
    t0 = time.perf_counter()
    if cell == "ord1":
        for j in range(1, args.ord_rows + 1):
            res = run_request(args.port, args.model, prompts.build_messages(args.ctx, j), args.ord_out, ordinary_extra)
            rows.append(record(res, {**base, "kind": "row", "role": "ordinary", "prompt_row": j,
                                     "max_tokens": args.ord_out}, t0))
            wait_idle(args.port, args.poll_s, settle_s=0.5)
    elif cell == "nat1":
        res = run_request(args.port, args.model, prompts.build_messages(args.ctx, 0), args.nat_out)
        rows.append(record(res, {**base, "kind": "row", "role": "native", "prompt_row": 0,
                                 "max_tokens": args.nat_out}, t0))
    elif cell == "mix":
        poller = Poller(args.port, args.poll_s)
        poller.start()
        first = threading.Event()
        results = {}

        def go(key, messages, max_tokens, extra=None, ev=None):
            results[key] = run_request(args.port, args.model, messages, max_tokens, extra, ev)

        nat = threading.Thread(target=go, args=("native", prompts.build_messages(args.ctx, 0), args.nat_out, None, first))
        nat.start()
        first.wait()
        workers = [threading.Thread(target=go, args=(j, prompts.build_messages(args.ctx, j), args.ord_out, ordinary_extra))
                   for j in range(1, args.ord_rows + 1)]
        for w in workers:
            w.start()
        for w in workers + [nat]:
            w.join()
        poller.stop.set()
        poller.join()
        native = record(results["native"], {**base, "kind": "row", "role": "native", "prompt_row": 0,
                                            "max_tokens": args.nat_out}, t0)
        rows.append(native)
        for j in range(1, args.ord_rows + 1):
            r = record(results[j], {**base, "kind": "row", "role": "ordinary", "prompt_row": j,
                                    "max_tokens": args.ord_out}, t0)
            r["native_overlap_share"] = overlap_share(r, native)
            rows.append(r)
    else:
        poller = Poller(args.port, args.poll_s)
        poller.start()
        results = {}
        reached = {j: threading.Event() for j in range(1, args.ord_rows + 1)}

        def go_ord(j):
            results[j] = run_request(args.port, args.model, prompts.build_messages(args.ctx, j), args.ord_out,
                                     ordinary_extra, reached=reached[j], after=args.late_after)

        def go_late():
            results["late"] = run_request(args.port, args.model, prompts.build_messages(args.ctx, 0), args.nat_out)

        workers = [threading.Thread(target=go_ord, args=(j,)) for j in range(1, args.ord_rows + 1)]
        for w in workers:
            w.start()
        for ev in reached.values():
            ev.wait()
        late = threading.Thread(target=go_late)
        late.start()
        for w in workers + [late]:
            w.join()
        poller.stop.set()
        poller.join()
        late_row = record(results["late"], {**base, "kind": "row", "role": "late", "prompt_row": 0,
                                            "max_tokens": args.nat_out}, t0)
        rows.append(late_row)
        for j in range(1, args.ord_rows + 1):
            r = record(results[j], {**base, "kind": "row", "role": "ordinary", "prompt_row": j,
                                    "max_tokens": args.ord_out}, t0)
            r["late_overlap_share"] = overlap_share(r, late_row)
            rows.append(r)
    t_end = time.perf_counter()
    after = fetch_status(args.port)
    tokens = sum(r.get("completion_tokens") or 0 for r in rows)
    last = max((r["t_last_offset_s"] for r in rows if r.get("t_last_offset_s") is not None), default=None)
    summary = {**base, "kind": "trial", "rows": len(rows),
               "native_mtp": native_mtp_delta(native_mtp_of(before), native_mtp_of(after)),
               "small_m_route": cb_of(after).get("small_m_route"),
               "small_m_route_admissions": admissions_delta(before, after),
               "aggregate_tps": round(tokens / last, 3) if last else None,
               "wall_s": round(t_end - t0, 3),
               "errors": [r["error"] for r in rows if r.get("error")]}
    if poller is not None:
        summary.update(peak_active_decode_rows=poller.peak_rows, peak_small_m_route_requests=poller.peak_routes,
                       status_samples=poller.samples)
    for r in rows + [summary]:
        out.write(json.dumps(r) + "\n")
    out.flush()
    print(f"TRIAL label={args.label} cell={cell} trial={t} rows={len(rows)} tokens={tokens} "
          f"agg_tps={summary['aggregate_tps']} native_admissions={summary['native_mtp'].get('requests_since_reset')} "
          f"errors={len(summary['errors'])} admissions={summary['small_m_route_admissions']}"
          + (f" peak_rows={poller.peak_rows} peak_routes={poller.peak_routes}" if poller else ""), flush=True)
    return not summary["errors"]


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--trials", type=int, default=6)
    p.add_argument("--ctx", type=int, default=1000)
    p.add_argument("--ord-rows", type=int, default=2)
    p.add_argument("--ord-out", type=int, default=512)
    p.add_argument("--nat-out", type=int, default=1024)
    p.add_argument("--cells", default="ord1,nat1,mix,mix_late")
    p.add_argument("--late-after", type=int, default=128,
                   help="mix_late: chunks every ordinary row streams before the late request starts")
    p.add_argument("--ordinary-field", default="x_lab_2462_ordinary")
    p.add_argument("--poll-s", type=float, default=0.5)
    args = p.parse_args(argv)
    cells = [c for c in args.cells.split(",") if c]
    if not cells or any(c not in ("ord1", "nat1", "mix", "mix_late") for c in cells):
        p.error("--cells takes ord1,nat1,mix,mix_late")
    if args.ord_rows < 1 or args.trials < 1:
        p.error("--ord-rows and --trials must be >= 1")
    if "mix_late" in cells and not 1 <= args.late_after < args.ord_out:
        p.error("--late-after must be in [1, --ord-out)")
    ok = True
    with open(args.out, "a") as out:
        for t in range(1, args.trials + 1):
            for cell in cells:
                ok = trial(args, cell, t, out) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
