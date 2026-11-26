#!/usr/bin/env python3
"""Where oMLX's GLM-5.3 prefill goes, by section (#2524 lab only).

usage: omlx_section_report.py --plain ref.jsonl --hooked ref.jsonl --sections DIR
                              [--prompt-tokens N] [--gap-s 0.5] --out-md F --out-json F

--plain   reference_omlx.py rows without the hook: the unsynchronized TTFT.
--hooked  rows of the run with the section hook (synchronized, slower).
--sections the hook's sections-<pid>.json files.

Prefill chunks (text-model calls of >= the hook's min tokens) are grouped into
requests: a new request starts when a chunk begins more than --gap-s after the
previous one ended. A request counts when its chunk tokens add up to within 2
of --prompt-tokens (default: the plain rows' median prompt_tokens; oMLX may leave the last prompt token to the first decode
step). Per section, the median over requests of its exclusive ms is scaled by
plain median TTFT / hooked median synced chunk total, as the Swift profile
scales to served TTFT. Prints OMLX_PROFILE lines; exits 1 when no request
matches.
"""

import argparse
import glob
import json
import os
import statistics
import sys


def rows(path):
    out = []
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            if r.get("kind") == "row" and r.get("error") is None and r.get("ttft_s") is not None:
                out.append(r)
    return out


def requests(calls, gap_s):
    groups, cur = [], []
    for c in sorted(calls, key=lambda c: c["start"]):
        if cur and c["start"] - cur[-1]["end"] > gap_s:
            groups.append(cur)
            cur = []
        cur.append(c)
    if cur:
        groups.append(cur)
    return groups


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--plain", required=True)
    ap.add_argument("--hooked", required=True)
    ap.add_argument("--sections", required=True)
    ap.add_argument("--prompt-tokens", type=int, help="default: the plain rows' median prompt_tokens")
    ap.add_argument("--gap-s", type=float, default=0.5)
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--out-json", required=True)
    a = ap.parse_args(argv)

    plain, hooked = rows(a.plain), rows(a.hooked)
    if not plain:
        print("OMLX_PROFILE_FAIL no plain rows", file=sys.stderr)
        return 1
    if a.prompt_tokens is None:
        a.prompt_tokens = int(statistics.median(r.get("prompt_tokens") or 0 for r in plain))
    calls, untimed, registered = [], set(), 0
    for p in sorted(glob.glob(os.path.join(a.sections, "sections-*.json"))):
        with open(p) as f:
            d = json.load(f)
        calls += d["calls"]
        untimed |= set(d.get("untimed", []))
        registered = max(registered, d.get("registered", 0))
    groups = [g for g in requests(calls, a.gap_s)
              if abs(sum(c["tokens"] for c in g) - a.prompt_tokens) <= 2]
    if not plain or not groups:
        print(f"OMLX_PROFILE_FAIL plain_rows={len(plain)} hooked_rows={len(hooked)} chunks={len(calls)} "
              f"matching_requests={len(groups)}", file=sys.stderr)
        return 1

    plain_ttft = statistics.median(r["ttft_s"] for r in plain) * 1000.0
    hooked_ttft = statistics.median(r["ttft_s"] for r in hooked) * 1000.0 if hooked else None
    synced = statistics.median(sum(c["total_ms"] for c in g) for g in groups)
    scale = plain_ttft / synced
    names = sorted({n for g in groups for c in g for n in c["sections"]})
    per = {n: statistics.median(sum(c["sections"].get(n, 0.0) for c in g) for g in groups) for n in names}
    chunks = [[c["tokens"] for c in g] for g in groups]

    lines = [
        f"oMLX prefill sections, {a.prompt_tokens} prompt tokens, {len(groups)} requests",
        "",
        f"- plain TTFT median {plain_ttft:.0f} ms ({len(plain)} rows); hooked TTFT median "
        f"{hooked_ttft:.0f} ms; synced chunk total median {synced:.0f} ms; scale {scale:.4f}"
        if hooked_ttft is not None else f"- plain TTFT median {plain_ttft:.0f} ms; synced total {synced:.0f} ms",
        f"- chunk tokens per request: {chunks}",
        f"- registered modules {registered}; untimed (compiled) sections: {sorted(untimed) or 'none'}",
        "- `model` is the text model's own time outside its layers (embedding, norm); the lm head and "
        "sampling are outside the timed calls (TTFT minus the scaled total).",
        "",
        "| section | synced ms | scaled ms | share of plain TTFT |",
        "|---|---:|---:|---:|",
    ]
    for n in sorted(names, key=lambda n: -per[n]):
        lines.append(f"| `{n}` | {per[n]:.1f} | {per[n] * scale:.1f} | {100 * per[n] * scale / plain_ttft:.1f}% |")
    lines.append(f"| **total** | {synced:.1f} | {synced * scale:.1f} | {100 * synced * scale / plain_ttft:.1f}% |")
    with open(a.out_md, "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(a.out_json, "w") as f:
        json.dump({"prompt_tokens": a.prompt_tokens, "plain_ttft_ms": plain_ttft, "hooked_ttft_ms": hooked_ttft,
                   "synced_total_ms": synced, "scale": scale, "chunks": chunks, "untimed": sorted(untimed),
                   "sections_synced_ms": per}, f, indent=1)
    for n in sorted(names, key=lambda n: -per[n]):
        print(f"OMLX_PROFILE section={n} synced_ms={per[n]:.1f} scaled_ms={per[n] * scale:.1f}")
    print(f"OMLX_PROFILE total plain_ttft_ms={plain_ttft:.0f} synced_ms={synced:.0f} requests={len(groups)} "
          f"chunks={chunks}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
