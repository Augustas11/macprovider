## Lens — CODE — Round 1

### HIGH C-1 — Catalog version is not pinned to the supported signer/coordinator schema

- Evidence: `phase7-verify/internal/catalog/catalog.go:108-110` accepts any positive `version`, while the coordinator hand-translation reference rejects anything other than `1` at `phase4-coordinator/internal/tier2/catalog.go:454-456`.
- Why it matters: §M.3.2 step 3 says the verifier parses the coordinator `catalogFile` schema and the Step 4 prompt requires identical accept/reject decisions with the coordinator. A signature-valid `version: 2` catalog is currently accepted under v1 semantics instead of failing closed as `catalog_format_invalid`.
- Validation: temp probe signed a `version: 2` catalog with the same canonical body shape; `Parse` and `Verify` both accepted it.
- Fix: require `f.Version == 1` in `Parse`, and add a regression test for signed `version: 0`, `version: 2`, and missing/wrong-type `version`.

### HIGH C-2 — Required catalog fields are not all enforced before signature acceptance

- Evidence: `phase7-verify/internal/catalog/catalog.go:125-137` validates only `model_id` and `sha256` for each model entry; it does not reject empty/missing `artifact_kind`, `hash_scope`, or `source`. `phase7-verify/internal/catalog/catalog.go:174-185` validates `signature.alg` and `signature.sig`, but never rejects empty/missing `signature.key_id`; the coordinator rejects empty `key_id` at `phase4-coordinator/internal/tier2/catalog.go:473-475`.
- Why it matters: §M.3.2 step 3 defines `{artifact_kind, hash_scope, model_id, notes?, sha256, source}` and `signature{alg, key_id, sig}` as the schema, with missing required fields mapped to `catalog_format_invalid`. Since the signature excludes the `signature` object, empty or omitted `key_id` does not break Ed25519 verification and is accepted today.
- Validation: temp probe signed catalogs with empty `artifact_kind`, `hash_scope`, `source`, and `key_id`; `Parse` and `Verify` accepted them.
- Fix: validate non-empty required string fields for `artifact_kind`, `hash_scope`, `source`, `signature.key_id`, and `signature.sig` during parse/verify, with explicit regression tests for missing and empty forms.

### MEDIUM C-3 — Parity test does not actually exercise `scripts/sign-catalog.go`

- Evidence: `phase7-verify/internal/catalog/catalog_test.go:224-258` labels the case as signer parity, but it constructs the canonical bytes using the verifier package's own `canonicalBody` and `json.Marshal`. It does not invoke `scripts/sign-catalog.go` or consume a golden file emitted by that tool.
- Why it matters: the Step 4 audit prompt names missing parity against the existing signer as a MEDIUM finding. This test can pass even if both the implementation and test drift together away from the signer.
- Fix: add a real parity fixture path: generate signed catalogs with `scripts/sign-catalog.go` or check in signer-produced golden catalogs, including randomized model order/field values.

VERDICT: NOT READY

COUNTS: CRITICAL 0, HIGH 2, MEDIUM 1, LOW 0

## Lens — SECURITY — Round 1

### HIGH S-1 — Verifier fails open for signature-valid catalogs outside the documented schema

- Evidence: `phase7-verify/internal/catalog/catalog.go:108-110` accepts future positive versions; `phase7-verify/internal/catalog/catalog.go:125-137` leaves required model metadata unchecked; `phase7-verify/internal/catalog/catalog.go:174-185` does not require `signature.key_id`. The locked §M.3.2 step 3 schema and coordinator reference reject these malformed cases.
- Why it matters: this is not a raw signature bypass; tampered body/signature tests exist and pass. The security issue is fail-open schema acceptance: a catalog signed by the trusted key but malformed or from a future incompatible schema can still become buyer-valid input. The verifier should reject every documented catalog-format failure before using the catalog for model-hash trust.
- Fix: fail closed on unsupported version and missing/empty required schema fields, returning typed format/signature errors that Step 5 can map to `catalog_format_invalid` or `catalog_signature_invalid`.

### MEDIUM S-2 — Boundary coverage is incomplete for expiry and external signer parity

- Evidence: expiry tests cover clearly within grace (`phase7-verify/internal/catalog/catalog_test.go:175-193`) and clearly beyond grace (`phase7-verify/internal/catalog/catalog_test.go:150-173`), but not exactly `expires_at + 60s` or just over it. The signer parity test at `phase7-verify/internal/catalog/catalog_test.go:224-258` is self-generated, not signer-generated.
- Why it matters: the code appears to implement the §M.3.2 step 5 `now > expires_at + 60s` boundary correctly at `phase7-verify/internal/catalog/catalog.go:202-207`, but the audit prompt calls the 60s edge and signer parity out as high-risk regression surfaces.
- Fix: add exact-boundary expiry tests (`+60s` accepted, `+60s+1ns` or `+61s` rejected) plus real signer-produced catalog fixtures.

VERDICT: NOT READY

COUNTS: CRITICAL 0, HIGH 1, MEDIUM 1, LOW 0

## Lens — ARCHITECT — Round 1

### HIGH A-1 — The verifier/coordinator accept-reject contract is not equivalent

- Evidence: Step 4 requires a hand translation of `phase4-coordinator/internal/tier2/catalog.go` with identical accept/reject decisions. The verifier accepts any positive version at `phase7-verify/internal/catalog/catalog.go:108-110`; coordinator requires `version == 1` at `phase4-coordinator/internal/tier2/catalog.go:454-456`. The verifier also omits required `signature.key_id` validation while the coordinator enforces it at `phase4-coordinator/internal/tier2/catalog.go:473-475`.
- Why it matters: Step 4 is the foundation for Step 5's verifier decision path. If buyer-side verification and coordinator-side catalog loading disagree, the system can publish or reject different catalog states depending on which component evaluates them.
- Fix: centralize the verifier's validation checklist around the coordinator schema fields and add table tests that mirror the coordinator's rejection cases.

### MEDIUM A-2 — Cache entry shape drifts from the §M.3.4 contract

- Evidence: §M.3.4 and the Step 4 prompt require cache entries to include `{catalog_bytes, catalog_pubkey_b64, fetched_at, expires_at, catalog_url}`. The implementation stores `catalog_pubkey_b64url` and `expires_at_cache` at `phase7-verify/internal/cache/catalog/catalog_cache.go:37-44`, not the named `catalog_pubkey_b64` and catalog `expires_at`.
- Why it matters: storing an absolute cache-expiry timestamp is useful, but replacing catalog `expires_at` with cache expiry loses the original catalog validity metadata that later Step 5 diagnostics/details may need. The field-name drift also makes the on-disk contract harder for future tooling to consume.
- Fix: store both the original catalog `expires_at` and the computed cache expiry, or align the field names with §M.3.4 while keeping TTL enforcement explicit.

### MEDIUM A-3 — Signer parity is asserted by local reconstruction instead of an external contract

- Evidence: `phase7-verify/internal/catalog/catalog_test.go:224-258` uses the verifier package's `canonicalBody`, so it validates internal consistency rather than compatibility with `scripts/sign-catalog.go`.
- Why it matters: Step 4 exists to consume the production signer output byte-for-byte. The architecture needs a contract test at that boundary, not only a unit test sharing the implementation's canonicalization assumptions.
- Fix: add signer-produced golden fixtures or a controlled `go run ../scripts/sign-catalog.go sign ...` parity test for multiple catalog bodies.

VERDICT: NOT READY

COUNTS: CRITICAL 0, HIGH 1, MEDIUM 2, LOW 0

## Lens — CODE — Round 2

No CODE findings.

Round 2 re-audit covered C.1-C.10 after the fix pass, plus two coordinator-equivalence gaps found during this audit and fixed before verdict:

- `phase7-verify/internal/catalog/catalog.go:97-100` now routes parsing through `decodeFile`, and `phase7-verify/internal/catalog/catalog.go:249-260` requires a single top-level JSON object with unknown-field rejection. Regression: `phase7-verify/internal/catalog/catalog_test.go:278-290`.
- `phase7-verify/internal/catalog/catalog.go:104-110` pins `version == 1`. Regression: `phase7-verify/internal/catalog/catalog_test.go:196-214`.
- `phase7-verify/internal/catalog/catalog.go:127-147` rejects empty/unsupported model fields, including `artifact_kind != "mlx_weight_file"` and unsupported `hash_scope`, matching `phase4-coordinator/internal/tier2/catalog.go:526-533`. Regressions: `phase7-verify/internal/catalog/catalog_test.go:216-317`.
- `phase7-verify/internal/catalog/catalog.go:153-160` rejects empty `signature.alg`, `signature.key_id`, and `signature.sig`; `phase7-verify/internal/catalog/catalog.go:195-220` enforces capital-E `"Ed25519"`, `base64.RawURLEncoding`, canonical key order, and `ed25519.Verify`.
- `phase7-verify/internal/catalog/catalog.go:223-229` keeps the inclusive 60-second expiry grace. Regression: `phase7-verify/internal/catalog/catalog_test.go:319-345`.
- `phase7-verify/internal/catalog/signer_parity_test.go:28-125` runs the real `scripts/sign-catalog.go` keygen/sign flow, accepts the signer output verbatim, and rejects tampering.
- `phase7-verify/internal/cache/catalog/catalog_cache.go:79-87` implements the three TTL bands; `phase7-verify/internal/cache/catalog/catalog_cache.go:161-167` misses on pubkey rotation and stale cache entries. Regressions: `phase7-verify/internal/cache/catalog/catalog_cache_test.go:9-122`.
- Import check: `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/catalog ./internal/cache/catalog` shows only stdlib imports for the Step 4 packages. Module-level `go list -m all` still lists pre-existing `golang.org/x/*` modules outside this Step 4 surface.

Validation:

- `go test ./internal/catalog -count=1 -v` PASS
- `go test ./internal/cache/catalog -count=1 -v` PASS
- `go test ./... -count=1` PASS

VERDICT: READY

COUNTS: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 0

## Lens — SECURITY — Round 2

No SECURITY findings.

Security re-audit confirms the fail-closed surfaces from Round 1 are closed:

- Schema acceptance is no longer a signature-valid bypass surface: unsupported versions, trailing JSON, missing required model fields, unsupported model enum values, and missing signature fields are rejected during parse at `phase7-verify/internal/catalog/catalog.go:97-160`.
- Signature verification cannot be bypassed by body/signature tampering: `phase7-verify/internal/catalog/catalog_test.go:100-149` covers tampered signature/body, and `phase7-verify/internal/catalog/signer_parity_test.go:110-124` repeats tamper rejection against real signer output.
- Algorithm and signature encoding are constrained before `ed25519.Verify`: `phase7-verify/internal/catalog/catalog.go:195-220` requires exact `"Ed25519"`, decodes `signature.sig` with `base64.RawURLEncoding`, checks signature length, and delegates the cryptographic comparison to `ed25519.Verify`.
- Expiry handling uses `now.After(expires_at + 60s)`, so exactly 60 seconds is accepted and 61 seconds is rejected: `phase7-verify/internal/catalog/catalog.go:223-229`, `phase7-verify/internal/catalog/catalog_test.go:319-345`.
- Cache integrity checks preserve the trust boundary: writes use mode `0600` at `phase7-verify/internal/cache/catalog/catalog_cache.go:119`; pubkey rotation and stale entries miss at `phase7-verify/internal/cache/catalog/catalog_cache.go:161-167`, with regressions at `phase7-verify/internal/cache/catalog/catalog_cache_test.go:83-122`.

Validation:

- `go test ./internal/catalog -count=1 -v` PASS
- `go test ./internal/cache/catalog -count=1 -v` PASS
- `go test ./... -count=1` PASS

VERDICT: READY

COUNTS: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 0

## Lens — ARCHITECT — Round 2

No ARCHITECT findings.

Architecture re-audit confirms Step 4 now composes with the locked SPEC-015 v0.3 contract and the coordinator/signer boundary:

- No locked-spec shifts: `git diff -- specs/SPEC-015-receipts.md specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_4_PROMPT.md` is empty.
- The verifier remains a hand translation, not a coordinator import. `rg -n "phase4-coordinator|internal/tier2|golang.org/x|github.com/" internal/catalog internal/cache/catalog` finds only comments referencing the coordinator and no third-party imports.
- The accept/reject contract now matches the coordinator on version, single-object JSON, required signature fields, model ID canonicalization, artifact kind, hash scope, source, and sha256 checks: `phase7-verify/internal/catalog/catalog.go:97-160` vs. `phase4-coordinator/internal/tier2/catalog.go:443-543`.
- The canonical signing boundary is covered by a real tool-level parity test: `phase7-verify/internal/catalog/signer_parity_test.go:28-125` runs `scripts/sign-catalog.go` and verifies the produced catalog with the verifier.
- Cache entry shape now carries both contract and implementation timing: `catalog_pubkey_b64`, catalog `expires_at`, and `cache_expires_at` are persisted at `phase7-verify/internal/cache/catalog/catalog_cache.go:46-53` and populated at `phase7-verify/internal/cache/catalog/catalog_cache.go:105-112`.
- Step 1 wire-shape composition is preserved: parser enforces raw 64-lowercase-hex `sha256` at `phase7-verify/internal/catalog/catalog.go:141-143`, with regressions at `phase7-verify/internal/catalog/catalog_test.go:347-369`.

Validation:

- `go test ./internal/catalog -count=1 -v` PASS
- `go test ./internal/cache/catalog -count=1 -v` PASS
- `go test ./... -count=1` PASS

VERDICT: READY

COUNTS: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 0
