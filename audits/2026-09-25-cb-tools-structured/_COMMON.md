# Codex audit: tool-bearing and structured-output rows batch (#1646, SPEC-038 AC-6c)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-1646-rest`. Branch:
`campaign/1646-remaining`. Review `git show 52fcb7e4` (the full diff vs
origin/main).

## The change
- **Gate.** `ModelRuntime.requestStateRepresentable` no longer serial-routes
  JSON `response_format` or enabled tools. Harmony (gpt-oss) models with
  tools or structured output stay serial-routed, as do `logit_bias` and
  logprobs.
- **Streaming.** Batched rows reuse the serial path's finalize. A new shared
  `SerialStreamingTextEmitter`, extracted from the serial streaming path, runs
  per batched streaming row in `AttachedPagedKVStreamState.step`, including
  the tool-turn stop, the structured accumulator and the SPEC-018 byte caps.
- **Non-streaming.** Batched non-streaming uses `parseGeneratedOutput` and
  `validateStructuredCompletion`, exactly as serial does.
- **Scheduler.** `ContinuousBatchScheduler` gains a row-stop hook, so a row
  stops at the serial stop point.
- **Spec.** SPEC-038 v0.2.11 AC-6c.
- **Tests.** `ContinuousBatchToolStructuredRowTests` (10 tests) and the routing
  tests. The full suite passes: 3535 tests, 0 failures.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
