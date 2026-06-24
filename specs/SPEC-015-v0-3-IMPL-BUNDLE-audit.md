# SPEC-015 v0.3 IMPL bundle audit — cross-step / system-level

Branch: `impl/spec-015-v0-3` (PR #131)
Head: `26eeda9` (Step 6) atop SPEC v0.3.3 LOCK `af53cb1`

Audit prompt: [specs/AUDIT_SPEC_015_v0_3_IMPL_BUNDLE_PROMPT.md](AUDIT_SPEC_015_v0_3_IMPL_BUNDLE_PROMPT.md)

Per-step transcripts (already 0/0/0/0 at lock):
- [Step 1](SPEC-015-v0-3-IMPL-STEP_1-audit.md)
- [Step 2](SPEC-015-v0-3-IMPL-STEP_2-audit.md)
- [Step 3](SPEC-015-v0-3-IMPL-STEP_3-audit.md)
- [Step 4](SPEC-015-v0-3-IMPL-STEP_4-audit.md)
- [Step 5](SPEC-015-v0-3-IMPL-STEP_5-audit.md)
- [Step 6](SPEC-015-v0-3-IMPL-STEP_6-audit.md)

---

## Lens — CODE — Round 1

No CRITICAL findings.

No HIGH findings.

No MEDIUM findings.

No LOW findings.

Validation evidence:
- Read the CODE focus files across producer, coordinator, verifier, cache, deploy gate, and manifest paths changed by `af53cb1..26eeda9`.
- Confirmed v0.3 tuple parity for non-null and null-hash fixtures: Swift emits exactly nine JCS-sorted fields, `model_hash:null` is preserved for the null case, and the Go verifier parses the same wire shape without re-canonicalizing signed bytes.
- Confirmed live parser dispatch detects unknown non-`"3"` `receipt_version` before strict v0.3 shape validation, preserving §M.1.4.
- Confirmed `parseTupleV02Locked` mirrors the locked `99d0c1e` seven-key parser closely enough for AC-38: v0.3 null and non-null receipts reject as `ErrTupleExtraKey`, while a legacy seven-field tuple accepts.
- Confirmed §M.3.2 catalog flow composes cache hit, parse, signature verification, case-folded model lookup, hash comparison, and `model_hash_verified=true` only after successful verification.
- Confirmed §M.3.4 TTL bands are enforced at cache write time and covered by tests for `R > 6h`, `R in [60s, 6h]`, and `R < 60s`.
- Confirmed `/poolz` catalog fields are gated by an effectively active signed catalog, and `/catalog/<id>` plus `/catalog/pubkey` are public, receipt-key-bucket rate-limited, and emit `alg:"Ed25519"`.
- Confirmed the nginx deploy gate scopes `proxy_pass` to the `/catalog/` block and fails a crafted broken config that points `/catalog/` at `127.0.0.1:8444`.
- Confirmed the acceptance manifest has AC-28..AC-42 plus a separate AC-32a entry, at least two evidence anchors per AC, and per-AC subtests.

Commands run:
- `bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh`
- crafted broken nginx config with `/catalog/` proxying to `127.0.0.1:8444` -> expected gate failure
- `cd phase7-verify && go test ./internal/receipt ./internal/verify ./internal/cache/catalog ./internal/catalog ./internal/cli -count=1`
- `cd phase4-coordinator && go test ./internal/ws ./internal/buyer ./internal/tier2 -count=1`
- `cd test/integration && go test ./spec015 -run 'TestSpec015V03Acceptance' -count=1`
- `cd test/integration && go test ./spec015 -run 'TestSpec015V03AcceptanceManifestCoversAC28ThroughAC42' -count=1`
- `cd phase3-binary && swift test --filter 'ReceiptBuilderTests|HTTPServerReceiptTests|InferenceRelayTests/testRelayNonStreamingEndFrameCarriesV03Receipt|JCSGoldenFixtureTests'`

VERDICT: PASS — no cross-step CODE defects found against SPEC-015 v0.3 §M.0..§M.6 focus areas.

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0

## Lens — SECURITY — Round 1

### CRITICAL-1-SECURITY-1 No-catalog non-null model_hash path still returns valid

phase7-verify/internal/verify/catalog_check.go:82 — v0.3 receipts with a non-null `model_hash` and no catalog flags return an empty catalog verdict:
```
if !opts.Catalog.Enabled {
	return v
}
```
phase7-verify/internal/verify/verify.go:377 — the empty catalog verdict falls through to `base.Result = resultValid`, so a non-null hash can produce `valid` with `model_hash_verified:null` instead of the threat-model-required inconclusive result. The same gap reaches `--require-model-hash` because `phase7-verify/internal/cli/cli.go:267` only derives catalog presence from `--catalog` / `--catalog-url` and never rejects `--require-model-hash` without a catalog source.
Why it matters: A provider or attacker holding a receipt key can assert an arbitrary non-null `model_hash` and still obtain a `valid` v0.3 verifier result when the buyer did not configure a catalog, which is exactly the no-catalog forge-a-receipt scenario this SECURITY lens says must be impossible.
Suggested fix: Treat v0.3 non-null `model_hash` with no catalog source as `inconclusive` (or reject `--require-model-hash` without catalog flags at CLI parse time) and add regression coverage for non-null v0.3 receipts with no catalog flags, including the `--require-model-hash` case.

### HIGH-1-SECURITY-2 Catalog endpoint rate-limit buckets collapse behind nginx loopback

phase4-coordinator/internal/buyer/server.go:828 — the public catalog endpoints share `allowReceiptKeys`, which keys solely from `poolCheckClientKey(r)`:
```
key := poolCheckClientKey(r)
now := s.now()
s.receiptKeysMu.Lock()
```
phase4-coordinator/internal/buyer/server.go:902 — that helper returns only the host from `r.RemoteAddr`, while `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:170` proxies `/catalog/` through local `127.0.0.1:8443` and places the real buyer IP only in `X-Real-IP` / `X-Forwarded-For`. In production, every public buyer therefore shares the loopback bucket.
Why it matters: One buyer can exhaust the shared `/catalog/*` and `/v1/receipt-keys/*` bucket for other buyers, defeating the prompt's endpoint-amplification isolation requirement.
Suggested fix: Replace `poolCheckClientKey` / `allowReceiptKeys` keying with a loopback-proxy-aware helper equivalent to `remoteIPForUnauthSemaphore`, honoring `X-Real-IP` only when the immediate remote is loopback, and add a regression proving two different `X-Real-IP` values behind `127.0.0.1` get independent buckets.

No MEDIUM findings.

No LOW findings.

Validation evidence:
Read the SECURITY focus files named by the prompt across CLI flag validation, catalog signature verification, catalog cache, coordinator buyer endpoints, output schema, Entry 80 config/defaults, deploy gate, runbook, and v0.2 forward-incompat parity. Confirmed operator-key smoke examples use `$OP` rather than a literal key; catalog signatures require exact `Ed25519` and raw URL-safe base64; cache writes use `0600` temp file plus rename, reject stale entries, and bind entries to pubkey; `/catalog/<id>` does not use the path segment for filesystem paths; schema branches require `model_hash_verified` with boolean-or-null type; Entry 80 stays false by default; deploy step 0 runs the nginx catalog gate without a `SKIP_NGINX_CHECK` bypass; and v0.2 locked parity rejects null and non-null v0.3 receipts.

Commands run:
- `cd phase7-verify && go test ./internal/cli ./internal/verify ./internal/catalog ./internal/cache/catalog ./internal/receipt -count=1`
- `cd phase7-verify && go test ./internal/cli -run 'TestV03SchemaConformance|TestSchemaValidationValid|TestSchemaRejectsExtraProperty|TestSchemaRejectsTrustSourceCoordinatorHostMismatches' -count=1`
- `cd phase7-verify && go test ./internal/receipt -run TestV02LockedParserRejectsV03Receipts -count=1`
- `cd phase7-verify && go test ./internal/catalog ./internal/cache/catalog -count=1`
- `cd phase4-coordinator && go test ./internal/buyer -run 'TestCatalogEndpointRateLimited|TestPoolCheckRateLimitIgnoresSpoofedXForwardedFor' -count=1`
- `cd phase4-coordinator && go test ./internal/buyer -run 'TestCatalogFileServesActiveCatalogBytes|TestCatalogFile404OnUnknownCatalogID|TestCatalogPubkeyReturnsBase64URLPubkeyAndCapitalEd25519|TestCatalogEndpointRateLimited' -count=1`
- `cd phase4-coordinator && go test ./internal/config -run 'TestDefault|TestRequireHashVerified|TestCatalog' -count=1`
- `bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh`

VERDICT: FAIL — the bundle still has a no-catalog v0.3 hash fail-open and a public catalog endpoint bucket-isolation defect.

COUNTS: CRITICAL=1 HIGH=1 MEDIUM=0 LOW=0

## Lens — SECURITY — Round 2

No CRITICAL findings.

No HIGH findings.

No MEDIUM findings.

No LOW findings.

Validation evidence:
- HIGH-1-SECURITY-2 is closed in `phase4-coordinator/internal/buyer/server.go:823-929`: `allowReceiptKeys` and `allowPoolCheck` both key through `poolCheckClientKey`, and `poolCheckClientKey` now honors `X-Real-IP` only when the immediate `r.RemoteAddr` host parses as loopback. Direct non-loopback callers still key on the parsed `RemoteAddr` host, so spoofed `X-Real-IP` does not split their bucket.
- Confirmed there is no catalog-specific alternate key path: `/catalog/pubkey`, `/catalog/{catalog_id}`, and `/v1/receipt-keys/{provider_id}` all reach the same receipt-keys bucket via `allowReceiptKeys`; `/poolz` reaches the same loopback-aware helper via `allowPoolCheck`.
- Confirmed production nginx supports the trust boundary assumed by the fix: `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:149-175` proxies `/v1/receipt-keys/` and `/catalog/` to loopback buyer port `127.0.0.1:8443` and overwrites `X-Real-IP` with `$remote_addr`.
- Confirmed the new regression fires on the intended properties in `phase4-coordinator/internal/buyer/catalog_endpoints_test.go:178-219`: buyer A behind `127.0.0.1` exhausts only its own `X-Real-IP` bucket, buyer B behind the same loopback gets a fresh bucket, and a direct non-loopback caller cannot escape by changing `X-Real-IP`.
- Re-traced the related SECURITY surfaces without finding a new cross-step defect: catalog signatures still require exact `Ed25519` and raw URL-safe base64 (`phase7-verify/internal/catalog/catalog.go:195-226`); cache writes remain temp-file plus rename with `0600`, expiry rejection, and pubkey-rotation invalidation (`phase7-verify/internal/cache/catalog/catalog_cache.go:117-169`); schema branches require `model_hash_verified` and type it as boolean-or-null (`phase7-verify/schemas/output.schema.json:17,168-172,219,432-435,510,670-673`); Entry 80 default remains `RequireHashVerified: false` (`phase4-coordinator/internal/config/config.go:344-349`); deploy step 0 runs the catalog nginx gate with no `SKIP_NGINX_CHECK` bypass (`phase4-coordinator/dist/deploy-pearl-vps.sh:87-95`).
- Re-traced mid-swap receipt provenance: HTTP and relay receipt paths use `completeWithServedSnapshot` for successful receipts and refuse `.ambiguous` provenance with `model_swap_violation` omission (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:257-285,650-666`; `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-320,350-360`; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:388-410`).
- Did not re-litigate CRIT-1-SECURITY-1: the locked SPEC text cited in the fix pass says `--require-model-hash` without catalog flags is legal and yields `valid` with `model_hash_verified:null` when signature checks (`specs/SPEC-015-receipts.md:2988-2994`), and the tri-state row lists "no catalog flags supplied" as a `null` cause (`specs/SPEC-015-receipts.md:3120`).

Commands run:
- `cd phase4-coordinator && go test ./internal/buyer -run 'TestCatalogEndpointRateLimited|TestCatalogEndpointRateLimitedPerXRealIPBehindLoopback' -count=1`
- `cd phase4-coordinator && go test ./internal/buyer -run '^TestCatalogEndpointRateLimitedPerXRealIPBehindLoopback$' -count=1 -v`
- `cd phase4-coordinator && go test ./internal/buyer -count=1`
- `cd phase7-verify && go test ./internal/cli -run 'TestV03SchemaConformance|TestSchema' -count=1`
- `cd phase7-verify && go test ./internal/catalog ./internal/cache/catalog ./internal/receipt -count=1`
- `cd phase7-verify && go test ./internal/verify -count=1`
- `cd phase4-coordinator && bash dist/test/check_nginx_catalog_routes_test.sh`
- `swift test --package-path phase3-binary --filter 'HTTPServerReceiptTests|InferenceRelayTests/testRelayNonStreamingEndFrameCarriesV03Receipt|ReceiptBuilderTests'`

VERDICT: PASS — HIGH-1 bucket isolation is fixed and no new SECURITY cross-step defects were found in the bounded Round 2 re-trace.

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0

## Lens — ARCHITECT — Round 1

No CRITICAL findings.

No HIGH findings.

No MEDIUM findings.

No LOW findings.

Validation evidence:
Confirmed the end-to-end /poolz -> /catalog -> verifier contract is wired across the bundle: provider receipt construction binds `model_hash` to the served runtime snapshot via `completeWithServedSnapshot` (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:388-410`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:257-285`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-320`); `/poolz` emits `catalog_id`, `catalog_url`, and `catalog_pubkey_url` from the active catalog contract (`phase4-coordinator/internal/ws/server.go:2733-2774`); nginx and the buyer server expose `/catalog/<catalog_id>` and `/catalog/pubkey` on the buyer port with the same public route names (`phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:158-176`, `phase4-coordinator/internal/buyer/server.go:393-405`, `phase4-coordinator/internal/buyer/server.go:743-805`); and the verifier resolves pubkey + catalog bytes, verifies signature/expiry, performs case-folded model lookup, and only then sets `model_hash_verified=true` (`phase7-verify/internal/verify/catalog_check.go:88-185`, `phase7-verify/internal/catalog/catalog.go:173-257`).

Confirmed the §M.1.2 rollout contract and Entry 80 orthogonality: the SPEC requires locked v0.1/v0.2 verifiers to reject v0.3 receipts as invalid and tells buyers to coordinate verifier upgrades with provider upgrades (`specs/SPEC-015-receipts.md:2652-2675`), matching the runbook's verifier-before-provider choreography (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:85-101`). Entry 80 remains independent: the default is still `RequireHashVerified: false` (`phase4-coordinator/internal/config/config.go:344-349`), the decision log preserves the deferral (`beta/DECISION_CRITERIA.md:374`), the SPEC says v0.3 binds receipts without flipping coordinator route/reject policy (`specs/SPEC-015-receipts.md:2571-2580`), and the runbook repeats the invariant (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:153-155`).

Confirmed §M.6 scope discipline and tagged-union receipt-version dispatch. The runbook's v0.4+ candidate list matches the prompt's six deferred implementation areas and states none are landing in v0.3 (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:164-173`); no changed file implements streaming receipts, multi-hash receipts, cross-catalog federation, on-chain anchoring, quantization-aware verification, or TUF/signed-root trust. The receipt parser detects unknown non-"3" `receipt_version` before strict shape validation and returns a version-only tuple stub (`phase7-verify/internal/receipt/receipt.go:207-228`); the verifier then short-circuits to `inconclusive: unknown_receipt_version` before signature or catalog work (`phase7-verify/internal/verify/verify.go:252-268`).

Confirmed the AC manifest is a living contract and the cross-step seams line up. The manifest has AC-28..AC-42 plus a distinct AC-32a sentinel (`test/integration/spec015/v03_acceptance_manifest_test.go:14-211`), enforces at least two evidence anchors and pattern existence per AC (`test/integration/spec015/v03_acceptance_manifest_test.go:213-248`), and separately checks the 28..42 coverage range (`test/integration/spec015/v03_acceptance_manifest_test.go:250-268`). Step-overlap review showed the expected coupling only: Step 4 catalog parser is consumed by Step 5 verifier integration, Step 1 receipt tuple is covered by Step 6 cross-binary parity, and Step 2 coordinator endpoints are routed by Step 3 nginx/deploy gate; field names, status codes, alg casing, and error envelope names matched across those boundaries.

Confirmed runbook composability and drift posture. The deploy script snapshots `/opt/macprovider/coordinator` to `/opt/macprovider/coordinator.prev` with explicit ownership/mode before upload (`phase4-coordinator/dist/deploy-pearl-vps.sh:220-233`), matching the rollback commands in the runbook (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:116-147`), and installs the full nginx site after the pre-SSH catalog-route gate (`phase4-coordinator/dist/deploy-pearl-vps.sh:87-95`, `phase4-coordinator/dist/deploy-pearl-vps.sh:313-326`). Runbook references to `GATEWAY_CONFIG`, `public_catalog_base_url`, `/poolz`, `/catalog/pubkey`, `/catalog/<id>`, `catalog_loaded`, `model_hash_verified`, `catalog_signature_invalid`, `macprovider-coordinator`, and the rollback path were checked against code or files on this branch; no stale operator instruction was found.

Commands run:
- `cd test/integration && go test ./spec015 -run 'TestSpec015V03AcceptanceCriteria|TestSpec015V03AcceptanceManifestCoversAC28ThroughAC42' -count=1 -v` -> AC-28 through AC-42 and AC-32a subtests all PASS.
- `cd phase4-coordinator && go test ./internal/ws ./internal/buyer ./internal/tier2 -run 'TestPoolzEmitsCatalogFieldsWhenCatalogActive|TestPoolzOmitsCatalogFieldsWhenCatalogNotConfigured|TestPoolzOmitsCatalogFieldsWhenCatalogLoadFails|TestCatalogFileServesActiveCatalogBytes|TestCatalogFile404OnUnknownCatalogID|TestCatalogPubkeyReturnsBase64URLPubkeyAndCapitalEd25519|TestCatalogEndpointRateLimited|TestCatalogEndpointRateLimitedPerXRealIPBehindLoopback|Test.*Hash|Test.*Catalog' -count=1 -v` -> PASS.
- `cd phase7-verify && go test ./internal/receipt ./internal/verify ./internal/catalog ./internal/cache/catalog -run 'TestV02LockedParserRejectsV03Receipts|TestCatalogCheck|TestVerify|TestComputeTTLBands|TestPutSkipsBelowMinTTL|TestGetMissOnPubkeyRotation|TestGetMissOnStaleEntry' -count=1 -v` -> PASS.
- `cd phase7-verify && go test ./internal/receipt ./internal/verify ./internal/cli -run 'Unknown|ReceiptVersion|V03' -count=1 -v` -> PASS, including `TestV03SchemaConformance/unknown_receipt_version`.
- `swift test --package-path phase3-binary --filter 'ReceiptBuilderTests|HTTPServerReceiptTests/testHTTPSuccessReceiptCarriesWarmSwapHash|HTTPServerReceiptTests/testHTTPReceiptRefusedOnAmbiguousProvenance|HTTPServerReceiptTests/testHTTPAmbiguousProvenanceEmitsReceiptOmittedAudit|InferenceRelayTests/testRelayNonStreamingEndFrameCarriesV03Receipt|JCSGoldenFixtureTests'` -> 13 selected tests passed.
- `bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh` -> `ok: SPEC-015 v0.3 §M.4 catalog routes present in nginx conf`.

VERDICT: PASS — no cross-step ARCHITECT defects found; the system-level contracts, rollout ordering, Entry 80 preservation, runbook/deploy composition, and AC manifest all hold for the v0.3 IMPL bundle.

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0
