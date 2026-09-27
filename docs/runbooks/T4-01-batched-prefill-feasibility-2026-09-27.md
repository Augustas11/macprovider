# T4-01 batched prefill feasibility decision (2026-09-27)

## Decision

Choose the incremental SPEC-038 scheduler path for issue #1758: add
decode-first, separate-phase batched prefill to the existing continuous
batching scheduler before considering a CBv2 engine port.

This record authorizes no release, provider restart, live coordinator join, or
production configuration change. Implementation remains behind the existing
continuous-batching gates and the Studio campaign loop.

## Why

The measured bottleneck is prefill scheduling, not steady decode. The
throughput decomposition shows the current scheduler admits one prefill per
iteration, with 1.5k x 4 at 19.9 aggregate tok/s and 25.0 s worst first token,
and 4k x 4 at 8.8 aggregate tok/s and 69.6 s worst first token
([decomposition](continuous-batching-qwen36-throughput-decomposition-2026-09-25.md)).
The paged decode path is already within roughly 3-6% of the stock MLX ceiling
in the same evidence set.

CBv2 is rejected for this slice because it would replace more serving
infrastructure than the observed blocker requires: relay lifecycle,
warm-swap, conversation cache, receipt boundaries, SPEC-028 exclusion, and
existing SPEC-039 block-table ownership would all need a larger bridge before
the first TTFT improvement. That remains a future option if the incremental
path cannot meet the gates below.

## Initial Production Targets

- Active batched-prefill scope: up to 4 rows.
- Per-iteration prefill budget: at most 1024 total prompt tokens.
- Per-row prefill chunk: at most 512 prompt tokens.
- Scheduler order: decode first, then bounded compatible prefill.
- Backend requirement: compatible rows share one prompt-phase forward; serial
  one-row-at-a-time prefill is not batched prefill.

These are initial production targets for the implementation PR, not permanent
capacity limits. Any later increase needs new evidence on the exact packaged
runtime tuple.

## Known Limitation

Ragged prompt offsets are not assumed safe for shared prefill in the first
implementation. If the backend cannot prove that a set of prompt rows is
compatible, the scheduler must split the group or use the serial prefill
fallback. The fallback is conformant only when it preserves FCFS progress,
cancellation boundaries, receipt boundaries, and per-row block-table isolation.

## Block-Pool Strategy

Use admission-time pool checks and bounded queueing as the primary defense for
concurrent long prompts. Admission reserves the prompt plus configured decode
headroom, not every row's full worst-case generation ceiling. When the pool
cannot fund an admitted-compatible group, the scheduler keeps rows queued
within the bounded queue or rejects with the existing backpressure surface.

The target failure mode for 8k-token concurrent prompts is graceful queueing or
reason-coded backpressure, not `continuous_batching_block_extension_failed`.
Mid-decode pool exhaustion remains the request-local FR-CB17 fallback, not a
whole-batch failure and not preemption.

## Studio Validation Gates

The implementation PR must validate these gates on the Studio candidate before
requesting release review:

- 1.5k x 4, 128 output tokens: worst first token under 20 s.
- 4k x 4, 128 output tokens: worst first token under 45 s.
- 8k x 4: no `continuous_batching_block_extension_failed`; the run either
  serves successfully or degrades through bounded queue/backpressure.
- Decode parity and cross-row isolation from the prior continuous-batching
  evidence remain green.
- Receipt, cancellation, duplicate terminal, and warm-swap boundaries remain
  unchanged from SPEC-038.

## Stop Condition

Stop this feasibility slice when SPEC-038 v0.3, `specs/CONFORMANCE.json`, and
the generated spec index record the batched-prefill requirement and this
decision record exists. The next slice is implementation plus Studio evidence;
if it misses the Studio gates above, reopen CBv2 as a separate decision rather
than broadening this slice.
