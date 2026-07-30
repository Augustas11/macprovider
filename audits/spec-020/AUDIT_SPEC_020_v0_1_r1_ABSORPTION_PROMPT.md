# SPEC-020 v0.1.0 → v0.1.1 — r1 absorption prompt

You are absorbing round-1 audit findings into
`specs/SPEC-020-provider-autoupdate.md`. Bump the version header from
**v0.1.0** to **v0.1.1**, add a change-log entry, and apply every
finding listed in `specs/SPEC-020-r1-audit.md` according to the "Fix"
text the auditor provided.

**Bar to pass r2 audit:** 0 CRITICAL + 0 HIGH + 0 MEDIUM. Your job is
to make every finding from r1 unrechabable by r2.

## Findings to absorb (verbatim references)

Read `specs/SPEC-020-r1-audit.md` for the structured table + per-finding
proposed fixes. The findings cluster into:

### Convergent (3+ lanes) — fold into combined sections

**T-1 Rollback observer + marker/backup hardening** (A-r1-H-3, B-r1-M-4, C-r1-M-3):
Add an R-4 (or new R-7) subsection that combines:
- Autoupdate eligibility MUST fail closed if watchdog/equivalent rollback observer is absent (`failure_class:"rollback_observer_unavailable"`).
- Pending marker path: `$HOME/.local/share/macprovider/autoupdate/pending.json`, UTF-8 JSON, atomic write (temp + fsync + rename), mode 0600.
- Exclusive lock path: `$HOME/.local/share/macprovider/autoupdate/update.lock`; on contention emit `failure_class:"autoupdate_already_pending"`.
- Rollback backup path: `<binary-dir>/.macprovider-cli.rollback-<update_id>`, mode 0700 directory ancestry owned by provider UID.
- Marker schema MUST include: update_id, target_version, target_path, backup_path, size, mode, SHA-256, marker_deadline.
- Both marker and backup MUST be opened with symlink-following disabled; watchdog MUST `lstat` and reject symlinks / unexpected hard links; MUST verify backup SHA-256 before restore.

**T-2 Observability schema + secret-leak prevention** (A-r1-M-2, B-r1-M-6, C-r1-M-4):
Rewrite §R-6 to:
- Call out `last_autoupdate_event` as a SPEC-001 wire-schema extension on heartbeat / state_update payloads. Coordinators implementing SPEC-020 MUST accept; providers MUST tolerate older coords ignoring the field.
- Enumerate enums:
  - `source`: `coordinator|github_poll|manual`
  - `outcome`: `success|failure|skipped|noop|in_progress`
  - `phase`: `detection|eligibility|cooldown|free_space|download|signature|checksum|archive|self_test|drain|backup|swap|restart|post_start|rollback`
  - `failure_class` enum: list explicitly (rollback_observer_unavailable, target_release_not_found, recommended_version_invalid, autoupdate_already_pending, target_revoked_or_below_minimum, signature_invalid, checksum_mismatch, self_test_failed, drain_timeout, post_start_crash, insufficient_disk_space, other).
- Size bound: `last_autoupdate_event` MUST serialize to ≤4096 bytes.
- Redaction invariant: payloads MUST NOT include provider tokens, Authorization headers, credentials, signing private key material, raw checksum/signature contents, full redirect URLs with query strings, or absolute local paths/usernames in coordinator-visible payloads. Free-text error strings MUST be redacted or mapped to stable reason/failure enums.

**T-3 Cross-spec amendment + trust state for trigger** (A-r1-H-1, C-r1-H-1):
Add a new section "Cross-spec amendment and trust state" placed before "Normative requirements" (or as the opening of R-1). Content:
- Names `coordinator_advertised_version.latest_binary_version` as the authoritative coordinator-side source (operator-set); policy for choosing the value is out of scope for this SPEC.
- States SPEC-020 supersedes the notify-only treatment of `recommended_binary_version` in `SPEC-001-phase3-binary.md` §6.5/§6.7 ONLY for SPEC-020-capable providers AND ONLY after the strongest configured coordinator authentication path has succeeded.
- Trust state required to trigger autoupdate: v2 `auth_response` accepted with matching Tier2 encrypted-leg parameters, plus provider-token/pinned authentication when configured. Legacy hello_ack-only, unauthenticated, provisional, or failed-Tier2 sessions remain notify-only and MUST NOT trigger download, drain, swap, marker creation, or cooldown.
- `required_binary_version` enforcement (the existing admission gate) is unchanged.

### Non-convergent HIGH findings

**A-r1-H-2 Convergence boundary**:
Add a "Convergence boundary" paragraph (next to Non-goals or as R-x.y):
"SPEC-020 guarantees convergence to latest only for default-installed, launchd-managed providers with autoupdate enabled and rollback observation available. Providers with explicit opt-out, missing/disabled watchdog, or unsupported install topology are outside the latest-assumption population. Future features that depend on latest-provider behavior MUST exclude old binaries via the existing `required_binary_version` admission gate or an equivalent explicit gate."

### Non-convergent MEDIUM findings (apply each Fix verbatim)

- **A-r1-M-1 drain protocol distinction**: add paragraph distinguishing provider-initiated autoupdate drain from coord-initiated drain.
- **A-r1-M-3 version comparator binding**: replace the comparator sentence with "MUST use `SelfUpdate.compareSemver` or a single shared implementation byte-for-byte behavior-equivalent. Manual update, coordinator recommendation handling, downgrade refusal, and status display MUST all use that same comparator."
- **B-r1-M-1 release-by-tag**: add R-x.y "For coordinator-triggered autoupdate, the provider MUST resolve the target via the GitHub release-by-tag endpoint, trying `v<TARGET>` first then `<TARGET>` when the tag omits `v`. MUST NOT use `/releases/latest` for coordinator-triggered installation. On miss → `failure_class:"target_release_not_found"`, no download, cooldown."
- **B-r1-M-2 version regex**: add validation `^[vV]?[0-9]+\.[0-9]+\.[0-9]+$`; missing/empty = no trigger; malformed = `failure_class:"recommended_version_invalid"`.
- **B-r1-M-3 backoff math**: replace SHOULD with `cooldown = min(300s * 2^(attempt-1), 3600s)`, 3600s cap fixed v0.1.0.
- **B-r1-M-5 opt-out compat**: accept BOTH `auto_update_enabled` and `autoupdate.enabled`; BOTH `MACPROVIDER_AUTO_UPDATE_ENABLED` and `MACPROVIDER_AUTOUPDATE`; explicit disabled wins.
- **C-r1-M-1 revocation hook**: add R-x.y "Autoupdate MUST fail closed for target versions below `minimum_safe_binary_version` or in `revoked_binary_versions`. v0.1.0 MAY ship compiled-in empty defaults; the hook, event, and precedence are normative. Coord MUST NOT override. Failure → `failure_class:"target_revoked_or_below_minimum"`." Also add T-8 (or new threat number) for signed historical-release replay.
- **C-r1-M-2 key rotation**: add policy paragraph: "Checksum verification key set is a binary-baked trust root. Planned rotation MUST ship a transition release trusted by the old key and carrying the new key before releases require the new key; transition assets SHOULD publish signatures under both keys. If old key is suspected compromised, providers trusting only that key MUST be recovered by out-of-band reinstall or other operator-controlled trust-root replacement, not by ordinary autoupdate."

### Non-blocking notes to address

- Fix the citation typo: the SPEC must reference `specs/SPEC-001-phase3-binary.md`, NOT `specs/SPEC-001-provider-discovery.md`.
- Optionally add a sentence to drain section: "No new attestation/preflight/inference admission may be represented as `ready` once autoupdate drain begins" (per C's non-blocking note).

## Process

1. **Read** `specs/SPEC-020-provider-autoupdate.md` v0.1.0 and `specs/SPEC-020-r1-audit.md`.
2. **Apply** every finding's Fix text verbatim or near-verbatim. Renumber R-N.M as needed; keep existing R-N.M numbers where possible.
3. **Bump** the version header from `v0.1.0` to `v0.1.1` (Status stays `Draft`).
4. **Add** a change-log entry with bullet list of the absorbed findings (citing IDs A-r1-H-1, etc.).
5. **Verify** every cross-spec citation resolves to a real file in the worktree.
6. **Output**: a single edited `specs/SPEC-020-provider-autoupdate.md`. No other file edits.

You are absorbing — not re-auditing. Do not invent additional findings.
Do not change scope. The goal is r2 = 0/0/0.
