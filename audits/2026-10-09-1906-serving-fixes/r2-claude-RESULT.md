# Round 2, Claude Opus adversarial review (anchored)

VERDICT: 0C/0H/1M (NEW only).

All round-1 critical, high and medium findings are fixed or covered by an operator decision. The signed CB policy not binding ragged prefill is not fixed, by operator decision (AGENTS.md rule 11); its spread-cap mitigation is present. Tests: pool and gateway passed; buyer `-race` failed once in three runs, unidentified.

## N1 MEDIUM (introduced by 662552b77): the depth key overrides max_concurrency_override
`Config.swift` let `max_concurrency_depth_override` replace any `max_concurrency_override`. Only the new applier removes the depth key. So an older CLI's apply, or an operator lowering the legacy key (for example to 1 for a draft model), was silently overridden. Results: serve refusing to start, or a stale depth carried over after a model switch. Fix: honour the depth key only when the legacy key is absent or exactly 8.

## N2 LOW (81d324722): the one-shot ignore flag isn't reset when a new wait starts
`RestoreForwardedSlot` and `MarkForwardedSlotFull` set `awaitingReadyOccupancy` again without clearing `ignoredLowerReadyReport`. Fix: clear it wherever the wait restarts.

## Residual LOWs
- An active-decode duplicate that becomes the owner measures TTFT from its own request start.
- Telemetry for `request_log.retried`.
