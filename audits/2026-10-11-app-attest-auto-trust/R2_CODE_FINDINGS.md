Round 2 CODE audit: **three MEDIUM issues remain** in `git diff origin/main...HEAD`, including one regression introduced by fix commit `51f14e275`.

R1 closure checks use the numbering in each lane’s findings file:

| R1 finding | Result | Evidence |
|---|---|---|
| CODE 1 — rejected submissions retain challenges | **CLOSED** | [appattest_submit.go:246](phase4-coordinator/internal/onboarding/appattest_submit.go:246) consumes on malformed submissions. |
| CODE 2 / ARCHITECTURE 2 — readiness checks presence only | **CLOSED** | [pearl-runtime.sh:229](scripts/ops/pearl-runtime.sh:229) runs login-plus-policy `--check`. |
| CODE 3 — missing REFERENCES/TRIGGER checks | **CLOSED** | [store_pg.go:59](phase4-coordinator/internal/onboarding/store_pg.go:59) checks both through the shared predicate. |
| CODE 4 — query overrides recorder credentials | **CLOSED** | [provision-app-attest-recorder.py:108](phase4-coordinator/dist/provision-app-attest-recorder.py:108) rejects credential/target overrides. |
| CODE 5 — static validation follows rotation | **CLOSED** | [provision-app-attest-recorder.py:236](phase4-coordinator/dist/provision-app-attest-recorder.py:236) derives and validates before SQL. |
| SECURITY 1 — incomplete recorder privilege isolation | **NOT CLOSED** | [store_pg.go:63](phase4-coordinator/internal/onboarding/store_pg.go:63) omits other trust-writing functions; finding below. |
| SECURITY 2 — recorder failure terminates startup | **CLOSED** | [main.go:821](phase4-coordinator/cmd/coordinator/main.go:821) logs a redacted failure and disables recording. |
| SECURITY 3 — bootstrap credential logging | **NOT CLOSED** | [app-attest-recorder-bootstrap.sql:28](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:28) leaves sampling logs enabled; finding below. |
| SECURITY 4 — undocumented missing-category acceptance | **CLOSED** | [SPEC-033:531](specs/SPEC-033-hardware-verifier.md:531) documents the compatibility exception and assurance. |
| SECURITY 5 / ARCHITECTURE 4 — unsupported per-device uniqueness | **CLOSED** | [SPEC-033:544](specs/SPEC-033-hardware-verifier.md:544) explicitly states per-key uniqueness and the device-level limitation. |
| ARCHITECTURE 1 — enrollment never retries while open | **CLOSED** | [MalibuAgent.swift:1164](phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:1164) schedules retries from healthy-provider polling. |
| ARCHITECTURE 3 — attested key handle not persisted | **NOT CLOSED — accepted carried LOW** | [AppAttestEnrollment.swift:142](phase3-binary/app/Sources/Malibu/Agent/AppAttestEnrollment.swift:142). Excluded from findings and counts as instructed. |

Open findings:

1. **MEDIUM — Recorder policy still permits drifted trust-workflow EXECUTE grants.**
   [store_pg.go:63](phase4-coordinator/internal/onboarding/store_pg.go:63) checks only `auto_trust_attested_hardware`; [bootstrap.sql:67](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:67) revokes only that function. Neither covers `request_hardware_trust_approval`, `approve_hardware_trust_approval`, or `revoke_hardware_trust_approval`. A direct EXECUTE grant on the existing SECURITY DEFINER revoke function passes provisioning, deployment and startup policy checks. Compromised recorder credentials could then revoke trust without table privileges or role membership. **Fix:** check and revoke every trust-workflow function signature consistently across the shared policy and bootstrap. This is a remaining R1 gap; the trust functions themselves are pre-existing.

2. **MEDIUM — Bootstrap’s logging suppression misses statement sampling.**
   [bootstrap.sql:28](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:28) disables ordinary statement, duration and error-statement logging, but leaves `log_min_duration_sample` and `log_transaction_sample_rate` unchanged. With sampling enabled, the validation SELECT at line 39 can log the interpolated SCRAM verifier even during a superuser bootstrap. PostgreSQL documents these as separate logging paths. [PostgreSQL logging documentation](https://www.postgresql.org/docs/current/runtime-config-logging.html). **Fix:** disable sampled duration and transaction logging before interpolating credential material, and refuse a session that cannot establish the required logging settings. Output redaction is fixed; server-log exposure remains.

3. **MEDIUM — R1 fix evaluates challenge expiry before reading the body.**
   [appattest_submit.go:235](phase4-coordinator/internal/onboarding/appattest_submit.go:235) captures `now` before `readBoundedBody`, then line 259 passes that stale timestamp to `Consume`. A submission beginning before expiry but completing its body afterward can still verify and record. The HTTP server permits reads for 310 seconds, exceeding the five-minute challenge TTL. **Fix:** evaluate expiry using fresh time when consuming after body processing, while retaining consumption on rejected bodies. Existing expiry tests advance time before handler entry and miss this regression.

No additional open correctness issues found in verifier fixtures, JCS/hash handling, recorder race outcomes, register-path removal, CLI/app transport, or signing changes.

Validation: five selected existing onboarding tests passed. The provisioning/signing Python suites ran 13 tests: 12 passed, one PostgreSQL integration test skipped. PostgreSQL integration, Swift and hardware checks were not run. No files changed, live hosts contacted, or new payloads constructed.

C/H/M/L = 0/0/3/0
