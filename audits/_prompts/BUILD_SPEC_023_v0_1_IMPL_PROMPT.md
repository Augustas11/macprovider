# BUILD_SPEC_023_v0_1_IMPL_PROMPT — Installer-Integrated Autotune Recommend

You are starting a fresh implementation session in the macprovider repo. You have no memory of prior conversations. Read this prompt end-to-end before writing code.

## 0. Workspace And Authority

Before editing anything, verify:

```bash
pwd
git status -sb
git fetch origin
ls specs/SPEC-023-installer-autotune-recommend.md
```

Work on a feature branch or isolated worktree, never local `main`. If `specs/SPEC-023-installer-autotune-recommend.md` is not present at HEAD, STOP: the SPEC-023 LOCK has not landed in your implementation base.

Controlling contract:

- `specs/SPEC-023-installer-autotune-recommend.md` v0.1 LOCKED.
- Final SPEC audit record: `specs/SPEC-023-v0_1-r7-audit.md`, with code/security/architect all at 0 critical/high/medium/low.
- Repo rules: `AGENTS.md` and `CLAUDE.md`.

This prompt implements the locked SPEC. Do not re-litigate the product decisions. If the code reveals a true SPEC ambiguity, stop and surface it as a SPEC follow-up; do not silently change the contract in code.

Clean-room boundary: do not inspect Darkbloom / layr-labs `d-inference` source. SPEC-023 competitive framing already used public surfaces only.

## 1. Scope Summary

Implement SPEC-023 v0.1:

- A public, read-only coordinator `GET /v1/rate-card` recommendation projection on the buyer mux, reachable through production nginx.
- A Swift CLI recommendation path for `macprovider-cli autotune --recommend`, including JSON/human output, baked/live static inputs, deterministic scoring, stale-state persistence, and donor-mode local-only UX.
- Static JSON integrity and fallback for `demand-rank.json` and `autotune-candidates.json`.
- Deterministic hardware identity, bandwidth-tier assignment, model admission gates, and canonical model artifact hash verification.
- Installer/update/status hooks for prompting re-tune and surfacing stale/donor status.
- Focused tests proving every SPEC-023 acceptance criterion AC-1 through AC-39.

Out of scope:

- No coordinator `/v1/demand-signal` endpoint.
- No auto-switching models without operator action.
- No provider quota/coverage allocation policy. Do not query live provider counts for recommendation. Parse/store `min_provider_target` only for operator planning and future v0.2 migration.
- No gateway billing, coordinator settlement, ledger, request-log, or `RateCardEntry` YAML schema changes.
- No coordinator/gateway donor-routing or donor settlement behavior.
- No arbitrary local-model/custom donor-mode path override.
- No Darkbloom source inspection.

## 2. Mandatory Implementation Slices

Implement in the order below. Each slice must include targeted tests before moving on.

### Slice A — Coordinator Rate-Card Projection

Files likely touched:

- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/cmd/coordinator/main.go` only if construction needs option wiring
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `phase4-coordinator/internal/buyer/*_test.go`

Requirements:

1. Add unauthenticated `GET /v1/rate-card` on the coordinator buyer mux (`buyer_port: 8443`), not provider/operator mux (`provider_port: 8444`).
2. Return JSON:

```json
{
  "version": "string",
  "generated_at": "RFC3339 timestamp",
  "usd_per_million_credits": 1.0,
  "rows": {
    "<model_key>": {
      "prompt_rate_per_mtok": 0,
      "completion_rate_per_mtok": 0,
      "provider_share_bps": 9000,
      "global_multiplier_ppm": 1000000
    }
  }
}
```

3. Build the projection from existing loaded config/runtime values only: `Rewards.RateCard`, `Rewards.ProviderShare`, `Rewards.GlobalMultiplier`, and `stats.rollup.usd_per_million_credits`.
4. Do not alter billing, settlement, routing, provider state, request logs, `RateCardEntry`, YAML schema, ledger schema, or settlement arithmetic.
5. Compute `version` as SPEC §3.3 defines: SHA-256 over the canonical recommendation projection only, excluding quarantine/force-void, request-log, operator, ledger, and settlement runtime state.
6. Add an exact nginx `location = /v1/rate-card` before the existing generic `/v1/` 404 block, proxying to `http://127.0.0.1:8443/v1/rate-card$is_args$args` and forwarding `Host`, `X-Real-IP`, `X-Forwarded-For`, and `X-Forwarded-Proto`.
7. Tests:
   - Unauthenticated handler returns the schema.
   - Handler is wired on buyer mux, not provider/operator mux.
   - `version` changes when rows/provider share/global multiplier/USD conversion changes.
   - `version` does not change for unrelated quarantine/request-log/operator/settlement runtime state.
   - Nginx config contains exact allow-through before the `/v1/` 404 block.

### Slice B — Swift Static Inputs And Integrity

Files likely added/touched:

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend*.swift` new files, split by responsibility.
- `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift`
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommend*Tests.swift`

Requirements:

1. Add typed models for:
   - candidate catalog
   - demand rank
   - rate-card projection
   - recommendation JSON output
   - stored `last-recommendation.json`
2. Add baked snapshots compiled into the CLI release. The baked candidate catalog must include at least the SPEC §3.2 rows. Every non-`blocked` baked row must include immutable `model_revision` and canonical `model_sha256`.
3. Add a CLI rate-card input fetcher:
   - Fetch `https://coordinator.streamvc.live/v1/rate-card`.
   - Validate the §3.3 schema before use.
   - Fall back to the baked rate-card snapshot on timeout, non-2xx, malformed JSON, schema-validation failure, missing required fields, non-finite/negative values, or unavailable network.
   - Emit `rate_card_fallback_used` to JSON `warnings[]` and stderr when baked fallback is used.
   - Persist the selected `rate_card_version` in `last-recommendation.json`.
   - Tests must cover AC-5, including failed fetch and schema-validation failure.
4. Implement static fetch from `https://get.streamvc.live/{demand-rank,autotune-candidates}.json` plus `{name}.json.sig`.
5. Verify detached Ed25519 sidecar exactly:

```json
{
  "key_id": "streamvc-autotune-static-v1",
  "alg": "ed25519",
  "signature": "<base64>"
}
```

6. Use release-pinned public key `autotune_static_json_ed25519_v1` and key ID `streamvc-autotune-static-v1`.
7. Parse JSON only after signature verification succeeds.
8. Validate schemas before admitting fetched JSON:
   - `demand-rank.json`: locked `source`, `cold_start_floor = 0.15`, `diversification_band = 0.85`, RFC3339 `generated_at`, finite `[0,1]` `demand_weight`, positive or null rank, boolean `recommendable`, non-negative integer `min_provider_target`.
   - `autotune-candidates.json`: locked `source`, RFC3339 `generated_at`, required row fields, allowed `runtime_status`, allowed bandwidth tiers, non-negative gates, non-`blocked` rows carrying `model_revision` and `model_sha256`.
   - Schema-validation failure falls back to baked and emits `demand_rank_fallback_used` or `candidate_catalog_fallback_used`.
9. Reject fetched file and fall back to baked snapshot when sidecar is missing/malformed, key/alg wrong, signature invalid, schema invalid, `generated_at` older than baked, more than 10 minutes in the future, or more than 30 days old.
10. Emit `demand_rank_stale` or `candidate_catalog_stale` for valid fetched files 14-30 days old.
11. Compute `candidate_catalog_sha256` over exact selected catalog JSON bytes after fetched/baked selection and before parsing normalization.
12. Tests cover fallback and warning behavior for every §3.5 rejection/allow path and AC-4/AC-6 schema-validation failure.

### Slice C — Recommendation Engine

Files likely added/touched:

- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
- `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift`
- new recommendation engine files under `phase3-binary/Sources/macprovider-cli/`
- Swift tests under `phase3-binary/Tests/macprovider-cliTests/`

Requirements:

1. Add `macprovider-cli autotune --recommend` and `--json` behavior without breaking existing autotune benchmark flags.
2. Preserve current full benchmark/autotune behavior for existing invocations. If needed, implement recommendation as a distinct mode gated by `--recommend`.
3. Hardware:
   - Extend/derive `bandwidth_tier`, `diversification_id`, benchmark status, swap, thermal, and binary identity without weakening `MachineFingerprinter.sample()`.
   - HMAC local secret is per-install CSPRNG-generated, stored in Keychain or a `0600` local file, never emitted/logged/bundled/sent.
   - Use separate HMAC domain labels for diversification and cache identity.
   - Tier order is `S >= A >= B >= C`; implement the SPEC §3.1 chip mapping exactly.
4. Candidate gates:
   - Missing selected-catalog metadata makes row ineligible before download/benchmark.
   - `blocked` rows are never downloaded, benchmarked, recommended, or donor-committed.
   - Require immutable `model_revision` and canonical `model_sha256` for every downloadable row.
   - Download by immutable revision, not branch/tag.
   - Reject model snapshots containing non-regular entries, symlinks, hardlinks with link count >1, device nodes, sockets, FIFOs, absolute paths, path escapes, or `..` path segments.
   - Compute canonical artifact-set hash exactly as SPEC §3.2 says before benchmark, recommendation, donor commit, or provider run.
   - Cached benchmark admission is fail-closed: a current `benchmark_id` from the active run is acceptable; otherwise a cached run may be reused only when selected `candidate_catalog_sha256`, binary version, model ID, HMAC-derived hardware identity hash, and benchmark `generated_at` age <= 7 days all match.
   - Add negative tests for each cached-benchmark mismatch: catalog hash, binary version, model ID, hardware identity hash, and age > 7 days.
5. Rate-card recommendation lookup:
   - Exact key, then Wave 0b `normalizeModelKey`.
   - Do not use coordinator `default` fallback unless candidate key is literally `default`.
6. Formula:
   - Use the locked §4 formula, including `cold_start_floor = 0.15`, `diversification_band = 0.85`, provider share, tier weight, and deterministic stable hash pool selection.
   - Paid recommendation requires all §5 gates and `expected_net_usd_per_hour >= 0.0050`.
   - Below threshold emits `recommended_model = null`, `recommendation_below_threshold`, and donor-tier transcript.
   - `min_provider_target` is parsed and preserved only; it must not affect v0.1 scoring, eligibility, diversification, or live provider-count queries.
7. JSON:
   - Deterministic field order matching SPEC §6.
   - Stable warning vocabulary sorted lexicographically.
   - Unknown optional fields use `null`, not omitted.
8. Human transcript:
   - Exact §7.1 and §7.2 text and `$%.4f/hr` formatting.
   - Earnings language remains estimate-only; no guaranteed earnings.
9. Tests:
   - Unit tests for scoring, threshold, top-band diversification, stable hash, no-default fallback, normalized lookup, tier comparison, stale warnings, and JSON field order.
   - Unit tests proving `min_provider_target` does not affect scoring or eligibility and no provider quota/count policy is consulted in v0.1.
   - Fixture tests for all SPEC ACs that do not require real model downloads.
   - Download/hash behavior can use local temp directories and mocked fetchers; do not hit external networks in unit tests.

### Slice D — Donor Mode, Apply, Status, Update, Installer Hooks

Files likely touched:

- `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift`
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` / update command surfaces if retune hook belongs there
- `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift` or status command files
- installer scripts under `phase3-binary/dist/` if they own post-install prompting

Requirements:

1. Add `--donor-mode` boolean on the configuration/apply path and `donor_mode: true` YAML config support.
2. Donor mode may skip only paid-yield threshold and demand-rank `recommendable == true` default-selection gate.
3. Donor mode must not bypass signed selected catalog metadata, immutable revision, canonical artifact digest, runtime status not blocked, model allowlist, RAM headroom, no-swap, no-thermal, or runtime support.
4. Donor mode is local-only for non-recommendable rows: applying it may write local config/status, but must not auto-start or auto-register a network-connected paid provider for a non-recommendable donor row.
5. No arbitrary local model/custom donor-mode path override in v0.1.
6. `macprovider-cli status` shows `DONOR MODE` when `donor_mode: true`.
7. Store recommendation state at `~/.config/macprovider/last-recommendation.json` with all §9 fields.
8. `macprovider-cli update` and installer rerun compare stored/live `rate_card_version`, `demand_rank_version`, `candidate_catalog_version/hash`, `binary_version`, `hardware_identity_hash`, and benchmark age; prompt re-tune on changes/expiry.
9. Status emits:

```text
Recommendation stale: recommendation inputs changed since {generated_at}.
Run: macprovider-cli autotune --recommend
```

10. Tests:
    - Donor-mode config write and warning.
    - No donor auto-start/auto-register for non-recommendable rows.
    - Status donor badge.
    - Stale recommendation detection for each stored field.
    - Update/installer hook unit tests where practical; shell smoke for installer rerun if needed.

## 3. Acceptance-Criteria Ownership Matrix

Every AC from SPEC §11 must have at least one test or explicit verification note:

- Slice B/C: AC-1 through AC-21.
- Slice D: AC-22 through AC-27.
- Slice C/D security and privacy: AC-28 through AC-36.
- Slice A: AC-37 and AC-38.
- Slice B/D: AC-39.

If an AC needs an integration or manual smoke rather than a unit test, create a named verification command or script and document the residual requirement in the final handoff. Do not mark an AC satisfied by prose alone when it can be tested.

## 4. Implementation Constraints

- Keep diffs small and local to SPEC-023 surfaces.
- Prefer existing Swift patterns in `AutotuneCommand`, `RecommendationEmitter`, `ConfigApplier`, `SelfUpdate`, and existing test fixture style.
- Prefer existing Go patterns in `internal/buyer` and `cmd/coordinator`; do not introduce a new router framework.
- Do not add dependencies unless the implementation is unreasonable without them. If adding a dependency, justify it in the commit body.
- Do not change billing formula, ledger writes, settlement math, request logs, gateway routing, or `RateCardEntry` YAML shape.
- Do not make live network calls in unit tests.
- Do not hardcode secrets. The Ed25519 public key is not a secret; the HMAC local secret is.
- Do not inspect Darkbloom source.

## 5. Verification Commands

Run the smallest relevant tests as you work, then finish with:

```bash
cd phase4-coordinator && go test ./internal/buyer ./cmd/coordinator
cd phase3-binary && swift test --filter Autotune
cd phase3-binary && swift test --filter Recommendation
```

If time permits or touched surfaces are broad:

```bash
cd phase4-coordinator && go test ./...
cd phase3-binary && swift test
```

Before final handoff:

```bash
git diff --check
git status -sb
```

## 6. Required Final Handoff

Final response from the implementation session must include:

- Branch/worktree used.
- Files changed grouped by coordinator, CLI, installer/status, tests.
- Acceptance criteria covered and any explicit gaps.
- Exact verification commands and outcomes.
- Confirmation that no product-design lane, no Darkbloom source inspection, and no money-path schema/settlement changes occurred.

Do not open a PR unless the operator explicitly asks.
