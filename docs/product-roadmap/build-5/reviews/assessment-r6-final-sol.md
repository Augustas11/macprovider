# Product Build 5 assessment R6 final independent revalidation

Date: 2026-09-11

Reviewer lane: independent GPT-5.6 Sol, high reasoning

Reviewed commit: `d7448054510a2d569fb6c7038d7c1e5b9d14d84d`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

Scope: final adversarial revalidation of the assessment and test plan after
documentation-byte normalization. This review authorizes no throughput-engine
implementation, scheduler activation, production traffic, hardware purchase or
provisioning, remote transfer, release, or economic action.

## Frozen current inputs

| Artifact | SHA-256 |
|---|---|
| `reviews/artifact-normalization-r7.md` | `5c1340a26777675f71e6478f728b4b90b02eec439d9875478a085545ec1bd549` |
| `reviews/assessment-r6-sol.md` | `1297879bae5fad1ba5783d01d65d58ae6e25449489c07b3ecadec8cb18f2128f` |
| `feasibility-assessment.md` | `d25b4cf9e4a4afa8e90e74c5fceabfc980b09536c02714b9a9ee6be866758993` |
| `test-benchmark-spec.md` | `3f52dc8802c0883fb06d3839b85bc7cd987473cb9039dc3a1a0fc49d6d22746c` |
| `current-state-evidence.md` | `141eccae93d374f54ae3fb95338d8202c5cd6504a34da61608e9411709851a51` |
| `resume-checkpoint.md` | `6553a93894465d31c12449160debaa0d295bfa0b05d3bf3486532189314ced86` |
| `reviews/assessment-r5-sol.md` | `0b90f8d254790b18f38a9f00c33666e7a3c266127af049609688c605e17574b9` |
| `reviews/assessment-r5-dispositions-r6.md` | `a1c7eb9ea79e1f2580ad815376ea632458ebee501775ed4e4bcaa26f2ec14991` |
| `evidence/real-mlx-3b-exploratory-r3.log` | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |

Every current digest above was recomputed from the reviewed commit.

## Normalization-chain verification

The normalization record contains six previous/current artifact pairs. I
independently hashed the parent-commit bytes and the normalized current bytes
for all six pairs. I then independently hashed the normalization record and the
current R6 review against the two externally supplied expected digests.

Result: **14 of 14 hash assertions matched**.

| Artifact | Parent digest matched | Current digest matched |
|---|---:|---:|
| `assessment-r4-sol.md` | Yes | Yes |
| `assessment-r4-dispositions-r5.md` | Yes | Yes |
| `assessment-r5-sol.md` | Yes | Yes |
| `assessment-r5-dispositions-r6.md` | Yes | Yes |
| `resume-checkpoint.md` | Yes | Yes |
| `assessment-r6-sol.md` | Yes | Yes |

The remaining two assertions were the normalization record itself and the
current R6 review; both matched. The commit removes exactly one trailing blank
line from `assessment-r4-sol.md`. Its other edits update the transitive hashes
and replace claims that the current bytes were reviewed with accurate statements
that the normalized bytes required this revalidation. No finding, disposition,
threshold, test result, qualification state, claim boundary, or implementation
authorization changed.

## Independent code and governance inspection

The complete `origin/main...d7448054` diff contains fifteen files and all are
under `docs/product-roadmap/build-5/`. It contains no runtime, test, build,
configuration, schema, conformance, release, or deployment change. The merge
base and current `origin/main` both resolve to the stated source base.

The assessment's merged-source classification remains accurate:

- `ModelRuntime.continuousBatchingCapability` supplies no requested runtime
  tuple and calls policy with `schedulerBackendAvailable: false`.
- `ModelRuntime.enforcePagedKVPreflight` rejects an `.attached` decision with a
  pre-inference, pre-settlement 503 until a lifecycle owner injects the cache.
- Nonstreaming and streaming generation continue through independent
  `TokenIterator` construction under the existing `inferenceGate`; there is no
  production shared-forward bridge or resident-model serial/batch arbiter.
- `AutotuneRecommendHardware.recommendedMaxBatch` still maps a base chip to one
  row, Max with at least 48 GiB to two rows, Ultra with at least 96 GiB to three
  rows, and Ultra with at least 128 GiB to four rows.
- `CONFORMANCE.json` still records SPEC-038 and SPEC-039 as
  `pending-reconciliation` and `not-deployed`; the SPEC-039 requirement records
  remain pending.

The local platform contracts used by the future test design were also checked.
`launchd.plist(5)` says launchd kills remaining processes with the dead job's
process-group ID unless `AbandonProcessGroup` is true. The installed dyld header
says add-image callbacks run after an image is loaded and bound but before its
initializers. These facts support the proposed design boundary; the plan still
requires the launcher, profile, sandbox, IPC, and failure behavior to be built
and proved before qualification.

## Adversarial review of the zero-finding logic

I re-evaluated the six R5 findings against the current primary assessment and
test specification rather than inheriting the prior R6 verdict.

1. **Darwin hard-stop authority:** `RLIMIT_AS` and `RLIMIT_RSS` are diagnostic
   only. Target-shaped runs cannot promote until an independently reviewed
   exact-OS mechanism synchronously bounds every CPU and forced-synchronous
   Metal committed-memory path. Preload, pre-calibration, ramps, pressure
   observation, and worker termination remain separate fail-closed defenses.
2. **Supervisor loss:** normal and controller-loss paths retain parent
   `waitpid`; supervisor loss instead closes admission, durably orphans every
   unresolved accepted request, attempts exact launchd-job termination, and
   forbids same-boot restart, lease reuse, and publication regardless of later
   empty-group observation. The plan no longer claims impossible orphan
   `waitpid` evidence.
3. **Allocation overlap:** one event-indexed maximum-live ledger covers
   adoption, mapping, conversion, load, warm-up, serving, drain, and unload. It
   charges simultaneous source, expanded, temporary, runtime, command, cache,
   KV, activation, logits, and output lifetimes, with explicit replacement
   edges and fail-closed unknowns.
4. **Disturbance counts:** deterministic open-loop saturation is separated from
   event-driven real-runtime campaigns. An independent state-machine
   reconstruction reproduced `SATURATION-ORACLE-R1`: depths one through four
   accept and terminate `62/124/186/248` requests and reject
   `538/476/414/352`, with 600 sent in every cell. Cancellation promotion uses
   1,000 actual boundary-reached observations per subcell rather than request
   indices or attempted arrivals.
5. **Statistical authority:** matched clean-start hierarchical intervals use
   50,000 fixed-seed resamples and preserve batch rows. Lower bounds govern
   uplift; upper bounds govern latency, variability, footprint, and recovery.
   Exact invariants and per-observation deadlines must pass independently of
   confidence intervals.
6. **Pre-runtime capture:** a minimal protected Apple-platform-only launcher is
   an explicit implementation and release prerequisite. Static closure,
   callback ordering, synchronous sequenced evidence, backpressure, loss,
   reentrancy, early constructors, signing, packaging, and updater behavior all
   have defined negative gates. The assessment makes no claim that this
   launcher exists today.

The wider plan retains the required evidence separation: deterministic
scheduler/allocator fixtures, simulated memory tests, small-model real MLX,
protected release integration, representative hardware, and production
activation remain distinct. The recorded 73 deterministic tests and one 3B
real-MLX run are earlier evidence and were not rerun for this documentation-only
review. The three skipped parity tests remain skips. The 3B run remains
exploratory because the harness does not deterministically select the snapshot
or bind authoritative nonzero descriptor hashes.

## Verdict

**PASS -- the normalized R6 assessment and future test plan are approved.**

Finding counts: **0 Critical, 0 High, 0 Medium, 0 Low**.

This approval is assessment-only. Paged KV and continuous batching remain
disabled. No target model/hardware tuple, capacity or performance claim,
protected release, remote-hardware path, or production rollout is qualified.
Representative capacity remains blocked on the exact artifact/runtime/OS/
hardware tuple, legal Entry 110 depth, accepted SPEC-038/SPEC-039 conformance,
the protected audit launcher and process topology, an independently reviewed
synchronous CPU/Metal memory cap, predeclared benchmark gates, and a separate
activation decision.

## Fresh verification

The following checks were run against the reviewed commit:

```text
git rev-parse HEAD
git merge-base origin/main HEAD
git diff --name-status origin/main...HEAD
git diff --check origin/main...HEAD
git diff --word-diff=porcelain HEAD^..HEAD -- <six normalized artifacts>
shasum -a 256 <current Build 5 artifacts>
git show HEAD^:<normalized artifact> | shasum -a 256
```

All completed successfully. The full branch diff is documentation-only,
`git diff --check` produced no error, and the worktree was clean before this
review artifact was added. No implementation, inference, release, deployed-
service, or representative-hardware test was run or implied by this final
normalization gate.
