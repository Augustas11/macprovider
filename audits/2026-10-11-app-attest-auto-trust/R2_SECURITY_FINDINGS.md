Round 2 found **two open MEDIUM issues and one new LOW regression** in the complete `origin/main...HEAD` diff.

| R1 finding | Closure evidence |
|---|---|
| Security M1 — privilege isolation | **NOT CLOSED** — `phase4-coordinator/internal/onboarding/store_pg.go:63`; trust-writing functions remain unchecked, detailed below. |
| Security M2 — recorder failure stops startup | **CLOSED** — `phase4-coordinator/cmd/coordinator/main.go:820`; failures disable recording and startup continues. |
| Security M3 — bootstrap credential logging | **NOT CLOSED** — `phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:27`; sampling remains enabled, detailed below. |
| Security L4 — missing validation category | **CLOSED** — `specs/SPEC-033-hardware-verifier.md:531`; compatibility exception and assurance basis documented. |
| Security L5 — per-device Sybil claim | **CLOSED** — `specs/SPEC-033-hardware-verifier.md:544`; explicitly states per-key uniqueness. |
| Code M1 — rejected submissions preserve challenge | **CLOSED** — `phase4-coordinator/internal/onboarding/appattest_submit.go:238`, `:246`, `:255`; rejected bodies consume it. |
| Code M2 — runtime readiness checks presence | **CLOSED** — `scripts/ops/pearl-runtime.sh:229`; runs login and privilege validation. |
| Code M3 — missing REFERENCES/TRIGGER checks | **CLOSED** — `phase4-coordinator/internal/onboarding/store_pg.go:59`; shared policy checks both. |
| Code M4 — DSN query overrides credentials | **CLOSED** — `phase4-coordinator/dist/provision-app-attest-recorder.py:108`; override parameters rejected before SQL. |
| Code L5 — static validation follows rotation | **CLOSED** — `phase4-coordinator/dist/provision-app-attest-recorder.py:236`; candidate connections validated before bootstrap. |
| Architecture M1 — enrollment never retries | **CLOSED** — `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:1164`; healthy polling retries through existing backoff. |
| Architecture M2 — recorder readiness | **CLOSED** — `scripts/ops/pearl-runtime.sh:229`; same login/policy check. |
| Architecture L1 — enrolled key handle discarded | **NOT CLOSED — accepted carried LOW** — `phase3-binary/app/Sources/Malibu/Agent/AppAttestEnrollment.swift:45`, `:142`; excluded from findings/counts as instructed. |
| Architecture L2 — per-device Sybil claim | **CLOSED** — `specs/SPEC-033-hardware-verifier.md:544`. |

1. **MEDIUM — Recorder policy still permits trust-writing function grants.**
   [store_pg.go:63](phase4-coordinator/internal/onboarding/store_pg.go:63), [bootstrap.sql:67](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:67).
   The shared policy and bootstrap cover only `auto_trust_attested_hardware`, omitting `request_hardware_trust_approval`, `approve_hardware_trust_approval`, and `revoke_hardware_trust_approval`. A recorder role drifted with EXECUTE on request and approve passes every new check. Those SECURITY DEFINER functions accept caller-supplied operator labels; a compromised recorder credential could request and approve a qualifying job using distinct labels, bypassing actual dual control. The functions are pre-existing; the incomplete isolation policy is introduced here and leaves R1 Security M1 open.
   **Fix:** reject effective EXECUTE on all three functions in the shared policy and revoke their recorder grants during bootstrap. Add existing integration coverage for function-grant drift.

2. **MEDIUM — Bootstrap can still log the SCRAM verifier.**
   [bootstrap.sql:27](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:27), [bootstrap.sql:39](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:39).
   Disabling `log_statement` and `log_min_duration_statement` does not disable statement-duration sampling or transaction sampling. With either configured, the validation query or password statement can still write the interpolated verifier to database logs, even for a superuser bootstrap. Non-superuser sessions skip all logging controls. Raw diagnostic redaction is fixed, but R1 Security M3 remains open. [PostgreSQL logging documentation](https://www.postgresql.org/docs/current/runtime-config-logging.html) confirms the independent sampling controls.
   **Fix:** establish and verify secret-safe session logging before transmitting credential material, including disabling both sampling paths; fail before interpolation when that cannot be established.

3. **LOW — R1 introduces a stale clock for challenge expiry.**
   [appattest_submit.go:235](phase4-coordinator/internal/onboarding/appattest_submit.go:235), [appattest_submit.go:259](phase4-coordinator/internal/onboarding/appattest_submit.go:259).
   The fix samples `now` before reading the request body and uses it later to consume the challenge. A valid request beginning before expiry but completing afterward can therefore be accepted past the five-minute deadline. Previously, consumption sampled the current time after reading the body. This does not bypass Apple verification or single-use enforcement.
   **Fix:** sample time at consumption; retain unconditional consumption on rejected-body paths.

Validation: existing provisioning/signing Python suites ran **13 tests: 12 passed, one PostgreSQL test skipped**. PostgreSQL integration, Go, Swift, and hardware checks were not run. No files changed or live operational hosts contacted. `git diff --check origin/main...HEAD` reported trailing whitespace in committed R1 audit markdown.

C/H/M/L = 0/0/2/1
