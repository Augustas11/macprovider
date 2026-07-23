# AUDIT — SPEC-037 v0.1.0 R4 — security lane

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
