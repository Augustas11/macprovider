# Audit prompt — SPEC-013 v0.3 (round 3 — closure-confirmation, LOCK candidate)

Operator-paste prompt to audit SPEC-013 v0.3
(`specs/SPEC-013-cli-autotune.md`).

**Round 3 of N (LOCK-CONFIRMATION audit).** Round 1 (Codex on
v0.1) returned `0 CRITICAL / 7 MAJOR / 11 MINOR / 2 QUESTION` →
v0.2 closed 17 of 19. Round 2 (Codex on v0.2) returned LOCK READY
with `0 CRITICAL anti-regression / 1 MAJOR new / 3 MINOR new`.
v0.3 closes the 4 new round-2 findings (N-D.1 MAJOR, Z-B.1
PARTIAL→CLOSED, N-OQ-E.1 MINOR, O.1 MINOR). v0.3's change log block
at the top of the spec enumerates each closure.

Round 3 is the NARROWEST round. The brief: "Did v0.3 close the
four round-2 findings, and did it introduce any new contract
precision gap?" Round 3 is NOT a fresh audit — it is a
LOCK-CONFIRMATION pass. The expected outcome is `0 CRITICAL / 0
MAJOR / ≤2 MINOR new`, at which point SPEC-013 v0.3 LOCKs and the
implementing PR can begin.

Output: APPEND a new `## Round 3 audit (Codex on v0.3 — LOCK
confirmation)` section to `specs/SPEC-013-audit.md`. Do NOT
overwrite or edit the round-1 or round-2 sections.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are running round 3 of the audit on SPEC-013 v0.3 at
/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md.
Round 2 found v0.2 LOCK READY pending 4 narrow cleanups
(N-D.1 MAJOR, Z-B.1 PARTIAL, N-OQ-E.1 MINOR, O.1 MINOR);
v0.3 claims to close all 4. The audit history is in
specs/SPEC-013-audit.md.

Round 3 is a LOCK-CONFIRMATION audit. Output: APPEND a new
section to /Users/augstar/macprovider-poc/specs/SPEC-013-audit.md
titled `## Round 3 audit (Codex on v0.3 — LOCK confirmation)`.
Do NOT edit or overwrite the round-1 or round-2 sections.

The audit's two questions:

1. Did v0.3 actually close each of the 4 round-2 findings?
   "Closed" = the new wording does not admit the failure mode.
2. Did the round-2 closures introduce any NEW contract precision
   gap? Round 3 spot-checks the SPECIFIC sections v0.3 edited:
   §5.2 FR-B.1 (Z-B.1 parse-rule lift), §5.4 FR-D.1 + §6 NFR-4
   + §8 AC-8 (N-D.1 shape-neutrality), §9 OQ-E (sampling
   protocol), and the four O.1 drift sites (FR-G.2 SQL comment,
   FR-H.2 prose, NFR-3 backup pattern, §7 disclaimer).

Round 3 is NOT a fresh full-spec audit. Findings unrelated to
the four round-2 closures are accepted but should be rare.

## Severity definitions (unchanged from rounds 1+2)

- **CRITICAL** — would cause production failure on rollout;
  silent regression of locked spec behavior; v0.3 INTRODUCED
  a contract violation in a previously-correct FR; v0.3's
  claimed closure of a round-2 finding is COSMETIC and the
  original failure mode still applies.
- **MAJOR** — round-2 closure is incomplete or v0.3 introduced
  a new precision gap.
- **MINOR** — quality issues that don't block LOCK.
- **QUESTION** — unresolved design choice.

## Critical constraints (unchanged from rounds 1+2)

All round-1 + round-2 critical constraints remain in force:

1. The "biggest-fit, not max-tps" framing in §1 is LOCKED.
2. SPEC-001 v1.4, SPEC-002 v1.3.5, SPEC-003 v0.9.2, SPEC-010
   v1.5, SPEC-011 v0.5 are LOCKED.
3. SPEC-only, no code.
4. Additive only / Tier-1 backward compat.
5. Operator-supplied candidate-list order is the contract.
6. Default candidate list curated by the network.
7. Knob-axis claims must match PR #105 reality.
8. Clean-room boundary on d-inference.
9. Telemetry / privacy invariant: nothing leaves the machine
   except per FR-D.1 pre-warm.
10. Anti-regression: v0.3 must NOT have weakened any v0.2
    behavior that round 2 did NOT flag.

## Required reading (very narrow this round)

1. `/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md`
   v0.3 — focus on the v0.3 change-log block at the top + the
   five edit sites named below. You do NOT need to re-read the
   unchanged surface; rounds 1+2 covered it.

2. `/Users/augstar/macprovider-poc/specs/SPEC-013-audit.md`
   § Round 2 — the input to this round. Round 3's job is to
   verify the four round-2 findings (N-D.1, Z-B.1, N-OQ-E.1,
   O.1) are now closed.

3. Code spot-checks ONLY for round-2-related claims:
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
     lines 559-566 and 622-641 — verify v0.3 NFR-4's Shape A /
     Shape B carve-out still accurately describes the runtime
     online-fallback path.
   - No other code re-checks required (round 2 covered Config.swift
     and the launchd artifacts).

## Round 3 audit categories — narrow

### Category Z-CLOSURE: did v0.3 close the round-2 four?

For each of the 4 round-2 findings, write CLOSED / PARTIAL /
NOT CLOSED / OVER-CLOSED verdict with a one-paragraph rationale:

- **N-D.1 (MAJOR)** Shape B pre-warm vs `models pull`-only
  wording inconsistency → v0.3 rewords NFR-4 to admit both
  Shape A and Shape B, and AC-8 is now shape-neutral with
  explicit Shape A and Shape B variants. Verify the rewording
  actually permits a Shape B implementation without violating
  the egress invariant, and that the AC variants are
  testable.
- **Z-B.1 (PARTIAL → CLOSED)** `--max-context-axis` parse
  rules in §7 reference only → v0.3 lifts the parse rules
  into FR-B.1 as a normative paragraph (absolute caps, sorted
  ascending, ≥ `--target-context`, flag-parse-time
  rejection, duplicate rejection, empty axis → single cell).
  Verify the lifted rules are complete and unambiguous and
  that the §7 / §5 conflict-resolution rule is stated.
- **N-OQ-E.1 (MINOR)** OQ-E thermal threshold lacked repeat
  protocol → v0.3 adds: minimum 10 paired forward/reverse
  runs on air5, 60s idle between paired runs, mismatch_pairs
  / 10 > 0.05 threshold. Verify the protocol is measurable
  and the math is honest (10 trials at 5% threshold is
  marginal statistical power; is this defensible for v1?).
- **O.1 (MINOR)** Residual v0.1 wording drift → v0.3 updates
  the four sites:
  - `tune_runs.spec_version` SQL comment ('SPEC-013 v0.1' →
    "e.g. 'SPEC-013 v0.3'; writer emits its own producing
    version")
  - FR-H.2 ("v0.1 default behavior" → "v1 default behavior";
    "out of scope for v0.1's normative contract" → "deferred
    from v1's normative contract")
  - NFR-3 (`.bak-<unix-ts>` → `.bak-<unix-ts>-<counter>` with
    collision explanation)
  - §7 ("MAY change in v0.2" → §5-vs-§7 conflict rule + flag
    shape may be refined while §5 semantics are preserved)
  Verify all four sites are actually updated and no NEW
  drift was introduced.

### Category N-NEWGAPS-V03: precision gaps introduced by v0.3 edits

Spot-check the v0.3 edit sites for new gaps. Examples to look
for:

- FR-B.1 lifted parse rules: does "reject duplicates after sort"
  conflict with operator UX (e.g. `--max-context-axis 4000,4000`
  is a deduped 1-element list, not an error)? Audit's choice.
- NFR-4 rewording: the new "the HuggingFace pre-warm fetch
  path selected by FR-D.1, whether explicit `models pull` or
  runtime online fallback" — does this exempt all weight
  fetches or only the autotune-driven ones? An implementation
  could argue the runtime's fetch during a normal `serve`
  also qualifies, but autotune isn't running. Make sure
  NFR-4's carve-out is scoped to "during an `autotune` run."
- AC-8 Shape B variant: "block egress to HuggingFace at the
  network-mock layer" — is the test fixture for this defined
  precisely enough? Network-mocking is non-trivial.
- OQ-E sampling protocol: 10 pairs at 5% threshold is marginal
  power; would the operator be satisfied with "≥ 1 mismatch in
  10" as the trigger threshold given there's a chance of
  observing 1 mismatch in 10 by pure chance even when the true
  rate is < 5%? Audit's call.

### Category R-REGRESSION-V03: anti-regression on v0.2 surface

The v0.3 edits were prose-narrow. Spot-check that none
incidentally weakened or invalidated:

- FR-D.1 Shape A and Shape B definitions (untouched in v0.3)
- FR-D.2 transient/integrity split (untouched in v0.3)
- FR-F.3 four-owned-keys list (untouched in v0.3)
- FR-G.1 ALTER TABLE migration SQL (untouched in v0.3)
- AC-17 operator-order test (untouched in v0.3)
- The round-1 + round-2 closure language in the change-log
  blocks at the top of the spec

If any of these was incidentally edited and weakened =
CRITICAL anti-regression.

### Category O-OTHER-V03: catch-all

Use sparingly. Round 3 is narrow; broad findings are not
expected. Any finding here SHOULD reference why rounds 1+2
didn't catch it.

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-013-audit.md`:

```
---

## Round 3 audit (Codex on v0.3 — LOCK confirmation)

**Audited:** SPEC-013 v0.3 (specs/SPEC-013-cli-autotune.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N (LOCK confirmation)
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 4 round-2 findings
**Round-3 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Lock verdict:** [LOCK / NARROW V0.4 REQUIRED / OTHER]

### Executive summary

[1-2 paragraphs.]

### Round-2 finding closures

For each of the 4 round-2 findings (N-D.1, Z-B.1, N-OQ-E.1,
O.1): closure verdict + one-paragraph rationale.

### Round-3 new findings

Group by category Z / N / R / O. Empty categories: `(no findings)`.

### Lock readiness

State your verdict: LOCK (v0.3 may be locked as-is) or NARROW
V0.4 REQUIRED (state the blocker).
```

## Out of scope for round 3

- Re-litigating round-1 or round-2 findings already closed
- Rewriting the spec
- Implementing the spec
- Auditing locked specs themselves
- Re-litigating biggest-fit framing
- Picking Option A vs Option B
- Fresh broad-scope audit of unchanged sections

## Done criteria

You are done when:

- The new `## Round 3 audit (Codex on v0.3 — LOCK confirmation)`
  section is appended to
  /Users/augstar/macprovider-poc/specs/SPEC-013-audit.md.
- Round-1 and round-2 sections are unchanged.
- Each of 4 round-2 findings has an explicit closure verdict.
- Each round-3 new finding (if any) has severity, location,
  what / why / recommendation.
- The "Lock verdict" line at the top says LOCK or NARROW V0.4
  REQUIRED.

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: ~10-15 min Codex round 3 (this is the
  NARROWEST round — closure verification of 4 findings on
  ~5 edit sites).
- Round-3 expected outcome (estimated): LOCK with 0 new findings
  or ≤1 MINOR. The v0.3 closures are localized prose edits and
  the round-2 findings were already cleanups, not architectural.
- If round 3 returns LOCK: push the branch and open the DRAFT PR
  per the originating prompt at
  `.omc/prompts/spec-cli-autotune-v1.md`. The PR title is
  `spec(cli): SPEC-013 v0.3 — macprovider-cli autotune subcommand`
  and the PR body leads with the biggest-fit-not-max-tps decision.
- If round 3 returns NARROW V0.4 REQUIRED: Claude drafts v0.4 +
  AUDIT_SPEC_013_V0_4_PROMPT.md for round 4 (very unlikely given
  v0.3's scope).
- After lock + merge, the implementing PR picks Option A or B
  per SPEC-013 §10 and the §11 post-lock checklist runs
  (decision-log entry, SPEC-003 install note, PR #103 disposition).
