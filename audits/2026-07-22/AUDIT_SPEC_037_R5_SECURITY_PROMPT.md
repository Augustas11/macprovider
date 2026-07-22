# AUDIT — SPEC-037 v0.1.0 R5 — security lane

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
