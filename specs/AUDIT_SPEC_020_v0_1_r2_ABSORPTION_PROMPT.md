# SPEC-020 v0.1.1 → v0.1.2 — r2 absorption prompt

You are absorbing round-2 audit findings into
`specs/SPEC-020-provider-autoupdate.md`. Bump the version header from
**v0.1.1** to **v0.1.2**, add a change-log entry, and apply every
finding listed in `specs/SPEC-020-r2-audit.md` according to the
auditors' proposed fixes.

**Bar to pass r3 audit:** 0 CRITICAL + 0 HIGH + 0 MEDIUM. Make every
r2 finding unreachable by r3.

## Findings to absorb

Read `specs/SPEC-020-r2-audit.md` for the full per-finding text. The
findings cluster into:

### Convergent — fold into combined sections

**T-1 Trust-state normative table** (A-r2-H-1 + C-r2-H-1, both HIGH):
Insert a normative trust-state table at the TOP of the "Cross-spec
amendment and trust state" section. Use the table provided in
`SPEC-020-r2-audit.md` T-1 verbatim. Minimum rows:

| Wire path | Tier | Encrypted-leg | Attestation (if required) | Token validation (if configured) | Verdict |
|---|---|---|---|---|---|
| Legacy `hello_ack` | — | — | — | — | notify-only |
| Unauthenticated / token-rejected | — | — | — | — | notify-only |
| v2 `auth_response` rejected | — | — | — | — | notify-only |
| v2 accepted | provisional | * | * | * | notify-only |
| v2 accepted | provisional (self-minted, bearerless-duplicate) | * | * | * | notify-only |
| v2 accepted | pinned | failed | * | * | notify-only |
| v2 accepted | pinned | succeeded with matching AEAD/KID | failed | * | notify-only |
| v2 accepted | pinned | succeeded with matching AEAD/KID | satisfied or not-required | rejected | notify-only |
| v2 accepted | pinned | succeeded with matching AEAD/KID | satisfied or not-required | validated or not-configured | **eligible** |

Add: "Implementations MUST store an explicit `autoupdate_trust_state`
field per coordinator session and MUST NOT derive eligibility from
`recommended_binary_version` alone."

Also explicitly state: "v2 encrypted-leg negotiation is REQUIRED for
eligibility regardless of whether Tier2 attestation is configured.
Tier2-attestation-not-required deployments are eligible only when
encrypted-leg succeeded with matching AEAD/KID."

**T-2 Trusted state root + marker hardening** (B-r2-M-1 + B-r2-M-2 + C-r2-M-2):

Add a new "Trusted state root" subsection under R-4 (or new R-7):

- `$HOME/.local/share/macprovider` and `$HOME/.local/share/macprovider/autoupdate`
  MUST be created or repaired as provider-UID-owned, mode 0700.
- Implementations MUST reject if any path component is a symlink, not
  owned by the provider UID, has group/world write, has non-owner-write
  ACLs, or crosses an unexpected device/mount boundary.
- `update.lock` MUST be opened with `O_CREAT|O_NOFOLLOW` mode 0600, and
  the implementation MUST take an advisory `flock(LOCK_EX|LOCK_NB)` (or
  `fcntl(F_SETLK)`) before doing any state mutation. A stale lockfile
  without a live process holding the lock is NOT contention.
- `pending.json` and rollback-backup temp files MUST use `O_CREAT|O_EXCL|O_NOFOLLOW`
  on create, `fsync()` file + parent directory, then atomic rename.

Expand R-4.6 marker schema with explicit JSON types:
- `update_id`: lowercase UUIDv4 (RFC 4122 §3, 36-char canonical form).
- `target_version`: semver string matching the validation regex.
- `target_path`: absolute path string, no trailing slash.
- `backup_path`: absolute path string, no trailing slash.
- `size`: JSON integer, bytes.
- `mode`: JSON integer, decimal representation of the octal mode
  (e.g., 493 for 0o755). Document explicitly: "decimal int of the
  octal mode value; e.g., `0o755` is serialized as `493`."
- `sha256`: lowercase 64-hex.
- `marker_deadline`: RFC 3339 UTC string (e.g., `2026-06-29T15:00:00Z`).

### Non-convergent — apply each fix

**T-3 SPEC-001 §6.7 citation precision** (A-r2-M-1):
Replace the SPEC-001 §6.7 reference for v2 auth_response with
**SPEC-008 §10.5** (or whichever section actually defines the v2
auth_response schema — verify in the worktree before citing). Keep
SPEC-001 §6.5 for legacy `hello_ack`.

**T-4 Drain wire contract** (A-r2-M-2):
- Add to R-3.1: a mandatory machine-readable autoupdate discriminator.
  Pin format: `state_update.reason = "autoupdate_to_<TARGET>"` where
  `<TARGET>` is the validated version string. This MUST be a stable
  format, NOT "such as".
- Add to R-3.3: the `drain_status.phase` enum is extended to include
  `timeout_skipped` for SPEC-020-capable coordinators. Note this
  extends SPEC-001 §6.5's enum; coordinators implementing SPEC-020
  MUST accept the additional value without rejecting the frame.

**B-r2-M-3 Partial rollback recovery**:
Add startup/watchdog recovery state machine for invalid pending
markers:
- If `pending.json` exists but `update.lock` is unheld AND no observer
  process is running: classify as orphaned. Emit
  `failure_class:"orphaned_pending_marker"`. Delete the marker.
  Restore from backup if backup is valid (size + hash match);
  otherwise quarantine the marker by renaming to
  `pending-quarantined-<timestamp>.json` and disable autoupdate
  until operator clears.
- If `pending.json` references a `backup_path` that is missing OR
  hash-mismatched: emit `failure_class:"rollback_backup_corrupt"`,
  do NOT delete the live binary (no rollback possible), disable
  autoupdate for the session, surface a structured event.

**B-r2-M-4 Release-asset-missing failure class**:
Add `release_asset_missing` to the `failure_class` enum. Update R-1.4:
when the release tag exists but the required tarball/checksum/
signature asset is missing, emit `failure_class:"release_asset_missing"`,
no download, enter cooldown for that target. Add an AC covering this.

**B-r2-M-5 4096-byte bound clarification**:
Replace R-6.3 + AC-V0.1-17 4096-byte language with:
"The `last_autoupdate_event` value MUST serialize to ≤4096 UTF-8 bytes
when JSON-minified (no whitespace), measured AS THE EVENT OBJECT
ALONE, before embedding in any wrapping heartbeat or state_update
payload. Implementations MUST drop optional fields (in priority order:
`extra_metadata`, `attempt_history`, `release_url`, free-text `reason`)
rather than truncate JSON strings. If the bound is unreachable after
dropping all optional fields, emit `failure_class:"event_payload_too_large"`
with a minimal stable payload."

**C-r2-M-1 Revocation provenance + precedence**:
Add to R-2.2 (or new R-2.x):
- `effective_minimum_safe_binary_version = max(compiled_in_minimum, local_operator_minimum, signed_policy_minimum if introduced in v0.2.0)`
- `effective_revoked_binary_versions = union(compiled_in_revoked, local_operator_revoked, signed_policy_revoked if introduced in v0.2.0)`
- Coordinator-advertised fields and recommendations MUST NEVER lower
  the effective floor or remove versions from the effective revoked
  set. This is a monotonic invariant.
- Amend T-8: v0.1.0 empty defaults are a hook, NOT active protection
  until a non-empty local baseline ships.

**C-r2-M-3 Version-string length bound**:
Add to R-1.3 (version validation):
- Maximum length: 32 UTF-8 bytes for the entire `recommended_binary_version` value.
- Maximum length per numeric component: 8 digits.
- Oversized values → `failure_class:"recommended_version_invalid"` with reason `version_too_long` or `version_component_too_long`.
- Coordinator-visible payloads MUST omit the raw oversized value OR substitute its SHA-256 prefix; MUST NOT log full attacker-controlled string.

## Process

1. Read `specs/SPEC-020-provider-autoupdate.md` v0.1.1, `specs/SPEC-020-r2-audit.md`, and the SPEC-008 file to verify the §10.5 citation for v2 auth_response.
2. Apply every fix listed above verbatim or near-verbatim. Renumber R-N.M as needed.
3. Bump version header `v0.1.1` → `v0.1.2` (Status stays `Draft`).
4. Add a change-log entry listing absorbed findings (cite IDs).
5. Verify the trust-state table is markdown-renderable and matches the rows in this prompt.
6. Verify `failure_class` enum now includes: `release_asset_missing`, `orphaned_pending_marker`, `rollback_backup_corrupt`, `event_payload_too_large`, `version_too_long`, plus existing values.
7. Output: a single edited `specs/SPEC-020-provider-autoupdate.md`. No other file edits.

You are absorbing — not re-auditing. Goal: r3 = 0/0/0.
