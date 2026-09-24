# Shared context — #1689 node-operator UX epic (one PR, full diff)

**Method constraint (read first):** this is a first-party software-correctness
and proof review of our own code. Reason from the source, tests, and SPEC text.
Do NOT author exploit payloads, attack scripts, or adversarial inputs; describe
any failure scenario in prose with file:line.

Repo: macprovider. Worktree: `/Users/augstar/macprovider-1689-status`,
branch `feat/1689-honest-status`, based on `origin/main` at `6c00a643`.

Review the FULL diff as it will land: `git diff 6c00a643...HEAD` in that
worktree (51 files changed, 5561 insertions(+), 127 deletions(-)). This is the complete epic, not a slice. Commits, in
order:

- `319a91ce` Show where status readiness, throughput, and context come from
- `a4f84baf` Stop reporting buyer-serving when the network catalog lacks the served model
- `c26610e3` Let operators prove local, coordinator, and public feed agree after a change
- `4570fc61` Stop writing a 4K production context cap on high-memory Macs and let operators change context safely
- `2ba29b2a` Let operators check a model's local bytes against its signed catalog row and repair partial downloads
- `444064c5` Recompute generated context when the served model changes and keep operator overrides

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

## Output format

Findings as CRITICAL / HIGH / MEDIUM / LOW / INFO, each with file:line, a
concrete failure scenario in prose, and a suggested fix. Gate:
**0 CRITICAL, 0 HIGH, 0 MEDIUM**. State explicitly if you find none. Tag each
finding NEW (introduced by this diff) or PRE-EXISTING.

## Your lane: ARCHITECTURE REVIEW
- Single source of truth: routing eligibility vs dispatch material lookup (one
  predicate?), context computation (recommend/apply vs `provider context` vs
  model-switch recompute — one function?), hold enum (SPEC-001 vs Go vs Swift),
  readiness semantics (`network_state` meaning unchanged for install.sh,
  deploy-pearl-vps.sh, catalog-canary-proof.py consumers).
- Is capability-gating via `tier2_capabilities` the right altitude, and is the
  legacy compatibility exception bounded (documented removal condition)?
- Is `provider verify` correctly positioned as read-only and reused by
  `context set --apply` / rollback without duplicating logic?
- Sidecar provenance design vs alternatives (in-config keys): evolution,
  migration, multi-writer (Malibu.app, installer, autotune) interaction.
- `models prepare` overloading of the SPEC-044 Lane A command via
  `--profile catalog`: contract clarity vs a separate command.
- Cross-spec consistency after the version bumps (SPEC-001/010/022/023) and
  the contract-lock / CONFORMANCE / README index.
- Anything in this one-PR epic that should not ship together (hidden
  coupling that makes rollback of one part impossible without the others).
