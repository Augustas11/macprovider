## Lens — CODE — Round 1

### CODE-HIGH-1 — Missing AC-39 failed-catalog negative coverage

Source: `phase4-coordinator/internal/ws/poolz_catalog_test.go:25-75`; `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:157-160`; `specs/SPEC-015-receipts.md:3565-3578`

Severity: HIGH

Problem: `/poolz` tests cover active catalog and no configured catalog, but do not cover the required configured-but-load/parse/signature-failed branches.

The implementation gates the new fields on `s.catalogRef().Active()` in `phase4-coordinator/internal/ws/server.go:2733-2774`, which is the right production predicate, but the new test file only asserts the positive case (`TestPoolzEmitsCatalogFieldsWhenCatalogActive`, lines 25-60) and the empty `CatalogPath` case (`TestPoolzOmitsCatalogFieldsWhenCatalogNotConfigured`, lines 62-75). The Step 2 prompt requires `/poolz` to omit the three fields when a configured catalog failed to load, and SPEC-015 AC-39 requires omission when the catalog fails to load / parse / verify-signature. The audit prompt classifies missing tests for the §M.4 effectively-active branches as HIGH because a future regression could publish stale catalog URLs after a catalog rotation failure without deterministic test failure.

Suggested resolution direction: Add table-driven `/poolz` tests for configured missing file, malformed catalog JSON, and bad signature/wrong pubkey; assert `catalog_id`, `catalog_url`, and `catalog_pubkey_url` are all absent, not null or empty strings.

### CODE-MEDIUM-1 — URL-construction edge cases are not tested

Source: `phase4-coordinator/internal/ws/server.go:2750-2771`; `phase4-coordinator/internal/ws/poolz_catalog_test.go:25-58`

Severity: MEDIUM

Problem: The new `/poolz` URL builder has no tests for trailing-slash `PublicCatalogBaseURL` or host-derived fallback URLs.

The implementation trims configured base URLs before appending `/catalog/<id>` and `/catalog/pubkey`, and falls back to `scheme://r.Host` when `PublicCatalogBaseURL` is empty. The only positive test uses `https://coordinator.malibu.tech` without a trailing slash, so it does not lock the slash-normalization path, host-with-port path, IPv6 host path, or empty-config fallback path called out in the CODE lens. This is not a current functional failure in the inspected code, but it leaves the URL-construction acceptance surface under-specified.

Suggested resolution direction: Extend `poolz_catalog_test.go` with table cases for configured base URL with a trailing slash, no configured base with `Host: example.test:8443`, and an IPv6 host such as `[2001:db8::1]:8443`.

### CODE-LOW-1 — `PublicCatalogBaseURL` comment describes a fallback the code does not implement

Source: `phase4-coordinator/internal/config/config.go:143-151`; `phase4-coordinator/internal/ws/server.go:2766-2771`

Severity: LOW

Problem: The config comment says URL fields are emitted as relative paths when no host is available, but the handler omits those URL fields when no base can be built.

The handler only assigns `catalog_url` and `catalog_pubkey_url` inside `if base != ""`, so the degraded no-base behavior is catalog-id-only. That aligns better with the Step 2 prompt's "catalog_id only" fallback than the config comment's "relative paths" wording, but the comment is misleading for later verifier or deploy authors reading the config struct as the behavior contract.

Suggested resolution direction: Rewrite the comment to say the URL fields are omitted when neither `public_catalog_base_url` nor request `Host` can provide an absolute base.

VERDICT: REQUEST CHANGES — Step 2 should not proceed while the AC-39 failed-catalog test branch is missing.

COUNTS: CRITICAL 0 / HIGH 1 / MEDIUM 1 / LOW 1

## Lens — SECURITY — Round 1

No security findings.

Evidence checked: `/poolz` still requires `authorizedOperator` before response construction (`phase4-coordinator/internal/ws/server.go:2643-2654`); the new catalog endpoints are registered only on the buyer `Handler()` and not the WS/operator mux (`phase4-coordinator/internal/buyer/server.go:393-407`, `phase4-coordinator/internal/ws/server.go:369-381`); the endpoints are intentionally public and share the receipt-keys per-IP bucket with `Retry-After: 1` on 429 (`phase4-coordinator/internal/buyer/server.go:749-805`, `phase4-coordinator/internal/buyer/server.go:823-853`); the URL `catalog_id` is compared with `tier2.CatalogID()` before reading the operator-configured `cfg.CatalogPath`, so it is not used as a filename (`phase4-coordinator/internal/buyer/server.go:755-770`); `/catalog/pubkey` returns only `cfg.CatalogPublicKey` and `alg: "Ed25519"`, with no private-key surface (`phase4-coordinator/internal/buyer/server.go:791-802`); and the audited packages pass the race detector.

VERDICT: READY TO LOCK — SECURITY lens found no CRITICAL/HIGH/MEDIUM issues for Step 2.

COUNTS: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0

## Lens — ARCHITECT — Round 1

### ARCHITECT-HIGH-1 — Step 2 coverage is not complete enough for the staged gate

Source: `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:157-166`; `phase4-coordinator/internal/ws/poolz_catalog_test.go:25-75`; `phase4-coordinator/internal/buyer/catalog_endpoints_test.go:83-98`

Severity: HIGH

Problem: The implementation does not satisfy the Step 2 test matrix because the configured-catalog-failed branch is absent.

The Step 2 build prompt explicitly lists `/poolz` omission when a configured catalog failed to load as a required test, and AC-39 requires the same negative branch before Step 3. The current `/poolz` tests cover active and unconfigured states, while buyer endpoint tests cover active serving, wrong id, no catalog, pubkey response shape, and rate limiting. They do not cover the architectural transition that matters for rollouts: `CatalogPath` set but the active catalog is unavailable because load/parse/signature verification failed. That gap weakens the staged audit loop because Step 3 nginx routing would be built on a Step 2 surface whose negative deploy state is not locked.

Suggested resolution direction: Close the Step 2 test matrix before Step 3 by adding failed-load and failed-signature `/poolz` cases, and consider mirroring the same inactive-catalog state against `/catalog/<id>` and `/catalog/pubkey` 404 behavior.

VERDICT: REQUEST CHANGES — Step 2 is not architecturally complete until the AC-39 negative branch is locked by tests.

COUNTS: CRITICAL 0 / HIGH 1 / MEDIUM 0 / LOW 0

## Lens — CODE — Round 2

No CODE findings.

Evidence checked: the Round 1 AC-39 coverage gap is closed by `TestPoolzOmitsCatalogFieldsWhenCatalogLoadFails`, which table-drives missing-file, malformed-JSON, and signature-mismatch states, confirms `tier2.Active() == false`, and asserts `catalog_id`, `catalog_url`, and `catalog_pubkey_url` are absent from the raw `/poolz` JSON (`phase4-coordinator/internal/ws/poolz_catalog_test.go:78-142`). The URL-construction gap is closed by `TestPoolzCatalogURLConstructionEdgeCases`, which locks trailing-slash trimming for `PublicCatalogBaseURL`, empty-config fallback to scheme plus `Host`, host-with-port, and IPv6 host handling (`phase4-coordinator/internal/ws/poolz_catalog_test.go:144-228`) against the handler logic in `handlePoolz` (`phase4-coordinator/internal/ws/server.go:2733-2774`). The config comment now matches the implementation's no-base behavior: URL fields are omitted while `catalog_id` may still be emitted (`phase4-coordinator/internal/config/config.go:143-155`). The buyer endpoints still return literal catalog bytes / pubkey shape, use the shared receipt-keys rate bucket, cache headers, and `catalog_not_found` envelope (`phase4-coordinator/internal/buyer/server.go:743-805`, `phase4-coordinator/internal/buyer/catalog_endpoints_test.go:21-165`). Verification run: `go test ./...` from `phase4-coordinator/` passed.

VERDICT: READY TO LOCK — CODE lens found no CRITICAL/HIGH/MEDIUM issues for Step 2 after the Round 2 fix pass.

COUNTS: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0

## Lens — SECURITY — Round 2

No SECURITY findings.

Evidence checked: `/poolz` still rejects unauthenticated operator requests before response construction (`phase4-coordinator/internal/ws/server.go:2643-2654`), and the new catalog fields expose only catalog-level URL/id metadata, not per-provider operator-sensitive fields (`phase4-coordinator/internal/ws/server.go:2733-2774`). The catalog endpoints remain registered only on the buyer mux and are intentionally public, unauthenticated, cacheable, and rate-limited (`phase4-coordinator/internal/buyer/server.go:393-407`, `phase4-coordinator/internal/buyer/server.go:743-805`); they are not registered on the WS/operator mux (`phase4-coordinator/internal/ws/server.go:369-381`). The catalog path is read only after the requested URL id matches `tier2.CatalogID()`, so the path parameter is never used as a filename (`phase4-coordinator/internal/buyer/server.go:755-770`). `/catalog/pubkey` returns only the configured public key plus capital-E `Ed25519`, matching the existing signing/validation surfaces (`phase4-coordinator/internal/buyer/server.go:791-802`, `scripts/sign-catalog.go:90`, `scripts/sign-catalog.go:142-145`, `phase4-coordinator/internal/tier2/catalog.go:470-485`). Concurrent catalog reads continue through the existing locked/atomic catalog accessors (`phase4-coordinator/internal/tier2/catalog.go:245-249`, `phase4-coordinator/internal/tier2/catalog.go:333-338`, `phase4-coordinator/internal/ws/server.go:323-331`). Verification run: `go test ./...` from `phase4-coordinator/` passed.

VERDICT: READY TO LOCK — SECURITY lens found no CRITICAL/HIGH/MEDIUM issues for Step 2.

COUNTS: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0

## Lens — ARCHITECT — Round 2

No ARCHITECT findings.

Evidence checked: the Step 2 implementation now covers the build prompt's `/poolz` active, unconfigured, and configured-but-failed catalog branches (`specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:137-167`, `phase4-coordinator/internal/ws/poolz_catalog_test.go:22-142`). It also covers the two public buyer endpoints, 404 envelope, pubkey shape, cache headers, and rate limiting (`phase4-coordinator/internal/buyer/catalog_endpoints_test.go:21-165`). The SPEC-002 candidate annotation remains additive: existing top-level `/poolz` keys `pool` and `summary` are preserved and only the three optional catalog fields were added (`phase4-coordinator/internal/ws/server.go:2738-2745`). Locked-spec and catalog-parser boundaries remain intact: `git diff --name-only main -- phase4-coordinator/internal/tier2 specs/SPEC-001-* specs/SPEC-002-* specs/SPEC-005-* specs/SPEC-006-* specs/SPEC-008-* specs/SPEC-010-* specs/SPEC-011-* specs/SPEC-013-*` returned no paths. Entry 80 orthogonality is preserved because the Step 2 diff does not change `RequireHashVerified` routing semantics, only the config struct's new `PublicCatalogBaseURL` field/comment (`phase4-coordinator/internal/config/config.go:140-155`, `phase4-coordinator/cmd/coordinator/main.go:631-640`). Verification run: `go test ./...` from `phase4-coordinator/` passed.

VERDICT: READY TO LOCK — ARCHITECT lens found no CRITICAL/HIGH/MEDIUM issues for Step 2 after the Round 2 fix pass.

COUNTS: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0
