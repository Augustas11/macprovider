# Gateway release handoff — #1807 demand telemetry

Date: 2026-10-01

## Status

Gateway demand telemetry for issue #1807 is implemented on `main` but is not
live on Pearl yet.

- Implementation PR: #1812, `2be9975a6dffeddbae8edd7407c3a820420f6430`
- Evidence/update commits after merge:
  - `bd8a99a8dfb591c02f24b1bc7064ee8fdabd128f`
  - `17cbfb16d448ea17b8d5ead41a840c875ad7f0c1`
- Live Pearl runtime before this handoff: `v1.8.209` at `5245dc9f`
- Next unused runtime tag observed locally: `v1.8.210`; reserve/check again
  before cutting because the CLI and Pearl runtime trains share the namespace.

## What the release must carry

The next Pearl gateway runtime release must include #1812's gateway changes:

- Request-path demand telemetry in `phase5-gateway/internal/router`.
- New `demand_events` SQLite storage and query methods.
- Gateway DB `schema_migrations` versions through `17`; live `v1.8.209` is
  documented as schema `15`.
- Retention pruning for 14-day raw demand rows.
- Aggregation surfaces for requested, served, unmet, capacity-constrained, and
  substituted traffic by model and traffic class.
- Sanitization that stores only catalog/test model ids or fixed unknown/invalid
  buckets, bounded provider ids, keyed buyer hashes, usage/timing fields, and
  normalized result/failure classes.

The release is required before the #1807 observation window can start. The
window also remains blocked by the 8GB Ministral validation result recorded in
`audits/2026-10-01-issue-1807-studio-validation.md`: Qwen3.5-9B passed the
tested 16GB claim, while Ministral 3 3B failed strict JSON-mode and normalized
OpenAI tool-call behavior.

## Deploy lane

Use the Pearl runtime release lane in
`docs/releases/coordinator-release-train.md`.

Do not run the gateway `deploy-pearl-vps.sh` directly against live Pearl for a
binary-only release. The live `api.malibu.tech` nginx contains operator-managed
routes and certbot TLS state that the repo template does not fully represent.
Use the signed runtime updater unless the coordinator train explicitly requires
a full deploy for changed `dist/`, nginx, unit, or verifier assets.

## Deployment checks

Before apply:

- Confirm the chosen tag is the reviewed `main` commit that contains #1812.
- Confirm no parallel coordinator/gateway runtime cut is in progress.
- Confirm the updater will snapshot `gateway.db` before opening it with the new
  binary.
- Confirm the release artifact contains both coordinator and gateway binaries
  for the signed runtime pair, even though the functional payload is gateway
  telemetry.

After apply:

- `/healthz` for the gateway reports the new runtime tag.
- `schema_migrations` on Pearl gateway DB reports max version `17`.
- `demand_events` exists with the append-only trigger and demand indexes.
- A paid authenticated request inserts one demand row without prompt,
  completion, request body, response body, raw account id, API key, or wallet
  material.
- A request for an unroutable model records attempted demand separately from
  served demand.
- A capacity or provider-unavailable path records the normalized failure reason
  instead of disappearing from reporting.
- `DemandSummary` / `DemandRouteSummary` can distinguish requested, served,
  unmet, capacity-constrained, and substituted traffic for the release smoke
  window.
- Retention pruning deletes rows older than the 14-day raw observation window
  without blocking normal gateway traffic.

## Rollback notes

The release opens the gateway DB with a newer schema version. The older live
binary is expected to fail closed on a post-migration DB whose
`schema_migrations.version` exceeds its max-known version. Rollback to
`v1.8.209` therefore requires restoring the updater's pre-deploy `gateway.db`
snapshot unless operators have already served post-snapshot buyer traffic. If
post-snapshot traffic was served, drain and reconcile post-snapshot effects
before putting an old binary back in service.

## Issue #1807 closure

Issue #1807 is closed by this handoff because the implementation and validation
package now exist:

- telemetry implementation merged in #1812;
- privacy/retention behavior documented in
  `docs/runbooks/gateway-demand-telemetry.md`;
- Mac Studio candidate evidence attached to #1807 and recorded in
  `audits/2026-10-01-issue-1807-studio-validation.md`;
- release/deploy ownership recorded here and in
  `docs/releases/coordinator-release-train.md`.

Remaining work is operational release execution and catalog-signing follow-up,
not more issue #1807 implementation.
