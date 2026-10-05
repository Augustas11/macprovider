# SPEC-048 R015 on the chunked fused baseline, Studio build 26A434

This directory preregisters a new formal R015 run for the Qwen3.6 A3B
native-MTP tuple. The ordinary path now uses the chunked fused MLX fork
revision `b181102984a4d1875efbd9e0eab3a7dfd1c012c5` (SPEC-048 0.1.23). The
designated Studio now runs macOS build `26A434`. Every earlier R015 policy
binds the retired envelope and build `25E253`.

The frozen byte-exact `policy.json` has SHA-256
`2c8a234462c1d3dcaff16268915e714774bbf3fff0aa944880208e807707e19a`.
It binds the lab binary to provider commit
`280f0e95d623353873147e523391e78d71327c5b` (origin/main after PR #1832). The
binary is built on the designated `Mac15,14` Studio with
`-DMACPROVIDER_LAB_HARNESS` and used only in an isolated, no-join hardware
window.

The policy is the 2026-10-03 fused-baseline policy (`de99e85c…`) with only
these fields changed: `os_build`, `provider_commit`, `mlx_fork_revision`, and
`seed` (`20261006`). The tuple, matrix, block count, sustained window, and every
threshold are unchanged. Proposal depth stays 1.

Status: preregistered. No measurement result is claimed yet. Raw JSONL and
contamination logs stay on the lab host. Analysis and redacted evidence will
be added without modifying this policy.
