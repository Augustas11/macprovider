# BYOM v0.2 slice 5 IMPL — independent cold-context review (2026-09-11)

Reviewed: `git diff origin/main -- phase4-coordinator scripts docs/runbooks specs/CONFORMANCE.json` at `4f2cc9f3` (content base = merge-base `1d2c930b`) plus the two operator-committed files, by three Claude lanes (code-reviewer, security-reviewer, architect; model opus; neutral prompt in the session scratchpad `slice5-independent-impl-review-prompt.md`; forbidden from reading `audits/`, `.omc/`, `.claude/`).

| Lane | C | H | M | L | I | Verdict |
|---|---|---|---|---|---|---|
| code-reviewer | 0 | 0 | 0 | 2 | 1 | APPROVE |
| security-reviewer | 0 | 0 | 0 | 1 | 3 | LOW |
| architect | 0 | 0 | 0 | 1 | 2 | — |

Bar met on every lane (0 C / 0 H / 0 M). Each lane verified the load-bearing invariants against the governing text: transient raw principal (token derived then account cleared before any mutation), `window_key` and principal tables zeroed at close, distinct-principal k-anonymity with sub-floor/sub-k omission, no identity on any wire/DB/log/grant, one 401 timing class with the auth-failure debit, two-sided freshness and read-side revalidation, complementary fleet suppression with the reconciliation invariant, the store-level pair ceiling, the four-category sanction predicate with ungated withdrawal (R006), and end-to-end evidence re-derivation in the generator.

## LOW findings and dispositions

- **Money-path recover covered only `Observe`, not the hook's catalog pre-checks** (security L1): the `recover()` now wraps the entire `observeUnmatchedModel` body, so no part of the intake path can fail or alter a buyer request (SPEC-017 §5.2b.2). Fixed.
- **Keyless-intake auth-failure slot not refunded on the 500 path** (architect L1): the `dispatchAuth` error path now refunds on `reservedKey != ""`, matching the reservation and success-path guards, so a burst of transient auth-dispatch 500s cannot spuriously drive later requests to 429. Fixed.
- **Runtime intake reconfiguration is restart-only** (code L1 / architect INFO / security INFO): intended and now documented — the coordinator reads `stats.intake.*` once at load, so a change closes the open window only on restart (`aggregator_stopped`); the "one window never mixes two policies" invariant still holds because a restart closes it. Runbook note added; `SetPolicy`/`SetParams` remain for a future SIGHUP path. Carried.
- **R009 test coverage does not directly assert the pair-ceiling abort, the build-timeout, the registration- and canary-sanction categories, or the operator rate limit** (code L2): the registration/canary categories are exercised at the shared `providerModelAdmissionSanctioned` predicate by the offer-path sanction tests; the ceiling and timeout are bounded-store/const paths. Carried as a coverage note; the invariants are met in code.

## INFO (carried, no change)

- `cap` shadows the builtin in `aggregator.go` (cosmetic).
- The operator intake snapshot loop has no explicit shutdown signal (matches the existing server background-loop pattern; not slice-5-specific).
- `handleIntake`'s internal disabled-endpoint 404 is unreachable behind the mux check (belt-and-suspenders).
- The branch was 5 commits behind `origin/main`; rebased onto current `origin/main` before the PR so the diff cannot appear to revert the continuous-batching runbook (the PR-rebase-silent-dep-regression pattern). Slice-5 touches none of those files.
