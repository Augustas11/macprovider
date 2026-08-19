# Codex audit — SPEC-042 gateway pool auth/emit slice — SECURITY lane

You are the security-review lane. This is a tenant-isolation authorization
change on a money/security path. The product promise is that a Trusted Pool is a
trust boundary: a buyer must not route into a pool it is not authorized for, and
the error surface must not leak private-pool existence. Review the FULL slice
diff as it will land.

Diff: `audits/2026-08-19/gateway-pool-auth-fulldiff.patch` (base `c70f97ce`).
Read changed files in the worktree. Normative spec: `specs/SPEC-042-pool-control-plane.md`
(R002 selection authorization; R010 error taxonomy, timing-oracle rule, and
positive capability negotiation). Design: `docs/design/spec-042-v0.1-slice-gateway-pool-auth.md`.

## Threat model to attack
- A buyer tries to route into a pool it is NOT authorized for (cross-tenant).
- A buyer probes error responses/latency to learn whether a private pool exists
  or is healthy (existence/timing oracle).
- A buyer tries to smuggle the internal authority header `X-MacProvider-Pool`
  (or spoof account/pool) directly to the gateway or through it to the
  coordinator.
- Version skew: a NEW gateway talking to an OLD coordinator that ignores
  `pool_id` and would route pool traffic from the global snapshot (spill).
- A misconfiguration or crafted value that makes the emitted header decode to
  empty at the coordinator (routed global = silent pool->global spill).

## Focus (Critical/High/Medium/Low/Info, file:line + concrete exploit)
1. Authorization completeness: is EVERY pool-selection path gated by the
   credential's authorized set? Can any input widen scope beyond the config
   ceiling (narrow-only invariant)? Account-vs-key granularity risk.
2. Non-disclosure: do unauthorized/unknown callers get exactly the generic
   `pool_unavailable` (same code, status, retryable) with no cause distinction?
   Does `pool_selection_invalid` ever confirm a pool exists?
3. Timing oracle: is the credential-scope check strictly before and independent
   of any coordinator existence/capability roundtrip, so an unauthorized caller's
   latency does not depend on pool existence? (SPEC-042-R010.)
4. Header trust: can a buyer's inbound headers reach the coordinator as authority
   metadata? Confirm the outbound `X-MacProvider-Pool` is set only by the gateway
   for an authenticated-account context and cannot be buyer-influenced except via
   the authorized selector value. Check the inbound selector header cannot be
   confused with the outbound one.
5. Capability handshake: is the fail-closed default correct when the coordinator
   omits/declines the advertisement, errors, or times out? Any path where a pool
   request proceeds without positive advertisement?
6. Spill guard: is the header-safe validation sufficient to prevent a
   pool->global downgrade via a sanitizer-dropped value, at both config-load and
   runtime?
7. Any secret/credential logged or retained; any PII in URLs/logs.

Give concrete exploit steps for any finding. Report 0 if genuinely clean.
