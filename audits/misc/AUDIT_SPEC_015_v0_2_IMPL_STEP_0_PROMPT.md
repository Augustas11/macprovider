# Audit prompt - SPEC-015 v0.2 implementation Step 0

Operator-paste prompt for Codex to perform an adversarial
**code / security / architecture review** of implementation commit
`951013d` on branch `impl/spec-015-v0-2-step-00`.

Step 0 absorbs the SPEC-002 v1.5 candidate
`GET /v1/receipt-keys/<provider_id>` coordinator endpoint required by
SPEC-015 v0.2.4 §10.7. This is a buyer-safe public trust-root lookup:
it must expose receipt keys without leaking operator-only pool fields.

This is a **read-only review**. Do not edit files.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial code / security / architecture review
of commit `951013d` on branch `impl/spec-015-v0-2-step-00` in:

/Users/augstar/macprovider-poc-spec015-v0-2-step-00

This review is scoped to SPEC-015 v0.2 implementation Step 0:
the coordinator buyer-port endpoint
`GET /v1/receipt-keys/<provider_id>`.

This is a READ-ONLY audit. You MUST NOT modify any file.

## Required Reading

Read in this order:

1. `git show --stat --patch 951013d`
2. `specs/SPEC-015-receipts.md` §10.7
3. `specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` Step 0
4. `specs/SPEC-002-coordinator.md` FR-O2
5. `phase4-coordinator/internal/pool/provider.go`
   - `Provider.ReceiptPubkey`
   - `Provider.ReceiptPubkeyPrev`
   - receipt-key publication / rotation helpers
   - `Registry.Resolve`
6. `phase4-coordinator/internal/buyer/server.go`
7. `phase4-coordinator/internal/buyer/receipt_keys_test.go`
8. `phase4-coordinator/implementation-notes-spec-015-v0-2.md`
9. `phase4-coordinator/internal/ws/server_test.go` delta only,
   to confirm the race-harness-only change does not alter runtime
   behavior.

Do not inspect or modify any locked spec file beyond reading the
sections above.

## Review Scope

Focus on these dimensions:

1. Handler correctness
   - Endpoint is mounted on the coordinator buyer port, not the
     operator/provider port.
   - Endpoint is public/unauthenticated and does not require operator
     bearer auth.
   - Unknown `provider_id` returns HTTP 404 using the existing
     coordinator error envelope with `error.code == "provider_not_found"`.
   - Success responses set `Cache-Control: public, max-age=300`.
   - 404 and 429 responses do not set the success cache header.

2. SPEC-015 §10.7 response-shape compliance
   - Success body has exactly these four top-level keys:
     `provider_id`, `receipt_pubkey`, `receipt_pubkey_prev`,
     `fetched_at`.
   - `receipt_pubkey` is standard padded base64 for current ed25519
     pubkey bytes, or JSON null when absent.
   - `receipt_pubkey_prev` is JSON null outside the grace window, or
     an object with exactly `pubkey`, `rotated_at`, and `expires_at`.
   - `rotated_at`, `expires_at`, and `fetched_at` are UTC RFC3339
     strings.
   - Previous-key inclusion uses the same server-clock decision as
     the response timestamp and does not leak expired previous keys.

3. Redaction completeness
   - Confirm the implementation marshals an explicit response struct
     and never marshals `pool.Provider` directly.
   - Confirm the body cannot include operator-sensitive Provider
     fields, including but not limited to:
     `endpoint_url`, `hostname`, `connected_at`, `slots_total`,
     `slots_free`, `throughput_tps_estimate`, `model_id`,
     `assigned_id`, `binary_version`, `auth_state`, `tier`,
     `state`, `last_heartbeat_at`, `last_activity_at`, `model_hash`,
     `supported_models`, or any Tier-2/session internals.
   - Check both success and error paths for accidental leakage.

4. Rate-limit correctness under concurrency
   - Required behavior is 10 req/sec/IP token bucket.
   - Overage must return HTTP 429 and `Retry-After: 1`.
   - Limiter state must be in coordinator memory and safe under
     concurrent requests.
   - Confirm source-IP keying behavior is deliberate and documented.
   - Confirm limiter eviction bounds memory without breaking the
     token-bucket contract for normal use.
   - Look for off-by-one, refill, burst, clock, and race issues.

5. Test adequacy
   - Confirm tests cover:
     - current key only
     - previous key in grace window
     - current key null for legacy providers
     - unknown provider 404
     - 429 after 11 same-IP requests within one second
     - top-level JSON key whitelist / sensitive-field exclusion
     - cache header present only on success
     - concurrent different-IP requests under `-race`
   - Identify any missing high-value tests, especially around expired
     previous keys, malformed path IDs, or proxy/IP assumptions.

## Validation Command

If you run commands, use:

```bash
cd phase4-coordinator
go vet ./...
go test ./... -race -count=1
```

## Output Contract

Return findings first, ordered by severity:

- CRITICAL: spec/security violation, redaction leak, wrong auth/port,
  or response shape incompatible with §10.7.
- MAJOR: concurrency/rate-limit bug, cache/error semantics bug, or
  missing required test that could hide a real violation.
- MINOR: maintainability, naming, documentation, or low-risk test gaps.

For each finding include:

- Severity
- File and line reference
- Evidence from code/spec/tests
- Concrete fix recommendation

If there are no CRITICAL or MAJOR findings, say that explicitly and
list any MINOR findings or residual risks.

=== END PROMPT ===
```
