# BUILD IMPL — SPEC-038 continuous batching first implementation slice

> **Historical / superseded:** this v0.1 scaffold prompt is retained only to
> explain the absorbed PR #804 controls. Its upstream-pin activation theory is
> not authoritative. Use
> `audits/_prompts/BUILD_SPEC_038_V0_2_SCHEDULER_IMPL_PROMPT.md`; local SPEC-039
> descriptor membership plus installed runtime capability is the only future
> activation path.

You are a senior systems engineer implementing SPEC-038 for the macprovider
provider runtime. Work in a fresh worktree from `origin/main`; do not edit the
canonical checkout. Treat `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md`
and `specs/SPEC-038-continuous-batching.md` as the requirements source.

## Goal

Land the first safe, reviewable implementation slice for continuous batching:
default-off operator controls, explicit unsupported-mode handling, scheduler
capability state, bounded FCFS admission scaffolding, and MSB measurement
contract support, without claiming or enabling shared-forward batching before a
reviewed upstream `mlx-swift-lm` batch API exists.

## Constraints

- The pinned dependency remains `mlx-swift-lm` 3.31.4. That release has no
  reviewed public `BatchGenerator` / `GenerationBatch` API, so the serve path
  must not advertise true continuous batching or fabricate a shared forward.
- `continuous_batching=off` is the default and must be byte-compatible with the
  current serial `AsyncSemaphore` + `TokenIterator` path.
- `continuous_batching=on` must fail preflight with a named reason until a
  reviewed upstream batch API/revision is pinned and the implementation can
  actually run one shared forward for active rows.
- `continuous_batching=canary` is permissive: unsupported tuples are explicitly
  serial-routed with observable reason-coded telemetry. No silent fallback.
- Draft-enabled SPEC-028 remains mutually exclusive with batching.
- Any `kv_bits` with batching requested is unsupported in this slice and must
  be rejected or serial-routed according to mode.
- Queue/admission scaffolding must be bounded and FCFS, but must not introduce
  an unbounded second HTTP or relay queue.
- Do not touch coordinator billing, router, auth, or settlement code.

## Required code shape

1. Add config/CLI/env/YAML plumbing:
   - `continuous_batching`: `off | canary | on`
   - `continuous_batch_queue_limit`: positive integer; default `2 * slots_total`
2. Add runtime capability/preflight helpers that expose:
   - effective scheduler mode
   - max active rows derived from Entry 110 `maxBatch`
   - queue limit
   - reviewed upstream revision/pin status
   - unsupported reason codes
3. Preserve serial fallback by default:
   - both non-streaming and streaming use the existing path unless the mode is
     explicitly requested and supported.
4. Fail loud for strict mode:
   - `on` plus missing upstream batch API => `continuous_batching_unavailable`
   - `on` plus `kv_bits` => `continuous_batching_unsupported_kv_bits`
   - draft model plus batching request => existing/spec-compatible draft
     capacity shortfall behavior.
5. Emit observable permissive telemetry in canary mode:
   - `event=continuous_batching_unsupported action=serial_routed reason=...`
6. Add tests covering defaults, config precedence, strict rejection, permissive
   serial routing, draft exclusion, queue-limit default/validation, and runtime
   threading.
7. Add or extend an MSB harness utility so aggregate TG is computed as total
   decoded tokens over common wall-clock, not summed per-request durations.

## Verification

Run targeted Swift tests for changed config/runtime/harness behavior, then run
the relevant package build or test subset. Do not claim the feature implements
true shared-forward decode unless the code actually has a batch API and test
evidence for one model forward per active decode step.
