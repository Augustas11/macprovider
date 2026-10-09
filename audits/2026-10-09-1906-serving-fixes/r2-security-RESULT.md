
Read-only Round 2 audit complete. No files were modified. I reviewed the merge-base diff, Round 1 results, and all five fix commits. No Swift builds/tests or network operations were run; Round 1 records show targeted Go tests passed.

### Round 1 dispositions

- **HIGH — version-skew 429 settlement:** **FIXED** — coordinator header gating in `phase4-coordinator/internal/buyer/server.go:416-420,2468-2494`; gateway advertises it on every chat path at `phase5-gateway/internal/router/chat_proxy.go:716-717`, `relay_blind_success.go:301-302`, and `server.go:403-404`. Client copies are excluded by `copyForwardHeaders` at `chat_proxy.go:4573-4582`; response copies strip `X-MacProvider-*` at `server.go:1675-1729`.

- **HIGH — rollback to old CLI breaks calibrated config/state:** **FIXED** — rollback-safe keys in `phase3-binary/Sources/MacProviderCore/Config.swift:180-188,837-842`; precedence remains CLI > environment > YAML, covered at `ServingKnobsConfigTests.swift:279-304`; config writes legacy `8` plus the extended key at `ConfigApplier.swift:588-593`. v1 calibration decoding is restored at `AutotuneConcurrencyCalibration.swift:42-60,113-135`.

- **HIGH — signed CB policy does not bind scheduler behavior:** **NOT FIXED** — policy identity still omits scheduler revision, ragged capability, and prefill budget at `ContinuousBatchingSignedPolicy.swift:173-195,276-287`; runtime enables the new behavior at `ModelRuntime.swift:4562-4669`. The default-on operator decision is respected, but it does not solve the authorization-binding gap. This remains a current HIGH finding below.

- **HIGH — bench pause trap can leave the live provider paused:** **FIXED** — `scripts/lab/cb-studio/bench.sh:16-20`.

- **MEDIUM — stale slot snapshots / incomplete live-slot accounting:** **FIXED** — queue reservations now query live routable slots under the queue lock at `slot_queue.go:126-204`; pinned and queued paths use live callbacks at `server.go:8047-8084,9160-9188`; relay-blind/private paths do likewise at `relay_blind.go:404-478,512-545`.

- **MEDIUM — calibrated depth above eight is not routable by default:** **PARTIALLY FIXED** — provider bound and rollback handling are fixed, and the clamp is documented at `ProviderStatus.swift:181-187`, `config.go:819-839,1699`, and `CONFORMANCE.json:2938`. Pearl still clamps all advertisements to eight at `ws/server.go:6073-6083,6171-6188,6687-6750`. This remains a current MEDIUM finding below.

- **MEDIUM — replay-derived signed TTFT:** **FIXED** — first buyer-visible chunk timing is used at `ModelRuntime.swift:6880-6905,6933-6943`; replay rows are marked non-settling at `ContinuousBatchScheduler.swift:2399-2403,5466-5495` and excluded from receipts at `InferenceRelay.swift:1241-1247`.

- **MEDIUM — sparse-output calibration inferred TTFT incorrectly:** **FIXED** — visible TTFT now uses the first streamed delta at `AutotuneConcurrencyCalibration.swift:467-469,501-507`; inferred decode start is used only for throughput.

- **MEDIUM — lower ready report ignored indefinitely:** **FIXED** — only one lower report is ignored, then the next applies at `pool/provider.go:2864-2869`.

- **MEDIUM — ragged prefill offset spread:** **FIXED** — spread cap at `ContinuousBatchScheduler.swift:684-759`; row-local masks and offsets remain isolated at `PagedKVRuntimeBridge.swift:3439-3459,4089-4097`.

- **MEDIUM — contradictory SPEC-006 capacity statuses:** **FIXED** — canonical status table and version-skew rules are now at `specs/SPEC-006-buyer-api.md:2842-2865`.

- **LOW — closed-loop test did not exercise refusal:** **FIXED** — deterministic refusal injection and assertion at `closed_loop_capacity_test.go:215,269-279`.

- **LOWs — stale spec revision, stale 8-slot rationale, wrong capacity message, sticky `capacityRefused`, missing v2 compatibility field:** **FIXED** at `SPEC-002-coordinator.md:3-12`, `CONFORMANCE.json:2938`, `server.go:3919-3923`, `forward_with_failover.go:100-110`, and `AutotuneConcurrencyCalibration.swift:47-60,113-145`.

### Current findings

1. **HIGH — NEW — signed CB policy does not authorize the new decode behavior**

   Where: `phase3-binary/Sources/macprovider-cli/ContinuousBatchingSignedPolicy.swift:173-195,276-287`; runtime behavior at `ModelRuntime.swift:4562-4669`.

   A tuple previously authorized for a model/backend can activate the new ragged-prefill path and 2048-token budget without a new signed policy identity or behavior-specific acceptance evidence. If mixed-row execution has a latent failure or latency regression, live buyers receive batch-wide failures or degraded TTFT under an authorization that only covered the older scheduler behavior.

   Minimal fix: bind scheduler revision, ragged capability, prefill budget, and spread-cap version into the signed tuple, or require a new signed policy entry and acceptance evidence for this behavior.

2. **MEDIUM — NEW — calibrated concurrency above eight is silently ineffective in Pearl**

   Where: `ProviderStatus.swift:181-187`; `config.go:819-839,1699`; `ws/server.go:6073-6083,6171-6188,6687-6750`.

   An opt-in calibration may persist and locally serve depth 16/24/32, while the deployed coordinator advertises and routes only eight slots. Operators can believe calibration increased fleet capacity while buyer routing and capacity metrics remain capped, causing rollout underperformance and misleading provider capacity reporting. The clamp prevents over-admission, so this is not a money-loss issue.

   Minimal fix: either raise the coordinator ceiling for an explicitly approved calibrated cohort or cap/surface the provider’s effective advertised depth to the coordinator ceiling.

3. **LOW — NEW — internal queue-full waits inflate retry telemetry**

   Where: `forward_with_failover.go:264-271`; `server.go:3795-3813,9373-9392`.

   A provider `error_queue_full` refusal can requeue the same buyer request while another request is still in flight, but the shared advance path increments `explicitRetries`. Operators and `request_log.retried` therefore count coordinator-internal capacity waits as buyer/provider retries, obscuring retry amplification and potentially consuming retry accounting on non-client actions.

   Minimal fix: maintain a separate internal queue-wait counter and exclude same-provider queue holds from buyer retry metrics.

No additional NEW billing/refund, header-spoofing, retry-classification, privacy downgrade, receipt-verifier, lower-seat, ragged-isolation, trace-disclosure, or release-build lab-path defect was found. The explicitly excluded pre-existing issues remain excluded.

VERDICT: 0C/1H/1M


