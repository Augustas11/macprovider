# Shared context — #1689 node-operator UX epic (one PR, full diff)

**Method constraint (read first):** this is a first-party software-correctness
and proof review of our own code. Reason from the source, tests, and SPEC text.
Do NOT author exploit payloads, attack scripts, or adversarial inputs; describe
any failure scenario in prose with file:line.

Repo: macprovider. Worktree: `/Users/augstar/macprovider-1689-status`,
branch `feat/1689-honest-status`, based on `origin/main` at `afbee248`.

Review the FULL diff as it will land: `git diff afbee248...HEAD` in that
worktree (52 files changed, 6478 insertions(+), 165 deletions(-)), 127 deletions(-)). This is the complete epic, not a slice. Commits, in
order:

- `bfd7df64` Show where status readiness, throughput, and context come from
- `b82e13e9` Stop reporting buyer-serving when the network catalog lacks the served model
- `fcc93c77` Let operators prove local, coordinator, and public feed agree after a change
- `128e9803` Stop writing a 4K production context cap on high-memory Macs and let operators change context safely
- `0910ef00` Let operators check a model's local bytes against its signed catalog row and repair partial downloads
- `cf08c665` Recompute generated context when the served model changes and keep operator overrides

## Problem being fixed (issue #1689)

Operators running a MacProvider node (human or coding agent, over SSH) could
not tell the node's true state, change a serving knob safely, or prove the
network agreed. Concretely observed on a 256GB Mac Studio:

1. `status` / `/v1/status` reported `network_state=buyer_serving` while 116/116
   strictly pinned buyer requests failed pre-inference with
   `route_snapshot_failed`: the coordinator's routing-eligibility and
   pool/check verdict treated missing signed Tier-2 route-snapshot material as
   legacy-eligible (`model_admission.go`), while dispatch in enforce mode
   rejected it (`route_snapshot.go`).
2. The startup-probe `throughput_tps_estimate` (≈8.6 tok/s, an 8-token probe
   incl. prefill, carried unchanged across warm swaps) read like sustained
   throughput (~96–110 tok/s measured).
3. Qwen3.6-27B was served with a 4,000-token `max_context_override` written by
   recommend/apply: `kvCacheBytesPerToken` required
   `hidden_size % num_attention_heads == 0` even when `head_dim` was declared
   (5120 % 24 ≠ 0) → nil → fail-closed 4K floor.
4. No CLI path to explain/change/verify/rollback context, no post-change proof
   that local / coordinator / public feed agree, no artifact-identity or
   partial-download diagnostics.

## What the change does (by commit)

1. **Status provenance (CLI, additive).** `/v1/status.capacity` gains
   `max_context_source`, `throughput_source`, `throughput_probe_max_tokens`,
   `throughput_probe_model` behind capability `capacity_provenance_v1`.
   `status --advanced` shows readiness layers, labelled probe vs stored
   sustained benchmark, context source, and a fixed coordinator URL line.
   `throughput_tps_estimate` wire semantics unchanged (SPEC-004 router scoring
   and SPEC-001 auth handshake consume it). SPEC-001 bump.
2. **Catalog-material readiness (CLI + coordinator, sensitive path
   `phase4-coordinator/internal/buyer/`).** SPEC-022 R-2.7: in settlement
   route mode *enforce*, a non-BYOM session whose served model lacks verified
   Tier-2 snapshot material is excluded from paid routing on every path
   (filter, pinned, slot-queue, queued poll) via one shared predicate used by
   routing and dispatch. `/v1/pool/check` returns `buyer_serving=false` +
   `buyer_serving_hold=catalog_material_missing` **only** to CLIs advertising
   `tier2_capabilities.catalog_material_hold_v1` in `auth_request`; legacy
   CLIs keep the old verdict (deployed CLIs reconnect on an unknown hold — a
   deliberate compatibility exception). CLI holds through the new reason like
   `model_admission_pending`. Buyers now get retryable 503
   `no_provider_available` / `pool_settlement_mode_unsatisfied` instead of 500
   `route_snapshot_failed`.
3. **`provider verify`** — read-only, bounded wait until local `/v1/models` +
   `/v1/status`, coordinator (`network_state`), and public
   `/v1/stats/routability` (SPEC-017) agree; per-layer lines, one proof line,
   distinct exit codes; fields the public feed cannot prove (anonymised
   provider id, per-provider context) are reported as unverifiable.
4. **4K fix + safe context changes.** SPEC-023 v0.14.3: `max_context_override`
   = min(RAM tier, declared model max, memory-safe); unknown bounds drop out;
   declared `head_dim` honoured; hybrid `layer_types` count only full-attention
   layers. `ConfigApplier` writes a best-effort sidecar
   `<config>.provenance.json` (`knob_provenance.v1`) so a
   recommendation-generated value is distinguishable from an operator value.
   `provider context explain | set [--preflight] [--apply] | rollback`: bounds
   + KV-memory preflight, atomic write under config lock with token-stripped
   backup, restart via existing `launchctl kickstart -k` helper, then verify;
   resource preflight lists competing serve processes / port listeners
   (suggest-only).
5. **Model diagnostics.** `models verify-artifact`, `models identity`,
   `models prepare --profile catalog [--repair-cache]` reusing the signed
   catalog loader and existing HF downloader; mismatch classified as
   local_download / revision_pin / catalog_row / unverifiable; redacted report;
   `--repair-cache` deletes only this model's partial-download artifacts.
   SPEC-010 v1.10 R008 (pending).
6. **Model-switch recompute.** A live `models switch` (control socket `handleSwitchRequest`) passes `ModelRuntime.switchKnobs(for:)` adoption knobs: when the resolved `max_context_source` is `recommendation_apply` (sidecar value matches), serve precomputes per-target contexts with the same `AutotuneRecommendHardware.recommendedMaxContext` function (via `ModelSwitchContext.recomputedContext`) for signed, locally verified switch targets; operator-owned values produce no knobs (context unchanged) and the CLI prints a one-line under-use warning. The live switch never rewrites config.yaml or the sidecar. `beginSwap` body is untouched (SPEC-010-R006 conformant evidence). Known limitation: the CLI notice uses the switch process's own config/env, so with a serve `--max-context` flag the printed line can say "recomputed" while serve correctly keeps the flag value.

## Known, deliberate consequences — judge them

- Legacy CLIs on a model without Tier-2 material keep seeing
  `buyer_serving=true` from pool/check although routing now excludes them.
- Existing `last-recommendation.json` files carrying a 4K context will be
  rejected by adoption's `validateSignedContextAuthority` because the expected
  value changed; providers need a fresh `autotune --recommend`.
- `/v1/models` may still list a model whose only providers are excluded by
  R-2.7 (same as today for missing receipt keys).

## Verification already run

- Coordinator: `go build ./... && go vet ./...`; `make test-coordinator` (pass, after adding AC-022-65 to the SPEC-022 D8 coverage map); `make lint-coordinator` 0 issues.
- `make test-gateway` pass; `make test-integration` pass (integration, spec015, spec_014_v0_2_pairing).
- `swift build --build-tests`; full `swift test --skip-build` (bounded): 3216 tests, 39 skipped, 0 failures.
- `python3 scripts/check_spec_governance.py --base-ref origin/main` pass; `scripts.tests.test_byom_contract_lock` 16 OK; `gen_spec_index.py --check` ok; `make test-dist` pass.
- Not run: Malibu app xcodebuild tests (no app-decoded field changed); no live hardware / Pearl run of this build.

## ROUND 2 — closure verification

Round 1 (same full diff, previous base) found, and this revision claims to fix:
- M1 (code+arch; security L3): rollback lost knob provenance; sidecar bound only by value → now bound to config bytes (`config_sha256`, provider_token lines excluded), sidecar backed up/restored with every config backup under the config lock.
- M2 (code): `provider verify` exceeded `--timeout` → `boundedFetch` races each request against min(5s, remaining); `--timeout 0` = one bounded pass.
- M3 (code): artifact diagnostics resolved different bytes than serve → shared `ServeCommand.pinnedArtifactLoadCandidate`.
- M4 (code): `try? ConfigLoader.load` swallowed explicit config errors → exit 2 before any work.
- M5 (arch): SPEC-022-R002 kept `conformant` on pre-R-2.7 evidence → now `pending` with a gap; new predicate/tests mapped.
- M6 (arch): SPEC-023 default-context algorithm had no requirement; AC-40 contradicted it → SPEC-023-R012 (§9.3) + AC-46, AC-40/R003 reconciled; SPEC-023 now v0.14.4 (main's #1694 took v0.14.3).
- Lows/info: hold-ended messaging per hold (L1), no-redirect + exact-URL response check in verify (L2), human output path redaction (L3), switch notice from runtime-applied `switch_progress` fields `max_context_tokens`/`max_context_source` (additive; SPEC-011 not edited) (L4), retirement condition for the legacy pool/check exception (L5), catalog profile rejects Lane-A-only options (INFO).
- Out of scope, PRE-EXISTING: phase7-verify golang.org/x/text v0.37.0.

Verify each fix is real and complete (not just a test added), and review the fix code itself for new defects. Report any remaining or newly introduced C/H/M.

Verification run on this revision: coordinator build/vet/test/lint (0 issues), gateway, integration, full Swift suite 3246 tests / 0 failures (bounded), Malibu app xcodebuild 616 tests / 0 failures, test-dist, spec governance, contract lock, spec index check+lint — all pass.

## Output format

Findings as CRITICAL / HIGH / MEDIUM / LOW / INFO, each with file:line, a
concrete failure scenario in prose, and a suggested fix. Gate:
**0 CRITICAL, 0 HIGH, 0 MEDIUM**. State explicitly if you find none. Tag each
finding NEW (introduced by this diff) or PRE-EXISTING.

## Your lane: SECURITY REVIEW
- Money/routing path (`phase4-coordinator/internal/buyer/`): can the new
  exclusion or the capability-gated pool/check verdict be influenced by a
  provider-asserted value to gain routing, avoid exclusion, or make
  settlement run without Tier-2 material? `catalog_material_hold_v1` is
  provider-asserted — confirm it only changes what the provider is *told*,
  never what routing *does*.
- Can the change let a request reach dispatch in enforce mode without
  material (TOCTOU between eligibility and dispatch, catalog reload/SIGHUP
  between the two)? Any new lock/ordering/deadlock risk on the buyer hot path
  (the global Tier-2 catalog read in eligibility)?
- Does any new buyer-visible error/status disclose internal identity (model
  hashes, catalog digests, provider ids, hostnames, file paths)?
- Local CLI surfaces: `/v1/status` new fields, `provider verify` (coordinator
  URL scheme handling: wss→https, ws/http only for loopback — any downgrade or
  SSRF-ish path?), `provider context set` (config write, backup files
  containing tokens — are they stripped and 0600?), `--repair-cache` deletion
  (path traversal / symlink following outside the target model's cache),
  `models verify-artifact` redaction completeness, `lsof`/process listing
  command construction.
- Sidecar `<config>.provenance.json`: can a crafted/stale sidecar make the CLI
  mislabel an operator value, or cause a larger-than-safe context to be
  written?
- Fleet-safety: any path where deployed (older) CLIs start flapping or
  reconnect-storming against a coordinator running this code.
