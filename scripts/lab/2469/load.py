#!/usr/bin/env python3
"""#2469/#2470 request driver against one loopback serve (stdlib only).

usage: load.py --port P --model ID --label qwen --out rows.jsonl --serve-err serve.err
               --cell nat1 --ctx 34000 --max-tokens 256 --trials 2
               [--rows 4] [--warmup-ctx 512 --warmup-tokens 32] [--poll-s 2]

Cells:
  nat1  one native-MTP-eligible request per trial, alone on the serve (the signed tuples admit
        one active native row, max_native_active_rows = 1). Trial t sends
        prompts.build_messages(ctx, t), so no trial reuses another's prefix.
  ordN  --rows ordinary requests at once (one thread each). Each carries the extra top-level key
        x_lab_2469_ordinary, which is not in NativeMTPDecodeSelector's admitted keys, so the row
        decodes ordinary (the #2462 mixed_load.py mechanism); prompts build_messages(ctx, 100 + r).
A warm-up request (--warmup-ctx/--warmup-tokens, native-eligible) runs first and is recorded
with trial=-1, so first-use compiles of the verify traces fall outside the trials.

Each trial waits for an idle serve, then records the byte size of --serve-err before its first
request and after its last, so verdict.py reads exactly the trial's section_timing lines, and the
/v1/status native_mtp counter change over the trial. Output: one JSON line per request
(kind=row) and per trial (kind=trial). Exit 0 when every request returned a usage frame and no
error, else 1.
"""
import argparse
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.environ.get("PARITY_GRID_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "parity-grid")))
import prompts  # noqa: E402
from provider_client import native_mtp_delta, native_mtp_of, row_record, run_request  # noqa: E402
from route_status import fetch_status  # noqa: E402

ORDINARY_FIELD = "x_lab_2469_ordinary"


def busy(status):
    """True while the serve has a decode row or a waiting request."""
    if status is None:
        return True
    cb = status.get("continuous_batching")
    sch = (cb.get("scheduler") if isinstance(cb, dict) else None) or {}
    return bool(sch.get("active_decode_rows") or sch.get("waiting_count"))


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
                return st
        else:
            misses = 0
        time.sleep(poll_s)


def err_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def run_trial(args, trial, cell, rows, ctx, max_tokens, out):
    before = wait_idle(args.port, args.poll_s)
    err_start = err_size(args.serve_err)
    t0 = time.perf_counter()
    if cell == "nat1":
        jobs = [(prompts.build_messages(ctx, max(trial, 0)), None)]
    else:
        jobs = [(prompts.build_messages(ctx, 100 + r), {ORDINARY_FIELD: True}) for r in range(rows)]
    results = [None] * len(jobs)
    barrier = threading.Barrier(len(jobs))

    def worker(i):
        messages, extra = jobs[i]
        barrier.wait()
        results[i] = run_request(args.port, args.model, messages, max_tokens, extra=extra, timeout=7200)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(len(jobs))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    after = wait_idle(args.port, args.poll_s)
    err_end = err_size(args.serve_err)
    ok = True
    for i, res in enumerate(results):
        rec = row_record(res, {"kind": "row", "label": args.label, "cell": cell, "trial": trial, "row": i,
                               "ctx": ctx, "max_tokens": max_tokens}, cell_t0=t0)
        rec.pop("_t_first", None)
        rec.pop("_t_last", None)
        rec.pop("reasoning_text", None)
        ok = ok and rec["error"] is None
        out.write(json.dumps(rec) + "\n")
        print(f"ROW {args.label} cell={cell} trial={trial} row={i} prompt={rec['prompt_tokens']} "
              f"completion={rec['completion_tokens']} ttft_s={rec['ttft_s']} decode_tps={rec['decode_tps']} "
              f"finish={rec['finish']} error={rec['error']}", flush=True)
    delta = native_mtp_delta(native_mtp_of(before), native_mtp_of(after))
    trec = {"kind": "trial", "label": args.label, "cell": cell, "trial": trial, "rows": len(jobs), "ctx": ctx,
            "max_tokens": max_tokens, "serve_err_start": err_start, "serve_err_end": err_end,
            "native_mtp": delta, "wall_s": round(time.perf_counter() - t0, 3)}
    out.write(json.dumps(trec) + "\n")
    out.flush()
    print(f"TRIAL {args.label} cell={cell} trial={trial} rows={len(jobs)} err_bytes={err_start}-{err_end} "
          f"native_mtp={json.dumps(delta, sort_keys=True)}", flush=True)
    return ok


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--serve-err", required=True)
    ap.add_argument("--cell", required=True)
    ap.add_argument("--ctx", type=int, required=True)
    ap.add_argument("--max-tokens", type=int, required=True)
    ap.add_argument("--trials", type=int, default=1)
    ap.add_argument("--rows", type=int, default=1)
    ap.add_argument("--warmup-ctx", type=int, default=0)
    ap.add_argument("--warmup-tokens", type=int, default=32)
    ap.add_argument("--poll-s", type=float, default=2.0)
    a = ap.parse_args(argv)
    if a.cell != "nat1" and not a.cell.startswith("ord"):
        ap.error("--cell must be nat1 or ordN")
    if a.trials < 1 or a.rows < 1 or a.ctx < 16 or a.max_tokens < 2:
        ap.error("--trials, --rows >= 1, --ctx >= 16, --max-tokens >= 2")
    ok = True
    with open(a.out, "a") as out:
        if a.warmup_ctx > 0:
            ok = run_trial(a, -1, "nat1", 1, a.warmup_ctx, a.warmup_tokens, out) and ok
        for t in range(a.trials):
            ok = run_trial(a, t, a.cell, a.rows, a.ctx, a.max_tokens, out) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
