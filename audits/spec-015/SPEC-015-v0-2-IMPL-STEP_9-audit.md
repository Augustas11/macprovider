# SPEC-015 v0.2 Step 9 audit

## Round 1 by Codex

Read-only audit against `impl/spec-015-v0-2-step-09` over base `impl/spec-015-v0-2-step-08`, using `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_9_PROMPT.md` plus the requested code/security/architect lenses.

### Code lens

#### HIGH C1 - `bundle_pubkey_provider_mismatch` preflight falsely rejects valid previous-key receipts when cache is populated

`phase7-verify/internal/cli/cli.go:245` calls `bundlePubkeyProviderMismatchResult` before `verify.Verify()`. That preflight parses the receipt pubkey and compares it only with `singleCacheEntryForProvider(...).ReceiptPubkey` at `phase7-verify/internal/cli/cli.go:374`-`389`; if different, it returns `invalid/bundle_pubkey_provider_mismatch` at `phase7-verify/internal/cli/cli.go:391`-`404`.

That bypasses the locked previous-key grace logic in `verify.Verify()`: `phase7-verify/internal/verify/verify.go:333`-`352` accepts `root.PubkeyPrev.Pubkey` when the receipt timestamp is inside the grace window. A normal cache entry can contain both current and previous keys (`phase7-verify/internal/cache/cache.go:59`-`65`, `phase7-verify/internal/cache/cache.go:311`-`324`), so a valid previous-key-in-grace bundle is rejected before the verifier can use the cached `receipt_pubkey_prev`.

Concrete repro run during audit:

```text
MACPROVIDER_CACHE_DIR=<tmp-with-current-plus-prev-cache> /tmp/macprovider-verify-r1 --bundle testdata/valid_prev_key_in_grace.bundle.json --json --offline
{"result":"invalid","reason":"bundle_pubkey_provider_mismatch",...}
EXIT=1
```

Expected result is `valid/signature_and_canonicalization_match`, because the same fixture passes when resolved through live previous-key data in `phase7-verify/integration_test.go:126` and the verifier grace logic accepts previous keys. The preflight should either compare against both current and previous cached keys with the same grace-window rules, or avoid preempting `Verify()` for cache records that carry `receipt_pubkey_prev`.

#### MEDIUM C2 - Step 9 integration does not exercise every schema/implementation reason value exposed today

The integration table exercises `signature_and_canonicalization_match`, all six invalid reasons, `pubkey_unresolvable`, `provider_id_not_in_pool`, and `cache_stale_and_live_unreachable` at `phase7-verify/integration_test.go:125`-`137`. It does not exercise top-level `provider_id_unresolvable`.

There is a contract tension: current `specs/SPEC-015-receipts.md:1822`-`1827` excludes `provider_id_unresolvable` from top-level inconclusive reasons, but `phase7-verify/schemas/output.schema.json:217`-`221` still permits it and `phase7-verify/internal/verify/verify.go:392`-`400` can map a `live_check_skipped/provider_id_unresolvable` warning into that top-level reason when `Verify()` is called directly without a provider id. Because the requested AC-24 fixture gate explicitly asks the integration test to exercise every reason value, Step 9 should either add a harness-driven top-level `provider_id_unresolvable` case or remove that top-level reason from schema/implementation if the spec exclusion is intentional.

#### INFO C3 - Positive coverage and validation evidence

The committed corpus has 12 bundle files, matching the expected count. The table in `phase7-verify/integration_test.go:125`-`137` covers both valid fixtures, six invalid fixtures including `invalid_bundle_pubkey_provider_mismatch.bundle.json`, two malformed exit-65 cases, and three inconclusive flows. Malformed bundles return before schema validation and require empty stdout at `phase7-verify/integration_test.go:169`-`173`.

The JSON schema gate is real: `phase7-verify/integration_test.go:35` imports `internal/schemavalidator`, and every JSON-emitting fixture stdout is validated via `schemavalidator.Validate(schema, stdout)` at `phase7-verify/integration_test.go:178`-`180`. The old output tests also use the extracted package at `phase7-verify/internal/cli/output_test.go:13` and `phase7-verify/internal/cli/output_test.go:387`-`389`; the remaining `validateRawJSON` helper delegates to the package at `phase7-verify/internal/cli/output_test.go:438`-`439`, so there is no inline duplicate validator.

Fixture generation is seed-driven: `phase7-verify/testdata/generator/main.go:49`-`58` reads only flags, `phase7-verify/testdata/generator/main.go:62`-`147` derives fixtures from the seed, and `phase7-verify/testdata/generator/main.go:260`-`264` derives ed25519 keys from SHA-256(seed,label). The generator has no `time.Now`, environment reads, or unseeded randomness. `json.MarshalIndent` over maps is Go's stable sorted-key encoding; the integration test enforces byte-for-byte regeneration twice and against committed bundles at `phase7-verify/integration_test.go:203`-`227`.

**Code lens verdict: NOT READY.** Residual risk: preflight coverage misses an ordinary cached-previous-key state, and the reason-value gate is still ambiguous for `provider_id_unresolvable`.

### Security lens

#### HIGH S1 - The bundle mismatch preflight turns local cache state into a premature invalid verdict

The same root cause as C1 is a security/trust-boundary issue. `phase7-verify/internal/cli/cli.go:374`-`389` treats any single cache entry for the provider as decisive before live resolution, signature verification, prompt/output hash checks, and previous-key grace-window checks run. A stale or partially representative local cache can therefore force a forged-looking `invalid/bundle_pubkey_provider_mismatch` result for a valid previous-key receipt.

This is especially sensitive because cache data is intentionally local verifier state, not a fresh coordinator assertion. The authoritative invalid no-match rule belongs in `verify.Verify()` after resolver selection and previous-key evaluation (`phase7-verify/internal/verify/verify.go:184`-`220`, `phase7-verify/internal/verify/verify.go:333`-`363`). Step 9 needs a regression test that seeds current+previous cache and verifies `valid_prev_key_in_grace.bundle.json` remains valid.

#### INFO S2 - Network isolation and TLS discipline look sound in the fixture test

The integration test routes every expected live fetch to an in-process TLS server (`phase7-verify/integration_test.go:153`, `phase7-verify/integration_test.go:313`-`326`) and passes the mock CA only through the child-process environment (`phase7-verify/integration_test.go:288`-`296`). The mock counts calls and asserts expected network/no-network behavior at `phase7-verify/integration_test.go:193`-`198`. Resolver production code still normalizes to HTTPS and clamps redirects/timeouts in `phase7-verify/internal/resolver/resolver.go:235`-`274` and `phase7-verify/internal/resolver/resolver.go:326`-`330`.

The stale-cache fixture seeds `fetched_at = time.Now().UTC().Add(-8*24*time.Hour)` at `phase7-verify/integration_test.go:158`-`160`, exceeding the 7-day TTL in `phase7-verify/internal/cache/cache.go:20`-`21`. Real `time.Now()` is used for test certificates and `fetched_at`; that is not ideal pure time injection, but it is bounded and did not create observed flakiness in this audit.

**Security lens verdict: NOT READY.** Residual risk: a local cache entry can currently override the verifier's previous-key trust rules before the actual verification algorithm runs.

### Architect lens

#### HIGH A1 - Mock `/v1/receipt-keys` parity cannot be proven because the named buyer handler is absent

The audit prompt asks to compare `phase7-verify/integration_test.go`'s mock to `phase4-coordinator/internal/buyer/server.go handleReceiptKeys`. On this branch, `phase4-coordinator/internal/buyer/server.go:379`-`385` registers only `/healthz`, `/v1/models`, `/v1/pool/check`, and `/v1/chat/completions`; there is no `/v1/receipt-keys/{provider_id}` route and `rg 'receipt-keys|handleReceiptKeys' phase4-coordinator/internal/buyer` finds no handler. Current SPEC-015 requires the public buyer-port endpoint at `specs/SPEC-015-receipts.md:2074`-`2081` and pins the success/error shape at `specs/SPEC-015-receipts.md:2093`-`2121`.

The Step 9 mock implements the expected path and 200/404/5xx dispositions at `phase7-verify/integration_test.go:247`-`279`, but without a production handler the integration test is validating only the verifier against a test double. It cannot catch route placement, response-shape leakage, error-envelope drift, cache headers, or auth exposure regressions in the real coordinator. Either the production endpoint must already exist in the audited base, or this Step 9 lock should fail until the real handler lands and the mock is compared against it.

#### INFO A2 - No Step 10 release-artifact creep found in the diff

Against Step 8, `phase7-verify/go.sum`, `phase7-verify/LICENSE`, `phase7-verify/README.md`, and `phase7-verify/internal/version/version.go` are unchanged. The only non-`phase7-verify` implementation change is the CI job that runs the fixture integration test in `.github/workflows/ci.yml:100`-`126`; it does not pre-implement Step 10 checksums, README polish, license changes, or a version bump. The built binary still reports `macprovider-verify 0.1.0-step1-scaffold`, consistent with Step 10 not having landed.

**Architect lens verdict: NOT READY.** Residual risk: the verifier fixture suite can pass while the buyer-facing coordinator endpoint is missing or drifting.

### Verification evidence

- `cd phase7-verify && go vet ./...` -> pass.
- `cd phase7-verify && go test ./... -race -count=1 -v 2>&1 | tail -30` -> pass; tail ended with `internal/verify` and `internal/version` passing.
- `cd phase7-verify && go test -tags=integration -count=1 -timeout 90s ./... 2>&1 | tail -20` -> pass; package tail showed all phase7 packages passing; measured `WALL_SECONDS=8`, under 60 seconds.
- Targeted fixture confirmation: `go test -tags=integration -run 'TestReceiptBundleFixturesEndToEnd|TestFixtureGeneratorIdempotentAndCommitted' -count=1 -timeout 90s -v .` -> pass in `1.855s`, including every listed fixture subtest and generator idempotency.
- `cd phase7-verify && go build -o /tmp/macprovider-verify-r1 ./cmd/macprovider-verify` -> pass.
- `/tmp/macprovider-verify-r1 --version` -> `macprovider-verify 0.1.0-step1-scaffold`.
- `/tmp/macprovider-verify-r1 --help` -> printed usage with bundle/header/hash/pubkey/provider-id/json/offline/coordinator flags.
- `test -z "$(git diff impl/spec-015-v0-2-step-08 -- phase7-verify/go.sum)"` -> pass.
- `ls phase7-verify/testdata/*.bundle.json | wc -l` -> `12`.
- Generator bundle-only check: two `go run ./testdata/generator -seed 0xCAFEBABE` outputs were byte-identical to each other and to every committed `testdata/*.bundle.json`.
- Exact directory spot-check command produced no non-`Only in` drift lines; raw `diff` status was `1` only because `testdata/` also contains non-bundle fixtures absent from the generator output directory.
- `grep -n "bundle_pubkey_provider_mismatch" phase7-verify/internal/cli/cli.go phase7-verify/testdata/EXPECTED_RESULTS.md` -> found the preflight result at `cli.go:393` and expected-result row at `EXPECTED_RESULTS.md:21`.

### Overall verdict

NOT READY - 0 CRITICAL, 3 HIGH, 1 MEDIUM, 4 INFO. The target `READY TO LOCK` condition is not met.

## Round 2 by Codex

Read-only audit against `impl/spec-015-v0-2-step-09` over base `impl/spec-015-v0-2-step-08`, focused on the two round-1 fix commits and the requested code/security/architect lenses. I did not modify code, tests, fixtures, or specs other than appending this round-2 audit section.

### Code lens

#### MEDIUM C4 - Newly added coordinator receipt-key grace test is time-dependent and will fail after 2026-06-29T12:00:00Z

`phase4-coordinator/internal/buyer/receipt_keys_test.go:105`-`116` hard-codes `TestReceiptKeysReturnsPreviousKeyInGraceWindow` with `rotatedAt = 2026-06-22T12:00:00Z` and `expiresAt = 2026-06-29T12:00:00Z`, but it does not freeze `server.now`. `NewServer` defaults `now` to `time.Now().UTC()` at `phase4-coordinator/internal/buyer/server.go:355`-`384`, and `handleReceiptKeys` serializes `receipt_pubkey_prev` only while `now.Before(provider.ReceiptPubkeyPrev.ExpiresAt)` at `phase4-coordinator/internal/buyer/server.go:711`-`725`.

This passes on the audit date (`date -u` returned `2026-06-23T18:16:43Z`) and the buyer suite is green now, but starting at `2026-06-29T12:00:00Z` the handler will return `receipt_pubkey_prev: null`, causing the test's `receipt_pubkey_prev = nil` assertion at `phase4-coordinator/internal/buyer/receipt_keys_test.go:133`-`134` to fail. The adjacent expired-key test explicitly documents the wall-clock dependency at `phase4-coordinator/internal/buyer/receipt_keys_test.go:72`-`75`, and the rate-limit test already freezes `server.now` at `phase4-coordinator/internal/buyer/receipt_keys_test.go:217`-`219`, so this is a localized test stability gap, not a production handler bug.

#### INFO C5 - Round-1 preflight removal and enum reconciliation are otherwise verified

`bundlePubkeyProviderMismatchResult` has no remaining code reference outside the round-1 audit text, and `invalid_bundle_pubkey_provider_mismatch.bundle.json` has no remaining fixture/testdata reference outside the round-1 audit text. The old preflight call is absent from `optionsToVerifyArgs`, which now resolves provider id and passes control into `verify.Verify` at `phase7-verify/internal/cli/cli.go:221`-`239`.

The reserved `bundle_pubkey_provider_mismatch` value remains declared in `phase7-verify/internal/verify/verify.go:33` and remains permitted by the invalid schema enum at `phase7-verify/schemas/output.schema.json:101`-`109`. The regression path now has direct coverage in `TestValidPreviousKeyInGraceAcceptsCurrentAndPreviousCacheOffline` at `phase7-verify/integration_test.go:197`-`239`; the targeted command passed:

```text
go test -tags=integration -v -run TestValidPreviousKeyInGraceAcceptsCurrentAndPreviousCacheOffline -count=1 -timeout 60s .
--- PASS: TestValidPreviousKeyInGraceAcceptsCurrentAndPreviousCacheOffline (0.29s)
PASS
```

The top-level inconclusive schema reason enum is exactly `pubkey_unresolvable`, `provider_id_not_in_pool`, and `cache_stale_and_live_unreachable` at `phase7-verify/schemas/output.schema.json:215`-`221`. The `provider_id_unresolvable` value remains valid only inside `live_check_skipped` warning enums, for example at `phase7-verify/schemas/output.schema.json:241`-`248`. `sourceNoneReason` maps a `live_check_skipped/provider_id_unresolvable` warning to the spec-legal top-level `pubkey_unresolvable` at `phase7-verify/internal/verify/verify.go:392`-`408`, and `TestSchemaRejectsTopLevelProviderIDUnresolvable` rejects the old top-level value at `phase7-verify/internal/cli/output_test.go:303`-`308`.

**Code lens verdict: NOT READY.** Residual risk: all functional round-1 fixes pass today, but the new coordinator buyer test suite has a near-term wall-clock failure.

### Security lens

#### INFO S3 - Preflight removal does not create an observed pubkey/provider bypass

With the CLI preflight gone, verifier-owned trust-root resolution runs before endorsement checks at `phase7-verify/internal/verify/verify.go:184`-`209`, then current-key, previous-key, and grace-window endorsement are enforced in `trustedVerificationKey` at `phase7-verify/internal/verify/verify.go:317`-`360`. A receipt pubkey that matches neither the live/cache current key nor a previous key in its grace window still returns `invalid/pubkey_not_endorsed`; the CLI regression asserts that both bundle and header modes avoid the reserved preflight reason and still reject the mismatch at `phase7-verify/internal/cli/cli_test.go:537`-`588`.

Warning/top-level reason separation is also clean: resolver emits `live_check_skipped` with `provider_id_unresolvable` only as warning metadata when provider id cannot be resolved (`phase7-verify/internal/resolver/resolver.go:154`-`161`), while verifier maps the top-level result to `pubkey_unresolvable` (`phase7-verify/internal/verify/verify.go:392`-`408`). I found no new security bypass or dropped exit-code path from the preflight removal/remapping pass; AC-25 exit codes remain covered at `phase7-verify/internal/cli/cli_test.go:27`-`93`, and `exitForResult`/`exitForError` still route valid/invalid/inconclusive/usage/data errors at `phase7-verify/internal/cli/cli.go:391`-`417`.

**Security lens verdict: READY TO LOCK.** Residual risk: the 5xx integration disposition models coordinator/server unavailability rather than an explicit `handleReceiptKeys` branch, but resolver handling for 429/5xx fetch failures is covered and no security downgrade was observed.

### Architect lens

#### LOW A2 - Receipt-keys mock is intentionally narrower than the real success payload for legacy null current keys

The coordinator route and handler now exist: `phase4-coordinator/internal/buyer/server.go:392`-`399` registers `GET /v1/receipt-keys/{provider_id}`, and `handleReceiptKeys` is implemented at `phase4-coordinator/internal/buyer/server.go:694`-`733`. The production success response keys are `provider_id`, `receipt_pubkey`, `receipt_pubkey_prev`, and `fetched_at` at `phase4-coordinator/internal/buyer/server.go:647`-`657`, with `Cache-Control: public, max-age=300` at `phase4-coordinator/internal/buyer/server.go:728`-`730`. The integration mock uses the same success keys at `phase7-verify/integration_test.go:47`-`58` and writes the same cache header at `phase7-verify/integration_test.go:315`-`317`.

The only parity caveat is that the real handler can serialize `receipt_pubkey: null` for a legacy provider (`phase4-coordinator/internal/buyer/server.go:716`-`719`, covered at `phase4-coordinator/internal/buyer/receipt_keys_test.go:170`-`186`), while the verifier integration mock's `ReceiptKeysResponse.ReceiptPubkey` is a non-null string at `phase7-verify/integration_test.go:47`-`51`. This does not affect the Step 9 fixture matrix, whose verifier flows all use a keyed provider, but it means the integration mock does not exercise the real handler's legacy-null success shape.

#### INFO A3 - HIGH A1 handler parity is closed for Step 9 fixture behavior

Production handler behavior now has direct buyer tests for current key success, previous-key grace success, expired previous-key elision, unknown-provider 404, rate limiting, response whitelisting, and concurrent IP buckets at `phase4-coordinator/internal/buyer/receipt_keys_test.go:19`-`302`. The integration mock's 200 and 404 paths match the fixture-relevant production outcomes (`phase7-verify/integration_test.go:285`-`317`; `phase4-coordinator/internal/buyer/server.go:705`-`730`). Its 5xx path is a transient-failure simulation for resolver behavior; production `handleReceiptKeys` has no authored 5xx branch, but process/proxy/server failures are still a valid live-unreachable class for verifier testing.

The forward-compat hygiene is acceptable: the CLI and verifier implementation notes both say `bundle_pubkey_provider_mismatch` is reserved/forward-compatible for a future spec revision at `phase7-verify/internal/cli/implementation-notes.md:48`-`52` and `phase7-verify/internal/verify/implementation-notes.md:43`-`47`; the verifier notes also document the `provider_id_unresolvable` warning to `pubkey_unresolvable` top-level mapping at `phase7-verify/internal/verify/implementation-notes.md:61`-`66`. A future v0.3+ top-level `provider_id_unresolvable` reason would need the expected spec/schema bump, which is the right compatibility pattern.

**Architect lens verdict: READY TO LOCK.** Residual risk: mock/handler parity is sufficient for keyed Step 9 fixtures, with a low-severity gap around legacy-null current-key success payloads.

### Verification evidence

- `cd phase7-verify && go vet ./...` -> pass.
- `cd phase7-verify && go test ./... -race -count=1 -v` -> pass across the full phase7 package set.
- `cd phase7-verify && go test -tags=integration -count=1 -timeout 120s ./...` -> pass; package output included root plus `cmd/macprovider-verify`, `internal/cache`, `internal/canon`, `internal/cli`, `internal/jcs`, `internal/receipt`, `internal/resolver`, `internal/verify`, and `internal/version`.
- `cd phase7-verify && go test -tags=integration -v -run TestValidPreviousKeyInGraceAcceptsCurrentAndPreviousCacheOffline -count=1 -timeout 60s .` -> pass.
- `cd phase4-coordinator && go test ./internal/buyer/... -count=1` -> pass now (`ok github.com/augstar/macprovider-coordinator/internal/buyer 1.787s`), but see MEDIUM C4 for the fixed-date expiry.
- `cd phase7-verify && go build -o /tmp/macprovider-verify-r2 ./cmd/macprovider-verify` -> pass.
- `/tmp/macprovider-verify-r2 --version` -> `macprovider-verify 0.1.0-step1-scaffold`.
- `test -z "$(git diff impl/spec-015-v0-2-step-08 -- phase7-verify/go.sum)"` and `git diff --exit-code impl/spec-015-v0-2-step-08 -- phase7-verify/go.sum` -> pass; `go.sum` unchanged.
- `ls phase7-verify/testdata/*.bundle.json | wc -l` -> `11`.
- `grep -n "bundlePubkeyProviderMismatch\|bundle_pubkey_provider_mismatch" phase7-verify/internal/cli/cli.go phase7-verify/internal/verify/verify.go phase7-verify/schemas/output.schema.json` -> only `verify.go:33` and `output.schema.json:108`; no CLI preflight symbol/call.
- `grep -n "provider_id_unresolvable" phase7-verify/schemas/output.schema.json phase7-verify/internal/verify/verify.go` -> warning enum entries plus `verify.go` internal constant/mapping only; no top-level inconclusive schema enum entry.
- `git diff --check impl/spec-015-v0-2-step-08..HEAD` -> pass.

### Overall verdict

NOT READY - 0 CRITICAL, 0 HIGH, 1 MEDIUM, 1 LOW, 4 INFO. The round-1 functional blockers are closed, but the new coordinator receipt-key test has a deterministic near-term wall-clock failure, so the target `READY TO LOCK` condition is not met.
