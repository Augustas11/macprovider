# AUDIT — SPEC-037 v0.1.0 R5 — architect lane

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




## R5 context — verify the R4 reconciliation

Round 5. R4 came back 0 CRITICAL / 0 HIGH across all five lanes; the
remaining MEDIUMs (converged) were: layers[] missing the layout_version
FR-KVP4 requires; no canonical null encoding for unquantized quantization
fields; no decoded_length field or shared derivation formula; integer-
second timestamps vs the hot tier's sub-second deadlines; purge recovery
able to re-run destructive steps against a post-purge re-cache (no
durable completion mark); DEK destruction on generation compaction vs
whole-entry eviction conflated; eviction not serialized with the mutation
lane / provisional-DEK cleanup; §5 row 17 unreachable in a conforming
request path; and the allowlist/ceiling/8k-gate arithmetic contradiction
(unquantized KVCacheSimple = ~96 KiB/token -> 8k = 768 MiB > 256 MiB;
the q4 class that fits was not allowlisted).

The current text addresses all of these: layers[] closed key set with
authenticated per-layer layout_version; canonical JSON null for
unquantized fields; decoded_length with one normative geometry formula
shared by the FR-KVP3 write estimate and FR-KVP9 trigger (+ structural
equality check); Unix-millisecond timestamps with deadline-boundary
fixtures; phase-aware tombstones (durable completion mark gates new
writes and bounds recovery); DEK retained across superseded-generation
compaction and destroyed only on whole-entry eviction, executed in the
mutation lane with writer cancellation and provisional-DEK abort cleanup;
purge cancels writers, never joins; row 17 reclassified as an
activation-recovery event; and KVS-01 split into KVS-01a (~2.5k
correctness gate runnable under the v1 allowlist) and KVS-01b (8k
performance gate, explicitly gated on the memo-Q6/Q7 format decision),
with §1's envelope claim corrected and golden JCS/AAD fixtures required.

Verify each theme in your lane's scope is genuinely resolved, then check
the small amount of new text as fresh material. Four reconciliations are
done and the defect stream has been strictly narrowing; do not
manufacture findings — polish that does not change implementability or
safety is LOW/INFO. PASS requires 0 C / 0 H / 0 M. Same verdict line.
