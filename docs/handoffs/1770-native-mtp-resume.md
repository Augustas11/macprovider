# Handoff: #1770 native MTP fused-baseline campaign

Resume the production-evidence campaign in draft PR #1832 on branch
`campaign/native-mtp-formal`. Read `AGENTS.md`, `CLAUDE.md`, the PR body, and
SPEC-048 / SPEC-023 R024 before changing the campaign.

Native MTP is implemented and remains **default-off**. A private,
non-promotable acceptance candidate is signed and notarized. Nothing in this
campaign is released, deployed, or activated.

## Current state

| Item | Revision / location | Status |
| --- | --- | --- |
| MacProvider campaign | PR #1832, `campaign/native-mtp-formal` | Draft; do not merge yet |
| Fused upstream baseline | `Augustas11/mlx-swift-lm@b181102984a4d1875efbd9e0eab3a7dfd1c012c5` | Chunked fused envelope plus tensor-layout validation (SPEC-048 0.1.23); R003 exception approved 2026-10-05 for the ordinary path; fused R015 `de99e85c` FAILED 10-03, native MTP default-off |
| Fused MacProvider pin | `3600d7b9f` | Exact pin and fused qualification requirements committed |
| SwiftPM release lock | `618dbe2d5` | Xcode 16.4 transitive pins restored; fused upstream revision preserved |
| Operator-pause fix | `0e5e63b0c` | Targeted test passes; published signed CLI needed for live validation |
| Private acceptance candidate | `v1.8.212`, workflow run `37075501296`, candidate `d806dcf203a94f813aadbe458c8de578be476bd0`, control `dac2ab8df6d1acd7bf54df61b2a604ac609780a4` | PASS; Developer ID signed, Apple notarized, stapled, and exported as a private `promotion_ready=false` artifact expiring `2026-10-03T23:42:32Z` |
| Post-gateway replay analyzer | `e2a5b51fc` | Exact R004 mix semantics and frozen corrected gates; capture/replay pending |
| Governance versions | `bfbdc0d94` | SPEC-023 v0.22.7 and SPEC-048 0.1.22 reconciled in `CONFORMANCE.json` |
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
The signed private candidate contains that fix, but it is not a published
release and therefore cannot replace or connect as the live Malibu provider.
Never stop or replace the live provider with it, and never connect a local,
unsigned, ad-hoc-signed, or unreleased build to Malibu.

The first private-candidate attempt used the exact campaign SHA
`40b630905246ea49109d1458d48a1b5db3b0379d` with `promotion_ready=false`.
Its unprivileged build passed, but Apple notarization returned HTTP 403 because
a required Apple Developer agreement is missing or expired. The workflow did
not export a signed candidate and did not create a tag or release. Because the
campaign subsequently merged current `origin/main`, any retry must bind the
new reviewed branch head rather than the failed candidate SHA.

The Account Holder restored the agreement on 2026-10-03. Replacement run
`37075501296` passed the unsigned build, independent protected-environment
approval, Developer ID signing, notarization, stapling, acceptance-envelope
signing, and private export. The downloaded artifact passed
`verify-release-checksums.sh` against run `37075501296/1`; every checksum also
passed on `1deMac-Studio.local`, and the embedded CLI passed strict code-sign
verification for team `YF7XNRJUG4`.

The next guarded Studio attempt again failed closed before any build or
hardware workload. The live provider remains the published, Developer-ID-
signed `v1.8.207`. The shared wrapper received
`pause_ack accepted=false, reason=lifecycle_state_persistence_failed` from that
old process. The exact fused source archive was staged separately on the Studio
and verified at `d806dcf` with the `ca29e954...` upstream pin, but its lab build
did not start. The live provider was not stopped, replaced, or modified.

## Resume order

1. Land and publish the reviewed lifecycle pause fix through an allowed release
   path, update the Studio's live provider to that published build, and validate
   the guarded pause/resume path through the shared wrapper. Do not install the
   private acceptance candidate into the live provider.
2. Run the fused upstream runtime tests on the designated Mac Studio.
3. Freeze a new fused-baseline R015 policy and run the right-sized matrix plus
   sustained window. Preserve every failed or incomplete cell.
4. Finish the serving journey gaps: EOS/post-output failure, committed
   cache-state digest, proposal/verify/commit boundary cancellations,
   deterministic mixed batch, warm swap, accounting, self-test, isolated
   coordinator canary, and redaction.
5. Privacy-review and preregister the representative post-gateway sample,
   capture/replay it on the Studio, and validate the evidence with
   `scripts/native_mtp_post_gateway_replay_analyze.py`. The analyzer requires
   the exact pre-capacity R004 conversation-key state, at least 10% eligible
   requests and completion tokens, and the frozen paired ordinary-row bounds.
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
- Post-gateway replay analyzer suite: 19 tests PASS, including closed selector
  reasons, conversation-key semantics, privacy/schema rejection, fixed
  eligibility floors, paired-block integrity, and frozen corrected bounds.
- SwiftPM lock contract: PASS locally; the exact Xcode 16.4 locked-resolution
  job passed on parent head `e2a5b51fc` before the governance-only follow-up.
- PR governance declaration: PASS.
- Full CI passed on `40b630905` in run `37002887994`, including the Malibu app
  suite after an unrelated timing flake passed on rerun. The later merge from
  `origin/main` requires its own GitHub Actions result; do not reproduce it
  locally on `Augustas-Air.local`.

The prior full-diff audits predate the fused-baseline, scheduler-fence, and
lifecycle changes. They are historical evidence only; run all three lanes
again after the hardware and journey freeze.
