# macprovider-verify v1.1.0

**SPEC-015 v0.3.3 model-hash binding** — catalog-based verification of the loaded MLX container against an operator-signed catalog.

## What's new

### Receipt format

- **v0.3 9-field receipt tuple** verification (`model_hash`, `model_id`, `output_hash`, `prompt_hash`, `provider_pubkey`, `receipt_version="3"`, `tokens_out`, `ttft_ms`, `unix_ts`).
- **Back-compat preserved (§M.1.1):** v0.1 / v0.2.0–v0.2.4 receipts still verify exactly as v1.0.x did. A `catalog_skipped_legacy_receipt` warning is emitted when `--catalog*` flags are supplied against a legacy receipt.
- **Forward-incompat enforced (§M.1.2):** the v0.2.4 LOCKED parser at the v1.0.x floor is preserved; locked v1.0.x verifiers report v0.3 receipts as `invalid` per spec. v1.1.x dispatches via tagged-union on `receipt_version` presence.
- **Unknown receipt_version → `inconclusive: unknown_receipt_version`** (§M.1.4). Future v0.4+ wire shapes degrade gracefully.

### New CLI flags

| Flag | Purpose |
|---|---|
| `--catalog <path>` | Local signed catalog file. |
| `--catalog-url <url>` | Remote signed catalog (e.g. `https://coordinator.malibu.tech/catalog/<id>`). |
| `--catalog-pubkey <43-char base64url-unpadded>` | Catalog Ed25519 pubkey, explicit. |
| `--catalog-pubkey-url <url>` | Catalog Ed25519 pubkey, fetched (e.g. `https://coordinator.malibu.tech/catalog/pubkey`). |
| `--require-model-hash` | Buyer fail-closed policy on null hash. With no `--catalog*` flags, asserts "I demand the provider participates in hash attestation, but I'll trust the provider's self-reported hash without catalog cross-check." |

§M.3.1.1 mutual-exclusion enforced: `--catalog` / `--catalog-url` mutually exclusive; `--catalog-pubkey` / `--catalog-pubkey-url` mutually exclusive; `--offline` incompatible with any `--catalog*-url` flag. `--catalog` / `--catalog-url` requires a paired pubkey source (exit 64).

### §M.3.2 8-step catalog algorithm

For v0.3 receipts with non-null `model_hash` AND catalog arguments supplied:

1. Resolve catalog pubkey from `--catalog-pubkey` or `--catalog-pubkey-url` (HTTP GET → `{"pubkey":"<43-char base64url>","alg":"Ed25519"}`).
2. Fetch catalog bytes from `--catalog` or `--catalog-url` (the §M.3.4 three-band TTL cache short-circuits when fresh).
3. Parse catalog (version pinned to 1; required fields enforced).
4. Verify Ed25519 signature (`alg` literal-checked as capital-E `"Ed25519"`; signature + pubkey via `base64.RawURLEncoding`).
5. Check `expires_at` (60-second skew grace).
6. Look up `model_id` (case-folded `catalogModelKey`).
7. Compare receipt `model_hash` to catalog `sha256` (case-sensitive lowercase hex).
8. Emit `model_hash_verified: true` on equality; `false` on mismatch; `null` if the algorithm short-circuited before step 7.

### Tri-state `model_hash_verified` (§M.3.2.1)

JSON output (`--json`) now always emits the `model_hash_verified` field:

- `true` — catalog ran AND hash matched.
- `false` — catalog ran AND hash mismatched (`reason: "model_hash_mismatch"`) OR `--require-model-hash` set with null hash (`reason: "model_hash_required"`).
- `null` — catalog did NOT run for any reason (no catalog flags supplied; null `model_hash` without `--require-model-hash`; legacy v0.1/v0.2 receipt; unknown `receipt_version`; catalog fetch / signature / expiry failure that short-circuits before step 7).

### New reasons + warnings

- Reasons: `model_hash_mismatch`, `model_hash_required`, `model_id_not_in_catalog`, `catalog_signature_invalid`, `catalog_unreachable`, `catalog_expired`, `catalog_format_invalid`, `unknown_receipt_version`, `extra_field`, `missing_field`.
- Warnings: `catalog_skipped_legacy_receipt`, `catalog_skipped_null_hash`.
- Schema (`schemas/output.schema.json`) v0.3 bump: `model_hash_verified` REQUIRED tri-state on every variant; conditional `allOf` requires `details.alg` when reason is `catalog_signature_invalid`.

### Catalog cache (§M.3.4)

URL-mode catalog fetches go through a three-band TTL cache at `~/.cache/macprovider-verify/catalog/`:

| Remaining receipt validity (R) | TTL band |
|---|---|
| R > 6h | 6h |
| 60s ≤ R ≤ 6h | R - 60s |
| R < 60s | no cache |

Cache writes are atomic (temp + rename, 0600). Pubkey rotation invalidates (stale entry for one pubkey will not satisfy a request for another). File-mode (`--catalog <path>`) bypasses the cache.

## What's unchanged

- **Pure-stdlib discipline.** `go.mod` unchanged.
- **Trust boundary (§10.6).** The v1.0.x trust statement still applies; v0.3 ADDS a catalog-attested model-honesty claim atop it.
- **Exit codes.** Unchanged: 0 valid, 1 invalid, 2 inconclusive, 64 usage, 65 input.
- **Legacy v0.1/v0.2 verification.** Same code path as v1.0.x; AC-38 cross-binary parity gate (`internal/receipt/v02_parity_test.go`) re-implements the v1.0.x LOCKED parser inline and asserts v0.3 receipts STILL reject as `ErrTupleExtraKey` under that parser — protects the §M.1.2 floor against future drift.

## Audit-loop trajectory

This release ships behind 19 codex audit rounds:

| Phase | Rounds | Closing verdict |
|---|---|---|
| SPEC v0.3.3 LOCK ([PR #130](https://github.com/Augustas11/macprovider/pull/130)) | 3 | 0 CRIT / 0 MAJ across 3 lenses |
| IMPL Step 1 — Swift provider 9-field tuple | 4 | 0/0/0/0 across 3 lenses |
| IMPL Step 2 — coordinator `/poolz` + 2 endpoints | 2 | 0/0/0/0 |
| IMPL Step 3 — nginx + deploy gates | 2 | 0/0/0/0 |
| IMPL Step 4 — pure-Go catalog parser + cache | 2 | 0/0/0/0 |
| IMPL Step 5 — verifier CLI + algorithm + schema | 5 | 0/0/0/0 |
| IMPL Step 6 — integration acceptance + parity | 2 | 0/0/0/0 |
| Bundle cross-step audit (CODE + SECURITY + ARCHITECT) | 1 + 1 SEC retry | 0/0/0/0 |

Per-step transcripts at `specs/SPEC-015-v0-3-IMPL-STEP_{1..6}-audit.md`; bundle transcript at `specs/SPEC-015-v0-3-IMPL-BUNDLE-audit.md`.

## Compatibility table

| macprovider-verify | SPEC-015 receipt versions verified |
|---|---|
| 1.0.x | 0.2.0 through 0.2.4 |
| 1.1.x | 0.2.0 through 0.3.3 (catalog-based model-hash binding per §M) |

## Operator rollout ordering

Per §M.1.2 forward-incompat: **release v1.1.0 to buyers BEFORE rolling out v0.3-emitting providers.** Existing v1.0.x verifiers report v0.3 receipts as `invalid`. Operator runbook at `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md`.

## Install

See `phase7-verify/README.md` install section. SHA-256 sums for each platform binary are published as release assets next to the binary.

## Reporting bugs and security issues

Same as v1.0.x. Use GitHub Issues for non-sensitive verifier bugs; GitHub's private vulnerability reporting for security-sensitive reports. Do not attach private prompts, responses, API keys, or receipt bundles to public issues.
