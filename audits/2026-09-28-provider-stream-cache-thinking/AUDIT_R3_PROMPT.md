# Audit R3 — provider streaming cleanup rewrite, receipt binding, MLX cache clear, preserve_thinking

Method constraint: this is a first-party software-correctness / proof review. Do NOT author or construct malformed
payloads. Evaluate by reading source and running EXISTING tests (and the new tests). Describe any gap abstractly
(field + condition) in prose.

Repository: this worktree. Audit the FULL diff `git diff origin/main...HEAD -- phase3-binary/` (two commits:
01ac80d01, d5febeb97). Read surrounding code as needed (ModelRuntime.swift, InferenceRelay.swift, HTTPServer.swift,
ReceiptBuilder.swift, phase4-coordinator/internal/buyer/settlement_output.go, internal/billing/settlement_verifier.go,
specs/SPEC-015-receipts.md settlement_output_v1, specs/SPEC-018 §3.10/§8.4, specs/SPEC-019 streaming rules).

## What changed and why
1. Streaming emitter (`SerialStreamingTextEmitter`, used by serial and continuous-batch streaming rows) previously
   emitted nothing for the rest of a stream after any decode that did not extend the already-emitted text. Tokenizer
   `clean_up_tokenization_spaces` (on for Llama-3.x, default-on for gemma-4) rewrites earlier text (" ." -> ".",
   " 's" -> "'s"), so streams silently truncated. Now it re-anchors on the longest common scalar prefix
   (`streamDeltaAfterCleanupRewrite`, `removingAlreadyEmittedRewritePrefix`). Already-sent bytes are immutable.
   `ByteLevelIncrementalTextDecoderBox.appendCleaned` became an incremental replacement pipeline.
2. Streamed completions now set `CompletionResult.content` to the exact concatenation of emitted deltas (Harmony
   excluded), because SPEC-015 defines streamed settlement content as delivered delta concatenation and the coordinator
   recomputes it and rejects `output_hash_mismatch`.
3. `Memory.clearCache()` once after prefill (after `TokenIterator` init) on serial, streaming and speculative serve
   paths; continuous batching unchanged. Mirrors upstream mlx-swift-lm #620.
4. `preserve_thinking: true` added to the chat-template context only when the template bytes contain both
   `enable_thinking` and `preserve_thinking` (Qwen3.6/3.8), keeping multi-turn prompts append-only for KV reuse.

## Required output
Write your report to `audits/2026-09-28-provider-stream-cache-thinking/R3-<LANE>.md` where <LANE> is your lane.
List findings with severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file:line, concrete failure condition, and fix. End with a
single line exactly: `VERDICT: <n> CRITICAL, <n> HIGH, <n> MEDIUM, <n> LOW`.

Lane focus:
- code: correctness of re-anchoring (no loss, no duplication, holdback/stop-sequence interaction, tool-call streaming,
  structured-output accumulator, finish flush), byte-identity in the no-rewrite case, CB pipeline equivalence to the
  old replacement semantics, all streaming paths that produce CompletionResult covered, test adequacy.
- security: money path — can signed receipt content ever differ from delivered bytes on any stream path (complete,
  cancelled, tool rows, structured errors, speculative, CB), usage/token accounting consistency, cleanup-rewrite used
  to smuggle content past the tool-call suppression or stop filters, clearCache concurrency safety with other rows.
- architect: single source of truth for delivered content, coupling between emitter and receipt binding, whether
  preserve_thinking capability plumbing mirrors enable_thinking consistently (warm switch targets, snapshots),
  SPEC impacts (does any SPEC need a text change: SPEC-015/018/019/SPEC-001 streaming), future pin-bump interactions.

## R3 additions (final round)
The branch is now rebased onto origin/main that includes #1774 (SPEC-048 native MTP serving; mlx-swift-lm pinned to the
Augustas11 fork backport). Audit the complete diff `origin/main...HEAD` (5 commits). Prior findings and fixes:
R1-*.md, R2-*.md. The R2 fix replaced "retain a cleaned space" with a cleanup-pattern suffix holdback so streamed
content and tool arguments are byte-identical to the non-streamed output, plus a fail-closed final-close check on
streamed tool calls. Verify: (1) R1/R2 findings closed; (2) every streaming path that produces a CompletionResult —
including any native-MTP streaming path added by #1774 — uses the same emitter/holdback and binds delivered bytes;
(3) the holdback composes with stop-sequence and UTF-8 holdbacks and never withholds content at finish;
(4) SPEC-018 v0.2.10 / SPEC-019 v0.2.6 text is consistent with the code and with SPEC-015 §N.5 and every other SPEC
restatement of stream/non-stream parity (grep specs/).
