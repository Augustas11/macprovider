Security audit found **3 MEDIUM and 2 LOW findings**.

1. **MEDIUM — Recorder privilege checks miss column-level grants.**  
   [deploy-pearl-vps.sh:2736](phase4-coordinator/dist/deploy-pearl-vps.sh:2736), [store_pg.go:325](phase4-coordinator/internal/onboarding/store_pg.go:325), [provision-app-attest-recorder.py:43](phase4-coordinator/dist/provision-app-attest-recorder.py:43).  
   A drifted recorder role with column-level writes on trust/profile tables can pass the deploy preflight: `has_table_privilege` does not detect those grants. Bootstrap resets privileges only on the verification table; provisioning and startup checks also omit sensitive-table/function access and elevated role attributes. This weakens the promised isolation under recorder-credential compromise. PostgreSQL provides [`has_any_column_privilege`](https://www.postgresql.org/docs/current/functions-info.html) for this distinction.  
   **Fix:** Apply one complete privilege policy across bootstrap, provisioning, startup and deployment, covering column grants, privileged attributes, ownership, memberships and trust-writing functions.

2. **MEDIUM — Recorder failure can prevent the whole coordinator from starting.**  
   [main.go:812](phase4-coordinator/cmd/coordinator/main.go:812), [store_pg.go:315](phase4-coordinator/internal/onboarding/store_pg.go:315).  
   An invalid recorder DSN, failed authentication or failed recorder smoke check terminates startup. Registration, evidence submission and serving therefore become unavailable instead of remaining on dual control. **The fatal startup behavior is pre-existing**, but this change provisions the credential, adds automatic env loading and expands fatal smoke conditions. It conflicts with SPEC-033-R004’s failure isolation.  
   **Fix:** Validate the recorder separately; on failure, close and disable that connection, emit a redacted alert, and keep the coordinator running with App Attest endpoints unavailable.

3. **MEDIUM — Bootstrap logging can expose credential material.**  
   [app-attest-recorder-bootstrap.sql:29](phase4-coordinator/dist/app-attest-recorder-bootstrap.sql:29), [provision-app-attest-recorder.py:194](phase4-coordinator/dist/provision-app-attest-recorder.py:194).  
   `\getenv` avoids argv exposure, but interpolation places the SCRAM verifier directly in SQL statements. Statement logging can retain it; accidentally supplied plaintext reaches the database in the validation query before rejection. The provisioning error path also prints raw PostgreSQL diagnostics, which can include statement text.  
   **Fix:** Validate the verifier locally before connecting, establish secret-safe logging for the bootstrap session, and replace raw diagnostic output with a redacted failure category.

4. **LOW — Developer ID validation silently accepts missing category evidence.**  
   [attest.go:225](phase4-coordinator/internal/appattest/attest.go:225).  
   Missing extensions—or an extensions map without `apple_validation_category_01`—skip the category check. The real fixture intentionally exercises this exception, so acceptance does not establish Developer ID category from attestation evidence. [Apple’s validation guidance](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server) calls for checking that value. No development-AAGUID or non-SIP bypass was demonstrated.  
   **Fix:** Document the missing-category compatibility exception and its assurance limit explicitly; reject missing category where the supported attestation format guarantees its presence.

5. **LOW — The stated per-device Sybil cost is unsupported.**  
   [SPEC-033:542](specs/SPEC-033-hardware-verifier.md:542).  
   Unique key IDs establish one provider per key, not one provider per physical Mac. A genuine Mac can generate distinct keys for distinct provider identities. Apple describes receipt-based fraud metrics for assessing multiple keys per device.  
   **Fix:** Correct the claim to per-key uniqueness and explicitly retain device-level Sybil resistance as an unresolved limitation.

Verification: Apple’s published root and the compiled root are DER-identical, matching the pinned SHA-256. Existing App Attest package tests and targeted onboarding tests passed. The two Python modules ran 11 tests with one PostgreSQL integration test skipped. No files were edited and no live operational host was contacted.

The inspected submit path preserves bearer-derived identity, server-side purpose/provider binding, atomic challenge consumption and database first-wins uniqueness. I found no direct attestation-forgery, cross-provider replay, production-AAGUID or ACL bypass.

C/H/M/L = 0/0/3/2
VERDICT: FAIL
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed
tokens used
127 413

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
