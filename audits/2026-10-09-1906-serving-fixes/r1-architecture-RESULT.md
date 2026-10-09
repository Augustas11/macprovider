
Result: changes required before merge. No CRITICAL findings; four NEW HIGH and four NEW MEDIUM findings.

- HIGH — NEW — `phase5-gateway/internal/router/chat_proxy.go:1071-1074`  
  A new coordinator deployed before the old gateway returns capacity `429`, but the old gateway does not recognize it and falls into the generic upstream-error path (`502` plus normal settlement handling). Public/wholesale buyers can see the wrong contract and be charged an estimate instead of receiving the 429/no-dispatch refund. Fix by deploying gateway-first with enforced rollback order, or make the old gateway recognize this 429 envelope.

- HIGH — NEW — `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:181-187`; `AutotuneCommand.swift:1365-1378`; `ConfigApplier.swift:586-589`  
  A new CLI can persist a calibrated `max_concurrency_override` above 8. Rolling back to an old CLI rejects that retained config at startup (`<= 8`), taking the provider offline; old binaries also cannot decode the new v2 calibration record because `ttft_regression_factor` is absent. Fix with a rollback-compatible config/state migration or a bridge release that clamps persisted values to 8.

- HIGH — NEW — `ContinuousBatchScheduler.swift:282`; `ModelRuntime.swift:4579-4585,4656-4657`; `ContinuousBatchingSignedPolicy.swift:276-287`; `scripts/ops/cli-release.sh:396-406`  
  The signed CB policy binds model/backend identity, but not scheduler revision, ragged-prefill capability, or the 2048-token budget. An already-authorized tuple can therefore silently gain the new scheduler behavior without packaged multi-row evidence. `SPEC-038-R002` remains pending with no journey/evidence (`specs/CONFORMANCE.json:4610-4668`). A live buyer may get row-local failures, wrong output, or TTFT regressions. Fix by binding these behavior dimensions to policy and requiring a dedicated multi-row canary, or retain the old defaults until evidence exists.

- HIGH — NEW — `scripts/lab/cb-studio/bench.sh:16-27`  
  The script pauses the live provider before installing its exit/signal traps. A drain timeout or interrupt leaves the live provider paused, causing a production capacity outage. Fix by installing traps immediately after a successful pause and explicitly resuming before timeout exits.

- MEDIUM — NEW — `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:142-160,6416-6452,6870-6889`; `InferenceRelay.swift:1096-1100`  
  CB receipts use the first scheduler token as `ttft_ms`. For non-streaming receipts, SPEC-015 requires full generation latency; streaming can mark before filtering, cancellation, UTF-8 buffering, or buyer-visible delivery. Signatures validate, but semantic TTFT is wrong. Fix non-streaming receipts to use full generation latency and mark streaming TTFT only at the first emitted buyer-visible byte.

- MEDIUM — NEW — `AutotuneConcurrencyCalibration.swift:475-490,844-885`  
  Sparse-output fallback infers decode start as `end - usageGenerationMS`, which is not buyer-visible TTFT. Hidden/suppressed work can therefore make an 11-second first visible response appear to have 2-second TTFT and select an unsafe depth. Fix by measuring the first buyer-visible delta directly; use inferred decode start only for throughput accounting.

- MEDIUM — NEW — `phase4-coordinator/internal/pool/provider.go:2848-2863`  
  `awaitingReadyOccupancy` can remain set indefinitely when every subsequent ready report is lower than the coordinator-owned count. A genuine lower-capacity report can be ignored forever, causing over-admission followed by provider queue-full responses and avoidable buyer 429s. Fix with an occupancy epoch/freshness bound or make the ignore behavior one-shot until the next authoritative report.

- MEDIUM — NEW — `scripts/lab/cb-studio/profile-serve-1906.sh:4,13,18`  
  With `set -u`, the exit trap expands `$LP` before it is initialized. An early interrupt can abort cleanup and leave the isolated serve process running, consuming the Studio port/GPU. Initialize `LP=` before installing the trap and use `${LP:-}`.

- LOW — NEW — `specs/SPEC-002-coordinator.md:7`; `specs/CONFORMANCE.json:6176`  
  The new capacity-shed text references SPEC-006 v0.9.48 even though the normative revision is v0.9.49. Fix the revision references.

- LOW — NEW — `specs/CONFORMANCE.json:2891-2933`  
  R009’s rationale still describes the hard bound as 8 while SPEC-023 v0.22.17 and the implementation use 32. Update the conformance rationale and bound.

- LOW — NEW — `audits/2026-10-09-1906-serving-fixes/r1-architecture.md:1`; `r1-code.md:1`; `r1-security.md:1`  
  The committed audit artifacts are scopes/prompts, not completed three-lane results. This weakens the repository’s required release audit gate. Replace them with evidence-backed findings before treating the PR as audited.

Retained/pre-existing issues:

- MEDIUM — PRE-EXISTING — `phase4-coordinator/internal/buyer/server.go:9129`; `slot_queue.go:184-205`  
  Queued reservation still uses a stale `SlotsFree` snapshot rather than `RoutableSlotsFree`, leaving a TOCTOU over-dispatch path. Add a live revalidation/atomic reservation test.

- MEDIUM — PRE-EXISTING — `phase4-coordinator/internal/buyer/relay_blind.go:429,474`  
  Relay-blind selection still reserves against stale slot snapshots. Use the live reservation primitive.

- MEDIUM — PRE-EXISTING — `AutotuneConcurrencyCalibration.swift:795-800`  
  `probe_prompt_tokens` counts words, not actual chat-template tokens, so the calibration shape is not guaranteed to match its recorded token count.

Validation: targeted coordinator buyer/pool Go tests and gateway capacity-shed Go tests passed. No Swift build/test or network operation was run.

VERDICT: 0C/4H/4M


