# AUDIT — SPEC-037 v0.1.0 R6 — security lane

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
