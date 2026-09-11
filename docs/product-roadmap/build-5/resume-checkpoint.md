# Product Build 5 resumption checkpoint

Date: 2026-09-11

Checkpoint revision: `build5-checkpoint-r5`

Branch: `codex/product-build-5-assessment`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

R4 review commit: `0608cbb629db2f9ab85bea74444a70368dbed3be`

## Scope and state

Product Build 5 remains assessment-only. No runtime, scheduler, package,
configuration, conformance, deployment, release, or production-enablement code
changed. No hardware was purchased or provisioned, and no model, prompt,
credential, private data, or operator secret was transmitted.

The independent R4 GPT-5.6 Sol review failed with 0 Critical, 2 High, 3
Medium, and 0 Low findings. R5 corrects all five without reducing an acceptance
threshold. R5 remains a candidate until a fresh independent GPT-5.6 Sol review
of the exact committed revision reports zero Critical, High, and Medium
findings.

## R5 candidate artifact digests

| Artifact | Revision | SHA-256 |
|---|---|---|
| `current-state-evidence.md` | `build5-evidence-r5` | `cd070f8cae3f9507b53bfba0faf351ca60c98e1b2976ebe61e9b782d91705c0d` |
| `feasibility-assessment.md` | `build5-assessment-r5` | `3418a419ea2123cd2196078e2c6fc9e2c51be405bfa65ed53e53607656bfbb60` |
| `test-benchmark-spec.md` | `build5-benchmark-r5` | `1d437557b9f05ccd03bab44183bcd08160f1010d5a4fd9d45f4e425bb4b564d5` |
| `reviews/assessment-r4-sol.md` | failed independent R4 gate | `21399619f980cb5964d6fd2e98472b32fe9f9f6a815d2277985083b8540bef8e` |
| `reviews/assessment-r4-dispositions-r5.md` | R5 corrections | `9314bd85f727a77a9a5b4d5855a8ee1674acb2b819011bf74b610137776a1f38` |
| `evidence/real-mlx-3b-exploratory-r3.log` | unchanged exploratory real MLX | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |

The fresh reviewer must recompute every digest from the committed tree. If a
digest differs, the gate fails until the checkpoint and frozen inputs agree.

## R5 corrections

- Added an a priori pre-calibration manifest with analytical full-pool KV,
  maximum-live static allocation ledger, fixed bootstrap reserves and
  allowance, staged 25/50/75% ramps, and a fail-closed process hard-stop proof.
  None of these terms depends on the exact-shape peak they exist to measure.
- Bounded mode epochs across pre-admission, historical accepted-queued, and
  active grants; made the 900-second request deadline queue-inclusive; and
  bounded waiter disposition to 900 seconds and old accepted-work
  reconciliation to 915 seconds at every legal Entry 110 depth and maximum
  queue. Grant occurs only after quiescence and while the waiter's deadline
  remains.
- Selected a separate inference worker. The controller owns admission and
  durable terminal outcomes; a launchd-owned lifecycle supervisor owns the
  worker PID/process group and observes actual `waitpid` exit, including after
  controller loss. Exit and durable reconciliation are required before lease
  reuse, restart, or generation publication.
- Closed model/runtime/campaign byte authority, static and actual dynamic-load
  closure, and backing-image custody within an explicit local-writer threat
  model without relying on a cooperative advisory lock.
- Fixed cancellation and slow-consumer boundaries down to prefill token/chunk,
  generated-token index, socket buffer/read schedule, queue occupancy, and the
  blocked producer event.
- Made clean starts the statistical decision units. Hierarchical bootstrap
  resamples starts and complete repetitions while preserving all rows and arm
  pairs; request-level intervals cannot promote.

Detailed one-to-one dispositions are in
`reviews/assessment-r4-dispositions-r5.md`.

## Evidence carried forward

The earlier deterministic Swift run passed 73 executable allocator/scheduler
tests while three selected real-model tests skipped; the skips are not passing
evidence. The fresh R3 opt-in real-MLX run passed 1/1 selected test in 5.944
seconds with 40/40 greedy token parity, but it remains exploratory because the
existing harness chooses the first snapshot and inserts zero descriptor hashes.
R5 ran no new implementation or inference tests because it changes only the
assessment documents. `git diff --check` is the required local formatting gate.

## Required next action

1. Commit the R5 documents with the repository Lore protocol.
2. Spawn a fresh read-only GPT-5.6 Sol verifier against the exact commit and
   recomputed inputs.
3. Require structured severity, evidence, consequence, and correction fields;
   revise until Critical, High, and Medium counts are all zero.
4. Keep implementation, enablement, releases, and hardware operations outside
   this assessment branch.

Qualification blockers remain: no merged runtime bridge/shared MLX forward;
no implemented serial/batch arbiter or separate inference worker; pending
SPEC-038 and SPEC-039 conformance; no legal four-row representative host or
verified large artifact; no clean sustained-load window; current non-
authoritative 3B harness; and no protected-toolchain release candidate with
final standalone/Malibu byte identity and updater proof.
