# AUDIT — SPEC-037 v0.1.0 R2 — architect lane

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
