# Build 1 single-PR orchestrator workflow v1

Status: active Build 1 Lane A execution overlay
Date: 2026-09-21
Owner intent: stop merging one Build 1 slice at a time. Keep one
orchestrator-owned PR open until the current Build 1 Lane A plan is complete,
then merge once.

## Recovery Amendment - 2026-09-26

`build1-control-recovery-plan-v2.md` is authoritative where it conflicts with
this workflow. PR #1658 is being rebuilt from current `origin/main`; its former
branch head is recovery input, not merge authority. The Llama tuple is
regression-only and must not receive a physical campaign. Execution and final
acceptance use the pinned non-catalog OrcaRouter tuple from v2. Superseded
coordinator commits and stale conformance evidence must not be replayed. A
locally built or unsigned CLI must not connect to the live Malibu coordinator.

## Decision

PR #1658, branch `feat/build1-lane-a-private-prep-record`, becomes the
long-lived Build 1 Lane A execution PR. The private preparation-state record is
now an internal milestone inside that PR, not the final merge boundary.

All remaining Lane A implementation work should land on the same branch and PR
unless the owner explicitly changes this workflow. Do not create one PR per
remaining blocker.

## Authority

The active Build 1 target remains Lane A from:

- `SPEC-044`
- `narrow-mvp-plan-v6.md`
- `narrow-mvp-test-spec-v6.md`
- `lane-a-executable-provider-path-prd-v1.md`
- `lane-a-executable-provider-path-test-spec-v1.md`
- `build1-control-recovery-plan-v2.md`

This workflow changes PR mechanics only. It does not widen Build 1 scope and
does not authorize production activation.

## Orchestrator Contract

One orchestrator session owns the Build 1 Lane A PR until the final stop
condition is met or the owner replaces this workflow.

The orchestrator must:

- Keep work on PR #1658 unless the owner explicitly requests a new PR.
- Maintain one current task queue mapped to the remaining Lane A blockers.
- Delegate bounded implementation tasks to Claude through `omx ask`.
- Review executor output before committing or pushing.
- Update this PR, issue #1642, and the control ledger after internal
  milestones.
- Keep the no-production boundary explicit in every handoff.
- Stop merge attempts immediately if the owner says pause.

The orchestrator must not:

- Merge #1658 before the full Lane A stop condition and owner greenlight.
- Split a remaining Lane A blocker into a separate PR by default.
- Allow an executor to expand scope into Lane B, production activation,
  rewards, payouts, public earnings, or general BYOM.
- Treat green CI for an internal milestone as Build 1 acceptance.

## Executor Contract

Executor sessions are bounded implementation helpers. The preferred executor is
Claude Fable 5.1 through `omx ask claude`. The generic dispatch form supported
by local `omx ask --help` is:

```bash
omx ask claude -p "<executor prompt>"
```

If the local Claude/OMX installation requires a separate model selector for
Fable 5.1, the orchestrator must set that selector in the local invocation or
environment before dispatch and record the exact command form in the milestone
note. Do not invent a CLI flag in checked-in instructions.

Executors may edit only the files named in their prompt. They must return a
summary, tests run, known gaps, and any scope pressure. They must not merge,
create new PRs, touch production settings, handle secrets, or push unless the
orchestrator explicitly delegates that narrow action.

## Internal Milestone Queue

Milestones stay inside PR #1658:

1. Private preparation-state record after durable adoption.
   - Status: implemented in PR #1658 before this overlay.
   - Merge status: do not merge as a standalone slice.
2. Serve/status evidence correlation.
   - Status: implemented in PR #1658 as an internal milestone.
   - Correlate local `GET /v1/status` `model_hash` and
     `weights_manifest_sha256` with the durable Lane A artifact, configured
     release, and private published-inventory receipt.
   - Do not claim descriptor-pinned runtime load custody until a later
     implementation actually provides it.
   - Preserve public v1 `models catalog-economics --json` compatibility until
     Lane B.
3. Measured artifact-bound staging input.
   - Status: implemented in PR #1658 as an internal milestone (consumer side);
     operator-local lab feed production is now in progress in the same PR.
   - `macprovider-cli models staging-input <catalog-key> --profile
     build1-lane-a --coordinator-url <staging> --json [--config <yaml>]
     [--status-capture <status.json>]` emits one
     `build1_lane_a_staging_input.v1` object that ties the signed staging
     artifact authority (measured `size_bytes`, trusted signer, release
     binding), the private published-inventory receipt for the adopted
     artifact, and the local `GET /v1/status` Lane A evidence into one
     handoff. It is `staging_input_ready` only when all three agree on tuple,
     release, digest, declared size, and private record; otherwise it is
     `blocked` with explicit blocker codes and exit 2. It is read-only: it
     never bootstraps private state, transfers bytes, or touches the active
     model.
   - Operator-local loopback feed production must measure every published
     primary artifact from real artifact files or Hugging Face snapshots, sign
     the resulting full feed with the trusted static-feed key, and serve it at
     `/v1/catalog-artifacts` + `.sig` on loopback. It must not publish a
     release, deploy Pearl, or touch production endpoints.
   - Runtime custody stays path-observed
     (`descriptor_pinned_runtime_custody=false`).
   - Dispatch record: the executor for this milestone was Claude Fable 5.1
     via the local Claude CLI invoked with `--model fable`, because local
     `omx ask claude --help` exposes no model selector.
4. Physical Apple Silicon Pearl-network journey.
   - Use the measured loopback feed and `staging_input_ready` object as
     preflight evidence, then run the acceptance proof against the real Pearl
     coordinator/gateway network when Pearl has the BYOM admission and
     verified-settlement path deployed.
   - Start a dedicated Lane A provider on MacStudio without disturbing the
     existing Qwen provider, submit the Lane A offer, perform the operator
     admission sequence through `settlement_capable`, route one non-streaming
     gateway request, and capture provider-side request-id-bearing
     receipt/audit correlation.
   - Use local/mock coordinator or gateway evidence only if Pearl is proven not
     to have the deployed BYOM path, and label that evidence as fallback rather
     than Pearl acceptance.
5. Verified settlement and validator bundle.
   - Retrieve verified settlement output for the physical request and produce a
     schema-valid, redacted evidence bundle.
6. Final full-PR audit and release gate.
   - Run code, security, and architecture review lanes over the complete PR
     diff as it will land.
   - Carry only LOW/INFO findings explicitly.

## Verification Gates

Each internal milestone must include:

- Targeted tests for changed behavior.
- `git diff --check`.
- A control-ledger or PR note explaining what was proved and what remains
  unproved.
- A no-secrets check for any evidence or generated artifacts.
- No production activation, rewards, payouts, public earnings, or automatic
  paid-provider qualification.

The final PR merge gate requires:

- All Lane A blockers in the control ledger resolved or explicitly blocked
  with owner-approved scope.
- Fresh green CI on the final head commit.
- Relevant local Swift, Go, script, or integration tests for the touched
  surfaces.
- Governance validator pass when required by the diff.
- Three independent audit lanes over the full PR diff with 0 CRITICAL, 0 HIGH,
  and 0 MEDIUM findings.
- Issue #1642 updated with final evidence links.
- Explicit owner greenlight to merge.

## Pause And Recovery

If the owner says pause, stop watchers and merge paths. Pushing docs or code is
allowed only when it preserves already-requested work and does not move the PR
toward merge without approval.

If CI fails, keep the fix in PR #1658 and diagnose from the failing check. Do
not create a new PR unless the owner explicitly chooses to split the work.

If executor work conflicts with current branch state, the orchestrator resolves
the conflict locally, reruns the smallest useful tests, and records the
resolution. If the conflict changes the Build 1 scope or proof boundary, stop
and ask the owner one concrete question.

## Executor Prompt Template

Use this template for each bounded Claude/Fable executor dispatch:

```text
You are the bounded executor for MacProvider Build 1 Lane A in PR #1658.

Worktree: /Users/augstar/.codex/worktrees/macprovider/build1-lane-a-private-record
Branch: feat/build1-lane-a-private-prep-record
Tracker: https://github.com/Augustas11/macprovider/issues/1642
PR: https://github.com/Augustas11/macprovider/pull/1658

Read AGENTS.md, CLAUDE.md, docs/product-roadmap/build-1/build1-control-recovery-plan-v2.md,
docs/product-roadmap/build-1/build1-single-pr-orchestrator-workflow-v1.md,
docs/product-roadmap/build-1/narrow-mvp-plan-v6.md,
docs/product-roadmap/build-1/narrow-mvp-test-spec-v6.md,
docs/product-roadmap/build-1/lane-a-executable-provider-path-prd-v1.md,
and docs/product-roadmap/build-1/lane-a-executable-provider-path-test-spec-v1.md
before editing.

Milestone scope:
<one named milestone and exact files/surfaces allowed>

Rules:
- Keep all work inside PR #1658; do not create another branch or PR.
- Do not merge, admin-merge, or bypass branch protection.
- Preserve the no-production-activation boundary: no release publication,
  payout/reward enablement, public earnings claim, or automatic paid-provider
  qualification. Any Pearl admission used for the proof must be temporary,
  auditable, scoped to Lane A, and cleaned up or withdrawn after evidence
  capture.
- Do not touch secrets or operator key material.
- Treat Lane A's exact Llama 3B tuple as regression-only and do not run it on
  physical hardware. Use the pinned OrcaRouter tuple only when the orchestrator
  assigns the M2/M3 milestone from the v2 recovery plan.
- Use existing repo patterns and targeted tests.
- Return a summary, changed files, tests run, remaining risks, and any scope
  pressure. If you push or commit, report the exact commit SHA.
```

## Stop Condition

This workflow is complete only when Build 1 Lane A has a physical
validator-accepted Pearl-network evidence bundle for the selected tuple, or an
explicitly labeled local/mock fallback bundle if Pearl is proven to lack the
deployed BYOM path; final full PR audits pass; CI is green on the final head;
#1642 is updated; and the owner explicitly greenlights merging #1658.
