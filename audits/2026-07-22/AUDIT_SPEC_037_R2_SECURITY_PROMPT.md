# AUDIT — SPEC-037 v0.1.0 R2 — security lane

You are the SECURITY audit lane reviewing a freshly written normative SPEC
before it merges. This is a spec-only PR review: judge whether the specified
design is safe and whether its guarantees are honestly stated; an
implementation gap is only a finding if the spec text itself specifies
something unsafe, omits a required control, or overstates a guarantee.

Repo root: the current working directory (a macprovider worktree).

Required reading (all in-repo):

1. `specs/SPEC-037-kv-survival-restart.md` — the target.
2. `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md` — decision
   source, especially §5 (security/isolation/billing/attestation), the 5×5
   threat table, and §5.3 mandatory invalidation rules.
3. `specs/SPEC-024-prefix-cache-billing.md` §11–§16 — the shipped isolation
   baseline (FR-CI1..FR-CI10a) the spec must preserve and extend to a
   restart-durable store.
4. `phase3-binary/Sources/macprovider-cli/ConversationCache.swift` and
   `phase3-binary/Sources/macprovider-cli/ProviderCredentialStore.swift` /
   `SecureEnclaveIdentity.swift` — shipped key-handling patterns the spec
   cites.

Lane focus (weighted):

- Cross-account isolation: does the spec fully preserve SPEC-024 FR-CI5/CI6
  reliance and close the widened blast radius (restart-durable entries, peer
  processes on a shared Mac)? Namespace binding into HMAC index + AEAD
  associated data — any bypass (file copy, replay, forged tag, epoch abuse)?
- Purge completeness: tombstone semantics, resurrection paths (backup
  restore, racing writes, pre-purge manifest replay), purge-all/epoch-bump
  crypto-shredding, Keychain old-key destruction. Is anything purgeable state
  left uncovered?
- Quota/DoS: is the cross-process capacity channel actually closed? Disk
  exhaustion, oversized-metadata allocation attacks, staging-RAM abuse,
  promotion back-pressure.
- Fail-safe completeness: enumerate failure modes and check every one
  resolves to miss per FR-KVP5; look for any path where corrupt/stale/
  ambiguous state could be reused or crash the serve loop.
- Honesty of guarantees: TTL-as-eligibility (no erasure claim), encryption
  limits, telemetry non-oracle claims, OPoI bypass.
- No receipt/billing drift: confirm the spec cannot create a new billing
  fact, receipt field, or `cached_prompt_tokens` inflation vector.

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
