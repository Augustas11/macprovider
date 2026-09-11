# Product Build 5 resumption checkpoint

Date: 2026-09-11

Checkpoint revision: `build5-checkpoint-r4`

Branch: `codex/product-build-5-assessment`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

R3 review commit: `4485efed922bdbbb31801bd8338da7a26070ff59`

## Scope and state

Product Build 5 remains assessment-only. No runtime, scheduler, package,
configuration, conformance, deployment, release, or production-enablement code
changed. No hardware was purchased or provisioned, and no model, prompt,
credential, private data, or operator secret was transmitted.

The independent R3 GPT-5.6 Sol review failed with 0 Critical, 1 High, 3 Medium,
and 0 Low findings. R4 corrects all four without reducing an acceptance
threshold. R4 remains a candidate until a fresh independent GPT-5.6 Sol review
of the exact committed revision reports zero Critical, High, and Medium
findings.

## R4 candidate artifact digests

| Artifact | Revision | SHA-256 |
|---|---|---|
| `current-state-evidence.md` | `build5-evidence-r4` | `0ab34821f52e1c2e56623d29923d1847e67ac56a689f5bd3fa4c194d4c50f0c6` |
| `feasibility-assessment.md` | `build5-assessment-r4` | `e44e9d8ca0e44fc5fc23b152e99833143eb28bce49ca30e7394bde890c426c77` |
| `test-benchmark-spec.md` | `build5-benchmark-r4` | `d527ac9e26f9a83543324d69162a7c15f93135433076d774d0951ec093eeedef` |
| `reviews/assessment-r3-sol.md` | failed independent R3 gate | `a58ae2d50e854221fbba61b9bc5905b8b05b4585d43db7f4e8c5146430134267` |
| `reviews/assessment-r3-dispositions-r4.md` | R4 corrections | `60904cb2307bf0d97d8d65d61701f757461b712c6581eece9697b7bda7c72cf9` |
| `evidence/real-mlx-3b-exploratory-r3.log` | unchanged exploratory real MLX | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |

The fresh reviewer must recompute every digest from the committed tree. If a
digest differs, the gate fails until the checkpoint and frozen inputs agree.

## R4 corrections

- Replaced discretionary memory calibration with five clean starts and five
  exact-shape dry runs, exactly 600 paired loaded-idle samples per start,
  per-start delta subtraction, maximum-across-start aggregation, lifetime
  physical-footprint high-water capture, non-replaceable failed runs, and a
  fail-closed rule for platforms lacking trustworthy high-water evidence.
- Closed the loader's byte authority with a read-only APFS adoption image,
  exhaustive file and transitive shard closure, tokenizer/config/code,
  executable/metallib/dependency/runtime-selection identity, and mandatory
  pre/post mutation recapture.
- Made the TTFT reference, slow-consumer, cancellation, warm-swap, whole-batch
  failure, and row-extension failure cells reproducible through exact counts,
  shapes, schedules, injection points, and deadlines. Restored the MSB-01
  aggregate-TG CV <=10% stability gate.
- Added bounded arbiter liveness: fixed forward/request/cancellation/handoff/
  drain/fence/healthy-grant/total-disposition deadlines, atomic admission
  preemption, generation failure and worker fencing on overrun, and tests for
  no lease reuse, late output, or unsafe publication.

Detailed one-to-one dispositions are in
`reviews/assessment-r3-dispositions-r4.md`.

## Evidence carried forward

The earlier deterministic Swift run passed 73 executable allocator/scheduler
tests while three selected real-model tests skipped; the skips are not passing
evidence. The fresh R3 opt-in real-MLX run passed 1/1 selected test in 5.944
seconds with 40/40 greedy token parity, but it remains exploratory because the
existing harness chooses the first snapshot and inserts zero descriptor hashes.
R4 ran no new implementation or inference tests because it changes only the
assessment documents. `git diff --check` is the required local formatting gate.

## Required next action

1. Replace the pending digest placeholders with exact final file hashes.
2. Commit the R4 documents with the repository Lore protocol.
3. Spawn a fresh read-only GPT-5.6 Sol verifier against the exact commit and
   recomputed inputs.
4. Require structured severity, evidence, consequence, and correction fields;
   revise until Critical, High, and Medium counts are all zero.
5. Keep implementation, enablement, releases, and hardware operations outside
   this assessment branch.

Qualification blockers remain: no merged runtime bridge/shared MLX forward;
no implemented serial/batch arbiter; pending SPEC-038 and SPEC-039 conformance;
no legal four-row representative host or verified large artifact; no clean
sustained-load window; current non-authoritative 3B harness; and no protected-
toolchain release candidate with final standalone/Malibu byte identity and
updater proof.
