# SPEC-048 R015 on the step-overhead fork candidate, Studio build 26A434

This directory preregisters a new formal R015 run for the Qwen3.6 A3B
native-MTP tuple on the step-overhead fork candidate
`ca8c384c4fb6bc7d2fbb7c70a18c34b935701805` (SPEC-048 0.1.24, review pending).
The candidate adds a single-pass checkpointed GDN verify kernel and skips the
all-true SSM mask for unpadded packed verification; the provider folds the
drafter seed conversion into the round's staged evaluation. Ordinary decode
is unchanged from the 2026-10-06 run.

The frozen byte-exact `policy.json` has SHA-256
`0c1b42bec091ab762ba56c9c8d460b9cf2ddc74950f9d98aa59d0af7b290aa87`.
It binds the lab binary to provider commit
`006a34ba845f3a5b2d306eb77356f0d5f6e59a07` (campaign PR #1862). The binary is
built on the designated `Mac15,14` Studio with `-DMACPROVIDER_LAB_HARNESS` and
used only in an isolated, no-join hardware window.

The policy is the 2026-10-06 policy (`2c8a2344…`) with only
`provider_commit` and `mlx_fork_revision` changed. `os_build` stays `26A434`
(verified on the Studio before freezing), and the seed stays `20261006`, so
the preregistered run order matches the 2026-10-06 run. The tuple, matrix,
block count, sustained window, and every threshold are unchanged. Proposal
depth stays 1.

Status: preregistered. No measurement result is claimed yet. Raw JSONL and
contamination logs stay on the lab host. Analysis and redacted evidence will
be added without modifying this policy.
