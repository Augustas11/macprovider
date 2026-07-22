# AUDIT — SPEC-037 v0.1.0 R2 — code lane

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

## R2 context — verify the R1 reconciliation

This is round 2. R1 (five lanes) found: unauthenticated envelope fields
(AAD bound only 5 fields), delete-before-tombstone purge ordering,
derivable epoch keys defeating crypto-shred, disk TTL extending eligibility
beyond the hot tier's bound, AC-7 byte-identical contradiction with AC-1,
live-layer mutation racing the async writer, no single-writer lock, open
reason-code set, unspecified nonces/chunking/canonical-key-bytes/Keychain
accessibility, missing SPEC-010 dependency, missing production fence and
numeric KVS-01 protocol, and missing buyer-key/disclosure enablement gate.

The spec was rewritten to address all of these (see FR-KVP3 snapshot +
write ordering, FR-KVP4 four-category validation + full-envelope AAD,
FR-KVP6 canonical key bytes/chunked AEAD/per-epoch keys, FR-KVP7 single
writer + quota accounting, FR-KVP8 tombstone-first + purge-generation
fence, FR-KVP10 eligibility preservation, FR-KVP11 config table +
buyer-key gate, FR-KVP12 closed enum + instrumentation, FR-KVP13, §5 22
rows, §6 fence/protocol, §7 AC-1..9).

Verify each R1 theme in your lane's scope is actually resolved in the
current text, then review the NEW text for fresh defects (the rewrite
added substantial new normative surface — purge-generation fencing,
buyer-key gating, epoch rotation ordering, chunk framing — audit it as
new). Same severity scale and verdict line.
