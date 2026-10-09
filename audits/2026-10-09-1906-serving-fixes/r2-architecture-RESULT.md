
## Round-1 disposition

| Round-1 finding | Status | Evidence |
|---|---|---|
| Old gateway before new coordinator mishandles capacity 429 | FIXED | `phase5-gateway/internal/router/chat_proxy.go:2533-2557`; coordinator falls back to legacy 503 at `phase4-coordinator/internal/buyer/server.go:7466-7474`. |
| New CLI depth rollback / v1 compatibility | FIXED | `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift:570-593`; legacy key remains ≤8, depth key carries >8; v1 decoder defaults the factor at `AutotuneConcurrencyCalibration.swift:113-146`. |
| Signed CB policy does not bind scheduler behavior | NOT FIXED | `ContinuousBatchingSignedPolicy.swift:16-22,276-329`; acceptance checks only model/runtime tuple at `ContinuousBatching.swift:152-179`. |
| Lab bench can leave provider paused | FIXED | `scripts/lab/cb-studio/bench.sh:16-20`; resume trap is armed immediately after pause. |
| CB receipt TTFT semantics | PARTIALLY FIXED | Normal non-streaming and streaming paths are corrected at `ModelRuntime.swift:6429-6462,6896-6943`; replay-owner semantics remain defective below. |
| Calibration used inferred decode start | FIXED | `AutotuneConcurrencyCalibration.swift:463-511`; visible first delta is used for TTFT. |
| Lower ready occupancy report could be ignored indefinitely | FIXED | `phase4-coordinator/internal/pool/provider.go:2846-2873,2968-2972,3197-3208`; one lower report is ignored, the next accepted. |
| Unset `LP` trap failure | FIXED | `scripts/lab/profile-serve-1906.sh:4,10-15`. |
| Stale live-slot reservation snapshots | FIXED | `slot_queue.go:126-180`; `pool/provider.go:1723-1738`. Remaining stale reconciliation paths were pre-existing. |
| SPEC-006 capacity-status contradiction | FIXED | `specs/SPEC-006-buyer-api.md:2842-2870`; canonical 429/503 version-skew table now exists. |
| Ragged offset spread | FIXED | `ContinuousBatchScheduler.swift:684-760`; cap is documented in `SPEC-038:540-567`. |
| CLI depth above coordinator default 8 | FIXED-BY-DESIGN | Served cap is 32 at `ProviderStatus.swift:181-187`; coordinator default remains 8 and clamps independently as specified. |
| Round-1 LOWs: requested-model message, `capacityRefused`, retry count, closed-loop refusal test, lower-report handling, v2 factor, SPEC-002 reference, R009 rationale, audit result artifacts | FIXED | Evidence includes `server.go:3919-3924`, `forward_with_failover.go:100-110`, `closed_loop_capacity_test.go:259-280`, `AutotuneConcurrencyCalibration.swift:42-60`, `specs/CONFORMANCE.json:2891-2939`, and the four `r1-*-RESULT.md` files. |

No Round-1 NEW CRITICAL finding existed.

## New or remaining findings

### HIGH — signed CB authorization does not bind the new runtime behavior

Files: `phase3-binary/Sources/macprovider-cli/ContinuousBatchingSignedPolicy.swift:16-22,276-329`; `ContinuousBatching.swift:152-179`; `specs/SPEC-038:9-34`; `specs/CONFORMANCE.json:4615-4640`

Status: NEW in this PR; Round-1 finding NOT FIXED.

A previously signed model/runtime tuple can authorize the new default-on ragged prefill path, 2048-token prefill budget, and scheduler behavior without binding any scheduler revision, ragged mode/spread cap, or prefill policy. During fleet rollout, a provider can therefore run newly changed CB behavior under old acceptance evidence. A bad ragged group can affect multiple buyer requests simultaneously, while operators may believe the signed policy still represents the qualified behavior.

Minimal fix: include scheduler revision, prefill budget, ragged enablement, and spread-cap policy in the signed tuple/hash, and require matching Studio acceptance evidence before accepting the tuple.

### MEDIUM — replay-owned streaming receipts can report the wrong TTFT

Files: `phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5460-5503`; `ModelRuntime.swift:6896-6905,6946-6958`; `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1405`; `InferenceRelay.swift:1096-1105`

Status: NEW residual defect; Round-1 receipt finding PARTIALLY FIXED.

If the original streaming settlement owner disconnects after the CB row completes, a replay waiter can become the new eligible settlement owner. Replay tokens intentionally do not mark `ContinuousBatchFirstTokenClock`; terminal replay then re-emits retained tokens through the unwrapped callback. The receipt path falls back to the replay request’s local elapsed time, rather than the canonical row’s original request-to-first-visible-token time.

Affected receipts remain cryptographically valid and verifier-compatible, but their `ttft_ms` is semantically wrong for settlement/SLA evidence.

Minimal fix: persist canonical first-visible timestamp/TTFT in the scheduler terminal result and reuse it for any replacement settlement owner. Never derive settlement TTFT from replay delivery time.

### LOW — SPEC-023-R011 conformance rationale still says the hard cap is 8

File: `specs/CONFORMANCE.json:2986-3002`

Status: NEW documentation/governance defect in this diff.

The active R011 rationale says “Hard cap remains 8,” while the same change set defines a served hard cap of 32 in `ProviderStatus.swift:181-187` and `SPEC-023:2827`. Operators or conformance tooling can incorrectly reject or under-report valid calibrated depths above 8.

Minimal fix: update R011 to say the tier default remains 8 while the served hard cap is 32.

## Explicitly checked with no new finding

- Capacity header is overwritten with `Header.Set` after forwarded buyer headers at `chat_proxy.go:680-717,2538-2548`; the buyer cannot spoof billing behavior.
- Every coordinator gateway path advertises the header; source coverage is enforced by `capacity_shed_capability_test.go`.
- Header negotiation changes response compatibility only; settlement still requires the no-prior-dispatch proof.
- Queue reservation and live-slot reads are serialized under the queue/pool lock order.
- Config precedence is conservative: YAML depth key, then environment, then explicit CLI; rollback preserves the legacy ≤8 key.
- Receipt verifier constraints remain satisfied; the remaining issue is timestamp semantics, not signature or field validation.
- Pre-existing exclusions remain excluded: `/v1/status`, calibration timeout, word/token probe counting, MSB release reachability, and the heartbeat timing flake.
- Permitted tests passed: `go test ./internal/buyer ./internal/pool` and `go test ./internal/router/...`. Swift tests/builds were not run per instruction.

VERDICT: 0C/1H/1M


