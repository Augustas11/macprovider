# Audit prompt — SPEC-010 v1.1 (narrow scope, round 2)

Operator-paste prompt to audit SPEC-010 v1.1
(`specs/SPEC-010-model-catalog.md`).

**Round 2.** Round 1 (Codex GPT-5 on v1.0) found 0 CRITICAL / 3
MAJOR / 1 MINOR / 0 QUESTION at `specs/SPEC-010-audit.md`. v1.1
is a contract-tightening pass that claims to close all 4
findings.

Round 2 has two jobs:

1. **Round-1 fix verification (R1V)** — for each round-1 finding,
   cite the v1.1 rule/AC and mark PASS / PARTIAL / FAIL.
2. **Newly normative surface audit** — v1.1 added/changed §3.1
   (`auth_request` wire shape with `version`/`stage` fields and
   stage-mismatch rejection), AC-13 (rewritten log-comparison
   semantics), AC-16 (actual wire shape end-to-end), AC-17
   through AC-23 (8 new ACs total), and §6.1/§6.2 candidate
   annotations (corrected SPEC-002 §7.1 vs §7.2 citation).

Round 1 prompt (`specs/AUDIT_SPEC_010_PROMPT.md`) is background;
this is the active prompt for v1.1.

Append round-2 findings to the existing
`specs/SPEC-010-audit.md` file as a new top-level section after
the round-1 report. Do not overwrite round 1.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v1.1 at /Users/augstar/macprovider-poc/
specs/SPEC-010-model-catalog.md. This is round 2 of the audit on
the post-split narrow scope.

Round 1 produced /Users/augstar/macprovider-poc/specs/SPEC-010-
audit.md with 0 CRITICAL / 3 MAJOR / 1 MINOR / 0 QUESTION findings
on v1.0. v1.1 is a contract-tightening pass that claims to close
all 4 findings (B.1, E.1, E.2, E.3).

You are NOT here to validate, rewrite, or extend the spec. Two
explicit jobs:

  J-1. **Round-1 fix verification (R1V).** For each round-1
       finding v1.1 claims to fix, cite the specific v1.1
       rule/section/AC that closes it. Mark PASS / PARTIAL /
       FAIL. Findings whose fix is incomplete OR introduces new
       problems = file a new round-2 finding in the appropriate
       category AND mark PARTIAL in R1V.

  J-2. **Audit the v1.1-new normative surface.** Specifically:
       - §3.1 rewrite — `auth_request` frame with `version: 2`
         and `stage: "initial" | "proof"`, the new stage-mismatch
         rule for `supported_models` across stages, and the
         corrected SPEC-002 §7.1 source citation.
       - §6.1 SPEC-001 v1.2.5 candidate — now cites the v2
         `auth_request` initial stage explicitly.
       - §6.2 SPEC-002 v1.3.5 candidate — now correctly cites
         §7.1 (provider WS protocol) instead of §7.2 (buyer HTTP
         API).
       - AC-13 rewrite — response byte-diff stays literal; log
         assertion uses normalized comparison.
       - AC-16 — tests the actual `auth_request` wire shape AND
         negative case for legacy `type: "auth"` example.
       - AC-17 — R-3.1.1 non-array + mixed-array rejection.
       - AC-18 — stage-mismatch between `initial` and `proof`.
       - AC-19 — R-3.6.2 binary default emission.
       - AC-20 — R-3.6.3 binary-side length validation
         (both >64 entries and >256 bytes).
       - AC-21 — R-3.6.4 publish flag default vs explicit.
       - AC-22 — R-3.1.9 step-1-vs-step-5 priority.
       - AC-23 — R-3.1.9 step-4-vs-step-5 priority.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

APPEND a new top-level section to the existing file:
  `## Round 2 — Codex GPT-5 — 2026-06-06`
followed by category-organized findings. Do NOT touch the round-1
section. Do NOT change the round-1 verdict.

## Severity definitions

Unchanged from round 1:
- **CRITICAL** — production failure on rollout, silent regression
  of locked-spec behavior, scope creep into a locked upstream
  spec (SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1,
  SPEC-008 v0.3), security regression, or violation of L-1..L-6.
- **MAJOR** — significant implementer confusion, predictable
  patch needed, unjustified thresholds, ambiguous failure
  semantics, back-compat that doesn't hold up, OR scope
  expansion recommendations.
- **MINOR** — quality issues that don't block lock.
- **QUESTION** — unresolved design choice.

## Critical constraints

**1. Locked decisions (§2 L-1 through L-6) are READ-ONLY.** Same
as round 1.

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1, SPEC-008
v0.3 are LOCKED.** Same as round 1. v1.1's §3.1 now correctly
cites the v2 `auth_request` frame and SPEC-002 §7.1; verify
these citations against the actual locked text.

**3. v1.1's narrow scope is unchanged from v1.0.** Round-1 found
zero scope creep. Recommendations that expand v1.1 to handle
warm swap, demand-pull, or buyer catalog visibility are scope
creep into SPEC-011/SPEC-012 → MAJOR findings.

**4. Stage-mismatch rejection is the one v1.1 wire surface
addition** (beyond field placement). Audit it for SPEC-002 v2
auth handshake compatibility: does it actually make sense to
reject mismatch, or should the `proof` stage's
`supported_models` just be ignored? Whichever the spec says,
verify the choice is consistent with how the existing
`auth_request` two-stage flow works.

**5. Clean-room.** Do NOT inspect d-inference source.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.1 — the spec under audit. Read the v1.1 change log at the
   top FIRST. Then read §3.1 (rewritten), §3.6, §5 ACs (esp.
   AC-13, AC-16 through AC-23), §6.1, §6.2 carefully.

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md` —
   round-1 findings (the active R1V target). Search for `### B.1`,
   `### E.1`, `### E.2`, `### E.3` for the specific findings to
   verify.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` — project
   conventions.

4. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on §6.5 (auth handshake) to verify v1.1 §3.1
   matches the actual v2 `auth_request` shape.

5. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on §7.1 (provider WebSocket protocol; the
   correct source for SPEC-010 §3.1) and §7.3 (token/auth
   behavior). Confirm §7.1 actually documents the
   `auth_request` `initial`/`proof` flow as v1.1 §3.1 claims.
   If §7.1 has different content = MAJOR (citation still wrong).

6. Code spot-checks:
   - `phase4-coordinator/internal/ws/messages.go` lines 37-57
     (`AuthRequest` Go struct — confirm Stage, Version field
     types/values match v1.1 §3.1 example)
   - `phase4-coordinator/internal/ws/messages.go` lines 302-329
     (parser logic — confirm it rejects `type: "auth"` (v1.0
     spec's wrong example) and accepts `type: "auth_request",
     version: 2, stage: "initial"`)
   - `phase4-coordinator/internal/pool/provider.go` lines 50-88,
     174, 420-432, 464-477 (Provider struct, seenModels,
     ModelKnown, heartbeat — no v1.1 change here but spot-check
     the v1.0 R-3.3.4 behavior claim is still accurate after
     v1.1)
   - `phase4-coordinator/internal/buyer/server.go` lines
     1027-1030 (THE ModelKnown caller — v1.0 §3.3.4 note
     described its behavior; still accurate?)
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     lines 18-28 (existing CLI shape — AC-20's exit-code-2
     contract needs to be feasible against the current CLI
     framework)

7. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   — to confirm no scope creep INTO SPEC-011 territory in v1.1's
   added surface.

8. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md` v0.3
   — confirm v1.1 still has zero interaction with §5.7 hash
   block (no change expected).

## Audit categories — work through each

### Category R1V: Round-1 fix verification (HIGHEST PRIORITY)

Output as a table. Mark PASS / PARTIAL / FAIL with v1.1 location
verified and 1-sentence evidence.

Round-1 findings:

- **R1V-B.1** Auth frame name + SPEC-002 §7.2 mis-citation
  → v1.1 §3.1 (rewritten with `type: "auth_request"`, `version:
  2`, `stage: "initial"`, citing SPEC-002 §7.1) + AC-16
  (positive + negative wire shape test) + §6.1 / §6.2 candidate
  references corrected.
- **R1V-E.1** Provider-binary + malformed catalog AC coverage
  → v1.1 AC-17 (R-3.1.1 non-array/mixed), AC-18 (stage mismatch),
  AC-19 (R-3.6.2 binary default emission), AC-20 (R-3.6.3
  binary-side length validation), AC-21 (R-3.6.4 publish flag
  default/explicit).
- **R1V-E.2** AC-13 raw log byte-identity is CI-flaky → v1.1
  AC-13 rewritten with response byte-diff (literal) + log
  normalized-comparison (event names, severity, stable fields,
  count, no new SPEC-010 events).
- **R1V-E.3** Multi-failure validation priority only partially
  AC-locked → v1.1 AC-22 (step-1-vs-step-5) + AC-23
  (step-4-vs-step-5).

### Category A2: Locked-decision preservation (v1.1 re-verification)

A2.1  Walk L-1 through L-6 in §2. Verify v1.1's added surface
      doesn't accidentally violate any lock. Specifically:
      - L-1 byte-identical: does the new stage-mismatch
        rejection rule fire only for SPEC-010 providers who sent
        non-matching supported_models? Or could it produce a new
        rejection path for some legacy auth_request shape?
      - L-2 permissionless: AC-17 mixed-array rejection — is the
        "mixed array with non-string element" a content
        validation rather than a shape one? Acceptable per L-2?
        (It is — non-string entries fail step 1 type check
        because the array is not "array of strings.")

A2.2  L-1 byte-identical: AC-13 rewrite changes the assertion
      shape but not the underlying invariant. Verify the
      normalized-log comparison still actually proves L-1: if an
      implementer accidentally emits a new SPEC-010-related log
      event on the legacy path, would the normalized comparison
      catch it? It should — "no new SPEC-010-related entries"
      is part of the assertion. But verify the spec is precise
      enough that "SPEC-010-related" is identifiable in test
      harness terms.

### Category B2: Wire-format correctness (v1.1 new surface)

B2.1  §3.1 `auth_request` wire example: does it match the
      actual Go struct field set in messages.go lines 37-57?
      Walk every field in the example against the struct: any
      field in the example that doesn't exist in the struct =
      MAJOR (example is broken). Any required struct field
      missing from the example that an implementer would forget
      = MINOR (incomplete example).

B2.2  §3.1 stage-mismatch rule: the new rule says
      `supported_models` MUST match between `initial` and
      `proof` stages of `auth_request`. Verify this is
      consistent with how the existing two-stage flow handles
      other field repetitions. If other repeated fields are
      tolerated to diverge (e.g. `binary_version`), the
      strict-match rule for `supported_models` alone is
      load-bearing — is it justified? If two-stage divergence
      is impossible by construction (e.g. coordinator never
      validates the proof stage's `supported_models`), the
      stage-mismatch rule is busy-work = MINOR.

B2.3  §3.1 wire example "remaining existing fields per SPEC-002
      §7.1": confirm SPEC-002 §7.1 actually documents the full
      field set with sufficient detail that an implementer can
      reconstruct it. If §7.1 is sparse and the implementer
      would need to scan code = MAJOR (the example's "..."
      becomes a hidden dependency).

B2.4  AC-16 negative case: tests that `type: "auth"` (v1.0
      spec's wrong example) is rejected by the v2 parser. The
      AC says "BEFORE reaching SPEC-010 catalog validation." Is
      the rejection actually before catalog validation in the
      current parser, or could it pass through to catalog
      validation and produce a different error code? Spot-check
      messages.go:302-329 to confirm.

### Category C2: AC quality (v1.1's 23 ACs)

C2.1  AC-13 normalized-log comparison: practical implementation
      check. Can the test harness actually parse logs into
      structured event records and apply normalization? If the
      coordinator's log format isn't structured (plain text
      with embedded timestamps), the normalization is nontrivial
      and AC-13 may still be CI-flaky in practice. Spot-check
      coordinator log format. If unstructured logging =
      MAJOR (AC-13 fix is theoretical).

C2.2  AC-17 second case (mixed array `[42, "ok"]`): how does
      this map to R-3.1.9 step 1 ("JSON type check on
      supported_models — must be array of strings")? Does the
      Go encoding/json parser surface "mixed-type array" as
      step 1 type failure or as some downstream parse error?
      If Go reports element type errors at element-decode time
      rather than array-decode time, AC-17's expected error
      reason may not be producible = MAJOR.

C2.3  AC-18 stage-mismatch: practical implementation. Does the
      coordinator currently retain initial-stage payload for
      cross-stage comparison? If not, AC-18 requires a new
      retention mechanism the spec doesn't otherwise mandate.
      Spot-check messages.go parser flow. If parser is
      stateless = MAJOR (AC needs a §3 rule to retain).

C2.4  AC-20 binary-side validation: stderr message text must
      "match the coordinator-side reason strings in R-3.1.9
      verbatim." Walk R-3.1.9 reason strings against AC-20
      expected strings — exact match? If diverged = MINOR
      (close, just needs alignment).

C2.5  AC-21 publish flag: covers default-false vs explicit-true.
      Is there a third case worth covering — explicit-false?
      Probably equivalent to default-false in observable
      behavior, but if an implementer might serialize the field
      differently when explicit = MINOR.

C2.6  AC-22 / AC-23 priority cases: verify they actually
      exercise the priority ordering. AC-22 expects step 1
      reason despite step 5 also failing. AC-23 expects step 4
      reason despite step 5 also failing. Are there other
      plausible high-value priority cases worth adding (e.g.
      step 2 vs step 3, where both length and array-cap
      failures could collide)? If a high-value case is missing
      = MINOR.

### Category D2: Companion-spec annotations (v1.1)

D2.1  §6.1 SPEC-001 v1.2.5 candidate: the v1.1 NOTE explicitly
      clarifies "the binary serves no buyer requests on the
      `auth_request` path." Walk SPEC-001 §6.5 to confirm. If
      §6.5 also implies buyer-API responsibilities on this path
      = MAJOR (candidate annotation mis-frames the binary's
      role).

D2.2  §6.2 SPEC-002 v1.3.5 candidate: cites §7.1 (provider WS)
      and notes §7.2 is buyer HTTP. Confirm SPEC-002 §7.3
      (token/auth) doesn't ALSO need a candidate annotation
      because SPEC-010 fields are "pre-token data carried in
      the same auth_request envelope" — is the placement
      relative to token validation actually correct? Verify
      token validation order in messages.go parser. If
      validation order would reject SPEC-010 fields before
      they're stored = MAJOR.

### Category E2: Anything else

E2.1  Documentation drift: any non-spec doc still references the
      v1.0 `type: "auth"` example shape? Check HANDOFF.md,
      RUNBOOK.md, CONTINUE_RUNBOOK.md, AGENTS.md. If yes =
      MINOR (those refs will rot post-lock).

E2.2  Decision-log entry: v1.1 doesn't yet include a
      DECISION_CRITERIA entry. Pre-lock so not yet a finding,
      but note for executive summary.

E2.3  Naming nit: §3.1 title was "Provider → coordinator: `auth`
      frame extension" — does v1.1 rename to `auth_request`? If
      title still says `auth` = MINOR (inconsistency with body).

E2.4  Anything that round-1 missed and v1.1's surface exposes.

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`.
Start your section with:

```
---

## Round 2 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v1.1 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-2 executive summary

[2-3 paragraphs. State whether v1.1 is ready to LOCK, ready with
the round-2 findings closed, or needs another pass. Specifically
note whether the round-1 fixes actually closed in substance.]

### Round-1 fix verification (R1V)

[Table: round-1 finding ID, PASS / PARTIAL / FAIL, v1.1 location
verified, 1-sentence evidence.]
```

Then for each category R1V, A2-E2, write a section. For each
finding:

```
### A2.1  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: §3.1, line ~XXX

[What. 1-3 sentences.]

[Why it matters. 1-3 sentences.]

[Recommendation. 1-2 sentences.]
```

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source (NOASSERTION license)
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-011 outline (separate cycle)
- Re-litigating round-1 findings already marked PASS

## Done criteria

You are done when:

- Round-2 section APPENDED to SPEC-010-audit.md (round 1 intact)
- Every round-1 finding has PASS / PARTIAL / FAIL in R1V
- Every category R1V, A2-E2 has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Round-2 executive summary states a clear verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 15-25 min (small surface to audit).
- Convergence target: 0 CRITICAL / 0 MAJOR → lock SPEC-010 v1.1
  directly without v1.2.
- If audit finds ≥1 CRITICAL or >1 MAJOR, draft v1.2, re-audit
  round 3. The narrow scope should make convergence achievable
  within 1 more round.
- After lock, append decision-log entry to
  `beta/DECISION_CRITERIA.md` summarizing the split decision
  and SPEC-010 v1.1 scope.
