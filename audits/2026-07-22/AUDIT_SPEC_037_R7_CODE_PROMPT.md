# AUDIT — SPEC-037 v0.1.0 R7 — code lane

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
