# Codex audit — SPEC-042 gateway pool auth/emit slice — CODE lane

You are the code-review lane auditing a money-path/security change to the
MacProvider gateway (phase5-gateway, Go) plus one small coordinator change
(phase4-coordinator). Review the FULL diff of the slice as it will land.

Diff: `audits/2026-08-19/gateway-pool-auth-fulldiff.patch` (base commit
`c70f97ce`, which already contains the coordinator-side pool routing/isolation).
Read the changed source files in the worktree for full context; the design is in
`docs/design/spec-042-v0.1-slice-gateway-pool-auth.md` and the normative spec is
`specs/SPEC-042-pool-control-plane.md` (esp. R002 and R010).

## What the slice does
The gateway authorizes a buyer credential to select a SPEC-042 Trusted Pool and,
only for an authorized + capability-satisfied selection, emits the outbound
`X-MacProvider-Pool: <pool_id>` header the coordinator honors. Poolless and
feature-off traffic must be byte-identical (no header emitted).

Key sites:
- `phase5-gateway/internal/router/pool_selection.go` — `resolvePoolSelection`
  decision table + error sentinels + header constants.
- `phase5-gateway/internal/router/chat_proxy.go` — resolution call placement
  (after parse, before quota reservation) + emit in `buildUpReq`.
- `phase5-gateway/internal/config/config.go` — `TrustedPoolsConfig`, `Authorizes`,
  `validateTrustedPoolsConfig`, `PoolIDHeaderSafe`.
- `phase5-gateway/internal/router/disclosure.go` — `Pools` capability field.
- `phase5-gateway/internal/router/server.go` — error-code registration.
- `phase4-coordinator/internal/buyer/server.go` — `/internal/routing` advertises
  `pools.enabled` gated on `trustPools != nil`.

## Focus (report Critical/High/Medium/Low/Info with file:line and a concrete failing scenario)
1. Correctness of the decision table: any input (body `pool`, header
   `X-MacProvider-Pool-Select`, feature flag, authorized set, capability) that
   yields a WRONG outcome — a pool emitted when it should not be, or a request
   dropped to global when a pool was named (silent pool->global is forbidden).
2. Ordering bugs: is authorization truly before quota reservation and before any
   coordinator capability roundtrip? Is the emit guarded by both an authorized
   selection AND the authenticated-account condition?
3. The emit value round-trips the coordinator's opaque header sanitizer — any
   value that would be dropped to empty (routed global) that is not rejected.
4. Error taxonomy: codes/status/retryability match the SPEC R010 table; both new
   codes are registered so the AST completeness guard passes; no code leaks pool
   existence.
5. Any resource leak, nil deref, unhandled error, concurrency issue, or context
   misuse introduced. Retry/failover interaction with the emitted header.
6. Test quality: do the tests actually prove non-dispatch on fail-closed paths
   and byte-identical global, or do they pass vacuously?

Be adversarial and concrete. If you assert a defect, give the exact input and
the wrong result. Rank by severity. Report 0 findings if the slice is clean.
