# Product Build 5 assessment R6 independent adversarial review

Date: 2026-09-11

Reviewer lane: independent GPT-5.6 Sol, high reasoning

Reviewed commit: `d7e63a6c615f5ac46b483dc0a840413065ff79b5`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

Scope: assessment and planning only. This review authorizes no throughput-engine
implementation, scheduler activation, production traffic, hardware procurement,
remote transfer, release, or economic action.

## Frozen inputs

| Artifact | SHA-256 |
|---|---|
| `feasibility-assessment.md` | `d25b4cf9e4a4afa8e90e74c5fceabfc980b09536c02714b9a9ee6be866758993` |
| `test-benchmark-spec.md` | `3f52dc8802c0883fb06d3839b85bc7cd987473cb9039dc3a1a0fc49d6d22746c` |
| `current-state-evidence.md` | `141eccae93d374f54ae3fb95338d8202c5cd6504a34da61608e9411709851a51` |
| `assessment-r5-sol.md` | `0b90f8d254790b18f38a9f00c33666e7a3c266127af049609688c605e17574b9` |
| `assessment-r5-dispositions-r6.md` | `a1c7eb9ea79e1f2580ad815376ea632458ebee501775ed4e4bcaa26f2ec14991` |
| `resume-checkpoint.md` | `6553a93894465d31c12449160debaa0d295bfa0b05d3bf3486532189314ced86` |
| `real-mlx-3b-exploratory-r3.log` | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |

At the original review, all seven then-recorded digests matched the reviewed
commit. The frozen-input table now records the normalized current bytes described
in `artifact-normalization-r7.md`; those bytes require fresh independent
revalidation. The reviewed commit and its source base were present, `origin/main`
and the merge base both resolved to the stated source base, and the worktree was
clean before this review artifact was added. The branch changes only durable
Build 5 assessment artifacts relative to that base.

## Independent inspection

The review independently inspected the current source and governance state:

- `ModelRuntime.continuousBatchingCapability` still supplies no requested tuple
  and passes `schedulerBackendAvailable: false`;
- `ModelRuntime.enforcePagedKVPreflight` still rejects an attached paged-KV
  decision because no lifecycle owner injects the cache and owns its handles;
- serving still uses the existing `AsyncSemaphore` and independent
  `TokenIterator` path;
- `AutotuneRecommendHardware.recommendedMaxBatch` still returns one for base
  chips, two for Max with at least 48 GiB, three for Ultra with at least 96 GiB,
  and four for Ultra with at least 128 GiB;
- `CONFORMANCE.json` records both SPEC-038 and SPEC-039 as draft,
  `pending-reconciliation`, and `not-deployed`; and
- the local `launchd.plist(5)` contract says launchd kills remaining processes
  in a dead job's process group unless `AbandonProcessGroup` is true. The local
  dyld header confirms add-image callbacks run after an image is loaded and
  bound but before its initializers, supporting the proposed launcher's narrow
  pre-runtime ordering claim.

No implementation, release, inference, or hardware test was rerun for this
documentation-only gate. As a fresh specification check, an independent state-
machine reconstruction reproduced the frozen `SATURATION-ORACLE-R1` totals for
Entry 110 depths one through four: accepted/terminal `62/124/186/248` and
rejected `538/476/414/352`, with 600 sent in every case. `git diff --check
HEAD^..HEAD` passed for the R6 correction commit. The recorded 73 deterministic
tests and one real-MLX 3B run remain earlier evidence with the limitations R6
states.

## Verdict

**PASS -- R6 is approved as the Product Build 5 assessment and future test plan.**

Finding counts: **0 Critical, 0 High, 0 Medium, 0 Low**.

The approval is deliberately narrow. It does not approve implementation, prove
the proposed launcher or process topology, qualify any model/hardware tuple, or
authorize a target-shaped promotion run. Those remain future evidence gates.

## R5 finding resolution

| Prior finding | R6 evidence | Result |
|---|---|---|
| H1 unproved `RLIMIT_AS` hard stop | `feasibility-assessment.md:206-218`, `test-benchmark-spec.md:681-687`, `:725-744`, and `:765-768` remove `RLIMIT_AS` from cap, admission, and promotion authority. Watcher evidence is explicitly asynchronous damage containment. Promotion remains blocked until a separately reviewed exact-OS mechanism covers every CPU and forced-synchronous Metal committed-memory path. Optional allocator probes can prove only the tested path and retain unlimited, below-limit, cumulative-crossing, synchronized-Metal, reason-code, and clean-start controls. | Closed without weakening the a-priori ledgers, ramps, pressure checks, or termination evidence. |
| H2 impossible post-parent `waitpid` | `test-benchmark-spec.md:111-141` freezes the launchd-owned non-escaping process group and boot/session/job/process/generation identity. Supervisor loss closes admission, durably orphans every unresolved accepted ID, attempts exact-job termination, and unconditionally forbids same-boot restart, lease reuse, or publication. `:177-190` requires real-process crash, PID-reuse, withheld-proof, restart, and boot-transition fixtures. Normal/controller-loss paths retain parent `waitpid`; the orphan path does not claim it. | Closed with a conservative, executable fail-closed outcome. Group-empty observation cannot authorize recovery. |
| H3 incomplete preload overlap bound | `test-benchmark-spec.md:647-710` defines an event-indexed maximum-live ledger across adoption, load, warm-up, serving, drain, and unload. It separately charges source residency, compression/conversion temporaries, expanded tensors, tied/duplicate materialization, runtime, staging, commands, cache, KV, activations, logits, and output/IPC, with forced synchronization, explicit coexistence edges, manifest-bound replacement, overflow checks, and fail-closed unknowns. `:229-232` requires negative fixtures for missing sites and wrong edges. | Closed. Neither `max(stored, expanded)` nor a future measured peak is used to admit the first load. |
| M1 nondeterministic disturbance counts | `test-benchmark-spec.md:462-539` separates one deterministic open-loop saturation oracle from lease/queue/event-driven real-runtime boundary campaigns. It freezes sent, accepted, rejected, boundary, acknowledgement, terminal, and reason-code counts; each cancellation boundary supplies exactly 1,000 reached observations over ten starts. The independent reconstruction confirmed all stated saturation totals. | Closed. Sent request indices and arrival rate no longer stand in for accepted or boundary-reached samples. |
| M2 confidence intervals did not govern decisions | `test-benchmark-spec.md:421-455` freezes ten matched clean-start blocks and 50,000 paired hierarchical resamples that retain full batch rows. `:800-852` makes lower bounds authoritative for uplift and upper bounds authoritative for latency, variability, footprint, and recovery. Exact invariants and deadline maxima must pass every observation. | Closed. A favorable point or request-level estimate cannot promote a tuple. |
| M3 unimplemented pre-runtime loader boundary | `test-benchmark-spec.md:281-319` now makes a protected minimal native launcher an explicit prerequisite. Its static closure may contain only Apple sealed platform images; it establishes the evidence channel and dyld capture before loading manifest-bound Swift/MLX/inference code, requires synchronous durable sequence acknowledgement, and fails on loss, backpressure, gaps, reentrancy, or outside loads. `:855-885` binds the launcher, IPC, profile, sandbox, entitlements, signing, packaging, and early-constructor fixture to the protected release gate. | Closed as a named qualification blocker. R6 makes no actual-loader completeness claim until the launcher is implemented and proved. |

## Broader assessment challenge

The prior hardware, workload, and claim boundaries remain adequate:

- The evidence matrix distinguishes analytical, deterministic/simulated,
  small-model MLX, protected integration/release, representative hardware, and
  production activation evidence.
- The current 32 GiB M5 host is limited to Entry 110 depth one for real serving.
  Artificial concurrency is fixture evidence only. Four-row dense MSB-02/03
  qualification requires a same-host Ultra with at least 128 GiB under current
  authority, or a future normative non-serving benchmark mode.
- The model-specific KV arithmetic states its fp16 assumptions, block
  fragmentation, context limits, runtime-transient omissions, and prohibition
  on extrapolating smaller or more heavily quantized results.
- Dense, MoE, and oMLX-oracle arms remain separate; MSB-05 cannot substitute for
  the candidate shared-forward executor. MoE promotion requires exact greedy
  token and terminal/accounting parity.
- Unsupported tools, structured output, logprobs, logit bias, sticky reuse,
  quantized KV, speculative decoding, unadvertised tuples, and unsupported MoE
  surfaces retain serial/reject routing and the single resident-model arbiter.
- Failure recovery forbids stitching visible output across executors, requires
  quiescence and process fencing before reuse, and preserves generation-bound
  request disposition, receipts, and rollback to the default-off serial path.
- Remote hardware remains optional and separately authorized, with public
  artifacts, synthetic prompts, short-lived access, sanitized evidence, and no
  secret or private-data transfer. No purchase or provisioning is authorized.

## Qualification state

Work that can proceed before larger hardware is available is limited to
normative reconciliation, deterministic allocator/scheduler/arbiter work,
failure fixtures, the protected harness and packaging path, and explicitly
non-promoting small-model development evidence. Paged KV and continuous
batching remain disabled.

Representative capacity, large-model memory/performance, target-shaped
promotion on Darwin, protected release qualification, and production rollout
remain unproved. They require the exact artifact/runtime/OS/hardware tuple, a
legal Entry 110 row count, the protected audit launcher, complete immutable
loader evidence, an independently reviewed synchronous CPU/Metal cap,
predeclared benchmark gates, and a separate activation decision.
