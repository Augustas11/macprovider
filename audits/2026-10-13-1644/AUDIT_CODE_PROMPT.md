Lane: CODE REVIEW. Read audits/2026-10-13-1644/AUDIT_COMMON.md first and follow it.

Focus: correctness of the implementation against SPEC-036 FR-19..FR-25 and
SPEC-022 R-16. In particular:
- FR-23 state machine transitions, window start/end, hold actions, revert on
  hold-write failure, persistence and restart behaviour.
- Engine concurrency: locks, goroutines, pending score map, in-flight counters,
  deadlocks, races, leaks, ticker/sweep behaviour, rate bounds (max_in_flight,
  max_per_hour), jitter.
- Tolerance band math (median/MAD, warm rule, per-operator cap, hard floors).
- Scorer selection rules and FR-24 tracking.
- Billing: payable view and weekly-settlement predicate, rollup triggers,
  release/close semantics, time-format comparisons.
- Swift: request parsing bounds, teacher-forced indexing (which logits score
  which token), chunking, determinism, actor isolation, permit usage.
- Tests: do they actually prove what they claim?
