# Handoff: #1770 native MTP fused-baseline campaign

Resume the production-evidence campaign in draft PR #1832 on branch
`campaign/native-mtp-formal`. Read `AGENTS.md`, `CLAUDE.md`, the PR body, and
SPEC-048 / SPEC-023 R024 before changing the campaign.

Native MTP is implemented and remains **default-off**. Nothing in this
campaign is signed, released, deployed, or activated.

## Current state

| Item | Revision / location | Status |
| --- | --- | --- |
| MacProvider campaign | PR #1832, `campaign/native-mtp-formal` | Draft; do not merge yet |
| Fused upstream baseline | `Augustas11/mlx-swift-lm@ca29e9544777068a0b53aad87310ff1cfaf3fd1d` | Pushed production candidate; Studio validation pending |
| Fused MacProvider pin | `3600d7b9f` | Exact pin and fused qualification requirements committed |
| Operator-pause fix | `0e5e63b0c` | Targeted test passes; reviewed signed CLI needed for live validation |
| Historical stock R015 | policy `30934c07e5b6ca6dfa569505bbfdb2fd118be719cba81ddf99193a4ebe72d581` | PASS, preserved, superseded for fused authorization |
| Serving journey | `NativeMTPJourneyE2ECommand.swift` | Incomplete; deterministic step-07 harness committed |

Do **not** rebase the campaign branch. Its preserved stock R015 policy binds
historical provider commit `cb708b58c`. New fused evidence must use a new
policy and run while the historical evidence remains immutable.

## Fused baseline contract

The Qwen3.6 A3B fused MoE path:

- applies only to flattened token counts 1...7;
- is default-on inside that exact envelope;
- falls back to the stock path at 8 or more tokens;
- has the `MLX_LM_QWEN35_FUSED_MOE=0` kill switch;
- preserves expert ordering and handles near-tie bf16 routing explicitly;
- is part of the KV/build identity and therefore invalidates the old stock
  R015 authorization evidence.

The candidate remains `approved:false` in `UPSTREAM_WATCH.json` until Studio
runtime validation, fresh R015, the complete serving journey, and freeze
audits all pass.

## Current hardware blocker

The first fused Studio attempt stopped before any hardware workload ran. The
released provider drained from the coordinator, entered
`coordinator_unavailable`, and then rejected the operator transition to
`paused_by_operator`.

Commit `0e5e63b0c` allows operator pause from `network_offline` and
`coordinator_unavailable`; its focused regression test passes for both states.
Do not retry the hardware campaign until a reviewed, signed CLI containing
that fix is installed. Never stop or replace the live provider, and never
connect a local, unsigned, ad-hoc-signed, or unreleased build to Malibu.

## Resume order

1. Obtain the reviewed signed CLI containing the pause fix and validate the
   guarded pause/resume path through the shared Studio wrapper.
2. Run the fused upstream runtime tests on the designated Mac Studio.
3. Freeze a new fused-baseline R015 policy and run the right-sized matrix plus
   sustained window. Preserve every failed or incomplete cell.
4. Finish the serving journey gaps: EOS/post-output failure, committed
   cache-state digest, proposal/verify/commit boundary cancellations,
   deterministic mixed batch, warm swap, accounting, self-test, isolated
   coordinator canary, and redaction.
5. Run the representative post-gateway eligibility replay, including the
   required eligible request and completion-token share.
6. Freeze the full diff and run fresh code, security, and architecture audits.
   The final gate is 0 Critical, 0 High, and 0 Medium findings.
7. The operator signs the R024 sidecar, challenge bank, and serving journey.
8. Cut and verify one signed release candidate; then run the release journey,
   SPEC-048-R014 revalidation, and controlled activation.
9. Qualify MXFP8 independently or move its remaining scope to a dedicated
   tracked issue before closing #1770.

## Studio boundary

- Designated host: `1deMac-Studio.local` via `ssh macstudio`, user `a1`.
- Shared wrapper: `/Users/a1/lab-cb-sampling/bench.sh`.
- Atomic lock: `/Users/a1/.lab-window.lock`.
- Fused upstream tree: `/Users/a1/mlx-swift-lm-a3b-prod/`.
- Formal build/evidence tree: `/Users/a1/macprovider-mtp-formal` and the
  existing `~/mtp-r015-*` / `~/mtp-journey-a3b` evidence directories.
- Hardware acceptance, performance, and release verification run only on the
  designated Studio. The operator Air is limited to targeted checks.

The wrapper-owned operator pause/resume is the only permitted live mutation.
If the host identity, lock ownership, binary provenance, or coordinator target
cannot be established, fail closed and leave the hardware run pending.

## Verified on the current campaign head

- Deterministic batch-composition scheduler test: PASS.
- Operator pause-after-disconnect lifecycle test: PASS for both predecessor
  states.
- Upstream watcher suite: 19 tests PASS; live comparison unchanged with remote
  revision and pin verified.
- PR governance declaration: PASS.
- Full CI for the latest head remains a GitHub Actions gate; do not reproduce
  it locally on `Augustas-Air.local`.

The prior full-diff audits predate the fused-baseline, scheduler-fence, and
lifecycle changes. They are historical evidence only; run all three lanes
again after the hardware and journey freeze.
