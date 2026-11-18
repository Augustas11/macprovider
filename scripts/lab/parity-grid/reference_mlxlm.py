#!/usr/bin/env python3
"""Stock mlx-lm reference for the parity grid: one loaded model, greedy decode.

usage: reference_mlxlm.py --model-path DIR --model-name NAME --out ref.jsonl
                          [--grid grid.json] [--trials 3] [--rows 1,4]
                          [--extra-row-trials 1] [--max-context N]
                          [--turns 2 --provider-jsonl provider.jsonl]
                          [--loader mlx-lm|qwen4] [--batched] [--batched-trials N]
                          [--prefill-batch-size N]

For every grid cell it runs prompt row 0 `--trials` times. For a cell with
N > 1 rows it also runs prompt rows 1..N-1 single-row (`--extra-row-trials`
times) so compare.py has a single-row reference text for every concurrent row.
Generation stops only on max_tokens ("length") or EOS ("stop"); no stop strings.
request_tps = completion_tokens / (t_last - t0): request-level output tok/s.
The first line of a run is a `kind: meta` record with the package versions.

--loader qwen4 loads with scripts/lab/ablit-perf/qwen4_oracle.py (mlx-lm's own qwen4_exp
Model and sanitize, mixed-width merges kept as two quantized matmuls); stock mlx_lm.load
cannot read the oQ4e build. The default loader is stock mlx_lm.load.

--batched: a cell with N > 1 rows is one batch of its N prompts through mlx-lm's
BatchGenerator (the engine under mlx_lm.generate.batch_generate), greedy, the cell's max
tokens, completion_batch_size = N, prefill_batch_size = --prefill-batch-size (default: mlx-lm's
own, 8). All N requests start at one instant t0 (the insert). Per batched trial it writes N
`kind: row` lines (rows N, row r = prompt row r, so every row carries its own text, token
count and timings) and one `kind: aggregate` line. Per row: ttft_s = first emitted token -
t0 (it includes the prefill queue of the rows ahead of it), decode_tps = (tokens - 1) /
(last - first token), request_tps = tokens / (last - t0); the last time is the row's final
response, the stop response included. aggregate_tps = total completion tokens / (last
response of the last row - t0): the definition of compare.py trial_metrics, so compare.py scores
a multi-row provider cell against it. With --batched the single-row runs are only for cells
with rows 1 (--extra-row-trials is ignored): a multi-row cell is judged against its batched run.
Rows = 1 behaviour is unchanged.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import prompts  # noqa: E402


def model_max_context(model_path):
    try:
        with open(os.path.join(model_path, "config.json")) as f:
            cfg = json.load(f)
    except OSError:
        return None
    for key in ("max_position_embeddings", "max_seq_len", "seq_length"):
        if isinstance(cfg.get(key), int):
            return cfg[key]
    text_cfg = cfg.get("text_config") or {}
    return text_cfg.get("max_position_embeddings")


def package_versions(names):
    out = {}
    for name in names:
        try:
            out[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            out[name] = None
    return out


def reference_jobs(cells, trials, extra_row_trials):
    """Map (ctx, out, prompt_row) -> trial count, deduplicated across cells."""
    jobs = {}
    for ctx, out, rows in cells:
        for r in range(rows):
            n = trials if r == 0 else extra_row_trials
            jobs[(ctx, out, r)] = max(jobs.get((ctx, out, r), 0), n)
    return sorted(jobs.items())


def summarize_batch(rows, t0):
    """Row records and the aggregate record of one batched trial.

    rows: per prompt row, a dict with prompt_tokens, tokens (emitted completion tokens, the stop
    token excluded), t_first (time of the first emitted token or None), t_last (time of the row's
    final response or None), finish and text. Times are perf_counter readings, t0 the common
    start. Returns (row records without cell/model fields, aggregate record).
    """
    out = []
    for r in rows:
        ct, tf, tl = r["tokens"], r["t_first"], r["t_last"]
        span = (tl - tf) if tf is not None and tl is not None else 0.0
        out.append({
            "prompt_tokens": r["prompt_tokens"],
            "completion_tokens": ct,
            "decode_tps": round((ct - 1) / span, 3) if ct > 1 and span > 0 else None,
            "ttft_s": round(tf - t0, 4) if tf is not None else None,
            "request_tps": round(ct / (tl - t0), 3) if ct > 0 and tl is not None and tl > t0 else None,
            "total_s": round(tl - t0, 4) if tl is not None else None,
            "start_offset_s": 0.0,
            "t_last_offset_s": round(tl - t0, 4) if tl is not None else None,
            "finish": r["finish"],
            "text": r["text"],
        })
    lasts = [r["t_last"] for r in rows if r["t_last"] is not None]
    wall = (max(lasts) - t0) if lasts else 0.0
    total = sum(r["tokens"] for r in rows)
    agg = {
        "aggregate_tps": round(total / wall, 3) if wall > 0 and total > 0 else None,
        "wall_s": round(wall, 4) if wall > 0 else None,
        "completion_tokens_sum": total,
        "per_row_request_tps": [o["request_tps"] for o in out],
        "per_row_ttft_s": [o["ttft_s"] for o in out],
        "ttft_s_max": max((o["ttft_s"] for o in out if o["ttft_s"] is not None), default=None),
    }
    return out, agg


def run_batch(model, tokenizer, ids_list, max_tokens, sampler, prefill_batch_size=None):
    """One batch of prompts (token id lists) through mlx-lm's BatchGenerator, greedy."""
    from mlx_lm.generate import BatchGenerator

    n = len(ids_list)
    kwargs = {} if prefill_batch_size is None else {"prefill_batch_size": prefill_batch_size}
    gen = BatchGenerator(model, max_tokens=max_tokens, sampler=sampler, completion_batch_size=n,
                         stop_tokens=[[t] for t in tokenizer.eos_token_ids], **kwargs)
    try:
        t0 = time.perf_counter()
        uids = gen.insert(ids_list, [max_tokens] * n)
        state = {u: {"tokens": [], "t_first": None, "t_last": None, "finish": None} for u in uids}
        while True:
            responses = gen.next_generated()
            now = time.perf_counter()
            if not responses:
                break
            for r in responses:
                st = state[r.uid]
                st["t_last"] = now
                if r.finish_reason != "stop":  # the stop token is not emitted (batch_generate does the same)
                    st["tokens"].append(r.token)
                    if st["t_first"] is None:
                        st["t_first"] = now
                if r.finish_reason is not None:
                    st["finish"] = r.finish_reason
    finally:
        gen.close()
    rows = [{"prompt_tokens": len(ids), "tokens": len(state[u]["tokens"]), "t_first": state[u]["t_first"],
             "t_last": state[u]["t_last"], "finish": state[u]["finish"],
             "text": tokenizer.decode(state[u]["tokens"])} for u, ids in zip(uids, ids_list)]
    return summarize_batch(rows, t0)


def batched_jobs(cells, trials):
    """(ctx, out, rows) of every multi-row cell, deduplicated, with the trial count."""
    return [((ctx, out, rows), trials) for ctx, out, rows in sorted({c for c in cells if c[2] > 1})]


def load_model(loader, path):
    """(model, tokenizer) by the stock loader or the qwen4_exp oracle loader (module docstring)."""
    if loader == "mlx-lm":
        from mlx_lm import load
        return load(path)
    from pathlib import Path

    from mlx_lm.utils import load_tokenizer

    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ablit-perf"))
    import qwen4_oracle

    model, info = qwen4_oracle.load(path)
    for line in info["split"]:
        print(f"ORACLE_SPLIT {line}", file=sys.stderr, flush=True)
    eos = set()
    for v in (model.args.text.eos_token_id, json.load(open(os.path.join(path, "config.json"))).get("eos_token_id")):
        eos |= set(v if isinstance(v, list) else [] if v is None else [v])
    return model, load_tokenizer(Path(path), eos_token_ids=sorted(eos))


def run_one(model, tokenizer, stream_generate, sampler, ids, max_tokens):
    t0 = time.perf_counter()
    t_first = t_last = None
    pieces = []
    last = None
    for resp in stream_generate(model, tokenizer, ids, max_tokens=max_tokens, sampler=sampler):
        now = time.perf_counter()
        if t_first is None:
            t_first = now
        t_last = now
        pieces.append(resp.text)
        last = resp
    finish = last.finish_reason
    raw_tokens = last.generation_tokens
    # mlx-lm counts the EOS token in generation_tokens but does not emit it.
    completion = raw_tokens - 1 if finish == "stop" else raw_tokens
    span = (t_last - t_first) if t_last and t_first else 0.0
    return {
        "prompt_tokens": last.prompt_tokens,
        "completion_tokens": completion,
        "mlxlm_generation_tokens": raw_tokens,
        "decode_tps": round((completion - 1) / span, 3) if span > 0 and completion > 1 else None,
        "ttft_s": round(t_first - t0, 4),
        "request_tps": round(completion / (t_last - t0), 3) if completion > 0 and t_last else None,
        "total_s": round(t_last - t0, 4),
        "mlxlm_generation_tps": round(last.generation_tps, 3),
        "mlxlm_prompt_tps": round(last.prompt_tps, 3),
        "peak_gb": round(last.peak_memory, 2),
        "finish": finish,
        "text": "".join(pieces),
    }


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--model-name", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--grid", default=os.path.join(here, "grid.json"))
    ap.add_argument("--trials", type=int)
    ap.add_argument("--rows", help="comma list overriding grid rows, e.g. 1,4")
    ap.add_argument("--extra-row-trials", type=int, default=1)
    ap.add_argument("--max-context", type=int)
    ap.add_argument("--turns", type=int, choices=(1, 2), default=1,
                    help="2: also run turn 2 (turn=2 rows) on the assistant1 text in --provider-jsonl")
    ap.add_argument("--provider-jsonl", help="provider.jsonl of a --turns 2 provider run (needed with --turns 2)")
    ap.add_argument("--loader", choices=("mlx-lm", "qwen4"), default="mlx-lm")
    ap.add_argument("--batched", action="store_true")
    ap.add_argument("--batched-trials", type=int)
    ap.add_argument("--prefill-batch-size", type=int)
    args = ap.parse_args(argv)
    if args.turns == 2 and not args.provider_jsonl:
        ap.error("--turns 2 needs --provider-jsonl")
    assistant1 = prompts.load_assistant1(args.provider_jsonl) if args.turns == 2 else {}

    grid = prompts.load_grid(args.grid)
    if args.rows:
        grid["rows"] = [int(x) for x in args.rows.split(",")]
    trials = args.trials or grid.get("trials", 3)
    max_ctx = args.max_context or model_max_context(args.model_path)
    cells = prompts.expand_cells(grid, max_ctx)

    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler

    t = time.perf_counter()
    model, tokenizer = load_model(args.loader, args.model_path)
    load_s = round(time.perf_counter() - t, 2)
    sampler = make_sampler(temp=0.0)

    # The provider renders a request that does not ask for reasoning with
    # thinking off. A template that has the switch gets the same here, or the
    # two sides decode different prompts.
    template = getattr(tokenizer, "chat_template", None) or ""
    template_kwargs = {"enable_thinking": False} if "enable_thinking" in str(template) else {}

    def encode(messages):
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, **template_kwargs)

    # Warm up on a prompt that no measured cell uses.
    run_one(model, tokenizer, stream_generate, sampler,
            encode(prompts.build_messages(200, 9999)), grid.get("warmup_tokens", 32))
    single_cells = [c for c in cells if c[2] == 1] if args.batched else cells
    extra_row_trials = 0 if args.batched else args.extra_row_trials
    batch_jobs = batched_jobs(cells, args.batched_trials or trials) if args.batched else []
    for n in sorted({rows for (_, _, rows), _ in batch_jobs}):  # one warm-up per batch width
        run_batch(model, tokenizer, [encode(prompts.build_messages(200, 9990 + i)) for i in range(n)],
                  grid.get("warmup_tokens", 32), sampler, args.prefill_batch_size)

    with open(args.out, "a") as out:
        out.write(json.dumps({"side": "reference", "kind": "meta", "reference": "mlx-lm",
                              "model": args.model_name, "model_path": args.model_path, "load_s": load_s,
                              "versions": package_versions(("mlx", "mlx-lm", "transformers")),
                              "loader": args.loader, "batched": args.batched,
                              "prefill_batch_size": args.prefill_batch_size}) + "\n")
        for (ctx, max_tokens, prow), n in reference_jobs(single_cells, trials, extra_row_trials):
            ids = encode(prompts.build_messages(ctx, prow))
            for trial in range(n):
                rec = run_one(model, tokenizer, stream_generate, sampler, ids, max_tokens)
                line = {
                    "side": "reference",
                    "reference": "mlx-lm",
                    "kind": "row",
                    "model": args.model_name,
                    "cell": prompts.cell_key(args.model_name, ctx, max_tokens, 1),
                    "ctx_target": ctx,
                    "max_tokens": max_tokens,
                    "rows": 1,
                    "row": prow,
                    "trial": trial,
                    "load_s": load_s,
                    **({"turn": 1} if args.turns == 2 else {}),
                    **rec,
                    "sha256": hashlib.sha256(rec["text"].encode()).hexdigest(),
                }
                out.write(json.dumps(line) + "\n")
                out.flush()
                print(f"ref ctx={ctx} out={max_tokens} row={prow} trial={trial} "
                      f"tps={rec['decode_tps']} n={rec['completion_tokens']} finish={rec['finish']}",
                      file=sys.stderr)
        # Turn 2 replays the provider's turn-1 text. This reference keeps no prefix cache between
        # requests, so cached_prompt_tokens is None (compare reports it as unknown).
        for (ctx, max_tokens, prow), n in reference_jobs(single_cells, trials, extra_row_trials):
            if (ctx, max_tokens, prow) not in assistant1 or args.turns != 2:
                continue
            a1 = assistant1[(ctx, max_tokens, prow)]
            ids = encode(prompts.build_turn2_messages(ctx, prow, a1))
            for trial in range(n):
                rec = run_one(model, tokenizer, stream_generate, sampler, ids, max_tokens)
                line = {
                    "side": "reference", "reference": "mlx-lm", "kind": "row", "model": args.model_name,
                    "cell": prompts.cell_key(args.model_name, ctx, max_tokens, 1), "ctx_target": ctx,
                    "max_tokens": max_tokens, "rows": 1, "row": prow, "trial": trial, "load_s": load_s,
                    "turn": 2, "cached_prompt_tokens": None, "assistant1": a1, **rec,
                    "sha256": hashlib.sha256(rec["text"].encode()).hexdigest(),
                }
                out.write(json.dumps(line) + "\n")
                out.flush()
                print(f"ref turn2 ctx={ctx} out={max_tokens} row={prow} trial={trial} "
                      f"ttft={rec['ttft_s']} n={rec['completion_tokens']}", file=sys.stderr)
        for (ctx, max_tokens, nrows), n in batch_jobs:
            ids_list = [encode(prompts.build_messages(ctx, r)) for r in range(nrows)]
            for trial in range(n):
                recs, agg = run_batch(model, tokenizer, ids_list, max_tokens, sampler, args.prefill_batch_size)
                base = {"side": "reference", "reference": "mlx-lm", "model": args.model_name,
                        "cell": prompts.cell_key(args.model_name, ctx, max_tokens, nrows),
                        "ctx_target": ctx, "max_tokens": max_tokens, "rows": nrows, "trial": trial,
                        "load_s": load_s, "batched": True}
                for prow, rec in enumerate(recs):
                    out.write(json.dumps({**base, "kind": "row", "row": prow, **rec,
                                          "sha256": hashlib.sha256(rec["text"].encode()).hexdigest()}) + "\n")
                out.write(json.dumps({**base, "kind": "aggregate", **agg}) + "\n")
                out.flush()
                print(f"ref batched ctx={ctx} out={max_tokens} rows={nrows} trial={trial} "
                      f"agg_tps={agg['aggregate_tps']} wall_s={agg['wall_s']} tokens={agg['completion_tokens_sum']}",
                      file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
