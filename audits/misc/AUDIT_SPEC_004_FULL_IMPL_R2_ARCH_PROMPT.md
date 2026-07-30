You are auditing the COMPLETE SPEC-004 IMPL — bundled PR #263 — from
an ARCHITECT lens. R2 of the FULL-IMPL audit fleet.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `15f6323`.
- R1 absorbed (architect-relevant):
  - ARCH-FULL-M1: no committed audit-result artifacts → 4 new
    files in specs/SPEC-004-{PILLAR_B,PILLAR_C,PILLAR_DA,FULL_IMPL}-
    audit-results.md
  - ARCH-FULL-L1: candidate.go package doc still labels D/A "wholly
    future" → still TBD (LOW, deferred)
  - Indirect: Phase A wiring (was "dead code", now wired) addressed
    the bigger structural concern from adversarial-H1.

# R2 audit scope (ARCHITECT lens)

- **Scope discipline still clean.** PR is bundled. No SPEC-005
  quarantine work, no SPEC-008 hash work, no SPEC-002 baseline
  changes in the diff.
- **Routing package surface coherent.** With Phase A now wired
  through, the routing/sticky/ subpackage has a real production
  caller. Verify nothing in server.go bypasses sticky.Map (no
  leftover s.sticky or s.stickyMu references). Verify the new
  Update return-value contract (mismatch bool) is documented for
  callers.
- **Decision struct shape after R1 fix-pass.** Decision now
  carries 24 SPEC-004 §7 fields + 5 Legacy* aliases (R1) +
  FilteredCounts (R2 fix). Verify the shape remains comprehensible
  and forward-compatible (no naming conflicts, no field-shadowing
  bugs).
- **Audit-result artifact files.** Per BUILD prompt convention.
  Verify the four new audit-result files (Pillar B, C, D+A,
  FULL_IMPL) collectively reconstruct the convergence path for
  a future reader from the repo alone.
- **Deferred-work list status.** Five items deferred:
  - objective.go (sort comparator extraction)
  - dispatch.go (RewriteModel extraction)
  - retry.go (retry loop extraction)
  - InvalidateClass SIGHUP trigger
  - per-attempt FR-SR-17 log threading (attempt_index, retry_count,
    retried, preflight_result at retry/preflight points)
  - seedForRequest mid-request stability across UTC midnight
  - BalancedScores compute caching (perf)
  - More AC-SR-1 scenarios (test-engineer follow-up)
  - candidate.go package doc reword
  Verify each is correctly classified (genuinely-deferrable vs
  must-block-merge). Where any of these become MEDIUM under R2
  scrutiny, the rule "0 C/H/M after R2" means absorb now or
  document why deferring is safe.
- **Bundling-PR readability.** Squash-merge will collapse 19+
  commits to one. The audit-result artifacts + commit messages
  must preserve enough trail for the next session.
- **Forward-compat for Phase 2 operator flip.** Every flag still
  default-OFF? Production binaries still safe?

# Severity vocabulary

CRITICAL = structural defect blocking production; HIGH = scope
ambiguity forcing rework; MEDIUM = precision improvement materially
helping the next session or production safety; LOW = wording.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: **0/0/0/0 ready for merge**.

Read the BUILD prompt + every file in `internal/routing/` and
`internal/routing/sticky/` + the changed server.go sections + the
audit-result artifact files + relevant origin/main code. Cite
quotes.
