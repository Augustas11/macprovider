You are auditing the Pillar D + A IMPL slice of SPEC-004 from an
ARCHITECT lens.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `922e454` (D+A R1 fix-pass).
- R1 absorbed: ARCH-M1 (sticky refresh-at-cap split into refresh-
  path-first vs insert-path-with-eviction) + ARCH-L1 (BalancedScores
  doc reword).

# Audit scope (ARCHITECT lens)

Standard slate: scope cohesion, sequencing, composition with
adjacent specs, NOT-covered exhaustiveness, gates structure.

R1-specific re-check:
- Verify the sticky.Map.Update refactor splits cleanly into two
  paths (refresh vs insert) with no shared state mutation risk.
- Verify the new Decision.Legacy* fields don't bloat the struct
  in a confusing way (they should default-derive transparently).
- Verify the BalancedScores doc reword accurately describes the
  Phase D deferred 'per-component logging' work without
  introducing new false claims.
- Verify no new circular dependencies or buyer-internal leaks
  from the additions.

# Severity vocabulary

CRITICAL / HIGH / MEDIUM / LOW per R1.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0.

Read the BUILD prompt §Phase D + §Phase A + R1 fix-pass commit +
relevant origin/main before writing any finding.
