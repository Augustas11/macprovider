# SPEC-020 v0.1.0 — Round 1 audit narrative

**Anchor:** `spec/020-provider-autoupdate` worktree at HEAD (post-draft commit pending)
**Audited SPEC:** `specs/SPEC-020-provider-autoupdate.md` v0.1.0 (DRAFT)
**Round:** r1
**Lanes:** 3 codex (architect, code, security)

## Per-lane verdicts

| Lane | Verdict | C | H | M | Notes |
|---|---|---|---|---|---|
| A architect (codex) | NEEDS REVISION | 0 | 3 | 3 | SPEC-001 amendment, convergence boundary, watchdog mandate, drain semantics, wire-schema, comparator binding |
| B code (codex) | NEEDS REVISION | 0 | 0 | 6 | Release-by-tag, version regex, backoff math, marker/backup path, opt-out compat, observability enums |
| C security (codex) | NEEDS REVISION | 0 | 1 | 4 | Trust state for trigger, revocation hook, key rotation, marker hardening, secret-leak prevention |

**Totals: 0 CRITICAL, 4 HIGH, 13 MEDIUM** across 3 lanes.

## Convergent themes (≥2 lanes)

### T-1: Rollback observer + marker/backup hardening (3 lanes)

Lanes: A-r1-H-3, B-r1-M-4, C-r1-M-3.

The SPEC delegates rollback to the existing watchdog but:
- A says watchdog presence must be an autoupdate **eligibility** precondition; the current watchdog is opt-out-able via `MACPROVIDER_NO_WATCHDOG=1` and must be extended.
- B says marker path, backup filename, JSON format, locking, and concurrent-update semantics are unspecified.
- C says marker + backup ownership, permissions, atomic-write semantics, symlink rejection, lstat checks, and backup hash verification are unspecified.

**Combined absorption**: add an R-x.y subsection "Rollback observer + marker/backup format" that mandates watchdog/equivalent observer as eligibility precondition (fail-closed `rollback_observer_unavailable` otherwise), pins exact paths, file modes, owner UID, atomic write semantics, exclusive lock, symlink/hardlink rejection, marker schema, and hash-on-restore verification.

### T-2: Observability schema + secret-leak prevention (3 lanes)

Lanes: A-r1-M-2, B-r1-M-6, C-r1-M-4.

- A says `last_autoupdate_event` is a SPEC-001 wire-schema extension and must be called out.
- B says the structured event schema is unpinned (`source`, `outcome`, `phase`, `failure_class` enums all free-text; size bound unstated).
- C says payloads must be redacted (no tokens, no auth headers, no signed-URL query strings, no absolute local paths, no usernames).

**Combined absorption**: rewrite §R-6 to (a) call out the SPEC-001 wire-schema extension with backward-compat clause for old coordinators, (b) enumerate the four enums + 4096-byte size bound, (c) explicit redaction invariant for coordinator-visible payloads.

### T-3: Cross-spec amendment + trust state for trigger (2 lanes, both HIGH)

Lanes: A-r1-H-1, C-r1-H-1.

- A says SPEC-020 turns SPEC-001's optional/informational `recommended_binary_version` into the primary autoupdate trigger but does not normatively amend SPEC-001 or pin authoritative source `coordinator_advertised_version.latest_binary_version`.
- C says SPEC-020 must require the strongest configured coordinator authentication (v2 auth_response + Tier2 + pinned/provider-token where configured) before honoring the recommendation; legacy/provisional/unauth sessions are notify-only.

**Combined absorption**: add a "Cross-spec amendment / coordinator contract" subsection (preferably before R-1) that:
- Names `coordinator_advertised_version.latest_binary_version` as authoritative source (operator-set).
- States SPEC-020 supersedes SPEC-001's notify-only treatment of `recommended_binary_version` ONLY for SPEC-020-capable providers AND ONLY after the strongest configured authentication path succeeds.
- Legacy / provisional / unauthenticated / failed-Tier2 sessions remain notify-only.

## Non-convergent findings (still must absorb)

### A-r1-H-2 — Convergence boundary unstated
SPEC frames autoupdate as the version-skew fix future SPECs can rely on, but R-5 allows opt-out and watchdog can be disabled. Fix: add explicit convergence-boundary paragraph, recommend `required_binary_version` admission gate at coord for features that need latest.

### A-r1-M-1 — Drain protocol distinction
SPEC reuses SPEC-001's `state_update state:"draining"` but doesn't distinguish autoupdate-drain (provider-initiated, terminates with launchd restart) from coordinator-initiated drain (must not exit, must reconnect within 15s). Fix: add distinguishing paragraph.

### A-r1-M-3 — Version comparator binding
SPEC says "provider semver comparator" but doesn't bind to `SelfUpdate.compareSemver` byte-for-byte. Fix: replace sentence with normative "MUST use `SelfUpdate.compareSemver` or a single shared implementation byte-for-byte behavior-equivalent".

### B-r1-M-1 — Resolve target via release-by-tag
Existing `SelfUpdate.run` uses `/releases/latest`; SPEC-020 requires installing the coordinator's exact `recommended_binary_version`. Fix: add R-x.y "GitHub release-by-tag endpoint, `v<TARGET>` then `<TARGET>`; on miss → `failure_class:"target_release_not_found"`, no download, cooldown".

### B-r1-M-2 — Recommended-version regex validation
Malformed/empty values silently coerce to `0`. Fix: regex `^[vV]?[0-9]+\.[0-9]+\.[0-9]+$`; missing/empty = no trigger; malformed = `failure_class:"recommended_version_invalid"`, no state mutation.

### B-r1-M-3 — Concrete backoff math
"SHOULD" backoff is not testable. Fix: replace with explicit formula `cooldown = min(300s * 2^(attempt-1), 3600s)`, 3600s cap fixed in v0.1.0.

### B-r1-M-5 — Opt-out config-key compatibility
Current loader already has `auto_update_enabled` / `MACPROVIDER_AUTO_UPDATE_ENABLED`; SPEC introduces `autoupdate.enabled` / `MACPROVIDER_AUTOUPDATE`. Fix: accept both; explicit disabled wins over enabled.

### C-r1-M-1 — Revocation / denylist hook
Downgrade refusal doesn't cover historical-release-with-known-vuln. Fix: add R-x.y normative hook `minimum_safe_binary_version` + `revoked_binary_versions`; v0.1.0 may default empty but the hook is normative; coord MUST NOT override; `failure_class:"target_revoked_or_below_minimum"`. Also add a threat entry for signed historical-release replay.

### C-r1-M-2 — Key rotation policy
SPEC silent on ECDSA P-256 key rotation. Fix: add policy paragraph — transition release trusted by old key + carrying new key; dual-signed assets during transition; compromise → out-of-band reinstall, not ordinary autoupdate.

## Non-blocking notes captured

- B's note: SPEC-001 filename in BUILD prompt was `SPEC-001-provider-discovery.md` but actual is `SPEC-001-phase3-binary.md`. BUILD prompt typo; absorption will use the correct filename when citing.
- B's note: `SelfUpdate.swift` lacks free-space checks, rollback staging, structured events, autoupdate opt-out enforcement, persistent cooldown, and bounded autoupdate drain. These are explicit IMPL work; the SPEC correctly names them.
- C's note: disk-space failure is safe as written (R-2.7 + R-2.10).
- C's note: drain currently doesn't forbid attestation/preflight admission during drain; consider adding to absorption.

## Raw artifacts

- Lane A architect: `.omc/artifacts/ask/codex-spec-020-v0-1-0-round-1-audit-prompt-per-lane-you-are-auditi-2026-06-29T14-53-18-758Z.md`
- Lane B code: `.omc/artifacts/ask/codex-spec-020-v0-1-0-round-1-audit-prompt-per-lane-you-are-auditi-2026-06-29T14-53-31-832Z.md`
- Lane C security: `.omc/artifacts/ask/codex-spec-020-v0-1-0-round-1-audit-prompt-per-lane-you-are-auditi-2026-06-29T14-53-17-255Z.md`

## Next action

Absorb r1 findings into `specs/SPEC-020-provider-autoupdate.md`, bump version to v0.1.1, then fire r2 audit. Absorption prompt: `specs/AUDIT_SPEC_020_v0_1_r1_ABSORPTION_PROMPT.md`.
