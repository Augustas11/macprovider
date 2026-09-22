# Round 3 re-audit — AC-25 Phase A

Worktree `/Users/augstar/macprovider-ac25-m2`, branch
`campaign/ac25-m2-api-lifecycle`, rebased on `origin/main` @ `025036b2`.

Review the **FULL combined diff as it will land**: `git diff origin/main..HEAD`.
Swift and docs only — if you see Go files in the diff, stop and say so, it
means the branch has drifted again.

Round 1: 0C/2H/4M/1L, fixed in `a32aec7c`.
Round 2: 0C/0H/2M, fixed in `99bb56b2`:

- **M-1** `.backpressure` carried two meanings. New `.deliveryBackpressure`
  case (code `continuous_batching_stream_delivery_backpressure`, 503,
  `inferenceRan: true`, `settlementRan: false`, retryable pinned `false` at the
  call site, no `Retry-After`) for the decode-pump post-token site and for the
  terminal-result `errorCode` replayed to duplicates. The six pre-admission
  sites keep `continuous_batching_stream_backpressure` unchanged in string,
  status, retryability and `Retry-After`.
- **M-2** streaming retry guidance is now body-visible: `retry_after` inside
  the `error` object of the terminal SSE payload for the two queue-pressure
  codes, plus `Trailer: Retry-After` now declared on every SSE head.

Verify both fixes and hunt for what they introduced. Specifically:

- Is the pre-admission vs post-token classification of **every**
  `.backpressure` / `.deliveryBackpressure` site correct? The claim is that the
  five `enqueue()` sites are pre-admission because each failing offer is the
  first event to a delivery created moments earlier in `submit()`, even when
  the row being joined is already decoding. Check that claim at each site,
  especially the one that attaches to an active decode row.
- `inferenceRan: true` on `.deliveryBackpressure`: can that now cause a
  settlement, receipt, or billing outcome that the previous `false` suppressed?
  Trace what consumes it. This is the reverse of the round-1 change and
  deserves the same scrutiny.
- Does adding `retry_after` inside the SSE `error` object change a wire
  contract any consumer validates (schema, relay parsing, SDK strictness)?
- Does declaring `Trailer: Retry-After` on **every** SSE head, including
  streams with no settlement metadata, break any existing consumer?
- Any remaining case where a buyer is told to retry work that partly ran, or
  told not to retry work that never ran.

Gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**. State explicitly if you find none.
This is round 3; if what remains are edits rather than defects that would
mis-bill, mis-settle, or mislead a buyer, say so and pass. Do not manufacture
findings. Do not propose SPEC edits. Findings as CRITICAL/HIGH/MEDIUM/LOW/INFO
with file:line, a concrete failure scenario, and a fix.
## Lane: CODE REVIEW — correctness, test adequacy, maintainability.
