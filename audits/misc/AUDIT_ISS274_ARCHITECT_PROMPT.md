# AUDIT — Issue #274 — ARCHITECT lane

## Goal
Architecture / SPEC-alignment audit on PR-pending commit `0e4dce2` (branch `fix/iss274-provider-id-validator`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `phase4-coordinator/internal/config/config.go` — placement of `ValidateProviderID`
- `phase4-coordinator/internal/ws/messages.go` — gate-application order
- `phase4-coordinator/internal/auth/tokens.go` — gate-application order in mint paths

## Background

- Issue #266 Tranche 3 (PR #275) consolidated `ProviderID + "/" + AssignedID` derivation onto `pool.Provider.SortKey()`. The "/" delimiter invariant created an implicit contract on every code path that produces a `ProviderID`.
- Configured pinned providers already enforced this via `config.providerIDPattern`.
- WS self-serve registration + admission mint paths only validated non-empty / non-control-char.
- The fix exports `config.ValidateProviderID` and applies it to all five paths.
- The issue body suggested an alternative: move the pattern to `internal/pool` as the canonical home of the consumer (SortKey).

## Lens — ARCHITECT

Audit for:

- **Layering / placement** — is `internal/config` the right home for `ValidateProviderID`, given that:
  - The consumer of the invariant (`pool.Provider.SortKey`) lives in `internal/pool`
  - The producer (config-validated providers, WS-received providers, admission-minted providers) is spread across `config`, `ws`, and `auth`
  - `internal/pool` already imports `internal/config`
  - The alternative — `pool.ValidateProviderID` — would force `auth` and `ws` to take a new pool dependency
  
  Is `internal/config` the right least-coupled home, or should this live elsewhere?

- **Invariant ownership** — the docstring on `ValidateProviderID` names `pool.Provider.SortKey` as the invariant-owner. Does this docstring drift naturally over time, or is there a more durable way (e.g. a SortKey-side comment that points TO the validator, a test that pins the contract)?

- **SPEC alignment** — is there a SPEC document (SPEC-003 provisional self-serve, SPEC-010 catalog, etc.) that should be amended to name the validator contract? If so, would amending be in-scope for this PR or a follow-up?

- **Future-proofing** — if/when `AssignedID` changes from a UUID (e.g. spec adds a structured assigned-id format), is the SortKey delimiter still safe? Should we record this as a SortKey constraint on `pool.Provider` to prevent future ambiguity?

- **API surface** — is `ValidateProviderID` the right name? Are there existing validator patterns in the repo (`ValidateEndpointURL` is right next to it in config.go) — does the new helper match the established style?

- **Test architecture** — is one regression-test file per package the right shape, or would one shared validator-contract test (in `config_test`) be more discoverable?

- **Deprecation / migration** — pre-#274 providers in the wild may have registered with provider_ids that contain "/". After this fix lands, do they get rejected on next connect (causing a self-DoS)? Is there a transition plan needed?

## Out of scope

- Style nits (CODE lane)
- Specific vulnerability classes (SECURITY lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk / Concern: <why it matters at the architectural layer>
Recommendation: <concrete change, including whether deferring to a follow-up is appropriate>
```

Summarize: `C/H/M/L/INFO = a/b/c/d/e`.

If nothing above LOW: `ACCEPT — 0 C/H/M`.
