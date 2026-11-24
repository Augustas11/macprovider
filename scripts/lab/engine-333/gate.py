#!/usr/bin/env python3
"""engine-333 window gate for one model pass directory (see window.sh).

usage: gate.py --pass cb|mtp [--text-change-expected REASON] PASS_DIR
--text-change-expected: the engine changes this model's numerics on purpose (REASON names the
upstream change), so a text difference from base1 is reported as INFO, not a failure.
Reads PASS_DIR/compare-new.json and compare-base2.json (compare.py --baseline base1) and, for
the mtp pass, compare-new-mtp-vs-new-ordinary.json, compare-new-mtp-vs-ref.json, base1/provider.jsonl
(native_mtp.proposed_tokens) and the native-MTP self-check and small-M route lines of
new/serve/serve.err and ../cb/new/serve/serve.err. Prints one line per failed check and a
GATE line; GATE_WARN lines report findings that do not fail the gate; exits 0 when every check
passes, 1 otherwise.
"""
import argparse, json, os, re, sys

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def cells(doc):
    return {(c["ctx"], c["out"], c["rows"]): c for c in (doc or {}).get("cells", [])}

def serve_events(run_dir, pattern):
    """Every capture of pattern in run_dir/serve/serve.err, in order."""
    out = []
    try:
        with open(os.path.join(run_dir, "serve", "serve.err"), errors="replace") as f:
            for line in f:
                out += [mm.group(1) for mm in re.finditer(pattern, line)]
    except OSError:
        pass
    return out

def serve_event(run_dir, pattern):
    """First capture of pattern in run_dir/serve/serve.err, or None."""
    ev = serve_events(run_dir, pattern)
    return ev[0] if ev else None

def proposed(jsonl):
    n = 0
    try:
        with open(jsonl) as f:
            for line in f:
                try:
                    n += int((json.loads(line).get("native_mtp") or {}).get("proposed_tokens") or 0)
                except (ValueError, TypeError, AttributeError):
                    pass
    except OSError:
        pass
    return n

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pass", dest="pass_", choices=("cb", "mtp"), required=True)
    ap.add_argument("--text-change-expected", default="")
    ap.add_argument("--new-only", action="store_true",
                    help="no base runs (RUNS without base1): skip the new-vs-base1 checks")
    ap.add_argument("dir")
    a = ap.parse_args()
    problems, info, warn = [], [], []
    new = None if a.new_only else load(os.path.join(a.dir, "compare-new.json"))
    # mtp pass: did base1 actually run native MTP? If it proposed no token, its cells are ordinary
    # decode and a new-vs-base1 speed delta compares native MTP against ordinary decode.
    base_mtp_ran = True
    if a.pass_ == "mtp":
        base_mtp_ran = a.new_only or proposed(os.path.join(a.dir, "base1", "provider.jsonl")) > 0
        if not base_mtp_ran:
            info.append("base1 proposed no native-MTP token: new-vs-base1 speed not compared"
                        " (base1 cells are ordinary decode; the cb pass gates that speed)")
    base2 = cells(load(os.path.join(a.dir, "compare-base2.json")))
    if new is None and not a.new_only:
        problems.append("no compare-new.json (new grid did not run)")
    for key, c in sorted(cells(new).items()):
        ctx, out, rows = key
        tag = f"ctx{ctx}|out{out}|rows{rows}"
        if not c.get("identical"):
            b = base2.get(key)
            if a.text_change_expected:
                info.append(f"{tag}: new text differs from base1 (expected: {a.text_change_expected})")
            elif rows == 1 or b is None or b.get("identical"):
                problems.append(f"{tag}: new text differs from base1"
                                + ("" if rows == 1 else " (base2 is identical there)"))
        delta, band = c.get("request_delta"), c.get("band", 0.03)
        if delta is not None and delta < -band and base_mtp_ran:
            problems.append(f"{tag}: new request tok/s {delta:+.3f} vs base1, beyond band {band:.3f}")
    if a.pass_ == "mtp":
        m = load(os.path.join(a.dir, "compare-new-mtp-vs-new-ordinary.json"))
        if m is None and not a.new_only:
            problems.append("no native-MTP vs ordinary comparison (new mtp or new cb grid did not run)")
        # SPEC-048 R015 losslessness is the serve's own native-MTP self-check: native MTP and
        # ordinary decode on the same serve, token for token. The cross-serve comparison above
        # sets this mtp serve against the cb pass's serve; when their small-M routes differ
        # (row_invariant/mixed vs stock_order) the matmul numerics differ, so its text
        # differences are reported, not gated.
        scs = serve_events(os.path.join(a.dir, "new"), r"event=native_mtp_self_check result=(\S+)")
        sc = "passed" if scs and all(x == "passed" for x in scs) else ",".join(scs) or "absent"
        if sc != "passed":
            problems.append(f"new native-MTP self-check result={sc} (R015 needs every line passed)")
        ref = load(os.path.join(a.dir, "compare-new-mtp-vs-ref.json"))
        if ref is None and a.new_only:
            problems.append("no same-route ordinary reference: a new-only window gates R015 on it")
        elif ref is None:
            info.append("no same-route ordinary reference (ref run absent): R015 rests on the self-check")
        for key, c in sorted(cells(ref).items()):
            if not c.get("identical"):
                problems.append(f"ctx{key[0]}|out{key[1]}|rows{key[2]}: native MTP text differs from same-route (row_invariant) ordinary decode")
        if not base_mtp_ran:
            for key, c in sorted(cells(m).items()):
                d = c.get("request_delta")
                if d is not None and d < -c.get("band", 0.03):
                    warn.append(f"ctx{key[0]}|out{key[1]}|rows{key[2]}: new native MTP {d:+.3f} request tok/s vs new ordinary decode")
        r_mtp = serve_event(os.path.join(a.dir, "new"), r"event=small_m_route mode=(\S+)")
        r_cb = serve_event(os.path.join(os.path.dirname(os.path.abspath(a.dir)), "cb", "new"),
                           r"event=small_m_route mode=(\S+)")
        for key, c in sorted(cells(m).items()):
            if c.get("identical"):
                continue
            tag = f"ctx{key[0]}|out{key[1]}|rows{key[2]}: native MTP text differs from the cb serve's ordinary decode"
            if r_mtp and r_cb and r_mtp != r_cb:
                info.append(f"{tag} (small-M route {r_mtp} vs {r_cb}; same-serve self-check {sc})")
            else:
                problems.append(f"{tag} (same small-M route {r_mtp or '?'})")
    for i in info:
        print("GATE_INFO", i)
    for w in warn:
        print("GATE_WARN", w)
    for p in problems:
        print("GATE_FAIL", p)
    print(f"GATE {'PASS' if not problems else 'FAIL'} {a.dir} problems={len(problems)}")
    return 0 if not problems else 1

if __name__ == "__main__":
    sys.exit(main())
