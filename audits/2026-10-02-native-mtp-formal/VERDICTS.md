# Native-MTP formal campaign freeze audit verdicts (2026-10-02)

Codex runs three lanes over `git diff origin/main...HEAD` (`omc ask codex`).
After each round, only the lanes that reported findings are re-run. The
operator cap is 3–4 rounds. Prompts: `r1/`, `r2/`, `r3/`, plus the round-4
`code.md` and `architect.md` at the top level.

| Lane | Round 1 | Round 2 | Round 3 | Round 4 | Final |
| --- | --- | --- | --- | --- | --- |
| security | 0/0/1/4 | 0/0/2/2 | **0/0/0/0** | not re-run | accepted, round 3 |
| code | 0/0/5/4 | 0/0/3/2 | 0/0/1/3 | **0/0/0/3** | 0 C/H/M, round 4 |
| architecture | 0/0/3/3 | 0/0/1/1 | 0/0/1/1 | 0/0/1/2 | cap reached; see below |

Counts are CRITICAL/HIGH/MEDIUM/LOW.

## After round 4 (fixed but not re-audited; the cap was reached)

- **Architecture MEDIUM: the MTP-7 fixture could not be satisfied at bound
  one.** MTP-7 now asks for native on every row the bound admits (a single
  row at bound one), and proves ordinary coexistence through the load-gate
  fixture at `qualified_slots`.
- **Architecture LOW: partial steps aggregated to `pass`.** The harness top
  level now reports `partial` whenever any passing step leaves clauses
  uncovered.
- **Architecture LOW: the bench README still described sustained resume.**
  The README now says admission sustained windows are never resumed.
- **Code LOW: analyzer integer domains.** Now bounded by Swift `Int.max`.
- **Code LOW: generator edge whitespace.** Now rejected, as the consumer
  does.
- **Code LOW: prompt-cap check.** It now also requires the
  `capability_mismatch` selector reason.

## Carried (classified by every lane as pre-existing, not introduced by this diff)

JOURNEY-NATIVE-MTP-SERVING step-07 mixed-batch parity fails on hardware.
Ordinary continuous-batching greedy output itself changes with arrival
timing (batch-composition numerics, the SPEC-048 §6 "Batched-verify
numerical parity" gap). It blocks the serving journey, which stays unsigned
and incomplete.
