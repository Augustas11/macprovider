# AUDIT — BUILD_SPEC_CHAOS_HARNESS_KICKSTART PR 1 (IMPL) — ARCHITECT lane

## What to audit

Branch `feat/chaos-scenario-12-reconnect-storm` (worktree at
`/Users/augstar/macprovider-chaos-pr1`). Diff:

```
git -C /Users/augstar/macprovider-chaos-pr1 diff origin/main...HEAD
```

Files changed:

- `test/network-harness/scenarios/15_provider_reconnect_storm.yaml` — new
- `test/network-harness/README.md` — new "Chaos lane" subsection + row in scenarios table

## Intent

This is PR 1 of a chaos/resilience lane inside `test/network-harness/`.
The lane's job is to exercise money-path invariants I1–I4 under
adversarial conditions. Scenario 12 is a scenario-only kickstart —
zero Go changes — that reuses the existing chaos primitive (a
`/bin/sh -c` executor with a `chaos_events` YAML timeline).

Discovery report is captured in the PR body / build spec; salient
architectural bets baked into this PR:

1. **Hybrid rig, not local rig.** Chaos targets the local provider
   process; Pearl coord+gateway are the SUT. No new coord+gateway
   local-bring-up infra shipped in this PR.
2. **Local rig decision deferred to PR 2.** Follow-up scenarios that
   need coord/gateway-side chaos (`13_gateway_restart_midstream.yaml`,
   `14_packet_loss_5pct.yaml`) will force the local-rig decision when
   they land, not before.
3. **`launchctl` command shape reused from scenarios 05, 06** — no new
   chaos vocabulary introduced.
4. **I1–I4 unchanged.** Chaos scenarios inherit the same hard
   invariants as the happy-path scenarios; no scenario-local
   tolerance bumps.
5. **Follow-up roadmap declared in README** (PR 2–5) so the shape of
   the lane is visible without a separate SPEC.

## Audit focus (ARCHITECT lane)

Please assess and write findings to
`specs/BUILD_SPEC_CHAOS_HARNESS_PR1_r1_architect-audit.md`. Rate
CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line, evidence,
concrete fix.

Bar for shipping: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.

### 1. Composability of the chaos primitive

- Read `test/network-harness/internal/chaos/runner.go` and
  `internal/scenario/schema.go` `ChaosEvent`. Is scenario 15's use of
  the primitive representative — will PR 2/3/5 (gateway restart,
  packet loss, coord restart) work through the SAME primitive without
  needing extensions? If so, great — argue why. If not, name the
  extension point that will be needed and whether shipping 12 first
  makes that harder or easier.
- Multiple chaos events (5 in this scenario) run as independent
  goroutines with a shared `context.Context` and a `sync.WaitGroup`.
  Any coordination assumption in the runner that scenario 15
  stress-tests for the first time (e.g. events firing after `duration`
  ends — spec comment says late events still fire)? Verify against
  code and against the 85s belt-and-suspenders event vs 90s duration.

### 2. Extensibility of the local rig — deferral rationale

- The README addendum explicitly defers the local coord+gateway
  bring-up decision. Is that the right architectural call given what
  the follow-up roadmap (PR 2–5) needs?
- Are there ANY latent commitments in scenario 15 that will make the
  future rig decision harder — e.g. an assumption that Pearl SSH is
  always available, that the buyer token is always live-Pearl-issued,
  that the DB snapshot path always shows Pearl paths? If so, name
  them and propose either (a) documenting them explicitly as known
  future churn, or (b) adjusting scenario 15 now.
- The scenario hardcodes `pearl:/var/lib/macprovider/coordinator.db`
  and `pearl:/var/lib/macprovider/gateway.db`. If PR 2 introduces a
  local rig, is the schema flexible enough to swap SSH paths for
  local paths without touching the scenario, or will scenario 15
  need to be forked?

### 3. Chaos artifact schema stability

- `chaos_events.json` schema is fixed by `internal/chaos/runner.go`
  `EventResult`. Scenario 12 relies on the same shape as scenarios
  05, 06. Verify no field is added / renamed / dropped by this PR.
- Phase-B triage will compare `chaos_events.json` across runs and
  across scenarios. Is the fixed schema rich enough to distinguish
  "kick fired but launchd didn't restart" from "kick fired and
  restart happened"? If not, INFO-level: what field would you add,
  and is it worth doing in a separate PR before more chaos scenarios
  land?

### 4. Fit within the phase-A / B / C discipline

- Read `test/network-harness/README.md` "Phase A → B → C flow" and
  "The four hard invariants" section. Is scenario 15 correctly framed
  as PHASE A (descriptive `expected_shape`, all findings recorded not
  asserted, exit-10 only on I1–I4 fail)? Or does it accidentally
  smuggle in a soft assertion?
- The `expected_shape` block includes a "PHASE B TRIAGE" call-out
  matching the sibling scenarios' style. Verify it invites the right
  triage question (root-causing repeated-kick drift → double-settle,
  routing race, unbounded retry) rather than pre-answering it.

### 5. Anti-scope discipline

- Per repo memory `feedback-bundle-spec-impl-one-pr` and the build
  spec's §4 "Do NOT include in first PR" list: verify this PR
  contains ONLY scenario 15, its README addendum, and the audit
  prompts. No changes to `phase4-coordinator`, `phase5-gateway`,
  `phase3-binary`, `internal/chaos/`, `internal/invariants/`, or any
  other harness Go code.
- Verify the README table row for scenario 15 doesn't leak future PR
  2–5 scenarios into the "committed" table.

### 6. SPEC-022 impact assessment

- Would scenario 15's expected outcomes reveal a genuine SPEC-022
  gap that the spec hasn't accounted for? For instance: SPEC-022 R-5.9
  says unverified prefixes cannot be charged — but SPEC-022 is silent
  on double-settlement risk when a provider reconnects mid-buyer-stream.
  If you see a plausible spec gap, name it and file it as a SEPARATE
  SPEC-only note (do NOT recommend folding into this PR — see repo
  memory `feedback-no-design-doc-churn`).
- If SPEC-022 is already tight enough for the reconnect-storm case,
  say so — that's a valid PASS for this lane.

### 7. Follow-up-roadmap coherence

- The README addendum's PR 2–5 table promises specific fault modes.
  Are the promised faults actually implementable with the existing
  chaos primitive plus a local rig decision at PR 2? Any that require
  a SPEC amendment first (e.g. `15_slow_provider_streaming.yaml`
  needs a provider-side throttle knob that may not exist)?
- Flag if any roadmap row is aspirational without a clear
  implementation path — LOW-level finding, not shipping blocker.

## Deliverable

Write findings to
`specs/BUILD_SPEC_CHAOS_HARNESS_PR1_r1_architect-audit.md` with the
same structure as the CODE lane: verdict header + `## Findings`
section, `### <SEVERITY>-N — <title>` entries listing file:line,
evidence, fix.

If zero C/H/M — write the file anyway to record convergence.
