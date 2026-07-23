# AUDIT — SPEC-037 v0.1.0 R5 — code lane

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
