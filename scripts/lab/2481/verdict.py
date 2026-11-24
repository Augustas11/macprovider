"""#2481 verdict: does the branch's native-MTP self-check agree with the one-row parity grid?

Reads three run-grid.sh provider.jsonl files (rows 1): `ordinary` (native MTP off), `native`
(the base build, which admits native MTP) and `served` (the branch build with native_mtp_mode
auto), plus the serve logs of the branch and base native-MTP serves. Per (context, output) cell it
takes the median one-row request tok/s (output tokens over the whole request, prefill included:
the #2481 table's metric) and prints

  T2481_CELL ctx=<n> out=<n> ordinary=<tps> native=<tps> delta=<%> served=<tps> served_delta=<%>
  T2481_SELFCHECK build=<branch|base> result=<reason> speedup=<x> point=<name> ...
  T2481_POINT <the branch serve's event=native_mtp_self_check_point fields>
  T2481_VERDICT <AGREES|DISAGREES> admitted=<bool> ...

The branch self-check agrees with the grid when it admitted native MTP and native beats ordinary
in every cell, or refused it and some cell is below the self-check margin (1.03). Exit 0 on
agreement, 1 on disagreement, 2 on unusable input.
"""
import argparse
import json
import re
import statistics
import sys

MARGIN = 1.03


def cells(path):
    """{(ctx_target, max_tokens): median request_tps} over error-free one-row turn-1 rows."""
    by_cell = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if r.get("kind", "row") != "row" or r.get("rows") != 1 or r.get("turn", 1) != 1:
                continue
            if r.get("error") or not r.get("request_tps"):
                continue
            by_cell.setdefault((r["ctx_target"], r["max_tokens"]), []).append(r["request_tps"])
    return {k: statistics.median(v) for k, v in by_cell.items()}


def selfcheck(path):
    """The last `event=native_mtp_self_check result=` line's fields and the point lines."""
    verdict, points = None, []
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None, []
    for line in text.splitlines():
        m = re.search(r"event=native_mtp_self_check(_point)? (.*)$", line)
        if not m:
            continue
        fields = dict(kv.split("=", 1) for kv in m.group(2).split() if "=" in kv)
        if m.group(1):
            points.append(fields)
        else:
            verdict = fields
    return verdict, points


def pct(new, old):
    return (new / old - 1.0) * 100.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ordinary", required=True)
    ap.add_argument("--native", required=True)
    ap.add_argument("--served", required=True)
    ap.add_argument("--selfcheck-log", required=True)
    ap.add_argument("--base-selfcheck-log")
    ap.add_argument("--json")
    a = ap.parse_args()

    ordinary, native, served = cells(a.ordinary), cells(a.native), cells(a.served)
    keys = sorted(set(ordinary) & set(native))
    if not keys:
        print("BLOCKER: no one-row cell has both an ordinary and a native result")
        return 2
    rows = []
    for ctx, out in keys:
        row = {"ctx": ctx, "out": out, "ordinary_tps": ordinary[(ctx, out)], "native_tps": native[(ctx, out)],
               "delta_pct": pct(native[(ctx, out)], ordinary[(ctx, out)]),
               "served_tps": served.get((ctx, out))}
        row["served_delta_pct"] = pct(row["served_tps"], row["ordinary_tps"]) if row["served_tps"] else None
        rows.append(row)
        sd = "n/a" if row["served_delta_pct"] is None else f"{row['served_delta_pct']:+.1f}%"
        st = "n/a" if row["served_tps"] is None else f"{row['served_tps']:.2f}"
        print(f"T2481_CELL ctx={ctx} out={out} ordinary={row['ordinary_tps']:.2f} native={row['native_tps']:.2f} "
              f"delta={row['delta_pct']:+.1f}% served={st} served_delta={sd}")

    branch, points = selfcheck(a.selfcheck_log)
    base, _ = selfcheck(a.base_selfcheck_log) if a.base_selfcheck_log else (None, [])
    for name, v in (("base", base), ("branch", branch)):
        if v is not None:
            print(f"T2481_SELFCHECK build={name} " + " ".join(f"{k}={v[k]}" for k in v))
    for p in points:
        print("T2481_POINT " + " ".join(f"{k}={p[k]}" for k in p))
    if branch is None:
        print("BLOCKER: the branch serve logged no event=native_mtp_self_check result= line")
        return 2

    admitted = branch.get("result") == "passed"
    native_wins_everywhere = all(r["delta_pct"] > 0 for r in rows)
    below_margin = [r for r in rows if r["native_tps"] / r["ordinary_tps"] <= MARGIN]
    agrees = native_wins_everywhere if admitted else bool(below_margin)
    print(f"T2481_VERDICT {'AGREES' if agrees else 'DISAGREES'} admitted={str(admitted).lower()} "
          f"native_wins_every_cell={str(native_wins_everywhere).lower()} cells_below_margin={len(below_margin)} "
          f"branch_result={branch.get('result')} branch_point={branch.get('point')}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"cells": rows, "branch_selfcheck": branch, "base_selfcheck": base, "points": points,
                       "admitted": admitted, "native_wins_every_cell": native_wins_everywhere,
                       "agrees": agrees, "margin": MARGIN}, f, indent=2, sort_keys=True)
    return 0 if agrees else 1


if __name__ == "__main__":
    sys.exit(main())
