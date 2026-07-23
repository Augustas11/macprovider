# AUDIT — SPEC-037 v0.1.0 R6 — code lane

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
