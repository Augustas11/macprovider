# AUDIT — SPEC-037 v0.1.0 R3 — code lane

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


## R3 context — verify the R2 reconciliation

Round 3. R2 (five lanes, incl. a CRITICAL) forced these changes — verify
each is genuinely resolved in the current text, then audit the newly added
surface as fresh material:

1. Synthetic-key gate rebuilt: positive `conv:kvs-synth:` sub-namespace +
   direct-HTTP-ingest provenance, both required (the old non-`conv:`
   exclusion was unsatisfiable against the shipped validConversationKey
   prefix rule). `allow_buyer_keys=true` is now REJECTED in v0.1.
2. Purge revocation authority = per-entry DEK Keychain items destroyed at
   purge (whole-directory snapshot rollback now dead); purge-generation
   high-watermark moved to namespace metadata (survives tombstone
   compaction); stamping instant pinned to lease acquisition; publication
   re-check inside a shared per-index mutation lane; purge-all now fences,
   cancels in-flight work, clears hot entries/leases before success.
3. Epoch rotation: durable rotation-intent journal (step 0) + activation
   read-barrier recovery.
4. New §5a byte-level format grammar: JCS-canonical manifest as chunk AAD,
   framed AEAD chunks, parsing bounds, KVCacheSimple-only allowlist,
   pinned mlx-swift-lm/MLX revisions in the envelope.
5. Write side bounded: geometry pre-check, write_staging_max_bytes,
   one pending snapshot per index, disk_write_committed durability event,
   shutdown drain; snapshot captures full envelope identity at commit.
6. Data-Protection Keychain mode normative (access group,
   AfterFirstUnlockThisDeviceOnly, non-interactive, no legacy fallback).
7. flock retry with bounded backoff; ALL recovery at tier-activation;
   purge requires the lock regardless of enabled flag; purge_failed code.
8. Clock high-water dormancy in namespace metadata (rollback cannot
   re-open expired eligibility); honest reboot/Keychain note.
9. AC-7 rescoped: availability may differ wherever cold tier retains
   residency hot tier lost (restart AND intra-epoch LRU eviction);
   byte-identity only in no-restart/no-eviction greedy-decoding fixture.
10. Phase-split outcome tables (25 read rows + write + control-plane);
    enum extended (disk_miss_absent/_budget, disk_write_committed,
    disk_store_quarantined, purge_failed); FR-KVP4 item 11 is a >= fence,
    items 1-10 byte-exact.
11. retention default 60 labeled cleanup-only; eligibility TTL surfaced in
    enable notice + status; promotion_max_seconds 5; min_free_bytes >= 1 GiB;
    CLI flag column + tilde expansion.

Bar unchanged: 0 CRITICAL / 0 HIGH / 0 MEDIUM to PASS. Judge the spec
text only (spec-only PR). Do not re-litigate decisions the memo already
made (Approach A, residency-only, eligibility non-extension) or prior-round
design calls that are internally consistent — find genuine remaining
defects. Same verdict line format.
