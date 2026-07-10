# IMPL audit prompt — SPEC-015 v0.3 IMPL Step 5 (Verifier CLI + algorithm + schema)

Audit Step 5 in `phase7-verify/`. Output: APPEND to
`specs/SPEC-015-v0-3-IMPL-STEP_5-audit.md`. Three lenses. VERDICT +
COUNTS per lens.

User policy: 0 CRITICAL + 0 HIGH + 0 MEDIUM target.

## What landed

- `phase7-verify/internal/receipt/receipt.go` — `Tuple` extended with
  `ReceiptVersion`, `ModelHash`, `ModelHashPresent`, `ModelHashNull`.
  v0.3 detection by PRESENCE of `receipt_version` field (NOT by field
  count). Strict 9-key shape for v0.3; strict 7-key shape for legacy.
  `model_hash` parsing distinguishes `null` literal from string
  (validated to 64-lowercase-hex pattern).
- `phase7-verify/internal/cli/cli.go` — 5 new flags:
  `--catalog`, `--catalog-url`, `--catalog-pubkey`, `--catalog-pubkey-url`,
  `--require-model-hash`. §M.3.1 mutually-exclusive validation
  (`--catalog` ↔ `--catalog-url`; pubkey pair; catalog implies pubkey;
  URL incompatible with `--offline`). §M.3.1.2 fail-closed flag plumbed
  through.
- `phase7-verify/internal/verify/verify.go` — `Result` extended with
  `ModelHashVerified` tri-state pointer + `ReceiptVersion` field;
  `VerifyOpts` extended with `Catalog CatalogOpts` + `RequireModelHash`.
  Output `MarshalJSON` always emits `model_hash_verified` (true / false /
  null) per §M.3.2.1 contract. New reason enum values + new warning kinds.
- `phase7-verify/internal/verify/catalog_check.go` — 8-step §M.3.2
  algorithm: catalog fetch (file / URL); pubkey fetch (file / URL);
  catalog Parse + Verify (signature + expiry); §M.3.2 step 6 case-folded
  Lookup; §M.3.2 step 7 hash equality. §M.1.1 legacy back-compat (skip
  catalog, emit `catalog_skipped_legacy_receipt` warning). §M.2.3
  null-hash path (skip catalog, emit `catalog_skipped_null_hash` warning).
  §M.3.1.2 `--require-model-hash` fail-closed on null-hash AND legacy.
- 6 new unit tests covering the catalog-check branches; existing
  v0.1/v0.2 tests preserved (full suite green).

## Severity definitions

- **CRITICAL** — catalog accepted under wrong base64 form; alg accepted
  lowercase; legacy receipt accepted as v0.3 (or vice versa); hash
  mismatch reported as `valid`; `model_hash_verified=true` returned
  when catalog check did not actually pass step 8; `--offline` ignored
  for URL-fetch flags; flag-combination matrix accepts a documented
  exit-64 case; third-party imports introduced.
- **HIGH** — AC-28..AC-42 / AC-32a / §M.5 acceptance gap; reason enum
  values diverge from §M.3.2.1; `model_hash_verified` emitted as
  absent (instead of `null`) when catalog check did not run; warning
  kinds emitted under wrong condition; receipt parser accepts a tuple
  with extra v0.3 fields under a legacy header AND vice versa;
  forward-compat (§M.1.4) unknown receipt_version path missing.
- **MEDIUM** — predictable bugs; missing tests on flag-combination
  edges; documentation gaps; output schema JSON drift; missing details
  block fields on the new reason values.
- **LOW** — polish.

## Constraints

1. SPEC-015 v0.3.3 LOCKED — no SPEC changes.
2. No locked-spec line-3 shifts.
3. `phase7-verify/` MUST stay pure-stdlib.
4. v0.1/v0.2 verifier behavior preserved (back-compat per §M.1.1).
5. The catalog package and cache from Step 4 are reused, not modified.

## Required reading

1. `specs/SPEC-015-receipts.md` §M.0 (tuple), §M.1.1 (back-compat),
   §M.1.2 (forward-incompat), §M.1.4 (unknown version), §M.2.3
   (null-hash), §M.3.1 (CLI flags), §M.3.1.1 (flag matrix), §M.3.1.2
   (--require-model-hash), §M.3.2 (8-step algorithm), §M.3.2.1
   (schema amendment), §M.3.3 (trust boundary), §M.5 AC-28..AC-42.
2. `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` Step 5.
3. `phase7-verify/internal/receipt/receipt.go` — v0.3 Tuple +
   `parseTuple` with version detection.
4. `phase7-verify/internal/cli/cli.go` — `parseOptions` + new flags +
   `buildCatalogOpts`.
5. `phase7-verify/internal/verify/verify.go` — Verify entry point +
   Result MarshalJSON.
6. `phase7-verify/internal/verify/catalog_check.go` — the catalog
   pipeline.
7. `phase7-verify/internal/verify/catalog_check_test.go` — coverage.
8. `phase7-verify/internal/verify/enum_drift_test.go` — verify the
   new enum values don't break the drift fence.

## Categories

CODE   C.1 v0.3 vs legacy version detection in `parseTuple`.
       C.2 Strict 9-key shape; reject extra / missing keys.
       C.3 model_hash null vs string parsing.
       C.4 CLI flag matrix (§M.3.1.1) — all documented exit-64 cases.
       C.5 8-step algorithm short-circuit ordering.
       C.6 model_hash_verified tri-state in JSON output.
       C.7 reason enum extension matches §M.3.2.1.
       C.8 warning kinds emitted under correct conditions.
       C.9 Catalog fetch network behaviour (5s budget, no retry).
       C.10 Pubkey fetch decode (base64url + capital-E alg).
       C.11 §M.1.4 unknown receipt_version forward-compat path.

SECURITY  S.1 Cannot bypass catalog check by mis-flagging.
          S.2 `--require-model-hash` cannot be silently disabled.
          S.3 Null-hash receipt cannot become valid+hash-attested.
          S.4 Hash mismatch cannot become `valid`.
          S.5 Catalog signature failure cannot be hidden.
          S.6 Network fetches honour `--offline`.
          S.7 No third-party imports.

ARCHITECT  A.1 Build-prompt Step 5 coverage.
           A.2 No locked-spec shifts.
           A.3 Composition with Step 4 catalog + cache.
           A.4 Composition with v0.2 receipt path (back-compat).
           A.5 §M.3.2.1 schema field-name contract on JSON output.
           A.6 §M.3.1.1 flag matrix correctness vs spec table.
           A.7 Forward-compat §M.1.4 unknown-version path.

Each finding cites file:line. End each lens with VERDICT + COUNTS.
