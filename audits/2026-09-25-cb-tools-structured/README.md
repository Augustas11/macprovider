# Codex audit: tool-bearing and structured-output rows batch (SPEC-038 v0.2.11 AC-6c)

Commits:
- `dd5a7d88`: the SPEC change.
- `52fcb7e4`: the implementation.
- `25117673`: the R1 fixes (Codex).
- `b8c9229a`: the R2 fix (Codex).
- `23429b7d`: the R3 fix (Codex).

| Lane | R1 | R2 | R3 (final round) |
| --- | --- | --- | --- |
| Code | FAIL 0/0/1: implicit context limit reported `length` | FAIL 0/0/1: O(n²) prefix decode at finalize and replay | FAIL 0/0/1: EOS or buyer stop exactly at explicit `max_tokens` reported `length` |
| Security / money path | FAIL 0/0/1: replay lost the serial tool-stop boundary (post-stop tokens billed and cached) | FAIL 0/0/1: same O(n²) finding | **PASS** |
| Architecture | **PASS** | not re-run | **PASS** |

**The R3 code MEDIUM after the round cap.** The user caps audits at 3 rounds, then moves to e2e. The R3 MEDIUM was fixed after the cap (`23429b7d`) and verified without a 4th audit round:
- 3 regression tests, which fail with 12 assertions when the fix is reverted;
- the full suite: 3545 tests, 0 failures;
- a Studio e2e, `finish_edge.py`. On the real Qwen3.6 model, `max_tokens` 21, 22, 23 and 24 give serial == batched `finish_reason` and usage for streaming and non-streaming. The case at 23, EOS at the limit, reports `stop` on both.

**Studio e2e on the final build `95d9b943`, with live paused.** Data: `tools_e2e.py`, `finish_edge.py`, `tools-lab.sh`.
- **Parity:** all 16 serial vs batched pairs are identical: `tool_calls`, `finish_reason` and completion tokens, for tools and JSON schema, streaming and non-streaming.
- **Concurrency:** 8 concurrent mixed tool, JSON and plain rows all returned 200.
- **Serve log:** 32 batched admissions, 0 forward failures.
- **Steady batched decode:** 66.0 tok/s at 32 × 4 and 65.2 at 1.5k × 4, against a baseline of 66.3 and 64.9. No regression.

**Carried.**
- Harmony (gpt-oss) models with tools or structured output stay serial-routed.
- Possible pre-existing problem: plain Harmony streaming rows may leak analysis-channel text when batched. It is not verified and not introduced here; check it before enabling CB for gpt-oss.
