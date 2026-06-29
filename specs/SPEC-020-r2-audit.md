# SPEC-020 v0.1.1 — Round 2 audit narrative

**Audited SPEC:** `specs/SPEC-020-provider-autoupdate.md` v0.1.1 (DRAFT)
**Round:** r2
**Lanes:** 3 codex (architect, code, security)

## Per-lane verdicts

| Lane | Verdict | C | H | M | Notes |
|---|---|---|---|---|---|
| A architect (codex) | NEEDS REVISION | 0 | 1 | 2 | Trust-state table needed; SPEC-001 §6.7 citation maps to SPEC-008; drain wire contract |
| B code (codex) | NEEDS REVISION | 0 | 0 | 5 | Marker schema types, flock semantics, partial-rollback recovery, missing-asset class, byte-bound clarity |
| C security (codex) | NEEDS REVISION | 0 | 1 | 3 | Trust-state matrix (= A's HIGH); revocation provenance precedence; FS hardening (ancestor symlinks, ACLs, O_NOFOLLOW); version-string length bound |

**Totals: 0 CRITICAL, 2 HIGH, 10 MEDIUM** (down from r1's 0/4/13).

## Convergent themes

### T-1: Trust-state requires normative table (2 lanes, both HIGH)

A-r2-H-1 + C-r2-H-1. Both lanes converge: v0.1.1's prose "strongest configured authentication" + "matching Tier2 encrypted-leg parameters" is ambiguous. Implementations could read it as fail-closed-forever for Tier2-unconfigured deployments, OR fall back to weaker legacy session for code install. Both lanes propose the same fix shape: a normative matrix table.

**Combined absorption**: insert a normative trust-state table at the top of "Cross-spec amendment and trust state" listing every coordinator session-state combination → notify-only OR autoupdate-eligible. Minimum rows:

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

Also require: implementations store an explicit `autoupdate_trust_state` field and MUST NOT derive eligibility directly from `recommended_binary_version` alone.

### T-2: Marker/lock filesystem hardening details (B + C)

B-r2-M-1, B-r2-M-2, C-r2-M-2. Lane B says marker JSON field types are unspecified (RFC3339 vs epoch; octal vs decimal mode) and lock-file semantics are unpinned (lockfile-existence vs `flock`). Lane C adds: state-root directory ownership/mode, ancestor symlinks, ACLs, mount-point crossings, and O_NOFOLLOW on open are all unspecified.

**Combined absorption**: add a "Trusted state root" subsection that pins:
- `$HOME/.local/share/macprovider` and `$HOME/.local/share/macprovider/autoupdate` MUST be provider-UID-owned, mode 0700.
- Implementations MUST reject if any path component is a symlink, not provider-owned, group/world-writable, has non-owner-write ACLs, or crosses an unexpected device/mount boundary.
- `update.lock` MUST be opened with `O_CREAT|O_NOFOLLOW` mode 0600 and use an advisory `flock`/`fcntl` exclusive lock. A stale lockfile without a live process holding the lock is NOT contention.
- `pending.json` and rollback-backup temp files MUST use `O_CREAT|O_EXCL|O_NOFOLLOW` for create, `fsync()` file + parent directory, then atomic rename.

And add a marker schema table to R-4.6 pinning JSON types:
- `update_id`: lowercase UUIDv4 hex (36 chars with dashes) or 64-hex (TBD pick).
- `target_version`: semver string matching the validation regex.
- `target_path`: absolute path string, no trailing slash.
- `backup_path`: absolute path string, no trailing slash.
- `size`: bytes, JSON integer.
- `mode`: octal integer (e.g., 493 = 0o755) — pick one and document.
- `sha256`: lowercase 64-hex.
- `marker_deadline`: RFC3339 UTC string (pick one over epoch).

### T-3: SPEC-001 §6.7 citation precision (A only)

A-r2-M-1. v0.1.1 cites SPEC-001 §6.7 as the v2 auth_response section, but §6.7 is actually the auth_request section. The v2 auth_response schema lives in SPEC-008 §10.5. Fix: amend the citation to SPEC-008 §10.5 for v2 auth_response treatment, keep SPEC-001 §6.5 for legacy `hello_ack`.

### T-4: Drain wire contract (A only)

A-r2-M-2. R-3.3 introduces `drain_status.phase: timeout_skipped` but SPEC-001 §6.5 only allows `starting|in_progress|complete`. Coordinator parser enforces that set today. R-3.1's "reason such as `autoupdate_to_vX.Y.Z`" is "such as" — not a mandatory discriminator.

**Fix**: add a cross-spec wire amendment requiring a mandatory machine-readable autoupdate drain discriminator (either exact `state_update.reason` format or new structured field). Add `timeout_skipped` to the `drain_status.phase` enum normatively for SPEC-020-capable coordinators.

## Non-convergent r2 findings

### B-r2-M-3 — Partial rollback state recovery
If `pending.json` exists but the backup is missing/hash-mismatched, R-4.8 says the observer rejects it, but does not say whether to quarantine/delete the marker, emit a class, block future updates, or require operator repair. Fix: add startup/watchdog recovery state machine for invalid pending markers.

### B-r2-M-4 — Release-asset-missing failure class
Existing `SelfUpdate.swift:53` has a concrete `missingAsset` path when tag exists but tarball is missing. v0.1.1 lumps this into `other`. Fix: add `release_asset_missing` or extend `target_release_not_found` semantics + AC coverage.

### B-r2-M-5 — 4096-byte bound clarity
R-6.3 bounds "serialized `last_autoupdate_event` value"; AC-V0.1-17 says heartbeat + state_update payloads serialize to ≤4096 bytes. Mismatch. Fix: pin to UTF-8 bytes of minified JSON for `last_autoupdate_event` ALONE before embedding; update AC to match.

### C-r2-M-1 — Revocation provenance + monotonic precedence
v0.1.1 says v0.1.0 ships empty defaults and coord cannot override, but provenance/precedence is fuzzy. Fix: define `effective_minimum_safe_binary_version = max(compiled_in, local_operator, signed_policy)` and `effective_revoked = union(...)`. Coord-advertised fields can NEVER lower the floor or remove revoked versions.

### C-r2-M-3 — Version-string length bound
`recommended_binary_version` is regex-validated but length-unbounded. A 5000-byte semver-shaped string would blow the 4096-byte event bound. Fix: cap input at 32 bytes total. Oversized → `failure_class:"recommended_version_invalid"` with reason `version_too_long`. Coordinator-visible payloads MUST omit or hash raw oversized values.

## Non-blocking observations captured by lanes

- Lane A: comparator binding to `SelfUpdate.compareSemver` is testable ✓
- Lane B: SPEC-001 §6.5/§6.7 resolve ✓; failure_class values are all in the R-6.5 enum ✓
- Lane C: key rotation policy is acceptable — R-2.3/R-2.4 imply new-key-only release with old-key provider fails closed before self-test/swap ✓

## Trend

r1 → r2: -2 HIGH, -3 MEDIUM. Both r2 HIGHs are convergent ratchets of r1 findings (trust state still prose → must become table). r2 MEDIUMs are mostly normative-detail tightening (file paths, modes, byte bounds, enum gaps). No new categorical gaps emerged. Strong signal that one more absorption + r3 audit should land at 0/0/0.

## Next action

Absorb r2 findings → SPEC-020 v0.1.2. Absorption prompt: `specs/AUDIT_SPEC_020_v0_1_r2_ABSORPTION_PROMPT.md`.

## Raw artifacts

- Lane A: `.omc/artifacts/ask/codex-spec-020-v0-1-1-round-2-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-06-29-464Z.md`
- Lane B: `.omc/artifacts/ask/codex-spec-020-v0-1-1-round-2-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-05-15-865Z.md`
- Lane C: `.omc/artifacts/ask/codex-spec-020-v0-1-1-round-2-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-05-44-850Z.md`
