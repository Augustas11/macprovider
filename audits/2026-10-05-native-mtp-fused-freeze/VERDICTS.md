# Fused-pin freeze audit verdicts (2026-10-05)

Codex ran three lanes (`omc ask codex`) over the complete PR #1832 diff
(`git diff origin/main...HEAD`, with origin/main merged in) and the pinned
fork diff `ef4ff856..<pin>` in `Augustas11/mlx-swift-lm`. Prompts:
`COMMON.md` plus `FOCUS_<lane>.md`; per-round prompts and final responses in
`r1/` and `r2/`.

| Lane | Round 1 (HEAD `7f02d49a0`, fork `9c1cd900`) | Round 2 (HEAD `7d55924eb`, fork `b1811029`) |
| --- | --- | --- |
| security | 0/0/1/0 | **0/0/0/0** |
| code | 0/0/1/0 | **0/0/0/0** |
| architecture | 0/0/1/0 | **0/0/0/1** |

Counts are CRITICAL/HIGH/MEDIUM/LOW. Gate (0 Critical, High, Medium in every
lane) met in round 2; all three lanes marked every round-1 finding VERIFIED.

## Round 1 findings and fixes

- **Security MEDIUM (fork):** `Qwen35FusedMoE.resolve` checked a few weight
  dimensions but not the packed-weight dtypes or the scale and bias shapes the
  kernels index. Fork `b1811029` requires uint32 packed weights and bf16
  scales and biases with the exact kernel-indexed shapes for every tensor; any
  mismatch keeps the block on stock. Test
  `testMismatchedQuantizedLayoutIsNotFusable`; Studio harness 133/133.
- **Architecture MEDIUM:** R024 allowed `proposal_depth` up to 16, so a
  native verification row (`depth + 1` tokens) could leave the seven-token
  fused envelope and cross kernels as the scheduler reduced depth. R024
  `proposal_depth` and the MTP manifest's `max_proposal_depth` and
  `adaptation_max_depth` are capped at 6 in the Swift consumer and the Python
  generator (SPEC-023 v0.22.11, SPEC-048 0.1.23), with tests in both.
- **Code MEDIUM:** the watch generator hard-coded
  `native_mtp_public_row_mapped_transactions_reviewed: true` (main derives it
  from the exception approval). Restored the derivation; the snapshot carries
  `false` while the exception is pending.

## Round 2 LOW (fixed after round 2, not re-audited)

- **Architecture LOW:** the watch generator still emitted the older fused
  scope and review-status strings. The generator now emits exactly the
  committed `UPSTREAM_WATCH.json` note, `review_status`, and `scope`.
