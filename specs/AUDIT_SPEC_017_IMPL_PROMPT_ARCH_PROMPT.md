# AUDIT_SPEC_017_IMPL_PROMPT — Architecture lane

Operator-paste prompt to audit `BUILD_SPEC_017_IMPL_PROMPT.md` from the architecture lens.

Severity model (per user instruction): findings tagged **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target: 0 CRITICAL + 0 HIGH + 0 MEDIUM. LOW + INFO MAY be deferred and acknowledged in the convergence commit.

Each round writes a fresh file: `specs/SPEC-017-IMPL-PROMPT-arch-rN-audit.md`.

---

```
=== BEGIN PROMPT ===

You are auditing the IMPL kickoff prompt
/Users/augstar/macprovider-spec-017/specs/BUILD_SPEC_017_IMPL_PROMPT.md
from the ARCHITECTURE lens.

Your audit target is the IMPL prompt itself, NOT the SPEC. The SPEC
(`specs/SPEC-017-network-stats-api.md` v0.1.6) is LOCKED and is the
single controlling contract. Your job is to find problems in HOW the
IMPL prompt instructs a fresh session to encode that contract.

Output: /Users/augstar/macprovider-spec-017/specs/SPEC-017-IMPL-PROMPT-arch-r1-audit.md
(round N writes SPEC-017-IMPL-PROMPT-arch-rN-audit.md; new file each round.)

Severity model:
- **CRITICAL** — would cause IMPL author to ship code that violates a
  locked SPEC invariant, breaks a public-API contract, or skips a
  prerequisite that would brick the deploy. Architectural drift that
  cannot be fixed in code without re-opening the SPEC.
- **HIGH** — would cause significant scope creep, an unnecessary v0.2
  fix-round within the first month, structural misalignment between
  steps (e.g. step 1 leaks responsibility into step 2 in a way that
  loses audit-lens benefit), or a missing structural boundary that
  the SPEC pins.
- **MEDIUM** — would cause confusion for the IMPL author, an
  ambiguity that two conforming IMPL sessions could resolve
  differently, or missing structural guidance for a non-trivial
  surface.
- **LOW** — quality/polish issues that don't block IMPL.
- **INFO** — observations worth surfacing but not findings.

## Critical constraints to honor while auditing

1. **SPEC-017 v0.1.6 is LOCKED.** Any finding that would REQUIRE a
   SPEC change is HIGH or CRITICAL (depending on whether the IMPL
   could legitimately go ahead without it). Do NOT propose SPEC
   changes as fixes; propose IMPL-prompt rewrites.
2. **Four locked design picks (advisor mirror):** separate rollup
   pipeline, public overview + optional partner keys on leaderboard,
   bucketed-default earnings + opt-in exact, embed in coordinator
   binary. Any IMPL-prompt phrasing that would let the IMPL author
   silently flip one of these is CRITICAL.
3. **Step boundaries are load-bearing.** The IMPL prompt decomposes
   into 4 steps with codex audits between. Any structural seam that
   bleeds across steps (e.g. handlers landed in step 1 schema PR;
   nginx config landed in step 3 handler PR) is HIGH.
4. **One-PR-per-step.** Per [[pr-rebase-silent-dependency-regression]]
   the rebase discipline matters. Any phrasing that would let two
   step PRs land out of order or merge without rebase is HIGH.
5. **Audit-loop is per-step + per-lane** (ARCH, CODE, SECURITY).
   Convergence is gated before PR. Any phrasing that weakens this
   (e.g. "single-lane audit if scope is small") is HIGH.

## Required reading

1. `/Users/augstar/macprovider-spec-017/specs/BUILD_SPEC_017_IMPL_PROMPT.md`
   — the document under audit. Read fully.
2. `/Users/augstar/macprovider-spec-017/specs/SPEC-017-network-stats-api.md`
   v0.1.6 LOCKED — the controlling contract. Read fully.
3. `/Users/augstar/macprovider-spec-017/specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
   — the closest analog (SPEC-016 IMPL kickoff). Compare structure
   for missing-section drift; SPEC-017 is structurally simpler but
   should not omit any conceptual seam SPEC-016 needed.
4. `/Users/augstar/macprovider-spec-017/specs/SPEC-017-advisor-round-2026-06-25.md`
   — the locked Q1-Q4 design picks.
5. `/Users/augstar/macprovider-spec-017/specs/SPEC-017-r1-audit.md`
   through `SPEC-017-r7-audit.md` — skim for the why behind each
   locked MUST; the IMPL prompt should not silently un-do an audit
   closure.

## Architecture audit categories

### A. Step decomposition correctness
A.1  Is the 4-step decomposition genuinely orthogonal? Do steps 2/3
     have hidden dependencies on step-1 schema choices that aren't
     surfaced?
A.2  Does each step end at a natural seam where the SPEC sections
     cluster? Specifically: are §9.1 schemas + §7.2 grants + §5.4.1
     partner_keys table + §6.1/§6.5 visibility tables all in step
     1, or are any split?
A.3  Are the audit lanes (ARCH, CODE, SECURITY) genuinely
     applicable to each step, or do some steps have a trivial
     SECURITY lane that wastes a round?
A.4  Step 4 (CLI + nginx + observability) — is this genuinely one
     step, or does it bundle three distinct surfaces (DevOps,
     operator UX, ops/monitoring) that each warrant their own seam?

### B. Prerequisite coverage
B.1  §1 prereqs (1-6): are they complete? Specifically, does the
     prereq list cover everything an IMPL author needs to know
     before writing code, OR are there hidden dependencies on
     operator action that surface later?
B.2  Is the hostname-pattern decision (prereq 1) genuinely a
     pre-IMPL gate, or could it be deferred until step 4 nginx work?
B.3  Is the SPEC-016 re-pin (prereq 3) actually necessary as a
     hard gate, or is it sufficient as "re-check at IMPL time"?
B.4  Is "discharge SPEC-014 v0.9 before SPEC-017 v0.1.6 IMPL"
     EVER required, or never required? The SPEC says v0.9 is a
     follow-up candidate. The IMPL prompt should make this
     unambiguous.

### C. Cross-step structural integrity
C.1  Does step 3 assume any code that step 2 doesn't produce? E.g.
     does step 3 reference a rollup snapshot the step-2 rollup
     pipeline doesn't actually write?
C.2  Does step 4 nginx config reference rate-limit zones the step-3
     handlers don't expose?
C.3  Is the partner-key authn flow (§5.4.3) implementable WITHOUT
     the partner-key CLI (step 4)? Or does step 3 effectively
     require step 4's CLI to land first for any keyed test to pass?

### D. PR strategy
D.1  Is one-PR-per-step actually viable, or do two steps need to
     land together (e.g. step 1 schema + step 2 rollup) because
     they can't be CI-greened independently?
D.2  Is the rebase discipline ([[pr-rebase-silent-dependency-regression]])
     mechanically enforceable, or does the IMPL prompt rely on
     author discipline alone?
D.3  Is the 4-PR series ordered correctly? Could step 3 land before
     step 2 if the rollup is mocked? If yes, should the prompt
     surface that as an optional shortcut?

### E. Audit-loop discipline
E.1  Is "0 CRITICAL + 0 MAJOR" the right lock target for the IMPL
     audits, or should it be "0 CRITICAL + 0 HIGH + 0 MEDIUM" to
     align with this audit's severity model?
E.2  Are MINOR findings actually deferrable, or do some of them
     in the SPEC-016 IMPL history reveal that "MINOR" should not be
     deferred for money-path or wire-contract surfaces?
E.3  Is the three-lane (ARCH, CODE, SECURITY) split genuinely
     useful for each step? Or does step 2 (rollup pipeline) have a
     mostly-trivial ARCH lane because the SPEC pins the structure
     exactly?

### F. SPEC-prompt fidelity
F.1  Compare every "What lands" bullet to the SPEC section it cites.
     Drift = HIGH. Missing = CRITICAL if SPEC says MUST.
F.2  Compare every "Tests" bullet to the corresponding AC. Missing
     AC coverage in tests = HIGH.
F.3  Are the 21 ACs each mapped to at least one step's "Tests"
     section? Walk through AC-1 through AC-21 and call out gaps.
F.4  Does the prompt include §11 Q1-Q13 in the §6 deferral list?
     Missing any of them = MEDIUM (those are explicit operator
     v0.2 questions the IMPL must not silently close).

### G. Honesty about scope
G.1  Is the 4-step + 4-audit cost honestly described, or does the
     prompt hide the ~12 codex rounds the SPEC-016 history shows
     are typical?
G.2  Is the operator-runbook scope (OPS.md) actually achievable in
     step 4, or does it bleed into step-5-that-doesn't-exist?
G.3  Are the "done when" criteria mechanically checkable, or do
     some of them rely on subjective judgment that two IMPL authors
     could resolve differently?

## Output format

Produce `specs/SPEC-017-IMPL-PROMPT-arch-rN-audit.md`:

```
# SPEC-017 IMPL prompt — ARCH lane audit, Round N (Codex, YYYY-MM-DDTHH:MM:SSZ)

## Summary
- N CRITICAL findings
- M HIGH findings
- K MEDIUM findings
- L LOW findings
- I INFO

## Category sweep
| Category | Result |
|---|---|

## CRITICAL findings
C1. ...
   **Location:** ...
   **Finding:** ...
   **Why it matters:** ...
   **Suggested fix:** ...

## HIGH findings
H1. ...

## MEDIUM findings
M1. ...

## LOW findings
L1. ...

## Operator questions
q1. ...

## Verdict
- READY TO LOCK
- READY WITH FIX PASS
- ANOTHER DESIGN ROUND NEEDED
```

Self-verification before declaring complete:
- [ ] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [ ] Read SPEC-017-network-stats-api.md fully.
- [ ] Walked each Category A through G.
- [ ] Severity for each finding chosen against the definitions above.
- [ ] Location (line range) on every finding.
- [ ] Suggested fix for every CRITICAL and HIGH finding.
- [ ] Verdict at end.

Print a 200-word handback summary then stop. Do NOT begin drafting
the fix prompt.

=== END PROMPT ===
```
