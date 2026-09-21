# MoE promotion activation (SPEC-038 AC-23 / FR-CB16) — 2026-09-20

This is the activation PR the 2026-09-20 promotion review deferred.

**Set `ContinuousBatchingPolicy.productionMoEPromotionEvidenceAvailable = true`.**
Production `makeContinuousBatchScheduler` now passes that constant. Buyer
`continuous_batching` stays **off**. Do not canary. Do not raise slots. Do not
promote the fleet CLI. Live Studio `v1.8.171` does not include this flag;
the next signed candidate after this merge is what can canary.

Descriptor membership still does not promote a MoE tuple by itself. The
scheduler and policy keep the independent evidence gate; this change is the
explicit production signal that AC-23 evidence has landed.

## Evidence cited

| Item | Result | Where |
| --- | --- | --- |
| Representative AC-23 fixture | pass | `testSchedulerContractMoERowsFeedTheirOwnCurrentTokenAndTelemetryStaysPerRow` |
| Load-time MoE isolation probe | pass | `PagedKVRuntimeParityProbe` |
| Live MSB-04 (scheduler lockstep, 2/4 rows) | 1.44× / 1.94× serial | [`continuous-batching-scheduler-lockstep-window-evidence-2026-09-20.md`](continuous-batching-scheduler-lockstep-window-evidence-2026-09-20.md) |
| Packaged 171 leftovers | isolation/replay/drain/MSB-03 pass; MSB-05 0.73× and temp-0 idx 9 recorded | [`continuous-batching-packaged-171-leftovers-evidence-2026-09-20.md`](continuous-batching-packaged-171-leftovers-evidence-2026-09-20.md) |
| Promotion review (flag stayed false) | this PR is the follow-up it named | [`continuous-batching-moe-promotion-review-2026-09-20.md`](continuous-batching-moe-promotion-review-2026-09-20.md) |

MSB-05 native-parallel 0.73× and FR-CB6 temp-0 divergence at token 9 are
recorded, not blockers for this gate. They do not leak across rows.

## What this does not do

- Does not set buyer `continuous_batching` to `canary` or `on`.
- Does not raise `max_concurrency_override` (Studio stays at 4).
- Does not treat `msb-throughput`'s measurement-seam `true` as the production
  policy. Production serve uses `ContinuousBatchingPolicy.productionMoEPromotionEvidenceAvailable`.
- Does not put the flag onto live 171. Canary waits for the next packaged RC.

## Next

Cut the next acceptance candidate off the merge (it will also include
#1648), swap Studio onto it, then operator-canary CB on that package only.

2026-09-20: 172 is live. Operator-canary on Studio entered the attached
scheduler and 503'd `continuous_batching_prefill_failed`; config rolled back
to off. See
[`continuous-batching-canary-172-enable-2026-09-20.md`](continuous-batching-canary-172-enable-2026-09-20.md).
