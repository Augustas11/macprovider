# AUDIT — SPEC-037 v0.1.0 R7 — security lane

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
