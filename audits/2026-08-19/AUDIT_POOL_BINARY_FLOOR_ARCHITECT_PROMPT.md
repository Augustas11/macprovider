# Codex audit — SPEC-042 pool binary-version floor — ARCHITECT lane

Judge whether this slice is the right shape and composes correctly with the
merged SPEC-042 Layer 2 stack. Review the FULL slice diff as it will land.

Diff: `audits/2026-08-19/pool-binary-floor-fulldiff.patch`. Read changed files.
Spec: `specs/SPEC-042-pool-control-plane.md` (R004, R010, R005). Design:
`docs/design/spec-042-v0.1-slice-pool-binary-floor.md`.

## Context
This completes the R010 positive capability handshake end-to-end. The gateway
already verifies the coordinator advertises pool support (#1076); this adds the
provider half inside the coordinator (the gateway can't see the selected
provider). It reuses the provider's existing `binary_version` handshake rather
than adding a dedicated `pool_support_version` field (Option A). Deferred: a
dedicated capability field decoupled from binary version; the signed manifest
(R001) as the floor source; other R004 predicates (encrypted-leg, attestation).

## Focus (Critical/High/Medium/Low/Info + rationale)
1. Boundary: is enforcing the floor inside the coordinator's eligibility gate the
   right layer? Is keying "pool support" off `binary_version` a sound proxy for
   the R010 "provider advertises pool support at the required version", or does
   it conflate concerns in a way that will hurt later?
2. Floor home: per-pool `minBinaryVersion` in the trustpool snapshot (rather than
   a global option). Correct call for consistency with the generation fence and
   R004's per-pool model? Any drift risk?
3. Composition: does the new gate slot cleanly alongside the existing
   membership/model-floor/receipt-key gates without double-counting or reordering
   hazards? Is the envelope precedence (pool_binary_too_old vs
   pool_no_eligible_member vs model_version_floor) sensible?
4. Scope discipline: are the deferrals sound and fail-closed (each defaults to
   no-floor = inert, which is fail-OPEN for the binary dimension when a pool is
   operated without setting a floor)? Is "floor unset = inert" the right default,
   or should operating a pool require a floor? Flag if this is a trap for the
   enable path.
5. Default-off / byte-identical: any global-traffic or latency change; any
   abstraction that won't survive the manifest (R001) or a dedicated capability
   field later.

Rank by severity with rationale. Report 0 findings if architecturally sound.
