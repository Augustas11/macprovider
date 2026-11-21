#!/usr/bin/env python3
"""engine-333 window gate for one model pass directory (see window.sh).

usage: gate.py --pass cb|mtp PASS_DIR
Reads PASS_DIR/compare-new.json and compare-base2.json (compare.py --baseline base1) and, for
the mtp pass, compare-new-mtp-vs-new-ordinary.json. Prints one line per failed check and a
GATE line; exits 0 when every check passes, 1 otherwise.
"""
import argparse, json, os, sys

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def cells(doc):
    return {(c["ctx"], c["out"], c["rows"]): c for c in (doc or {}).get("cells", [])}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pass", dest="pass_", choices=("cb", "mtp"), required=True)
    ap.add_argument("dir")
    a = ap.parse_args()
    problems = []
    new = load(os.path.join(a.dir, "compare-new.json"))
    base2 = cells(load(os.path.join(a.dir, "compare-base2.json")))
    if a.pass_ == "cb" and new is None:
        problems.append("no compare-new.json (new grid did not run)")
    for key, c in sorted(cells(new).items()):
        ctx, out, rows = key
        tag = f"ctx{ctx}|out{out}|rows{rows}"
        if not c.get("identical"):
            b = base2.get(key)
            if rows == 1 or b is None or b.get("identical"):
                problems.append(f"{tag}: new text differs from base1"
                                + ("" if rows == 1 else " (base2 is identical there)"))
        delta, band = c.get("request_delta"), c.get("band", 0.03)
        if delta is not None and delta < -band:
            problems.append(f"{tag}: new request tok/s {delta:+.3f} vs base1, beyond band {band:.3f}")
    if a.pass_ == "mtp":
        m = load(os.path.join(a.dir, "compare-new-mtp-vs-new-ordinary.json"))
        if m is None:
            problems.append("no native-MTP vs ordinary comparison (new mtp or new cb grid did not run)")
        for key, c in sorted(cells(m).items()):
            if not c.get("identical"):
                problems.append(f"ctx{key[0]}|out{key[1]}|rows{key[2]}: native MTP text differs from ordinary decode")
    for p in problems:
        print("GATE_FAIL", p)
    print(f"GATE {'PASS' if not problems else 'FAIL'} {a.dir} problems={len(problems)}")
    return 0 if not problems else 1

if __name__ == "__main__":
    sys.exit(main())
