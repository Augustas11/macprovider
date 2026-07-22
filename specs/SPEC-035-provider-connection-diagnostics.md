# SPEC-035 — Provider connection diagnostics and failure history

Version: v0.1.0
Status: draft (Partial #535 coordinator journal + operator GET)
Owner: coordinator operator observability
Issue: https://github.com/Augustas11/macprovider/issues/535

## 1. Purpose and scope

Give operators a secure, remote, queryable view of provider connection health
and recent WebSocket auth/disconnect/warmup/liveness failures without exposing
provider secrets or providing remote shell access.

In scope for v0.1 (this Partial):

- Durable bounded `provider_connection_events` journal on the coordinator
  SQLite DB shared with request-log/admission state.
- Last-known non-secret provider snapshot for offline representation.
- Closed failure taxonomy and redaction rules.
- Operator-authenticated GET endpoints under `/admin/providers*`.
- Optional Prometheus counters with closed-set labels.

Out of scope (later Partials of #535):

- Provider-originated `diagnostic_status` over WSS and local schema unify.
- `pearlctl provider inspect` and alert rules.
- Separate HTTPS diagnostic beacon.
- Buyer/gateway exposure of diagnostics.
- Remote shell, arbitrary log/file fetch, or remote restart.

## 2. Dependencies and authority

Depends on SPEC-002 (coordinator WS lifecycle) and SPEC-003 (provider auth
admission). Owns authority domain `provider-connection-diagnostics`.

## 3. Normative requirements

**SPEC-035-R001 — Durable redacted connection events.** The coordinator MUST
persist provider connection lifecycle events to a bounded durable journal. Events
MUST include provider ID when known, timestamps, kind/outcome, normalized failure
reason, auth stage, first-message family when applicable, binary version when
known, and bounded redacted diagnostic/close fields. Implementations MUST NOT
persist raw tokens, Authorization headers, or raw protocol payloads.

**SPEC-035-R002 — Closed failure taxonomy.** Failure reasons MUST normalize to
the closed set: `invalid_token`, `invalid_auth_request`, `no_common_aead_suite`,
`tier2_attestation_failed`, `version_unsupported`, `warmup_failed`,
`heartbeat_stale`, `provider_websocket_disconnected`, `upgrade_failed`,
`unrecognized_auth_message`, `pool_full`, `other`.

**SPEC-035-R003 — Operator-only admin GETs.** The coordinator MUST expose
`GET /admin/providers`, `GET /admin/providers/{provider_id}`, and
`GET /admin/providers/{provider_id}/events` only to requests that pass the
existing human-operator bearer check. Missing/invalid operator credentials MUST
fail closed with `401`. These routes MUST NOT accept gateway service tokens and
MUST NOT be reachable on buyer/gateway public APIs.

**SPEC-035-R004 — Offline last-known representation.** A provider that is not
currently connected MUST be represented as `presence=offline` with its last-known
non-secret snapshot and recent failure events when available, not as an empty or
unknown record. Connected providers MUST surface live pool fields for version,
ID, model, readiness/state, auth state, and last-seen/heartbeat timestamps.

**SPEC-035-R005 — Retention bound.** The journal MUST prune events older than a
configured retention window (default 14 days) and MUST enforce a per-provider
row cap so unbounded reconnect storms cannot grow storage without bound.

## 4. Rollout

v0.1 ships coordinator-side only. Provider WSS diagnostic snapshots, CLI
inspect, alerts, and any HTTPS beacon remain deferred under #535.
