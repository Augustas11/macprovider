# IMPL audit prompt — SPEC-015 v0.3 IMPL Step 4 (Verifier catalog parser + cache)

You are auditing Step 4 in `phase7-verify/`. Output: APPEND to
`specs/SPEC-015-v0-3-IMPL-STEP_4-audit.md`. Three lenses (CODE,
SECURITY, ARCHITECT). VERDICT + COUNTS per lens.

User policy: 0 CRITICAL + 0 HIGH + 0 MEDIUM target.

## What landed

- `phase7-verify/internal/catalog/catalog.go` — pure-stdlib hand
  translation of the coordinator's tier2 catalog parser/verifier.
  `Parse(data)` returns a typed `*Catalog` with strict schema
  validation (unknown fields rejected, sha256 pattern enforced,
  duplicate model_id rejected on the canonical case-folded key).
  `Verify(c, pubkey, now)` reconstructs the canonical body and
  runs `ed25519.Verify`, then checks expiry with the 60-second
  skew grace per §M.3.2 step 5. `Lookup(c, modelID)` returns the
  catalog entry under `catalogModelKey` (lowercase + trim), mirroring
  the coordinator's match function.
- `phase7-verify/internal/cache/catalog/catalog_cache.go` —
  on-disk cache implementing the §M.3.4 three-band TTL
  (`ComputeTTL`). Cache keyed by SHA-256 of catalog URL; pubkey
  rotation invalidates via comparison on read. Stale entries miss.

## Severity definitions

- **CRITICAL** — catalog accepted despite bad signature; pubkey
  decoded with wrong base64 form (`StdEncoding` instead of
  `RawURLEncoding`); alg accepted in lowercase; canonical body
  marshalled in the wrong key order (would break verification of
  catalogs produced by `scripts/sign-catalog.go`); third-party
  imports introduced (breaks pure-stdlib discipline); cache hit
  on rotated pubkey; cache hit on stale entry.
- **HIGH** — AC-35 / §M.3.2 step 4 acceptance gap (the verifier
  doesn't reject every documented failure mode); cache TTL band
  off-by-one at the 60s / 6h boundary; expiry grace boundary
  off-by-one at the 60s edge; case-fold lookup diverges from the
  coordinator's `strings.ToLower(strings.TrimSpace(...))`.
- **MEDIUM** — predictable bugs; documentation gaps; missing
  parity test against the existing `scripts/sign-catalog.go`
  canonical body shape.
- **LOW** — polish; deferrable.

## Constraints

1. SPEC-015 v0.3.3 LOCKED.
2. No locked-spec line-3 shifts.
3. `phase7-verify/` MUST stay pure-stdlib (no third-party
   imports). Verify by `cd phase7-verify && go list -m all`.
4. The catalog parser MUST NOT import the coordinator's `tier2`
   package — it's a hand translation per the v0.2 IMPL discipline.

## Required reading

1. `specs/SPEC-015-receipts.md` §M.3.1, §M.3.2 (8-step algorithm),
   §M.3.4 (cache TTL), §M.3.3 (trust boundary).
2. `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` Step 4.
3. `phase7-verify/internal/catalog/catalog.go` — the parser and
   `Verify`.
4. `phase7-verify/internal/catalog/catalog_test.go` — the test
   surface (9 cases).
5. `phase7-verify/internal/cache/catalog/catalog_cache.go` — the
   cache implementation.
6. `phase7-verify/internal/cache/catalog/catalog_cache_test.go` —
   the TTL band + rotation + stale tests.
7. `scripts/sign-catalog.go` — particularly lines 31 (sha256
   field name), 42-49 (canonical body key order), 90 (pubkey
   base64.RawURLEncoding), 142-145 (Ed25519 capital E), 145 (sig
   RawURLEncoding).
8. `phase4-coordinator/internal/tier2/catalog.go` — particularly
   lines 470 (alg validator), 479-485 (pubkey + sig decoding),
   559-560 (`catalogModelKey`).
9. `phase7-verify/go.mod` — verify no new third-party imports.

## Categories

CODE  C.1 Parse strictness — unknown-field rejection, sha256 regex,
          dup model_id detection on canonical key, RFC3339 strict.
      C.2 Verify alg casing — only `"Ed25519"` accepted.
      C.3 Pubkey + signature base64 forms — `RawURLEncoding` both.
      C.4 Canonical body key order — matches sign-catalog.go.
      C.5 Lookup case-fold — matches coordinator catalogModelKey.
      C.6 Expiry grace — 60s boundary on either side tested.
      C.7 Cache `ComputeTTL` — 3 bands tested at boundaries.
      C.8 Cache rotation invalidation.
      C.9 Cache stale invalidation.
      C.10 Pure-stdlib discipline (no new imports).

SECURITY  S.1 Signature verification cannot be bypassed.
          S.2 Tampered body produces ErrSignatureInvalid.
          S.3 Tampered signature produces ErrSignatureInvalid.
          S.4 Expired catalog produces ErrExpired.
          S.5 Cache cannot serve a stale-signed catalog.
          S.6 Cache cannot serve under a rotated pubkey.
          S.7 File mode 0600 on cache writes (no operator
              secrets leak — the catalog is public, but pubkey
              binding is part of the cache integrity).
          S.8 No timing leaks in alg / sig comparisons (use
              `ed25519.Verify`; do NOT compare alg with
              non-constant-time helpers — but the alg is a
              short ASCII string so this is informational).

ARCHITECT  A.1 Build prompt Step 4 coverage.
           A.2 No locked-spec shifts.
           A.3 No third-party imports.
           A.4 Catalog package does NOT import coordinator tier2.
           A.5 Composition with Step 1 wire shape (catalog sha256
               matches the SPEC-011 raw 64-hex form Step 1 binds).
           A.6 Parity test against scripts/sign-catalog.go shape.

Each finding cites file:line. End each lens with VERDICT + COUNTS.
