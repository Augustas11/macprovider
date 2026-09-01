# SPEC-035 — Provider connection diagnostics and failure history

Version: v0.4.2
Status: draft (Partial #535 coordinator journal + provider diagnostic snapshot + monitor alerts + admission-ceiling drift diagnostics; #1267 operator onboarding funnel join; #1314 local diagnostic signature schema)
Owner: coordinator operator observability
Issue: https://github.com/Augustas11/macprovider/issues/535

Changelog:

- v0.4.1 (2026-08-31): adds the operator onboarding funnel join for
  [#1267](https://github.com/Augustas11/macprovider/issues/1267). `GET /admin/onboarding`
  and `coordinator-cli list-onboarding` project exclusive pending / confirmed /
  live / failed_expired / failed_revoked states from referral redemptions,
  bootstrap identities, last-known/events, and live pool presence. Redeemed is
  not a success marker. Invite codes, code digests, tokens, and receipt keys
  MUST NOT appear in the projection. The admin GET is page-capped with a
  `next_after` / `next_after_ts` cursor. After bootstrap-identity collection,
  a leftover redemption still projects as `failed_expired` with its redemption
  timestamp; expiry MAY be omitted.
- v0.4.2 (2026-09-01): adds the closed local diagnostic `signature_id`
  taxonomy, source precedence, and redacted diagnostics bundle v2 contract for
  [#1314](https://github.com/Augustas11/macprovider/issues/1314).

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
- Pearl-side monitor alerting over the existing operator-authenticated
  coordinator admin endpoints.
- Coordinator-observed proof-of-weights admission-ceiling drift diagnostics on
  heartbeat model changes.
- Operator onboarding funnel join (`GET /admin/onboarding` and
  `coordinator-cli list-onboarding`) that distinguishes pending, confirmed,
  live, expired-unconfirmed, and revoked attempts without treating redemption
  as a successful join.

Out of scope (later Partials of #535):

- `pearlctl provider inspect`; prebeta operations MAY use Pearl DB/admin
  endpoint inspection directly for the small cohort.
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
`GET /admin/providers`, `GET /admin/providers/{provider_id}`,
`GET /admin/providers/{provider_id}/events`, and `GET /admin/onboarding`
only to requests that pass the existing human-operator bearer check.
Missing/invalid operator credentials MUST fail closed with `401`. These
routes MUST NOT accept gateway service tokens and MUST NOT be reachable on
buyer/gateway public APIs. `GET /admin/onboarding` MUST join referral
redemptions, bootstrap identities, last-known/events, and live pool presence
into exclusive operator states `pending`, `confirmed`, `live`,
`failed_expired`, and `failed_revoked`. A redeemed-but-unconfirmed identity
that has passed bootstrap token expiry MUST surface as `failed_expired` with
its redemption timestamp and, while the bootstrap identity row remains, its
expiry timestamp. After identity collection removes the bootstrap row, the
redemption MUST still appear as `failed_expired` with the redemption
timestamp; expiry MAY be omitted because it is no longer durably present.
The list MUST be page-capped and MUST emit a stable cursor (`next_after`,
`next_after_ts`) when more matching rows remain. The projection MUST NOT
include invite codes, code digests, provider tokens, or receipt public keys.
The Pearl-local `coordinator-cli list-onboarding` command is the offline
sibling of this GET and MUST apply the same exclusive states and redaction
rules, except that `live` requires an in-process connected session and
therefore remains `confirmed` on the CLI unless a later operator HTTP overlay
supplies presence.

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

**SPEC-035-R008 — Pearl monitor diagnostic alerts.** Pearl-side alerting SHOULD
consume the existing operator-authenticated `/admin/providers*` endpoints rather
than querying the coordinator SQLite journal directly. Alert rules MUST be
bounded by configurable event limits and recent time windows, MUST deduplicate
provider-scoped alerts against the latest event cursor that contributes to each
alert condition, MUST deduplicate remotely-triggerable `_anonymous` alerts by
active episode, and MUST avoid paging on ordinary small-cohort sleep/offline
behavior. High-signal diagnostic alerts SHOULD cover repeated `invalid_token`,
`invalid_auth_request`, `warmup_failed`, `heartbeat_stale`,
reconnect/liveness failures, pre-identity failures in the capped `_anonymous`
bucket, any `version_unsupported`, and optionally configured expected-provider
missing-auth windows. Alerts MUST NOT expose raw tokens, Authorization values,
raw protocol payloads, local paths, or provider diagnostics to buyer/gateway
APIs.

**SPEC-035-R009 — Admission-ceiling drift diagnostics.** When a live provider
heartbeat changes `model_id`, the coordinator SHOULD compare the new model's
signed catalog `min_ram_gb` against the provider session's observed
proof-of-weights admission cap when both values are available. If the session has
no observed admission cap, the coordinator MUST emit a bounded redacted
operator-visible event with kind `missing_admission_cap`. If the new catalogued
model exceeds the observed cap, the coordinator MUST emit a bounded redacted
operator-visible event with kind `model_ceiling_drift`. These diagnostics MUST
be coalesced or rate-limited per provider and event kind so a compromised
provider cannot create an unbounded durable-event or warning-log stream by
toggling model IDs or reconnecting. These diagnostics MUST NOT evict, exclude,
degrade, or otherwise alter buyer routing by themselves; they are observe-only
operator signals. A separate strict-gate route predicate specified by SPEC-032
MAY act on the same heartbeat; that predicate is not authority granted by this
diagnostic event. They MUST NOT expose raw protocol payloads, tokens,
Authorization values, local paths, or buyer-visible diagnostics.

**SPEC-035-R010 — Closed local diagnostic signature taxonomy.** Malibu local
diagnostic reports MUST use the closed `signature_id` set below. Unknown
`signature_id` values MUST be ignored by readers whose supported reader version
is at least the report `minimum_reader_version`; they MUST NOT make the whole
report unreadable.

| `signature_id` | Owned source/predicate |
| --- | --- |
| `stale_launch_agent` | `ProviderLogDiagnostics` log line `provider process unhealthy: launchd service live.malibu.provider has no validated pid at` plus current launchd repair state. |
| `stale_model_catalog` | `ProviderLogDiagnostics` log line `model catalog provenance envelope is stale`. |
| `catalog_admission` | `ProviderLogDiagnostics` log line `model artifact is not admitted by the signed candidate catalog`. |
| `rate_card_admission` | `ProviderLogDiagnostics` log line `model artifact is not admitted by the signed rate card`. |
| `catalog_key_mismatch` | `ProviderLogDiagnostics` log line `model must match model_catalog_key`. |
| `artifact_hash_mismatch` | `ProviderLogDiagnostics` log line `model artifact hash mismatch`. |
| `artifact_verification_failed` | `ProviderLogDiagnostics` log line `model artifact verification failed`. |
| `missing_catalog_provenance` | `ProviderLogDiagnostics` log line `model_artifact_sha256 requires model_catalog_* provenance`. |
| `missing_artifact_sha` | `ProviderLogDiagnostics` log line `coordinator join requires model_artifact_sha256`. |
| `snapshot_path_mismatch` | `ProviderLogDiagnostics` log line `model must be the catalog-pinned hugging face snapshot path`. |
| `autoupdate_home_acl_rejected` | `ProviderLogDiagnostics` watchdog line `autoupdate recovery_error=acl_write_rejected:<home>` without a later handled marker. |
| `credential_store_unavailable` | Fresh, contract-compatible `/v1/status` `credential.state` in `locked`, `not_logged_in`, `permission_denied`, `keychain_failure`, `incompatible`, or `unavailable`. |
| `serve_unresponsive` | Missing, stale, or contract-incompatible `/v1/status`; or fresh `/v1/status` `network_state` in `not_buyer_serving`, `buyer_serving_unknown`, `network_offline`, or `coordinator_unavailable`; or slice-2 `doctor report` serve-dead evidence when `/v1/status` is not fresh. |
| `admission_identity_blocked` | Fresh, contract-compatible `/v1/status` `admission_identity.state` in `missing`, `recovery_pending`, `degraded_previous_key`, or `recovery_required`. |
| `autoupdate_in_progress` | Fresh, contract-compatible `/v1/status` `lifecycle.state` in `update_in_progress` or `rollback_in_progress`, or the Malibu-local update/repair in-progress flags. |
| `autoupdate_disabled` | Config/log evidence from the canonical key `auto_update_enabled` or dotted status key `autoupdate.enabled` showing `false`; legacy `autoupdate_enabled` MUST NOT be emitted as the canonical key. |

Coordinator-only `waiting_trust_429` and `benchmark_quarantined` evidence is
outside the local signature catalog unless a later SPEC names a local verified
emitter.

**SPEC-035-R011 — Diagnostic finding precedence.** Local diagnostic aggregators
MUST return every closed finding, ordered by source precedence. A fresh,
contract-compatible `/v1/status` observation wins the fields owned by serve
status: credential, lifecycle, model, admission identity, and network. Log
findings MAY supplement but MUST NOT override a fresh status-owned field. A
doctor report MAY contribute only `serve_unresponsive`, and only when
`/v1/status` is unavailable, stale according to `observation.valid_for_ms`, or
contract-incompatible. A subprocess `credentials status` result MUST NOT
override a fresh serve-owned `credential.state`; it MAY contribute only when
fresh status is absent or lacks credential state.

**SPEC-035-R012 — Diagnostics bundle v2 allowlist and redaction.** Malibu
diagnostic bundles MUST be allowlist-only and MUST NOT copy config files,
Keychain values, environment variables, raw coordinator frames, provider tokens,
Authorization values, bootstrap-token material, private keys, or arbitrary local
filesystem contents. Bundle v2 MUST include `schema_version: 2`,
`minimum_reader_version`, redacted `diagnostic_findings`, and bounded redacted
provider/watchdog log tails. `LogTailBuffer` v2 redaction MUST scrub secret
lines, absolute paths, usernames, hostnames, IP addresses, and C0/C1 control
characters. Redaction is a no-secrets/no-private-path guarantee; it is not an
anonymity guarantee.

## 4. Rollout

v0.4 ships coordinator-side journal/admin GETs, provider `status --json`,
authenticated WSS `diagnostic_status` snapshots, Pearl monitor diagnostic
alerts, and coordinator observe-only admission-ceiling drift events. v0.4.1
adds the operator onboarding funnel join (`GET /admin/onboarding` and
`coordinator-cli list-onboarding`). v0.4.2 adds the local diagnostic signature
schema and redacted bundle v2. CLI inspect wrappers and any HTTPS beacon remain
deferred under #535.
