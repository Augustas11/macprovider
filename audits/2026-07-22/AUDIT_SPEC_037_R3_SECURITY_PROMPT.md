# AUDIT — SPEC-037 v0.1.0 R3 — security lane

You are the SECURITY audit lane reviewing a freshly written normative SPEC
before it merges. This is a spec-only PR review: judge whether the specified
design is safe and whether its guarantees are honestly stated; an
implementation gap is only a finding if the spec text itself specifies
something unsafe, omits a required control, or overstates a guarantee.

Repo root: the current working directory (a macprovider worktree).

Required reading (all in-repo):

1. `specs/SPEC-037-kv-survival-restart.md` — the target.
2. `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md` — decision
   source, especially §5 (security/isolation/billing/attestation), the 5×5
   threat table, and §5.3 mandatory invalidation rules.
3. `specs/SPEC-024-prefix-cache-billing.md` §11–§16 — the shipped isolation
   baseline (FR-CI1..FR-CI10a) the spec must preserve and extend to a
   restart-durable store.
4. `phase3-binary/Sources/macprovider-cli/ConversationCache.swift` and
   `phase3-binary/Sources/macprovider-cli/ProviderCredentialStore.swift` /
   `SecureEnclaveIdentity.swift` — shipped key-handling patterns the spec
   cites.

Lane focus (weighted):

- Cross-account isolation: does the spec fully preserve SPEC-024 FR-CI5/CI6
  reliance and close the widened blast radius (restart-durable entries, peer
  processes on a shared Mac)? Namespace binding into HMAC index + AEAD
  associated data — any bypass (file copy, replay, forged tag, epoch abuse)?
- Purge completeness: tombstone semantics, resurrection paths (backup
  restore, racing writes, pre-purge manifest replay), purge-all/epoch-bump
  crypto-shredding, Keychain old-key destruction. Is anything purgeable state
  left uncovered?
- Quota/DoS: is the cross-process capacity channel actually closed? Disk
  exhaustion, oversized-metadata allocation attacks, staging-RAM abuse,
  promotion back-pressure.
- Fail-safe completeness: enumerate failure modes and check every one
  resolves to miss per FR-KVP5; look for any path where corrupt/stale/
  ambiguous state could be reused or crash the serve loop.
- Honesty of guarantees: TTL-as-eligibility (no erasure claim), encryption
  limits, telemetry non-oracle claims, OPoI bypass.
- No receipt/billing drift: confirm the spec cannot create a new billing
  fact, receipt field, or `cached_prompt_tokens` inflation vector.

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
