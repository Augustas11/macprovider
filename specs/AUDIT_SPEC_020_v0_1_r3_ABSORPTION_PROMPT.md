# SPEC-020 v0.1.2 → v0.1.3 — r3 absorption prompt

Absorb r3 findings into `specs/SPEC-020-provider-autoupdate.md`. Bump
version header **v0.1.2 → v0.1.3**, add changelog entry, apply every
fix below.

**Bar:** r4 audit must return 0 CRITICAL + 0 HIGH + 0 MEDIUM. Read
`specs/SPEC-020-r3-audit.md` for the full per-finding text.

## Convergent — fold into one combined fix

### T-1 Trust state as LIVE invariant (A-r3-H-1 + C-r3-M-1)

Locate the existing R-1.x trust-state subsection (or the "Cross-spec
amendment and trust state" section). Add:

> **Live trust-state predicate.** `autoupdate_trust_state` is NOT a
> handshake-time snapshot; it is a live session predicate. The
> provider MUST re-evaluate eligibility immediately before each
> irreversible autoupdate phase:
>
> 1. Before starting download.
> 2. Before entering drain.
> 3. Before creating `pending.json` / writing the rollback backup.
> 4. Before invoking the atomic binary swap.
> 5. Before invoking `launchctl bootstrap` to start the new binary.
>
> Any transition from `eligible` to a notify-only verdict (per the
> trust-state table) between these phases MUST:
> - Abort the autoupdate sequence immediately.
> - Emit `failure_class:"trust_state_lost"` with a stable structured
>   reason naming the trigger (e.g., `encrypted_leg_invalidated`,
>   `tier_demoted`, `token_revoked`, `coordinator_disconnected`,
>   `attestation_state_degraded`).
> - Clean up partial state: release `update.lock`, delete any temp
>   downloads, delete any partial `pending.json` and rollback backup
>   that have not yet been atomically committed.
> - Refuse to retry autoupdate for the remainder of the session;
>   cooldown re-evaluation is performed on the next coordinator
>   session start.

Add `trust_state_lost` to the `failure_class` enum (R-6.5).

Add AC: "AC-V0.1-N: provider becomes eligible at v2 `auth_response`,
begins download, encrypted-leg is invalidated mid-download — no swap
occurs, `failure_class:"trust_state_lost"` event emitted, partial
state cleaned up, autoupdate refused for the remainder of the
session."

## Non-convergent — apply each fix

### A-r3-M-1: Drain wire `timeout_skipped` capability gate

Add to R-3.3 (drain wire amendment):

> **Coordinator capability gate.** The `drain_status.phase:"timeout_skipped"`
> value extends SPEC-001 §6.5's enum. Current coordinator code
> (`ParseDrainStatus`) rejects any phase outside `starting|in_progress|complete`.
> Therefore SPEC-020-capable providers MUST gate the emission of
> `timeout_skipped` on an explicit coordinator capability signal:
> the coordinator MUST advertise `autoupdate_drain_extensions:true`
> in the `hello_ack` or v2 `auth_response` payload. Providers that do
> not see this capability MUST emit `drain_status.phase:"complete"`
> instead of `timeout_skipped` (sacrificing observability for
> backward compatibility). Additionally, after a timeout-skipped
> swap, if the provider remains healthy and ready to serve, it MUST
> emit `state_update state:"ready"` so the coordinator's readiness
> accounting recovers.

### B-r3-M-1: Success-state cleanup

Add to R-4.10 (or new R-4.10a):

> **Success-state cleanup.** When the post-start observation succeeds
> (new binary passes local health AND rejoins the coordinator with
> `binary_version == target_version` within the post-start window),
> the observer MUST atomically:
> 1. Mark success in a structured event (`outcome:"success"`,
>    `phase:"post_start"`).
> 2. Delete `pending.json` via `unlink()`.
> 3. Delete the rollback backup at `<binary-dir>/.macprovider-cli.rollback-<update_id>`.
> 4. Release `update.lock` if still held.

State explicitly: "v0.1.0 deletes the rollback backup on success.
Multi-version rollback retention is deferred to v0.3.0."

### B-r3-M-2: `marker_deadline` semantics

Replace the bare `marker_deadline: RFC 3339 UTC string` line with:

> **`marker_deadline` semantics.** Writer: the autoupdate process at
> marker-write time. Basis: `marker_write_time + post_start_window + 5 min safety margin`.
> The post-start window is 60s per R-4.11 default; safety margin is
> 5 min to absorb local clock skew. Comparison rule: provider's local
> wall-clock (`Date()` / equivalent). Tolerance: ±5 minutes; deadlines
> outside this window are treated as malformed.
>
> Behavior:
> - **Missing or malformed**: treat marker as invalid; trigger
>   orphaned-marker recovery (R-4.8) with
>   `failure_class:"orphaned_pending_marker"`.
> - **Expired (now > marker_deadline + 5 min)**: trigger
>   orphaned-marker recovery same as above.
> - **Future beyond tolerance (marker_deadline > now + post_start_window + 30 min)**:
>   reject as evidence of clock manipulation or bad writer; treat
>   as malformed.

### B-r3-M-3: `v<TARGET>` normalization

Add to R-1.3:

> **Normalization.** Define `NORMALIZED_TARGET` as the target version
> with exactly one leading `v` or `V` character stripped if present.
> All downstream uses MUST use the normalized form:
> - Release lookup: try `v<NORMALIZED_TARGET>` first, then
>   `<NORMALIZED_TARGET>` (R-1.4).
> - Marker `target_version` field: `<NORMALIZED_TARGET>`.
> - Drain reason: `state_update.reason = "autoupdate_to_<NORMALIZED_TARGET>"`.
> - Cooldown key: `(NORMALIZED_TARGET, failure_class)`.

### B-r3-M-4: Post-start rollback failure_class mapping

Split R-4.11 triggers into explicit classes. Update R-6.5 enum to
include:
- `post_start_crash` — new binary exited within post-start window.
- `post_start_health_failed` — new binary started but local health
  check (e.g., `/healthz` probe) failed within window.
- `post_start_rejoin_timeout` — new binary did not rejoin coord with
  `binary_version == target_version` within window.

Update R-4.11: each trigger maps to exactly one of these failure
classes. Update AC-V0.1-10 to cover all three triggers and
classifications.

### C-r3-M-2: Signed-policy monotonic persistence

Add to R-2.2 (or new R-2.x):

> **Persisted monotonic signed-policy state.** The trusted state root
> at `$HOME/.local/share/macprovider/autoupdate/` MUST persist:
> - `persisted_signed_policy_minimum`: `max(observed signed_policy_minimum across all valid signed releases ever installed)`.
> - `persisted_signed_policy_revoked`: `union(observed signed_policy_revoked across all valid signed releases ever installed)`.
>
> Both are write-once-grow-only. Signed releases MAY only raise the
> persisted minimum and ADD revoked versions. A signed release that
> attempts to lower `signed_policy_minimum` or remove versions from
> `signed_policy_revoked` MUST NOT clear or shrink the persisted
> values; the autoupdate path applies the maximum/union of persisted
> + new-signed-content. Clearing requires operator-initiated
> repair/reinstall, not ordinary signed content.
>
> When computing eligibility:
> `effective_minimum_safe_binary_version = max(compiled_in_minimum, local_operator_minimum, persisted_signed_policy_minimum)`
> `effective_revoked_binary_versions = union(compiled_in_revoked, local_operator_revoked, persisted_signed_policy_revoked)`

Update T-8 (historical-replay threat): note that the persisted
monotonic invariant protects against attacker-controlled signed
release attempting to retroactively clear revocations.

### C-r3-M-3: SHA-256 prefix specification

Replace ambiguous "SHA-256 prefix" language with:

> **Oversized version redaction.** When the raw `recommended_binary_version`
> value exceeds 32 UTF-8 bytes, coordinator-visible payloads MUST omit
> the raw value and instead include a separate field:
> `recommended_binary_version_sha256: "<lowercase 64-hex digits>"`
> containing the full SHA-256 of the raw UTF-8 value. v0.1.0 uses
> full 64-hex digests; prefix truncation is forbidden.

## Process

1. Read v0.1.2 and `specs/SPEC-020-r3-audit.md`. Verify SPEC-008
   §10.5 still resolves; verify SPEC-001 §6.5 `drain_status.phase`
   enum is `starting|in_progress|complete` only.
2. Apply every fix listed above.
3. Bump version `v0.1.2` → `v0.1.3` (Status: Draft).
4. Add changelog entry citing absorbed IDs.
5. Verify `failure_class` enum now includes: `trust_state_lost`,
   `post_start_health_failed`, `post_start_rejoin_timeout`, plus all
   existing values.
6. Confirm AC count increased by at least 1 (for the live-invariant
   trust-state AC) and existing ACs reference normalized targets +
   updated failure classes where relevant.
7. Output: single edited `specs/SPEC-020-provider-autoupdate.md`. No
   other file edits.

You are absorbing — not re-auditing. Goal: r4 = 0/0/0.
