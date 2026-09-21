# MoE promotion review (SPEC-038 AC-23 / FR-CB16) — 2026-09-20

Separately reviewed activation decision for `moePromotionEvidenceUnavailable`.
This is **not** a buyer-canary enable, a slot raise, or a packaged RC.

Buyer `continuous_batching` stays **off**. Live v1.8.170 stays at 4 slots. Do
not canary 170.

## Decision

**Superseded 2026-09-20:** production activation is
[`continuous-batching-moe-activation-2026-09-20.md`](continuous-batching-moe-activation-2026-09-20.md).
This review kept the flag false until leftovers and packaged 171 evidence
landed.

**Do not set `moePromotionEvidenceAvailable = true` on the production
`ModelRuntime` scheduler in this change.**

The throughput half of AC-23 is now measured. The correctness fixture exists.
The remaining blockers are packaged-RC activation evidence, not a missing MoE
isolation test.

Descriptor membership still does not promote a MoE tuple. Production
`ContinuousBatchingPolicy` keeps fail-closing Qwen3-Coder with
`.moePromotionEvidenceUnavailable` until a later PR that is explicitly the
activation change.

## What AC-23 requires

SPEC-038 AC-23 (FR-CB16, FR-CB14):

- batched decode feeds each MoE row its **own current token** into the shared
  `[B, 1]` forward
- per-row expert-affected outputs, load-balancing telemetry, stop/cancel
  lifecycle, output-token accounting, and receipt state stay request-isolated
- live-model **MSB-04** aggregate-TG is measured on the catalog MoE tuple
- until both land, the tuple stays unsupported for continuous batching

## Correctness fixture

Already on `main`:

- `testSchedulerContractMoERowsFeedTheirOwnCurrentTokenAndTelemetryStaysPerRow`
  in `ContinuousBatchSchedulerTests.swift` — scripted backend, two MoE rows,
  each row's current token is the only token that row's decode input carries,
  telemetry stays per-request
- load-time `PagedKVRuntimeParityProbe` MoE isolation probe
  (`testMoEDispatchGateRequiresGenuinelyProvenSharedForwardIsolation`)
- real-model isolation (env-gated): `PagedKVParityTests` batched shared-forward
  input isolation

These are the representative AC-23 fixtures. They do not by themselves open
buyer traffic.

## Live MSB-04

Measured 2026-09-20 on Mac Studio M3 Ultra 256 GB, catalog
`mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`,
`msb-throughput --engine scheduler --compile` (serve-path scheduler,
`decodeLockstepWindow`, buyer CB off):

| Rows | vs production serial `generate()` | Gate |
| ---: | ---: | --- |
| 2 | **1.44×** | MSB-04 pass (>1.3×) |
| 4 | **1.94×** | MSB-02 pass (>1.5×) |

Evidence:
[`continuous-batching-scheduler-lockstep-window-evidence-2026-09-20.md`](continuous-batching-scheduler-lockstep-window-evidence-2026-09-20.md).

The failed 0.40–0.53× paged-gather path is obsolete for this decision. The
compiled lockstep scheduler path is the one that counts.

## Why the production flag still stays false

1. **Packaged RC.** Enable-gate package identity is still v1.8.170 with CB
   off. Worktree `msb-throughput` is not a packaged runtime.
2. **Durable replay.** `ContinuousBatchRuntimeReplayAuthority` in-process stub
   is explicitly not activation evidence. HTTPServer settlement already gates
   on `.eligibleOwner`; the stub does not satisfy the relay-identity wiring
   required to canary.
3. **FR-CB15 leftovers.** MSB-03 ragged, MSB-05 native-parallel Q1, temp-0
   parity, and serve-path usage/isolation/drain still need a recorded
   hardware bundle (`msb-throughput --scenario leftovers|msb03|msb05`). Those
   measurements do not require flipping MoE promotion.
4. **Buyer surface.** Canary on Qwen would take the CB path the moment the
   flag is true. That is the activation change, and it is out of scope here.

## What a later activation PR must contain

A follow-up that sets `moePromotionEvidenceAvailable: true` in production
`makeContinuousBatchScheduler` must:

- cite this review plus the leftover evidence bundle
- keep buyer default `off` until the packaged-RC canary step
- not raise 170 slots
- not treat MSB harness `moePromotionEvidenceAvailable: true` (measurement
  seam) as the production policy

Until that PR, Qwen3-Coder remains `.moePromotionEvidenceUnavailable` on the
buyer/serve capability gate.
