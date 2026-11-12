"""DeepSeek V4-Flash: DSpark against ordinary decoding on a corrected target (#2111).

Usage (Studio, inside a window, live provider stopped):
  python3 -I dsv4_dspark_bench.py <model_dir> <out_dir> --policy dsv4-cb-dspark-policy.json
      --requests dsv4-dspark-requests.json --long-prompts <oracle-dir>
      [--reference-oracles <window-1 b/oracles>] [--deadline-epoch N] [--stop-file F ...]

The target is mlx-vlm 0.7.10's DeepSeek V4 with the three corrections of
`dsv4_vlm_fidelity.py` (carried ratio-4 overlap, exact indexer top-k, float32
router). The drafter is mlx-vlm's DSpark module (`deepseek_v4_dspark`, the
artifact's own `mtp.*` stages) at a fixed block size `b` (b - 1 proposals per
round). DeepSeek's TensorFold reference port has no DSpark forward
(`deepseek_v4.py` raises NotImplementedError), and its MoE is a numpy loop,
so it can be neither the drafter host nor a throughput baseline.

Every DSpark run has a same-window ordinary control on the same prompt, and
greedy parity is checked token for token against it. Phases run in this
order and each run is skipped, not cut, when the deadline cannot fit it:

  A  1 row, 12 natural requests (prose, reasoning, code), ordinary then b in depths
  B  4 rows, one batch per stratum, ordinary then b in depths
  C  the 8192-token prompt at every depth, the 32768-token prompt at b = 2 and
     the best natural depth (prompts are the oracle prompts, a repeated code
     corpus: reported, never decisive)

Writes <out_dir>/runs.jsonl (one line per run, flushed) and <out_dir>/dspark.json.
"""

import argparse
import hashlib
import importlib.metadata as md
import json
import math
import os
import platform
import subprocess
import sys
import threading
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

PREFILL_STEP = 2048


def sha_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Guard:
    """Exit hard on a stop file, the hard deadline, or the parent's death."""

    def __init__(self, deadline, stop_files, log):
        self.deadline = deadline
        self.stop_files = [Path(f) for f in stop_files]
        self.parent = os.getppid()
        self.log = log
        threading.Thread(target=self._watch, daemon=True).start()

    def _watch(self):
        while True:
            reason = None
            if any(f.exists() for f in self.stop_files):
                reason = "stop file"
            elif self.deadline and time.time() > self.deadline + 60:
                reason = "hard deadline"
            elif os.getppid() != self.parent:
                reason = "parent exited"
            if reason:
                self.log({"event": "guard_exit", "reason": reason})
                os._exit(3)
            time.sleep(2)

    def fits(self, seconds):
        if any(f.exists() for f in self.stop_files):
            return False
        return not self.deadline or time.time() + seconds <= self.deadline


def parity(tokens, reference):
    n = min(len(tokens), len(reference))
    first = next((i for i in range(n) if tokens[i] != reference[i]), None)
    if first is None and len(tokens) != len(reference):
        first = n
    return {"equal": first is None, "compared": n, "first_divergence": first,
            "lengths": [len(tokens), len(reference)]}


def spec_stats(drafter, b):
    accepted = [int(a) for a in getattr(drafter, "accept_lens", [])]
    drafted = [int(d) for d in getattr(drafter, "draft_lens", [])]
    rounds = len(accepted)
    if not rounds:
        return {"rounds": 0}
    per_position = []
    for k in range(1, b):
        offered = sum(1 for d in drafted if d >= k)
        hit = sum(1 for a, d in zip(accepted, drafted) if d >= k and a >= k)
        per_position.append(hit / offered if offered else None)
    return {
        "rounds": rounds,
        "accepted": sum(accepted),
        "drafted": sum(drafted),
        "accept_rate": sum(accepted) / sum(drafted) if sum(drafted) else None,
        "tokens_per_round": (sum(accepted) + rounds) / rounds,
        "per_position_acceptance": per_position,
        "accept_histogram": [accepted.count(k) for k in range(b)],
    }


def gap_at(logprobs, index):
    import mlx.core as mx

    if index is None or index >= len(logprobs):
        return None
    top = mx.topk(logprobs[index].reshape(-1).astype(mx.float32), 2)
    return float(mx.max(top) - mx.min(top))


def one_row(model, ids, decode, drafter=None, b=None, keep_logprobs=False):
    import mlx.core as mx
    from mlx_vlm.generate import generate_step

    mx.synchronize()
    mx.clear_cache()
    mx.reset_peak_memory()
    extra = {}
    if drafter is not None:
        drafter.accept_lens, drafter.draft_lens = [], []
        extra = {"draft_model": drafter, "draft_kind": "dflash", "draft_block_size": b}
    tokens, stamps, logprobs = [], [], []
    t0 = time.perf_counter()
    for token, lp in generate_step(mx.array([ids]), model, None, None, max_tokens=decode, temperature=0.0,
                                   prefill_step_size=PREFILL_STEP, **extra):
        stamps.append(time.perf_counter())
        tokens.append(int(token.item() if hasattr(token, "item") else token))
        if keep_logprobs and lp is not None:
            logprobs.append(lp)
    record = {
        "prompt_tokens": len(ids),
        "decode_tokens": len(tokens),
        "ttft_s": stamps[0] - t0,
        "decode_tps": (len(stamps) - 1) / (stamps[-1] - stamps[0]) if len(stamps) > 1 else None,
        "peak_memory_gb": mx.get_peak_memory() / 1e9,
    }
    if drafter is not None:
        record["spec"] = spec_stats(drafter, b)
    return record, tokens, logprobs


def multi_row(model, processor, prompts, decode, drafter=None, b=None):
    import mlx.core as mx
    from mlx_vlm.generate import BatchGenerator
    from mlx_vlm.generate.ar import _split_prompt_kwargs_per_row

    mx.synchronize()
    mx.clear_cache()
    mx.reset_peak_memory()
    row_kwargs = []
    for ids in prompts:
        embedded = model.get_input_embeddings(mx.array([ids]), None, mask=None)
        kw = {k: v for k, v in embedded.to_dict().items() if v is not None}
        row_kwargs.append(_split_prompt_kwargs_per_row(kw, 1)[0])
    extra = {}
    if drafter is not None:
        drafter.accept_lens, drafter.draft_lens = [], []
        extra = {"draft_model": drafter, "draft_kind": "dflash", "draft_block_size": b}
    rows = len(prompts)
    gen = BatchGenerator(model.language_model, processor, max_tokens=decode, prefill_batch_size=rows,
                         completion_batch_size=rows, prefill_step_size=PREFILL_STEP, compute_logprobs=False,
                         greedy_sampling=True, **extra)
    t0 = time.perf_counter()
    uids = gen.insert([list(p) for p in prompts], decode, prompt_kwargs=row_kwargs)
    first, last, tokens = {}, {}, {u: [] for u in uids}
    while gen.has_work:
        _, responses = gen.next()
        now = time.perf_counter()
        for r in responses:
            first.setdefault(r.uid, now)
            last[r.uid] = now
            tokens[r.uid].append(int(r.token))
    wall = time.perf_counter() - t0
    gen.close()
    counts = [len(tokens[u]) for u in uids]
    decode_start = max(first.values())
    window = max(last.values()) - decode_start
    record = {
        "rows": rows,
        "prompt_tokens": [len(p) for p in prompts],
        "output_tokens": sum(counts),
        "wall_s": wall,
        "aggregate_output_tps": sum(counts) / wall,
        "decode_window_tps": sum(n - 1 for n in counts) / window if window > 0 else None,
        "ttft_first_row_s": min(first.values()) - t0,
        "ttft_last_row_s": decode_start - t0,
        "peak_memory_gb": mx.get_peak_memory() / 1e9,
    }
    if drafter is not None:
        record["spec"] = spec_stats(drafter, b)
    return record, [tokens[u] for u in uids]


def geomean(xs):
    xs = [x for x in xs if x]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else None


def verdict(runs, depths, strata, bar):
    """Natural-request speedup; every required cell and observed parity must pass."""
    table = {}
    for b in depths:
        per_stratum = {}
        complete = True
        observed = [r for r in runs if r.get("b") == b]
        exact = all(r.get("parity", {}).get("equal") is True for r in observed)
        for s in strata:
            cells = [r for r in observed if r.get("phase") == "A" and r.get("stratum") == s]
            expected = {f"{s}-{i}" for i in range(4)}
            ratios = [r["speedup"] for r in cells if isinstance(r.get("speedup"), (int, float))
                      and math.isfinite(r["speedup"]) and r["speedup"] > 0 and not r.get("error")]
            complete = complete and {r.get("name") for r in cells} == expected and len(cells) == len(ratios) == 4
            per_stratum[s] = geomean(ratios)
        batches = [r for r in observed if r.get("phase") == "B"]
        complete = complete and {r.get("stratum") for r in batches} == set(strata) and len(batches) == len(strata)
        complete = complete and any(r.get("phase") == "C" and r.get("ctx") == 8192 for r in observed)
        means = [v for v in per_stratum.values() if v]
        table[b] = {"per_stratum_speedup": per_stratum, "mean_of_strata": sum(means) / len(means) if means else None,
                    "all_exact": exact, "complete": complete}
    best = max((b for b in table if table[b]["mean_of_strata"]), key=lambda b: table[b]["mean_of_strata"], default=None)
    for b in {depths[0], best} - {None}:
        table[b]["complete"] = table[b]["complete"] and any(
            r.get("phase") == "C" and r.get("ctx") == 32768 and r.get("b") == b for r in runs)
    go = [b for b, t in table.items() if t["complete"] and t["all_exact"] and (t["mean_of_strata"] or 0) >= bar]
    stratum_only = sorted({s for b, t in table.items() if t["complete"] and t["all_exact"]
                           for s, v in t["per_stratum_speedup"].items() if (v or 0) >= bar})
    if go:
        decision = "GO"
    elif stratum_only:
        decision = "GO_STRATUM_ONLY"
    elif not any(t["complete"] for t in table.values()):
        decision = "INCOMPLETE"
    else:
        decision = "NO_GO"
    return {"bar": bar, "by_depth": table, "go_depths": go, "strata_clearing_bar": stratum_only,
            "best_depth": best, "decision": decision}


def main():
    import numpy as np

    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--policy", required=True)
    ap.add_argument("--requests", required=True)
    ap.add_argument("--long-prompts", required=True)
    ap.add_argument("--reference-oracles")
    ap.add_argument("--deadline-epoch", type=float, default=0)
    ap.add_argument("--stop-file", action="append", default=[])
    a = ap.parse_args()
    out = Path(a.out_dir)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    policy = json.loads(Path(a.policy).read_text())
    lane = policy["dspark"]
    depths, decode, bar = lane["block_sizes"], lane["decode_tokens"], lane["go_speedup"]
    log_file = open(out / "runs.jsonl", "a", buffering=1)
    runs = []

    def log(record):
        record = {"t": round(time.time(), 3), **record}
        log_file.write(json.dumps(record) + "\n")
        print(json.dumps(record), flush=True)
        if "phase" in record:
            runs.append(record)

    guard = Guard(a.deadline_epoch, a.stop_file, log)
    meta = {"lane": "mlx-vlm-0.7.10-deepseek_v4+dsv4_vlm_fidelity", "policy_sha256": sha_file(a.policy),
            "requests_sha256": sha_file(a.requests), "bench_sha256": sha_file(__file__),
            "fidelity_sha256": sha_file(HERE / "dsv4_vlm_fidelity.py"), "proof_scope": "reference_only"}
    summary = {"meta": meta}

    def finish(status):
        summary["status"] = status
        summary["verdict"] = verdict(runs, depths, ["prose", "reasoning", "code"], bar)
        (out / "dspark.json").write_text(json.dumps(summary, indent=1))
        log({"event": "finish", "status": status, "decision": summary["verdict"]["decision"]})

    import mlx.core as mx
    import dsv4_vlm_fidelity as fidelity
    from mlx_vlm import load
    from mlx_vlm.generate import generation_stream, wired_limit
    from mlx_vlm.speculative.drafters import load_drafter

    meta["sources"] = fidelity.verify_sources()
    meta["versions"] = {p: md.version(p) for p in ("mlx", "mlx-metal", "mlx-vlm", "transformers", "numpy")}
    meta["macos_build"] = subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip()
    meta["machine"] = platform.machine()
    requests = json.loads(Path(a.requests).read_text())["requests"]
    long_prompts = {}
    for ctx in lane["long_contexts"]:
        prompt = np.load(Path(a.long_prompts) / f"oracle_{ctx}.npz")["prompt"].astype(np.int32).tolist()
        if len(prompt) != ctx:
            raise SystemExit(f"oracle_{ctx}.npz prompt has {len(prompt)} tokens")
        long_prompts[ctx] = prompt

    t = time.perf_counter()
    model, processor = load(a.model_dir)
    meta["load_s"] = time.perf_counter() - t
    meta["fidelity"] = fidelity.apply(model)
    tok = getattr(processor, "tokenizer", processor)
    for r in requests:
        ids = tok.encode(r["prompt"], add_special_tokens=False)
        if list(ids) != r["ids"]:
            raise SystemExit(f"{r['name']}: runtime tokenization differs from the frozen production ids")
    t = time.perf_counter()
    drafter, kind = load_drafter(a.model_dir, kind="dflash")
    meta["drafter_load_s"] = time.perf_counter() - t
    meta["drafter"] = {"kind": kind, "type": type(drafter).__name__,
                       "block_size": int(drafter.config.block_size)}
    if kind != "dflash" or type(drafter).__name__ != "DeepseekV4DsparkDraftModel":
        raise SystemExit(f"unexpected drafter {meta['drafter']}")
    if max(depths) > int(drafter.config.block_size):
        raise SystemExit(f"block size {max(depths)} exceeds the drafter's {drafter.config.block_size}")
    drafter.prefer_requested_block_size = True  # fixed depth: no acceptance-driven backoff
    mx.eval(drafter.parameters())
    log({"event": "loaded", **{k: meta[k] for k in ("load_s", "drafter_load_s", "fidelity", "drafter")}})

    try:
        with wired_limit(model, [generation_stream]):
            one_row(model, requests[0]["ids"], 8)
            one_row(model, requests[0]["ids"], 8, drafter, 2)
            ordinary_1row = {}
            # A: 1 row, natural requests.
            for r in requests:
                if not guard.fits(60):
                    log({"phase": "A", "name": r["name"], "stratum": r["stratum"], "skipped": "deadline"})
                    continue
                base, base_tokens, base_lp = one_row(model, r["ids"], decode, keep_logprobs=True)
                ordinary_1row[r["name"]] = base_tokens
                log({"phase": "A", "name": r["name"], "stratum": r["stratum"], "b": 0, **base})
                for b in depths:
                    try:
                        rec, tokens, _ = one_row(model, r["ids"], decode, drafter, b)
                        p = parity(tokens, base_tokens)
                        p["ordinary_top2_gap_at_divergence"] = gap_at(base_lp, p["first_divergence"])
                        speedup = rec["decode_tps"] / base["decode_tps"] if rec["decode_tps"] else None
                        log({"phase": "A", "name": r["name"], "stratum": r["stratum"], "b": b, **rec,
                             "speedup": speedup, "parity": p})
                    except Exception as exc:
                        log({"phase": "A", "name": r["name"], "stratum": r["stratum"], "b": b,
                             "error": f"{type(exc).__name__}: {exc}"})
                del base_lp
            best = verdict(runs, depths, ["prose", "reasoning", "code"], bar)["best_depth"] or depths[0]
            # B: 4 rows per stratum.
            for stratum in ("prose", "reasoning", "code"):
                group = [r for r in requests if r["stratum"] == stratum][: lane["batch_rows"]]
                if not guard.fits(240):
                    log({"phase": "B", "stratum": stratum, "skipped": "deadline"})
                    continue
                try:
                    base, base_rows = multi_row(model, processor, [r["ids"] for r in group], decode)
                    vs_1row = [parity(t, ordinary_1row[r["name"]])["equal"] if r["name"] in ordinary_1row else None
                               for t, r in zip(base_rows, group)]
                    log({"phase": "B", "stratum": stratum, "b": 0, **base, "rows_equal_1row_ordinary": vs_1row})
                except Exception as exc:
                    log({"phase": "B", "stratum": stratum, "b": 0, "error": f"{type(exc).__name__}: {exc}"})
                    continue
                for b in depths:
                    try:
                        rec, rows = multi_row(model, processor, [r["ids"] for r in group], decode, drafter, b)
                        ps = [parity(t, ref) for t, ref in zip(rows, base_rows)]
                        speedup = (rec["decode_window_tps"] / base["decode_window_tps"]
                                   if rec["decode_window_tps"] and base["decode_window_tps"] else None)
                        log({"phase": "B", "stratum": stratum, "b": b, **rec, "speedup": speedup,
                             "parity": {"equal": all(p["equal"] for p in ps), "rows": ps}})
                    except Exception as exc:
                        log({"phase": "B", "stratum": stratum, "b": b, "error": f"{type(exc).__name__}: {exc}"})
            # C: long contexts.
            for ctx, prompt in long_prompts.items():
                arms = depths if ctx <= 8192 else sorted({depths[0], best})
                cost = (ctx / 330 + 15) * (len(arms) + 1)
                if not guard.fits(cost):
                    log({"phase": "C", "ctx": ctx, "skipped": "deadline", "estimate_s": cost})
                    continue
                base, base_tokens, base_lp = one_row(model, prompt, decode, keep_logprobs=True)
                ref = None
                if a.reference_oracles and (Path(a.reference_oracles) / f"oracle_{ctx}.npz").exists():
                    oracle = np.load(Path(a.reference_oracles) / f"oracle_{ctx}.npz")
                    if oracle["prompt"].tolist() == prompt:
                        ref = parity(base_tokens, oracle["greedy"].tolist())
                log({"phase": "C", "ctx": ctx, "b": 0, **base, "ordinary_vs_reference_oracle": ref})
                for b in arms:
                    try:
                        rec, tokens, _ = one_row(model, prompt, decode, drafter, b)
                        p = parity(tokens, base_tokens)
                        p["ordinary_top2_gap_at_divergence"] = gap_at(base_lp, p["first_divergence"])
                        log({"phase": "C", "ctx": ctx, "b": b, **rec, "parity": p,
                             "speedup": rec["decode_tps"] / base["decode_tps"] if rec["decode_tps"] else None})
                    except Exception as exc:
                        log({"phase": "C", "ctx": ctx, "b": b, "error": f"{type(exc).__name__}: {exc}"})
                del base_lp
    except Exception as exc:
        log({"event": "lane_error", "error": f"{type(exc).__name__}: {exc}"})
        finish("error")
        raise
    finish("complete")


if __name__ == "__main__":
    main()
