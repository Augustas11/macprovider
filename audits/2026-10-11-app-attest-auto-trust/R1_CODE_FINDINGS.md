Found four MEDIUM issues and one LOW issue in the complete diff. All are introduced by this change.

1. **MEDIUM — Failed submissions leave challenges reusable.** [appattest_submit.go:241](phase4-coordinator/internal/onboarding/appattest_submit.go:241) rejects unknown fields and invalid key/attestation encodings before consuming the challenge. This conflicts with SPEC-033 §5.7.1’s “removed whether or not the rest succeeds.” The existing test explicitly reuses a challenge after rejection. Consume the token-bound challenge before validating the remainder, and test that subsequent retries return `409 challenge_invalid`.

2. **MEDIUM — Runtime readiness checks presence, not validity.** [pearl-runtime.sh:227](scripts/ops/pearl-runtime.sh:227) marks recorder provisioning done based solely on a nonempty env-file line. Empty quoted values, invalid credentials, or wrong-role DSNs pass this check; coordinator startup then fails. Validate login and privileges before marking the step done, and expose invalid state for repair.

3. **MEDIUM — Idempotence accepts privileges that startup rejects.** [provision-app-attest-recorder.py:43](phase4-coordinator/dist/provision-app-attest-recorder.py:43) omits `REFERENCES` and `TRIGGER` checks. An existing recorder role holding either returns “already provisioned,” bypassing bootstrap’s privilege repair, while [startup smoke](phase4-coordinator/internal/onboarding/store_pg.go:323) rejects it. Align the checks and add privilege-drift coverage.

4. **MEDIUM — DSN query parameters can override recorder credentials.** [provision-app-attest-recorder.py:99](phase4-coordinator/dist/provision-app-attest-recorder.py:99) preserves the onboarding query, and `service_entry` applies its parameters after the generated authority. Query-level `user` or `password` therefore overrides the recorder credentials. Bootstrap commits and the incorrect DSN is written before verification fails. Normalize effective connection settings, replace credentials authoritatively, and validate before publishing the DSN.

5. **LOW — Static validation happens after password rotation.** [provision-app-attest-recorder.py:191](phase4-coordinator/dist/provision-app-attest-recorder.py:191) runs bootstrap before deriving the recorder DSN. Unsupported DSN formats or invalid ports can fail afterward, leaving the role password changed without saving the generated credential. Derive and validate the candidate before executing SQL.

No additional correctness findings in JCS/hash byte handling, production verifier fixtures, recorder race outcomes, register-path removal, or signing workflows.

Validation passed: full `internal/appattest` tests, targeted onboarding tests, and Python provisioning/signing tests (11 run, one skipped). PostgreSQL integration and Swift tests were not run. Checkout remains unchanged.

C/H/M/L = 0/0/4/1
VERDICT: FAIL
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed
tokens used
141 919

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
