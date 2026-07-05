Branch: `fix/autotune-timeout-progress` (commit `ae23d48`).

Context: fresh-install onboarding was 100% failing at `.autotuning`
because `AutotuneRecommendationRunner.processTimeout` was 30 seconds
but autotune actually needs 2-20 minutes on cold installs (real
model-load + prefill benchmarks). See:
- `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift`
  (bumped 30 → 1800s, added rationale comment)
- `phase3-binary/app/Tests/MalibuTests/AutotuneRecommendationRunnerTimeoutTests.swift`
  (3 new tests pinning the invariant against CLI's own budgets)
- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:379-420`
  (`Stage1Prober` with `readyTimeoutSec=120`, `probeIdleTimeoutSec=300`)
- Smoke evidence:
  `/private/tmp/claude-501/.../scratchpad/smoke-v183/` (v1.8.3 timing
  traces showing autotune manual run for 90+ seconds)

Scope of THIS PR is strictly the timeout bump + tests. Progress UI
(tail stderr for `[warn] spec-023 probe:` messages) is deferred to a
follow-up. Do NOT recommend scope expansion — just audit what's here.

Lock bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

Output format (per repo convention):

Start with:
`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`
or:
`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then ID-prefixed findings (severity-first). Each finding must cite the
file:line and concrete evidence.
