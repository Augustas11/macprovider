# SPEC-035 — Provider connection diagnostics and failure history

Version: v0.2.0
Status: draft (Partial #535 coordinator journal + provider diagnostic snapshot)
Owner: coordinator operator observability
Issue: https://github.com/Augustas11/macprovider/issues/535

## 1. Purpose and scope

Give operators a secure, remote, queryable view of provider connection health
and recent WebSocket auth/disconnect/warmup/liveness failures without exposing
provider secrets or providing remote shell access.

In scope for v0.2 (this Partial):

- Durable bounded `provider_connection_events` journal on a dedicated
  coordinator SQLite file (sibling of the request-log DB) so journal
  maintenance never shares the money-path writer lock.
- Last-known non-secret provider snapshot for offline representation, including
  redacted model-loaded/model-hash and latest local connection failure summary.
- Closed failure taxonomy and redaction rules.
- Operator-authenticated GET endpoints under `/admin/providers*`.
- Optional Prometheus counters with closed-set labels.
- Anonymous/`_anonymous` bucket + global/per-provider caps, async enqueue,
  and periodic reconcile for reconnect storms.
- Provider local JSON status over loopback-only CLI inspection.
- Provider-originated `diagnostic_status` schema v1 over the already
  authenticated provider WebSocket.

Out of scope (later Partials of #535):

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
MUST include provider ID when known and identity-bound, timestamps, kind/outcome,
normalized failure reason, auth stage, first-message family when applicable,
binary version when known, and bounded redacted diagnostic/close fields.
Implementations MUST NOT persist raw tokens, Authorization headers, or raw
protocol payloads. Pre-identity failures MAY be attributed to the reserved
`_anonymous` bucket under rate and row caps. Identity-bound writes MUST NOT be
silently dropped on journal-queue overflow (synchronous fallback is permitted);
anonymous overflow MAY be sampled/dropped.

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
Transport presence MUST follow an active provider websocket session (or an
in-pool non-unavailable live admission). Disconnect-grace registry ghosts that
are `unavailable` without a session MUST report `presence=offline`.

**SPEC-035-R005 — Retention bound.** The journal MUST prune events older than a
configured retention window (default 14 days) and MUST enforce per-provider,
anonymous-bucket, and global row caps so unbounded reconnect storms cannot grow
storage without bound. Pre-identity failures MAY use the reserved
`_anonymous` provider_id bucket under the anonymous cap.

**SPEC-035-R006 — Provider local JSON diagnostic status.** The provider CLI MUST
expose a localhost-only JSON diagnostic status suitable for operator collection
without remote shell access. The local JSON MUST include provider ID, assigned
ID when known, binary version, model ID, model-loaded state, model/weights hash
metadata, coordinator connection state, request/error counters, and credential
presence booleans. It MUST NOT expose raw provider tokens, Authorization header
values, bootstrap-token material, or arbitrary local filesystem contents.

**SPEC-035-R007 — Authenticated WSS diagnostic snapshot.** After an
authenticated provider WebSocket session is accepted, the provider SHOULD send a
bounded `diagnostic_status` schema v1 frame and SHOULD refresh it after state
updates or reconnects when local failure state changes. The coordinator MUST
accept this frame only from an admitted provider session, MUST verify
`provider_id` and `assigned_id` match the active session, MUST reject oversized
payloads and malformed required fields, MUST preserve live pool routing/auth
truth over provider-supplied eligibility claims, and MUST store only redacted
operator-visible last-known data. The diagnostic snapshot MUST NOT become
buyer-visible and MUST NOT introduce a second credential or HTTPS beacon path.

## 4. Rollout

v0.2 ships coordinator-side journal/admin GETs plus provider `status --json` and
authenticated WSS `diagnostic_status` snapshots. CLI inspect wrappers, alerts,
and any HTTPS beacon remain deferred under #535.
