#!/usr/bin/env python3
"""Is `mx.gather_qmm` on the sorted-indices route row-invariant to tile composition? (#2451)

usage: glm_gather_qmm_bitwise.py pin --pins-dir DIR --resolved Package.resolved
       glm_gather_qmm_bitwise.py plan [--seed 2451] [--targets 32]
       glm_gather_qmm_bitwise.py run --expect-mlx VERSION --out-json FILE [--seed 2451] [--targets 32]

Question (scratchpad glm-ttft-research.md, candidate 1 condition (b), "Not verified" item 4):
a wide row-local prefill keeps each row's arithmetic only if `gather_qmm_rhs` gives a row the
same bits whether the 16-row tile it sits in holds rows of one expert or of several. At 512
prompt rows GLM-5.3-Flash routes 512*8/288 = 14 rows per expert (below one tile, so most
tiles straddle experts); at 4096 rows it is 114.

Test: the routed-expert MLP of SwitchGLU as mlx-lm / MLXLMCommon run it at prefill (indices
>= 64: sort, gather_qmm up and gate with sorted_indices, SiLU(gate) * up, gather_qmm down,
unsort), at GLM-5.3-Flash expert shapes: 288 experts, top-8, hidden 4096, expert
intermediate 2048 (GLM5Next.swift SwitchGLU(hiddenSize, moeIntermediateSize, nRoutedExperts);
the 11-18 prefill scout: "d 4096, inter 2048"), affine 4-bit, group 64, bf16 activations,
random weights from a fixed seed. TARGETS target tokens keep the same input row and the same
eight experts in every case; their neighbours change: 512, 2048 or 4096 rows with uniformly
routed neighbours, neighbours routed only to the targets' experts (full, uniform tiles) or
never to them (each target expert's segment holds only target rows, so every tile is mixed),
the targets placed first, in the middle or last (their offset inside each expert segment moves:
in the middle of a crowded segment their tiles hold one expert only), and the
targets alone (a different kernel route: the tail-route question). Every case's target rows
(up, gate and down outputs, viewed as uint16) are compared bit for bit with the reference
case (512 rows, uniform neighbours), which is also run twice to show the route is
deterministic. The SwiGLU limit and the score-weighted sum are row-local elementwise work
and are left out.

MLX version: the provider's MLX core is the fork tag SPEC048_MLX_CORE_TAG of
scripts/read_swiftpm_pins.py (v0.32.4-macprovider.15), pinned through the mlx-swift revision
in Package.resolved; `pin` checks that pin and prints the upstream release it is based on
(0.32.4), whose wheel the job installs. The fork's 23 commits over upstream v0.32.4 (GitHub
compare 36969c09...4e9a71dc) change QuantizedMatmul, QQMatmul, dispatch_qmv and qmm_splitk and
only add kernels to quantized.h; GatherQMM::eval_gpu and the gather kernels are unchanged, so
the wheel runs the provider's gather_qmm code.

Output: per case and stage one `BITWISE_EQUAL ...` or `BITWISE_DIFF ... rows_diff=a/b
elems_diff=c/n max_ulp=u` line, then `GQMM_VERDICT route=gather_qmm_rhs invariant` (every case on the reference's kernel
route equal) or `... varies cases=[...]`, plus `other_route_differs=[...]` for the cases on
another route (targets alone), which never decide the verdict. `plan` prints the cases without MLX. Exit 0 when the run
completed (a difference is the finding, not an error), 1 on a non-deterministic reference,
2 on bad input or a wrong MLX version.
"""
import argparse
import json
import random
import re
import sys
from pathlib import Path

EXPERTS = 288
TOP_K = 8
HIDDEN = 4096
INTERMEDIATE = 2048
BITS = 4
GROUP = 64
TILE_ROWS = 16  # gather_qmm_rhs tile bm on non-NAX (research: 16x32x32)
SORT_MIN_INDICES = 64  # SwitchGLU sorts when indices.size >= 64
STAGES = ("up", "gate", "down")


def core_wheel_version(tag):
    """'v0.32.4-macprovider.15' -> '0.32.4' (the upstream MLX release the fork tag is based on)."""
    m = re.fullmatch(r"v?(\d+\.\d+\.\d+)(?:-macprovider\.\d+)?", tag or "")
    if not m:
        raise ValueError(f"not an MLX core tag: {tag!r}")
    return m.group(1)


def pinned_core(pins, resolved):
    """(core tag, wheel version, core revision) for the mlx-swift revision Package.resolved pins."""
    got = pins.read_production_pins(Path(resolved))
    if got.get("mlx_swift") != pins.SPEC048_MLX_SWIFT_REVISION:
        raise ValueError(f"Package.resolved pins mlx-swift {got.get('mlx_swift')}, not the reviewed "
                         f"{pins.SPEC048_MLX_SWIFT_REVISION} whose core gitlink is {pins.SPEC048_MLX_CORE_TAG}")
    return pins.SPEC048_MLX_CORE_TAG, core_wheel_version(pins.SPEC048_MLX_CORE_TAG), pins.SPEC048_MLX_CORE_REVISION


def predicted_route(index_rows, experts=EXPERTS):
    """The gather_qmm kernel MLX picks for x with M == 1 (quantized.cpp: `M == 1 && B >= 16 &&
    sorted && B/E >= 4` -> gather_qmm_rhs), B = index rows."""
    if index_rows < SORT_MIN_INDICES:
        return "unsorted"
    return "gather_qmm_rhs" if index_rows >= 16 and index_rows / experts >= 4 else "gather_qmv/qmm"


def _distinct(rng, pool, k):
    return rng.sample(pool, k)


def build_case(name, rows, mode, placement, targets, seed):
    """{name, rows, mode, placement, indices [rows][K], target_pos [targets], neighbour_rows}.

    Target tokens t get the same experts in every case (from `seed`); neighbours use
    `seed` + the case name. mode: uniform | crowd (only the targets' experts) | avoid (never
    them) | alone (no neighbours)."""
    trng = random.Random(seed)
    target_idx = [_distinct(trng, list(range(EXPERTS)), TOP_K) for _ in range(targets)]
    used = sorted({e for row in target_idx for e in row})
    pool = {"uniform": list(range(EXPERTS)), "crowd": used,
            "avoid": [e for e in range(EXPERTS) if e not in set(used)], "alone": []}[mode]
    if mode == "alone":
        rows = targets
    if rows < targets or (mode != "alone" and len(pool) < TOP_K):
        raise ValueError(f"case {name}: {rows} rows cannot hold {targets} targets in mode {mode}")
    nrng = random.Random(f"{seed}:{name}")
    n = rows - targets
    neighbours = [_distinct(nrng, pool, TOP_K) for _ in range(n)]
    start = {"first": 0, "middle": (rows - targets) // 2, "last": rows - targets}[placement]
    pos = list(range(start, start + targets))
    indices, ti, ni, at = [], 0, 0, set(pos)
    for r in range(rows):
        if r in at:
            indices.append(target_idx[ti]); ti += 1
        else:
            indices.append(neighbours[ni]); ni += 1
    return {"name": name, "rows": rows, "mode": mode, "placement": placement, "indices": indices,
            "target_pos": pos, "neighbour_rows": n}


def tile_stats(case):
    """Target index rows per target expert and the share of target index rows in a mixed
    16-row tile, for a stable sort by expert (MLX's argsort order inside a segment may differ,
    so this is the expected composition, not a measured one)."""
    flat = [(e, r, k) for r, row in enumerate(case["indices"]) for k, e in enumerate(row)]
    flat.sort(key=lambda t: t[0])
    targets = set(case["target_pos"])
    target_experts = {e for r in targets for e in case["indices"][r]}
    per_expert = {}
    for e, _, _ in flat:
        per_expert[e] = per_expert.get(e, 0) + 1
    mixed = total = 0
    for start in range(0, len(flat), TILE_ROWS):
        tile = flat[start:start + TILE_ROWS]
        n = sum(1 for _, r, _ in tile if r in targets)
        total += n
        if len({e for e, _, _ in tile}) > 1:
            mixed += n
    mean = sum(per_expert[e] for e in target_experts) / len(target_experts)
    return {"index_rows": len(flat), "route": predicted_route(len(flat)),
            "rows_per_target_expert": round(mean, 1), "target_rows_in_mixed_tiles": f"{mixed}/{total}"}


def default_cases(seed, targets):
    spec = [("ref-512-uniform", 512, "uniform", "first"), ("512-uniform-last", 512, "uniform", "last"),
            ("2048-uniform", 2048, "uniform", "first"), ("2048-uniform-last", 2048, "uniform", "last"),
            ("2048-crowd", 2048, "crowd", "first"), ("2048-avoid", 2048, "avoid", "first"),
            ("2048-crowd-middle", 2048, "crowd", "middle"),
            ("4096-uniform", 4096, "uniform", "first"), ("4096-uniform-middle", 4096, "uniform", "middle"),
            ("4096-crowd", 4096, "crowd", "first"), ("4096-crowd-middle", 4096, "crowd", "middle"),
            ("512-avoid", 512, "avoid", "first"), ("targets-alone", targets, "alone", "first")]
    return [build_case(n, r, m, p, targets, seed) for n, r, m, p in spec]


def _ordered(b):
    """bf16 bit pattern -> an integer that orders like the value (for a ULP distance)."""
    return b ^ 0x8000 if b < 0x8000 else 0xFFFF - b


def compare_rows(ref, got):
    """(rows_diff, rows, elems_diff, elems, max_ulp) over equal-shaped [row][elem] uint16 lists."""
    if len(ref) != len(got):
        raise ValueError("row count differs")
    rows_diff = elems_diff = elems = max_ulp = 0
    for a, b in zip(ref, got):
        if len(a) != len(b):
            raise ValueError("row length differs")
        elems += len(a)
        d = [abs(_ordered(x) - _ordered(y)) for x, y in zip(a, b) if x != y]
        if d:
            rows_diff += 1
            elems_diff += len(d)
            max_ulp = max(max_ulp, max(d))
    return rows_diff, len(ref), elems_diff, elems, max_ulp


def verdict_line(name, stage, cmp, stats):
    rows_diff, rows, elems_diff, elems, max_ulp = cmp
    info = (f"route={stats['route']} index_rows={stats['index_rows']} rows_per_target_expert="
            f"{stats['rows_per_target_expert']} target_rows_in_mixed_tiles={stats['target_rows_in_mixed_tiles']}")
    if elems_diff == 0:
        return f"BITWISE_EQUAL case={name} stage={stage} rows={rows} elems={elems} {info}"
    return (f"BITWISE_DIFF case={name} stage={stage} rows_diff={rows_diff}/{rows} elems_diff={elems_diff}/{elems} "
            f"max_ulp={max_ulp} {info}")


# ---- MLX part (lab Mac only) ----

def run_mlx(cases, seed, targets):  # pragma: no cover - needs MLX on Apple silicon
    import mlx.core as mx

    def projection(out_dim, in_dim, key):
        parts = []
        for k in mx.random.split(key, EXPERTS // 32):
            w = (mx.random.normal((32, out_dim, in_dim), key=k) * 0.02).astype(mx.bfloat16)
            q = mx.quantize(w, group_size=GROUP, bits=BITS)
            mx.eval(*q)
            parts.append(q)
            del w
        return tuple(mx.concatenate([p[i] for p in parts], axis=0) for i in range(3))

    keys = mx.random.split(mx.random.key(seed), 5)
    weights = {"up": projection(INTERMEDIATE, HIDDEN, keys[0]), "gate": projection(INTERMEDIATE, HIDDEN, keys[1]),
               "down": projection(HIDDEN, INTERMEDIATE, keys[2])}
    mx.eval(*[a for w in weights.values() for a in w])
    x_targets = mx.random.normal((targets, HIDDEN), key=keys[3]).astype(mx.bfloat16)
    max_rows = max(c["rows"] for c in cases)
    x_neigh = mx.random.normal((max_rows, HIDDEN), key=keys[4]).astype(mx.bfloat16)

    def gqmm(x, stage, idx):
        wq, scales, biases = weights[stage]
        return mx.gather_qmm(x, wq, scales, biases, rhs_indices=idx, transpose=True,
                             group_size=GROUP, bits=BITS, sorted_indices=True)

    def forward(case):
        rows, pos = case["rows"], case["target_pos"]
        order_rows, ti, ni, at = [], 0, 0, set(pos)
        for r in range(rows):
            if r in at:
                order_rows.append(("t", ti)); ti += 1
            else:
                order_rows.append(("n", ni)); ni += 1
        x = mx.stack([x_targets[i] if kind == "t" else x_neigh[i] for kind, i in order_rows])
        indices = mx.array(case["indices"], dtype=mx.uint32)
        # mlx-lm SwitchGLU with indices.size >= 64 (_gather_sort / _scatter_unsort).
        xe = mx.expand_dims(x, (-2, -3))
        flat = indices.flatten()
        order = mx.argsort(flat)
        inv = mx.argsort(order)
        xs = xe.flatten(0, -3)[order // TOP_K]
        si = flat[order]
        up = gqmm(xs, "up", si)
        gate = gqmm(xs, "gate", si)
        h = (gate * mx.sigmoid(gate)) * up
        down = gqmm(h, "down", si)
        out = {}
        for stage, y in (("up", up), ("gate", gate), ("down", down)):
            y = y[inv].reshape(rows, TOP_K, -1)
            y = y[mx.array(pos)].reshape(len(pos) * TOP_K, -1)
            out[stage] = mx.view(y, mx.uint16).tolist()
        return out

    results = {}
    for case in cases:
        results[case["name"]] = forward(case)
    repeat = forward(cases[0])
    return results, repeat, mx.__version__


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pin")
    p.add_argument("--pins-dir", required=True)
    p.add_argument("--resolved", required=True)
    for name in ("plan", "run"):
        s = sub.add_parser(name)
        s.add_argument("--seed", type=int, default=2451)
        s.add_argument("--targets", type=int, default=32)
        if name == "run":
            s.add_argument("--expect-mlx", required=True)
            s.add_argument("--out-json", required=True)
    args = ap.parse_args(argv)
    if args.cmd == "pin":
        sys.path.insert(0, args.pins_dir)
        import read_swiftpm_pins as pins
        try:
            tag, version, rev = pinned_core(pins, args.resolved)
        except ValueError as e:
            print(f"GQMM_PIN_FAIL {e}")
            return 2
        print(f"GQMM_PIN core_tag={tag} core_revision={rev} wheel={version}")
        return 0
    if not 1 <= args.targets <= 256:
        print("--targets must be 1..256", file=sys.stderr)
        return 2
    cases = default_cases(args.seed, args.targets)
    stats = {c["name"]: tile_stats(c) for c in cases}
    if args.cmd == "plan":
        for c in cases:
            print(f"GQMM_CASE {c['name']} rows={c['rows']} mode={c['mode']} placement={c['placement']} "
                  + " ".join(f"{k}={v}" for k, v in stats[c["name"]].items()))
        return 0
    results, repeat, version = run_mlx(cases, args.seed, args.targets)
    print(f"GQMM_MLX version={version} expected={args.expect_mlx}")
    if version != args.expect_mlx:
        print(f"GQMM_FAIL mlx {version} is not the pinned core's release {args.expect_mlx}")
        return 2
    ref_name = cases[0]["name"]
    ref = results[ref_name]
    report = {"mlx": version, "seed": args.seed, "targets": args.targets,
              "shapes": {"experts": EXPERTS, "top_k": TOP_K, "hidden": HIDDEN, "intermediate": INTERMEDIATE,
                         "bits": BITS, "group_size": GROUP},
              "reference": ref_name, "cases": []}
    det = [compare_rows(ref[s], repeat[s]) for s in STAGES]
    deterministic = all(c[2] == 0 for c in det)
    print(f"GQMM_DETERMINISM case={ref_name} {'equal' if deterministic else 'DIFFERS'} "
          + " ".join(f"{s}_elems_diff={c[2]}" for s, c in zip(STAGES, det)))
    varies, other_route = [], []
    ref_route = stats[ref_name]["route"]
    for c in cases[1:]:
        entry = {"name": c["name"], "rows": c["rows"], "mode": c["mode"], "placement": c["placement"],
                 **stats[c["name"]], "stages": {}}
        for s in STAGES:
            cmp = compare_rows(ref[s], results[c["name"]][s])
            print(verdict_line(c["name"], s, cmp, stats[c["name"]]))
            entry["stages"][s] = dict(zip(("rows_diff", "rows", "elems_diff", "elems", "max_ulp"), cmp))
            # A case on another kernel route (targets alone: gather_qmv) answers the tail-route
            # question, not tile composition, so it never decides the verdict.
            bucket = varies if stats[c["name"]]["route"] == ref_route else other_route
            if cmp[2] and c["name"] not in bucket:
                bucket.append(c["name"])
        report["cases"].append(entry)
    report["deterministic"] = deterministic
    report["varies"] = varies
    report["other_route_differs"] = other_route
    Path(args.out_json).write_text(json.dumps(report, indent=2) + "\n")
    print(f"GQMM_VERDICT route={ref_route} " + (f"varies cases={varies}" if varies else "invariant")
          + f" other_route_differs={other_route}")
    return 0 if deterministic else 1


if __name__ == "__main__":
    sys.exit(main())
