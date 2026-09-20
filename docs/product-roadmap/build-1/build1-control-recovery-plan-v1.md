# Build 1 Control Recovery Plan v1

Status: active control ledger
Date: 2026-09-15
Base evidence: `origin/main` at `12de7aea` plus PR #1649
Decision: freeze new Build 1 implementation slices unless they name one Build 1 lane from this document.

## Purpose

Build 1 is not being built without a SPEC. `SPEC-044` is the current normative
authority for Malibu model catalog economics and safe preparation, and the
narrow MVP plan/test spec define a smaller staging-only acceptance target.

The control problem is different: Build 1 now has many slice plans, test specs,
reviews, handoffs, and merged PRs. Future sessions need one entry point that
says which lane is active, what already landed, what remains unproved, and when
to stop.

## Current Decision

Use Lane A unless the product owner explicitly selects a different lane.

### Lane A - Narrow Staging MVP

Recommended current lane. Deliver one constrained physical staging proof for:

- Canonical model: `meta-llama/llama-3.2-3b-instruct`
- Provider artifact: `mlx-community/Llama-3.2-3B-Instruct-4bit`
- Environment: staging coordinator/gateway only
- Boundary: no production activation, rewards, payouts, public earnings claims,
  or automatic paid-provider qualification

This lane stops when a schema-valid evidence bundle proves the selected model
tuple ran through the intended provider path in staging, and a human can review
the source captures. It does not stop on fixture-only, skipped, timed-out, or
local-only evidence.

### Lane B - Full SPEC-044 v2 Experience

Larger product lane. This includes the complete public v2 model catalog
economics and preparation experience across catalog projection, preparation,
cancel/commit behavior, admission, settlement, user journeys, release evidence,
and production readiness. This lane should start only after an explicit owner
decision because all `SPEC-044` conformance requirements remain pending.

### Lane C - Stop Build 1

Pause Build 1 as a shippable effort and preserve the merged groundwork as
internal foundations. This lane should also be explicit, because otherwise
future sessions will keep interpreting stale handoffs as active work.

## Landed Ledger

| PR | Commit | What it proves | What it does not prove |
| --- | --- | --- | --- |
| #1490 | `c8c97f66` | `SPEC-044` authorizes safe model preparation and records the no-production-activation boundary. | No implementation, release, journey, staging run, admission, settlement, or earnings proof. |
| #1501 | `4c99f9d7` | Signed rate-card runtime parity is guarded against billing drift. | No artifact preparation path, provider staging journey, or full Build 1 acceptance. |
| #1504 | `4f388d67` / `55339a58` | Preparation-state trust boundaries and private fail-closed store foundations landed. | No public action surface, physical preparation/adoption journey, admission, or settlement. |
| #1507 | `40fb348a` | Public v1 catalog behavior is preserved while private v2 projection foundations are grounded. | No public v2 action claims, preparation lifecycle, cleanup, or physical acceptance. |
| #1510 | `5a4e3735` | v2 storage projection is grounded in private inventory and the old dependency is merged. | Not Build 1 product acceptance; no public prepare/adopt/cancel path or staging journey. |
| #1512 | `ab181787` | Narrow MVP evidence validation is guarded against overclaiming and the old dependency is merged. | Does not create the physical evidence bundle, provider execution path, or product acceptance. |
| #1519 | `82e8f7c7` | Configured v2 storage budget groundwork is landed behind private boundaries. | No public v2 status, env/YAML runtime parser, preparation action, admission, settlement, payout, release, or production activation. |
| #1525 | `68b90269` | Lane A `macprovider-cli models prepare` exists behind exact tuple, staging coordinator, `--json`, and `--yes` guards, and fails closed with transaction events. | No signed artifact authority, artifact download, staging, durable adoption, physical provider run, admission, settlement, payout, release, or production activation. |
| #1530 | `4913590c` | The guarded `models prepare` path verifies the exact Lane A signed artifact authority tuple from the staging artifact feed before doing anything else. | No artifact download, staging, durable adoption, physical provider run, admission, settlement, payout, release, or production activation. |
| #1649 | open, head `1971e7a6` | `models prepare` stages the exact MLX snapshot into an isolated hash-qualified directory, verifies the snapshot-manifest digest against the signed authority, and adopts it into the provider-owned durable store; failure, timeout, and cancellation leave the active model and durable store unchanged. | No private preparation-state record, `serve`/status evidence binding, staging admission, gateway request, receipt/audit correlation, settlement, payout, release, physical run, or production activation. |

Current open PRs as of 2026-09-15 are not Build 1 control blockers:

- #1496 `fix/1484-or-market-feeds-engine` - open, changes requested, behind.
- #1473 Build 3 docs - open, review required, behind.
- #1472 Build 5 docs - open, review required, behind.
- #1471 Build 4 docs - open, review required, behind.

## Superseded Or Stale Inputs

- PR #1491, `feat(build1): bind private preparation recovery contracts`, was
  closed unmerged on 2026-09-15 and is superseded by later merged preparation
  state, private store, v2 projection, storage projection, and evidence
  validation work. Do not reopen it for Lane A unless a fresh diff proves it
  contains required behavior not present on `origin/main`.
- Handoffs that say #1510 or #1512 are still unmerged are stale after
  `origin/main` commit `c4238cfa`.
- Historical plan/test-spec versions remain evidence, not current authority.
  Use `narrow-mvp-plan-v6.md` and `narrow-mvp-test-spec-v6.md` for Lane A, and
  `SPEC-044` plus conformance records for Lane B.
- Old local Build 1 worktrees and branches are not active authority. Clean them
  up only as a separate maintenance task after checking each worktree is clean
  and no session still owns it.

## Remaining Blockers

Lane A blockers:

- Record private preparation state for the adopted Lane A artifact through the
  existing `ModelPreparationPrivateStore` contracts so `models catalog-economics`
  can project it without touching public v1 output.
- Bind `serve` local status evidence (`model_hash`, `weights_manifest_sha256`)
  to the adopted Lane A artifact for the evidence validator.
- Produce a measured, artifact-bound staging release or equivalent staging
  input for the selected Llama 3B tuple.
- Run the physical Apple Silicon staging journey against staging
  coordinator/gateway.
- Collect validator-accepted evidence that is not fixture-only, skipped,
  timed out, or local-only.
- Preserve the boundary that local preparation alone never grants paid
  admission, settlement, earnings, rewards, payouts, or production activation.

Lane B blockers:

- Reconcile and implement all pending `SPEC-044` conformance requirements
  `R001` through `R012`.
- Publicly expose only the required v2 economics/preparation states and actions.
- Implement and verify cancel-after-commit, terminal reconciliation, lock graph,
  post-action projection refresh, release evidence, full user journeys, and
  production readiness.
- Obtain explicit owner approval before production activation.

## Next Authorized Action

The next implementation work, if Build 1 continues, is the Lane A private
preparation-state record for the adopted artifact: after `models prepare`
adopts the verified Lane A tuple (#1649), write the private published-inventory
record through the existing `ModelPreparationPrivateStore` envelope contracts
and keep public `models catalog-economics` v1 output unchanged. After that, the
`serve` local status evidence binding for the same artifact.

That PR or handoff must state:

- Selected lane: Lane A.
- Requirement source: `SPEC-044`, `narrow-mvp-plan-v6.md`,
  `narrow-mvp-test-spec-v6.md`, and
  `lane-a-executable-provider-path-prd-v1.md`.
- What the PR will prove.
- What the PR will not prove.
- Stop condition.
- No-production-activation boundary.

## Future Session Gate

Before opening any Build 1 PR, a session must:

1. Read this control recovery plan.
2. Confirm no newer Build 1 control plan supersedes it.
3. State the selected lane in the PR body or handoff.
4. Cite the current requirement source.
5. Explain how the diff reduces a named remaining blocker.
6. Preserve the no-production-activation boundary unless the owner explicitly
   approves production activation in that same session.

If these fields cannot be filled, stop and recover control instead of creating
another slice.

## Validation

This is a docs-only control recovery change. Validation for this PR is limited
to markdown diff hygiene and repository governance checks; code tests are not
required unless later edits touch executable, spec, schema, runtime, CI,
release, catalog, rate-card, or production-affecting paths.
