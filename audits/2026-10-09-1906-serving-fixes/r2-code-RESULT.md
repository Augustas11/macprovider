
Audit completed read-only. Targeted Go tests passed:

- `go test ./internal/buyer ./internal/pool`
- `go test ./internal/router/...`

No Swift builds/tests or network access used.

Round-1 disposition:

- HIGH stale slot snapshots — **FIXED**: live callbacks now cover direct, queued, pinned, private, and relay-blind paths (`phase4-coordinator/internal/buyer/slot_queue.go:126-235`, `server.go:8068-8084`).
- MEDIUM contradictory SPEC-006 status rules — **FIXED**: canonical table and version-skew behavior at `specs/SPEC-006-buyer-api.md:2842-2865`.
- HIGH coordinator-ahead-of-gateway 429 skew — **FIXED**: capability header negotiation and legacy fallback (`phase4-coordinator/internal/buyer/server.go:2491-2494,7470-7474`; `phase5-gateway/internal/router/chat_proxy.go:716-717`).
- HIGH rollback-incompatible depth/v2 calibration — **FIXED**: safe value remains ≤8 while depth is carried separately; v1 decoder compatibility restored (`ConfigApplier.swift:588-593,695-708`; `Config.swift:837-842`; `AutotuneConcurrencyCalibration.swift:118-146`).
- HIGH signed CB policy does not bind scheduler behavior — **NOT FIXED**.
- HIGH lab bench pause cleanup — **FIXED**: traps installed immediately (`scripts/lab/cb-studio/bench.sh:16-20`).
- MEDIUM CB TTFT semantics — **PARTIALLY FIXED**: non-streaming and runtime clock are correct (`ModelRuntime.swift:6460-6462,6880-6905,6942`), but relay receipts still hardcode zero.
- MEDIUM sparse calibration TTFT fallback — **FIXED** (`AutotuneConcurrencyCalibration.swift:491-511`).
- MEDIUM lower ready-seat report — **FIXED**: one lower report is ignored, the next is applied (`pool/provider.go:2846-2873`).
- MEDIUM profile cleanup trap — **FIXED** (`scripts/lab/cb-studio/profile-serve-1906.sh:10-15`).
- MEDIUM live-slot reservation coverage — **FIXED**; queue/pool locking and atomic consume/release are covered by the passing Go tests.
- MEDIUM calibrated depth above the coordinator’s default 8 — **PARTIALLY FIXED**: provider bound is 32, but Pearl still safely clamps advertised capacity to 8 (`ProviderStatus.swift:181-187`; `config.go:819-839,1695-1700`). This remains an operational rollout limitation.
- MEDIUM ragged offset spread — **FIXED**: factor-2 cap enforced (`ContinuousBatchScheduler.swift:684-759`).
- MEDIUM capacity-429 overcharge/version-skew path — **FIXED**: gateway strips client copies, overwrites the header, and conservatively settles unmarked responses (`chat_proxy.go:716-717,2123-2143`).
- Fixed LOWs: closed-loop refusal assertion (`closed_loop_capacity_test.go:215,257-276`), requested-model error text (`server.go:3919-3923`), per-attempt `capacityRefused` reset (`forward_with_failover.go:105-111`), v2 factor preservation, stale spec references, R009 bound rationale, and completed audit-result artifacts.

Findings:

1. **HIGH — NEW — NOT FIXED**  
   `phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:83-95,165-179`; `ContinuousBatchingSignedPolicy.swift:276-287`

   Signed CB acceptance binds model, artifact, KV, hardware, Metal library, and kernel identity, but not scheduler revision, ragged-prefill behavior, spread cap, or the 2048-token budget. A signed tuple can therefore authorize the new scheduler behavior without behavior-specific multi-row evidence. Buyers may see row-local failures or TTFT regressions, while the policy still reports the runtime as accepted.

   Minimal fix: include scheduler-behavior revision, ragged capability/cap, and prefill budget in the signed tuple and acceptance coverage.

2. **MEDIUM — NEW — PARTIALLY FIXED**  
   `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1541-1578,1639-1667`; `ModelRuntime.swift:6942`; `ReceiptBuilder.swift:383-387`

   Continuous-batching streaming receipts still sign `ttft_ms: 0`, even when `ContinuousBatchFirstTokenClock` measured the first buyer-visible chunk. Terminal replay can also lack the canonical row’s original TTFT. Signatures and verification pass because the verifier only rejects negative values. Settlement evidence, SLA metrics, and calibration data therefore contain semantically false TTFT.

   Minimal fix: thread `completion.ttftMilliseconds` through every streaming/cancel receipt path and carry canonical TTFT through replay ownership.

3. **MEDIUM — NEW — PARTIALLY FIXED**  
   `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:181-187`; `phase4-coordinator/internal/config/config.go:819-839,1695-1700`

   Calibration can select 16–32 slots, but the default coordinator ceiling remains 8. The provider advertises higher local capacity while Pearl routes only eight buyer slots, so the opt-in feature produces no live throughput gain unless rollout configuration is separately raised.

   Minimal fix: make release/activation tooling reject or clearly gate calibrated values above the active coordinator ceiling.

No residual defect was found in header spoofing, live-slot lock ordering, ended-request identity handling, or the ragged spread-cap implementation.

VERDICT: 0C/1H/2M


