# AUDIT — SPEC-037 v0.1.0 R4 — architect lane

You are the ARCHITECT audit lane reviewing a freshly written normative SPEC
before it merges. This is a spec-only PR review: judge the design's
boundaries, sequencing, and fidelity to its decision source. The decision
(RESEARCH_233 Approach A) is made and is not itself reviewable; what is
reviewable is whether this SPEC faithfully and completely encodes it.

Repo root: the current working directory (a macprovider worktree).

Required reading (all in-repo):

1. `specs/SPEC-037-kv-survival-restart.md` — the target.
2. `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md` — decision
   source. Check constraint fidelity: the 7 hard constraints (hot-cache
   semantics, safety envelope, per-provider isolation/quotas, purge
   ship-blocker, no receipt change, paged-KV independence, KVS-01 stop
   condition) must all be normative in the spec.
3. `specs/SPEC-024-prefix-cache-billing.md` (header + §11–§16) and
   `specs/SPEC-015-receipts.md` (header only, LOCKED v0.4.2) — authority
   boundaries the spec must respect, not re-own.
4. `specs/AUTHORITY.json` / `specs/CONFORMANCE.json` — the new
   `kv-cache-persistence` domain and SPEC-037 entries: correct ownership,
   dependencies, consumers.
5. `docs/research/RESEARCH_ROADMAP.md` §232 sequencing notes if present, and
   the SPEC-038 guardrail note in recent commits (037 provider IMPL lands
   first; 038 rebases).

Lane focus:

- Authority-boundary correctness: does SPEC-037 anywhere restate, weaken, or
  implicitly re-own SPEC-024 isolation invariants, SPEC-005 billing, or
  SPEC-015 receipts? Are dependency and domain declarations right?
- Scope discipline: is everything out-of-scope explicitly recorded (no
  silent drops)? Is the coordinator-purge-propagation deferral honest and
  clearly bounded? Is anything in scope that the memo rejected (sidecar,
  dedup, plaintext, oMLX)?
- Sequencing with RESEARCH_232 / SPEC-038: codec/version boundary adequacy,
  no batch-aware layout leakage, stop-condition well-formedness (is it
  actionable and unambiguous about when to stop and what to record?).
- Lifecycle/versioning strategy: format evolution (new codec version vs
  migration), compatibility-epoch pinning, flag rollout (default-off,
  fail-closed without purge primitive).
- Spec quality: is v0.1 buildable as specified (an implementer could produce
  the IMPL PR without design decisions that belong in the spec)? Are defaults
  (16 GiB, 240 min TTL, 256 MiB staging, 64 entries) marked operational vs
  normative correctly?

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
