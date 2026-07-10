You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), ARCHITECT lane, ROUND 4.

R3 returned 1 CRITICAL (SPEC-002 line 46 `legacy` state contradicted
v0.3.3 row-3+ crediting) + 1 HIGH (line 1703 v1.5.0 AttemptN
defense-in-depth paragraph still said all three sites "derive from
COUNT") + 1 LOW (SPEC-007 line 567 stale `[GAP]` for stored attempt_n).

R4 fixes all three:
1. **CRITICAL**: SPEC-002 `legacy` state text updated to apply v0.3.3
   fallback rules: row 3+ credited normally via byte-identical id-ASC
   arithmetic; only `attempt_n=1 retried=0` quarantined.
2. **HIGH**: SPEC-002 line 1703 paragraph renamed "AttemptN read-side
   discipline (v1.5.2; supersedes v1.5.0 derivation rule)" and rewritten
   to say: read persisted `request_log.attempt_n` when non-NULL, fall
   back to v1.5.0 COUNT-based derivation only when NULL. Final sentence
   pins the row-3+ rule explicitly.
3. **LOW**: SPEC-007 line 567 `[GAP]` updated to `[GAP-CLOSED]` per
   SPEC-002 v1.5.2 / #168.

R3 security MEDIUM additionally fixed via `--dry-run` (see security
lane prompt).

## Verify

- SPEC-002 v1.5.2 internal consistency: do `legacy` / `populating` /
  `populated` state descriptions agree with the v0.3.3 row-3+ rule?
- SPEC-002 line 1703 paragraph: does the new text correctly describe
  the v1.5.2 column-first read with v1.5.0 COUNT-based fallback?
  Any residual contradiction with §request_log table or §15.2?
- SPEC-007 design-doc internal consistency: §2.3 and §3.4 both
  show `[GAP-CLOSED]` for stored attempt_n now?
- Cross-SPEC sweep one more time: SPEC-001, SPEC-003, SPEC-004,
  SPEC-005, SPEC-006, SPEC-016 — do they all agree on the v0.3.3
  contract?
- Are there ANY remaining stale "row 3+ MUST quarantine" / "row 3+
  is quarantined" / "Row 3+ quarantined until SPEC-002" references
  anywhere in `specs/`?
- The `--dry-run` operator surface: does the SPEC text accurately
  describe how operators decide between live and maintenance-window?
  Is "4s warning threshold = 75% of 6s budget" mentioned in SPEC,
  or only in the CLI emit?

## Severity rubric

- **CRITICAL**: contradiction with another SPEC remains.
- **HIGH**: ambiguity that splits implementations.
- **MEDIUM**: cross-SPEC pointer / scope gaps.
- **LOW / NIT**: phrasing, edge cases.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
