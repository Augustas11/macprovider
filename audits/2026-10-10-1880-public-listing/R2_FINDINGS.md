=================== code
## Raw output

```text
Round-1 CODE findings:

- **FIXED — MEDIUM:** Finished-job cooldowns now return `hardware_evidence_rate_limited`; the CLI treats only `hardware_evidence_pending` as non-fatal. Coordinator and CLI regressions cover the distinction.
- **FIXED — LOW:** [integration_test.go:2914](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/stats/integration_test.go:2914) directly invokes the DB function as the verifier role, covering repeated calls, expired roots, and mismatched tuples.

The related round-1 model-swap pause bypass is also **FIXED** by the `ProviderStatus` fence. Two new findings remain:

- **MEDIUM — An in-flight heartbeat can publish ready/busy after pause completes.** [CoordinatorClient.swift:6878](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:6878). The heartbeat computes availability before awaiting runtime/catalog/event-store operations. During those suspensions, `pauseByOperator()` can finish and publish `unavailable`; the old heartbeat subsequently sends its cached availability without rechecking pause. The coordinator’s state guard accepts `busy` from `unavailable`. The asynchronous hazard is **pre-existing and remains after this fix**. **Fix:** apply the pause clamp immediately before transmission, after payload-building awaits, and add a deterministic regression that suspends a heartbeat while pause completes.

- **MEDIUM — Configured engine origins are omitted from admission readback and withdrawal.** [ModelsSubcommand.swift:707](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:707), [:818](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:818), [:930](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:930). Discover/evaluate/offer/propose now honor `loopback_origin`, but admission status, withdrawal, and catalog economics still probe default ports. With an engine on a configured non-default port, proposing by model reference succeeds while status cannot resolve that reference correctly and withdrawal fails `candidateNotFound`; economics omits the runtime. Default-port behavior is **pre-existing; the inconsistent command flow is introduced here**. **Fix:** pass `configuredLoopback` through all three builders and test candidate resolution across those commands.

**Gate: FAIL.** Reviewed the complete `origin/main...HEAD` diff at `9f6321591` and affected code. `git diff --check origin/main...HEAD` passed. Runtime tests were not executed; no files were edited or live hosts contacted.

C/H/M/L = 0/0/2/0
=================== security
## Raw output

```text
Round-1 security findings:

- **FIXED — HIGH: onboarding SQL role could fabricate attestation provenance.** Migration 031 now reads insert-only `provider_app_attest_verifications`, writable through the separate `app_attest_recorder` role. The registration handler records provenance only after Apple verification succeeds.
- **NOT FIXED — HIGH: revocation bypass through another hardware hash.** New grants are blocked provider-wide, but previously obtained automatic roots under other hashes remain usable.
- **FIXED — MEDIUM: model-swap completion lifts a coordinator-connected operator pause.** `ProviderStatus` now fences readiness transitions, and heartbeat publication clamps paused availability. A separate local-only omission remains below.

**Remaining findings — security gate FAIL**

1. **HIGH — Pre-created alternate automatic roots bypass revocation.**  
   [031_hardware_trust_app_attest_auto.up.sql:268](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/stats/migrations/031_hardware_trust_app_attest_auto.up.sql:268), [verify.go:238](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/stats/hardwareverify/verify.go:238).

   **Scenario:** Before revocation, an attested provider obtains automatic roots for self-reported hashes H and H′ through successive valid submissions. Revoking H expires only H. Fresh evidence for H′ matches its surviving root, so `Evaluate` succeeds without calling the function containing the provider-wide revocation guard. Promotion also checks only whether the matching root is active. If H′ backs the current profile, the revocation demotion can leave it verified immediately.

   **Fix:** Under the existing provider lock, revoke every `app_attest` root belonging to that provider, while retaining the intended independent operator/inventory approvals. Alternatively, consistently exclude revoked providers’ automatic roots from every trust consumer. Add a regression obtaining H and H′ **before** revocation, then submitting fresh H′ evidence afterward. This automatic-root bypass is introduced by this PR; hash-scoped operator revocation is pre-existing.

2. **MEDIUM — Local-only operator pause never activates the new fence.**  
   [MacProviderCLI.swift:3435](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:3435), [ProviderStatus.swift:735](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:735).

   **Scenario:** With `--no-join` and warm swapping enabled, the local control handler accepts pause by setting `.unavailable`, but leaves `operatorPauseFence=false`. A model swap completing afterward transitions the provider to `.ready`; `beginRequestIfAccepting` then admits HTTP inference while the durable lifecycle state still says paused. Restored local-only pauses likewise omit the fence. **Pre-existing; remains outside the coordinator-path fix.**

   **Fix:** Activate the fence on local-only pause and restored startup pause, and clear it only after successful resume persistence. Cover local-only swap completion after accepted pause.

No additional findings in attestation replay binding, pending-response freshness handling, or discovery/log redaction.

Reviewed the complete diff at `9f6321591` and surrounding security paths. `git diff --check origin/main...HEAD` passed. Static review only; no runtime tests, file edits, or live-host contact.

C/H/M/L = 0/1/1/0
=================== architecture
## Raw output

```text
Round-1 architecture findings:

- **FIXED — MEDIUM: terminal-job cooldown classified as pending.** `hardware_evidence.go:414` now returns `hardware_evidence_rate_limited`; `AutotuneHardwareEvidence.swift:163` accepts only `hardware_evidence_pending`. Legacy coordinator queue responses remain fatal. Regression coverage covers both distinctions.
- **FIXED — LOW: R002/R003 wording omitted exceptions.** `SPEC-033-hardware-verifier.md:329` exempts accepted replay; `:510` qualifies same-run promotion on chip-profile availability and advisory-lock acquisition.
- **NOT FIXED — INFO: outsider admission still needs operators; pre-existing and disclosed.** `docs/byom/creator-guide.md:96` acknowledges that neither shipping client submits App Attest. This campaign enables a conditional server path but does not complete operator-free outsider admission. **Follow-up:** ship the attestation producer and prove buyer-serving admission without operator approval.

New finding:

- **LOW — Attestation-record failures silently lose automatic-trust eligibility.** [apptrack.go:635](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/onboarding/apptrack.go:635). **Scenario:** Apple verification and registration succeed, but the separate recorder write times out or fails. Its error is discarded, registration still returns success, and the provider lacks the authoritative verification row. Hardware therefore remains on the operator path. A committed registration replay returns earlier (`:472`) without retrying the record. This is fail-safe, but operationally invisible. **Fix:** report recorder failures through sanitized logging/metrics and provide a retry mechanism that preserves the verified-provenance boundary.

Architecture gate **PASS: no C/H/M findings**.

SPEC-first ordering is preserved. Migration application precedes installation/startup of the new verifier, whose smoke check requires migration 031. The 031 rollback demotes profiles before removing automatic roots and precedes 019. Deploy runtime before CLI: old CLI/new coordinator still fails on pending 429; new CLI/old coordinator also keeps ambiguous legacy 429 fatal.

Reviewed `origin/main...HEAD` through `9f6321591`. `git diff --check origin/main...HEAD` passed; checkout remains clean. Runtime tests were not run. No files edited or live hosts contacted.

C/H/M/L = 0/0/0/1
