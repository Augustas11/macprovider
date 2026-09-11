# Product Build 5 resumption checkpoint

Date: 2026-09-11

Checkpoint revision: `build5-checkpoint-r6`

Branch: `codex/product-build-5-assessment`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

R5 review commit: `11a772342d808ea168f66da0ad35d29fa4c3fa2d`

## Scope and state

Product Build 5 remains assessment-only. No runtime, scheduler, package,
configuration, conformance, deployment, release, or production-enablement code
changed. No hardware was purchased or provisioned, and no model, prompt,
credential, private data, or operator secret was transmitted.

The independent R5 GPT-5.6 Sol review failed with 0 Critical, 3 High, 3
Medium, and 0 Low findings. R6 corrects all six without reducing an acceptance
threshold. R6 remains a candidate until a fresh independent GPT-5.6 Sol review
of the exact committed revision reports zero Critical, High, and Medium
findings.

## R6 candidate artifact digests

| Artifact | Revision | SHA-256 |
|---|---|---|
| `current-state-evidence.md` | `build5-evidence-r6` | `141eccae93d374f54ae3fb95338d8202c5cd6504a34da61608e9411709851a51` |
| `feasibility-assessment.md` | `build5-assessment-r6` | `d25b4cf9e4a4afa8e90e74c5fceabfc980b09536c02714b9a9ee6be866758993` |
| `test-benchmark-spec.md` | `build5-benchmark-r6` | `3f52dc8802c0883fb06d3839b85bc7cd987473cb9039dc3a1a0fc49d6d22746c` |
| `reviews/assessment-r5-sol.md` | failed independent R5 gate | `f4e78200c06a6ef54773d2e0b9e05d861dbcaa07eda9118f5d02e08a178ff2b0` |
| `reviews/assessment-r5-dispositions-r6.md` | R6 corrections | `26153941e241f53de28a88b3dee9c5deb2a50ea3820c91d217a4846ed09c0b66` |
| `evidence/real-mlx-3b-exploratory-r3.log` | unchanged exploratory real MLX | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |

The fresh reviewer must recompute every digest from the committed tree. If a
digest differs, the gate fails until the checkpoint and frozen inputs agree.

## R6 corrections

- Removed Darwin `RLIMIT_AS` from memory-cap authority. A-priori ledgers govern
  admission; asynchronous footprint/pressure observation and worker kill are
  measured damage containment. Target-shaped runs remain non-promoting until an
  independently reviewed exact-OS mechanism synchronously covers every CPU and
  forced-Metal committed-memory path.
- Defined one executable supervisor-loss outcome. The normal/controller-loss
  path retains parent `waitpid`. Supervisor loss is detected within 250 ms,
  unresolved work is durably marked `generation_orphaned`, launchd group
  termination is attempted, and same-boot restart/reuse/publication is
  unconditionally forbidden until the boot UUID changes.
- Replaced `max(stored, expanded)` with one event-indexed maximum-live ledger
  spanning adoption through unload. It separately charges stored mappings,
  expanded tensors, conversion/decompression temporaries, duplicate/tied
  weights, runtime/staging/commands/caches, KV, activations, and outputs, with a
  manifest-bound replacement edge when measured loaded idle supersedes covered
  analytical resident rows.
- Split deterministic open-loop saturation from real boundary evidence. The
  600-arrival oracle freezes exact accepted/rejected/terminal counts for Entry
  110 depths one through four. Closed-loop cancellation, slow-consumer, and
  warm-swap cells advance only from funded lease/queue and exact boundary
  events; each cancellation boundary has 1,000 observations across ten starts.
- Made matched-start hierarchical confidence intervals decision-authoritative.
  Lower bounds govern uplifts; upper bounds govern latency, variability,
  footprint, and recovery. Exact invariants and maxima must pass every sample
  and cannot be rescued by an interval.
- Added an explicit protected pre-runtime loader blocker and candidate audit
  boundary. A minimal Apple-only launcher must install capture before loading
  any non-platform Swift/MLX/inference bytes, synchronously persist sequenced
  events, and pass early-constructor, backpressure, loss, hardened-runtime, and
  dual-package tests. Static closure or post-main callbacks alone cannot
  qualify.

Detailed one-to-one dispositions are in
`reviews/assessment-r5-dispositions-r6.md`.

## Evidence carried forward

The earlier deterministic Swift run passed 73 executable allocator/scheduler
tests while three selected real-model tests skipped; the skips are not passing
evidence. The fresh R3 opt-in real-MLX run passed 1/1 selected test in 5.944
seconds with 40/40 greedy-token parity, but it remains exploratory because the
existing harness chooses the first snapshot and inserts zero descriptor hashes.
R6 ran no new implementation, inference, release, or hardware test because it
changes only the assessment documents. `git diff --check` is the local
formatting gate.

## Required next action

1. Commit the R6 documents with the repository Lore protocol.
2. Spawn a fresh read-only GPT-5.6 Sol verifier against the exact commit and
   recomputed inputs.
3. Require structured severity, evidence, consequence, and correction fields;
   revise until Critical, High, and Medium counts are all zero.
4. Keep implementation, enablement, releases, remote execution, and hardware
   operations outside this assessment branch.

Qualification blockers remain: no merged runtime bridge/shared MLX forward; no
implemented serial/batch arbiter or separate inference worker; pending SPEC-038
and SPEC-039 conformance; no protected pre-runtime audit launcher; no
synchronous Darwin CPU/Metal memory cap and therefore no promotable target-
shape run; no legal four-row representative host or verified large artifact; no
clean sustained-load window; current non-authoritative 3B harness; and no
protected-toolchain release candidate with final standalone/Malibu byte identity
and updater proof.
