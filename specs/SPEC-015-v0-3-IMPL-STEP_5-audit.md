## Lens — CODE — Round 1

### Findings

1. **HIGH — CLI JSON omits the required v0.3 `model_hash_verified` field.**  
   `verify.Result.MarshalJSON` was extended with `model_hash_verified`, but the CLI never uses it for `--json`: `emitResult` calls `renderJSON`, whose `jsonResult` type has only the v0.2 fields and whose payload construction copies only those fields. This violates §M.3.2.1's "REQUIRED (always present)" contract and the audit prompt's HIGH condition for absent `model_hash_verified`.  
   Evidence: `phase7-verify/internal/cli/cli.go:463`, `phase7-verify/internal/cli/output.go:16`, `phase7-verify/internal/cli/output.go:40`.

2. **HIGH — Unknown `receipt_version` is not implemented as `inconclusive: unknown_receipt_version`.**  
   The parser branches on presence of `receipt_version`, parses any string value, and `validateTuple` never requires `"3"` or returns a forward-compat result. The catalog layer explicitly carries a TODO saying unknown versions are not handled; as written, a signed receipt with `receipt_version: "4"` and the v0.3 key shape can continue through normal verification instead of short-circuiting per §M.1.4.  
   Evidence: `phase7-verify/internal/receipt/receipt.go:245`, `phase7-verify/internal/receipt/receipt.go:374`, `phase7-verify/internal/verify/catalog_check.go:59`.

3. **HIGH — v0.3 missing/extra tuple fields do not produce the required JSON `invalid` reasons.**  
   §M.0 / §M.3.2.1 require v0.3 shape failures to return `invalid` with `reason: "extra_field"` or `"missing_field"` and populated `details.field`. The implementation returns parser errors from `receipt.Parse`, wraps them as `InputFormatError`, and the CLI maps that class to exit 65 with no JSON result. The new reason constants also omit `extra_field` and `missing_field`.  
   Evidence: `phase7-verify/internal/receipt/receipt.go:223`, `phase7-verify/internal/receipt/receipt.go:228`, `phase7-verify/internal/verify/verify.go:45`, `phase7-verify/internal/verify/verify.go:367`, `phase7-verify/internal/cli/cli.go:489`.

4. **HIGH — AC-41 catalog URL cache is not composed into the verifier path.**  
   Step 5 requires the Step 4 `internal/cache/catalog` package and AC-41 TTL behavior for `--catalog-url`. The current Step 5 verifier resolves catalog bytes with a direct `http.Client.Get` every time and does not thread or call the catalog cache layer; `VerifyOpts.Catalog` also has no cache option. This leaves the AC-41 acceptance gate unimplemented.  
   Evidence: `phase7-verify/internal/verify/catalog_check.go:93`, `phase7-verify/internal/verify/catalog_check.go:168`, `phase7-verify/internal/verify/verify.go:98`.

5. **MEDIUM — v0.3 details fields are serialized in the wrong shape or dropped.**  
   §M.3.2.1 requires fields like `details.expected`, `details.actual`, `details.model_id`, `details.catalog_id`, `details.expires_at`, and `details.policy_flag`. The shared `Details` type only exposes `field`, `computed`, `receipt`, and an `extra` map, and the CLI renderer emits details only for `invalid`, dropping required details for `model_id_not_in_catalog` and `catalog_expired` inconclusive results.  
   Evidence: `phase7-verify/internal/verify/verify.go:131`, `phase7-verify/internal/verify/catalog_check.go:127`, `phase7-verify/internal/verify/catalog_check.go:141`, `phase7-verify/internal/verify/catalog_check.go:152`, `phase7-verify/internal/cli/output.go:50`.

6. **MEDIUM — The advertised CLI surface is stale despite the flags being registered.**  
   The five new flags are registered in `parseOptions`, but `printUsage` still lists only the v0.2 flags. `go run ./cmd/macprovider-verify --help` confirms `--catalog`, `--catalog-url`, `--catalog-pubkey`, `--catalog-pubkey-url`, and `--require-model-hash` are absent, violating the Step 5 done condition.  
   Evidence: `phase7-verify/internal/cli/cli.go:158`, `phase7-verify/internal/cli/cli.go:511`.

VERDICT: **FAIL** — Step 5 is not ready for the target of 0 CRITICAL / 0 HIGH / 0 MEDIUM.  
COUNTS: CRITICAL 0, HIGH 4, MEDIUM 2, LOW 0.

## Lens — SECURITY — Round 1

### Findings

1. **HIGH — JSON-mode buyers cannot tell whether catalog attestation ran.**  
   The verifier can compute `ModelHashVerified`, but the CLI JSON output strips it. A buyer integrating against `--json` receives `valid` without the required `model_hash_verified: true|false|null` discriminator, making catalog-attested validity indistinguishable from legacy/no-catalog/null-hash validity. That weakens the §M.3.3 trust boundary at the machine-readable interface.  
   Evidence: `phase7-verify/internal/verify/verify.go:120`, `phase7-verify/internal/cli/output.go:16`, `phase7-verify/internal/cli/output.go:40`, `phase7-verify/internal/cli/cli.go:463`.

2. **HIGH — Future receipt versions can be processed under the v0.3 trust model.**  
   §M.1.4 forbids canonicalization/signature checking for unknown `receipt_version` values and requires `inconclusive`. The current code does not enforce that boundary and even documents the missing path as a TODO, so a future receipt shape that happens to satisfy the v0.3 key set can be accepted or catalog-checked under semantics the v0.3 verifier was not built to understand.  
   Evidence: `phase7-verify/internal/receipt/receipt.go:210`, `phase7-verify/internal/receipt/receipt.go:266`, `phase7-verify/internal/verify/catalog_check.go:59`.

3. **MEDIUM — `--explain` still gives the v0.2 trust-boundary disclosure for v0.3 catalog-valid results.**  
   §M.3.1.1 and §M.3.3 require `--explain` to disclose which catalog contributed to a v0.3 `valid` verdict and the catalog-pubkey trust root. The current explanation still says a valid result does not prove the response was generated by the named model and describes model-hash binding as v0.3+ candidate work. This can mislead operators reviewing security posture from the human-facing output.  
   Evidence: `phase7-verify/internal/cli/cli.go:131`, `phase7-verify/internal/cli/cli.go:530`, `phase7-verify/internal/cli/cli.go:544`.

VERDICT: **FAIL** — security-relevant output and forward-compat boundaries are incomplete.  
COUNTS: CRITICAL 0, HIGH 2, MEDIUM 1, LOW 0.

## Lens — ARCHITECT — Round 1

### Findings

1. **HIGH — The shipped JSON schema remains v0.2 and does not model the Step 5 output contract.**  
   `schemas/output.schema.json` still describes "SPEC-015 v0.2", does not require or allow `model_hash_verified`, and lacks the new reason/warning/details shapes. The enum drift test also hardcodes only the old reason list, so the suite stays green while the schema remains out of date. This breaks the §M.3.2.1 schema artifact contract.  
   Evidence: `phase7-verify/schemas/output.schema.json:5`, `phase7-verify/schemas/output.schema.json:9`, `phase7-verify/schemas/output.schema.json:100`, `phase7-verify/schemas/output.schema.json:216`, `phase7-verify/internal/verify/enum_drift_test.go:10`.

2. **HIGH — Step 5 acceptance coverage is mostly unit-level and bypasses the public verifier contract.**  
   The new catalog-check tests call `applyCatalogCheck` directly with synthetic `receipt.Parsed` values, so they do not exercise receipt parsing, signature verification, CLI flag plumbing, exit codes, JSON rendering, schema validation, or the required golden fixture commands for AC-32 through AC-37. AC-38 and AC-41 are not represented by the Step 5 tests.  
   Evidence: `phase7-verify/internal/verify/catalog_check_test.go:13`, `phase7-verify/internal/verify/catalog_check_test.go:51`, `phase7-verify/internal/verify/catalog_check_test.go:97`, `phase7-verify/internal/verify/catalog_check_test.go:124`, `phase7-verify/internal/verify/catalog_check_test.go:152`.

3. **HIGH — The Step 4 catalog cache package is architecturally bypassed.**  
   The build prompt requires Step 5 to compose with Step 4's `internal/cache/catalog` package. The verification path imports only `internal/catalog` and resolves URL catalogs with direct HTTP reads, so cache TTL, cache-miss-on-rotation, and cached pubkey binding are not part of the actual verifier architecture.  
   Evidence: `phase7-verify/internal/verify/catalog_check.go:3`, `phase7-verify/internal/verify/catalog_check.go:13`, `phase7-verify/internal/verify/catalog_check.go:170`, `phase7-verify/internal/cache/catalog/catalog_cache.go:1`.

4. **MEDIUM — Public docs and help still describe the v0.2 verifier.**  
   The README CLI table and version compatibility section omit all v0.3 catalog flags and still document the old schema/trust posture. The command usage output is similarly stale. That leaves the public verifier surface inconsistent with the implementation and with the Step 5 done condition.  
   Evidence: `phase7-verify/README.md:68`, `phase7-verify/README.md:78`, `phase7-verify/README.md:118`, `phase7-verify/internal/cli/cli.go:511`.

5. **MEDIUM — The result details abstraction does not match the v0.3 schema amendment.**  
   The existing generic `Details{Field, Computed, Receipt, Extra}` shape made sense for v0.2 hash mismatches, but Step 5 adds distinct details contracts for catalog, policy, and unknown-version reasons. Keeping the new data under `Extra` makes schema conformance and stable downstream parsing harder, and the renderer already drops inconclusive details because the abstraction remains v0.2-oriented.  
   Evidence: `phase7-verify/internal/verify/verify.go:131`, `phase7-verify/internal/verify/catalog_check.go:123`, `phase7-verify/internal/verify/catalog_check.go:127`, `phase7-verify/internal/verify/catalog_check.go:141`, `phase7-verify/internal/cli/output.go:50`.

VERDICT: **FAIL** — architecture is not yet aligned with the Step 5 public contract or acceptance gate.  
COUNTS: CRITICAL 0, HIGH 3, MEDIUM 2, LOW 0.

## Lens — CODE — Round 2

### Fix-pass confirmation

- CLI JSON now carries `model_hash_verified` on all rendered outputs via `jsonResult.ModelHashVerified` and `renderJSON` population. `go test ./...` confirms the suite is green.
- `receipt_version` is propagated into JSON-capable results after normal verification, and unknown-version handling exists in `Verify()` before resolver, canonical prompt/output hash recomputation, catalog, or signature verification.
- `extra_field` / `missing_field` reason constants and enum-drift coverage were added.
- URL catalog fetch now consults `tryCachedCatalogBytes` before HTTP fetch and persists successful URL fetches after catalog verification.
- `printUsage` advertises the five v0.3 catalog flags plus `--require-model-hash`; `explainText` now includes the catalog-attested v0.3 trust statement.

### Findings

1. **HIGH — Unknown future `receipt_version` receipts are still shape-validated as v0.3 before the §M.1.4 short-circuit can run.**  
   `parseTuple` uses presence of `receipt_version` to select the exact v0.3 `v03TupleKeys` set and returns `ErrTupleExtraKey` / `ErrTupleMissingKey` before `Verify()` sees the unknown version. That means a future v0.4 receipt with `receipt_version: "4"` plus an added field, omitted v0.3-only field, or changed field type will be mapped to `invalid: extra_field` / `missing_field` / exit-65 format error instead of `inconclusive: unknown_receipt_version`. §M.1.4 says unknown versions must not use field count as a fallback heuristic; version detection must happen before known-version strict-shape validation.  
   Evidence: `phase7-verify/internal/receipt/receipt.go:210`, `phase7-verify/internal/receipt/receipt.go:212`, `phase7-verify/internal/receipt/receipt.go:223`, `phase7-verify/internal/receipt/receipt.go:228`, `phase7-verify/internal/verify/verify.go:225`, `phase7-verify/internal/verify/verify.go:241`.

2. **MEDIUM — v0.3 details are emitted under `details.extra` instead of the §M.3.2.1 top-level detail keys.**  
   The implementation now renders details for inconclusive results, but the details payload still uses the v0.2-shaped `Details{field, computed, receipt, extra}` abstraction. Required fields such as `details.expected`, `details.actual`, `details.policy_flag`, `details.catalog_id`, `details.expires_at`, `details.model_id`, and `details.receipt_version` are nested under `details.extra` rather than appearing at `details.<key>` as §M.3.2.1 requires. This blocks stable downstream parsing even though the terminal result/reason is correct.  
   Evidence: `phase7-verify/internal/verify/catalog_check.go:54`, `phase7-verify/internal/verify/catalog_check.go:77`, `phase7-verify/internal/verify/catalog_check.go:143`, `phase7-verify/internal/verify/catalog_check.go:157`, `phase7-verify/internal/verify/catalog_check.go:168`, `phase7-verify/internal/verify/verify.go:249`, `phase7-verify/internal/cli/output.go:35`, `phase7-verify/internal/cli/output.go:81`.

VERDICT: **FAIL** — the main Round 1 code fixes landed, but §M.1.4 and v0.3 details shape are still not fully compliant.  
COUNTS: CRITICAL 0, HIGH 1, MEDIUM 1, LOW 0.

## Lens — SECURITY — Round 2

### Fix-pass confirmation

- JSON-mode consumers can now distinguish catalog-attested valid results from non-attested valid results through `model_hash_verified: true|false|null`.
- `--require-model-hash` now fails closed for legacy and null-hash receipts with `model_hash_verified=false`.
- Catalog cache composition no longer silently downgrades explicit URL catalog checks: cache misses fall back to HTTP fetch, and stale / pubkey-rotated entries miss.
- The v0.3 `--explain` text no longer preserves the old blanket "does not prove model" statement for catalog-attested valid results; it scopes the stronger claim to `model_hash_verified: true`.

### Findings

1. **MEDIUM — Security-relevant diagnostic details are not exposed in the specified machine-readable shape.**  
   The verifier returns the correct terminal states for policy reject, hash mismatch, catalog expiry, missing model, and unknown version, but the reason-specific facts are nested in `details.extra` or constrained by the old `field/computed/receipt` model. A buyer-side policy engine expecting §M.3.2.1 fields like `details.expected`, `details.actual`, `details.policy_flag`, or `details.receipt_version` cannot consume them as specified. This does not create a false-valid path, so it is not HIGH, but it weakens the intended security automation surface.  
   Evidence: `phase7-verify/internal/verify/catalog_check.go:54`, `phase7-verify/internal/verify/catalog_check.go:143`, `phase7-verify/internal/verify/catalog_check.go:168`, `phase7-verify/internal/verify/verify.go:249`, `phase7-verify/internal/cli/output.go:35`, `phase7-verify/internal/cli/output.go:81`.

VERDICT: **FAIL** — no catalog-bypass or false-valid security path found, but the machine-readable security diagnostics remain off-contract.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 1, LOW 0.

## Lens — ARCHITECT — Round 2

### Fix-pass confirmation

- `schemas/output.schema.json` is now labeled v0.3, requires `model_hash_verified` in all result branches, includes the new reason enum values, and admits the new warning kinds.
- `enum_drift_test.go` includes the ten new reason constants and proves the schema reason set is bijective with verifier constants.
- Step 4 catalog cache is now part of the verifier URL path: `tryCachedCatalogBytes` is called before `resolveCatalogBytes`, and successful verified URL fetches are persisted through `internal/cache/catalog`.
- Help and explain text now align with the v0.3 catalog surface at a public CLI level.

### Findings

1. **HIGH — The published v0.3 output schema still does not model v0.3 `details` and rejects several outputs the verifier can emit.**  
   The invalid branch includes the new v0.3 reasons, but its `details.field` enum still only allows the v0.2 fields (`signature`, `prompt_hash`, `output_hash`, `pubkey`, `grace_window`) and requires `details.receipt`; `model_hash_required` and `model_hash_mismatch` emit `details.field: "model_hash"`, so schema validation rejects them. The inconclusive branch includes `model_id_not_in_catalog`, `catalog_expired`, and `unknown_receipt_version`, but defines no `details` property while `additionalProperties: false` is set, so the now-rendered required inconclusive details are schema-invalid. This leaves the release artifact contract incomplete despite the enum bump.  
   Evidence: `phase7-verify/schemas/output.schema.json:225`, `phase7-verify/schemas/output.schema.json:272`, `phase7-verify/schemas/output.schema.json:279`, `phase7-verify/schemas/output.schema.json:332`, `phase7-verify/schemas/output.schema.json:498`, `phase7-verify/schemas/output.schema.json:503`, `phase7-verify/schemas/output.schema.json:506`, `phase7-verify/schemas/output.schema.json:693`, `phase7-verify/internal/verify/catalog_check.go:54`, `phase7-verify/internal/verify/catalog_check.go:168`.

2. **HIGH — The forward-compat boundary is split across parser and verifier layers, so §M.1.4 is not architecturally enforced at the version-dispatch boundary.**  
   The verifier has a correct-looking unknown-version branch, but it sits after `parseInput`; the parser has already committed unknown `receipt_version` inputs to the v0.3 exact-shape contract. That violates the intended tagged-union architecture from the build prompt: legacy, known v0.3, and unknown-version receipts should be separated before known-version canonical shape validation. The current layering will regress on future-version receipts that do not preserve the v0.3 nine-key shape.  
   Evidence: `phase7-verify/internal/receipt/receipt.go:207`, `phase7-verify/internal/receipt/receipt.go:212`, `phase7-verify/internal/receipt/receipt.go:223`, `phase7-verify/internal/receipt/receipt.go:228`, `phase7-verify/internal/verify/verify.go:225`, `phase7-verify/internal/verify/verify.go:241`, `phase7-verify/internal/verify/catalog_check.go:60`.

3. **MEDIUM — The green suite does not cover v0.3 schema conformance for the newly-added reason/detail combinations.**  
   `go test ./...` is green, but schema validation tests only exercise legacy-shaped invalid details and generic inconclusive output. There is no schema validation case for `model_hash_required`, `model_hash_mismatch`, `model_id_not_in_catalog`, `catalog_expired`, or `unknown_receipt_version`, which is why the schema/detail mismatch above escaped.  
   Evidence: `phase7-verify/internal/cli/output_test.go:253`, `phase7-verify/internal/cli/output_test.go:257`, `phase7-verify/internal/cli/output_test.go:287`, `phase7-verify/internal/verify/catalog_check_test.go:37`, `phase7-verify/internal/verify/catalog_check_test.go:75`, `phase7-verify/internal/verify/catalog_check_test.go:97`, `phase7-verify/internal/verify/catalog_check_test.go:124`.

VERDICT: **FAIL** — cache/help/schema-enum fixes landed, but the public schema artifact and unknown-version boundary remain architecturally incomplete.  
COUNTS: CRITICAL 0, HIGH 2, MEDIUM 1, LOW 0.

## Lens — CODE — Round 3

### Fix-pass confirmation

- Unknown `receipt_version` is now dispatched in `parseTuple` before known-version strict-shape validation. A present string value other than `"3"` returns a Tuple stub with only `ReceiptVersion` populated, allowing `Verify()` to short-circuit to `inconclusive: unknown_receipt_version` before resolver, canonicalization, signature check, or catalog work.
- v0.3 `Details` now has named fields (`expected`, `actual`, `policy_flag`, `model_id`, `catalog_id`, `expires_at`, `receipt_version`, `cause`, `url`, `alg`) and the CLI JSON renderer carries those fields through for invalid and inconclusive results.
- `schemas/output.schema.json` now accepts v0.3 named details for invalid and inconclusive variants, allows `trust_source: "none"` on pre-resolver invalid/inconclusive paths, and keeps valid results restricted to `explicit_pubkey`, `cache`, or `live`.
- `TestV03SchemaConformance` adds fixtures for the Round 2 schema/detail gaps, and `go test ./...` is green in `phase7-verify/`.

### Findings

1. **MEDIUM — `catalog_signature_invalid` omits the required `details.alg` field.**  
   §M.3.2.1 requires `catalog_signature_invalid` details to include `details.field: "signature"` and `details.alg: <observed alg string>`. The data model and CLI renderer now have an `Alg` field, but `applyCatalogCheck` populates only `Field` and `Cause` for both typed catalog signature failures and generic verification failures. The positive schema fixture mirrors that omission, so the new schema conformance test does not catch the missing required detail. This does not create a false-valid or catalog-bypass path, but the v0.3 machine-readable details contract is still incomplete for one new reason.  
   Evidence: `phase7-verify/internal/verify/verify.go:150`, `phase7-verify/internal/verify/verify.go:152`, `phase7-verify/internal/verify/catalog_check.go:127`, `phase7-verify/internal/verify/catalog_check.go:134`, `phase7-verify/internal/verify/catalog_check.go:146`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:87`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:97`.

VERDICT: **FAIL** — Round 2's parser-layer and broad details/schema fixes landed, but one v0.3 details requirement remains off-contract.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 1, LOW 0.

## Lens — SECURITY — Round 3

### Fix-pass confirmation

- No false-valid catalog path was found: hash mismatch still returns `invalid` with `model_hash_verified=false`, catalog signature failure still returns `invalid`, and successful catalog match is the only path that sets `model_hash_verified=true`.
- `--require-model-hash` remains fail-closed for legacy and null-hash receipts.
- URL catalog and pubkey fetches remain blocked by `--offline`; default HTTP clients use a 5-second timeout and no retry loop.
- Changed verifier packages import only standard-library and repo-local packages; no third-party runtime imports were introduced in the changed verification path.

### Findings

1. **MEDIUM — Security automation cannot rely on the specified algorithm diagnostic for catalog signature failures.**  
   Lowercase or otherwise unexpected catalog signature algorithms are rejected, but the resulting verifier details expose the algorithm only inside a human-readable `cause` string rather than the required `details.alg` field. Buyer-side policy or telemetry that keys on §M.3.2.1's structured `alg` detail cannot distinguish lowercase-alg rejection from other signature failures without string parsing. The terminal result remains fail-closed, so this is not HIGH.  
   Evidence: `phase7-verify/internal/catalog/catalog.go:195`, `phase7-verify/internal/catalog/catalog.go:196`, `phase7-verify/internal/catalog/catalog.go:197`, `phase7-verify/internal/verify/catalog_check.go:127`, `phase7-verify/internal/verify/catalog_check.go:134`, `phase7-verify/internal/verify/catalog_check.go:146`.

VERDICT: **FAIL** — fail-closed behavior is intact, but one structured security diagnostic remains below the v0.3 contract.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 1, LOW 0.

## Lens — ARCHITECT — Round 3

### Fix-pass confirmation

- The unknown-version boundary now matches the build prompt's tagged-union shape: parser version dispatch happens before v0.3 strict key validation, and verifier short-circuiting happens before canonicalization/signature/catalog stages.
- The schema artifact now accepts named v0.3 details for both invalid and inconclusive outputs and preserves the existing valid-variant trust-source constraints.
- The new schema conformance test demonstrates acceptance of 11 representative v0.3 output fixtures, including unknown receipt version, strict-shape errors, catalog-attested valid output, and legacy-with-catalog skipped output.
- Validation run: `go test ./...` passed for all `phase7-verify` packages; targeted `TestV03SchemaConformance` and `TestSchemaRejectsTrustSourceCoordinatorHostMismatches` also passed.

### Findings

1. **MEDIUM — The schema/test layer accepts a `catalog_signature_invalid` output that is missing a required v0.3 detail.**  
   The published schema defines `details.alg` as an allowed string, but it does not conditionally require `alg` when `reason` is `catalog_signature_invalid`. `TestV03SchemaConformance` then validates a `catalog_signature_invalid` fixture with `details.field` and `details.cause` but no `details.alg`, so the acceptance gate can go green while the §M.3.2.1 detail contract is not fully modeled. This is narrower than the Round 2 schema failure because actual v0.3 outputs are no longer rejected wholesale, but the schema is still permissive for one required reason-specific field.  
   Evidence: `phase7-verify/schemas/output.schema.json:225`, `phase7-verify/schemas/output.schema.json:235`, `phase7-verify/schemas/output.schema.json:273`, `phase7-verify/schemas/output.schema.json:315`, `phase7-verify/schemas/output.schema.json:319`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:87`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:97`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:183`.

VERDICT: **FAIL** — architectural Round 2 blockers are resolved, but the schema/test contract still does not enforce one required v0.3 detail field.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 1, LOW 0.

## Lens — CODE — Round 4

### Fix-pass confirmation

- The lowercase/wrong-alg catalog path now propagates `catalog.ErrSignatureInvalid.ObservedAlg` from `catalog.Verify()` into `verify.Details.Alg`, and `catalog_check.go` emits that field for typed signature failures.
- The positive `TestV03SchemaConformance` fixture for `catalog_signature_invalid` now includes `details.alg`, and `schemas/output.schema.json` has a conditional `allOf` requiring non-empty `details.alg` when `reason` is `catalog_signature_invalid`.
- Validation run: `go test ./...` passed for all `phase7-verify` packages.

### Findings

1. **MEDIUM — Tampered catalog signatures still emit `catalog_signature_invalid` without the required `details.alg`.**  
   The new `ObservedAlg` plumbing is present for wrong `signature.alg`, base64 decode failure, and signature length failure, but the normal cryptographic verification failure path still returns `&ErrSignatureInvalid{Reason: "ed25519.Verify returned false"}` without `ObservedAlg`. `catalog_check.go` copies `sigErr.ObservedAlg` directly into `Details.Alg`; because the CLI JSON field is `omitempty`, this reachable bad-signature output omits `details.alg` and violates §M.3.2.1. The existing tampered-signature tests assert only the typed error, not the observed algorithm field, so the suite stays green.  
   Evidence: `phase7-verify/internal/catalog/catalog.go:195`, `phase7-verify/internal/catalog/catalog.go:226`, `phase7-verify/internal/catalog/catalog.go:227`, `phase7-verify/internal/verify/catalog_check.go:127`, `phase7-verify/internal/verify/catalog_check.go:134`, `phase7-verify/internal/cli/output.go:50`, `phase7-verify/internal/catalog/catalog_test.go:119`, `phase7-verify/internal/catalog/catalog_test.go:124`.

VERDICT: **FAIL** — the schema/test fixture fix landed for the wrong-alg case, but one common signature-invalid path still violates the `details.alg` contract.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 1, LOW 0.

## Lens — SECURITY — Round 4

### Fix-pass confirmation

- Lowercase or otherwise wrong catalog `signature.alg` remains fail-closed and now exposes the observed algorithm in structured JSON details.
- The schema now rejects a synthetic `catalog_signature_invalid` result that omits `details.alg`.
- No false-valid path was found in the Round 4 review; catalog signature failures still return `invalid`.

### Findings

1. **MEDIUM — Structured security diagnostics are still incomplete for real bad-signature bytes.**  
   A catalog with `signature.alg: "Ed25519"` but tampered signed bytes is rejected, but the emitted typed error does not carry the observed alg. Downstream policy engines and telemetry that rely on §M.3.2.1's structured `details.alg` cannot uniformly process `catalog_signature_invalid` without string inspection or a schema failure. This remains fail-closed, so it is not HIGH, but the machine-readable security surface is still off-contract.  
   Evidence: `phase7-verify/internal/catalog/catalog.go:226`, `phase7-verify/internal/catalog/catalog.go:227`, `phase7-verify/internal/verify/catalog_check.go:131`, `phase7-verify/internal/verify/catalog_check.go:134`, `phase7-verify/internal/catalog/catalog_test.go:100`, `phase7-verify/internal/catalog/catalog_test.go:119`, `phase7-verify/internal/catalog/catalog_test.go:124`.

VERDICT: **FAIL** — fail-closed behavior is preserved, but `catalog_signature_invalid` diagnostics are not yet uniformly structured.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 1, LOW 0.

## Lens — ARCHITECT — Round 4

### Fix-pass confirmation

- The schema artifact now models the Round 3 requirement by conditionally requiring `details.alg` for `catalog_signature_invalid`.
- The conformance suite includes both a positive `catalog_signature_invalid` fixture with `details.alg` and a negative fixture proving omission is schema-invalid.
- Full validation run: `go test ./...` passed.

### Findings

1. **MEDIUM — The stricter schema is now ahead of one verifier emission path.**  
   Architecturally, the contract moved in the right direction: schema validation now requires `details.alg`. However, `catalog.Verify()` does not attach `ObservedAlg` on the `ed25519.Verify returned false` path, and there is no end-to-end schema conformance test for an actual tampered catalog emission. The artifact layer can now reject a result shape the verifier can still produce, so the Step 5 schema/renderer contract is not fully closed.  
   Evidence: `phase7-verify/schemas/output.schema.json:472`, `phase7-verify/schemas/output.schema.json:488`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:87`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:99`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:184`, `phase7-verify/internal/cli/v03_schema_conformance_test.go:201`, `phase7-verify/internal/catalog/catalog.go:226`, `phase7-verify/internal/catalog/catalog.go:227`.

VERDICT: **FAIL** — schema enforcement is fixed, but implementation and coverage are not yet aligned with that stricter artifact contract.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 1, LOW 0.

## Lens — CODE — Round 5

### Fix-pass confirmation

- The `ed25519.Verify returned false` branch in `catalog.Verify()` now returns `ErrSignatureInvalid` with `ObservedAlg: f.Signature.Alg`, matching the existing wrong-alg, signature-decode, and signature-length branches.
- `applyCatalogCheck()` already copies `catalog.ErrSignatureInvalid.ObservedAlg` into `Details.Alg`; with the catalog-layer fix, tampered signature bytes now produce `catalog_signature_invalid` with non-empty `details.alg`.
- `TestVerifyTamperedSignatureCarriesObservedAlg` covers the catalog package's tampered-signature branch directly, and `TestCatalogCheckTamperedCatalogPopulatesDetailsAlg` covers the full `applyCatalogCheck` emission path for a post-signing tampered catalog.
- Validation run: `go test ./internal/catalog ./internal/verify ./internal/cli` passed; `go test ./...` passed for all `phase7-verify` packages.

### Findings

None.

VERDICT: **PASS** — the last Round 4 code gap is closed; no remaining CODE CRITICAL / HIGH / MEDIUM findings found in this pass.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 0.

## Lens — SECURITY — Round 5

### Fix-pass confirmation

- A catalog with `signature.alg: "Ed25519"` but tampered signed bytes still fails closed as `invalid` with `reason: "catalog_signature_invalid"`.
- The same bad-signature path now carries the observed algorithm as structured `details.alg`, so security automation no longer needs to parse a human-readable cause string for this reason.
- The model-hash attestation boundary remains unchanged: catalog signature failure short-circuits before model lookup/hash equality and cannot set `model_hash_verified=true`.
- Validation run: `go test ./...` passed.

### Findings

None.

VERDICT: **PASS** — no false-valid catalog path or incomplete structured security diagnostic remains for the Round 4 tampered-signature case.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 0.

## Lens — ARCHITECT — Round 5

### Fix-pass confirmation

- The implementation now matches the stricter schema contract: `catalog_signature_invalid` emissions from both wrong-alg and tampered-signature paths can satisfy the schema's conditional `details.alg` requirement.
- Coverage now spans all relevant layers for the prior gap: catalog typed error propagation, verifier catalog-check result details, and schema-level rejection of missing `details.alg`.
- The helper `writeTamperedSignedCatalog` creates the intended fixture class: a catalog signed with `signature.alg: "Ed25519"` and then mutated after signing so verification reaches the cryptographic false branch.
- Validation run: `go test ./internal/catalog ./internal/verify ./internal/cli` passed; `go test ./...` passed.

### Findings

None.

VERDICT: **PASS** — schema, verifier emission, and regression coverage are aligned for Step 5's final `details.alg` contract.  
COUNTS: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 0.
