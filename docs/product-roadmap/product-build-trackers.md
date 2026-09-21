# Product build tracker index

Date: 2026-09-20
Base: `origin/main` at `12de7aea`
Status: active coordination index

## Purpose

This index gives product-build agents one GitHub tracker per build before they
open new slices. It does not authorize implementation, production activation,
reward activation, payout activation, or any bypass of the build-specific gates
below.

Future sessions should update the matching issue first when they change build
scope, land a control document, or close a blocking PR. If a newer merged
control ledger contradicts this file, the newer ledger wins and this file
should be updated in a small docs-only follow-up.

## Tracker issues

| Build | Tracker | Current control surface | Stop condition |
| --- | --- | --- | --- |
| Build 1 | [#1642](https://github.com/Augustas11/macprovider/issues/1642) | `docs/product-roadmap/build-1/build1-control-recovery-plan-v1.md`, `narrow-mvp-plan-v6.md`, `lane-a-executable-provider-path-prd-v1.md` | Lane A physical Apple Silicon staging evidence bundle proves prepare, serve, admission, gateway request, receipt/audit correlation, and verified settlement with production disabled. |
| Build 2 | [#1643](https://github.com/Augustas11/macprovider/issues/1643) | `origin/codex/product-build-2`; latest observed `docs/product-roadmap/build-2/prd-implementation-plan-r8.md` and `test-spec-r8.md` | Exact Build 2 authority/test docs pass independent review and merge before implementation begins. |
| Build 3 | [#1644](https://github.com/Augustas11/macprovider/issues/1644) | Draft PR [#1473](https://github.com/Augustas11/macprovider/pull/1473), `origin/codex/product-build-3` | Accepted compute-observation gate docs merge; product work still waits for collector, calibration, evidence-bundle, release, and qualification gates. |
| Build 4 | [#1645](https://github.com/Augustas11/macprovider/issues/1645) | Draft PR [#1471](https://github.com/Augustas11/macprovider/pull/1471), `origin/codex/product-build-4` | Accepted Trusted Pool private-settlement gate docs merge; runtime remains blocked on accepted Build 2 and Build 3 contracts. |
| Build 5 | [#1646](https://github.com/Augustas11/macprovider/issues/1646) | Draft PR [#1472](https://github.com/Augustas11/macprovider/pull/1472), `origin/codex/product-build-5-assessment` | Accepted feasibility/benchmark gates merge; runtime activation remains blocked on exact tuple qualification and separate enable decision. |

## Active boundaries

- Build 1 continues on Lane A unless the owner explicitly chooses Lane B or
  Lane C. Old local Build 1 branches are not active authority and must not be
  merged wholesale.
- Build 2 has pushed planning work but no open PR at the time this index was
  created. Use issue #1643 to decide whether to open a fresh PR, supersede the
  branch, or reduce the plan to a smaller gate.
- Builds 3, 4, and 5 already have draft PRs. Their tracker issues should hold
  cross-session status and dependency decisions; the PRs remain the code-review
  surfaces for the current docs.
- No tracker issue, checklist, validator report, fixture test, or planning PR
  can substitute for the physical, release, hardware, or settlement evidence
  required by the relevant build.

## Agent handoff rule

Before starting product-build work, an agent must:

1. Open the build's tracker issue.
2. Read the current control surface named in the table.
3. State the selected build, lane or gate, proof boundary, and stop condition in
   the PR body or handoff.
4. Preserve any no-production, no-rewards, no-payout, no-public-earnings, and
   no-capacity-advertisement boundary unless the owner explicitly changes that
   boundary in the same session.
