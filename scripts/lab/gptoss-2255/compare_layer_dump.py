"""Find the first gpt-oss tensor where native and mlx-lm diverge (#2255).

Reads a native dump (`native_f*_*.npy`, written by the fork's
`MLX_LM_GPTOSS_LAYER_DUMP`) and an mlx-lm dump (`mlxlm_f*_*.npy`, written by
mlxlm_layer_dump.py). For each forward it compares, in forward order,
embed, layer00_attn, layer00 .. layerNN and final_norm, and prints the max
and mean absolute difference. It names the first tensor whose max diff is
above --tolerance (default 0: the first inexact tensor).

Usage: python -I compare_layer_dump.py <native_dir> <mlxlm_dir> [--tolerance 0] [--json out.json]
Needs numpy only.
"""

import argparse
import json
import re
from pathlib import Path

import numpy as np


def order(name):
    if name == "embed":
        return (0, 0)
    if name == "layer00_attn":
        return (1, 0)
    m = re.fullmatch(r"layer(\d+)", name)
    if m:
        return (2, int(m.group(1)))
    return (3, 0)  # final_norm


def tensors(directory, prefix):
    found = {}
    for path in Path(directory).glob(f"{prefix}_f*_*.npy"):
        m = re.fullmatch(rf"{prefix}_f(\d+)_(.+)\.npy", path.name)
        if m:
            found[(int(m.group(1)), m.group(2))] = path
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("native_dir")
    ap.add_argument("mlxlm_dir")
    ap.add_argument("--tolerance", type=float, default=0.0)
    ap.add_argument("--json", help="also write the rows as JSON")
    args = ap.parse_args()

    native = tensors(args.native_dir, "native")
    ref = tensors(args.mlxlm_dir, "mlxlm")
    keys = sorted(set(native) & set(ref), key=lambda k: (k[0], order(k[1])))
    if not keys:
        raise SystemExit("no tensors in common; check the directories and --forwards on both sides")
    only = sorted(set(native) ^ set(ref))
    rows, first = [], None
    for forward, name in keys:
        a, b = np.load(native[(forward, name)]), np.load(ref[(forward, name)])
        row = {"forward": forward, "name": name, "shape": list(a.shape)}
        if a.shape != b.shape:
            row.update(max_abs=None, mean_abs=None, note=f"shape {a.shape} vs {b.shape}")
        else:
            d = np.abs(a.astype(np.float64) - b.astype(np.float64))
            row.update(max_abs=float(d.max()), mean_abs=float(d.mean()), argmax=list(np.unravel_index(d.argmax(), d.shape)))
        rows.append(row)
        if first is None and (row["max_abs"] is None or row["max_abs"] > args.tolerance):
            first = row
    for r in rows:
        diff = r.get("note") or f"max {r['max_abs']:.6g}  mean {r['mean_abs']:.6g}"
        print(f"f{r['forward']} {r['name']:<14} {diff}")
    if only:
        print("only on one side:", ", ".join(f"f{f}_{n}" for f, n in only))
    print("first divergence:", f"f{first['forward']} {first['name']}" if first else f"none above {args.tolerance}")
    if args.json:
        Path(args.json).write_text(json.dumps({"tolerance": args.tolerance, "first": first, "rows": rows}, indent=2, default=int))


if __name__ == "__main__":
    main()
