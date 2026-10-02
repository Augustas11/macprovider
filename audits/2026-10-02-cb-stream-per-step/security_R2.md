METHOD CONSTRAINT: first-party correctness review of our own code by reading the repository and the diff. Do not construct exploit payloads, attack strings, or weaponized inputs; describe failure scenarios in prose.

# security review — CB per-step streaming inside lockstep windows

Repo: /Users/augstar/macprovider-cb-stream-per-step, branch fix/cb-stream-per-step. Review the FULL diff `git diff origin/main...HEAD` (code + SPEC-038 v0.3.8 FR-CB2 text + CONFORMANCE mapping). Governing: specs/SPEC-038-continuous-batching.md FR-CB2/FR-CB5 (SPEC-038-R002), SPEC-039 paged KV, SPEC-024 retained conversation cache.

Change: non-hybrid continuous-batching rows decode in 16-step lockstep windows inside one backend hop. Before, tokens reached buyers only when the window returned (16-token bursts). Now `ContinuousBatchSchedulerBackend.decodeLockstepWindow(rows:steps:onStep:)` reports each step's sampled tokens (`ContinuousBatchDecodeWindowStep`) synchronously from inside the model hop; the observer yields them into an AsyncStream consumed by a Task on the scheduler actor (`applyStreamedDecodeStep`), which runs stop filtering/visibility/delivery per step via `advanceDecodeRow` and defers release/terminal finish (`completeDecodeRow`) to the hop boundary. The returned window is authoritative: streamed tokens must be its prefix or the row fails `continuous_batching_decode_stream_mismatch`. `ContinuousBatchDecodeWindowControl` lets the backend end the hop once every row is cancelled or has completed the step after its terminal token (writing the terminal token KV for retention). The bridge also throws at the next step boundary once `cancelInFlight` started. `cancel(requestID:)` ignores a row whose completion was decided mid-window. The compiled-decode path streams but never ends early. Window size 1 (hybrid models) passes no observer, preserving the old path. Studio evidence (llama-3.1-8b, M3 Ultra, batched route): audits/2026-10-02-cb-stream-per-step/studio-results-20261002T004124Z.txt.

Focus: cross-row isolation (can a token of one request ever be delivered to another request id or waiter, including via zip of requestIDs/tokens or stale step events); fail-closed behavior when the backend stream and window result disagree; settlement/receipt eligibility of rows that streamed tokens then failed or were cancelled (buyer charged for undelivered or delivered-but-failed output, or paid output not charged); resource exhaustion (unbounded AsyncStream buffering, Task leaks, lock contention, blocks released while backend still writes them -> use-after-release of paged KV); cancellation/drain fail-closed guarantees; replay/dedupe terminal result codes.

Output: findings with severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file:line, failure scenario, fix. End with exactly one line: VERDICT: C=<n> H=<n> M=<n> L=<n>.


## Round 2

Round 1 findings and dispositions (verify each against the current diff; report anything still wrong at its real severity):
- Early hop exit vs full-window block-table extension (blockTableMismatch on record): early exit is now allowed only when every row in the hop is cancelled (`ContinuousBatchDecodeWindowControl` tracks cancels only, marked synchronously in `cancel(requestID:)`); on an early end the bridge stores no session and removes row state instead of recording (`endedEarly` in `performDecode`). Normal stops keep the hop running.
- Native-MTP capture branch skipped `onStep` and the cancellation poll: the branch no longer `continue`s; capture, state handling, collection, cancel poll and observer share one per-step tail.
- Protocol default silently ignored the observer: the observer window is now the protocol requirement; the 2-arg form is an extension convenience; the default decode-only loop streams one-token steps; MSB/test wrappers forward the observer.
- Step metadata trusted before validation: steps are positional (`tokens[i]` for `rows[i]`), validated for step order and shape before any delivery; a malformed step halts streaming for the hop and the returned window decides. Stream buffer bounded to the window length.
- Completion overtaken by cancel after window state was cleared: `streamedWindowRows` now lives until the function exits (after outputs are applied).
- Cancel masking stream mismatch: mismatch is decided before `processCancellations()`.
- AsyncStream timing for early exit: early exit no longer depends on actor scheduling (cancel marks are synchronous); terminal rows never end a hop early.
- Fixed sleeps in tests removed; CONFORMANCE SPEC-038-R002 now maps the decode implementation and v0.3.8 rationale.
- Relay/gateway classification of post-token provider failure envelopes (security R1 #2): attributed PRE-EXISTING and outside this diff. Post-token CB failures (forward_failed, row_sampling_failed, invalid_decode_token, delivery backpressure) already reached buyers after earlier windows had streamed, through the same `terminalFailureError` mapping in ModelRuntime.swift; this diff adds one more code on that path. Judge only whether this diff makes it worse.

Review the FULL combined diff `git diff origin/main...HEAD` again, not only the round-2 commit.
