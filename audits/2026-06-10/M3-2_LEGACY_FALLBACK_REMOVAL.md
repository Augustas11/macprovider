# M3-2: legacy OperatorKey fallback removal (post-cutover)

**Status (2026-06-26):** REMOVED in PR #87 item 3 (branch
`fix/m3-2-legacy-fallback-removal-v2`, prepared 2026-06-26, merge
target 2026-07-12 per the 30-day clean-cutover gate). The
gateway_service_token is now the SOLE accepted credential on
`/internal/routing` and `/internal/sticky`; the gateway's
`UpstreamCoordinatorBearer()` returns ServiceToken directly (no
fallback) and `Validate()` requires it non-empty. Audit-log shape
preserved (`event=internal_bearer_accepted key=service_token`).

What follows below is the pre-removal tracker — kept for historical
reference; sections about the bridge being "current state" no longer
apply.

---

Tracked removal task for the dual-credential bridge added in PR #73
(M3-2 / SECU-4) and scoped down by its codex security audit fixup
(HIGH-1, HIGH-2, MED, LOW).

## Current state (post-PR-73-fixup)

Two bearer-token classes flow through the coordinator:

- `operator_key` — human-admin. Accepted by `/admin/blacklist`,
  `/admin/promote`, `/admin/reject`, `/admin/provisional`, `/poolz`,
  `/admin/ledger/*`, `/admin/explorer/*`. The `gateway_service_token`
  is intentionally NOT accepted here (codex HIGH-1 fix scoped the
  bridge to gateway-internal paths only).
- `gateway_service_token` — service-to-service. Accepted by
  `/internal/routing` and `/internal/sticky` (the only upstream paths
  the gateway calls today). The legacy `operator_key` is ALSO accepted
  here as a backward-compat fallback so the operator can roll out the
  cutover without an atomic flip.

The audit-log line on every accepted internal-bearer hit is:

```
event=internal_bearer_accepted key=<operator_key|service_token> path=<url> remote_addr=<host>
```

The operator watches journald with:

```
journalctl -u macprovider-coordinator -f | grep internal_bearer_accepted
```

## Trigger to remove the legacy fallback

The `operator_key` fallback on `/internal/*` is what lets a
not-yet-upgraded gateway keep working with a coordinator that already
holds both credentials. Once cutover is complete the fallback is dead
code that widens the attack surface.

REMOVE the fallback in a dedicated PR when ALL of these are true:

1. Every gateway in the fleet is rolled out with
   `coordinator.service_token` populated (env-resolved, fail-closed per
   PR #73 MED fix).
2. The operator has rotated `auth.operator_key` to a fresh value the
   gateway does NOT know.
3. For **30 consecutive days** after the rotation, the live coordinator
   audit log shows ZERO `key=operator_key` events from gateway origins.
   "Gateway origin" is established by `remote_addr` matching the
   internal gateway IP/CIDR.
4. The 30-day window has been logged in `beta/DECISION_CRITERIA.md` as
   a new entry citing this file by name.

## Removal scope

When the gate above is met, the dedicated removal PR should:

- `phase5-gateway/internal/config/config.go` — drop the
  `OperatorKey` branch from `UpstreamCoordinatorBearer()`. After that,
  `Validate()` should reject a config with an empty `ServiceToken`.
- `phase4-coordinator/internal/buyer/server.go` — drop the
  `gatewayServiceToken` parameter from `internalBearerAuthorizedFull`
  and call `auth.BearerTokenMatchesHeader` directly against
  `gatewayServiceToken`. `OperatorKey` is no longer consulted on
  `/internal/*` paths.
- `phase4-coordinator/internal/auth/tokens.go` —
  `GatewayInternalBearerMatches` becomes a thin wrapper around
  `BearerTokenMatchesHeader`. Keep the `InternalBearerKind` type so
  the audit-log shape is stable.
- Remove the bridge tests that pin `operator_key` acceptance on
  `/internal/*` (`phase4-coordinator/internal/buyer/server_bridge_test.go`).
- Append a new entry to `OPS.md` documenting the post-removal
  invariant: gateway calls without a valid `service_token` are 401.

## Why we cannot remove this now

The codex architect-review noted: pre-fixup the cutover procedure was
documented but had no enforced exit condition. A bare `// TODO:
remove the fallback` comment is not a tracking mechanism. This file is
the tracking mechanism. The reciprocal `TODO(m3-2-cleanup)` comments
in:

- `phase5-gateway/internal/config/config.go` (near
  `UpstreamCoordinatorBearer`)
- `phase4-coordinator/internal/ws/server.go` (above
  `authorizedOperator`, pointing at the buyer-side bridge)
- `phase4-coordinator/internal/buyer/server.go` (above
  `internalBearerAuthorized`)

are entry points back to this file so future code reviewers cannot
silently land the removal before the 30-day gate is met.

## Cross-references

- Codex review (PR #73, 2026-06-12): identified inverted token scope
  (HIGH-1), monitor sandbox gap (HIGH-2), short-circuit timing oracle
  (MED), gateway env: silent-empty fallback (MED), stale OPS.md prose
  (architect).
- PR #73 itself (M3-2 Parts A/B/C) — the original split.
- M1-1 `provider_token` plumbing (PR #41) — sibling bearer class for
  per-provider creds; separate auth path.
