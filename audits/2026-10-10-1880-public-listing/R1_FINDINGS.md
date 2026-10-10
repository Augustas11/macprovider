=================== code
## Raw output

```text
Gate **FAIL**: 1 MEDIUM finding.

- **MEDIUM — Terminal-job rate limiting is misclassified as pending.** [AutotuneHardwareEvidence.swift:162](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/AutotuneHardwareEvidence.swift:162), [hardware_evidence.go:411](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/onboarding/hardware_evidence.go:411). The DB cap includes terminal jobs submitted within ten minutes. After a job is rejected, submitting different evidence can produce `rate_limited` with the legacy queue message despite **no outstanding job**. The new CLI treats that response as pending, lets required-evidence install/update/freshness checks succeed, and records misleading doctor output. The ambiguous server message is **pre-existing**; treating it as non-fatal is introduced here. **Fix:** give current-coordinator terminal-job cooldown refusals a distinct message/code outside the legacy pending matcher. Add a regression covering a recent rejected job, a different evidence submission, and CLI classification.

- **LOW — The idempotency test bypasses the new DB function.** [integration_test.go:2816](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/stats/integration_test.go:2816). The second job already matches an active trust root, so `ProcessPending` never calls `auto_trust_attested_hardware` again. Consequently, this test would miss a regression that overwrites an existing root or duplicates audit records on repeated function execution. **Fix:** call the function twice on a non-terminal job using the verifier role and assert unchanged root/audit data; also cover expired and differently bound existing roots.

Reviewed the complete diff and surrounding code. `git diff --check origin/main...HEAD` passed. Runtime tests were not executed; no files were edited or live hosts contacted.

C/H/M/L = 0/0/1/1
=================== security
## Raw output

```text
Security gate **FAIL**. Reviewed the complete `origin/main...HEAD` diff at `439ed4656`. No files edited or live hosts contacted; findings are based on static review.

1. **HIGH — Onboarding SQL compromise can mint hardware trust without Apple verification.**  
   [031_hardware_trust_app_attest_auto.up.sql:111](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/stats/migrations/031_hardware_trust_app_attest_auto.up.sql:111) trusts `attested=TRUE` plus any non-null key ID. Migration 006 grants `provider_onboarding` table-level INSERT/UPDATE on these fields. An attacker holding that role can fabricate both values and submit consistent evidence; the legitimate verifier then creates the trust root. Denying onboarding EXECUTE on the function does not prevent this indirect path. The broad grant is **pre-existing; automatic trust escalation is new**.  
   **Fix:** store verified attestation provenance behind a separate trusted writer role, removing onboarding INSERT/UPDATE access to the authoritative fields. Add a role-level regression proving fabricated provenance cannot promote hardware.

2. **HIGH — Revocation can be bypassed by changing the self-reported hardware hash.**  
   [031_hardware_trust_app_attest_auto.up.sql:120](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/stats/migrations/031_hardware_trust_app_attest_auto.up.sql:120) blocks re-grants only for the revoked `(provider_id, hardware_identity_hash)`. The hash is provider-controlled and shape-checked; App Attest’s registration binding does not include it. After revocation of hash H, the same attested provider can submit fresh, consistent evidence using H′ and obtain another automatic root without new Apple verification or operator approval. **New bypass.**  
   **Fix:** make revocation block automatic grants for the stable provider/attestation identity until explicit operator reauthorization, or establish a verified immutable device binding. Test revoked H followed by H′.

3. **MEDIUM — Model-switch completion can lift an operator pause outside the new guards.**  
   [ProviderStatus.swift:735](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:735) changes `.unavailable` to `.ready` when a target swap completes. A swap started before pause can finish after pause is accepted; model switching also lacks a pause check. Request admission then accepts work, and [CoordinatorClient.swift:6871](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:6871) publishes the ready status through heartbeat, bypassing the new `sendStateUpdate` guard. **Pre-existing; remains after this pause fix.**  
   **Fix:** enforce a persistent pause fence inside `ProviderStatus`, independent of model readiness, and clamp heartbeat availability. Test swap completion after accepted pause.

No additional findings in pending-response freshness handling or discovery/log redaction: pending follows evidence validation and does not itself promote hardware.

C/H/M/L = 0/2/1/0
=================== architecture
## Raw output

```text
Architecture gate: **FAIL — 1 MEDIUM finding.** Reviewed the complete `origin/main...HEAD` diff and touched code. No files edited or live hosts contacted.

- **MEDIUM — Terminal-job throttling is misclassified as pending.** `phase3-binary/Sources/macprovider-cli/AutotuneHardwareEvidence.swift:162`; `phase4-coordinator/internal/onboarding/hardware_evidence.go:410`.
  **Scenario:** A recently submitted job has already been rejected. A changed submission hits the admission cap, which counts recent jobs regardless of status (`hardware_evidence.go:144`). The pending lookup finds nothing, but the handler returns the legacy “hardware evidence queue already has a recent job” message. The new CLI classifies that as pending and lets `--require-hardware-evidence` and freshness checks continue despite having no outstanding verification job. The ambiguous server message is **pre-existing**; accepting it as non-fatal is new.
  **Fix:** Give the new coordinator’s recent-terminal-job throttle a distinct error code/message that remains a CLI failure. Add coverage for a recent rejected job. Document the unavoidable ambiguity of the legacy-coordinator fallback.

- **LOW — R002/R003 normative wording omits implemented exceptions.** `specs/SPEC-033-hardware-verifier.md:487` and `:322`.
  **Scenario:** R002 promises same-run promotion after §5.1–§5.4 pass, but a missing chip profile still parks an attested job (`hardwareverify/verify.go:414`), and advisory-lock contention deliberately defers it. R003 unconditionally requires a pending-job submission to return 429, while same-identity replay intentionally returns an accepted response first (`hardware_evidence.go:367`). These behaviors are described elsewhere, leaving conflicting normative statements.
  **Fix:** Qualify R002 promotion on chip-profile availability and lock acquisition; explicitly exempt accepted replay from R003’s 429 requirement.

- **INFO — The outsider path still requires operators; pre-existing and disclosed.** `docs/byom/creator-guide.md:96`.
  Neither shipping client submits App Attest. Consequently, ordinary new Macs remain on `waiting_trust` and dual-control approval. Non-fatal installation does not establish buyer-serving admission. **Follow-up:** Ship the attestation producer and verify an outsider’s admission without operator trust approval before declaring that campaign objective complete.

Other architecture checks: SPEC changes precede implementation in branch history. Migration application precedes verifier startup in deployment tooling; the new verifier fails startup without migration 031. The 031 rollback correctly precedes 019 and demotes profiles before deleting automatic roots. Runtime-before-CLI deployment is documented. Old CLI/new coordinator still treats pending 429 as failure; new CLI/old coordinator recognizes the legacy message, subject to the MEDIUM finding above.

Validation was static inspection; `git diff --check origin/main...HEAD` passed. Runtime and hardware tests were not run.

C/H/M/L = 0/0/1/1
