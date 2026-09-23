**Resource constraint:** do NOT run full test suites or builds (no full `swift test`, `swift build`, `xcodebuild`, `make test-*`); PR CI runs them on push. Review by reading code/tests/specs; run at most a few targeted `go test -run` / grep commands.

# Shared context — #1689 node-operator UX epic (one PR, full diff)

**Method constraint (read first):** this is a first-party software-correctness
and proof review of our own code. Reason from the source, tests, and SPEC text.
Do NOT author exploit payloads, attack scripts, or adversarial inputs; describe
any failure scenario in prose with file:line.

Repo: macprovider. Worktree: `/Users/augstar/macprovider-1689-status`,
branch `feat/1689-honest-status`, based on `origin/main` at `761e5f0c`.

Review the FULL diff as it will land: `git diff 761e5f0c...HEAD` in that
worktree (70 files changed, 10587 insertions(+), 231 deletions(-)), 231 deletions(-)), 181 deletions(-)), 172 deletions(-)), 165 deletions(-)), 127 deletions(-)). This is the complete epic, not a slice. Commits, in
order:

- `fef9624a` Show where status readiness, throughput, and context come from
- `e005cd3b` Stop reporting buyer-serving when the network catalog lacks the served model
- `892846bf` Let operators prove local, coordinator, and public feed agree after a change
- `e4c3824f` Stop writing a 4K production context cap on high-memory Macs and let operators change context safely
- `09e09984` Let operators check a model's local bytes against its signed catalog row and repair partial downloads
- `a1f2ed81` Recompute generated context when the served model changes and keep operator overrides
- `2630cc64` Record the #1689 audit prompts

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
4. **4K fix + safe context changes.** SPEC-023 v0.15.2: `max_context_override`
   = min(RAM tier, declared model max, memory-safe); unknown bounds drop out;
   declared `head_dim` honoured; hybrid `layer_types` count only full-attention
   layers. Provenance of a recommendation-generated context is stored in config.yaml itself (see ROUND 4).
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

## ROUND 6 — FINAL gate (code + architecture; security PASSED R5 0/0/0)

Round 5 found and this revision claims to fix:
- HIGH/MEDIUM: `provider context set`/`rollback` validated a different state than they committed (live slot count vs the file's post-restart slots; config edits between preflight and lock; rollback beside current draft_model). Now: model inspection outside the lock + fingerprint of the relevant fields; under the config lock re-read with an empty environment, compare fingerprint (≤3 re-preflights, then refuse writing nothing); shared `check(_:facts:)` validates the complete prospective config (draft cap, >1 slot refused with a draft model, model limit, KV memory for the FILE's post-restart slot count); rollback validates the restored state against non-restored fields.
- MEDIUM: block-form `max_context_override_provenance` lost on rollback/recovery → owned-value capture normalizes a valid record to canonical flow form.
- MEDIUM: `provider verify` feed not bound to the live coordinator → `/v1/status.coordinator_origin` (capability `coordinator_origin_v1`, normalized scheme://host[:port]); feed endpoint derived only from it; missing capability / null / unreadable origin ⇒ terminal unverifiable (exit 7), never agree.
- LOWs: draft checks under the lock; audit-prompt whitespace.

GATE FOR THIS ROUND (operator-approved): BLOCKING = any CRITICAL or HIGH anywhere, plus any MEDIUM in the money/routing path (phase4-coordinator buyer/routing/billing/settlement, phase5-gateway). MEDIUM findings confined to operator-only CLI tooling will be carried as a tracked follow-up issue, not block. Classify every finding's path explicitly as MONEY/ROUTING or OPERATOR-CLI.

## Output format

Findings as CRITICAL / HIGH / MEDIUM / LOW / INFO, each with file:line, a
concrete failure scenario in prose, and a suggested fix. Gate:
**0 CRITICAL, 0 HIGH, 0 MEDIUM**. State explicitly if you find none. Tag each
finding NEW (introduced by this diff) or PRE-EXISTING.

## Your lane: CODE REVIEW
- Correctness of each behavior change against the SPEC text it cites
  (SPEC-001 v1.9.2x FR-17/FR-20a/FR-20b + buyer-serving holds; SPEC-022 R-2.7 /
  AC-022-65; SPEC-023 v0.14.3 §6; SPEC-010 v1.10 §3.8 / R008). Every
  restatement of a changed rule inside those SPECs must agree.
- `max_context_source` precedence (CLI flag > env > config > RAM default,
  draft clamp, adoption, recommendation_apply) — is the recorded source always
  the source that actually won? Sidecar mismatch handling.
- KV-bytes-per-token math after the head_dim / layer_types change: every
  architecture in the signed catalog (dense, MoE, hybrid, GQA) — any row whose
  recommended context now exceeds memory safety?
- Hold state machine in the CLI (`.held(hold)`, re-entry on hold change,
  watchdog, promotion to confirmed): no path that holds forever or reconnects
  when it should hold.
- `provider verify` exit-code mapping, backoff never exceeding the deadline,
  comparison logic vs the public feed shape.
- `provider context set/rollback`: atomicity, backup/restore fidelity, lock
  usage, behavior when restart or verify fails.
- `models verify-artifact/prepare`: classification correctness,
  `--repair-cache` deletion scope, Lane A (`build1-lane-a`) behavior unchanged.
- Test adequacy: are the new tests asserting the behavior or just the shape?
  Any changed/renamed existing test that now asserts less than before?
- Wire/golden frames (Swift + Go) updated deliberately, nothing silently
  loosened.
