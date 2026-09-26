# Codex audit: tool-bearing and structured-output rows batch (#1646, SPEC-038 AC-6c)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-1646-rest`. Branch:
`campaign/1646-remaining`. Review the full diff `git diff 8d6e99ee..HEAD -- phase3-binary specs` (commits dd5a7d88, 52fcb7e4, the R1 fix 25117673 and the R2 fix b8c9229a).

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

## Round 2
R1 found two MEDIUMs, and `25117673` fixes both:
- **Code lane.** Batched `finish_reason` reported "length" on the implicit context limit. It now reports "length" only for an explicit `max_tokens` reached before truncation, as serial does.
- **Security lane.** A duplicate or terminal replay lost the serial tool-stop boundary. The boundary is now derived once from the row's generated tokens (`continuousBatchSerialToolStopTokenCount`) and applied before billing and cache settlement.

Tests: 3 new regression tests, each proven to fail without its fix. The full suite passes: 3538 tests, 0 failures.

Verify both fixes and re-check the lane for anything new. Also check the cost of the fix: `AttachedPagedKVStreamState.step` now re-decodes the whole accumulated token list on EVERY token, instead of once per delivered event. The canonical stop detection decodes every prefix. Is that O(n^2) detokenization on long streamed outputs, and does it apply to plain batched streaming rows too? If it is a material throughput or latency regression, rate it and propose an incremental fix.

## Round 3 (final)
In R2, the code and security lanes both raised one MEDIUM: O(n^2) prefix detokenization. `b8c9229a` fixes it:
- The canonical serial tool-stop boundary is computed once in scheduler-owned row state and reused for finalization and replay.
- Qwen and Llama serial tool rows use bounded byte-level incremental decoding, meant to match UTF-8 and tokenizer-cleanup behaviour.
- Plain and structured non-tool replay events decode once per event.
- Counted decodes over 128 tokens fall from 8,384 to 128.

Verify the fix. Scrutinize the incremental byte-level decoding for any divergence from the real tokenizer's `decode(tokens)`: multi-byte UTF-8 split across tokens, cleanup of leading spaces and special tokens, byte-fallback tokens, and other model families that fall back to full decode. Then re-check the whole lane.
## Lane: SECURITY / MONEY PATH

Check:
- Usage, receipt and settlement fields for batched tool and structured rows, especially tokens generated after the serial stop point: are they billed or excluded exactly as on the serial path?
- Cross-row isolation of tool-call parser state and of structured accumulators.
- The SPEC-018 argument byte caps are enforced per row.
- Harmony gating: no path lets a Harmony tool request batch.
