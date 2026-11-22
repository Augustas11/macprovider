#!/usr/bin/env python3
"""#2451 tile microbench: GLM-5.3-Flash prefill shapes, the bench plan and the verdict.

usage: tiles.py shapes --model-dir DIR [--out FILE]
       tiles.py plan [--shapes FILE] [--rows 2048,4096] [--routings uniform,skewed] [--samples 8]
                     [--target-ms 25] [--seed 2451] [--families dense,gather] --out FILE
       tiles.py verdict --bench FILE [--threshold-pct 3] --out-md FILE --out-json FILE

Question: does a different non-NAX tile for MLX's quantized matmuls speed up GLM-5.3-Flash prefill
on the M3 Ultra without changing a bit of output? Two candidates from the issue's profile:
  c3  the routed-expert tile: gather_qmm_rhs (transposed), stock bm16/bn32/bk32/wm1/wn2
      (mlx quantized.cpp gather_qmm_rhs, "TODO: Tune the block sizes");
  c5  the dense projection tile: affine_qmm_t, stock BM32/BK32/BN32 with WM = WN = 2 (quantized.cpp
      qmm; quantized.h qmm_t_impl), oMLX-style 64x64 and neighbours.
The fork branch macprovider/2451-tile-variants selects a tile per call from MLX_LAB_2451_QMM_TILE
("bm,bk,bn") and MLX_LAB_2451_GQMM_RHS_TILE ("bm,bn,bk,wm,wn"); unset is the stock tile.

Shapes (`shapes`): every affine quantized linear of the checkpoint's text layers 0 ..
num_hidden_layers-1 (the MTP layer, embed_tokens and lm_head are left out: lm_head runs only on the
last row of a prompt, and the MTP head is not prefill), read from the safetensors headers, never the
tensors. kv_b_proj is left out: GLM5Next runs it as embed_q/unembed_out MultiLinear (batched)
matmuls, not as a [rows, 512] projection. Routed experts are one gather_qmm_rhs call per projection
per sparse layer. EMBEDDED_* below is that scan of snapshot 242f8fcf (Studio, 2026-11-22); the job
derives the table again from the served snapshot and uses the derived one.

Plan (`plan`): one cell per (family, rows, routing, N, K, bits), `count` = calls per prompt chunk
(layer count). Dense cells take x [1, rows, K]. Gather cells take rows * 8 index rows sorted by
expert, as SwitchGLU feeds gather_qmm after gatherSort: `expert_counts` (rows per expert, sum rows*8)
come from top-8 routing over 288 experts, `uniform` (each token picks 8 distinct experts uniformly)
or `skewed` (expert e drawn with weight 1/(e+1)^0.5, a stand-in for an unbalanced router; real router
loads are not measured here). Each cell lists its tiles: the stock control first, then the
candidates; the bench runs them in the order control, t1, control, t2, ..., control, so every
candidate block sits between two control blocks (AGENTS.md swarm rule 3), each block `samples`
timed samples of `iters` back-to-back calls (iters chosen by the bench for about `target_ms` per
sample). PAD lines give the share of gather tile rows that are padding per tile height.

Verdict (`verdict`): per family, configuration (rows, routing) and candidate tile, the count-weighted
sum over cells of the median per-call time, against each neighbouring control's sum: gain_vs_a,
gain_vs_b, gain = min of the two (positive only when it beats both). A tile's gain is its minimum over
configurations; the candidate's tile is the one with the largest gain. bits=identical when every cell
of that tile matched the control output bit for bit (bf16 viewed as uint16), else differ.
Lines: `T2451_TILES c3|c5 gain=<+x.xx%> bits=<identical|differ>` then `T2451_TILE_BEST`,
`T2451_TILE_CONFIG`, `T2451_CONTROL_DRIFT` detail lines and `T2451_PHASE2 run|skip QMM_TILE=..
GQMM_RHS_TILE=..` (run when a candidate's gain >= threshold; its env assignments are the serve env).
Exit 0 on a complete verdict, 2 on bad input.
"""
import argparse
import glob
import json
import os
import random
import re
import statistics
import struct
import sys

EXPERTS = 288
TOP_K = 8
GROUP = 64

# (name, N, K, bits, calls per prompt chunk), layers 0..44 of snapshot 242f8fcf, kv_b_proj excluded.
EMBEDDED_DENSE = [
    ("mlp.down_proj", 4096, 12288, 8, 3),
    ("mlp.gate_proj", 12288, 4096, 8, 3),
    ("mlp.shared_experts.down_proj", 4096, 2048, 8, 42),
    ("mlp.shared_experts.gate_proj", 2048, 4096, 8, 42),
    ("mlp.shared_experts.up_proj", 2048, 4096, 8, 42),
    ("mlp.up_proj", 12288, 4096, 8, 3),
    ("self_attn.b_proj", 64, 4096, 6, 11),
    ("self_attn.b_proj", 64, 4096, 8, 23),
    ("self_attn.f_a_proj", 128, 4096, 6, 11),
    ("self_attn.f_a_proj", 128, 4096, 8, 23),
    ("self_attn.f_b_proj", 8192, 128, 6, 11),
    ("self_attn.f_b_proj", 8192, 128, 8, 23),
    ("self_attn.g_a_proj", 128, 4096, 6, 11),
    ("self_attn.g_a_proj", 128, 4096, 8, 23),
    ("self_attn.g_b_proj", 8192, 128, 6, 11),
    ("self_attn.g_b_proj", 8192, 128, 8, 23),
    ("self_attn.indexer.weights_proj", 32, 4096, 8, 11),
    ("self_attn.indexer.wk", 128, 4096, 8, 11),
    ("self_attn.indexer.wq_b", 4096, 1536, 8, 11),
    ("self_attn.k_proj", 8192, 4096, 6, 11),
    ("self_attn.k_proj", 8192, 4096, 8, 23),
    ("self_attn.kv_a_proj_with_mqa", 512, 4096, 8, 11),
    ("self_attn.o_proj", 4096, 8192, 6, 12),
    ("self_attn.o_proj", 4096, 8192, 8, 22),
    ("self_attn.o_proj", 4096, 16384, 6, 4),
    ("self_attn.o_proj", 4096, 16384, 8, 7),
    ("self_attn.q_a_proj", 1536, 4096, 8, 11),
    ("self_attn.q_b_proj", 16384, 1536, 8, 11),
    ("self_attn.q_proj", 8192, 4096, 6, 12),
    ("self_attn.q_proj", 8192, 4096, 8, 22),
    ("self_attn.v_proj", 8192, 4096, 6, 12),
    ("self_attn.v_proj", 8192, 4096, 8, 22),
]
# (name, N, K, bits, calls per prompt chunk): one gather_qmm_rhs per projection per sparse layer.
EMBEDDED_GATHER = [
    ("mlp.experts.down_proj", 4096, 2048, 4, 42),
    ("mlp.experts.gate_proj", 2048, 4096, 4, 42),
    ("mlp.experts.up_proj", 2048, 4096, 4, 42),
]

DENSE_ENV = "MLX_LAB_2451_QMM_TILE"
GATHER_ENV = "MLX_LAB_2451_GQMM_RHS_TILE"
# Stock tile first. Must match the fork's allow-lists (quantized.cpp lab_2451_*_tile) and
# instantiations (quantized.metal instantiate_lab_2451_*).
DENSE_TILES = ["32,32,32", "64,32,64", "64,64,64", "32,32,64", "64,32,32", "32,64,32"]  # bm,bk,bn
GATHER_TILES = ["16,32,32,1,2", "8,32,32,1,2", "16,64,32,1,2", "16,32,64,1,2", "32,32,32,2,2",
                "32,64,32,2,2", "64,64,32,2,2"]  # bm,bn,bk,wm,wn
FAMILY = {"dense": ("c5", DENSE_ENV, DENSE_TILES), "gather": ("c3", GATHER_ENV, GATHER_TILES)}
ROUTINGS = ("uniform", "skewed")


# ---- shapes ----

def read_header(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        if n <= 0 or n > 1 << 30:
            raise ValueError(f"{path}: bad safetensors header length {n}")
        h = json.loads(f.read(n))
    h.pop("__metadata__", None)
    return h


def scan_shapes(model_dir):
    """(dense, gather) tables from the checkpoint headers, as EMBEDDED_DENSE / EMBEDDED_GATHER."""
    cfg = json.load(open(os.path.join(model_dir, "config.json")))
    text = cfg.get("text_config", cfg)
    layers = int(text["num_hidden_layers"])
    experts = int(text["n_routed_experts"])
    if experts != EXPERTS or int(text["num_experts_per_tok"]) != TOP_K:
        raise ValueError(f"experts {experts} top-k {text['num_experts_per_tok']}, not {EXPERTS}/{TOP_K}")
    hdr = {}
    files = sorted(glob.glob(os.path.join(model_dir, "*.safetensors")))
    if not files:
        raise ValueError(f"no safetensors in {model_dir}")
    for f in files:
        hdr.update(read_header(f))
    dense, gather = {}, {}
    for key, meta in hdr.items():
        if not key.endswith(".scales"):
            continue
        base = key[: -len(".scales")]
        w = hdr.get(base + ".weight")
        m = re.search(r"\.layers\.(\d+)\.", base)
        if not w or w["dtype"] != "U32" or not m or int(m.group(1)) >= layers:
            continue
        name = re.sub(r"^.*\.layers\.\d+\.", "", base)
        if name.endswith("kv_b_proj"):
            continue
        k = meta["shape"][-1] * GROUP
        bits = w["shape"][-1] * 32 // k
        n = w["shape"][-2]
        if ".experts." in name:
            name = re.sub(r"experts\.\d+", "experts", name)
            gather[(name, n, k, bits)] = gather.get((name, n, k, bits), 0) + 1
        else:
            dense[(name, n, k, bits)] = dense.get((name, n, k, bits), 0) + 1
    dense_t = sorted((*key, c) for key, c in dense.items())
    gather_t = []
    for key, c in sorted(gather.items()):
        if c % EXPERTS:
            raise ValueError(f"{key}: {c} expert tensors is not a multiple of {EXPERTS}")
        gather_t.append((*key, c // EXPERTS))
    return dense_t, gather_t


def merged(table):
    """Sum the counts of entries with one (N, K, bits): they are the same matmul."""
    out = {}
    for name, n, k, bits, count in table:
        e = out.setdefault((n, k, bits), {"names": [], "count": 0})
        e["names"].append(name)
        e["count"] += count
    return [{"n": n, "k": k, "bits": b, "count": e["count"], "name": "+".join(sorted(set(e["names"])))}
            for (n, k, b), e in sorted(out.items())]


# ---- routing ----

def expert_counts(rows, routing, seed):
    """Index rows per expert for `rows` tokens each routed to TOP_K distinct experts."""
    rng = random.Random(f"{seed}:{routing}:{rows}")
    counts = [0] * EXPERTS
    if routing == "uniform":
        for _ in range(rows):
            for e in rng.sample(range(EXPERTS), TOP_K):
                counts[e] += 1
    elif routing == "skewed":
        order = list(range(EXPERTS))
        rng.shuffle(order)
        weights = [1.0 / (r + 1) ** 0.5 for r in range(EXPERTS)]
        for _ in range(rows):
            picked = set()
            while len(picked) < TOP_K:
                picked.add(order[rng.choices(range(EXPERTS), weights)[0]])
            for e in picked:
                counts[e] += 1
    else:
        raise ValueError(f"routing {routing!r}")
    return counts


def padding(counts, bm):
    """(padded tile rows, share of tile rows that are padding) for row tiles of height bm per expert."""
    tiles = sum((c + bm - 1) // bm for c in counts)
    real = sum(counts)
    return tiles, (tiles * bm - real) / (tiles * bm) if tiles else 0.0


def build_plan(dense, gather, rows_list, routings, samples, target_ms, seed, families):
    cells = []
    for rows in rows_list:
        if "dense" in families:
            for c in merged(dense):
                cells.append({"family": "dense", "rows": rows, "routing": None, "env": DENSE_ENV,
                              "tiles": DENSE_TILES, **c})
        if "gather" in families:
            for routing in routings:
                counts = expert_counts(rows, routing, seed)
                for c in merged(gather):
                    cells.append({"family": "gather", "rows": rows, "routing": routing, "env": GATHER_ENV,
                                  "tiles": GATHER_TILES, "experts": EXPERTS, "top_k": TOP_K,
                                  "expert_counts": counts, **c})
    for i, c in enumerate(cells):
        c["id"] = f"{i:03d}-{c['family']}-r{c['rows']}" + (f"-{c['routing']}" if c["routing"] else "") \
            + f"-n{c['n']}-k{c['k']}-b{c['bits']}"
    return {"seed": seed, "samples": samples, "target_ms": target_ms, "group_size": GROUP, "cells": cells}


# ---- verdict ----

def config_key(cell):
    return f"rows{cell['rows']}" + (f"-{cell['routing']}" if cell.get("routing") else "")


def evaluate(bench, threshold_pct):
    """{candidate: {...}} from a bench.json (see the module docstring)."""
    out = {}
    cells = bench.get("cells") or []
    if not cells:
        raise ValueError("no cells in the bench output")
    for family, (cand, env, tiles) in FAMILY.items():
        fam = [c for c in cells if c["family"] == family]
        if not fam:
            continue
        configs = {}
        for c in fam:
            blocks = c["blocks"]
            want = [tiles[0]]
            for t in tiles[1:]:
                want += [t, tiles[0]]
            got = [b["tile"] for b in blocks]
            if got != want:
                raise ValueError(f"{c['id']}: block order {got} is not control-candidate-control {want}")
            meds = [statistics.median(b["samples_ms"]) for b in blocks]
            if len(blocks[0]["samples_ms"]) < 6 or any(len(b["samples_ms"]) != len(blocks[0]["samples_ms"]) for b in blocks):
                raise ValueError(f"{c['id']}: fewer than 6 samples or uneven blocks")
            cfg = configs.setdefault(config_key(c), {})
            w = c["count"]
            for i, t in enumerate(tiles[1:]):
                s = cfg.setdefault(t, {"a": 0.0, "v": 0.0, "b": 0.0, "identical": True, "cells": 0, "elems_diff": 0})
                s["a"] += w * meds[2 * i]
                s["v"] += w * meds[2 * i + 1]
                s["b"] += w * meds[2 * i + 2]
                bits = c["bits_vs_control"][t]
                s["identical"] = s["identical"] and bits["elems_diff"] == 0
                s["elems_diff"] += bits["elems_diff"]
                s["cells"] += 1
            drift = cfg.setdefault("_drift", [])
            drift.append(max(meds[0::2]) / min(meds[0::2]) - 1 if min(meds[0::2]) > 0 else 0.0)
        per_tile = {}
        for key, cfg in configs.items():
            for t, s in cfg.items():
                if t == "_drift":
                    continue
                ga, gb = 1 - s["v"] / s["a"], 1 - s["v"] / s["b"]
                e = per_tile.setdefault(t, {"tile": t, "configs": {}, "identical": True, "elems_diff": 0})
                e["configs"][key] = {"gain_vs_a": ga, "gain_vs_b": gb, "gain": min(ga, gb),
                                     "control_a_ms": s["a"], "candidate_ms": s["v"], "control_b_ms": s["b"]}
                e["identical"] = e["identical"] and s["identical"]
                e["elems_diff"] += s["elems_diff"]
        for e in per_tile.values():
            e["gain"] = min(c["gain"] for c in e["configs"].values())
        best = max(per_tile.values(), key=lambda e: e["gain"])
        out[cand] = {"family": family, "env": env, "best": best, "tiles": per_tile,
                     "control_drift_max": {k: max(v["_drift"]) for k, v in configs.items()},
                     "phase2": best["gain"] * 100 >= threshold_pct}
    if not out:
        raise ValueError("no dense or gather cells")
    return out


def verdict_lines(result, threshold_pct):
    lines, env = [], []
    for cand in ("c3", "c5"):
        r = result.get(cand)
        if not r:
            lines.append(f"T2451_TILES {cand} gain=n/a bits=n/a (family not measured)")
            continue
        b = r["best"]
        lines.append(f"T2451_TILES {cand} gain={b['gain'] * 100:+.2f}% bits={'identical' if b['identical'] else 'differ'}")
    for cand in ("c3", "c5"):
        r = result.get(cand)
        if not r:
            continue
        b = r["best"]
        lines.append(f"T2451_TILE_BEST {cand} {r['env']}={b['tile']} gain={b['gain'] * 100:+.2f}% "
                     f"elems_diff={b['elems_diff']}")
        for t, e in sorted(r["tiles"].items(), key=lambda kv: -kv[1]["gain"]):
            for key, c in sorted(e["configs"].items()):
                lines.append(f"T2451_TILE_CONFIG {cand} tile={t} config={key} gain_vs_a={c['gain_vs_a'] * 100:+.2f}% "
                             f"gain_vs_b={c['gain_vs_b'] * 100:+.2f}% bits={'identical' if e['identical'] else 'differ'}")
        for key, d in sorted(r["control_drift_max"].items()):
            lines.append(f"T2451_CONTROL_DRIFT {cand} config={key} max_cell_drift={d * 100:.2f}%"
                         + (" NOISY" if d > 0.03 else ""))
        if r["phase2"]:
            env.append(f"{r['env']}={b['tile']}")
    lines.append(f"T2451_PHASE2 {'run' if env else 'skip'} threshold={threshold_pct:g}% " + (" ".join(env) or "-"))
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("shapes")
    s.add_argument("--model-dir", required=True)
    s.add_argument("--out")
    p = sub.add_parser("plan")
    p.add_argument("--shapes")
    p.add_argument("--rows", default="2048,4096")
    p.add_argument("--routings", default="uniform,skewed")
    p.add_argument("--samples", type=int, default=8)
    p.add_argument("--target-ms", type=float, default=25.0)
    p.add_argument("--seed", type=int, default=2451)
    p.add_argument("--families", default="dense,gather")
    p.add_argument("--out", required=True)
    v = sub.add_parser("verdict")
    v.add_argument("--bench", required=True)
    v.add_argument("--threshold-pct", type=float, default=3.0)
    v.add_argument("--out-md", required=True)
    v.add_argument("--out-json", required=True)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "shapes":
            dense, gather = scan_shapes(args.model_dir)
            same = sorted(map(tuple, dense)) == sorted(EMBEDDED_DENSE) and sorted(map(tuple, gather)) == sorted(EMBEDDED_GATHER)
            doc = {"dense": dense, "gather": gather, "matches_embedded": same}
            text = json.dumps(doc, indent=1)
            if args.out:
                open(args.out, "w").write(text + "\n")
            print(f"SHAPES {'OK matches the embedded table' if same else 'DRIFT differs from the embedded table'} "
                  f"dense={len(dense)} gather={len(gather)}")
            return 0
        if args.cmd == "plan":
            rows_list = [int(r) for r in args.rows.split(",")]
            routings = args.routings.split(",")
            families = set(args.families.split(","))
            if any(r < 64 or r > 16384 for r in rows_list) or not set(routings) <= set(ROUTINGS) \
                    or not families <= set(FAMILY) or not families or args.samples < 6 or args.target_ms <= 0:
                print("plan: rows 64..16384, routings uniform|skewed, families dense|gather, samples >= 6",
                      file=sys.stderr)
                return 2
            if args.shapes:
                doc = json.load(open(args.shapes))
                dense, gather = [tuple(x) for x in doc["dense"]], [tuple(x) for x in doc["gather"]]
            else:
                dense, gather = EMBEDDED_DENSE, EMBEDDED_GATHER
            plan = build_plan(dense, gather, rows_list, routings, args.samples, args.target_ms, args.seed, families)
            open(args.out, "w").write(json.dumps(plan) + "\n")
            nd = sum(1 for c in plan["cells"] if c["family"] == "dense")
            ng = len(plan["cells"]) - nd
            print(f"PLAN cells={len(plan['cells'])} dense={nd} gather={ng} rows={args.rows} "
                  f"routings={args.routings} samples={args.samples} target_ms={args.target_ms:g}")
            if "gather" in families:
                for rows in rows_list:
                    for routing in routings:
                        counts = expert_counts(rows, routing, args.seed)
                        pads = " ".join(f"bm{bm}={padding(counts, bm)[1] * 100:.1f}%" for bm in (8, 16, 32, 64))
                        print(f"PAD rows={rows} routing={routing} rows_per_expert_mean={rows * TOP_K / EXPERTS:.1f} "
                              f"min={min(counts)} max={max(counts)} padding {pads}")
            return 0
        bench = json.load(open(args.bench))
        result = evaluate(bench, args.threshold_pct)
        lines = verdict_lines(result, args.threshold_pct)
        open(args.out_json, "w").write(json.dumps(result, indent=1, sort_keys=True) + "\n")
        md = ["# #2451 tile microbench verdict", "",
              f"Bench: {bench.get('device', '?')}, mlx core {bench.get('core', '?')}, plan seed {bench.get('seed', '?')}.",
              "", "```"] + lines + ["```", ""]
        open(args.out_md, "w").write("\n".join(md))
        print("\n".join(lines))
        return 0
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as e:
        print(f"tiles.py {args.cmd}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
