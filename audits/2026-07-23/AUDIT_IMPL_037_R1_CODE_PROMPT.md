# AUDIT — SPEC-037 IMPL R1 — CODE lane

You are the CODE audit lane reviewing the IMPLEMENTATION of SPEC-037
before it merges. Repo root: the current working directory (a macprovider
worktree, branch impl/233-kv-survival).

Scope: the full diff `git diff origin/main...HEAD` — 24 files, all in
phase3-binary/ plus test/e2e/coldwarm-ttft/ (kvs-01a harness). New files:
KVDiskCacheFormat/Keys/Store.swift, KVDiskTier.swift,
KVConversationColdTierAdapter.swift, ConversationColdTier.swift,
KVCacheCommand.swift, KVDiskCacheConfig.swift (MacProviderCore), plus
tests. Modified: ConversationCache.swift, ModelRuntime.swift,
ControlSocket.swift, HTTPServer.swift, InferenceRelay.swift,
ChatCompletionRequest.swift, Config.swift, MacProviderCLI.swift.

THE SPEC IS NORMATIVE: specs/SPEC-037-kv-survival-restart.md (merged to
main; seven-round audited). Judge the implementation against it. Also
load-bearing: SPEC-024 §11–§16 isolation invariants must be preserved
byte-for-byte in hot-tier behavior for non-gated keys.

Documented stage-5 residuals (judge their scoping, do not re-discover
them as new findings unless they violate a normative MUST): (1) first
post-restart-turn promotion needs a load-time geometry template — the
adapter only promotes after the model has committed once in-process;
(2) shutdown drain is best-effort fire-and-forget Tasks rather than a
bounded drain queue (spec FR-KVP3 says "drains pending snapshots for up
to shutdown_drain_seconds" — assess whether the implementation honors
the durability contract that only disk_write_committed generations are
promised); (3) AC-4 HW-map-at-cap rotation and AC-8 live spec-decode
no-lease assertions are named skips (need injectable cap / Metal).

Lane focus (code):
- Correctness of the §5a format implementation vs the spec byte grammar
  (JCS AAD projection, chunk framing, decoded_length equation constants,
  bounds, milliseconds timestamps, closed field lists).
- FR-KVP3 commit protocol ordering in KVDiskCacheStore (fsync sequence,
  O_EXCL temps, mutation-lane pre-publication recheck, commit-sequence
  recovery), snapshot immutability (deep copy vs live-layer aliasing).
- ConversationCache/ModelRuntime integration: lease lifecycle (begin/
  commit/abort with cold context), promotion path reusing the shipped
  predicate, purge fencing of in-flight commits, speculative reorder not
  changing non-speculative behavior, busy-key hygiene.
- Concurrency: actor isolation, Sendable, races between writer/purge/
  promotion/eviction; anything that could corrupt the hot tier.
- Test adequacy vs §7 AC map; harness scripts (kvs-01a.sh/probe.mjs)
  correctness.
Report findings numbered, each with severity (CRITICAL/HIGH/MEDIUM/LOW/
INFO), file:line, the defect, a concrete fix. End with exactly:
VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO
PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
