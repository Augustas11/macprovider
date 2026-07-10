You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), ARCHITECT lane, ROUND 3.

R2 returned 1 CRITICAL (rollout-window row-3+ behavior still
contradictory at SPEC-005 §8.2 + SPEC-002 lines 75-76) + 2 LOW
(SPEC-007 design notes stale `[GAP]`; "tens of ms" empirical wording).

R3 fixes:
- **CRITICAL**: SPEC-005 §8.2 quarantine paragraph + SPEC-002
  change-log both reworded to say row 3+ is credited normally in BOTH
  the persisted-attempt_n path AND the byte-identical id-ASC fallback
  path. Only attempt_n=1 retried=0 remains as a quarantine class.
- **LOW**: SPEC-007 design notes `[GAP]` for stored attempt_n updated
  to `[GAP-CLOSED]` pointing at SPEC-002 v1.5.2 / issue #168.
- **LOW**: SPEC-002 backfill live-safety wording removed the "tens of
  ms" empirical claim; replaced with operator-discretion-based
  wording.
- Cross-lane: SPEC-005 §10.5 + AC-ATTEMPT-FALLBACK fixture detail
  (line 2510) also reworded; ban on direct SQL `UPDATE
  quarantined=0` added explicitly.

## Verify

- Cross-SPEC consistency: SPEC-002 v1.5.2 change-log + SPEC-005
  v0.3.3 change-log + SPEC-005 §8.2 + §15.2 + §10.5 + AC-D10 + AC-
  ATTEMPT-FALLBACK + OQ-1 + SPEC-007 design notes — do they ALL
  agree that row 3+ is credited normally in BOTH paths and that
  only attempt_n=1 retried=0 is the remaining quarantine class?
- Are there ANY remaining contradictions or scope ambiguities in
  the SPEC text?
- The "direct SQL unquarantine ban" sentence — is the cross-link to
  #169 strong enough that operators don't try to side-step?
- The backfill live-safety wording — is it operator-actionable now,
  or does it just shift the burden ("measure it yourself") without
  guidance?
- SPEC-007 design notes `[GAP-CLOSED]` annotation: should normative
  SPEC-007 ALSO get a sentence acknowledging the closed gap, or is
  the design-doc annotation sufficient?
- Any other spec files that reference attempt_n derivation outside
  what I've audited (SPEC-001, SPEC-003, SPEC-004, SPEC-016)? Do
  they need updates?

## Severity rubric

- **CRITICAL**: contradiction with another SPEC remains.
- **HIGH**: ambiguity that splits implementations.
- **MEDIUM**: cross-SPEC pointer / scope gaps.
- **LOW / NIT**: phrasing, defensive clauses.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
