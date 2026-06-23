# AUDIT_SPEC_015_v0_2_IMPL_STEP_6_PROMPT

Audit Step 6 of `BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md`: the
`phase7-verify/internal/verify` verification orchestrator.

Scope is limited to Step 6 files and tests:

- `phase7-verify/internal/verify/verify.go`
- `phase7-verify/internal/verify/verify_test.go`
- `phase7-verify/internal/verify/implementation-notes.md`

Do not modify locked normative specs. Do not require Step 7 CLI parsing or
Step 8 output formatting to exist. Treat Steps 2/3/4/5 as dependencies to be
consumed through their public internal package APIs unless a Step 6 bug is only
explainable through their behavior.

## Audit Focus

1. SPEC-015 §10.0 algorithm step-by-step correctness
   - Confirm the orchestrator parses the receipt before trust-root resolution.
   - Confirm tuple raw bytes are passed to ed25519 verification unchanged.
   - Confirm resolver output is the only online trust-root source.
   - Confirm canonical prompt comparison happens before canonical output
     comparison.
   - Confirm clock-skew handling runs only as an informational warning and does
     not alter the result.

2. Tri-state distinctness
   - `valid` requires signature verification, canonical prompt/output hash
     matches, and a trusted pubkey source.
   - `invalid` covers signature failure, prompt hash mismatch, output hash
     mismatch, pubkey not endorsed, and previous-key outside grace.
   - `inconclusive` covers unresolved trust roots, stale-cache plus live
     failure, missing provider identity after resolver classification, and
     provider not in pool.
   - No path may report `valid` when resolver source is `none`.
   - No authoritative key no-match may collapse into `inconclusive`.

3. §10.4.2 reason enum coverage
   - Every returned `Result` must emit one documented enum value.
   - Validate exact strings for:
     `signature_and_canonicalization_match`,
     `signature_verify_failed`,
     `prompt_hash_mismatch`,
     `output_hash_mismatch`,
     `pubkey_not_endorsed`,
     `previous_key_outside_grace_window`,
     `pubkey_unresolvable`,
     `provider_id_unresolvable`,
     `cache_stale_and_live_unreachable`,
     and `provider_id_not_in_pool`.
   - Confirm malformed receipt input returns typed errors for Step 7 exit 65
     mapping instead of inventing non-enum result reasons.

4. §10.2.1 grace-window boundary correctness
   - Previous-key verification may only use `receipt_pubkey_prev.pubkey`.
   - The accepted interval is inclusive on both ends:
     `rotated_at - 60s <= unix_ts <= expires_at`.
   - `unix_ts == rotated_at - 60s` must be valid.
   - `unix_ts == expires_at` must be valid.
   - `unix_ts > expires_at` and `unix_ts < rotated_at - 60s` must be invalid
     with `previous_key_outside_grace_window`.
   - A previous-key match must verify the signature against the previous key,
     not the current key.

5. Warning kind taxonomy
   - Resolver warnings are preserved in order:
     `live_check_skipped`, `explicit_vs_live_divergence`,
     `non_default_coordinator`.
   - Verify adds only `clock_skew`.
   - `clock_skew` fields are exactly `unix_ts`, `system_time`, and
     `delta_seconds`.
   - `--quiet`/`VerifyOpts.Quiet` must not suppress warning records.

6. AC-18 through AC-27 mapping
   - AC-18: valid live current-key path.
   - AC-19: response content mutation -> `output_hash_mismatch`.
   - AC-20: request content mutation -> `prompt_hash_mismatch`.
   - AC-21: tuple byte mutation -> `signature_verify_failed` before hash
     mismatch reporting.
   - AC-22: live unreachable, no cache, no explicit pubkey -> `inconclusive`
     with network-unreachable warning.
   - AC-23: offline explicit pubkey -> valid with zero network traffic.
   - AC-24: `Result` JSON tags/shape are ready for Step 8 schema formatting.
   - AC-25: result-state-to-exit-code mapping and typed error split are
     documented/testable for Step 7.
   - AC-26: stale cache triggers live fetch and live failure does not reuse the
     stale entry as valid.
   - AC-27: previous-key grace success and out-of-window failure.

7. No bypass paths
   - Explicit pubkey must skip resolver pubkey endorsement comparison but still
     verify the ed25519 signature against the explicit key.
   - Explicit wrong-key signatures must be invalid.
   - Canonicalization mismatch must not be masked by a fast path after
     signature success.
   - Receipt embedded `provider_pubkey` must never be trusted when resolver
     returns `SourceNone`.
   - The verifier must not scan all known cached providers to find a matching
     pubkey.

8. No Step 7 / Step 8 scope creep
   - Step 6 should not parse CLI flags, read bundle files, print human output,
     decide process exit codes, or publish JSON Schema documents.
   - Step 6 may expose typed errors and JSON tags because later steps need a
     stable API, but formatting policy remains outside this package.

## Verification Expected From The Auditor

Run at minimum:

```bash
cd phase7-verify
go vet ./internal/verify/...
go test ./internal/verify/... -race -count=1 -v
go test ./... -race -count=1
```

Confirm `go.sum` remains unchanged.

## Expected Output

Return findings first, ordered by severity, with concrete file and line
references. Include a short residual-risk section only after findings.
Call out any missing AC mapping explicitly. The Step 6 implementation is
acceptable only with zero CRITICAL, HIGH, or MEDIUM findings.
