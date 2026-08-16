# BUILD_SPEC_015_v0_3_MODELHASH_IMPL — model-hash binding implementation (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing any code.**

Your job is to implement SPEC-015 v0.3.x (`specs/SPEC-015-receipts.md`, LOCKED — confirm by checking line 3 says `0.3.x` and lock state says all three lenses returned READY TO LOCK). The v0.3 contract extends the 7-field v0.1/v0.2 receipt tuple to 9 fields by adding `model_hash` and `receipt_version`, defines a catalog-based verifier extension, and adds a SPEC-002 v1.6 candidate `/poolz` catalog surface.

This work is downstream of:
- SPEC-015 v0.1.3 (issuance, PR [#123](https://github.com/Augustas11/macprovider/pull/123)) — LANDED on `main` as commit `e95c365`.
- SPEC-015 v0.2.4 (verify CLI, PR [#124](https://github.com/Augustas11/macprovider/pull/124)) — LANDED on `main` as commit `99d0c1e`. `phase7-verify/` Go module is in place.
- SPEC-015 v0.2 nginx proxy (PR [#129](https://github.com/Augustas11/macprovider/pull/129)) — LANDED on `main` as commit `08dbece`. Coordinator nginx forwards `/v1/receipt-keys/`.
- SPEC-011 v0.5 catalog signing infrastructure — LIVE in production. Pearl coordinator runs observation mode against catalog `macprovider-tier2-model-catalog-2026-05-31` (342+ `model_hash_verified` events in last 7 days as of 2026-06-24).

Confirm by:
- `git log --oneline | grep -E "SPEC-015"` shows the three v0.1/v0.2 PRs.
- `ls phase7-verify/cmd/macprovider-verify/main.go` exists.
- `head -3 specs/SPEC-015-receipts.md` shows `**Version:** 0.3.x` with LOCKED status.
- `head -8 specs/SPEC-011-operator-pushed-warm-swap.md` shows v0.5 LOCK or v0.5 LOCK-candidate.

If SPEC-015 v0.3 has NOT locked yet (`Lock state v0.3:` still says "audit pending"), STOP. v0.3 IMPL does not begin until v0.3 SPEC is the locked contract.

## What you are building

Three coordinated code surfaces, in order of dependency:

1. **Swift provider receipt issuance extension** (`phase3-binary/`) — emit 9-field v0.3 receipts. Read `model_hash` from the binary's local SPEC-011 hash-tracking state. Add `receipt_version: "3"`. JCS canonicalization extends mechanically (UTF-16 key-order emitter picks up the two new keys; `RFC8785JCS.swift` requires no amendment per SPEC-015 §M.1.5). Wire envelope unchanged (still `<base64(JCS(T))>.<base64(SIG)>` in the `X-MacProvider-Receipt` header).

2. **Coordinator `/poolz` extension + two new endpoints** (`phase4-coordinator/`) — three new top-level `/poolz` fields (`catalog_id`, `catalog_url`, `catalog_pubkey_url`) and two new public endpoints (`GET /catalog/<catalog_id>`, `GET /catalog/pubkey`). Per SPEC-015 §M.4 + the SPEC-002 v1.6 candidate annotation. Reuse existing `tier2.ParsedCatalog` state + catalog-signing-key plumbing.

3. **Verifier extension** (`phase7-verify/`) — five new CLI flags (`--catalog`, `--catalog-url`, `--catalog-pubkey`, `--catalog-pubkey-url`, `--require-model-hash` per §M.3.1.2), pure-Go catalog parser + signature check, the 8-step verification algorithm per §M.3.2, cache layer per §M.3.4, new JSON output fields per §M.3.2.1 schema amendment (`model_hash_verified` tri-state, extended `reason` enum, extended `details` disposition, extended `warnings[]` enum), back-compat path for v0.1/v0.2 receipts per §M.1.1, forward-compat path for unknown `receipt_version` per §M.1.4.

Every MUST/MUST NOT/SHOULD in SPEC-015 §M and the v0.3 deltas to §3.1, §3.4, §7.6, §10.4, §10.6, §11 is binding here. AC-28 through AC-42 in §M.5 are the deterministic acceptance gate.

## Repo conventions you MUST honour

1. **House style.** Existing Swift patterns live in `phase3-binary/Sources/macprovider-cli/`; existing Go patterns in `phase4-coordinator/internal/` and `phase5-gateway/internal/`; verifier module conventions in `phase7-verify/internal/` (Step-by-step structure shipped via PR [#124](https://github.com/Augustas11/macprovider/pull/124)).
2. **No locked-spec edits beyond named candidate annotations.** v0.3 IMPL absorbs exactly one SPEC-002 v1.6 candidate (the `/poolz` catalog fields + `GET /catalog/...` endpoints). ANY other edit to SPEC-001 / 002 / 005 / 006 / 008 / 010 / 011 / 013 / 015 text is OUT OF SCOPE and a critical violation. If you find yourself needing to change a locked spec, STOP and surface the issue.
3. **`phase7-verify/` pure-stdlib discipline preserved.** v0.2 shipped `phase7-verify/` with zero third-party imports. v0.3 MUST preserve this. The catalog parser is hand-written from `scripts/sign-catalog.go` + `phase4-coordinator/internal/tier2/catalog.go` as references; do NOT import the coordinator's `tier2` package into the verifier.
4. **Audit-loop discipline (NON-NEGOTIABLE, per `feedback-build-audit-loop` memory):** after each numbered Step below, author `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_N_PROMPT.md`, fire it at codex via `omc ask codex "$(cat /path/to/prompt)"`, fix the findings, re-audit with `R<n+1>_PROMPT.md` if needed, loop until **0 CRITICAL, 0 MAJOR** for that step. Only then proceed to Step N+1. Existing pattern: SPEC-015 v0.1 IMPL ran ~11 audit rounds, v0.2 IMPL ran 10 — v0.3 is smaller surface (~5-7 steps) but the model-hash binding is security-critical; expect comparable audit density per step.
5. **Branching.** Create `impl/spec-015-v0-3-step-NN` branches off `main` per logical PR group (see §"PR grouping" below). Do NOT develop on local `main`. Follow `CLAUDE.md` PR workflow: feature branch → IMPL audit loop on branch → push → PR → squash-merge → `git reset --hard origin/main` locally.
6. **PR grouping per `feedback-bundle-spec-impl-one-pr` exception rule.** v0.3 SPEC ships standalone (already merged as a separate PR — confirm by `git log --grep="SPEC-015 v0.3 spec"`). IMPL ships in ITS OWN PR per the major-version-bump-with-downstream-implementer exception. Steps may land as several PRs (Swift / coordinator / verifier) merged in dependency order.
7. **AC-28 through AC-42 (SPEC-015 §M.5) are the acceptance gate.** Every AC must have a mechanically-runnable test by the time the implementation is ready for the Step-6 integration acceptance run.
8. **`implementation-notes-spec-015-v0-3.md`** per worktree as the v0.1/v0.2 IMPL did. Track design decisions where the spec was ambiguous, deviations (there should be none), tradeoffs, open questions.
9. **No silent capability degradation.** If a step uncovers that an AC is not satisfiable as written, STOP and surface the gap. Do NOT relax the AC; either fix the implementation or escalate back to a SPEC-015 v0.3.x+1 spec revision.
10. **Wire-shape parity test (MANDATORY, security-critical).** Step 1 + Step 5 MUST share a golden-fixture corpus that proves byte-identical canonical encoding of the 9-field tuple across the Swift signer and the Go verifier. The v0.2 IMPL set the precedent (Swift↔Go JCS parity test corpus); v0.3 extends it.

## Files you should read before writing code

1. `specs/SPEC-015-receipts.md` v0.3.x LOCKED — particularly §M (all six subsections), §3.1 v0.3 pointer, §3.4 v0.3 wire-size update, §7.6 v0.3 error-receipt rule (via §M.2 inheritance), §10.4 + §10.4.2 + §10.4.4 + §10.6 verifier updates, §11 `receipt_omitted` enum update, §15 Q6 + Q7, §16.2 v0.3 references. The change log v0.3.0 block is the index.
2. `specs/SPEC-015-v0-3-audit.md` — the v0.3 SPEC audit history (3-5 rounds). Round-1 findings explain WHY the v0.3 design is shaped the way it is. Read these to avoid re-introducing patterns the audit closed.
3. `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 — §3.2 warm-swap state machine, §3.3 heartbeat extension (R-3.3.0 opt-in gating, R-3.3.1 raw 64-hex format), §3.4 drain semantics. The §M.2 provenance rules rest on these.
4. `specs/SPEC-008-tier2.md` v0.3 — §5.3-5.6 Pillar A model-hash semantics. The verifier's catalog-check path is a buyer-side mirror of the coordinator-side check.
5. `scripts/sign-catalog.go` — the catalog signing tool. Step 5 verifier MUST consume what this tool produces, byte-for-byte. Particularly: `sha256` field name (line 31), canonical body key order `catalog_id, expires_at, issued_at, models, version` (line 42-49), `base64.RawURLEncoding` for the signature (line 145).
6. `phase4-coordinator/internal/tier2/catalog.go` — the in-coordinator catalog parser/verifier. Step 5 verifier reimplements this in pure Go in `phase7-verify/internal/catalog/`. Do NOT import the coordinator's tier2 package.
7. `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` — the in-house Swift JCS implementation. Step 1 confirms no amendments are needed (per SPEC-015 §M.1.5) and adds parity test fixtures.
8. `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift` — the v0.1/v0.2 signing-side reference. Step 1 extends this to construct the 9-field tuple.
9. `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (lines 294-325 hash computation) — the source of truth for `model_hash` provenance per §M.2.1. Step 1 reads from this surface.
10. `phase4-coordinator/internal/config/config.go` lines 142, 335 — `Tier2Config.RequireHashVerified` default false; verify Step 2 / Step 3 do NOT change this default.
11. `phase4-coordinator/internal/pool/provider.go` lines 420-432 — current heartbeat hash-handling code. Step 2 reuses this state for the `/poolz` catalog field exposure.
12. `phase7-verify/` Go module from v0.2 — particularly `internal/jcs/`, `internal/canon/`, `internal/receipt/`, `internal/resolver/`. Step 5 adds `internal/catalog/`, `internal/cache/catalog/` and extends `internal/cli/` + `internal/verify/`.
13. `beta/DECISION_CRITERIA.md` Entry 80 (2026-06-22) — operator ruling on `RequireHashVerified` deferral. v0.3 IMPL MUST preserve this unchanged.
14. `CLAUDE.md` (this repo) — PR workflow, git identity routing, dirty-main restoration steps.

## Dependencies (HARD constraint)

- **`phase7-verify/` stays pure stdlib.** No third-party imports. New code uses `crypto/ed25519`, `crypto/sha256`, `encoding/base64`, `encoding/json`, `net/http`, `os`, `flag`, `time`. Catalog parser is hand-written (~150 lines) per Step 5.
- **No cgo.** Cross-compile cleanly for `darwin/arm64`, `darwin/amd64`, `linux/amd64`.
- **`phase3-binary/` Swift module** continues to use the existing `swift-crypto` + `CryptoKit` set. No new third-party dependencies.
- **`phase4-coordinator/` Go module** reuses existing `internal/tier2` package state. No new third-party dependencies beyond what's already vendored.

## Step decomposition (6 steps)

Each step lands on its own `impl/spec-015-v0-3-step-NN` branch. Each step goes through the audit loop before the next step starts. Steps 1-3 are Swift+Coordinator (independent); Step 4-5 are verifier (depend on Step 1's wire shape being finalized). Step 6 is integration acceptance.

### Step 0 — Pre-flight checks + tracking-issue setup

**Branch:** `impl/spec-015-v0-3-step-00` (or just a tracking issue, no code)

**What lands:** No code. This step is a checklist confirmation.

**Verify:**
1. SPEC-015 v0.3.x is on `main` (`git log --oneline main | grep "SPEC-015 v0.3"` returns the spec-only PR).
2. SPEC-015 v0.3.x is LOCKED (line 3 says LOCKED, lock state says all three lenses passed).
3. `phase7-verify/` builds clean (`cd phase7-verify && go build ./...`).
4. `phase3-binary/` builds clean (`cd phase3-binary && swift build`).
5. `phase4-coordinator/` builds clean and tests pass (`cd phase4-coordinator && go test ./...`).
6. Pearl production coordinator is at a known version (`curl -s https://coordinator.malibu.tech/healthz` returns `version` field).
7. No SPEC-001 / 002 / 005 / 006 / 008 / 010 / 011 / 013 line-3 versions have shifted since v0.3 SPEC lock (`git diff main -- specs/SPEC-{001,002,005,006,008,010,011,013}-*.md` shows no line-3 changes).

**Tracking issue:** open one GitHub issue titled "SPEC-015 v0.3 IMPL — model-hash binding" listing Steps 1-6 as a checklist. Update as each step lands.

**Audit prompt:** NONE for Step 0. Pre-flight only.

**Done when:** all checks above pass.

---

### Step 1 — Swift provider: 9-field receipt tuple emission

**Branch:** `impl/spec-015-v0-3-step-01`  
**Module:** `phase3-binary/`  
**SPEC reference:** §M.0, §M.1.5, §M.2.1, §M.2.2, §M.2.3, §3.1, §3.4

**What lands:**

1. `ReceiptBuilder.swift` extended to construct the 9-field tuple per §M.0 with JCS canonical order: `model_hash`, `model_id`, `output_hash`, `prompt_hash`, `provider_pubkey`, `receipt_version`, `tokens_out`, `ttft_ms`, `unix_ts`.
2. `receipt_version: "3"` is a constant string literal in the builder; do NOT thread through a version parameter (v0.3 is the only version this binary emits).
3. `model_hash` provenance:
   - Read from the binary's local SPEC-011 hash-tracking state per §M.2.1. The state machine in `ModelRuntime.swift` (or wherever the binary's `--enable-warm-swap=true` path tracks the loaded container's SHA-256) is the source.
   - If `--enable-warm-swap=false` (the SPEC-011 R-3.1.0 default): the binary has no SPEC-011 state → emit the literal JSON null per §M.2.3. The `model_hash` field in the constructed tuple is a Swift optional `String?`; nil maps to JSON null via `RFC8785JCS.swift`'s null-handling path.
   - The atomic-read invariant: `model_hash` MUST reflect the container that started this request's generation per §M.2.2 — i.e. the runtime captures the hash at request-acceptance time and uses that value at receipt-emission time, even if the global runtime state has moved to a new hash mid-response.
4. `RFC8785JCS.swift` does NOT need amendment per §M.1.5. Add a parity test that asserts: given a fixture 9-field tuple (with model_hash as 64-hex AND as null in two separate cases), the canonical bytes match a golden file `phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/`. Both `null` and non-null model_hash MUST produce stable bytes.
5. `receipt_omitted: model_swap_violation` enforcement per §M.2.2: at receipt-emission time, the runtime queries the swap state. If `loading` or `draining` (SPEC-011 §3.2), AND the runtime cannot disambiguate which container served (per §M.2.2's defence-in-depth clause; under SPEC-011 R-3.4.1 + R-3.2.2, this case is unreachable by construction, but the check is still mandatory), the receipt-emission code refuses with a structured audit log row `{event: "receipt_omitted", reason: "model_swap_violation", request_id, provider_id}` and the response goes out without an `X-MacProvider-Receipt` header. Wire emission is otherwise unchanged.
6. The SPEC-011 R-3.3.1 raw 64-char lowercase hex format MUST be preserved (no `sha256:` prefix). If the binary's internal state stores hashes with a prefix or in any other form, convert at the receipt-emission boundary.

**Tests (XCTest, table-driven where possible):**
- 9-field tuple canonicalization parity test (vs. golden fixtures).
- `model_hash` = null when `--enable-warm-swap=false`.
- `model_hash` = 64-hex when `--enable-warm-swap=true`.
- `receipt_version` is exactly `"3"`.
- Receipt size ≤ 960 bytes (§3.4 v0.3 update).
- Error-receipt (SPEC-001 §6.0 path; AC-12 / v0.3 AC-31) carries the same `model_hash` value a successful receipt would.
- Mid-swap refusal: simulated `loading` state at receipt-emission produces `receipt_omitted` audit row and NO header.
- v0.1.3 / v0.2 wire shape is NOT regressed for backward-tests (this binary now emits v0.3 only, but the canonicalization step must STILL produce v0.1/v0.2-compatible bytes for an isolated 7-field tuple — this is the §M.1.5 "RFC8785JCS unchanged" sanity check).

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_1_PROMPT.md` — fire at codex. Findings to expect: `model_hash` provenance ambiguity under edge cases (swap-in-progress at request-acceptance vs. at receipt-emission), null-encoding parity test coverage, audit-log row schema completeness.

**Done when:** 0 CRITICAL / 0 MAJOR on the IMPL audit AND `swift test` passes including the new parity fixtures AND a hand-curl against a locally-running v0.3 binary returns a 9-key receipt that decodes cleanly.

---

### Step 2 — Coordinator: SPEC-002 v1.6 candidate `/poolz` catalog fields

**Branch:** `impl/spec-015-v0-3-step-02`  
**Module:** `phase4-coordinator/`  
**SPEC reference:** §M.4

**What lands:**

1. `/poolz` JSON response extended with three new optional top-level fields (`catalog_id`, `catalog_url`, `catalog_pubkey_url`) per §M.4. Present iff `Tier2Config.CatalogPath` is set AND the catalog loaded cleanly AND the verifier-side signature check passed (i.e. `tier2.Default().Active()` returns true).
2. The new fields are computed once at handler-time from:
   - `tier2.Default().CatalogID()` for `catalog_id`.
   - A new config field `Tier2Config.PublicCatalogBaseURL` (string, optional, default empty) — when set, the coordinator builds `catalog_url = PublicCatalogBaseURL + "/catalog/" + catalog_id` and `catalog_pubkey_url = PublicCatalogBaseURL + "/catalog/pubkey"`. When the config field is empty, the handler computes them from the request's `Host` header IF the request came via a buyer-port surface — i.e. the URLs are absolute and resolvable by the buyer.
   - The handler MUST NOT emit `catalog_url` / `catalog_pubkey_url` if it cannot construct absolute URLs (no `PublicCatalogBaseURL` + no usable `Host`). In that degraded case it emits `catalog_id` only — a verifier with `--catalog` (file path) but missing `--catalog-url` still works; the `/poolz` field set is best-effort.
3. New endpoint `GET /catalog/<catalog_id>` on the buyer-port mux (alongside `/v1/receipt-keys/<provider_id>` from v0.2 §10.7):
   - Public, unauthenticated.
   - Returns the signed catalog file bytes verbatim (the literal bytes of `Tier2Config.CatalogPath` on disk).
   - `Content-Type: application/json`, `Cache-Control: public, max-age=300`.
   - 404 with `error.code = "catalog_not_found"` envelope if the `<catalog_id>` path segment doesn't match `tier2.Default().CatalogID()` OR if no catalog is configured.
   - Rate-limited per-IP: 10 req/sec; over-quota → 429.
4. New endpoint `GET /catalog/pubkey` on the buyer-port mux:
   - Public, unauthenticated.
   - Returns `{"pubkey": "<43-char base64url-unpadded>", "alg": "Ed25519"}` (plus optional `key_id`). The pubkey value MUST use `base64.RawURLEncoding` (NOT standard padded base64) and the alg value MUST be capital-E `"Ed25519"` — matching `scripts/sign-catalog.go:90,142-145` and SPEC-008 §5.2.1.
   - The pubkey value comes from `Tier2Config.CatalogPublicKey` (configured at coordinator startup; it's the same key the coordinator uses to verify the loaded catalog).
   - `Content-Type: application/json`, `Cache-Control: public, max-age=300`.
   - 404 if no catalog is configured. Rate-limited same as above.

**Tests (table-driven):**
- `/poolz` includes the three fields when catalog is configured and active.
- `/poolz` omits the three fields when catalog is not configured.
- `/poolz` omits the three fields when configured catalog failed to load.
- `GET /catalog/<id>` returns the on-disk bytes for the active catalog.
- `GET /catalog/<wrong-id>` returns 404 with the right envelope.
- `GET /catalog/pubkey` returns the base64 pubkey.
- `GET /catalog/pubkey` returns 404 with no catalog.
- Rate limit fires at 11 req/sec.
- `/poolz` does NOT leak any new operator-sensitive field (regression test of the v0.2 redaction discipline).
- `/poolz` operator-only authentication is unchanged; the three new fields are buyer-visible but the rest of `/poolz` remains operator-only per SPEC-002 v1.4 §FR-O2.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_2_PROMPT.md` — fire at codex. Findings to expect: URL construction edge cases (X-Forwarded-Host, IPv6 hosts), 404 envelope completeness, `PublicCatalogBaseURL` config-field naming, cache header semantics.

**Done when:** 0 CRITICAL / 0 MAJOR on the IMPL audit AND `go test ./internal/buyer/... ./internal/tier2/...` passes AND a local curl against `/poolz`, `/catalog/<id>`, `/catalog/pubkey` returns the right shapes.

---

### Step 3 — Coordinator: nginx config + Pearl deploy gates

**Branch:** `impl/spec-015-v0-3-step-03`  
**Module:** `phase4-coordinator/dist/` + deploy scripts  
**SPEC reference:** §M.4

**What lands:**

1. `phase4-coordinator/dist/nginx-coordinator.conf` (or wherever the Pearl coordinator nginx conf lives) extended to proxy `/catalog/<id>` and `/catalog/pubkey` to the buyer port (NOT the operator port). Mirror the existing `/v1/receipt-keys/` route shape from PR #129.
2. `check-deploy-config.sh` extended to assert the new nginx routes exist before Pearl deploy (the C2 gate pattern from M1-6).
3. `Tier2Config.PublicCatalogBaseURL` config field added to `coordinator.yaml.example` with a Pearl-appropriate default `https://coordinator.malibu.tech`.
4. NO change to `Tier2Config.RequireHashVerified` default (preserves Entry 80).

**Tests:**
- `nginx -t` clean against the updated conf.
- `check-deploy-config.sh` exits 0 on a config that has the new routes; exits non-zero on one that doesn't.
- Smoke test against Pearl prod is OPERATOR-PENDING — Pearl deploy is operator-driven post-merge.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_3_PROMPT.md` — fire at codex. Findings to expect: nginx route ordering, conflict with existing `/catalog` routes (probably none), `check-deploy-config.sh` integration.

**Done when:** 0 CRITICAL / 0 MAJOR on the IMPL audit AND `nginx -t` against the updated conf is clean.

---

### Step 4 — Verifier: catalog parser + signature check (pure Go)

**Branch:** `impl/spec-015-v0-3-step-04`  
**Module:** `phase7-verify/internal/catalog/`  
**SPEC reference:** §M.3.2 steps 3-4, §M.3.4

**What lands:**

1. New package `phase7-verify/internal/catalog/`:
   - `Parse(bytes []byte) (*Catalog, error)` — strict JSON parsing per the `catalogFile` schema in `phase4-coordinator/internal/tier2/catalog.go:64`. Reject on missing required fields, wrong types, malformed RFC3339 timestamps, `sha256` not matching `^[0-9a-f]{64}$`.
   - `Verify(c *Catalog, pubkey ed25519.PublicKey) error` — reconstructs the canonical body (the `catalogFile` minus the `signature` field, in the exact key order `catalog_id, expires_at, issued_at, models, version` per `scripts/sign-catalog.go:42-49`), decodes `signature.sig` via `base64.RawURLEncoding`, and runs `ed25519.Verify`. Returns the `model_hash_mismatch` / `catalog_signature_invalid` / `catalog_expired` enum values via typed errors.
   - `Lookup(c *Catalog, modelID string) (sha256 string, ok bool)` — match per §M.3.2 step 6: apply the `catalogModelKey` transform `strings.ToLower(strings.TrimSpace(modelID))` (mirroring `phase4-coordinator/internal/tier2/catalog.go:559-560`) before lookup. Buyer-side AND coordinator-side MUST share this match function.
2. New package `phase7-verify/internal/cache/catalog/`:
   - Three-band TTL per §M.3.4: > 6h → 6h; in (60s, 6h) → `expires_at - now() - 60s`; < 60s → no cache.
   - Cache location `~/.macprovider/verify/catalogs/<sha256(catalog_url)>.json`.
   - Cache entry shape `{catalog_bytes, catalog_pubkey_b64, fetched_at, expires_at, catalog_url}`.
   - Cache-miss-on-rotation: if cached `catalog_pubkey_b64` differs from a freshly-resolved pubkey, treat as miss.
   - Stale entries (TTL exceeded) MUST NOT be served as `valid`; the cache returns "miss" and the verifier re-fetches.
3. Hand-translation of the catalog parsing rules from `phase4-coordinator/internal/tier2/catalog.go` (DO NOT import). The two implementations should produce identical accept/reject decisions on every input.
4. Reuse the existing `phase7-verify/internal/jcs/` package for canonical-body reconstruction (the catalog canonical body is JCS-able JSON with the named key order).

**Tests (table-driven):**
- Parse valid catalog → no error, fields populated.
- Parse invalid catalog (each schema violation enumerated) → typed error.
- Verify valid signature → no error.
- Verify with `signature.alg != "Ed25519"` (capital E required per §M.3.2 step 4 + AC-35) → typed error. Tampered alg values (`"ed25519"` lowercase, `""`, `"ECDSA"`) all rejected.
- Verify with tampered signature → typed error.
- Verify with tampered body → typed error.
- Lookup matched model → returns `sha256`.
- Lookup unknown model → returns `(_, false)`.
- Cache TTL bands: each band tested with controlled clock.
- Cache miss on pubkey rotation.
- Cache miss on stale entry.
- Parity test: feed `scripts/sign-catalog.go` 10 randomized catalogs, the verifier accepts every one.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_4_PROMPT.md` — fire at codex. Findings to expect: canonical-body byte-order divergence (vs. `sign-catalog.go`), base64 encoding subtleties (RawURLEncoding vs. StdEncoding), expires_at edge cases (60s grace boundary).

**Done when:** 0 CRITICAL / 0 MAJOR on the IMPL audit AND `go test ./internal/catalog/... ./internal/cache/catalog/...` passes.

---

### Step 5 — Verifier: CLI flag extension + verification algorithm

**Branch:** `impl/spec-015-v0-3-step-05`  
**Module:** `phase7-verify/internal/cli/`, `phase7-verify/internal/receipt/`, `phase7-verify/internal/verify/`  
**SPEC reference:** §M.0, §M.1.1, §M.1.2, §M.1.3, §M.1.4, §M.3.1, §M.3.2, §M.3.3

**What lands:**

1. `internal/receipt/` extended: parser detects receipt version by presence of `receipt_version` field per §M.0 + §M.1.1 + §M.1.4. Returns a tagged-union (`LegacyReceipt7` for v0.1/v0.2 shape; `V03Receipt9` for v0.3 shape; `UnknownVersionReceipt` for forward-compat). Strict shape validation per version.
2. `internal/verify/` extended: dispatches to legacy 7-field path or v0.3 9-field path based on the tagged union. Both paths share the §3.2 JCS canonicalization (reuse existing `internal/jcs/`).
3. `internal/cli/` extended with FIVE new flags per §M.3.1 + §M.3.1.2:
   - `--catalog <path>` (mutually exclusive with `--catalog-url`)
   - `--catalog-url <url>` (mutually exclusive with `--catalog`; incompatible with `--offline`)
   - `--catalog-pubkey <base64url>` (mutually exclusive with `--catalog-pubkey-url`; value is `base64.RawURLEncoding` base64url-unpadded, exactly 43 ASCII chars — NOT standard padded base64)
   - `--catalog-pubkey-url <url>` (mutually exclusive with `--catalog-pubkey`; incompatible with `--offline`)
   - `--require-model-hash` (boolean per §M.3.1.2; fail-closed on `model_hash: null` with `reason: "model_hash_required"`)
4. Flag-combination matrix per §M.3.1.1 (the normative v0.3 table extending §10.4.4): catalog without pubkey (or vice versa) → exit 64; both -path and -url variants of either flag → exit 64; `--catalog-url` or `--catalog-pubkey-url` with `--offline` → exit 64. Implement the full §M.3.1.1 table as a single CLI validator.
5. Result-schema per §M.3.2.1 (the normative v0.3 schema amendment extending §10.4.2):
   - `model_hash_verified` (REQUIRED, tri-state: `true` | `false` | `null`). Present in EVERY JSON output. `true` ⇔ catalog check ran AND matched; `false` ⇔ catalog check ran AND mismatched (result is `invalid`) OR `--require-model-hash` set with null hash (`reason: "model_hash_required"`); `null` ⇔ catalog check did not run.
   - `reason` enum extended per §M.3.2.1: `model_hash_mismatch`, `model_hash_required`, `model_id_not_in_catalog`, `catalog_signature_invalid`, `catalog_unreachable`, `catalog_expired`, `catalog_format_invalid`, `unknown_receipt_version`, `extra_field`, `missing_field`.
   - `details` REQUIRED for the v0.3-named inconclusive cases per §M.3.2.1's `details` disposition table (e.g. `model_id_not_in_catalog` carries `details.model_id`; `unknown_receipt_version` carries `details.receipt_version`; `catalog_expired` carries `details.catalog_id` + `details.expires_at`).
   - `warnings[]` enum extended: `catalog_skipped_null_hash`, `catalog_skipped_legacy_receipt`.
6. The 8-step §M.3.2 algorithm implemented as a single deterministic function. Step ordering: resolve catalog → resolve pubkey → parse → verify signature → check expiry → lookup model_id → compare hashes → emit verdict. Short-circuit at each failure with the right `result + reason`.
7. Trust-boundary disclosure per §M.3.3 / §10.6 v0.3 update: `--explain` output for `valid` results discloses which catalog was used (catalog_id, expires_at, source URL or path) and that `valid` now attests model-hash binding subject to the catalog-pubkey trust root.
8. Back-compat path per §M.1.1: v0.1/v0.2 receipts (no `receipt_version`) verify exactly as a v0.2.4 verifier would, with `catalog_skipped_legacy_receipt` warning if `--catalog` was supplied.
9. Forward-compat path per §M.1.4: unknown `receipt_version` → `inconclusive: unknown_receipt_version`, exit 2, `details.receipt_version` populated.
10. Cache integration per Step 4's `internal/cache/catalog/`.

**Tests (golden fixtures + table-driven):**
- Every AC-28..AC-42 (§M.5) has a fixture and an assertion. AC-32a (`--require-model-hash` fail-closed on null hash) is in scope.
- AC-32: null-hash v0.3 receipt + catalog → valid + warning (default posture, `--require-model-hash` NOT set).
- AC-32a: same fixture + `--require-model-hash` → invalid + `model_hash_required`.
- AC-33: hash mismatch → invalid + `model_hash_mismatch`.
- AC-34: unknown model_id → inconclusive + `model_id_not_in_catalog`.
- AC-35: bad catalog signature → invalid + `catalog_signature_invalid`.
- AC-36: expired catalog → inconclusive + `catalog_expired`.
- AC-37: v0.2 receipt under v0.3 verifier + catalog → valid + `catalog_skipped_legacy_receipt`.
- AC-38: cross-binary test against `phase7-verify-v0.2.4` (a checked-in binary from a prior release): v0.3 receipt → invalid.
- AC-41: cache TTL bands.
- AC-42: mid-swap refusal is verifier-side-NA (the provider refused emission; the verifier never sees a swap-spanning receipt). Sanity-check by feeding a swap-violating fixture (a hand-constructed receipt asserting a hash that was never loaded) → invalid via signature or hash-mismatch path.
- Flag combination matrix: each invalid combination returns 64.
- Output schema: every result includes `model_hash_verified` (null when no catalog ran, bool when catalog ran).
- JSON-schema validation: extend the v0.2 JSON schema with the new fields; every fixture's output validates.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_5_PROMPT.md` — fire at codex. Findings to expect: version-detection edge cases (a 7-field receipt with one field named `receipt_version`), flag-matrix combinatorial gaps, `model_hash_verified` null-vs-absent ambiguity, back-compat regressions.

**Done when:** 0 CRITICAL / 0 MAJOR on the IMPL audit AND `go test ./...` in `phase7-verify/` passes including every AC fixture AND `macprovider-verify --help` shows the five new flags (`--catalog`, `--catalog-url`, `--catalog-pubkey`, `--catalog-pubkey-url`, `--require-model-hash`).

---

### Step 6 — Integration acceptance + cross-binary parity

**Branch:** `impl/spec-015-v0-3-step-06`  
**Modules:** all of `phase3-binary/`, `phase4-coordinator/`, `phase7-verify/`  
**SPEC reference:** §M.5 (AC-28..AC-42)

**What lands:**

1. End-to-end test harness at `test/integration/spec015_v03/`:
   - Spin up a coordinator with a test catalog (`scripts/sign-catalog.go sign --in test/integration/spec015_v03/catalog.json --out test/integration/spec015_v03/catalog.signed.json --key test/integration/spec015_v03/catalog-priv.b64`).
   - Connect a v0.3 binary (one with `--enable-warm-swap=true`, one without).
   - Issue a non-streaming chat completion, capture the receipt.
   - Run `macprovider-verify --bundle <captured>.json --catalog-url ... --catalog-pubkey-url ...`.
   - Assert AC-28..AC-42 outcomes.
2. Cross-binary parity test: build the v0.3 verifier AND a v0.2.4 verifier (checked-in binary or rebuilt from `v0.2.4` tag) and run both against the same v0.1/v0.2 receipts AND v0.3 receipts. Assert: v0.3 verifier accepts both shapes; v0.2.4 verifier accepts v0.1/v0.2 and rejects v0.3 (AC-38).
3. JCS canonical-bytes parity test (Swift signer ↔ Go verifier): the same 9-field tuple emitted by Swift MUST canonicalize to identical bytes when read by the Go verifier. Run on the test catalog's models.
4. Operator runbook in `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md` (or wherever the operator-followup docs live): Pearl deploy choreography, monitoring queries, rollback procedure.

**Tests:**
- Every AC-28..AC-42 fires green.
- Cross-binary parity green.
- JCS bytes parity green.
- A v0.3 binary in observation mode does NOT change `RequireHashVerified` behavior — the coordinator's routing decisions are byte-identical to pre-v0.3 (Entry 80 preservation).

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_6_PROMPT.md` — fire at codex. Findings to expect: integration-test reproducibility (timing-sensitive nodes), JCS parity test corpus completeness, runbook gaps.

**Done when:** 0 CRITICAL / 0 MAJOR on the IMPL audit AND every AC-28..AC-42 has a green test AND the operator runbook is ready to hand off.

---

## PR grouping

Per `feedback-bundle-spec-impl-one-pr` major-version-bump-with-downstream-implementer exception, v0.3 IMPL ships in its own PR(s) separate from the SPEC PR. Recommended grouping:

- **PR A** (Steps 1 + 2 + 3): Swift receipt extension + coordinator `/poolz` catalog fields + nginx config. Single PR keeps wire-shape coordination atomic.
- **PR B** (Steps 4 + 5): Verifier extension. Depends on PR A landing (need the wire shape stable for fixtures).
- **PR C** (Step 6): Integration acceptance. Depends on A and B.

OR if the audit-loop discipline produces blocking findings on Step 1: split Step 1 + Step 2-3 into separate PRs to unblock the coordinator side independently. Use your judgment.

## DECISION_CRITERIA entry on close

When all 6 steps land and the operator-pending Pearl deploy is queued, append a `beta/DECISION_CRITERIA.md` entry describing:

- What landed (6 steps, ~3 PRs, AC count cleared).
- The operator runbook reference and Pearl deploy ETA.
- Confirmation that Entry 80 `RequireHashVerified` deferral is preserved unchanged.
- Audit-round count across all 6 IMPL audits (the v0.1 IMPL averaged ~3 rounds/step; expect similar).
- Cross-references: SPEC-015 v0.3 LOCK entry, Entry 80, the BUILD prompt (this file).

## Quality bar

A great v0.3 IMPL leaves the system with:
- v0.3 receipts emitting cleanly from v0.3 providers, verifying cleanly with v0.3 verifiers, AND v0.1/v0.2 receipts still verifying cleanly under v0.3 verifiers (full back-compat preserved).
- The catalog-check path implementable by a third-party from §M.3 alone, with no need to read the coordinator's `tier2.go`.
- The Swift↔Go JCS parity test corpus extended to cover the 9-field tuple with both null and non-null `model_hash`, future-proofing v0.4+ work.
- Pearl production unchanged in routing behavior (Entry 80 preservation; observation mode still on; `RequireHashVerified` still off).

A bad v0.3 IMPL:
- Hand-waves `model_hash` provenance and ends up reading from the coordinator's heartbeat-derived state instead of the provider's local container state.
- Lets a malicious provider opt out of hash attestation undetectably (the null-hash path should be clearly *attested*, not silently *absent*).
- Embeds the verifier's catalog parser in the coordinator's `tier2` package, breaking the pure-stdlib discipline.
- Silently flips `RequireHashVerified` to `true` or changes the Entry 80 default.

## Final deliverables when you're done

1. Six merged PRs (or 3 grouped PRs) landing Steps 1-6 on `main`.
2. `beta/DECISION_CRITERIA.md` entry per above.
3. `audits/2026-XX-XX/SPEC_015_V03_OPERATOR_RUNBOOK.md` queued for Pearl deploy.
4. Tracking GitHub issue closed with checkmarks against Steps 0-6.
5. README.md line 22 + lines 113-137 updated to reflect that v0.3 closes the `model_hash` binding gap (the v0.1.3 README update from Entry 82 left this as a v0.3+ candidate; v0.3 IMPL is where the README catches up).

**You're not done when the code compiles. You're done when v0.3 SPEC ACs are deterministically green across the integration test, Pearl deploy is queued, and the operator handoff is documented.**
