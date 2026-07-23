# AUDIT — SPEC-037 v0.1.0 R7 — architect lane

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






## R7 context — confirmation round

Round 7. R6's findings (all lanes converged on the same three-item set,
audited against a snapshot that predated the fix commit) were: the §5a
field-type enumeration still saying "Unix seconds" and still listing a
scalar "chunk count"; the §5 partition sentence mis-bucketing row 15; and
(architect) interrupted-purge recovery not explicitly re-advancing the
high-watermark. Commit 702662fa fixed all four: the enumeration now reads
integer Unix milliseconds with the floor(timeIntervalSince1970 × 1000)
conversion rule and derives chunk count as chunks[].length (not a
serialized field); the partition sentence now matches the code column
row-by-row (2-12+14 envelope, 15 expiry, 13/16/18 corrupt, 17 reserved/
AC-3, 19-25 own codes); and recovery of an incomplete tombstone FIRST
re-advances the high-watermark to the tombstone's carried generation,
THEN runs steps 2-4 (asserted in AC-4).

Verify those exact points in the CURRENT text (grep: "Unix seconds"
must return nothing; "chunk count" only as derived; partition sentence
vs table codes; FR-KVP8 recovery clause). Then confirm no other
contradiction remains in your lane's scope. Everything else was verified
clean in R6 (decoded_length equation constants walked against the
grammar; purge crash-points; DEK ownership; memo fidelity). This is a
certification round: report only genuine remaining defects; polish =
LOW/INFO. PASS requires 0 C / 0 H / 0 M. Same verdict line.
