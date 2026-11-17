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
versions, wired limit, the ablation parameters and direction sha256, and the
loader shims applied.

glm5_next loader shim (patch_glm5_next): stock mlx-vlm (0.7.11 through 0.8.0)
cannot load a per-tensor mixed-precision checkpoint in Hugging Face layout
(oMLX oQ exports such as GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2). Its
sanitize fuses q/k/v (and f_a/b/g_a, q_a/kv_a, gate/up) by concatenating the
packed weights, which fails when the parts carry different bits; and its
quantization lookup never maps module paths (`language_model.model.X`) to the
checkpoint's `model.language_model.X` keys, so every module would get the
default bits. The shim leaves a fusion as one matmul per part when the parts'
packed widths differ (same weights, same per-part quantized matmul, outputs
concatenated in the fused order) and adds the missing key aliases. It changes
nothing where stock loading works. MTP layers are dropped by stock sanitize as
before; the DFlash drafter is a separate GGUF that mlx-vlm never reads. Neither
is part of the main forward pass.
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


# Projections stock glm5_next sanitize fuses by concatenating weights:
# (owner under a decoder layer, fused attribute, sources in fused order).
GLM5_FUSIONS = (
    ("self_attn", "qkv_proj", ("q_proj", "k_proj", "v_proj")),
    ("self_attn", "fbg_a_proj", ("f_a_proj", "b_proj", "g_a_proj")),
    ("self_attn", "qkv_a_proj", ("q_a_proj", "kv_a_proj_with_mqa")),
    ("mlp", "gate_up_proj", ("gate_proj", "up_proj")),
    ("mlp.shared_experts", "gate_up_proj", ("gate_proj", "up_proj")),
)
# Modules sanitize rebuilds from kv_b_proj at kv_b_proj's bits.
GLM5_DERIVED = {"embed_q": "kv_b_proj", "unembed_out": "kv_b_proj"}


def glm5_mixed_fusions(shapes, num_layers):
    """(layer, owner, fused, sources) whose parts differ in packed width, scales
    width or affine biases, i.e. in bits, group size or mode; `shapes` maps
    sanitized-prefix keys (language_model.model.layers.N...) to shape tuples."""
    out = []
    for i in range(num_layers):
        for owner, fused, sources in GLM5_FUSIONS:
            base = f"language_model.model.layers.{i}.{owner}"
            if not all(f"{base}.{s}.weight" in shapes for s in sources):
                continue
            sigs = {(shapes[f"{base}.{s}.weight"][-1], (shapes.get(f"{base}.{s}.scales") or (None,))[-1],
                     f"{base}.{s}.biases" in shapes) for s in sources}
            if len(sigs) > 1:
                out.append((i, owner, fused, sources))
    return out


def glm5_quant_aliases(path):
    """Checkpoint quantization keys for a glm5_next module path."""
    head = "language_model.model."
    if not path.startswith(head):
        return ()
    parts = ("model.language_model." + path[len(head):]).split(".")
    fused = {f: s for _, f, s in GLM5_FUSIONS}
    if parts[-1] in GLM5_DERIVED:
        parts[-1] = GLM5_DERIVED[parts[-1]]
    elif parts[-1] in fused:
        # A fused module exists only when all its sources share one quantization.
        parts[-1] = fused[parts[-1]][0]
    elif len(parts) > 1 and parts[-2] in fused and parts[-1] in fused[parts[-2]]:
        del parts[-2]  # one part of a split fusion
    return (".".join(parts),)


def patch_glm5_next():
    """Install the glm5_next loader shim (module docstring); returns a log list
    that the patched sanitize fills with the fusions it split."""
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_vlm.models.glm5_next import glm5_next, language

    split_log = []

    class SplitLinear(nn.Module):
        def __init__(self, in_dims, parts):
            super().__init__()
            self.part_names = ",".join(name for name, _, _ in parts)  # a str stays out of the parameters
            for name, out_dims, bias in parts:
                setattr(self, name, nn.Linear(in_dims, out_dims, bias=bias))

        def __call__(self, x):
            return mx.concatenate([language.linear(getattr(self, n), x) for n in self.part_names.split(",")],
                                  axis=-1)

    stock_sanitize = language.LanguageModel.sanitize

    def sanitize(self, weights):
        shapes = {k: tuple(v.shape) for k, v in weights.items()}
        for i, owner_path, fused, sources in glm5_mixed_fusions(shapes, len(self.layers)):
            owner = self.layers[i]
            for attr in owner_path.split("."):
                owner = getattr(owner, attr)
            base = f"language_model.model.layers.{i}.{owner_path}"
            parts = []
            for s in sources:
                for suffix in ("weight", "scales", "biases", "bias"):
                    if f"{base}.{s}.{suffix}" in weights:
                        weights[f"{base}.{fused}.{s}.{suffix}"] = weights.pop(f"{base}.{s}.{suffix}")
                parts.append((s, shapes[f"{base}.{s}.weight"][0], f"{base}.{s}.bias" in shapes))
            setattr(owner, fused, SplitLinear(getattr(owner, fused).weight.shape[-1], parts))
            split_log.append(f"layer {i} {owner_path}.{fused}: " + ", ".join(
                f"{s} {shapes[f'{base}.{s}.weight']}" for s in sources))
        return stock_sanitize(self, weights)

    language.LanguageModel.sanitize = sanitize
    glm5_next.Model.quantization_path_aliases = staticmethod(glm5_quant_aliases)
    return split_log


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

    with open(os.path.join(args.model_path, "config.json")) as f:
        model_type = json.load(f).get("model_type")
    split_log = patch_glm5_next() if model_type == "glm5_next" else None
    t = time.perf_counter()
    model, processor = load(args.model_path)
    load_s = round(time.perf_counter() - t, 2)
    for line in split_log or ():
        print(f"glm5_next shim: split {line}", file=sys.stderr)
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
            "loader_shims": None if split_log is None else {"glm5_next": {"split_fusions": split_log}},
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
