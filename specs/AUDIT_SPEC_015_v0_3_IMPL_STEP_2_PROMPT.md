# IMPL audit prompt — SPEC-015 v0.3 IMPL Step 2 (Coordinator /poolz catalog + 2 endpoints)

You are auditing the Step 2 implementation of SPEC-015 v0.3 model-hash binding
in `phase4-coordinator/` (Go coordinator). The controlling spec is
`specs/SPEC-015-receipts.md` v0.3.3 LOCKED. The build prompt is
`specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` Step 2.

Output: APPEND a section to
`specs/SPEC-015-v0-3-IMPL-STEP_2-audit.md` for your lens. Headers:
"## Lens — CODE — Round R", "## Lens — SECURITY — Round R",
"## Lens — ARCHITECT — Round R".

You are running ALL THREE lenses (CODE, SECURITY, ARCHITECT). End each
section with VERDICT + COUNTS (CRITICAL/HIGH/MEDIUM/LOW).

User policy: loop until **0 CRITICAL + 0 HIGH + 0 MEDIUM** for this step
before proceeding to Step 3. LOW findings can be deferred.

## Severity definitions

- **CRITICAL** — would cause: locked-spec line-3 version shift; SPEC-002
  v1.4 `/poolz` shape regression (e.g. removed/renamed an existing
  top-level key); operator-sensitive field leak in the new `/poolz`
  catalog fields or the two new endpoints; catalog file served despite
  failed signature verification or wrong catalog_id; `/catalog/pubkey`
  emitting standard padded base64 instead of base64url-unpadded;
  `/catalog/pubkey` emitting lowercase `"ed25519"` instead of the
  capital-E `"Ed25519"` matching `scripts/sign-catalog.go:142-145` +
  `phase4-coordinator/internal/tier2/catalog.go:470` + SPEC-015
  v0.3.3 §M.4; missing operator authentication on the operator-only
  surface (`/poolz` remains operator-only); operator authentication
  added to the new public endpoints (which would defeat their public
  trust posture).

- **HIGH** — would cause: AC-39 / §M.4 acceptance failure on a
  deterministic test; catalog fields emitted under wrong precondition
  (e.g. when CatalogPath is set but catalog failed to load); URL
  construction edge cases producing malformed absolute URLs (host
  with port, IPv6 host, X-Forwarded-Host); 404 envelope schema
  divergence from existing buyer endpoint pattern; rate-limit
  semantics that share buckets across endpoints in a buyer-visible
  way; missing tests for the §M.4 effectively-active condition's
  three branches (no path / load failed / signature failed); SPEC-008
  hash semantics regression (this step does NOT change them — verify).

- **MEDIUM** — would cause: code that diverges from existing house
  style; missing comments documenting the §M.4 / §M.3.3 trust posture;
  under-specified edge cases not tested; minor inconsistencies in
  error envelope `code` values; documentation gaps that would mislead
  the Step 5 verifier author.

- **LOW** — quality polish; deferrable to v0.3.x+1.

## Critical constraints

1. **SPEC-015 v0.3.3 is LOCKED.** Any required SPEC change = CRITICAL.
2. **No locked-spec line-3 version shifts.** Verify via
   `git diff main -- 'specs/SPEC-{001,002,005,006,008,010,011,013}-*.md'`.
3. **SPEC-002 v1.4 `/poolz` shape MUST remain additive.** v0.3 only
   adds three top-level optional fields per §M.4. Verify the existing
   `pool` + `summary` top-level keys are byte-identical to v0.2
   behavior.
4. **Operator-only routing is preserved.** `/poolz` remains operator-
   only (existing behavior); the two new catalog endpoints are public
   on the buyer port. Verify they are NOT registered on the operator
   port and DO NOT inherit operator auth.
5. **Catalog parser unchanged.** This step reuses the existing
   `tier2.Default().Active()`, `tier2.CatalogID()`, `cfg.CatalogPath`
   reads. v0.3 does not modify the catalog parser; verify nothing in
   `phase4-coordinator/internal/tier2/` was touched.

## Required reading

1. `specs/SPEC-015-receipts.md` v0.3.3 §M.4 (entire section), §M.3.3
   trust boundary, §M.5 AC-39 (test commands).
2. `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` Step 2 (entire
   step's "What lands" and "Tests" list).
3. `phase4-coordinator/internal/config/config.go` — the new
   `PublicCatalogBaseURL` field.
4. `phase4-coordinator/internal/ws/server.go` — `handlePoolz` with the
   new poolzResponse + `catalog_*` field-presence rule.
5. `phase4-coordinator/internal/buyer/server.go` — the two new
   handlers (`handleCatalogFile`, `handleCatalogPubkey`) and their
   route registrations.
6. `phase4-coordinator/internal/buyer/catalog_endpoints_test.go` —
   the new endpoint tests.
7. `phase4-coordinator/internal/ws/poolz_catalog_test.go` — the
   /poolz catalog-fields tests.
8. `phase4-coordinator/cmd/coordinator/main.go` lines 631-660 —
   tier2ReloadFieldClasses table now includes
   PublicCatalogBaseURL.
9. `scripts/sign-catalog.go` lines 90, 142-145 — the catalog file
   format the endpoints serve and the `Ed25519` alg + base64url-
   unpadded pubkey shape.
10. `phase4-coordinator/internal/tier2/catalog.go` lines 246-260,
    334 — the `Active()` and `CatalogID()` accessors.
11. `beta/DECISION_CRITERIA.md` Entry 80 — verify
    `RequireHashVerified` is unchanged.
12. The v0.2 §10.7 receipt-keys handler at
    `phase4-coordinator/internal/buyer/server.go:694` — verify the
    new handlers follow the same shape (rate limit, cache headers,
    error envelope).

## Lens-specific categories

### CODE lens

C.1  `/poolz` extension — verify the three fields appear ONLY under
     the §M.4 three-condition rule (`tier2.Active()`), and the
     existing `pool` + `summary` keys are unchanged.
C.2  URL construction — when `PublicCatalogBaseURL` is empty, verify
     the fallback derives from `r.Host` + scheme; verify trailing
     slash handling; verify the URL form `<base>/catalog/<id>` and
     `<base>/catalog/pubkey` match §M.4 exactly.
C.3  `/catalog/<catalog_id>` — verify it serves the on-disk catalog
     bytes verbatim with `Content-Type: application/json` and
     `Cache-Control: public, max-age=300`; verify 404 when no catalog
     OR wrong id; verify error envelope code is `catalog_not_found`.
C.4  `/catalog/pubkey` — verify response shape `{"pubkey":"<43-char
     base64url-unpadded>","alg":"Ed25519"}` matches §M.4 EXACTLY;
     verify the `pubkey` value is `cfg.CatalogPublicKey` verbatim
     (already in base64url form per `scripts/sign-catalog.go:90`).
C.5  Rate limiting — verify the new endpoints share the existing
     receipt-keys bucket OR define their own; verify 429 + Retry-
     After: 1 on overage; verify behavior under concurrent requests.
C.6  Error envelope — verify the new handlers use the same
     `writeError` helper / JSON shape as the v0.2 receipt-keys
     handler.
C.7  PublicCatalogBaseURL config field — verify yaml tag, default
     value handling, and the tier2ReloadFieldClasses entry.

### SECURITY lens

S.1  Operator-only `/poolz` auth UNCHANGED. Verify the new code
     doesn't accidentally weaken `s.authorizedOperator(r)` checks.
S.2  Public-trust posture of the two new endpoints — verify NO
     authentication is added (this is intentional per §M.4 +
     v0.2 §10.7 precedent), and that the rate limiter prevents
     resource exhaustion.
S.3  Catalog file leakage — verify the on-disk catalog file path is
     a known operator-configured path (`cfg.CatalogPath`); verify no
     path traversal possible via `<catalog_id>` URL param (the param
     is compared to `tier2.CatalogID()`, NOT used as a filename).
S.4  Catalog pubkey leakage — verify `cfg.CatalogPublicKey` is the
     SAME key the coordinator already verifies catalogs against;
     v0.3 publishes it to buyers per §M.3.3 trust posture. Verify
     the operator's catalog signing PRIVATE key is NOT exposed.
S.5  Catalog-fields presence rule — verify the three §M.4 fields
     are ABSENT (not present-with-null) when the §M.4
     effectively-active condition fails. Absence prevents buyers
     from trusting a stale URL after a catalog rotation.
S.6  Rate limit — verify the shared bucket prevents a single
     attacker from exhausting either endpoint independently;
     verify the IP key is the same `poolCheckClientKey(r)`
     used by `handleReceiptKeys`.
S.7  /poolz operator-sensitive fields — verify the new code DOES
     NOT expose `endpoint_url`, `hostname`, etc. in the catalog
     fields (those are catalog-level, not per-provider).
S.8  Concurrent access — verify `tier2.Active()`, `tier2.CatalogID()`,
     `cfg.CatalogPath` reads are safe under concurrent reload
     (SIGHUP). The atomic Catalog pointer pattern from M3-8d should
     handle this; verify no new race conditions.

### ARCHITECT lens

A.1  BUILD prompt Step 2 coverage — every "What lands" + "Tests"
     item appears in the implementation.
A.2  SPEC-002 v1.6 candidate annotation discipline — the three
     `/poolz` fields and the two new endpoints follow the v1.4
     receipt_pubkey / v1.5 receipt-keys candidate-annotation pattern
     (additive, parser-optional, non-breaking).
A.3  No locked-spec line-3 shifts.
A.4  No changes to `phase4-coordinator/internal/tier2/`. The catalog
     parser/verifier is reused, not amended.
A.5  Entry 80 orthogonality — `RequireHashVerified` is unchanged;
     this step is purely surface-level annotation for §M.4.
A.6  Composition with v0.2 §10.7 — the new endpoints share auth
     posture, rate-limit posture, cache header posture with
     `/v1/receipt-keys/`. Inconsistency = MAJOR.
A.7  Nginx proxy — Step 3 (not this step) handles the nginx config;
     verify nothing in Step 2 implies a nginx change at deploy time.
A.8  Test coverage gaps — verify AC-39 has both positive AND
     negative tests (catalog active vs absent).

## What MUST be in every finding

- Source file + line range.
- Severity tag.
- One-sentence problem.
- One-paragraph elaboration with file:line citations.
- Suggested resolution direction (NOT a fix).

End each lens with VERDICT + COUNTS.
