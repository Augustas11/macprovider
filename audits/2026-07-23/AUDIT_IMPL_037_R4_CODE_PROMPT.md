# AUDIT — SPEC-037 IMPL R4 — CODE lane

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



## R4 context — certify the concurrency+durability redesign

Round 4. R3 found (across five lanes) 2 CRITICAL + HIGHs concentrated in
the purge-fence and memory-budget subsystems — the recurrence signalled a
wrong model (transient in-memory fences patched incrementally). A single
root-cause redesign then landed (commits 7fc9f98f..abc80914):

- CRITICAL-1/2 (7fc9f98f): admission for reads/writes/promotions now
  derives "index/namespace blocked?" from DURABLE state — a blockedIndexes
  set from incomplete tombstones (established at recovery + whenever a
  purge writes an incomplete tombstone, cleared only by the durable
  completion mark) and namespace-blocked while a purge-all is in flight or
  an open rotation journal persists. All purge/rotation ops serialize
  through one actor-held gate (owned fences, no racing). The durable
  incomplete tombstone + HWM are made durable BEFORE the suspending hot
  callback, so a crash inside the callback is recoverable and a failed
  purge (DEK/unlink/fsync error) stays fenced across the failure AND a
  restart.
- HIGH-3 (262bc0b9): true aggregate write-live budget, single-release
  token held across pending→serialize→completion/cancel/displacement.
- HIGH-4 read peak (9d3a3454): copy-free KVByteReader; peak enforced
  post-materialization incl. resident tensors.
- HIGH-5 (c860b364): promotion admission is a short actor claim, decode
  off-actor, second promotion gets disk_miss_busy immediately.
- HIGH-6 (e919954d): typed KVActivationDormancy — keychain-unavailable is
  retryable dormancy, never quarantine/false-active.
- HIGH-7 + full-generation reservation (9e84b493): commit-failure cleanup,
  superseded-leak accounting, compact-before-append, full new-generation
  reservation, activation temp sweep.
- M-6/LOW (97d3382a): Time Machine exclusion; stale-epoch tombstone fence;
  test-injection hooks behind #if DEBUG (release build verified).
- Harness (abc80914): warm arm is a genuine third turn asserting nonzero
  cached; §6 identity/format fields emitted on disk_hit/disk_write_committed
  and merged from persist+promotion events.

Verify each R3 theme in your lane's scope is genuinely closed by this
redesign, and — critically — that the redesign did not introduce NEW
defects (the last two rounds each closed the prior CRITICAL and opened a
new one in the same subsystem; that pattern must stop here). Walk every
await in purge/purgeAll/rotation for a suspension window; walk the
durable-block derivation on the failure path AND across restart; walk the
aggregate budget and off-actor promotion for leaks/races.

Documented residuals (judge scoping, don't re-flag): open-rotation-journal
namespace fence recovers at next activation (no in-process rotation retry;
fail-closed meanwhile); freeSpaceOverride/simulateStatvfsFailure are Config
values (inert in prod); KVS-01a/live-MLX tests need a lab Mac (gated behind
KV_ENABLE_MLX_TESTS); the load-time-geometry residual (stale template can
only miss, never promote wrong).

This is certification. Report only genuine defects; polish that doesn't
change safety/correctness is LOW/INFO. PASS requires 0 C/H/M. Same verdict
line. Base for the real IMPL diff is `origin/main...HEAD` (three-dot).
