# AUDIT — SPEC-037 v0.1.0 R4 — code lane

You are the CODE audit lane reviewing a freshly written normative SPEC before
it merges. This is a spec-only PR review: judge the SPEC text, not a missing
implementation. An implementation gap is only a finding if the spec text
itself is wrong, self-contradictory, ambiguous on a MUST, untestable, or
conflicts with shipped code.

Repo root: the current working directory (a macprovider worktree).

Required reading (all in-repo):

1. `specs/SPEC-037-kv-survival-restart.md` — the target.
2. `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md` — the landed
   decision source. The decision (Approach A) is made; do not re-open it.
3. `phase3-binary/Sources/macprovider-cli/ConversationCache.swift` — the
   shipped hot tier the spec claims to preserve exactly.
4. `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` — cache call
   sites (begin ~L1239/L1584, commit ~L1316/L1794); where modelID/kvBits come
   from; `snapshot.modelHash` availability.
5. `phase3-binary/Sources/MacProviderCore/Config.swift` — the `idle_prewarm`
   triple-source config pattern the spec's FR-KVP11 cites.
6. `specs/CONFORMANCE.json` and `specs/AUTHORITY.json` — the new SPEC-037 and
   SPEC-037-R001..R012 entries.

Lane focus:

- Internal consistency: FR cross-references, §5 not-a-hit table vs FR-KVP4/5
  coverage (every envelope field mapped to a row and vice versa), acceptance
  criteria AC-1..AC-9 vs the FRs they claim to verify.
- Conflicts with shipped code: does anything in the spec contradict the
  actual `ConversationCache` semantics (LCP threshold, trim behavior, TTL,
  eviction, key handling, `cached_prompt_tokens` accounting), the config
  loading pattern, or the control-socket architecture?
- Format/commit-protocol soundness: is the blob+manifest fsync/rename
  protocol as specified actually crash-consistent? Are there ordering or
  durability holes in the described protocol?
- Testability: is every MUST verifiable by a test or fixture? Are the AC
  fixtures well-defined enough to implement?
- Governance hygiene: requirement IDs, manifest entries, version headers.

Report findings as a numbered list; each finding must state severity
(CRITICAL / HIGH / MEDIUM / LOW / INFO), the spec section, the defect, and a
concrete fix. End with exactly one summary line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.



## R4 context — verify the R3 reconciliation

Round 4. R3 found (converged across five lanes): a CRITICAL circular AAD
construction (blob_sha256 inside the AAD that produces the tags the hash
covers), single-key purge not fencing outstanding hot leases, the lock
inode inside the tree --forget deletes, incoming-vs-served model identity
conflation, missing namespace-parent fsync, DEK lifecycle gaps on
eviction/recreate/uninstall-enumeration, unbounded control-plane state
(purge high-watermark map), imprecise clock-rollback claims, write-side
budget not covering active serialization, entries writable that can never
be promoted, under-enumerated §5a grammar, unnamed CLI commands, and
q4-calibration/KVCacheSimple-unquantized disclosure gaps.

The current text addresses all of these: §5a AAD is a non-circular
projection (blob_sha256 excluded, structural fast-fail pre-open;
chunk-table nonce authoritative); FR-KVP8 runs purge in the per-key lane
with stamped lease generations and commit rejection; the lock lives
outside deletable paths; FR-KVP4 item 4 splits request_model from served
identity; FR-KVP3 has parent-fsync, counter recovery, atomic write-live
budget, and an exceeds_promotion_ceiling write skip; FR-KVP6/7 complete
the DEK lifecycle and hard-bound control-plane state (4096-index HW cap
forcing rotation); FR-KVP10 states the precise clock guarantee with the
accepted residual named; §5a enumerates the closed manifest field list
and a self-delimiting payload grammar (incl. cache_offset) with the
codec-evolution rule; FR-KVP8/12 name the kv-cache CLI spellings
(--key-stdin preferred); §1/§6/§5a carry the 8k-envelope, q4-calibration,
KVCacheSimple-unquantized, and Approach-B-deferral disclosures.

Verify each R3 theme in your lane's scope is genuinely resolved, then
review the (small) new text as fresh material. The spec has now been
through three full reconciliations; do not manufacture findings — report
only genuine remaining defects. LOW/INFO polish that does not change
implementability or safety should be reported as LOW/INFO, not inflated.
Same severity scale and verdict line; PASS requires 0 C / 0 H / 0 M.
