# SPEC-020 v0.1.2 — Round 3 audit narrative

**Audited SPEC:** `specs/SPEC-020-provider-autoupdate.md` v0.1.2 (DRAFT)
**Round:** r3
**Lanes:** 3 codex (architect, code, security)

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect | NEEDS REVISION | 0 | 1 | 1 |
| B code | NEEDS REVISION | 0 | 0 | 4 |
| C security | NEEDS REVISION | 0 | 0 | 3 |

**Totals: 0 CRITICAL, 1 HIGH, 8 MEDIUM** (down from r2: 0/2/10).

Trend r1→r2→r3:
- HIGH: 4 → 2 → 1
- MEDIUM: 13 → 10 → 8

## Convergent theme (2 lanes)

### T-1: Trust state must be a LIVE invariant (A=HIGH, C=MEDIUM)

A-r3-H-1 + C-r3-M-1. Both lanes converge on the same root cause:
v0.1.2's trust-state table is correct AT HANDSHAKE TIME but
`autoupdate_trust_state` is stored "per coordinator session" and
evaluated once. SPEC-008 has rekey/restart lifecycle transitions, so
mid-session trust degradation is realistic — and v0.1.2 doesn't say
re-evaluate before download / drain / marker / swap.

Failure modes both lanes name:
- v2 pinned encrypted session whose encrypted-leg fails or rekeys
  mid-session.
- Coordinator restart invalidating Pillar B keys.
- Token-valid session that is revoked / kicked before swap.
- Attestation state degradation mid-session.

**Combined absorption**: define `autoupdate_trust_state` as a LIVE
session predicate. The provider MUST re-evaluate eligibility
immediately before each irreversible phase (download begins, drain
entry, marker / backup creation, swap, restart). Any transition from
`eligible` to a notify-only verdict between phases MUST abort, emit
`failure_class:"trust_state_lost"`, clean up partial state (lock,
temp downloads, partial marker), and refuse to re-attempt for the
remainder of the session.

Add AC: "eligible at v2 auth_response, then encrypted-leg invalidated
before swap → no swap occurs; event emitted; clean shutdown."

## Non-convergent r3 findings

### A-r3-M-1 — Drain wire `timeout_skipped` capability gate

v0.1.2 documents `drain_status.phase:"timeout_skipped"` as a
SPEC-020 extension but current coordinator's `ParseDrainStatus`
rejects any phase not in `starting|in_progress|complete`.
`recommended_binary_version` cannot serve as a SPEC-020 capability
signal because current coords already emit it. Fix: either (a)
require coord-side amendment/release that accepts `timeout_skipped`
before provider autoupdate is enabled, or (b) add an explicit coord
capability field in `hello_ack` / `auth_response`. Also: require
`state_update state:"ready"` after a skip if the provider remains
healthy.

### B-r3-M-1 — Success-state cleanup

v0.1.2 defines write, orphan recovery, and rollback-on-failure for
`pending.json` + rollback backup, but does not define when a
successful post-start observation deletes them. A later startup can
see unheld `update.lock` + stale `pending.json` and treat a
successful update as orphaned. Fix: after the new binary passes local
health and rejoins coord with `binary_version == target_version`,
atomically mark success, delete `pending.json`, and either delete or
retain/quiesce the rollback backup (pick one).

### B-r3-M-2 — `marker_deadline` semantics

RFC 3339 typed but no writer / basis / comparison rule / clock-skew
tolerance. Fix: define writer (autoupdate process at marker-write
time), basis (now + max(post-start window) + safety margin),
comparison rule (provider local clock), tolerance window (e.g., ±5
minutes), and behavior if missing / malformed / expired / future-
beyond-tolerance.

### B-r3-M-3 — `v<TARGET>` normalization

R-1.3 allows optional leading `v`/`V` in `recommended_binary_version`;
R-1.4 says try `v<TARGET>` first. If coord sends `v1.7.0`, a literal
implementation probes `vv1.7.0` → fails. Fix: define
`NORMALIZED_TARGET = target with exactly one leading v/V stripped`.
Use `v<NORMALIZED_TARGET>` then `<NORMALIZED_TARGET>` for release
lookup, same normalized value in marker, cooldown key, drain reason
field.

### B-r3-M-4 — Post-start rollback failure_class mapping

R-4.11 covers post-start crash, failed start, failed local health,
and coord rejoin timeout but only R-6.5 has `post_start_crash`. Fix:
either map ALL four R-4.11 triggers to `post_start_crash`, or split
into `post_start_crash`, `post_start_health_failed`,
`post_start_rejoin_timeout` (and update R-6.5 + AC-V0.1-10).

### C-r3-M-2 — `signed_policy_revoked` monotonic persistence

Monotonic rule says coord-advertised fields can't lower the floor,
but `signed_policy_revoked` is signed content. An attacker with
signing-key control (or accidental bad release) can publish an empty
signed policy and erase prior signed revocations. Fix: provider MUST
persist `max(observed signed_policy_minimum)` and
`union(observed signed_policy_revoked)` in the trusted state root.
Signed policies can only RAISE the minimum and ADD revoked versions.
Clearing requires operator repair / reinstall, not signed content.

### C-r3-M-3 — SHA-256 prefix length

Oversized `recommended_binary_version` may be substituted with a
"SHA-256 prefix" but length is unspecified. Fix: pick exactly. Prefer
full lowercase 64-hex; if prefix required, ≥128 bits / 32 hex chars
under explicit field name `recommended_binary_version_sha256_prefix`.

## Non-blocking observations

- Lane B confirmed citations resolve: SPEC-008 §10.5 has v2
  auth_response with `recommended_binary_version`; SPEC-001 §6.5 has
  legacy `hello_ack`, `state_update`, and `drain_status.phase`.
- Lane B noted AC count is now 21 (was 17 in v0.1.1), accounting for
  the +4 ACs added in r2 absorption.
- Lane C confirmed trust-state table is complete for handshake-time;
  SPEC-008 §10.5 citation is correct; macOS ACL/firmlink language is
  adequate at spec level given the inherited-write ACL guard.

## Next action

Absorb r3 findings → SPEC-020 v0.1.3. Live-invariant trust state is
the load-bearing fix; the rest is normative-detail tightening. r4
should land at 0/0/0.

## Raw artifacts

- Lane A architect: `.omc/artifacts/ask/codex-spec-020-v0-1-2-round-3-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-16-19-922Z.md`
- Lane B code: `.omc/artifacts/ask/codex-spec-020-v0-1-2-round-3-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-17-28-859Z.md`
- Lane C security: `.omc/artifacts/ask/codex-spec-020-v0-1-2-round-3-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-16-14-581Z.md`
