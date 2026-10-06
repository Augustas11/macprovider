# Exploratory re-read of this run under the SPEC-048 0.1.25 gates

**Exploratory, not a gate, no verdict.** The frozen verdict of this run is
the FAIL in `../analysis.json`, judged by the gates of its own policy
(`0c1b42be…`, inter-chunk ITL gate). That verdict stands and is not
reinterpreted.

This directory is a sanity check of the amended analyzer only:

```bash
python3 scripts/native_mtp_r015_analyze.py r015-a3b-step-overhead-26a434.jsonl policy.json \
  --exploratory-amended-gates            # analysis.json (overall_status EXPLORATORY_NO_VERDICT)
```

on the same raw JSONL (`72e1e5bb…`) and policy. Without the flag, the amended
analyzer reproduces `../analysis.json` exactly (the legacy gate set is still
judged by its own gates).

The run was contaminated by live provider load (see `../README.md`), so these
numbers do not predict a quiet run. What they show: with the structural
inter-chunk mismatch removed, the one-slot per-output-token latency of native
is 19-23% below ordinary at the median (p95 TPOT 8.9-9.7 ms against
11.6-11.9 ms), and the native p99 chunk gap is below ordinary's in every
one-slot cell at the median. Corrected bounds that fail here (s1-p1536-o128
TPOT, s1-p4096-o512 gap p99, the gated cells) are driven by the same
contaminated blocks the original analysis names.
