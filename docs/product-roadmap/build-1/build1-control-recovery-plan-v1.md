# Build 1 Control Recovery Plan v1

Status: superseded for current execution by `build1-control-recovery-plan-v2.md`
Date: 2026-09-15
Base evidence: `origin/main` at `7c2e4d97` plus PR #1658
Decision: retained as historical control evidence. The v2 ledger owns the
private-tuple acceptance correction and current recovery sequence.
Execution overlay: `build1-single-pr-orchestrator-workflow-v1.md` keeps Lane A
work in one orchestrator-owned PR (#1658) until the Lane A stop condition is
met and the owner explicitly greenlights merge.

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
- Environment: Pearl coordinator/gateway network when the currently deployed
  binaries include the BYOM admission and verified-settlement path; local/mock
  evidence is a fallback only if Pearl lacks that deployed path.
- Boundary: no release publication, payout/reward enablement, public earnings
  claims, or automatic paid-provider qualification. Any Pearl admission used
  for the proof must be explicit, temporary, auditable, and scoped to the Lane A
  tuple and provider.

This lane stops when a schema-valid evidence bundle proves the selected model
tuple ran through the intended provider path on the real coordinator/gateway
network, and a human can review the source captures. It does not stop on
fixture-only, skipped, timed-out, or local-only evidence while Pearl has the
required BYOM path deployed.

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
| #1649 | `4cf73a6f` | `models prepare` stages the exact MLX snapshot into an isolated hash-qualified directory, verifies the snapshot-manifest digest against the signed authority, and adopts it into the provider-owned durable store; failure, timeout, and cancellation leave the active model and durable store unchanged. | No private preparation-state record, `serve`/status evidence binding, staging admission, gateway request, receipt/audit correlation, settlement, payout, release, physical run, or production activation. |
| #1658 | open | After durable adoption, `models prepare` writes the exact adopted Lane A tuple into the private published-inventory record through the existing `ModelPreparationPrivateStore` envelope contracts, with a persisted publication receipt under the managed-v3 namespace; the private state bootstraps before any transfer and fails closed; failure, timeout, and cancellation never write or mutate the record; public `models catalog-economics --json` v1 output is unchanged. The same PR now also correlates `GET /v1/status` diagnostic evidence for Lane A to the exact private receipt and configured release: the observed `model_hash` is matched to the receipt `artifact_sha256` and the configured artifact SHA; the receipt `artifact_identity_digest`, receipt digest, and root identity digest are published as digests only; `weights_manifest_sha256` is reported as observed (presence and algorithm only, not bound to the receipt). The correlation is path-observed and states `descriptor_pinned_runtime_custody=false`, while explicitly preserving no admission, settlement, payout, rewards, or production activation semantics. The same PR now also adds `models staging-input`, a read-only Lane A command that assembles one `build1_lane_a_staging_input.v1` handoff from the signed staging artifact authority (measured `size_bytes`, trusted signer, release binding), the private publication receipt for the adopted artifact, and the local `GET /v1/status` Lane A evidence; it is `staging_input_ready` only when all three name the same tuple, release, digest, declared size, and private record, and otherwise reports explicit blockers (`artifact_feed_not_served`, `artifact_feed_rejected`, `private_record_*`, `status_*`) with exit 2. | No signed measured artifact feed served by the staging coordinator yet (operator release action), no staging admission, descriptor-pinned runtime load custody, gateway request, receipt/audit correlation, settlement, payout, release, physical run, public v2 projection, cleanup transaction, or production activation. A `staging_input_ready` report is a staging input, not acceptance; local preparation/status evidence alone never implies admission, settlement, or earnings. |

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

- Produce measured artifact-feed authority for the selected Llama 3B tuple
  without faking byte counts: the lab/staging path must measure every published
  primary artifact from real artifact files or Hugging Face snapshots, sign the
  full artifact feed with the trusted static-feed key, and serve
  `/v1/catalog-artifacts` plus its detached signature on loopback or approved
  staging authority. PR #1658 now owns the operator-local loopback helper for
  this path; production release publication remains out of scope.
- Add descriptor-pinned runtime load custody if the physical staging journey
  needs more than path-observed local status correlation.
- Run the physical Apple Silicon journey against the Pearl coordinator/gateway
  network when Pearl has the BYOM admission and settlement path deployed. Use
  local/mock coordinator or gateway evidence only as an explicitly labeled
  fallback if that deployed path is absent.
- Collect validator-accepted evidence that is not fixture-only, skipped,
  timed out, or local-only.
- Preserve the boundary that local preparation alone never grants paid
  admission, settlement, earnings, rewards, payouts, or production activation;
  any Pearl admission/request proof must be temporary, auditable, and cleaned up
  or withdrawn when the proof is complete.

Lane B blockers:

- Reconcile and implement all pending `SPEC-044` conformance requirements
  `R001` through `R012`.
- Publicly expose only the required v2 economics/preparation states and actions.
- Implement and verify cancel-after-commit, terminal reconciliation, lock graph,
  post-action projection refresh, release evidence, full user journeys, and
  production readiness.
- Obtain explicit owner approval before production activation.

## Next Authorized Action

The next work, if Build 1 continues, is to use the measured artifact-feed
helper output as preflight evidence, then run the physical Apple Silicon journey
against Pearl because Pearl has BYOM admission and verified-settlement code
deployed: start a dedicated Lane A provider on MacStudio without disturbing the
existing Qwen provider, submit the Lane A offer, perform the operator decision
sequence through `settlement_capable`, route one non-streaming gateway request,
capture receipt/audit and settlement evidence, and assemble the validator
bundle. Local/mock coordinator or gateway evidence is acceptable only if Pearl
is proven not to have the deployed BYOM path. Public v1
`models catalog-economics` output stays unchanged until Lane B.

Per `build1-single-pr-orchestrator-workflow-v1.md`, this work should continue
inside PR #1658 as an internal milestone. #1658 should not merge merely because
the private preparation-state record or `serve`/status evidence-binding
milestone has green CI.

That PR milestone or handoff must state:

- Selected lane: Lane A.
- Requirement source: `SPEC-044`, `narrow-mvp-plan-v6.md`,
  `narrow-mvp-test-spec-v6.md`, and
  `lane-a-executable-provider-path-prd-v1.md`.
- What the PR will prove.
- What the PR will not prove.
- Stop condition.
- No-production-activation boundary.

## Future Session Gate

Before opening any Build 1 PR, or before adding a Build 1 milestone to PR
#1658, a session must:

1. Read this control recovery plan.
2. Confirm no newer Build 1 control plan supersedes it.
3. State the selected lane in the PR body, milestone note, or handoff.
4. Cite the current requirement source.
5. Explain how the diff reduces a named remaining blocker.
6. Preserve the no-production-activation boundary unless the owner explicitly
   approves production activation in that same session. A scoped Pearl network
   proof is not a release, payout, reward, or public earnings activation, but
   it must remain temporary, auditable, and limited to Lane A.

If these fields cannot be filled, stop and recover control instead of creating
another slice.

## Validation

This is a docs-only control recovery change. Validation for this PR is limited
to markdown diff hygiene and repository governance checks; code tests are not
required unless later edits touch executable, spec, schema, runtime, CI,
release, catalog, rate-card, or production-affecting paths.
