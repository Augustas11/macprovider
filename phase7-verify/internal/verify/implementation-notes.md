# Verification Orchestrator Implementation Notes

## Algorithm Ordering

`Verify` follows SPEC-015 §10.0 in the verifier-owned order:

1. Parse the receipt header with `receipt.Parse`.
2. Let Step 3 tuple validation stand; `Verify` does not duplicate it.
3. Resolve a trust root with `resolver.Resolve`.
4. For resolver-derived roots, compare the receipt's embedded
   `provider_pubkey` to the current key first, then to
   `receipt_pubkey_prev.pubkey` when present.
5. When the previous key matches, enforce §10.2.1 before signature
   verification: `rotated_at - 60s <= unix_ts <= expires_at`.
6. Run ed25519 verification through `receipt.Verify` using the selected
   trusted key: explicit key, current key, or previous key.
7. Canonicalize the buyer-held request via `canon.CanonicalPrompt` and compare
   `prompt_hash`.
8. Canonicalize the buyer-held response via `canon.CanonicalOutput` and compare
   `output_hash`.
9. Add the verify-owned `clock_skew` warning when applicable and return
   `valid`.

This ordering makes signature failure win over prompt/output mismatch for a
mutated tuple, while still rejecting an unendorsed or out-of-window pubkey before
the verifier spends work on canonicalization.

## Parse Errors vs Invalid Results

`receipt.Parse` failures are returned as `*InputFormatError`, not as
`Result{Result: "invalid"}`. Step 7 can map that typed error to exit 65 for
malformed receipt input, preserving the §10.1 split between malformed input and
a parsed receipt that fails verification.

`Verify` returns `*UsageError` for invocation-level problems that are not
receipt-verification outcomes, such as missing receipt data or request/response
bodies that cannot be canonicalized. Step 7 can map these to exit 64.

Once parsing succeeds, cryptographic, canonical-hash, pubkey-endorsement, and
grace-window failures return a tri-state `Result` with `result: "invalid"` and
one of the §10.4.2 reason enum values.

`bundle_pubkey_provider_mismatch` is a reserved enum value; v0.2 verifier paths
emit `pubkey_not_endorsed` for receipt-pubkey-vs-resolver-pubkey divergence. A
future spec revision may define a narrower bundle-layer detection that
distinguishes intra-bundle identity drift; the schema/enum is
forward-compatible.

### Reserved-reason convention

`TestReasonEnumBijection` (`enum_drift_test.go`) AST-walks this package's
`reasonXxx` string constants and fails if any are declared but never
referenced in non-test source. To declare a constant that is intentionally
reserved for a future SPEC revision (like `reasonBundlePubkeyProviderMismatch`
above), open the constant's doc comment with the literal token
`FORWARD-COMPAT` or `RESERVED` at the start of a line (optionally after a
list-marker prefix like `*` or `-`). Natural forms accepted:

- `// FORWARD-COMPAT v0.3+: reserved for ...`
- `// RESERVED (do not delete)`
- `// * RESERVED *`

Prose negations like `// NOT RESERVED`, `// DEFINITELY NOT-RESERVED`, or
`// may someday be RESERVED` do NOT silence the check — the marker must
lead its line. The pinned contract lives in `TestReservedMarkerRE`.

## Warning Merge Strategy

The resolver owns trust-root warnings:

- `live_check_skipped`
- `explicit_vs_live_divergence`
- `non_default_coordinator`

`Verify` copies resolver warnings into `Result.Warnings` without suppression;
`Quiet` remains a CLI/reporting concern. The orchestrator appends only one
verify-owned warning kind: `clock_skew`.

`SourceNone` reason mapping uses resolver warnings plus cache metadata:

- `provider_id_unresolvable` warning -> `pubkey_unresolvable`
- `network_unreachable` with stale cache entries -> `cache_stale_and_live_unreachable`
- `network_unreachable` without stale cache -> `pubkey_unresolvable`
- resolver `ErrProviderNotInPool` -> `provider_id_not_in_pool`

## Clock Skew

The clock-skew threshold is exactly 24 hours:

`abs(receipt.unix_ts - opts.Now().Unix()) > 24 * 3600`

The warning fields are `unix_ts`, `system_time`, and `delta_seconds`. Per
SPEC-015 §10.6, this warning is informational only. It never downgrades a
receipt from `valid` to `invalid` or `inconclusive` because the signed timestamp
commits to a claimed value, not to real wall-clock honesty.

## Scope Boundary

This package does not parse CLI flags, decode bundle JSON, map results to
process exit codes, or implement final JSON/human output formatting. Those
remain Step 7 and Step 8 responsibilities.
