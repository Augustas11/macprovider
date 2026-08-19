# Codex audit — SPEC-042 gateway pool auth/emit slice — ARCHITECT lane

You are the architecture-review lane. Judge whether this slice is the right
shape, sits at the right boundary, and composes correctly with the coordinator
pool routing already merged in the base. Review the FULL slice diff as it lands.

Diff: `audits/2026-08-19/gateway-pool-auth-fulldiff.patch` (base `c70f97ce`,
which already contains coordinator pool ingestion/routing/isolation/settlement
labels). Read changed files in the worktree. Spec:
`specs/SPEC-042-pool-control-plane.md` (R002, R010). Design:
`docs/design/spec-042-v0.1-slice-gateway-pool-auth.md`.

## Context
This is the gateway half of SPEC-042 Layer 2: credential->pool authorization +
the positive coordinator↔gateway capability handshake (R010) + the
`X-MacProvider-Pool` emit. Deliberately deferred (documented in the design):
wallet-session pool selection (needs a SPEC-040 envelope amendment); per-API-key
pool columns (this slice binds at account granularity via operator config); the
provider-half capability advertisement; predicate-specific error codes.

## Focus (Critical/High/Medium/Low/Info, with rationale)
1. Boundary correctness: is authorization at the right layer (gateway, before
   reservation/dispatch)? Is the capability handshake modeled correctly —
   coordinator advertises, gateway refuses on absence — and does the division of
   labor (gateway checks coordinator; coordinator enforces member-only routing;
   provider-half deferred) leave any spill gap that is NOT fail-closed?
2. Contract/compat: the coordinator advertisement is a shared wire contract
   (`/internal/routing.pools.enabled`) consumed by the gateway. Is it
   forward/backward compatible (old gateway ignores it; old coordinator omits
   it -> gateway fails closed)? Does the emitted header contract match exactly
   what the base coordinator honors (name, sanitization, auth gating)?
3. Scope discipline: are the deferrals sound and safe (each fails closed, not
   open)? Is the account-granularity config ceiling an acceptable MVP for the
   credential binding, or does it create a trap when per-key scopes arrive?
4. Is the feature genuinely default-off and the poolless path byte-identical?
   Any global-traffic behavior change, latency, or new failure mode introduced
   for non-pool requests (e.g., the capability fetch on the hot path)?
5. Idiomatic fit: does the slice follow existing gateway patterns (feature
   config, capability-metadata gating like sticky, error registration) or invent
   a divergent one? Any abstraction that will not survive the next slice
   (wallet-session selection, per-key scopes, provider-half handshake)?
6. Anything under-specified that should block landing vs. safely follow up.

Rank by severity with rationale. Report 0 findings if architecturally sound.
