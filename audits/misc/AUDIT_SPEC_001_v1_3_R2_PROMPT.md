# Audit prompt — SPEC-001 v1.3 (round 2 — LOCK confirmation)

Operator-paste prompt to audit SPEC-001 v1.3
(`specs/SPEC-001-phase3-binary.md`) — the round-2 LOCK-confirmation
pass after closing all round-1 MAJORs + MINORs + the QUESTION.

Round 1 (Codex GPT-5, 2026-06-06) verdict: `0 CRITICAL / 3 MAJOR /
2 MINOR / 1 QUESTION` → POLISH ROUND REQUIRED. Round-1 findings
filed at `specs/SPEC-001-v1-3-audit.md`:

- **MAJOR D.1** — §6.2 + §6.7.3 cell 1 said "supported_models
  not emitted" in default path; SPEC-010 R-3.6.2 + AC-19 require
  single-entry `[model_id]` emission as the binary default.
- **MAJOR E.1** — AC-18.3 expected stderr `"warm swap not
  enabled"`; R-6.9.5 + SPEC-011 AC-18 require the ENOENT case-1
  stderr `"macprovider-cli serve is not running on this host
  (no control socket at ...)"`.
- **MAJOR E.2** — AC-18.0 (byte-identical default) and AC-18.9
  (cites SPEC-010 AC-19) contradicted each other.
- **MINOR E.3** — AC coverage gaps for R-6.9.5 ECONNREFUSED/
  timeout, R-6.11.5 cooldown/`--force`, R-6.11.4 reconnect-hello,
  R-6.8.3 state-value enum.
- **MINOR F.1** — `--swap-drain-timeout-seconds` lacked inline
  defaults/range/exit-code; `--publish-supported-models` lacked
  env/config priority.
- **QUESTION A.1** — L-1 scope ambiguity: was it "full wire-frame
  byte identity" or "no NEW SPEC-010/SPEC-011 surface"?

Polish pass closed all 6 findings:
- **D.1 + E.2 fix** — §6.2 `--supported-models` rewrites the
  default-path text to reflect R-3.6.2 single-entry emission;
  §6.7 R-6.7.3 rewrites the field-control narrative to "always
  emitted" with R-3.6.2/AC-19 default; §6.7.3 cell-1 rewritten
  to "LEGACY-EQUIVALENT" with explicit single-entry + omitted
  `publishes_supported_models` per AC-21; cell 3 likewise.
  AC-18.0 expanded into 4 sub-assertions (a)-(d) with explicit
  L-1 baseline scoping; AC-18.9 expanded into per-cell shape
  assertions traceable to SPEC-010 AC-19/AC-21 + SPEC-011 AC-18.
- **E.1 fix** — AC-18.3 rewritten to use the ENOENT case-1 stderr
  text per SPEC-011 v0.5 AC-18.
- **F.1 fix** — `--swap-drain-timeout-seconds` now inlines
  default 20 + range 5-600 + exit code 2 per R-3.9.1;
  `--publish-supported-models` now documents CLI > ENV
  (`MACPROVIDER_PUBLISH_SUPPORTED_MODELS`) > config
  (`publish_supported_models: bool`) per SPEC-010 AC-10.
- **E.3 fix** — 5 new ACs added: AC-18.12 (ECONNREFUSED),
  AC-18.13 (handshake timeout), AC-18.14 (cooldown +
  `--force`), AC-18.15 (WS drop reconnect uses `hello`),
  AC-18.16 (runtime state-value enum).
- **A.1 fix** — L-1 wording narrowed in top revision line,
  v1.3 change-log entry, AC-18.0, AC-18.9 cell-1 text, and
  §6.7.3 cell-1 to "no NEW SPEC-010/SPEC-011 fields, sockets,
  or runtime state beyond the single-entry catalog default."
  Each wording change cites SPEC-010 v1.5 §4.1 back-compat
  analysis as the rationale for why single-entry default is
  back-compat-equivalent.

Round 2 has ONE job: confirm `0 CRITICAL / 0 MAJOR / 0 MINOR`
across the round-1-finding closure surface, and emit a LOCK
CONFIRMATION verdict — mirroring SPEC-010 v1.5 round 6 and
SPEC-011 v0.5 round 4.

Trajectory:
- v1.3 round 1: 0 CRITICAL / 3 MAJOR / 2 MINOR / 1 QUESTION
- v1.3 round 2 target: **0 / 0 / 0 → LOCK CONFIRMED**

Append round-2 findings to existing
`specs/SPEC-001-v1-3-audit.md` as a new top-level section after
round 1.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-001 v1.3 (post round-1 polish) at
/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md.
This is round 2 and the LOCK confirmation pass.

Round 1 (Codex GPT-5 on the BUILD-pass v1.3) delivered POLISH
ROUND REQUIRED with 0 CRITICAL / 3 MAJOR / 2 MINOR / 1 QUESTION.
The polish pass closed all 6 findings via spec-text-only edits.

Your job:
1. **R1V — Round-1 finding closure verification.** For each of
   D.1, E.1, E.2, E.3, F.1, A.1, cite the v1.3 (post-polish)
   location and mark PASS / PARTIAL / FAIL.
2. **LOCK confirmation.** If round 2 finds 0 CRITICAL / 0
   MAJOR / 0 MINOR, state explicitly "LOCK CONFIRMED" in the
   executive summary. If round 2 finds new MINORs but no
   MAJOR/CRITICAL, state "LOCK CONFIRMED WITH MINOR DEFERRED
   FIXES." If round 2 finds any new MAJOR or CRITICAL, state
   "LOCK NOT CONFIRMED — UNEXPECTED REGRESSION."

This is a narrow surface to audit (~6 closure verifications +
4 sanity-check categories). Expected duration ~10-15 min.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-001-v1-3-audit.md

APPEND a new top-level section:
  `## Round 2 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION`
followed by R1V table + category findings (likely "(no
findings)" across most categories).

## Severity definitions

Unchanged from round 1.

## Critical constraints

**1. Locked specs READ-ONLY.** SPEC-002 v1.3.4, SPEC-004
v0.3.1, SPEC-005, SPEC-006 v0.8.1, SPEC-008 v0.3, SPEC-010
v1.5, SPEC-011 v0.5 all LOCKED. Spot-check:
`git diff specs/SPEC-002*.md specs/SPEC-004*.md
specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md
specs/SPEC-011*.md` must be empty.

**2. §6.5 byte-identity is the hard invariant.** Spot-check:
```
git show HEAD:specs/SPEC-001-phase3-binary.md > /tmp/spec001-head.md
diff <(awk '/^### 6\.5/,/^### 6\.6/' /tmp/spec001-head.md) \
     <(awk '/^### 6\.5/,/^### 6\.6/' specs/SPEC-001-phase3-binary.md)
```
If non-empty = CRITICAL.

**3. No phase3-binary code changes.** `git diff --stat
phase3-binary/` must be empty.

**4. `$XDG_RUNTIME_DIR` allowlist.** Spot-check:
`grep -n 'XDG_RUNTIME_DIR' specs/SPEC-001-phase3-binary.md`
must return ONLY the §6.9 "Why not" rationale line.

**5. Round 2 is a sanity check, not a deep audit.** If
nothing new surfaces in the closure-verification + sanity
categories, the verdict is LOCK CONFIRMED.

**6. Clean-room.** No d-inference inspection.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.3 (post-polish) — focus on the specific lines that closed
   each round-1 finding:
   - **D.1 closure** — §6.2 `--supported-models` flag text
     (lines ~980-993); §6.7.3 cell-1 row (line ~1715); §6.7.3
     cell-3 row (line ~1717); §6.7 R-6.7.3 narrative (lines
     ~1640-1652).
   - **E.1 closure** — AC-18.3 text (lines ~2334-2342) — must
     now reference ENOENT case-1 stderr.
   - **E.2 closure** — AC-18.0 4-part assertion (lines
     ~2314-2331); AC-18.9 per-cell expansion (lines ~2382-2405).
   - **E.3 closure** — AC-18.12 through AC-18.16 (after the
     prior end-of-section, before the `---` separator).
   - **F.1 closure** — §6.2 `--publish-supported-models` text
     (env/config priority); §6.2 `--swap-drain-timeout-seconds`
     text (default 20 + range 5-600 + exit code 2).
   - **A.1 closure** — top revision line (line 4); v1.3
     change-log entry (line 8); AC-18.0 scoping wording;
     §6.7.3 cell-1 wording; the "L-1 baseline" language.

2. `/Users/augstar/macprovider-poc/specs/SPEC-001-v1-3-audit.md`
   round 1 — re-read the round-1 D.1, E.1, E.2, E.3, F.1, A.1
   findings to verify the polish addresses what was actually
   said.

3. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 (LOCKED) — verify R-3.6.2 / AC-19 / AC-21 / R-3.6.4
   wording matches what SPEC-001 v1.3 post-polish now cites.

4. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 (LOCKED) — verify AC-18 ENOENT case-1 stderr text + L-1
   scoping (R-3.1.0, R-3.3.0) + R-3.9.1 swap-drain range matches
   what SPEC-001 v1.3 post-polish now cites + AC-24 cooldown
   contract + §3.8 / R-3.8.3 reconnect-via-hello + R-3.2.3
   state-value enumeration.

5. `/Users/augstar/macprovider-poc/CLAUDE.md` — conventions.

## Audit categories

### Category R1V: Round-1 finding closure verification

Table format: round-1 finding, PASS/PARTIAL/FAIL, v1.3 post-polish
location, 1-sentence evidence.

- **R1V-D.1** §6.2 `--supported-models` no longer says "omitted
  in default path"; §6.7.3 cell 1 says single-entry emitted +
  `publishes_supported_models` omitted; §6.7 R-6.7.3 narrative
  says "always emitted."
- **R1V-E.1** AC-18.3 cites the ENOENT case-1 stderr per
  SPEC-011 AC-18.
- **R1V-E.2** AC-18.0 + AC-18.9 consistent: both reflect
  single-entry catalog as the L-1 baseline, no contradiction.
- **R1V-E.3** AC-18.12 (ECONNREFUSED), AC-18.13 (handshake
  timeout), AC-18.14 (cooldown + `--force`), AC-18.15 (WS drop
  reconnect uses hello), AC-18.16 (state-value enum) present
  and trace to the cited SPEC-011 rules.
- **R1V-F.1** `--swap-drain-timeout-seconds` inlines default
  20 + range 5-600 + exit code 2; `--publish-supported-models`
  documents env/config priority.
- **R1V-A.1** L-1 wording narrowed in top revision line +
  change-log + AC-18.0; the "byte-identical to v1.2.4" framing
  is replaced with "L-1 baseline: no NEW SPEC-010/SPEC-011
  fields, sockets, or runtime state beyond single-entry catalog
  default."

### Category A2: Locked-decision preservation (sanity check)

A2.1  §6.5 byte-identity to HEAD (run the diff spot-check above).

A2.2  Locked-companion diff sanity check (run spot-check above).

A2.3  `phase3-binary/` diff sanity check (run spot-check above).

A2.4  `$XDG_RUNTIME_DIR` allowlist sanity check (run spot-check
      above).

### Category B2: Citation accuracy on the closure surface

B2.1  Every NEW or REWRITTEN R-rule / AC introduced by the polish
      pass cites a binding SPEC-010 v1.5 or SPEC-011 v0.5 rule.
      Sample at least: AC-18.0 (4 sub-assertions), AC-18.3,
      AC-18.9 (4 cell assertions), AC-18.12-AC-18.16, §6.7.3 cell
      1, §6.7 R-6.7.3 narrative, §6.2 `--supported-models` flag
      text. If any cite references a non-existent or unrelated
      locked rule = MAJOR.

B2.2  ENOENT stderr text in AC-18.3 byte-matches SPEC-011 v0.5
      AC-18 case-1 wording. If literal mismatch = MINOR.

### Category C2: New AC coverage soundness

C2.1  AC-18.12 ECONNREFUSED — the test description is
      operationally testable (i.e. there's an unambiguous
      stale-socket setup the test can reproduce).

C2.2  AC-18.13 handshake timeout — the 2-second threshold
      matches SPEC-011 R-3.1.5.x case 3.

C2.3  AC-18.14 cooldown + `--force` — the "10s" cooldown matches
      SPEC-011 R-3.1.4 default; `--force` MUST NOT bypass SPEC-010
      pre-flight per SPEC-011 R-3.1.3; cite is correct.

C2.4  AC-18.15 reconnect-hello — the OLD-hash-during-load
      assertion matches SPEC-011 §3.8.3 / SPEC-001 R-6.10.5.

C2.5  AC-18.16 state-value enum — the "`failed` is
      internal-only-transient" assertion matches SPEC-011
      R-3.2.3 + R-3.1.5 `runtime_state` enum.

### Category D2: Anything else

D2.1  Did the polish pass introduce any new normative surface
      that should be audited?

D2.2  Documentation drift on the closure surface (e.g. the
      change-log v1.3 entry references "byte-identical default"
      somewhere it wasn't updated).

D2.3  Decision-log entry: NOT a finding, but reminder that one
      should be added after LOCK (Entry 56 mirroring Entry 54 /
      Entry 55 format).

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-001-v1-3-audit.md`.
Start with:

```
---

## Round 2 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-001 v1.3 (post round-1 polish)
            (specs/SPEC-001-phase3-binary.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N (normative, LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-2 executive summary — LOCK VERDICT

[1-2 sentences. State explicitly one of:
- "LOCK CONFIRMED" (0/0/0)
- "LOCK CONFIRMED WITH MINOR DEFERRED FIXES" (0/0/N with N ≤ 2,
  MINORs are non-blockers)
- "LOCK NOT CONFIRMED — UNEXPECTED REGRESSION" (any new MAJOR
  or CRITICAL)]

### Round-1 finding closure verification (R1V)

[Table format.]
```

Then for each category R1V, A2-D2, write a section. For each
finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- d-inference inspection
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-002, SPEC-004, SPEC-005, SPEC-006, SPEC-008,
  SPEC-010 v1.5, SPEC-011 v0.5 (all LOCKED)
- Re-litigating round-1 findings that the round-1 audit closed

## Done criteria

You are done when:

- Round-2 section APPENDED to SPEC-001-v1-3-audit.md (round 1
  intact)
- Every round-1 finding (D.1, E.1, E.2, E.3, F.1, A.1) has
  PASS/PARTIAL/FAIL in R1V
- Every category R1V, A2-D2 has a section
- All 4 spot-checks executed and result reported
- Executive summary states the explicit LOCK verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 10-15 min (6 closure verifications + 4
  spot-checks + 5 sanity categories).
- If verdict is LOCK CONFIRMED: lock SPEC-001 v1.3, append
  Entry 56 to `beta/DECISION_CRITERIA.md` (alongside Entry 54 /
  Entry 55), proceed to `BUILD_SPEC_002_v1_3_5_PROMPT.md`
  (coordinator-side counterpart).
- If unexpected regression: narrow v1.3.1 fix + round 3.
