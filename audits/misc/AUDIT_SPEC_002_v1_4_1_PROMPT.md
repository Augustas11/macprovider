# SPEC-002 v1.4.1 Audit Prompt — additive `/poolz` `auth_state` delta

You are a SPEC auditor. Scope is the SPEC-002 v1.4.1 additive delta only —
NOT the rest of SPEC-002.

## Branch / commit
- Branch: `fix/gateway-poolz-auth-state`
- Worktree: `../macprovider-gateway-poolz-auth-state` (origin/main base: e816dff)
- File in scope (read the diff `git diff origin/main -- specs/SPEC-002-coordinator.md`):
  - `specs/SPEC-002-coordinator.md`

## What this delta does (operator summary — not the audit answer)

Tracking issue #82 item 1. The coordinator's `pool.Provider.AuthState`
has been emitted on `/poolz` since SPEC-003 v0.8.3 (enum
`bearer_validated`, `self_minted`, `bearerless_duplicate`, `mint_failed`),
but SPEC-002 never documented it as part of the `/poolz` contract surface.

The v1.4.1 delta:
1. Adds `auth_state` to the FR-O2 `/poolz` provider-row example + a
   new descriptive paragraph.
2. Adds a normative aggregation rule: downstream `/poolz` consumers (the
   SPEC-006 gateway `/v1/status`) MUST exclude
   `auth_state == "bearerless_duplicate"` rows from capacity counts
   (Ready, per-model ReadyProviderCount, slot totals, model availability).
3. Bumps version 1.4.0 → 1.4.1 (additive; pre-v1.4.1 consumers that
   ignore unknown fields keep working).

## Sources of truth to cross-check

- `phase4-coordinator/internal/pool/provider.go` — `AuthState` const block
  (~lines 64-91) and `RoutingEligible()` (~line 214).
- `phase4-coordinator/internal/ws/server.go` — `/poolz` handler
  (~line 2705 onward), `providerPublishedReady` (~line 2784).
- `specs/SPEC-003-*.md` — FR-C9.1 / FR-C9.4 normative source for the
  enum semantics.
- `phase5-gateway/internal/router/server.go` — the downstream consumer
  whose `aggregateStatus` the new normative rule binds.

## Audit lenses (apply each independently — do not collapse)

### Lens 1 — contract correctness
- Does the v1.4.1 enum match what the coordinator actually emits today?
- Is the `omitempty` semantics ("absent/empty preserves pre-v0.8.3
  behavior") consistent with `pool.Provider.AuthState` zero-value
  being treated as routable by `RoutingEligible()`?
- Is the cross-reference to SPEC-003 (v0.8.3 for the enum, v0.8.4
  for `mint_failed`) accurate against the current spec text?

### Lens 2 — aggregation-rule precision
- The new rule excludes only `bearerless_duplicate`. SPEC-003 v0.8.4
  added `mint_failed` with the rationale that admitting it as fully
  routable would amplify a DB-error storm into a routing DoS. But
  `pool.Provider.RoutingEligible()` excludes only
  `AuthBearerlessDuplicate`. Is the SPEC self-consistent in deferring
  `mint_failed` aggregation policy to issue #82 item 2 rather than
  bundling it here?
- Does the rule cover the right counters? (Ready, ReadyProviderCount,
  slot totals, availability — vs. TotalProviders, which the IMPL also
  excludes.) Is the SPEC silent on TotalProviders intentional or a gap?
- The gateway's existing summary-fallback path triggers when the per-
  provider loop produces zero entries
  (`out.Pool.TotalProviders == 0 && poolz.Summary.TotalProviders > 0`).
  After v1.4.1, an all-bearerless pool would land in this fallback
  using coordinator-supplied `Summary.TotalProviders` (which includes
  bearerless) and `Summary.Ready` (which already excludes bearerless
  per coordinator-side `providerPublishedReady`). Does the SPEC need
  to address this edge case explicitly?

### Lens 3 — version policy
- Is v1.4.1 (patch bump) the right semver step for an additive `/poolz`
  field PLUS a new normative aggregation rule? Or should this be v1.5
  given the second change has behavioural consequences for the gateway?
- Are pre-v1.4.1 consumers actually safe? The gateway already decodes
  `/poolz` without `auth_state` today — they get the over-promise bug
  but no parse error. Is "additive" the right characterization?

### Lens 4 — completeness and cross-spec consistency
- Anything in the FR-O2 prose or the `/poolz` example block that
  contradicts the new paragraph?
- Are downstream specs that reference `/poolz` (SPEC-006 gateway,
  SPEC-015 receipt-pubkey absorption) affected and missing a
  cross-reference? Should v1.4.1 add a pointer in SPEC-006?
- Is the change-log entry style consistent with v1.4.0 and v1.4
  preceding entries?

### Lens 5 — operator visibility
- Does the SPEC distinguish clearly enough between "auth_state is
  emitted for operator visibility (all values)" and "auth_state ==
  bearerless_duplicate triggers buyer-facing capacity exclusion"?
  Could an operator reading only v1.4.1 misunderstand bearerless
  rows being hidden from operators?

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

Write the audit report to `specs/SPEC-002-v1-4-1-audit.md` with the round
number in the filename if this is a follow-up round (e.g.
`specs/SPEC-002-v1-4-1-r2-audit.md`).

If 0 CRITICAL and 0 HIGH and 0 MEDIUM, end the report with the line:
`VERDICT: READY TO LOCK v1.4.1`
