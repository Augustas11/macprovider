# Pubkey Resolver Implementation Notes

## Priority Semantics

`Resolve` follows SPEC-015 §10.2 in order:

1. Explicit pubkey wins. Offline mode returns it immediately and records
   `live_check_skipped` with `reason=offline_flag`.
2. Explicit pubkey online still attempts one live fetch when `provider_id` is
   available. A differing live key records `explicit_vs_live_divergence`, but the
   explicit key remains the trust root.
3. Without an explicit pubkey, a fresh cache entry for the coordinator/provider is
   used as `SourceCache` and live fetch is skipped.
4. Without a fresh cache entry, the resolver performs one live fetch. Success
   writes the cache and returns `SourceLive`.
5. Offline without a fresh cache returns `SourceNone` with
   `live_check_skipped reason=offline_flag`.

The Step 5 `Resolve` API does not receive the receipt's embedded pubkey, so cache
selection uses the freshest provider entry. The cache package still exposes exact
pubkey lookup for Step 6 verification.

## Network Discipline

The only live request is:

`GET https://<coordinator-host>/v1/receipt-keys/<provider_id>`

Enforcement points:

- `provider_id` must match `^[A-Za-z0-9_-]+$` before URL construction.
- `http://` coordinator URLs fail with `ErrInsecureScheme`.
- The default client timeout is 5 seconds.
- No retry loop is implemented; each resolver call issues at most one initial GET.
- Redirects are followed only when the redirected URL remains `https` and the
  host equals the configured coordinator host.
- `User-Agent` is `macprovider-verify/<internal/version.BinaryVersion>`.
- There are no telemetry, version-check, analytics, crash-report, `/poolz`, or
  other network calls.

## Warning Schema

Warnings map directly to SPEC-015 §10.4.2:

- `explicit_vs_live_divergence`: fields `live_pubkey`, `coordinator_host`.
- `live_check_skipped`: field `reason`, using `offline_flag`,
  `network_unreachable`, or `provider_id_unresolvable`.
- `non_default_coordinator`: field `coordinator_host`.

`ResolveOpts.Quiet` is intentionally not used to suppress warning records.
Quiet-mode stderr suppression belongs at the CLI/reporting layer.

## Stale Cache Invariant

When live fetch fails and only stale cache exists, `Resolve` returns
`SourceNone`, not `SourceCache`. This preserves the S3 / round-1 SPEC audit
invariant: stale coordinator attestations cannot produce a `valid` result. The
caller can map this to `inconclusive` with `cache_stale_and_live_unreachable` or
`pubkey_unresolvable` depending on final Step 6/7 result construction.

## Typed Errors

The resolver exposes typed sentinels for downstream mapping:

- `ErrInsecureScheme`
- `ErrInvalidProviderID`
- `ErrProviderNotInPool`
- `ErrRedirectOffHost`
- `ErrFetchFailed`

`ErrProviderNotInPool` is returned with `SourceNone` so the verifier can report
`provider_id_not_in_pool` without downgrading the receipt to `invalid`.
