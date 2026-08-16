# AUDIT_SPEC_015_v0_2_IMPL_STEP_5_PROMPT

Audit Step 5 of `BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md`: the
`phase7-verify/internal/cache` on-disk pubkey cache and
`phase7-verify/internal/resolver` `/v1/receipt-keys` resolver.

Scope is limited to Step 5 files and tests:

- `phase7-verify/internal/cache/cache.go`
- `phase7-verify/internal/cache/cache_test.go`
- `phase7-verify/internal/cache/implementation-notes.md`
- `phase7-verify/internal/resolver/resolver.go`
- `phase7-verify/internal/resolver/resolver_test.go`
- `phase7-verify/internal/resolver/implementation-notes.md`

Do not inspect or require Step 0 coordinator code; it is on a parallel branch.
Use the existing mock-server tests as the source of network behavior evidence.

## Audit Focus

1. Cache atomicity and crash recovery
   - Confirm writes use a same-directory temp file plus `os.Rename`.
   - Check whether readers can observe partial files under concurrent or
     cross-process access.
   - Confirm corrupt lines are skipped without hiding whole-file read failures.
   - Verify replacement is scoped to the exact
     `(coordinator_host, provider_id, receipt_pubkey)` tuple.

2. Resolver priority-rule completeness against SPEC-015 §10.2
   - Explicit pubkey wins in every explicit path.
   - Fresh cache skips live fetch.
   - Cache miss or stale cache triggers live fetch when online.
   - Offline without fresh cache returns `SourceNone`.
   - Live success writes cache before returning a live trust root.

3. SPEC-015 §10.5 network discipline
   - Exactly one `GET /v1/receipt-keys/<provider_id>` per live attempt.
   - No retries on 429, 5xx, timeout, or network errors.
   - Reject `http://` coordinator configuration.
   - Reject redirects to a different host and HTTPS downgrades.
   - Assert no network beyond `/v1/receipt-keys`: no `/poolz`, telemetry,
     version checks, analytics, crash reporting, or update checks.

4. Warning schema correctness against §10.4.2
   - Validate warning kinds and field names:
     `explicit_vs_live_divergence`, `live_check_skipped`,
     `non_default_coordinator`.
   - Validate `live_check_skipped.reason` enum values:
     `offline_flag`, `network_unreachable`, `provider_id_unresolvable`.
   - Confirm `--quiet` does not suppress warning records; it should only affect
     future stderr rendering.

5. Stale-cache-does-not-produce-valid invariant
   - A stale cache entry plus live network failure must return `SourceNone`, not
     `SourceCache`.
   - Treat any stale-cache fallback to a valid trust root as CRITICAL because it
     violates the S3 / round-1 SPEC audit invariant.

6. Typed error coverage
   - Confirm downstream-detectable sentinels exist and are tested:
     `ErrInsecureScheme`, `ErrInvalidProviderID`, `ErrProviderNotInPool`.
   - Check whether redirect and general fetch failures preserve enough typed
     information for Step 6/7 result mapping.

7. Non-default coordinator visibility
   - Every returned `ResolvedRoot`, including explicit, cache, live, and none
     paths, must carry `non_default_coordinator` when the coordinator host is not
     `coordinator.malibu.tech`.

## Expected Output

Return findings first, ordered by severity, with concrete file and line
references. Include a short residual-risk section only after findings.
