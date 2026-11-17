#!/usr/bin/env python3
"""Stock mlx-lm reference for the parity grid: one loaded model, greedy decode.

usage: reference_mlxlm.py --model-path DIR --model-name NAME --out ref.jsonl
                          [--grid grid.json] [--trials 3] [--rows 1,4]
                          [--extra-row-trials 1] [--max-context N]
                          [--turns 2 --provider-jsonl provider.jsonl]

For every grid cell it runs prompt row 0 `--trials` times. For a cell with
N > 1 rows it also runs prompt rows 1..N-1 single-row (`--extra-row-trials`
times) so compare.py has a single-row reference text for every concurrent row.
Generation stops only on max_tokens ("length") or EOS ("stop"); no stop strings.
request_tps = completion_tokens / (t_last - t0): request-level output tok/s.
The first line of a run is a `kind: meta` record with the package versions.
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

    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    t = time.perf_counter()
    model, tokenizer = load(args.model_path)
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

    with open(args.out, "a") as out:
        out.write(json.dumps({"side": "reference", "kind": "meta", "reference": "mlx-lm",
                              "model": args.model_name, "model_path": args.model_path, "load_s": load_s,
                              "versions": package_versions(("mlx", "mlx-lm", "transformers"))}) + "\n")
        for (ctx, max_tokens, prow), n in reference_jobs(cells, trials, args.extra_row_trials):
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
        for (ctx, max_tokens, prow), n in reference_jobs(cells, trials, args.extra_row_trials):
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
