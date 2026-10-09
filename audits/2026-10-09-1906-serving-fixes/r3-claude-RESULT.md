# Round 3, Claude Opus adversarial review (final)

VERDICT: 0C/0H/1M (NEW only).

## Round-2 fixes
- Streamed-receipt TTFT: fixed.
- One-shot flag reset: fixed.
- R011 rationale: fixed.
- Depth-key precedence: partially fixed; the gap is L2.

## M1 MEDIUM: queue-full after in-flight drained sheds; the PR's own closed-loop test flakes
`TestClosedLoopNClientsAgainstNSlotsShedZero` failed 2/20 runs without `-race` and 6/20 with it. Every shed came from `server.go:~7950`. `requeueAfterQueueFull` requeued only while in-flight > 0. Old provider CLIs, which lack the end-frame release, would still occasionally shed at N buyers on N slots.

## L1 LOW
`MarkForwardedSlotFull` cleared `ignoredLowerReadyReport`, so the first ready report after a refusal was ignored.

## L2 LOW
Malibu.app's config writer didn't own `max_concurrency_depth_override`.
