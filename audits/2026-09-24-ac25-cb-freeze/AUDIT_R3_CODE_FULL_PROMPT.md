# Freeze audit round 3 — #1716 after folding #1731 (Qwen3.6 hybrid-cache CB)

Method constraint: first-party software-correctness review. Read source and
run EXISTING tests only. Do NOT construct malformed payloads; describe gaps
abstractly in prose.

Worktree `/Users/augstar/macprovider-ac25-m2`, branch
`campaign/ac25-m2-api-lifecycle`. Everything up to `6f75c3a1` passed a
three-lane audit (0/0/0, `audits/2026-09-24-ac25-cb-freeze/`). Review the
full diff `git diff origin/main...HEAD` with focus on what is new since
`6f75c3a1`:

- `422a83a7` merge of #1731 (commits `46df88d9`, `e38840a5`): Qwen3.6-27B
  (`Qwen3_5ForConditionalGeneration`) hybrid cache: `PagedKVCache` for the 16
  full-attention layers, row-local `MambaCache` for the 48 linear-attention
  layers (`PagedKVSharedLayerBatch`, `packMambaRows`, `syncMambaRows`),
  first-turn only (retained hybrid handoff throws; no contiguous-cache bridge
  for hybrid), hybrid isolation probe with leave/rejoin,
  `RuntimeContinuousBatchingSnapshot` in `/v1/status`, `event=batching_admitted`,
  SPEC-039 exception text, MSB harness mixed topology. Merge resolution:
  `compiledDecode: false` for every layout.
- `87ba9771` isolation probe tries ordered challenge prompt pairs and stops at
  the first `challengeDistinguishing` pair.

Interactions to check: this branch's earlier fixes on the same code
(`packFromRows`/`syncRowsFromBatch` ragged-row fix, EOS stop/usage trim,
drain race, lazy record) combined with the hybrid path; Mamba row state across
leave/join/ragged rows (`syncMambaRows` sets row `offset = batch.offset`);
cancellation/cleanup for hybrid rows (paged handle lookup via
`pagedAttentionCaches`).

Studio evidence (lab, `--no-join`): Qwen3.6 parity established (16 layers),
isolation proven with pair 2, attach + scheduler admission confirmed; batched
output matches serial exactly in 13/14 concurrent rows at N=2/4/8 (one late
tolerance divergence), 1024-token rows complete, zero forward failures.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Findings with file:line, concrete failure
scenario, fix. Do not manufacture findings. End with `VERDICT: PASS` or
`VERDICT: FAIL (C/H/M counts)`.
## Lane: CODE — correctness, concurrency, tests.
Hunt: Mamba state corruption when rows join/leave or are ragged; the probe
loop (can a non-distinguishing pair's result leak into the verdict; is the
distinguishing requirement ever bypassed); status snapshot actor/concurrency
safety; tests that would not fail on a real regression.
