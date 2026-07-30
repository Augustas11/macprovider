# SPEC-029 Implementation Notes

> **Numbering (2026-07-10):** the spec these notes implement was promoted to
> canonical **SPEC-030** (`specs/SPEC-030-losslessness-probe.md`); the canonical
> **SPEC-029** number now belongs to the unrelated sweep-workload-class spec. This
> file, its `spec029/` fixtures, and the `losslessness_probe_v1` wire constant keep
> the `029`/`spec029` labels deliberately — renaming a shipped wire identifier is
> out of scope. See `beta/DECISION_CRITERIA.md` Entry 127.

Status: prototype implementation from `v0.1-draft`.

Source-of-truth commit: `adef83ef16c039b5be1da310a5666bf200fc1708`
(`Define the SPEC-029 implementation handoff`).

Authorization: the user explicitly requested implementation of
`BUILD_SPEC_029_v0_1_IMPL_PROMPT.md` while SPEC-029 remains a draft. Runtime
behavior is therefore gated off by default and must not be treated as production
rollout approval.

## Implemented In This Slice

- Coordinator disabled-by-default config gate: `pool.losslessness_probe`.
- Coordinator protocol structs, shared RFC8785/JCS canonical payload digesting,
  raw-string probe digesting, request/result envelope validation with
  inner/outer probe binding, golden JCS fixtures including a non-NFC string
  fixture, distribution validation, target/draft identity checks, K=256
  terminal tail ceiling, TV interval math, reason-code/profile state
  transitions, repeated retryable-inconclusive abuse promotion, target-grid
  readiness, synthetic corpus prompt guard, explicit result-frame dispatch,
  in-memory `draft_admission_v1` records, in-memory coordinator target
  generation records, in-memory pending-probe binding, duplicate
  probe-id/nonce/request-digest rejection, expiry/nonce/digest single-use
  checks, in-memory profile-state persistence, typed telemetry snapshots for
  probe results and admission-blocked cases, and dedicated Tier-2 carrier
  helpers.
- Coordinator prototype scheduler entry point gated by
  `pool.losslessness_probe.enabled`: once per configured interval it dispatches
  one synthetic coordinator-owned probe per ready provider when no probe is
  already pending for that provider, rotating the default profile grid. Issuance
  fails closed unless a current draft-admission record exists. The request seeds
  requested-position membership, coordinator-owned high-entropy flags, context
  hashes, vocabulary bounds, and offline baselines in pending state; these are
  not sent on the wire.
- Runtime measurement verdicts now fail closed if pending safety metadata is
  absent, require the K=64-to-K=256 retry gate before pass/warn/quarantine
  decisions, use canonical lower-middle median over TV intervals, and require
  an accepted calibration/verdict-engine marker before `pass_fresh` or
  quarantine disablement can count toward grid readiness.
- Provider disabled-by-default config gate:
  `MACPROVIDER_LOSSLESSNESS_PROBE_ENABLED` / `losslessness_probe_enabled`.
- Provider cleartext and Tier-2 request handling for `losslessness_probe_v1`
  carriers, including invalid-message NAKs for malformed enabled probe frames
  and plaintext probe-request rejection after an active Tier-2 session exists.
- Provider result generation for the current runtime state:
  `provider_inconclusive` with
  `inconclusive:unsupported_sampler`, because the current Swift/MLX runtime seam
  does not expose the full post-processor distribution required by SPEC-029.
  This result echoes `probe_nonce`, binds to `probe_request_digest`, and carries
  null target/draft identity fields with `identity_unavailable_reason`.
- SPEC-015 guard coverage showing probe metadata is not accepted in v0.4 receipt
  tuples or `usage`.

## Deliberately Deferred

- Durable scheduler storage, durable replay/profile/telemetry persistence,
  jitter/backoff persistence, retention sweeps, admin dashboard storage, and
  operator telemetry export surfaces. In-memory typed snapshots exist for this
  prototype; production enablement still requires a durable store.
- Durable `draft_admission_v1` storage, durable coordinator-owned
  `target_generation` persistence, and warm swap generation invalidation.
- Full K=256 retry orchestration/redispatch, calibration baseline approval
  workflow, threshold-version management, and dashboard nullability. This slice
  contains the fail-closed verdict guards but not the operator workflow needed
  to mark calibration/verdict prerequisites accepted in production.
- Real MLX full-distribution sampler hook and measurement emission.
- Deterministic Tier-2 encrypted golden fixture with static test keys.
- Grid-state telemetry golden fixtures.
- SPEC-028 stochastic speculative decoding enablement. This remains blocked on
  a separate rollout approval naming grid key, feature flag, allowed profiles,
  and rollback condition.

## Verification Log

- `cd phase4-coordinator && gofmt -w internal/config/config.go internal/ws/losslessness.go internal/ws/losslessness_test.go`
- `cd phase4-coordinator && go test ./internal/config ./internal/ws`
- `cd phase3-binary && swift test --filter LosslessnessProbeProtocolTests`
- `cd phase4-coordinator && go test ./internal/config ./internal/ws ./internal/spec015contract`
- `cd phase3-binary && swift test --filter 'LosslessnessProbeProtocolTests|CoordinatorClientTests/testEncryptedLosslessnessProbeRejectsCarrierRequestIDMismatch'`
- `cd phase4-coordinator && go test ./internal/config ./internal/ws ./internal/spec015contract`
- `cd phase3-binary && swift test --filter 'LosslessnessProbeProtocolTests|CoordinatorClientTests/testEncryptedLosslessnessProbeRejectsCarrierRequestIDMismatch'`
- `cd phase4-coordinator && go test ./internal/config ./internal/ws ./internal/spec015contract`
- `cd phase3-binary && swift test --filter 'LosslessnessProbeProtocolTests|CoordinatorClientTests/testEncryptedLosslessnessProbeRejectsCarrierRequestIDMismatch'`
- `cd phase4-coordinator && go test ./internal/config ./internal/ws ./internal/spec015contract`
- `cd phase4-coordinator && go test ./...`
- `cd phase3-binary && swift test --filter 'LosslessnessProbeProtocolTests|CoordinatorClientTests/testEncryptedLosslessnessProbeRejectsCarrierRequestIDMismatch'`

Additional verification should be appended before merge if this prototype is
expanded to scheduler/dashboard/runtime measurement slices.
