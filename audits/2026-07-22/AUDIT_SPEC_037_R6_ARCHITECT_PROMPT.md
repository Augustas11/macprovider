# AUDIT — SPEC-037 v0.1.0 R6 — architect lane

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





## R6 context — verify the R5 reconciliation

Round 6. R5 was 0 CRITICAL / 0 HIGH everywhere; the remaining MEDIUMs
(converged) were pure encoding hygiene: a stale "Unix seconds" line
contradicting the milliseconds spec; decoded_length lacking an exact
mechanical equation; chunk_count named as a field but absent from the
closed list; §5 rows 13/16/17 not a clean one-to-one partition; purge
step-1 writing high-watermark and tombstone without ordering (and step-4
missing a directory fsync before the completion mark); and provisional-
DEK abort cleanup able to delete a successor's re-created DEK.

The current text: timestamps are uniformly integer Unix milliseconds
with a floor conversion rule; chunk count is defined as chunks[].length
(no separate field); decoded_length has an exact overflow-checked byte
equation (dims include the sequence axis; K and V each counted with u64
length prefixes) plus required numeric golden vectors; §5 now has an
explicit partition rule (rows 2-12+14 = envelope-vs-runtime; rows
13+15-18 = artifact integrity; row 17 reserved/AC-3-exempt, AC-2 says
"every reason-coded row"); purge orders incomplete-tombstone-fsync
BEFORE high-watermark advance, adds entry-dir fsync before the durable
completion mark, and AC-4 injects kills at every sub-boundary; DEK
cleanup is ownership-checked per write incarnation in the mutation lane.

Verify these six themes are resolved in your lane's scope and check the
new text. Five reconciliations are done; the defect stream has narrowed
to wording level for two straight rounds. Do not manufacture findings;
polish that does not change implementability or safety is LOW/INFO.
PASS requires 0 C / 0 H / 0 M. Same verdict line.
