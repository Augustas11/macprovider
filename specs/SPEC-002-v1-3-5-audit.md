# SPEC-002 v1.3.5 audit history

## Round 1 — Codex GPT-5 — 2026-06-06 — Normative audit

**Audited:** SPEC-002 v1.3.5 (specs/SPEC-002-coordinator.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N (normative)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 1 MAJOR / 2 MINOR / 0 QUESTION

### Round-1 executive summary

POLISH ROUND REQUIRED. SPEC-002 v1.3.5 preserves the L-1 baseline, passes the §5 / §7.1 existing / §7.2 / §7.3 byte-identity checks, passes the phase4-coordinator no-code-diff guard, and the §7.1 ApplyHeartbeat REPLACEMENT is clear and correct. One MAJOR remains: the SPEC-002 proof-stage mismatch reason string diverges from locked SPEC-010 v1.5 R-3.1.10 / AC-18(c); two MINOR AC coverage gaps should be polished before lock confirmation.

### Category A: L-1 baseline coordinator handling

(no findings)

Verification notes:
- AC-K.0, R-7.1.1, and R-7.1.3 preserve the L-1 path: no `model_hash` / `loading` heartbeat fields means the LEGACY PATH keeps v1.3.4 hash-clearing behavior at `provider.go:420-432`.
- R-7.8.3 states the v1.3 single-entry `supported_models: [model_id]` default is functionally indistinguishable from pre-SPEC-010 behavior per SPEC-010 §4.1 and SPEC-001 AC-18.0.
- R-7.9.8 keeps the SPEC-010 presence gate: no `supported_models` and no `publishes_supported_models` means no SPEC-010 retention state.

### Category B: Locked-spec citations and accuracy

**MAJOR B.1 - Proof-stage mismatch reason string diverges from locked SPEC-010.**

Location: `specs/SPEC-002-coordinator.md:2719-2727` (R-7.8.7) and `specs/SPEC-002-coordinator.md:3623-3631` (AC-K.3).

SPEC-002 requires the proof-stage mismatch reason text to contain `"supported_models mismatch between initial and proof stages"`. Locked SPEC-010 v1.5 requires `"supported_models mismatch between auth_request stages"` in R-3.1.10 clause 4 (`specs/SPEC-010-model-catalog.md:648-654`) and AC-18(c) (`specs/SPEC-010-model-catalog.md:1053-1060`). A coordinator implemented only to the SPEC-002 wording would miss the locked SPEC-010 test oracle.

Recommendation: replace both SPEC-002 occurrences with the locked SPEC-010 substring: `"supported_models mismatch between auth_request stages"`.

### Category C: Code-grounding accuracy

(no findings)

Verification notes:
- `server.go:354` contains `authAttemptID := "auth-" + s.newUUID()`.
- `server.go:355` contains the 10-minute challenge expiry assignment, with `.UTC()` appended.
- `server.go:398` enforces proof-stage `auth_attempt_id`, provider-ID, and expiry checks.
- `messages.go:333-388` is `parseAuthInitial`; `messages.go:391-401` is `parseAuthProof`.
- `provider.go:411-432` is the `ApplyHeartbeat` range; `provider.go:420-432` is the legacy model-change hash-clear/update range.
- `config.go:269` is `MaxUnauthenticatedConn: 64`.
- `loading_window_ms` in R-7.10.6 correctly uses coordinator clock, matching SPEC-011 R-3.6.3.

### Category D: ApplyHeartbeat REPLACEMENT correctness

(no findings)

Verification notes:
- The title includes `REPLACEMENT` at `specs/SPEC-002-coordinator.md:1999`.
- The opening paragraph identifies `phase4-coordinator/internal/pool/provider.go:411-432`.
- Dispatch is per-heartbeat field presence: LEGACY PATH when `model_hash` is absent, SPEC-011 PATH when present; R-7.1.3 / R-7.1.4 do not define a sticky path.
- R-7.1.6 uses `LastLoadingState` sticky reset for exactly-once emission.
- R-7.1.6 cross-references R-7.10.10 and covers both reconnect-after-swap (no event) and reconnect-during-load (event on subsequent completion).

### Category E: New AC coverage

**MINOR E.1 - AC-K coverage omits explicit coordinator validation-order and retention-bound tests.**

Location: `specs/SPEC-002-coordinator.md:2689-2693` (R-7.8.4), `specs/SPEC-002-coordinator.md:2787-2795` (R-7.9.6), and `specs/SPEC-002-coordinator.md:3597-3729` (AC-K.0 through AC-K.14).

R-7.8.4 introduces SPEC-010 validation-order behavior into SPEC-002, but no AC-K item directly asserts the ordered first-failure reason cases traced to SPEC-010 AC-17 / AC-22 / AC-23. R-7.9.6 introduces the aggregate retention-map bound and `too_many_auth_attempts` rejection behavior, but AC-K.4 / AC-K.5 cover expiry and disconnect release only.

Recommendation: add narrow AC-K coverage for SPEC-010 validation-order pass-through and the R-7.9.6 retention-bound rejection path.

**MINOR E.2 - AC-K coverage does not pin the audit-log table schema or table timestamp format.**

Location: `specs/SPEC-002-coordinator.md:2823-2845` (R-7.10.1 / R-7.10.2) and `specs/SPEC-002-coordinator.md:3719-3729` (AC-K.13 / AC-K.14).

R-7.10.1 defines concrete `audit_log` columns and indexes, and R-7.10.2 requires table-level `ts_utc` to be RFC3339 UTC. AC-K.10 covers the event payload schema, AC-K.13 covers write-failure tolerance, and AC-K.14 covers retention, but no AC-K item directly asserts the table schema, indexes, or `ts_utc` format.

Recommendation: add one narrow AC-K asserting `audit_log` schema/index creation and `ts_utc` RFC3339 UTC formatting.

### Category F: §3.X Provider data-model extension

(no findings)

Verification notes:
- R-3.X.1 / R-3.X.2 correctly document `SupportedModels[]` and `PublishesSupportedModels` per SPEC-010 §3.3.
- R-3.X.3 documents the SPEC-008 five-state `HashStatus` enum.
- R-3.X.4 documents `LastLoadingState bool` and its sticky reset.
- R-3.X.5 documents `AuthAttemptRetention` and the SPEC-010 presence gate.

### Category G: §7.4 /v1/status echo extension

(no findings)

Verification notes:
- R-7.4.1 is conditional on `PublishesSupportedModels == true`.
- When false or absent, `supported_models` is omitted entirely, not emitted as `null` or `[]`.

### Category H: Change-log + §13 hand-off

(no findings)

Verification notes:
- The v1.3.5 change-log header is distinct at the top of the file.
- Prior change-log entries from v1.3.4 onward are byte-identical to HEAD.
- §13 lists the 4 new files and 6 modified files required by the BUILD prompt hand-off extension.

### Category I: Anything else

(no findings)

Verification notes:
- §7.10 R-rule numbering is sequential R-7.10.1 through R-7.10.11, no duplicates or gaps.
- AC-K numbering is sequential AC-K.0 through AC-K.14, no duplicates or gaps.
- Payload schema check passes: §7.10.2 has SPEC-011's 8 REQUIRED keys (`event`, `ts`, `provider_assigned_id`, `from_model_id`, `to_model_id`, `to_model_hash`, `loading_window_ms`, `hash_verification_result`), 2 OPTIONAL keys (`from_model_hash`, `drain_inflight_count_estimate`), and no extra top-level keys.
- F-1.5 invariant check passes: R-7.10.9 and AC-K.11 prohibit `conv:`, raw `account_id`, sticky session identifiers, buyer prompt text, and sticky-derivation inputs.
- Conditional emission check passes: R-7.10.10 and AC-K.12 cover reconnect-after-swap (no event) and reconnect-during-load (event after subsequent completion).
- Tier-2 handling remains limited to SPEC-008 citations; no v1.3.5 text expands Tier-2 behavior.

### Round-1 verification evidence

- Required files read in order: SPEC-002 v1.3.5, SPEC-001 v1.3, SPEC-010 v1.5, SPEC-011 v0.5, SPEC-008 v0.3 (`specs/SPEC-008-tier2.md`), decision-log Entries 54-56, `CLAUDE.md`, then code spot-check files.
- Byte-identity spot checks executed: §5, §7.2, and §7.3 commands from the prompt all produced empty diffs.
- Existing §7.1 content check executed: HEAD §7.1 compared to current §7.1 before the appended `Heartbeat field extension`; diff was empty.
- `git diff --stat phase4-coordinator/` was empty.
- `git diff specs/SPEC-001-phase3-binary.md specs/SPEC-004*.md specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md specs/SPEC-011*.md` was empty.
- No d-inference source was inspected.

---

## Round 2 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-002 v1.3.5 (post round-1 polish)
            (specs/SPEC-002-coordinator.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N (normative, LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 1 MAJOR / 0 MINOR / 0 QUESTION

### Round-2 executive summary — LOCK VERDICT

LOCK NOT CONFIRMED — UNEXPECTED REGRESSION. The B.1 and E.2 polish
closures pass, but AC-K.15's new validation-order test oracle diverges
from locked SPEC-010 v1.5 reason substrings for two failure classes.

### Round-1 finding closure verification (R1V)

| Round-1 finding | Status | v1.3.5 post-polish location | Evidence |
|---|---|---|---|
| R1V-B.1 | PASS | `specs/SPEC-002-coordinator.md:2719-2727`, `specs/SPEC-002-coordinator.md:3623-3632` | R-7.8.7 and AC-K.3 both require the locked substring `"supported_models mismatch between auth_request stages"`; the prior `"between initial and proof stages"` wording was not found. |
| R1V-E.1 | PARTIAL | `specs/SPEC-002-coordinator.md:3732-3752` | AC-K.15 and AC-K.16 are present, and AC-K.16 correctly covers the R-7.9.6 retention-bound rejection, but AC-K.15 quotes two SPEC-010 reason substrings incorrectly. |
| R1V-E.2 | PASS | `specs/SPEC-002-coordinator.md:2823-2845`, `specs/SPEC-002-coordinator.md:3754-3762` | R-7.10.1 defines the 5-column `audit_log` schema plus three indexes, R-7.10.2 pins `ts_utc` RFC3339 UTC, and AC-K.17 asserts both. |

### Category A2: Locked-decision preservation (sanity check)

(no findings)

Verification notes:
- A2.1 locked-companion diff spot-check executed: `git diff specs/SPEC-001-phase3-binary.md specs/SPEC-004*.md specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md specs/SPEC-011*.md` was empty.
- A2.2 `phase4-coordinator/` diff spot-check executed: `git diff --stat -- phase4-coordinator/` was empty.
- A2.3 byte-identity spot-checks executed: §5, §7.2, and §7.3 prompt diffs were empty; existing §7.1 compared from HEAD §7.1 to current §7.1 before `Heartbeat field extension`, and the diff was empty.
- A2.4 pre-audit M.1/M.2/M.3 closures remain intact: §7.10.2 still has 8 REQUIRED + 2 OPTIONAL payload fields at `specs/SPEC-002-coordinator.md:2872-2885`; R-7.10.9 F-1.5 invariants remain at `specs/SPEC-002-coordinator.md:2919-2927`; R-7.10.10 conditional emission remains at `specs/SPEC-002-coordinator.md:2929-2946`.

### Category B2: New AC tracing and operational testability

**MAJOR B2.1 - AC-K.15 reason-text substrings diverge from locked SPEC-010.**

Location: `specs/SPEC-002-coordinator.md:3732-3743`; locked references
at `specs/SPEC-010-model-catalog.md:521-540`,
`specs/SPEC-010-model-catalog.md:1023-1028`,
`specs/SPEC-010-model-catalog.md:1166-1178`.

What: AC-K.15 cites SPEC-010 v1.5 R-3.1.9 / AC-17 / AC-22 / AC-23,
but two of its quoted reason substrings do not match the locked SPEC-010
test oracle. AC-K.15 says `"supported_models entry exceeds 256 UTF-8
bytes"` while SPEC-010 uses `"supported_models entry exceeds 256
bytes"`, and AC-K.15 says `"supported_models contains duplicate after
normalization"` while SPEC-010 uses `"supported_models contains
duplicate entries"`. AC-22's `"supported_models exceeds 64 entries"`
substring matches.

Why: This reintroduces the same class of cross-spec test-oracle drift
that round 1 B.1 fixed. An implementation or harness following SPEC-002
AC-K.15 literally could reject the locked SPEC-010 reason strings even
though the rule text claims to require the locked SPEC-010 substrings.

Recommendation: Change only AC-K.15's two quoted substrings to the
locked SPEC-010 text: `"supported_models entry exceeds 256 bytes"` and
`"supported_models contains duplicate entries"`.

**B2.2 Auth-attempt retention-bound rejection.**

(no findings)

Verification notes:
- AC-K.16 cites SPEC-002 R-7.9.6 and SPEC-010 R-3.1.10 at `specs/SPEC-002-coordinator.md:3745-3752`.
- R-7.9.6 contains the recommended 1024 bound and `too_many_auth_attempts` rejection text at `specs/SPEC-002-coordinator.md:2787-2794`.

**B2.3 Audit-log schema and timestamp testability.**

(no findings)

Verification notes:
- AC-K.17 cites R-7.10.1 / R-7.10.2 at `specs/SPEC-002-coordinator.md:3754-3762`.
- R-7.10.1 contains the 5-column schema and three indexes at `specs/SPEC-002-coordinator.md:2823-2839`.
- R-7.10.2 contains the RFC3339 UTC `ts_utc` requirement at `specs/SPEC-002-coordinator.md:2841-2845`.

### Category C2: Anything else

(no findings)

Verification notes:
- C2.1 The polish pass introduced new normative AC surface AC-K.15 through AC-K.17; only AC-K.15's two reason substrings drift from locked SPEC-010.
- C2.2 No additional documentation drift was found on the closure surface.
- C2.3 Renumbering sanity passes: §7.10 rules are sequential R-7.10.1 through R-7.10.11, and AC-K is sequential AC-K.0 through AC-K.17.
- C2.4 Decision-log Entry 57 remains a post-LOCK reminder, not a round-2 finding.

### Round-2 verification evidence

- Required files read: SPEC-002 v1.3.5, SPEC-002 v1.3.5 audit round 1, SPEC-010 v1.5, SPEC-011 v0.5, and CLAUDE.md.
- Required locked-companion diff spot-check was empty.
- Required §5 / §7.1 existing / §7.2 / §7.3 byte-identity spot-checks were empty.
- Required `phase4-coordinator/` diff spot-check was empty.
- No d-inference source was inspected.

---

## Round 3 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-002 v1.3.5 (post round-2 regression fix)
            (specs/SPEC-002-coordinator.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N (normative, LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 1 MAJOR / 0 MINOR / 0 QUESTION

### Round-3 executive summary — LOCK VERDICT

LOCK NOT CONFIRMED — UNEXPECTED REGRESSION. The forbidden round-2
substrings are gone and AC-22 / AC-23 are fixed, but the required
AC-K.15 grep for AC-17 returns no line because the locked substring
`"supported_models entry exceeds 256 bytes"` is wrapped across two
Markdown lines.

### Round-2 finding closure verification (R2V)

| Round-2 finding | Status | v1.3.5 post-round-2 polish location | Evidence |
|---|---|---|---|
| R2V-B2.1 | PARTIAL | `specs/SPEC-002-coordinator.md:3732-3743` | AC-22 (`"supported_models exceeds 64 entries"`) and AC-23 (`"supported_models contains duplicate entries"`) match locked SPEC-010, and forbidden prior substrings (`"UTF-8 bytes"`, `"after normalization"`) were not found in SPEC-002; however the prompt-required grep for AC-17 returned no output because `"supported_models entry exceeds 256 bytes"` is split across lines 3738-3739. |

### Category R2V: Round-2 finding closure verification

**MAJOR R2V-B2.1 - AC-K.15 AC-17 substring is still not grep-visible verbatim.**

Location: `specs/SPEC-002-coordinator.md:3738-3739`; locked references at
`specs/SPEC-010-model-catalog.md:530`,
`specs/SPEC-010-model-catalog.md:947`,
`specs/SPEC-010-model-catalog.md:1154`.

What: The exact required command
`grep -nE "supported_models entry exceeds 256 (bytes|UTF-8 bytes)" specs/SPEC-002-coordinator.md`
returned no output. AC-K.15 currently wraps the quoted reason as
`"supported_models entry exceeds` on line 3738 and `256 bytes"` on line
3739, so the locked SPEC-010 substring does not appear as a contiguous
line-level substring in SPEC-002. The companion required command for
duplicates returned `3740:AC-23 ("supported_models contains duplicate
entries"), and the`.

Why: Round 3's critical constraint 5 makes the exact grep result the
regression-fix target. A lock pass would leave the AC-17 test oracle
invisible to that mandated spot-check.

Recommendation: Reflow only AC-K.15 so
`"supported_models entry exceeds 256 bytes"` appears contiguously on
one line. Do not change locked companion specs or coordinator code.

### Category A3: Locked-decision preservation (sanity check)

(no findings)

Verification notes:
- A3.1 locked-companion diff spot-check executed:
  `git diff specs/SPEC-001-phase3-binary.md specs/SPEC-004*.md specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md specs/SPEC-011*.md`
  was empty.
- A3.2 `phase4-coordinator/` diff spot-check executed:
  `git diff --stat phase4-coordinator/` was empty.
- A3.3 byte-identity spot-checks executed: §5, existing §7.1 content
  before `Heartbeat field extension`, §7.2, and §7.3 diffs against
  `HEAD:specs/SPEC-002-coordinator.md` were empty.
- A3.4 pre-audit M.1 / M.2 / M.3 closures and round-1 B.1 / E.1 /
  E.2 closures remain intact on the narrow surface: AC-K.11, AC-K.12,
  and AC-K.17 remain present; the locked proof-stage mismatch substring
  remains `"supported_models mismatch between auth_request stages"`;
  the prior `"between initial and proof stages"` substring was not
  found.

### Category B3: Anything else

**B3.1 AC-K.15 polish introduced unintended line-wrap surface.**

Severity: MAJOR (same finding as R2V-B2.1; not counted separately).

Location: `specs/SPEC-002-coordinator.md:3738-3739`.

What: The round-2 polish removed the incorrect words, but the AC-17
locked reason text is split across a newline, so SPEC-002 still does
not contain the contiguous locked substring required by the round-3
grep target.

Why: The issue is confined to one AC and does not add new normative
semantics, but it blocks LOCK because the lock-confirmation prompt
requires the exact grep to return the AC-K.15 line.

Recommendation: Make the AC-17 quoted reason a single-line substring
inside AC-K.15.

**B3.2 Renumbering sanity.**

(no findings)

Verification notes:
- §7.10 rules are sequential R-7.10.1 through R-7.10.11, no duplicates
  or gaps.
- AC-K entries are sequential AC-K.0 through AC-K.17, no duplicates or
  gaps.

**B3.3 Decision-log Entry 57 reminder.**

(no findings)

Verification notes:
- Entry 57 remains a post-LOCK reminder, not a round-3 finding.

### Round-3 verification evidence

- Required files read: SPEC-002 v1.3.5 AC-K.15 through AC-K.17 and
  numbering surface, SPEC-002 v1.3.5 audit round 2, SPEC-010 v1.5
  R-3.1.9 / R-3.1.10 / AC-17 / AC-22 / AC-23, and `CLAUDE.md`.
- Required AC-K.15 substring spot-checks executed. The first required
  grep for `supported_models entry exceeds 256 (bytes|UTF-8 bytes)`
  returned no output; the second required grep returned the AC-K.15
  duplicate-entry line; forbidden prior substrings were not found in
  SPEC-002.
- Required locked SPEC-010 source grep executed:
  `grep -n "exceeds 256 bytes\|duplicate entries" specs/SPEC-010-model-catalog.md`
  returned the expected multiple hits for both phrases.
- Required locked-companion diff spot-check was empty.
- Required `phase4-coordinator/` diff spot-check was empty.
- Required §5 / §7.1 existing / §7.2 / §7.3 byte-identity spot-checks
  were empty.
- No d-inference source was inspected.

---

## Round 4 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION (post round-3 false-positive fix)

**Audited:** SPEC-002 v1.3.5 (post round-3 line-wrap fix)
            (specs/SPEC-002-coordinator.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 4 of N (normative, LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 0 MAJOR / 0 MINOR / 0 QUESTION

### Round-4 executive summary — LOCK VERDICT

LOCK CONFIRMED. The round-3 line-wrap finding was a false positive
against the normative content and is now resolved for the specified
line-level grep oracle. All requested R3V checks pass, forbidden
round-2 substrings remain absent from SPEC-002, locked-decision
invariants are preserved, and no new regression was found on the
round-3-polish scope.

### R3V — round-3 line-wrap fix

PASS. Each required substring is present on a single grep-visible line:

```text
$ grep "supported_models entry exceeds 256 bytes" specs/SPEC-002-coordinator.md
- AC-17 per-entry byte length: `"supported_models entry exceeds 256 bytes"`

$ grep "supported_models exceeds 64 entries" specs/SPEC-002-coordinator.md
- AC-22 array length: `"supported_models exceeds 64 entries"`

$ grep "supported_models contains duplicate entries" specs/SPEC-002-coordinator.md
- AC-23 normalized duplicate: `"supported_models contains duplicate entries"`
```

### Forbidden-substring check

PASS. Both forbidden substrings are absent from SPEC-002:

```text
$ grep "UTF-8 bytes" specs/SPEC-002-coordinator.md
<no output; exit 1>

$ grep "after normalization" specs/SPEC-002-coordinator.md
<no output; exit 1>
```

### Sanity-check invariants

PASS.

- `git diff --stat phase4-coordinator/` was empty.
- `git diff specs/SPEC-001-phase3-binary.md specs/SPEC-004*.md specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md specs/SPEC-011*.md` was empty.
- §5 / §7.2 / §7.3 remain byte-identical to HEAD by MD5:

```text
current §5    ed2f1f37afaab9d662d8907c878c3d1d
HEAD §5       ed2f1f37afaab9d662d8907c878c3d1d
current §7.2  51b5a020ade9e2dbfbab676847f1b397
HEAD §7.2     51b5a020ade9e2dbfbab676847f1b397
current §7.3  1aa8792c331c10951e002d1ed6115f56
HEAD §7.3     1aa8792c331c10951e002d1ed6115f56
```

### Scoped regression check

PASS. The round-3-polish scope remains confined to AC-K.15's
grep-oracle reformat. AC-K.0 through AC-K.14 and AC-K.16 / AC-K.17
were re-read in the current SPEC-002 block and remain present with
sequential numbering:

```text
3599:**AC-K.0 L-1 baseline coordinator handling.**
3611:**AC-K.1 SPEC-010 catalog opt-in echo.**
3617:**AC-K.2 SPEC-010 catalog opt-in suppressed echo.**
3623:**AC-K.3 v2 `auth_request` proof-stage retention.**
3634:**AC-K.4 Auth-attempt expiry.**
3642:**AC-K.5 Auth-attempt release on disconnect-before-proof.**
3648:**AC-K.6 ApplyHeartbeat LEGACY PATH.**
3657:**AC-K.7 ApplyHeartbeat SPEC-011 PATH.**
3668:**AC-K.8 ApplyHeartbeat path selection by field presence.**
3675:**AC-K.9 `operator_model_swap` exactly-once emission.**
3681:**AC-K.10 `operator_model_swap` payload schema (REQUIRED/OPTIONAL keys).**
3698:**AC-K.11 `operator_model_swap` payload F-1.5 invariants.**
3707:**AC-K.12 `operator_model_swap` conditional emission (WS-drop).**
3720:**AC-K.13 Audit-log write failure tolerance.**
3726:**AC-K.14 Audit-log retention.**
3732:**AC-K.15 SPEC-010 validation-order pass-through.**
3747:**AC-K.16 Auth-attempt retention-bound rejection.**
3756:**AC-K.17 Audit-log table schema + `ts_utc` format.**
```

The AC-K block fingerprint after the round-3-polish fix is
`70249ea767e4a1d4bfa6fe66bffe607f`; the non-AC-K.15 subset fingerprint
is `34fa0d83898d8953c3cb3258c7d95035`; AC-K.15 alone is
`d8c555ceb036687a246d047949a30f7b`.

### Round-4 verification evidence

- Required files read: `CLAUDE.md`, SPEC-002 v1.3.5 AC-K.0 through
  AC-K.17, and SPEC-002 v1.3.5 audit rounds 1 through 3.
- Required R3V greps executed exactly as specified; all three returned
  the AC-K.15 bullet lines.
- Required forbidden-substring greps executed exactly as specified;
  both returned no output with exit code 1.
- Required locked-companion diff spot-check was empty.
- Required `phase4-coordinator/` diff spot-check was empty.
- Required §5 / §7.2 / §7.3 byte-identity spot-checks matched HEAD by
  MD5.
- No d-inference source was inspected.
