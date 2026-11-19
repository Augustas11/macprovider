#!/usr/bin/env python3
"""Gate and table for the #2409 GLM serial prefill-step change (job-glm-prefill-step-gate.sh).

Reads a `prefill-profile --generate-tokens N --served-only` JSON whose served runs recorded
their greedy tokens, and checks, per prompt length:
  - every run decoded exactly N tokens;
  - every run at one step size decoded the same tokens (run-to-run determinism);
  - the runs at every step size decoded the same tokens as at the first step size, at every
    position (first differing position reported otherwise);
and that the step serve resolves for the model with prefill_step_size unset
(`serve_default_step`) is --expect-default-step.

Writes gate.md (TTFT median/min/max per step and prompt, change against the first step, decode
time, MLX peak memory per step) and gate.json, prints `GATE_PASS` or `GATE_FAIL <reasons>` and
exits 0 on pass, 1 on fail, 2 on unreadable input.
"""

import argparse
import json
import statistics
import sys


def first_difference(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None if len(a) == len(b) else min(len(a), len(b))


def evaluate(profile, expect_default_step):
    n = profile.get("generate_tokens")
    failures = []
    if not isinstance(n, int) or n < 2:
        failures.append(f"generate_tokens={n!r}: the profile did not decode past the first token")
    default = profile.get("serve_default_step")
    if default != expect_default_step:
        failures.append(f"serve_default_step={default!r}, expected {expect_default_step}")
    prompts = []
    for prompt in profile.get("prompts", []):
        length = prompt.get("tokens")
        steps = []
        reference = None
        reference_step = None
        for served in prompt.get("served", []):
            step = served.get("step")
            runs = served.get("runs", [])
            token_lists = [r.get("tokens") for r in runs]
            ttft = [r["ttft_ms"] for r in runs]
            decode = [r.get("decode_ms") for r in runs if r.get("decode_ms") is not None]
            row = {
                "step": step,
                "runs": len(runs),
                "ttft_ms": ttft,
                "ttft_median_ms": statistics.median(ttft) if ttft else None,
                "decode_median_ms": statistics.median(decode) if decode else None,
                "mlx_peak_bytes": served.get("mlx_peak_bytes"),
                "deterministic": None,
                "matches_first_step": None,
                "first_difference": None,
            }
            if not runs:
                failures.append(f"prompt {length} step {step}: no runs")
            elif any(not isinstance(t, list) or len(t) != n for t in token_lists):
                lengths = [len(t) if isinstance(t, list) else None for t in token_lists]
                failures.append(f"prompt {length} step {step}: decoded {lengths} tokens, expected {n}")
            else:
                row["deterministic"] = all(t == token_lists[0] for t in token_lists)
                if not row["deterministic"]:
                    failures.append(f"prompt {length} step {step}: runs decoded different tokens")
                if reference is None:
                    reference, reference_step = token_lists[0], step
                else:
                    diff = first_difference(reference, token_lists[0])
                    row["matches_first_step"] = diff is None
                    row["first_difference"] = diff
                    if diff is not None:
                        failures.append(
                            f"prompt {length}: step {step} leaves step {reference_step} at token {diff} "
                            f"({reference[diff] if diff < len(reference) else None} vs "
                            f"{token_lists[0][diff] if diff < len(token_lists[0]) else None})")
            steps.append(row)
        if len(steps) < 2:
            failures.append(f"prompt {length}: fewer than two step sizes")
        prompts.append({"tokens": length, "steps": steps})
    if not prompts:
        failures.append("no prompts")
    return {"generate_tokens": n, "serve_default_step": default, "prompts": prompts,
            "pass": not failures, "failures": failures}


def markdown(result):
    gb = lambda b: f"{b / 1e9:.1f}" if isinstance(b, (int, float)) else "-"
    ms = lambda v: f"{v:,.1f}" if isinstance(v, (int, float)) else "-"
    lines = [
        "# GLM-5.3-Flash serial prefill step gate (#2409)", "",
        f"Greedy tokens compared per run: {result['generate_tokens']}; serve's step with "
        f"prefill_step_size unset: {result['serve_default_step']}.", "",
        "| prompt | step | runs | TTFT ms median (min-max) | TTFT vs first step | decode ms median "
        "| MLX peak GB | runs agree | tokens equal first step |",
        "|---:|---:|---:|---|---:|---:|---:|---|---|",
    ]
    for prompt in result["prompts"]:
        base = prompt["steps"][0]["ttft_median_ms"] if prompt["steps"] else None
        for row in prompt["steps"]:
            t = row["ttft_ms"]
            change = (f"{(row['ttft_median_ms'] / base - 1) * 100:+.1f}%"
                      if base and row["ttft_median_ms"] is not None else "-")
            equal = ("-" if row["matches_first_step"] is None
                     else "yes" if row["matches_first_step"] else f"NO (token {row['first_difference']})")
            agree = "-" if row["deterministic"] is None else ("yes" if row["deterministic"] else "NO")
            lines.append(
                f"| {prompt['tokens']} | {row['step']} | {row['runs']} | {ms(row['ttft_median_ms'])} "
                f"({ms(min(t)) if t else '-'}-{ms(max(t)) if t else '-'}) | {change} | "
                f"{ms(row['decode_median_ms'])} | {gb(row['mlx_peak_bytes'])} | {agree} | {equal} |")
    lines += ["", f"Gate: {'PASS' if result['pass'] else 'FAIL'}"]
    lines += [f"- {f}" for f in result["failures"]]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--profile", required=True)
    parser.add_argument("--expect-default-step", type=int, required=True)
    parser.add_argument("--out-md", required=True)
    parser.add_argument("--out-json", required=True)
    args = parser.parse_args(argv)
    try:
        with open(args.profile) as f:
            profile = json.load(f)
    except (OSError, ValueError) as error:
        print(f"GATE_FAIL unreadable profile: {error}")
        return 2
    result = evaluate(profile, args.expect_default_step)
    with open(args.out_json, "w") as f:
        json.dump(result, f, indent=2, sort_keys=True)
    with open(args.out_md, "w") as f:
        f.write(markdown(result))
    print("GATE_PASS" if result["pass"] else "GATE_FAIL " + "; ".join(result["failures"]))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
