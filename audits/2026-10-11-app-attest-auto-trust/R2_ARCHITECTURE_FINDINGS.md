Round 2 architecture audit: **two MEDIUM issues remain open**. Reviewed the complete `git diff origin/main...HEAD`, including fix commit `51f14e2`.

R1 closure status below uses each lane’s finding order.

| R1 finding | Status | Evidence |
|---|---|---|
| Architecture #1: enrollment retry | CLOSED | Healthy polling schedules enrollment at [MalibuAgent.swift:1164](phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:1164); persisted backoff remains enforced. |
| Architecture #2 / Code #2: runtime recorder readiness | CLOSED | [pearl-runtime.sh:228](scripts/ops/pearl-runtime.sh:228) runs the login/policy check and offers repair for invalid state. |
| Architecture #3: discarded key handle | NOT CLOSED — accepted carried LOW | [AppAttestEnrollment.swift:45](phase3-binary/app/Sources/Malibu/Agent/AppAttestEnrollment.swift:45) still persists only completion and retry state. Excluded from findings/counts as instructed. |
| Architecture #4 / Security #5: unsupported device uniqueness | CLOSED | [SPEC-033:544](specs/SPEC-033-hardware-verifier.md:544) explicitly states per-key uniqueness and the device-level Sybil limitation. |
| Code #1: reusable rejected challenge | CLOSED | [appattest_submit.go:238](phase4-coordinator/internal/onboarding/appattest_submit.go:238), :246 and :255 consume challenges on body-validation failures. |
| Code #3: inconsistent privilege checks | CLOSED | Shared policy at [store_pg.go:51](phase4-coordinator/internal/onboarding/store_pg.go:51) includes REFERENCES/TRIGGER and column grants. |
| Code #4: DSN query overrides | CLOSED | [provision-app-attest-recorder.py:108](phase4-coordinator/dist/provision-app-attest-recorder.py:108) rejects credential/target overrides before SQL. |
| Code #5: validation after rotation | CLOSED | Candidate DSNs are derived and validated before bootstrap at [provision-app-attest-recorder.py:236](phase4-coordinator/dist/provision-app-attest-recorder.py:236). |
| Security #1: incomplete recorder isolation | CLOSED | [store_pg.go:53](phase4-coordinator/internal/onboarding/store_pg.go:53) checks attributes, memberships, ownership, column privileges and trust-function access; bootstrap revokes sensitive grants. |
| Security #2: recorder failure stops coordinator | NOT CLOSED | Connection/policy failures are isolated at [main.go:820](phase4-coordinator/cmd/coordinator/main.go:820), but env-resolution failure remains fatal; finding 1 below. |
| Security #3: credential logging | NOT CLOSED | [app-attest-recorder-bootstrap.sql:27](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:27) leaves independent logging paths enabled; finding 2 below. |
| Security #4: missing category assurance | CLOSED | Compatibility exception and assurance limit documented at [SPEC-033:531](specs/SPEC-033-hardware-verifier.md:531). |

Open findings:

1. **MEDIUM — Recorder failure isolation does not cover missing env references.**
   [coordinator.yaml:283](phase4-coordinator/dist/coordinator.yaml:283) now explicitly references `env:ONBOARDING_APP_ATTEST_RECORD_DSN`. If that variable becomes absent or empty, [config.go:2582](phase4-coordinator/internal/config/config.go:2582) returns an error, and [main.go:187](phase4-coordinator/cmd/coordinator/main.go:187) exits before recorder failure isolation runs. A restart consequently removes registration, evidence submission and serving instead of leaving App Attest unavailable. The strict resolver is pre-existing; the distribution config’s mandatory recorder reference is introduced here. **Fix:** resolve this optional recorder field tolerantly, emit a redacted unavailable event, and retain the deploy provisioning prerequisite.

2. **MEDIUM — Bootstrap still permits server logs to capture the SCRAM verifier.**
   [app-attest-recorder-bootstrap.sql:27](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:27) disables three logging settings, but leaves `log_min_duration_sample` and `log_transaction_sample_rate` unchanged. With transaction sampling enabled, the password-bearing `ALTER ROLE` at :75 can still be logged. PostgreSQL documents transaction sampling as an independent statement-logging path. The non-superuser branch also proceeds without establishing safe logging before the verifier-bearing query at :39. **Fix:** disable duration and transaction sampling before interpolating credential material, and refuse sessions that cannot establish the required logging settings. [PostgreSQL logging documentation](https://www.postgresql.org/docs/current/runtime-config-logging.html)

No additional architecture findings in the single-writer boundary, auto-trust/revoke composition, SPEC-049 separation, or signing/version coupling. The in-memory challenge store remains appropriate for one coordinator process; multiple instances require shared atomic consumption or enforced affinity.

Validation: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_provision_app_attest_recorder scripts.tests.test_malibu_app_attest_signing` completed successfully: **13 tests, one skipped**. PostgreSQL integration and Swift/hardware checks were not run. No files changed or live hosts contacted; checkout remains clean.

C/H/M/L = 0/0/2/0
