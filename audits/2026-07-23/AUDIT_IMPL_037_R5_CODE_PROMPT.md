# AUDIT — SPEC-037 IMPL R5 — CODE lane

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




## R5 context — certify R4 fixes + rebase-conflict resolution

Round 5 (certification). Diff base `origin/main...HEAD` (three-dot). The branch was rebased onto latest origin/main since R4.

R4 found 2 CRITICAL (both the same purge/promotion TOCTOU class: off-actor-promotion decode missing a post-decode fence recheck; purge-all rotation journal not durable before the hot callback) + 2 HIGH + 3 MEDIUM + 1 LOW. ALL fixed (commits be55cd45..45c08cca on the pre-rebase branch; now replayed). Key fixes to verify still hold post-rebase:
- read()/promotion: after the detached off-actor decode returns, re-enter the actor and recheck epoch + high-watermark + namespace/index block + live-entry before returning .hit; begin() rechecks localPurgeGen/globalPurgeGen after promoteCandidate; purge cancels/joins in-flight promotions before DEK destroy. New failpoints testPromotionDecodeRaceSingleKeyPurgeYieldsMiss / ...PurgeAllYieldsMiss.
- performNamespacePurgeRotation persists+fsyncs the rotation-intent journal BEFORE the hotPurgeAll suspension.
- write-live budget covers active seal buffers; activation charges undeletable orphan bytes; catalog_revision is a distinct identity field (identity_unavailable when absent); serve --kv-disk-cache-* flags forwarded + config errors logged; KVS-01a warm-relative thresholds advisory (correctness gates fail).
The R4 adversarial lane confirmed the R3 durable-fence redesign is sound and rated the off-actor TOCTOU MEDIUM (bounded/non-persistent) — the fix closes it. Class sweep established: writes are synchronous-on-actor (no TOCTOU); every purge/promotion await is durable-before or recheck-after.

ADDITIONALLY — audit the rebase-conflict resolution in ModelRuntime.swift (NEW since R4, not previously audited): origin/main added a harmony-integrated speculative block AFTER conversationCache.begin() on the streaming path; this branch's FR-KVP2.5 fix routes speculative decode BEFORE begin() (block ahead of the lease acquisition, cache:nil, no lease, returns). The resolution KEPT the pre-begin speculative block + origin's harmony parser setup + generationContext.model iterator, and DROPPED origin's duplicate post-begin speculative block (which would double-run and, on its success return, leak the lease as a stuck busy key). Verify: (a) speculative decode is determined exactly once, before begin(), on BOTH streaming and non-streaming endpoints; (b) a speculative-routed request acquires no lease / leaves no busy key (FR-KVP2.5 / FR-CI4a); (c) no double-run; (d) harmony streaming for the non-speculative path is intact; (e) the cold-tier commit sites correctly pass `cold: coldContext` with origin's resultTokenIDs token collection.

Certification round: report only genuine defects; polish that doesn't change safety/correctness is LOW/INFO. PASS requires 0 C/H/M. Same verdict line.
