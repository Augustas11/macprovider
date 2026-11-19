"""Offline comparison for #2414: honest cross-chip vs dishonest quantization gaps.

Reads every run directory (dump.py output, any depth) under the given roots
and prints / writes:

1. Weights and inputs check: every run used the same inputs.json, and each
   variant has the same weight hashes on every host. A mismatch is fatal.
2. Gate: each (host, arm, variant) base run has rep0 and rep1 and they are
   bit-identical. If not, the rep0-vs-rep1 difference is reported as that
   arm's noise floor and the gate is marked failed.
3. Arm checks: per host, which arms are bit-identical to `default`
   (on a pre-generation-17 Mac `tf32off` must be).
4. Injection plumbing: an injection run whose source is the same host, arm and
   variant must equal the base run bit for bit. A mismatch is fatal.
5. Per layer range and statistic, honest = M3 Ultra `default` vs M5 <arm> on
   the same variant; dishonest = same host, `default` arm, different variant.
   Separation = smallest dishonest difference / largest honest difference.
   One table per claimed variant and M5 arm.
6. Injection (the shard case): source = M3 Ultra `default` layer-k output fed
   into an M5 run's layers k+1..; compared with the source's own layer k+n.
   Honest = M5 run on the same variant; dishonest = M5 run on another variant.
7. Final logits: top-1 agreement over every position, the reference top-2
   gap at each disagreement, and max |delta| of the teacher token logprob.

Statistics per hidden-state vector (one layer, one position): max_abs
(max |a-b|), rel_l2 (|a-b| / |a|), one_minus_cos, one_minus_topk (1 minus
the overlap of the --top largest-|x| indices, default 128). Larger is always "more different".

Exit 0 when every check ran (whatever the separation), 1 on a failed gate,
2 on unusable input.

Usage:
  python3 compare.py <runs root> [<runs root> ...] --out <dir>
      [--ref-host m3u] [--test-host m5] [--ranges 4] [--top 128]
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

STATS = ("max_abs", "rel_l2", "one_minus_cos", "one_minus_topk")
INJECT_NS = (1, 4, 8)


class Unusable(Exception):
    pass


def vec_stats(a, b, top):
    """a, b: float arrays [..., hidden]. Returns dict stat -> array [...]."""
    a = a.astype(np.float64)
    b = b.astype(np.float64)
    d = a - b
    na = np.linalg.norm(a, axis=-1)
    nb = np.linalg.norm(b, axis=-1)
    nd = np.linalg.norm(d, axis=-1)
    with np.errstate(divide="ignore", invalid="ignore"):
        rel = np.where(na > 0, nd / na, np.where(nd > 0, np.inf, 0.0))
        cos = np.where((na > 0) & (nb > 0), np.sum(a * b, axis=-1) / (na * nb), 1.0)
    ia = np.argpartition(-np.abs(a), top - 1, axis=-1)[..., :top]
    ib = np.argpartition(-np.abs(b), top - 1, axis=-1)[..., :top]
    flat_a = ia.reshape(-1, top)
    flat_b = ib.reshape(-1, top)
    overlap = np.array([len(np.intersect1d(x, y, assume_unique=True)) for x, y in zip(flat_a, flat_b)])
    overlap = overlap.reshape(ia.shape[:-1]) / top
    return {
        "max_abs": np.max(np.abs(d), axis=-1),
        "rel_l2": rel,
        "one_minus_cos": np.where(nd == 0, 0.0, np.clip(1.0 - cos, 0.0, None)),
        "one_minus_topk": 1.0 - overlap,
    }


def summarize(values):
    v = np.asarray(values, dtype=np.float64).ravel()
    if v.size == 0:
        return None
    return {
        "min": float(v.min()),
        "p50": float(np.percentile(v, 50)),
        "p99": float(np.percentile(v, 99)),
        "max": float(v.max()),
        "n": int(v.size),
    }


def ratio(dis_min, hon_max):
    if hon_max == 0:
        return float("inf") if dis_min > 0 else float("nan")
    return dis_min / hon_max


class Run:
    def __init__(self, path):
        self.path = path
        self.meta = json.loads((path / "meta.json").read_text())
        if self.meta.get("schema") != "hidden-state-2414-run-v1":
            raise Unusable(f"{path}: not a hidden-state-2414-run-v1 run")
        self._seqs = None

    @property
    def key(self):
        m = self.meta
        inj = m["inject"]
        if inj is not None and inj["source_rep"] != 0:
            raise Unusable(f"{self.path}: injection source must be rep0, got rep{inj['source_rep']}")
        tag = None if inj is None else (inj["source_host"], inj["source_arm"], inj["source_variant"], inj["layer"])
        return (m["host"], m["arm"], m["variant"], m["rep"], tag)

    def seqs(self):
        if self._seqs is None:
            files = sorted(self.path.glob("seq*.npz"), key=lambda p: int(p.stem[3:]))
            if not files:
                raise Unusable(f"{self.path}: no seq*.npz")
            self._seqs = [dict(np.load(f)) for f in files]
        return self._seqs

    def layers(self):
        """float32 [S, L, P, H]"""
        return np.stack([s["layers"] for s in self.seqs()])

    def files_hash(self):
        return self.meta["files_sha256"]


def load_runs(roots):
    runs = {}
    for root in roots:
        for meta in Path(root).rglob("meta.json"):
            r = Run(meta.parent)
            if r.key in runs:
                raise Unusable(f"duplicate run {r.key}: {runs[r.key].path} and {r.path}")
            runs[r.key] = r
    if not runs:
        raise Unusable("no runs found")
    return runs


def check_inputs_and_weights(runs):
    inputs = {r.meta["inputs_sha256"] for r in runs.values()}
    if len(inputs) != 1:
        raise Unusable(f"runs used {len(inputs)} different inputs files")
    by_variant = defaultdict(set)
    for r in runs.values():
        by_variant[r.meta["variant"]].add(json.dumps(r.meta["weights_sha256"], sort_keys=True))
    bad = [v for v, h in by_variant.items() if len(h) != 1]
    if bad:
        raise Unusable(f"weight hashes differ across runs for variant(s) {bad}")
    return {v: json.loads(next(iter(h))) for v, h in by_variant.items()}


def layer_ranges(num_layers, k):
    edges = np.linspace(0, num_layers, k + 1).round().astype(int)
    return [(int(edges[i]), int(edges[i + 1]) - 1) for i in range(k)]


def range_stats(a, b, ranges, top):
    """a, b: [S, L, P, H]. Returns {range label: {stat: values array}}."""
    st = vec_stats(a, b, top)  # each [S, L, P]
    out = {}
    for lo, hi in ranges:
        out[f"L{lo}-{hi}"] = {s: st[s][:, lo:hi + 1, :] for s in STATS}
    return out


def logit_compare(ref, test):
    agree = total = 0
    disagreements = []
    max_next = 0.0
    for si, (r, t) in enumerate(zip(ref.seqs(), test.seqs())):
        rt, tt = r["top_ids"][:, 0], t["top_ids"][:, 0]
        total += rt.size
        agree += int(np.sum(rt == tt))
        for p in np.nonzero(rt != tt)[0]:
            disagreements.append({
                "seq": si, "pos": int(p),
                "ref_top1": int(rt[p]), "test_top1": int(tt[p]),
                "ref_top2_gap": float(r["top_logprobs"][p, 0] - r["top_logprobs"][p, 1]),
                "test_top2_gap": float(t["top_logprobs"][p, 0] - t["top_logprobs"][p, 1]),
            })
        max_next = max(max_next, float(np.max(np.abs(r["next_logprob"] - t["next_logprob"]))))
    return {
        "top1_agree": agree, "positions": total,
        "max_abs_next_logprob_delta": max_next,
        "disagreements": disagreements,
    }


def bit_identical(a, b):
    return a.files_hash() == b.files_hash()


def fmt(x):
    if x is None:
        return "-"
    if isinstance(x, float) and (np.isinf(x) or np.isnan(x)):
        return str(x)
    return f"{x:.3g}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("roots", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--ref-host", default="m3u")
    ap.add_argument("--test-host", default="m5")
    ap.add_argument("--ranges", type=int, default=4)
    ap.add_argument("--top", type=int, default=128)
    args = ap.parse_args()
    try:
        return run(args)
    except Unusable as e:
        print(f"compare: unusable input: {e}", file=sys.stderr)
        return 2


def run(args):
    runs = load_runs(args.roots)
    weights = check_inputs_and_weights(runs)
    any_run = next(iter(runs.values()))
    num_layers = any_run.meta["num_layers"]
    full_layers = any_run.meta["full_layers"]
    hidden = any_run.layers().shape[-1]
    if args.top >= hidden:
        raise Unusable(f"--top {args.top} >= hidden size {hidden}: the top-k overlap would be trivially 1")
    ranges = layer_ranges(num_layers, args.ranges)
    R, T = args.ref_host, args.test_host
    base = {k[:4]: r for k, r in runs.items() if k[4] is None}
    variants = sorted({k[2] for k in base})
    lines = []
    report = {"weights_sha256": weights, "ranges": [f"L{a}-{b}" for a, b in ranges], "hosts": {}}
    for k, r in base.items():
        if k[3] == 0:
            report["hosts"].setdefault(k[0], {})[f"{k[1]}/{k[2]}"] = {
                f: r.meta.get(f) for f in ("chip", "hw_model", "macos", "macos_build", "mlx", "mlx_lm",
                                         "gpu_architecture", "env", "activation_dtype")}

    # 2. gate
    gate_ok = True
    gate = []
    for (h, a, v, rep), r in sorted(base.items()):
        if rep != 0:
            continue
        r1 = base.get((h, a, v, 1))
        if r1 is None:
            gate.append({"run": f"{h}/{a}/{v}", "status": "missing rep1"})
            gate_ok = False
            continue
        if bit_identical(r, r1):
            gate.append({"run": f"{h}/{a}/{v}", "status": "bit-identical"})
        else:
            gate_ok = False
            st = range_stats(r.layers(), r1.layers(), ranges, args.top)
            gate.append({"run": f"{h}/{a}/{v}", "status": "DIFFERS",
                         "noise_floor": {rg: {s: summarize(x) for s, x in d.items()} for rg, d in st.items()}})
    report["gate"] = gate
    lines.append("## Gate: rep0 vs rep1 on the same Mac\n")
    lines += [f"- {g['run']}: {g['status']}" for g in gate]

    # 3. arm checks
    arms = []
    for (h, a, v, rep), r in sorted(base.items()):
        if rep != 0 or a == "default":
            continue
        d = base.get((h, "default", v, 0))
        if d is not None:
            arms.append({"host": h, "arm": a, "variant": v, "identical_to_default": bit_identical(r, d),
                         "gpu_architecture": r.meta.get("gpu_architecture")})
    for x in arms:
        if x["host"] == R and x["arm"] == "tf32off" and not x["identical_to_default"]:
            gate_ok = False
            gate.append({"run": f"{R}/tf32off/{x['variant']}",
                         "status": "DIFFERS from default (the flag must be inert before generation 17)"})
    report["arm_checks"] = arms
    lines.append("\n## Arms vs default on the same Mac\n")
    lines += [f"- {x['host']}/{x['arm']}/{x['variant']} (arch {x['gpu_architecture']}): "
              f"{'bit-identical' if x['identical_to_default'] else 'differs'}" for x in arms]
    ref_arch = report["hosts"].get(R, {}).get(f"default/{variants[0]}", {}).get("gpu_architecture") if variants else None
    for (h, a, v, rep), r in base.items():
        if h == T and a == "arch-m3u" and rep == 0 and ref_arch and r.meta.get("gpu_architecture") != ref_arch:
            raise Unusable(f"{T}/arch-m3u reports {r.meta.get('gpu_architecture')}, {R} reports {ref_arch}")

    # 4. injection plumbing
    inj = {k: r for k, r in runs.items() if k[4] is not None}
    plumbing = []
    for (h, a, v, rep, (sh, sa, sv, k)), r in sorted(inj.items()):
        if (sh, sa, sv) == (h, a, v):
            ref = base.get((h, a, v, 0))
            if ref is None:
                raise Unusable(f"self-injection {r.path} has no base run")
            ok = bit_identical(r, ref)
            plumbing.append({"run": f"{h}/{a}/{v} L{k}", "bit_identical_to_base": ok})
            if not ok:
                raise Unusable(f"self-injection {r.path} differs from its base run: injection is not exact")
    for (h, a, v, rep, (sh, sa, sv, k)), r in inj.items():
        src = base.get((sh, sa, sv, 0))
        if src is None:
            raise Unusable(f"injection {r.path}: source run {sh}/{sa}/{sv} rep0 not found")
        for i, (x, y) in enumerate(zip(r.seqs(), src.seqs())):
            if not (np.array_equal(x[f"full_{k}"], y[f"full_{k}"]) and np.array_equal(x["layers"][k], y["layers"][k])):
                raise Unusable(f"injection {r.path} seq{i}: layer {k} does not equal the source; injection did not apply")
    report["injection_plumbing"] = plumbing

    # 5. separation per claimed variant and test arm
    ref_runs = {v: base.get((R, "default", v, 0)) for v in variants}
    test_arms = sorted({a for (h, a, v, rep) in base if h == T and rep == 0})
    dishonest = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))  # claimed -> range -> stat -> [arrays]
    dis_pairs = defaultdict(list)
    for host in (R, T):
        for c in variants:
            for o in variants:
                if o == c:
                    continue
                rc, ro = base.get((host, "default", c, 0)), base.get((host, "default", o, 0))
                if rc is None or ro is None:
                    continue
                dis_pairs[c].append(f"{host}:{c}-vs-{o}")
                for rg, d in range_stats(rc.layers(), ro.layers(), ranges, args.top).items():
                    for s, x in d.items():
                        dishonest[c][rg][s].append(x)
    separation = {}
    lines.append("\n## Separation: smallest dishonest / largest honest, per layer range\n")
    lines.append("Honest = M3 Ultra default vs M5 arm, same weights. Dishonest = same Mac, "
                 "default arm, the claimed variant vs another quantization.\n")
    for c in variants:
        rr = ref_runs.get(c)
        if rr is None:
            continue
        for a in test_arms:
            tr = base.get((T, a, c, 0))
            if tr is None or not dishonest[c]:
                continue
            honest = range_stats(rr.layers(), tr.layers(), ranges, args.top)
            tab = {}
            lines.append(f"\n### claimed {c}, M5 arm `{a}` (dishonest: {', '.join(dis_pairs[c])})\n")
            lines.append("| range | stat | honest p50 | honest max | dishonest min | dishonest p50 | separation |")
            lines.append("|---|---|---|---|---|---|---|")
            for rg in honest:
                tab[rg] = {}
                for s in STATS:
                    hs = summarize(honest[rg][s])
                    ds = summarize(np.concatenate([x.ravel() for x in dishonest[c][rg][s]]))
                    sep = ratio(ds["min"], hs["max"])
                    tab[rg][s] = {"honest": hs, "dishonest": ds, "separation": sep}
                    lines.append(f"| {rg} | {s} | {fmt(hs['p50'])} | {fmt(hs['max'])} | {fmt(ds['min'])} "
                                 f"| {fmt(ds['p50'])} | {fmt(sep)} |")
            separation[f"{c}/{a}"] = tab
    report["separation"] = separation

    # 6. injection: M3 Ultra layer k into M5 layers k+1..
    injection = {}
    lines.append("\n## Injection: M3 Ultra layer-k output into M5 layers k+1..k+n, vs M3 Ultra layer k+n\n")
    lines.append("| claimed | M5 arm | k | n | stat | honest max | dishonest min | separation |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for c in variants:
        src = ref_runs.get(c)
        if src is None:
            continue
        src_layers = src.layers()
        for a in test_arms:
            for k in full_layers:
                hon = inj.get((T, a, c, 0, (R, "default", c, k)))
                dis = [r for (h, aa, v, rep, tag), r in inj.items()
                       if h == T and aa == a and v != c and tag == (R, "default", c, k)]
                if hon is None:
                    continue
                for n in INJECT_NS:
                    tgt = k + n
                    if tgt >= num_layers:
                        continue
                    hs_all = vec_stats(src_layers[:, tgt], hon.layers()[:, tgt], args.top)
                    ds_all = [vec_stats(src_layers[:, tgt], r.layers()[:, tgt], args.top) for r in dis]
                    cell = {}
                    for s in STATS:
                        hs = summarize(hs_all[s])
                        ds = summarize(np.concatenate([x[s].ravel() for x in ds_all])) if ds_all else None
                        sep = ratio(ds["min"], hs["max"]) if ds else None
                        cell[s] = {"honest": hs, "dishonest": ds, "separation": sep}
                        lines.append(f"| {c} | {a} | {k} | {n} | {s} | {fmt(hs['max'])} "
                                     f"| {fmt(ds['min'] if ds else None)} | {fmt(sep)} |")
                    injection[f"{c}/{a}/L{k}+{n}"] = cell
    report["injection"] = injection

    # 7. final logits
    logits = {}
    lines.append("\n## Final logits, teacher-forced, every position\n")
    lines.append("| pair | top-1 agree | max abs delta teacher logprob | disagreements (ref top-2 gap) |")
    lines.append("|---|---|---|---|")

    def add_logits(label, a_run, b_run):
        res = logit_compare(a_run, b_run)
        logits[label] = res
        gaps = ", ".join(f"{d['ref_top2_gap']:.3g}" for d in res["disagreements"][:12])
        more = "" if len(res["disagreements"]) <= 12 else f" (+{len(res['disagreements']) - 12})"
        lines.append(f"| {label} | {res['top1_agree']}/{res['positions']} | "
                     f"{fmt(res['max_abs_next_logprob_delta'])} | {gaps}{more} |")

    for c in variants:
        rr = ref_runs.get(c)
        if rr is None:
            continue
        for a in test_arms:
            tr = base.get((T, a, c, 0))
            if tr is not None:
                add_logits(f"{c}: {R}/default vs {T}/{a}", rr, tr)
    for host in (R, T):
        for i, c in enumerate(variants):
            for o in variants[i + 1:]:
                rc, ro = base.get((host, "default", c, 0)), base.get((host, "default", o, 0))
                if rc is not None and ro is not None:
                    add_logits(f"{host}: {c} vs {o}", rc, ro)
    report["final_logits"] = logits
    report["gate_ok"] = gate_ok

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").write_text(json.dumps(report, indent=1, default=float) + "\n")
    text = "\n".join(lines) + "\n"
    (out / "summary.md").write_text(text)
    print(text)
    if not gate_ok:
        print("compare: gate FAILED (see Gate); cross-Mac numbers carry the reported noise floor", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
