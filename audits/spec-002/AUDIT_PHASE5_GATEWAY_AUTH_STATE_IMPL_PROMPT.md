# Phase 5 Gateway `auth_state` IMPL Audit Prompt

You are an IMPL auditor. Scope is the gateway-side `/poolz` decode +
capacity aggregation change for issue #82 item 1 — NOT the SPEC-002 v1.4.1
delta, NOT the rest of phase5-gateway.

## Branch / commit
- Branch: `fix/gateway-poolz-auth-state`
- Worktree: `../macprovider-gateway-poolz-auth-state` (origin/main base: e816dff)
- Files in scope (`git diff origin/main -- phase5-gateway/`):
  - `phase5-gateway/internal/router/server.go`
  - `phase5-gateway/internal/router/server_test.go`

## What the change does (operator summary — not the audit answer)

1. Adds `AuthState string \`json:"auth_state,omitempty"\`` to the inner
   anonymous struct in `poolzResponse.Pool` (~line 506).
2. In `aggregateStatus` (~line 581), the first thing the loop body does
   is `if p.AuthState == "bearerless_duplicate" { continue }` — BEFORE
   any counter is touched.
3. Adds two new tests in `server_test.go`:
   `TestAggregateStatusExcludesBearerlessDuplicatesFromCapacity` and
   `TestAggregateStatusAllBearerlessPoolReportsNoCapacity`.

## Authoritative source the IMPL must mirror

- `phase4-coordinator/internal/pool/provider.go`
  - `AuthState` const block defining the enum (~lines 64-91)
  - `RoutingEligible()` (~line 214) — currently excludes ONLY
    `AuthBearerlessDuplicate`; `AuthMintFailed` is intentionally NOT
    excluded per SPEC-003 v0.8.4 rationale.
- `phase4-coordinator/internal/ws/server.go` `providerPublishedReady`
  (~line 2784) — coordinator's own `/poolz` summary computation; same
  exclusion shape.
- `specs/SPEC-002-coordinator.md` v1.4.1 (this branch) — the normative
  contract the IMPL must honor.

## Audit lenses (apply each independently — do not collapse)

### Lens 1 — correctness vs SPEC
- Does the IMPL exclusion match the new SPEC-002 v1.4.1 normative rule
  (excludes `bearerless_duplicate`, includes everything else)?
- Does the IMPL agree with the authoritative coordinator-side predicate
  `pool.Provider.RoutingEligible()`?
- The exclusion uses the string literal `"bearerless_duplicate"`. The
  authoritative const is `pool.AuthBearerlessDuplicate` in
  `phase4-coordinator/internal/pool/provider.go`. The gateway cannot
  import `phase4-coordinator` internals. Is the string-literal duplication
  acceptable? Is there a risk the value drifts from the const? If a
  drift-prevention test is warranted, where would it live?
- The decode field uses `json:"auth_state,omitempty"` matching the
  coordinator's emission tag. Confirm pre-v0.8.3 coordinators (which omit
  the field) decode to `""` and aggregate normally.

### Lens 2 — placement of the early-`continue`
- The `continue` is placed BEFORE `out.Pool.TotalProviders++` and BEFORE
  the `switch p.State` block. This means a bearerless duplicate is
  excluded from EVERY counter, including `TotalProviders`. Compare
  against SPEC-002 v1.4.1 which only explicitly requires exclusion from
  `Ready / ReadyProviderCount / slots / availability` — TotalProviders
  isn't explicitly covered. Is the IMPL over-excluding? Could it be
  argued that operators want bearerless rows visible in TotalProviders
  as a "non-routable but present" count?
- Does the same `continue` correctly skip per-model registration
  (`models[p.ModelID]`, `supportedSets[p.ModelID]`, `stats[p.ModelID]`)?
  Could a bearerless duplicate's `supported_models` array still leak
  into the buyer-visible per-model union? Trace through the loop body
  and confirm.

### Lens 3 — summary-fallback edge case
- The function has an existing fallback at
  `if out.Pool.TotalProviders == 0 && poolz.Summary.TotalProviders > 0`
  which copies `poolz.Summary.TotalProviders` and `poolz.Summary.Ready`
  into the output. After this change, an all-bearerless pool yields
  `out.Pool.TotalProviders == 0` and triggers the fallback. Trace what
  the buyer sees in that case:
  - `out.Pool.TotalProviders` becomes coordinator's `Summary.TotalProviders`
    (which INCLUDES bearerless rows — see `phase4-coordinator/internal/ws/server.go` ~line 2682 `TotalProviders: len(providers)`).
  - `out.Pool.Ready` becomes coordinator's `Summary.Ready` (which
    EXCLUDES bearerless rows via `providerPublishedReady`).
  Is this acceptable? Does the test `TestAggregateStatusAllBearerlessPoolReportsNoCapacity` cover it adequately?
- Could an attacker / misconfigured coordinator construct a `/poolz`
  response that exploits the fallback to inflate buyer-visible Ready?

### Lens 4 — test adequacy
- Are the two new tests sufficient? Specifically:
  - Mixed-pool test asserts TotalProviders=3, Ready=3, slot totals,
    per-model availability. Is there an off-by-one risk it would miss?
  - All-bearerless test asserts no model entries appear. Verify the
    summary-fallback in that test doesn't accidentally populate Ready.
- Missing-coverage check:
  - Empty `auth_state` (pre-v0.8.3 coordinator) — does any test prove
    it still counts as routable?
  - `auth_state == "mint_failed"` — does any test pin its current
    routable treatment so item 2 can flip it explicitly?
  - `auth_state` with an unknown future value — does the IMPL silently
    aggregate it (defensive default) or skip it?

### Lens 5 — broader gateway surface
- Are there OTHER places in `phase5-gateway/` that decode `/poolz` or
  consume per-provider entries from the coordinator? `grep` for `poolz`,
  `auth_state`, `bearerless`, and any place that constructs capacity
  counts. If a sibling code path exists, has it been updated too?

### Lens 6 — money-path side effects
- This is buyer-facing capacity. Could the change reduce capacity below
  what a billing/usage path expects? Check `coordinatorBuyerURL` callers
  and any health-gated routing that consults `/v1/status`. If a
  bearerless duplicate currently "counts" in some money-path predicate,
  removing it from `/v1/status` aggregation could shift behavior
  elsewhere. Trace the consumers.

## Output format

Return findings in this exact structure:

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>

HIGH (N):
  H1. ...

MEDIUM (N):
  M1. ...

LOW (N):
  L1. ...

QUESTIONS (N):
  Q1. ...
```

Use the CRITICAL/HIGH/MEDIUM/LOW severity scale (not MAJOR/MINOR).

Write the audit report to `specs/PHASE5_GATEWAY_AUTH_STATE_IMPL_audit.md`
with a round suffix on follow-ups (e.g.
`specs/PHASE5_GATEWAY_AUTH_STATE_IMPL_r2_audit.md`).

If 0 CRITICAL and 0 HIGH and 0 MEDIUM, end the report with the line:
`VERDICT: READY TO MERGE phase5-gateway auth_state IMPL`
