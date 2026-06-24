# Audit prompt — SPEC-013 v0.2 (round 2 — audit-response check)

Operator-paste prompt to audit SPEC-013 v0.2
(`specs/SPEC-013-cli-autotune.md`).

**Round 2 of N (audit-response check).** Round 1 (Codex on v0.1,
`specs/SPEC-013-audit.md`) returned `0 CRITICAL / 7 MAJOR / 11
MINOR / 2 QUESTION`. v0.2 claims to close all 7 MAJORs, 10 of 11
MINORs, and both QUESTIONs (M.2 documentation-checklist MINOR was
intentionally deferred to a post-lock checklist). v0.2's change log
block at the top of the spec enumerates each closure with explicit
audit-finding references (A.1, D.1, E.1, F.1, F.2, G.1, J.1 for
the MAJORs).

Round 2 is NARROWER than round 1. The brief: "Did v0.2 actually
close the round-1 findings, and did the closures introduce new
contract precision gaps?" Round 2 is NOT a fresh full-spec audit —
findings unrelated to the round-1 list are accepted but should be
rare, and any v0.2-introduced regression in unchanged FRs is a
CRITICAL anti-regression finding.

Output to the same file: `specs/SPEC-013-audit.md`. APPEND a new
"## Round 2 audit (Codex on v0.2)" section AFTER the existing
round-1 sections; do NOT overwrite round 1. The single-file pattern
matches `specs/SPEC-010-audit.md` and `specs/SPEC-011-audit.md`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the audit on SPEC-013 v0.2 at
/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md.
Round 1 was you (Codex) on v0.1; the report is in
/Users/augstar/macprovider-poc/specs/SPEC-013-audit.md. v0.2 is
the audit-response draft on the same feature branch.

You are NOT here to validate, rewrite, or extend the spec. You are
here to answer two questions:

1. Did v0.2 actually close each round-1 MAJOR, MINOR, and QUESTION
   it claims to close? Closure means "the new wording does not
   admit the failure mode round-1 named." Cosmetic closures that
   restate the problem without fixing it are NOT closed.
2. Did the round-1 closures introduce new contract precision
   gaps elsewhere in the spec? v0.2 edited large sections (FR-D
   rewritten, FR-E.1 rewritten, FR-F.1/F.2/F.3 retitled, FR-G.1
   expanded, §7 CLI summary changed, 3 new ACs added, JSON schema
   expanded, §11 expanded with renumber note + post-lock
   checklist). Each edit is a potential precision-loss site.

Output: APPEND a new section to
  /Users/augstar/macprovider-poc/specs/SPEC-013-audit.md
titled `## Round 2 audit (Codex on v0.2)`. Do NOT overwrite or
edit the round-1 sections; the round-1 report is the historical
record.

Match the rigor and tone of round 1 and of prior audit reports in
this repo (specs/SPEC-010-audit.md, specs/SPEC-011-audit.md).

## Severity definitions (unchanged from round 1)

- **CRITICAL** — would cause production failure on rollout; silent
  regression of locked spec behavior; v0.2 INTRODUCED a contract
  violation in a previously-correct FR; v0.2's claimed closure
  of a round-1 finding is COSMETIC and the original failure mode
  still applies.
- **MAJOR** — round-1 MAJOR closure is incomplete (closed in some
  cases but admits the failure mode in others); v0.2 introduced
  a new precision gap; the round-1 closure language is
  unambiguous but conflicts with a different existing FR.
- **MINOR** — quality issues that don't block lock; closure works
  but the new wording is awkward or has a sentence-level error.
- **QUESTION** — genuinely unresolved design choice surfaced by
  the v0.2 changes.

## Critical constraints (unchanged from round 1)

All round-1 critical constraints remain in force:

1. The "biggest-fit, not max-tps" framing in §1 is LOCKED.
2. SPEC-001 v1.4, SPEC-002 v1.3.5, SPEC-003 v0.9.2, SPEC-010
   v1.5, SPEC-011 v0.5 are LOCKED.
3. SPEC-only, no code.
4. Additive only / Tier-1 backward compat.
5. Operator-supplied candidate-list order is the contract.
6. Default candidate list is curated by the network.
7. Knob-axis claims must match PR #105 reality.
8. Clean-room boundary on d-inference.
9. Telemetry / privacy invariant: nothing leaves the machine.

Additionally for round 2:

10. **Anti-regression discipline.** v0.2 must NOT have weakened or
    broken any v0.1 FR that round 1 did NOT flag. Spot-check the
    untouched sections (§1 mission, §2 scope, §3 architecture,
    §5.1 FR-A, §5.2 FR-B, §5.3 FR-C, §5.5 FR-E.2 `--no-join`,
    §6 NFR-1/2/3/4, AC-1-5 and AC-7-8, AC-10-15, AC-16). Any
    regression introduced into these = CRITICAL anti-regression
    finding.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md`
   v0.2 — the spec under audit. Pay particular attention to the
   v0.2 change-log block at the top, which enumerates each
   closure claim with explicit audit-finding references.

2. `/Users/augstar/macprovider-poc/specs/SPEC-013-audit.md`
   round-1 report — the input to this round. Round 2's job is to
   verify each round-1 finding is closed (or honestly flag the
   ones that aren't).

3. `/Users/augstar/macprovider-poc/specs/AUDIT_SPEC_013_PROMPT.md`
   — the round-1 prompt, for severity definitions and critical
   constraints.

4. Code spot-checks for the new factual claims v0.2 introduces:
   - `phase3-binary/Sources/MacProviderCore/Config.swift`
     lines 239-241 — verify v0.2 FR-F.3's owned-key list
     (`model`, `kv_bits`, `max_context_override`,
     `max_concurrency_override`) matches what the parser
     actually reads. v0.1 had this wrong; v0.2 claims it's
     fixed.
   - `phase3-binary/dist/install.sh` lines ~749 and ~923 +
     `phase3-binary/dist/launchd-plist-template.plist` — verify
     v0.2 FR-E.1's launchd label `live.streamvc.macprovider`
     and the bootout/bootstrap drain sequence match
     SPEC-003 v0.9.2 + the install scripts.
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
     lines 559-566 and 622-641 — verify v0.2 FR-D.1's Shape B
     "rely on online-fallback during load" claim matches the
     actual runtime behavior.

5. The PR #103 prototype branch `spike/provider-model-autotune`
   `beta/autotune.py` — verify v0.2 §12 L.1 closure correctly
   characterizes what the prototype actually does (no explicit
   pre-download).

You do NOT need to re-read SPEC-001 / SPEC-002 / SPEC-003 /
SPEC-010 / SPEC-011 in full — round 1 covered them. Spot-check
only where v0.2's edits make a new factual claim about a locked
spec.

## Round 2 audit categories — work through each in order

### Category Z-CLOSURE: did v0.2 actually close round 1?

For each round-1 finding listed below, write a closure verdict:
**CLOSED**, **PARTIAL** (some failure modes closed, some not),
**NOT CLOSED** (cosmetic / failure mode still applies), or **OVER-CLOSED**
(closure introduced a new gap). For PARTIAL / NOT CLOSED /
OVER-CLOSED, file a finding with severity.

Round-1 MAJORs:
- **A.1** fallback contradiction → v0.2 replaces `fallbacks` with
  NAME-ONLY `alternates`; AC-1/AC-2 updated. Verify.
- **D.1** `models pull` precondition understated → v0.2 reframes
  FR-D as "weights cache-warm before probe; measurement-isolation
  guarantee" with Shape A / Shape B implementation choice.
  Verify the contract is now sufficient without depending on a
  not-yet-existing `models pull` subcommand.
- **E.1** launchd label wrong → v0.2 binds to
  `live.streamvc.macprovider` and the SPEC-003 bootout/bootstrap
  sequence. Verify against `phase3-binary/dist/`.
- **F.1** `--apply` wrote wrong YAML keys → v0.2 updates to
  `max_context_override` / `max_concurrency_override`. Verify
  against `Config.swift:239-241`.
- **F.2** recipe_hash not deterministic → v0.2 pins
  `sha256:<64-lowercase-hex>` + RFC 8785 JCS + explicit hash
  input domain. Verify the canonicalization profile is
  implementable from the spec text alone.
- **G.1** SQLite migration invalid → v0.2 spells the SQL as
  `ALTER TABLE tune_trials ADD COLUMN stage INTEGER NOT NULL
  DEFAULT 1`. Verify this is now valid SQLite.
- **J.1** no AC for operator-supplied order → v0.2 adds AC-17.
  Verify AC-17 actually catches the failure mode (an
  implementation that pre-sorts `--candidate-models` by
  parameter-count-descending must fail AC-17).

Round-1 MINORs (10 claimed closed):
- B.1 (max-context-axis semantics); C.1 (CLI summary kv-bits);
  F.3 (backup naming); G.2 (transactional retention); H.1
  (--resume removed from §7); J.2 (AC-18 new); J.3 (AC-19 new +
  exit_reason enum); K.1 (OQ-B/D thresholds); L.1 (prototype
  migration note); M.1 (cross-spec renumber note).

Round-1 QUESTIONs (2 resolved):
- D.2 (signature mismatch vs network failure) → v0.2 splits
  pre-warm failures into transient (advance) vs integrity
  (abort whole run). Verify the classification is operationally
  unambiguous.
- K.2 (thermal/order) → v0.2 adds OQ-E with a quantitative
  decision threshold. Verify the threshold is measurable from
  the planned air5 data.

### Category R-REGRESSION: anti-regression in unchanged FRs

Walk these v0.2-UNCHANGED FRs and confirm they still work as
v0.1 originally specified:

- §5.1 FR-A.1, FR-A.2, FR-A.3, FR-A.4 (Stage 1 iteration logic)
- §5.2 FR-B.1, FR-B.2, FR-B.3 (Stage 2 hill-climb)
- §5.3 FR-C.1, FR-C.2, FR-C.3 (default candidate list)
- §5.5 FR-E.2 `--no-join` (still an implementation precondition;
  the binary doesn't yet have this flag)
- §6 NFR-1, NFR-2, NFR-3, NFR-4
- §8 AC-1 through AC-5, AC-7, AC-8, AC-10, AC-11, AC-13, AC-14,
  AC-15

If v0.2 incidentally edited any of these and weakened them =
CRITICAL anti-regression. If v0.2 left them as-is and round 1
already covered them = no finding.

Specifically check:
- AC-1 + AC-2 wording: v0.2 changed the `fallbacks` →
  `alternates` outputs. Verify the ACs were updated correctly,
  not just renamed.
- FR-A.2 step 7: v0.2 must still STOP iterating models on first
  feasible. v0.2's new `alternates` list MUST be populated from
  the operator's input list, NOT from a fallback-probing pass
  that re-iterates.
- FR-B.2 `_is_new_best` semantics: v0.2 must not have changed
  the throughput-primary + TTFT-tiebreak-within-epsilon rule.

### Category N-NEWGAPS: precision gaps introduced by v0.2 edits

For each v0.2 edited section, check whether the new wording
introduces:
- A claim that contradicts another part of the spec
- An ambiguity that didn't exist before
- A reference to a locked spec section that doesn't exist
- A code citation (file path, line number, function name) that
  doesn't match reality

Specific check sites (high-leverage):

- §5.4 FR-D.1: the "measurement-isolation" contract requires
  load-fetch latency to be excluded from gate-ttft-ms. Is the
  exclusion mechanism specified precisely enough to implement?
  How does the implementation distinguish "load-fetch latency"
  from "first-request prefill latency"?
- §5.4 FR-D.2: the integrity-class enumeration includes
  "repository contents inconsistent with expected shape (e.g.
  missing tokenizer.json)." Is this enforceable by autotune,
  or does it require coordination with the HF cache layer? If
  the failure mode can only be detected at serve-start (not at
  pre-warm), the abort-whole-run rule may be wrong.
- §5.5 FR-E.1 launchd drain: step 2's "do NOT escalate to
  SIGKILL on a launchd-managed install" — what if the
  bootout-then-poll never frees the port? The spec says
  "abort with a clear error" — is the operator state recoverable
  from there?
- §5.6 FR-F.2 recipe_hash input domain: the spec enumerates
  fields IN the hash but uses ad-hoc field names. Cross-check
  against the JSON schema — any field named in the hash input
  that doesn't actually appear in the JSON schema = MAJOR
  (impossible to compute).
- §5.6 FR-F.3 launchd hint: the hint command uses `$UID` (shell
  variable). Will the printed hint work as a copy-paste in the
  operator's shell, or does autotune need to resolve `$UID` at
  print-time?
- §5.7 FR-G.1 transactional retention: SQLite transaction
  semantics — must the retention sweep be in the SAME
  transaction as the new `tune_runs` INSERT, or a SEPARATE
  transaction after the insert commits? v0.2 says "after the
  new `tune_runs` row is created" which is ambiguous on this
  point.
- §5.7 FR-G.2 exit_reason enum: the enum lists 9 values; do any
  of them collide with the `applied INTEGER` semantics? E.g.
  `applied = 1, exit_reason = 'interrupted'` — is the
  interrupted state allowed to have applied changes already?
- §7 `--kv-bits-axis` representation table: the `serve_command`
  row says "`--kv-bits` flag omitted entirely" when value is
  null. Is the FR-F.2 JSON `knobs.kv_bits: null` consistent
  with this? The `serve_command` string and the JSON must
  produce identical runtime behavior.
- §8 AC-17: is the test setup precise enough? "Hardware where
  both 1B and 32B are feasible" — does this exist on any
  realistic test rig, or is the test always hardware-specific?
  May need a mock-provider-based test.
- §8 AC-18: `--max-context-axis 2000,4000` with `--target-context
  4000` — the test says the 2000 cell makes it invalid. Is the
  rejection rule clearly enough specified that an implementer
  knows to fail at flag-parse time vs Stage-2 setup?
- §9 OQ-E thermal threshold: "would produce a DIFFERENT
  keep-best winner more than 5% of the time" — measurable how?
  Run the same cell set forward + reverse N times and compare?
  How many repeats? Is this defensible?
- §11 cross-spec renumber note: verify SPEC-014 is not already
  claimed by any other in-flight spec work.
- §12 L.1 closure: verify against `beta/autotune.py` on the
  prototype branch.

### Category O-OTHER: anything else round 2 surfaces

This is the catch-all. Round 2 should NOT generate broad new
findings outside the round-1 scope; if you find one, ask
yourself whether round 1 should have caught it (and if so, file
it as MAJOR-class because that's a hole in round 1's coverage
that v0.2's edits may have exposed).

Examples that DO belong here:
- AC numbering off-by-one after v0.2 added 3 ACs
- Cross-reference drift (a section number that v0.2 edits
  invalidated)
- Change-log block at top has a typo or references a wrong
  audit-finding ID

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-013-audit.md`:

```
---

## Round 2 audit (Codex on v0.2)

**Audited:** SPEC-013 v0.2 (specs/SPEC-013-cli-autotune.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED / N
                     OVER-CLOSED] across 7 MAJOR + 10 MINOR + 2
                     QUESTION round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]

### Executive summary

[2-3 paragraphs. State whether v0.2 is ready to lock, ready with
narrow v0.3 fixes, or needs another response round. Be specific.]

### Round-1 finding closures

For each of the 19 round-1 findings (7 MAJOR + 10 MINOR + 2
QUESTION), one paragraph: closure verdict and rationale. Reference
the round-1 finding's category code (e.g. "A.1 → CLOSED").

### Round-2 new findings

Group by category Z / R / N / O. Same finding format as round 1:
SHORT TITLE, severity, location, what / why / recommendation.

### Lock readiness

State your verdict in one of:
- LOCK READY (no CRITICAL, ≤3 MAJOR — operator may lock or roll
  narrow v0.3)
- NARROW V0.3 REQUIRED (any CRITICAL anti-regression, or >3
  MAJORs)
- STRUCTURAL REVISION REQUIRED (multiple CRITICAL or v0.2
  failed to close >2 round-1 MAJORs)
```

## Out of scope for round 2

- Re-litigating round-1 findings that v0.2 closed
- Rewriting the spec
- Implementing the spec
- Auditing locked specs themselves
- Re-litigating biggest-fit framing
- Picking Option A vs Option B

## Done criteria

You are done when:

- The new "## Round 2 audit (Codex on v0.2)" section is appended
  to `/Users/augstar/macprovider-poc/specs/SPEC-013-audit.md`.
- Round-1 sections are unchanged.
- Each of 19 round-1 findings has an explicit closure verdict.
- Each round-2 new finding has severity, location, what / why /
  recommendation.
- Lock-readiness verdict is stated.

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: ~20-30 min Codex round 2 (narrower than
  round 1, primarily closure verification + new-gap spot-checks).
- Round-2 expected outcome (estimated): LOCK READY with 0-2
  remaining MINORs to clean in v0.3 OR at lock-time. The MAJORs
  in round 1 were code-grounded and v0.2's responses are
  code-grounded; the closure rate should be high.
- If round 2 returns LOCK READY: operator decides whether to lock
  v0.2 as-is or roll a narrow v0.3 closing the remaining MINORs.
  Either is acceptable per the SPEC-010 v1.5 / SPEC-011 v0.5
  patterns.
- If round 2 returns NARROW V0.3 REQUIRED: Claude drafts v0.3
  closing the remaining issues and authors
  `AUDIT_SPEC_013_V0_3_PROMPT.md` for round 3.
- After lock, the implementing PR picks Option A (Swift-native) or
  Option B (Python wrapper) per SPEC-013 §10. PR #103 disposition
  per the §11 post-lock checklist.
