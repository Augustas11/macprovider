#!/usr/bin/env python3
"""mlx-vlm reference for the parity grid: one loaded model, greedy decode.

usage: reference_mlxvlm.py --model-path DIR --model-name NAME --out ref.jsonl
                           [--grid grid.json] [--trials 3] [--rows 1,4]
                           [--extra-row-trials 1] [--max-context N]
                           [--refusal-ablation SNAPSHOT_DIR]

The counterpart of reference_mlxlm.py for families mlx-lm cannot load
(GLM-5.3-Flash glm5_next, MiniMax M3.1-Flash): same jobs, same JSONL schema,
same formulas. It decodes with mlx-vlm's own `stream_generate` loop (text
only, `temperature=0.0` = greedy argmax, repetition/presence penalties
explicitly off, no prompt cache), on prompt ids
rendered by the tokenizer's chat template (`enable_thinking: False` when the
template has the switch) and encoded without added special tokens.

  decode_tps  = (completion_tokens - 1) / (t_last - t_first)
  ttft_s      = t_first - t0
  request_tps = completion_tokens / (t_last - t0)
t_first / t_last are the arrival times of the first and last generated token;
completion_tokens excludes EOS (recorded as `vlm_generation_tokens`).

--refusal-ablation SNAPSHOT_DIR applies the runtime refusal-direction
projection that SNAPSHOT_DIR's config.json names (`text_config.refusal_ablation`:
layers, alpha, direction_file, direction_key), the way minimax_ablate.py and
minimax_parity_oracle.py do: in each listed decoder layer the attention output
and the MLP/MoE output y become y - alpha * d (d . y). --model-path is then
the unmodified base snapshot (mlx-vlm would read the direction file of the
published snapshot as a weight). The abliterated row's reference so computes
the same function as our runtime on the published snapshot.

The first output line is a `kind: meta` record: mlx / mlx-vlm / transformers
versions, wired limit, and the ablation parameters and direction sha256.
"""
import argparse
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import prompts  # noqa: E402
from reference_mlxlm import model_max_context, package_versions, reference_jobs  # noqa: E402

MINIMAX_DIR = os.path.join(HERE, "..", "minimax")


def read_ablation(snapshot_dir):
    """The refusal_ablation block and direction path of a published snapshot."""
    with open(os.path.join(snapshot_dir, "config.json")) as f:
        cfg = json.load(f)
    abl = (cfg.get("text_config") or cfg).get("refusal_ablation")
    if not isinstance(abl, dict):
        raise SystemExit(f"{snapshot_dir}/config.json has no text_config.refusal_ablation")
    lo, hi = abl["layers"]
    path = os.path.join(snapshot_dir, abl["direction_file"])
    with open(path, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    return {"layers": [int(lo), int(hi)], "alpha": float(abl["alpha"]), "direction_file": path,
            "direction_key": abl.get("direction_key"), "direction_sha256": sha}


def apply_ablation(model, abl):
    import mlx.core as mx
    sys.path.insert(0, os.path.abspath(MINIMAX_DIR))
    from minimax_ablate import Ablation  # noqa: E402  (class-level layer patch)

    loaded = mx.load(abl["direction_file"])
    key = abl["direction_key"] if abl["direction_key"] in loaded else None
    if key is None:
        if len(loaded) != 1:
            raise SystemExit(f"direction file holds {sorted(loaded)}, none is {abl['direction_key']}")
        key = next(iter(loaded))
    d = loaded[key]
    if d.ndim != 1:
        raise SystemExit(f"direction {key} has shape {d.shape}, want 1-D")
    layers = model.language_model.model.layers
    lo, hi = abl["layers"]
    if not 0 <= lo <= hi < len(layers):
        raise SystemExit(f"ablation layers {lo}..{hi} outside 0..{len(layers) - 1}")
    Ablation(type(layers[0]))
    for i in range(lo, hi + 1):
        layers[i]._ablate = (abl["alpha"], d)


def run_one(model, processor, stream_generate, ids, max_tokens):
    import mlx.core as mx
    input_ids = mx.array([ids])
    t0 = time.perf_counter()
    t_first = t_last = None
    pieces = []
    last = None
    for resp in stream_generate(model, processor, "", input_ids=input_ids,
                                max_tokens=max_tokens, temperature=0.0,
                                # Explicit no-ops: unset options fall back to
                                # the checkpoint's generation_config.json.
                                repetition_penalty=1.0, presence_penalty=0.0):
        now = time.perf_counter()
        pieces.append(resp.text)
        last = resp
        # The closing summary (finish_reason set) carries no new token: on
        # "length" it repeats the last one, on "stop" it is the EOS.
        if getattr(resp, "finish_reason", None) is None and resp.token is not None:
            if t_first is None:
                t_first = now
            t_last = now
    finish = getattr(last, "finish_reason", None)
    raw_tokens = last.generation_tokens
    completion = raw_tokens - 1 if finish == "stop" else raw_tokens
    span = (t_last - t_first) if t_last and t_first else 0.0
    return {
        "prompt_tokens": last.prompt_tokens,
        "completion_tokens": completion,
        "vlm_generation_tokens": raw_tokens,
        "decode_tps": round((completion - 1) / span, 3) if span > 0 and completion > 1 else None,
        "ttft_s": round(t_first - t0, 4) if t_first else None,
        "request_tps": round(completion / (t_last - t0), 3) if completion > 0 and t_last else None,
        "total_s": round((t_last or time.perf_counter()) - t0, 4),
        "vlm_generation_tps": round(last.generation_tps, 3),
        "vlm_prompt_tps": round(last.prompt_tps, 3),
        "peak_gb": round(last.peak_memory, 2),
        "finish": finish,
        "text": "".join(pieces),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--model-name", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--grid", default=os.path.join(HERE, "grid.json"))
    ap.add_argument("--trials", type=int)
    ap.add_argument("--rows", help="comma list overriding grid rows, e.g. 1,4")
    ap.add_argument("--extra-row-trials", type=int, default=1)
    ap.add_argument("--max-context", type=int)
    ap.add_argument("--refusal-ablation", metavar="SNAPSHOT_DIR",
                    help="apply the runtime refusal-direction projection this snapshot's config names")
    args = ap.parse_args(argv)

    grid = prompts.load_grid(args.grid)
    if args.rows:
        grid["rows"] = [int(x) for x in args.rows.split(",")]
    trials = args.trials or grid.get("trials", 3)
    max_ctx = args.max_context or model_max_context(args.model_path)
    cells = prompts.expand_cells(grid, max_ctx)
    ablation = read_ablation(args.refusal_ablation) if args.refusal_ablation else None
    if ablation and os.path.realpath(args.refusal_ablation) == os.path.realpath(args.model_path):
        raise SystemExit("--model-path must be the unmodified base, not the --refusal-ablation snapshot")

    import mlx.core as mx
    from mlx_vlm import load
    from mlx_vlm import stream_generate

    # Keep the weights resident, as mlx-lm's generate and the provider do;
    # without it macOS pages a ~190 GB model back in on every forward.
    info = mx.device_info() if hasattr(mx, "device_info") else mx.metal.device_info()
    wired = int(info["max_recommended_working_set_size"])
    mx.set_wired_limit(wired)

    t = time.perf_counter()
    model, processor = load(args.model_path)
    load_s = round(time.perf_counter() - t, 2)
    if ablation:
        apply_ablation(model, ablation)
    tokenizer = getattr(processor, "tokenizer", processor)

    template = getattr(tokenizer, "chat_template", None) or ""
    template_kwargs = {"enable_thinking": False} if "enable_thinking" in str(template) else {}

    def encode(messages):
        text = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False,
                                             **template_kwargs)
        return tokenizer.encode(text, add_special_tokens=False)

    run_one(model, processor, stream_generate, encode(prompts.build_messages(200, 9999)),
            grid.get("warmup_tokens", 32))

    with open(args.out, "a") as out:
        out.write(json.dumps({
            "side": "reference", "kind": "meta", "reference": "mlx-vlm", "model": args.model_name,
            "model_path": args.model_path, "load_s": load_s, "wired_limit_bytes": wired,
            "versions": package_versions(("mlx", "mlx-vlm", "mlx-lm", "transformers")),
            "refusal_ablation": ablation,
        }) + "\n")
        for (ctx, max_tokens, prow), n in reference_jobs(cells, trials, args.extra_row_trials):
            ids = encode(prompts.build_messages(ctx, prow))
            for trial in range(n):
                rec = run_one(model, processor, stream_generate, ids, max_tokens)
                line = {
                    "side": "reference",
                    "reference": "mlx-vlm",
                    "kind": "row",
                    "model": args.model_name,
                    "cell": prompts.cell_key(args.model_name, ctx, max_tokens, 1),
                    "ctx_target": ctx,
                    "max_tokens": max_tokens,
                    "rows": 1,
                    "row": prow,
                    "trial": trial,
                    "load_s": load_s,
                    **rec,
                    "sha256": hashlib.sha256(rec["text"].encode()).hexdigest(),
                }
                out.write(json.dumps(line) + "\n")
                out.flush()
                print(f"ref ctx={ctx} out={max_tokens} row={prow} trial={trial} "
                      f"tps={rec['decode_tps']} req_tps={rec['request_tps']} n={rec['completion_tokens']} "
                      f"finish={rec['finish']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
