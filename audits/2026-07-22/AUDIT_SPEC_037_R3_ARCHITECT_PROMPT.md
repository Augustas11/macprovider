# AUDIT — SPEC-037 v0.1.0 R3 — architect lane

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
