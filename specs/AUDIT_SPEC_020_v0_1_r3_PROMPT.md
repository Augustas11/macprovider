# SPEC-020 v0.1.2 — Round 3 audit prompt (per-lane)

You are auditing **SPEC-020 v0.1.2 (2026-06-29, DRAFT)** — provider
autoupdate, post-r2 absorption.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM before the SPEC PR opens.**

## Trend so far

- r1: 0C + 4H + 13M (3 lanes)
- r2: 0C + 2H + 10M (3 lanes) — convergent ratchets on trust-state matrix + FS hardening
- r3 target: 0/0/0

## What changed since r2 (v0.1.1 → v0.1.2)

- **New normative trust-state table** at top of "Cross-spec amendment and trust state" with explicit verdicts per (wire_path, tier, encrypted-leg, attestation, token-validation) combination. T-1 absorption.
- **Trusted state root subsection** under R-4 pinning directory ownership, mode 0700, ancestor symlink rejection, ACL invariants, mount-boundary checks, O_NOFOLLOW + O_EXCL semantics, advisory flock. T-2 absorption (B-r2-M-1/M-2 + C-r2-M-2).
- **Expanded marker schema** with explicit JSON types (UUIDv4, decimal-of-octal mode, RFC 3339 marker_deadline, lowercase-hex sha256). T-2 absorption.
- **SPEC-008 §10.5 citation** for v2 auth_response (instead of the wrong SPEC-001 §6.7). T-3.
- **Mandatory autoupdate drain discriminator** `state_update.reason = "autoupdate_to_<TARGET>"` + `drain_status.phase:"timeout_skipped"` wire extension. T-4.
- **Orphaned-pending-marker + corrupt-rollback-backup recovery state machine** (B-r2-M-3).
- **`release_asset_missing` failure class** (B-r2-M-4).
- **4096-byte bound clarification** — event-object alone, drop optional fields in priority order, `event_payload_too_large` fallback (B-r2-M-5).
- **Revocation precedence formula** `effective_minimum_safe_binary_version = max(...)`, `effective_revoked = union(...)`, monotonic (C-r2-M-1).
- **Version-string length bounds** 32 bytes total + 8-digit numeric components + redaction in coord-visible payloads (C-r2-M-3).

## Authoritative inputs

(Same as r2 — re-read the SPEC, r2 narrative, BUILD prompt, IMPL anchors,
SPEC-001 + SPEC-008 cross-spec citations.)

## Lane-specific focus

### Lane A — Codex architect

- **Trust-state table completeness**: does any realistic wire-state
  combination fall through with no verdict? Spot check: (legacy
  hello_ack with valid provider token but no v2 auth_response),
  (v2 accepted with `tier:"pinned"` but encrypted_leg attempted
  and failed mid-session), (provider that connects, completes
  autoupdate, restarts, reconnects on a newly-rotated token).
- **SPEC-008 citation verification**: confirm SPEC-008 §10.5
  actually defines v2 auth_response and that the recommendation
  field is present there. If not, find the correct cite.
- **Drain wire amendment**: does adding `timeout_skipped` to the
  `drain_status.phase` enum require a SPEC-001 edit, or is this
  documented as a SPEC-020-only consumer-side extension? If the
  coordinator rejects unknown enum values today, then SPEC-020 must
  either gate on `recommended_binary_version`-emitting coords or
  require a coord-side change.
- **Cross-spec invariant**: SPEC-018/SPEC-019 are active product
  surfaces. Does any v0.1.2 trust-state row interact with their
  flows (Tier2 receipts, structured-output streaming)?
- **Convergence boundary completeness**: r1's A-r1-H-2 added a
  convergence boundary; r2 added trust-state. With both in place,
  does the "providers in the latest-assumption population" set match
  what future SPECs can rely on? Specifically, are
  Tier2-attestation-not-required providers in or out?

### Lane B — Codex code

- **Citations + cross-spec resolve**: every cite in v0.1.2 must
  resolve. Verify SPEC-008 §10.5 line; verify `drain_status.phase`
  exists in SPEC-001 §6.5; verify all `phase3-binary` code paths
  cited.
- **R-N.M implementability** for the +new requirements: pick the
  trickiest 5 and trace IMPL-ability. Edge cases:
  - A v2 auth_response that succeeded BUT then the encrypted-leg
    session re-keys mid-session — does the trust-state row still
    hold or does it transition?
  - The flock holder crashes between rename and watchdog observing
    success — what does the next provider start see?
  - The marker_deadline lives in RFC 3339 but the comparator must
    handle clock skew (provider local time vs. real time). Where's
    the tolerance window?
  - A coordinator advertises `autoupdate_to_v1.7.0` reason while
    the provider is mid-drain for `autoupdate_to_v1.6.5`: race
    handling unspecified?
- **failure_class enum exhaustive**: every `failure_class:"X"`
  in the SPEC body MUST appear in the R-6.5 enum list. Grep
  every occurrence; flag any mismatch.
- **Marker schema mode encoding**: confirm the decimal-of-octal
  encoding is unambiguous (e.g., what does mode 256 mean? Is that
  `0o400`?). Provide concrete examples.
- **AC count + coverage**: v0.1.2 has 17 ACs. Does every absorbed
  r2 finding have an AC? Specifically B-r2-M-3 (orphaned marker
  recovery), B-r2-M-4 (release_asset_missing), B-r2-M-5
  (event_payload_too_large fallback).

### Lane C — Codex security

- **Trust-state table — adversarial review**: walk through each row
  and ask "can the verdict be flipped by attacker control of one
  variable?" Especially:
  - Coord that briefly produces a valid pinned + encrypted-leg
    session, then transitions to provisional — does the eligibility
    persist or re-evaluate?
  - Provider token validated at session start but revoked mid-session
    — does the trust state re-evaluate before swap?
- **Trusted state root**: ancestor checks cover symlinks, ACLs,
  mount boundaries. What about extended attributes that grant
  inheritable write (e.g., macOS ACL "file_inherit")? What about
  APFS firmlink (system-managed cross-volume link)?
- **Marker integrity invariant**: SHA-256 verification on restore.
  Is the verification done with constant-time comparison? Is there
  a TOCTOU window between hash-verify and exec-replace?
- **Revocation precedence monotonic invariant**: T-1 (signing-key
  compromise) — can the attacker who controls signing key also push
  a release that has empty `signed_policy_revoked` set to clear
  prior revocations? The "monotonic" rule says coord-advertised
  fields can't lower the floor, but `signed_policy_revoked` is
  signed content — does the SPEC explicitly forbid lowering the
  effective floor via signed releases?
- **Version-string redaction**: when oversized
  `recommended_binary_version` is hashed for coord-visible payload,
  what's the hash truncation policy? Full SHA-256 (64 hex)?
  Partial? Spec must pick.
- **drain wire ambiguity**: `state_update.reason = "autoupdate_to_<TARGET>"`
  — can a malicious coord poison the discriminator with an oversized
  TARGET to inflate the reason field past safe bounds? Bound check?
- **Event redaction enforcement**: drop optional fields in priority
  order. Is the priority-order list complete (no remaining optional
  fields not in the drop-list)?

---

## Output format

(Same as r1/r2. Start with `VERDICT: ...`. Each finding: ID with lane
prefix + round, Severity, SPEC section, Bug, Fix.)

Convergent findings still strongest signal. If you find 0/0/0, return
`VERDICT: READY TO LOCK` with any Notes you want recorded.
