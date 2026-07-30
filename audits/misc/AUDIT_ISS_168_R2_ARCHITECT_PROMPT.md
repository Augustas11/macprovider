You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), ARCHITECT lane, ROUND 2.

R1 returned 1 CRITICAL + 1 HIGH + 2 LOW. R2 fixes:

1. **CRITICAL: SPEC-005 stale row-3+ references.** Rewrote 5+
   locations across §D10 (line 334), v0.3.3 quarantine narrative
   (line 746), AC-D10 expected text (line 1270), AC-D10 fixture
   detail (line 1383), §15.2 legacy fallback (line 1115), OQ-1
   resolution narrative (line 1577), AC-D10 fixture oracle
   (line 2378). All now describe row 3+ as credited normally.

2. **HIGH: legacy-quarantine resolution claim.** Reworded change-log
   to be honest: v0.3.3 closes the quarantine CREATION class for
   row 3+. Pre-existing quarantines from v0.3.1 remain immutable
   per ledger schema (`quarantined` is `0 → 1` monotonic transition).
   Resolution requires the §OQ-5 force-credit/force-void admin
   surface (issue #169) — explicitly out of scope for #168.

3. **LOW: backfill live-safety SHOULD vs MAY.** SPEC-002 change-log
   now: SHOULD run during a maintenance window; MAY run live but
   operators MUST accept that the UPDATE holds the writer lock and
   could trigger 6s INSERT timeouts → buyer 503s. Small corpora
   MAY skip the window.

4. **LOW: future umbrella subcommand** — deferred, out of scope.

## Verify

- SPEC-005 internal consistency: are there ANY remaining
  references to "row 3+ MUST quarantine" or "row 3+ is quarantined"
  in the SPEC body? Should turn up zero. (`rg "row 3\\+ .* quarantin"
  specs/SPEC-005-billing.md` should match only historical/legacy
  references explicitly framed as resolved.)
- The "pre-existing quarantines are immutable" narrative — is the
  cross-link to #169 sufficient? Should SPEC-005 explicitly recommend
  that an operator who wants to clear legacy quarantines wait for
  #169, OR is "manual SQL UPDATE under explicit operator authority"
  acceptable?
- Cross-SPEC consistency: SPEC-002 v1.5.2 change-log + SPEC-005
  v0.3.3 change-log + the SPEC-005 §15.2 legacy fallback text —
  do they agree on the row-3+ contract? Look for divergence.
- The backfill SHOULD-vs-MAY language: is "tens of milliseconds for
  single-digit-thousand legacy rows" empirically defensible, or
  should the SPEC offer a row-count threshold for operators to
  use as a decision point?
- SPEC-002 v1.5.2 change-log says backfill MAY run live but the
  v0.3.3 quarantine class transition isn't fully covered: during
  the rollout window, a NULL `attempt_n` row going through the
  id-ASC fallback derivation could still land in the row-3+ slot
  and be credited normally. That's consistent with v0.3.3. But
  during the BACKFILL UPDATE itself (which is a single transaction),
  could a concurrent hot-path INSERT see a partially-applied state?
  (Answer: no, because BACKFILL UPDATE is atomic. Worth checking
  the UPDATE SQL again.)
- Cross-spec dep: SPEC-005 v0.3.3 depends on SPEC-002 v1.5.2.
  Does anything else need to bump its SPEC-002 dependency? SPEC-006,
  SPEC-007, SPEC-016 don't consume attempt_n directly, but check.

## Severity rubric

- **CRITICAL**: contradiction with another normative SPEC remains.
- **HIGH**: ambiguity that splits implementations on observable
  behavior.
- **MEDIUM**: cross-SPEC pointer / scope gaps.
- **LOW / NIT**: phrasing, defensive clauses.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
