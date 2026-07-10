# IMPL audit prompt — SPEC-015 v0.3 IMPL Step 6 (integration acceptance + cross-binary parity)

Audit Step 6 — the v0.3 integration acceptance gate + operator runbook.
Output: APPEND to `specs/SPEC-015-v0-3-IMPL-STEP_6-audit.md`. Three
lenses. VERDICT + COUNTS per lens.

User policy: 0 CRITICAL + 0 HIGH + 0 MEDIUM target.

## What landed in Step 6

- `test/integration/spec015/v03_acceptance_manifest_test.go` — extends
  the existing acceptance manifest with the 15 v0.3 ACs (AC-28..AC-42)
  plus AC-32a. Each AC names a runnable command, the CI job, and at
  least 2 evidence anchors (file + grep pattern). The manifest test
  asserts every named pattern exists in the named file.
- `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md` — operator-
  facing deploy runbook covering pre-deploy checklist, coordinator
  binary + nginx + config, smoke-checks for `/poolz` + `/catalog/...`,
  provider/buyer rollout choreography (cv0.2 verifier reads v0.3 as
  invalid per §M.1.2), monitoring, rollback, Entry 80 invariant
  preservation, and v0.4+ deferred candidates.

## Severity definitions

- **CRITICAL** — locked-spec edit; AC manifest claims coverage of an
  AC that the cited evidence does not actually establish (e.g. evidence
  anchor points at a file that doesn't run the right test); operator
  runbook telling the operator to flip Entry 80 `RequireHashVerified`;
  runbook telling the operator to ship the provider binary before the
  verifier binary (§M.1.2 forward-incompat would silently break buyers).
- **HIGH** — v0.3 AC manifest entry missing a runnable command, a CI
  job mapping, or evidence anchors; runbook step that doesn't compose
  with the v0.2 deploy script; missing rollback path for a new
  surface (e.g. /catalog/ endpoint).
- **MEDIUM** — manifest text wording errors; runbook gaps in monitoring
  / Pearl journald grep lines; missing reference to the v0.3 SPEC
  section for each AC.
- **LOW** — polish.

## Constraints

1. SPEC-015 v0.3.3 LOCKED — no SPEC changes.
2. No locked-spec line-3 shifts.
3. Entry 80 (`RequireHashVerified` deferral) MUST be preserved
   verbatim. v0.3 IMPL does NOT flip the flag.
4. The v0.3 IMPL is COMPLETE in terms of code surfaces; Step 6 is
   acceptance + handoff to operator + future v0.4 staging.

## Required reading

1. `specs/SPEC-015-receipts.md` §M.5 (AC-28..AC-42), §M.6 (deferred
   items including Entry 80 preservation), §M.4 (catalog surface).
2. `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` Step 6 +
   final deliverables list.
3. `test/integration/spec015/v03_acceptance_manifest_test.go` —
   the new manifest.
4. `test/integration/spec015/acceptance_manifest_test.go` — v0.2
   pattern to compare against.
5. `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md` — the
   runbook.
6. `phase4-coordinator/dist/deploy-pearl-vps.sh` — current
   deploy script (does the runbook compose with it?).
7. `beta/DECISION_CRITERIA.md` Entry 80 — verify the runbook
   preserves it verbatim.
8. The Step 1-5 audit transcripts at
   `specs/SPEC-015-v0-3-IMPL-STEP_{1..5}-audit.md`.

## Categories

CODE  C.1 v0.3 AC manifest covers exactly AC-28 through AC-42 +
          AC-32a (16 ACs total).
      C.2 Each AC has runnable command + CI job + evidence anchors.
      C.3 Every evidence pattern actually exists in the named file
          (manifest test asserts this).
      C.4 Manifest test compiles AND runs `t.Run(AC-NN)` for each.

SECURITY  S.1 Runbook does NOT recommend flipping
              `RequireHashVerified` (Entry 80 preservation).
          S.2 Runbook orders verifier release BEFORE provider
              binary distribution per §M.1.2 forward-incompat.
          S.3 Smoke-check commands do not leak secrets (operator
              key handling).
          S.4 Rollback path is documented.

ARCHITECT  A.1 Build prompt Step 6 coverage.
           A.2 No locked-spec line-3 shifts (existing audit gates
               this; verify the v0.3 IMPL bundle does not regress).
           A.3 v0.4+ candidate list matches §M.6 deferred items.
           A.4 README.md update plan documented in runbook.
           A.5 Composition with M3-2 / Entry 80 / Entry 84
               (the SPEC v0.3 LOCK entry) — no contradictions.

Each finding cites file:line. End each lens with VERDICT + COUNTS.
