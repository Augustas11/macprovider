Architecture review of `git diff origin/main...HEAD`: **two MEDIUM and two LOW findings**.

- **MEDIUM — Enrollment does not retry while Malibu remains open.** [MalibuAgent.swift:2086](phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:2086) discards the enrollment outcome and clears the task. Its only scheduling call is during initial provider attachment; health polling never retries. A transient outage, coordinator restart between challenge and submit, old coordinator, or old installed CLI can therefore leave an eligible Mac unenrolled indefinitely after the prerequisite recovers. The persisted backoff is checked only on another invocation. **Fix:** trigger enrollment from healthy-provider polling, respecting the existing backoff and task guard. Verify recovery without relaunching Malibu.

- **MEDIUM — Runtime readiness checks presence rather than recorder usability.** [pearl-runtime.sh:227](scripts/ops/pearl-runtime.sh:227) marks provisioning done whenever the env assignment is nonempty. A stale password or incorrectly provisioned role passes this step and reaches runtime apply, although coordinator startup can then fail its recorder smoke check. The stronger check added to `deploy-pearl-vps.sh` does not protect the signed updater path. **Fix:** run a secret-safe login and complete least-privilege check before marking this step done and proceeding to plan/apply. Surface an invalid DSN as the specific blocked prerequisite before downtime.

- **LOW — Enrollment discards the key handle needed by the later posture slice.** [AppAttestEnrollment.swift:142](phase3-binary/app/Sources/Malibu/Agent/AppAttestEnrollment.swift:142) generates a key, but durable state retains only `done` and backoff. Meanwhile, coordinator records are immutable and first-wins, and `already_recorded` does not return the enrolled key ID. Later code cannot recover the handle through this implementation to generate assertions with that enrolled key. **Fix:** persist the opaque key ID with successful enrollment and define recovery for already-enrolled installations. Posture implementation remains outside this audit’s scope.

- **LOW — The stated Sybil cost exceeds the enforced boundary.** [SPEC-033:542](specs/SPEC-033-hardware-verifier.md:542) claims “one real macOS 27 Mac per provider id.” The implementation enforces unique **keys**, not unique devices: enrollment state is per provider ID, and each enrollment generates a fresh key. The design establishes genuine-device provenance without establishing a distinct physical Mac for each identity. **Fix:** state that limitation explicitly; do not describe key uniqueness as device uniqueness.

The core boundary is sound: only submit records verification, using the token-bound provider ID and the separate recorder connection. Migration 031 consumes that same ID, and its provider-wide revoke ledger prevents automatic regrant under another hardware hash. This hardware verification does not replace SPEC-049 R024 eligibility or R025 posture/key enrollment.

The bounded in-memory challenge store is adequate for one coordinator process. Restart invalidates outstanding challenges safely; clients must reacquire them. A future deployment with multiple instances needs shared atomic challenge consumption or enforced request affinity.

The register path’s verification-only behavior is explicitly documented. SPEC versions, R004 numbering, CONFORMANCE references, and AUTHORITY ownership are consistent. No new calendar expiry is imposed on recorded trust; challenge lifetime and provisioning-profile validity are distinct from feature sunset. Endpoint availability does inherit the pre-existing default-off app-track registration gate.

Validation: the two existing Python suites ran **11 tests, with one skipped**, and passed. No files changed, no live hosts contacted, and no hardware or broad local workloads ran.

C/H/M/L = 0/0/2/2
VERDICT: FAIL
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed
tokens used
102 571

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
