=================== code
## Raw output

```text
Round-2 CODE findings:

- **FIXED — MEDIUM: stale heartbeat overtakes pause.** `CoordinatorClient.swift:6979` clamps ready/busy immediately before sending, after payload-building awaits. `CoordinatorClientTests.swift:1996` covers a heartbeat suspended across an accepted pause. The pre-existing race is addressed.
- **FIXED — MEDIUM: configured origins omitted from status, withdrawal, and economics.** `BYOMDiscovery.swift:2610` provides the shared config resolver used by all seven models commands. `BYOMLoopbackAdapterTests.swift:510` covers configured origin and serve-port resolution.

**New findings: none. CODE gate PASS.**

Reviewed the complete `origin/main...HEAD` diff at `1ae0b80ec` and surrounding implementation, including migration privileges/idempotency/audit rows, provider-wide revoke and re-trust prevention, pending-429 callers, discovery skips, bootstrap directories, pause publication guards, and resume.

`git diff --check origin/main...HEAD` passed; checkout is clean. Static review only: runtime tests were not executed. No files edited or live hosts contacted.

C/H/M/L = 0/0/0/0
=================== security
## Raw output

```text
- **FIXED — HIGH: onboarding role fabricated attestation provenance.** [Migration 031:52](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/stats/migrations/031_hardware_trust_app_attest_auto.up.sql:52) denies onboarding access to verification records; automatic trust reads recorder-written provenance.
- **FIXED — HIGH: alternate automatic roots bypassed revocation.** [Migration 031:288](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/stats/migrations/031_hardware_trust_app_attest_auto.up.sql:288) expires every provider-owned `app_attest` root under the provider lock, with demotion and revoke ledger insertion in the same transaction.
- **FIXED — MEDIUM: model-swap completion lifted operator pause.** [ProviderStatus.swift:1006](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:1006) fences ready/busy transitions.
- **FIXED — MEDIUM: local-only and restored pauses omitted the fence.** [MacProviderCLI.swift:4679](/Users/augstar/macprovider-1880-listing/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:4679) sets it after pause persistence; startup also sets it, and resume clears it only after persistence succeeds. This omission was **pre-existing**.

No new security findings. Attestation binding/replay checks, SQL privileges, pending-response freshness handling, discovery/log redaction, and pause admission paths showed no additional actionable issues.

**Security gate: PASS.** Reviewed the complete `origin/main...HEAD` diff at `1ae0b80ec` and surrounding code. `git diff --check` passed. Static review only; runtime tests were not executed. No edits or live-host contact; checkout remains clean.

C/H/M/L = 0/0/0/0
=================== architecture
## Raw output

```text
Round-2 architecture findings:

- **FIXED — MEDIUM: terminal-job cooldown classified as pending.** Coordinator returns `hardware_evidence_rate_limited`; CLI accepts only `hardware_evidence_pending` as non-fatal. Accepted replays retain 2xx.
- **FIXED — LOW: R002/R003 wording omitted exceptions.** Current SPEC-033 v0.7.2 covers accepted replay, chip-profile availability, advisory-lock contention, and provider-wide revocation.
- **NOT FIXED — INFO: outsider admission still requires operators; pre-existing and disclosed.** [creator-guide.md:96](/Users/augstar/macprovider-1880-listing/docs/byom/creator-guide.md:96). Neither shipping client submits App Attest, so the conditional server path does not remove operator approval from outsider onboarding. **Fix:** ship the attestation producer and demonstrate buyer-serving admission without operator approval.
- **NOT FIXED — LOW: recorder failure recovery; partially addressed.** [apptrack.go:635](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/onboarding/apptrack.go:635). Sanitized `app_attest_record_failed` logging fixes the silent-failure aspect, but no retry mechanism was added. After a transient recorder failure, registration succeeds without authoritative provenance; committed registration replay returns at [apptrack.go:472](/Users/augstar/macprovider-1880-listing/phase4-coordinator/internal/onboarding/apptrack.go:472) without retrying. Automatic eligibility remains lost despite database recovery. Carried from round 2; introduced by this PR. **Fix:** add durable reconciliation or a replay path that re-verifies Apple provenance before retrying the recorder write.

**New issues: none. Architecture gate PASS: no CRITICAL/HIGH/MEDIUM findings.**

The complete diff preserves SPEC-first ordering. Revocation now expires every automatic root for the provider within the same transaction. Migration 031 must precede starting the new verifier; its smoke check fails closed without the function privilege. The updater holds changed sidecars until migration/deploy completes. Rollback 031 demotes profiles before removing automatic roots and explicitly precedes rollback 019.

Deploy runtime before CLI. Old CLI/new coordinator continues to treat pending 429 as fatal; new CLI/old coordinator keeps ambiguous legacy 429 fatal. Runtime-first deployment enables the new behavior once the CLI is updated.

Reviewed `origin/main...HEAD` through `1ae0b80ec`, including affected code and regression tests. `git diff --check origin/main...HEAD` passed; checkout is clean. Static review only: no runtime tests, edits, or live-host contact.

C/H/M/L = 0/0/0/1
