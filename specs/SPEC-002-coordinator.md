# SPEC-002 — Phase 4 Coordinator: Mac Provider Request Router

**Version:** 1.1.5 (2026-05-29, audit response, public-pool production invariants)
**Depends on:** SPEC-001 v1.2.4 (Phase 3 binary wire protocol, locked)

**Change log v1.1.5:**
- Adds normative production gates (§ 7.7 PG-1 through PG-5) for the transition from Tier 1 cooperative-trust deployment to public-buyer launch (H-002 from the 2026-05-29 independent security audit). nginx routing block expanded with pre-WS-upgrade rate-limit and connection-cap directives. Audit category I.2 added for the "default-permissive flag in production deployment" anti-pattern. No code change required. Current Tier 1 deployment configuration remains valid; the patch documents the gate, not the migration timing.

**Change log v1.1.4:**
- Closes F-602-1 through F-602-6 from `specs/SPEC-CROSS-006-audit.md`: X-Request-ID correlation, public coordinator-owned `GET /v1/pool/check`, nginx route split, per-model `degraded`, `/poolz` gateway summary fields, SPEC-001 v1.2.4 dependency, and SPEC-006 gateway buyer-port rebind notes.

**Change log v1.1.3:**
- § 7.1 / FR-P12: added `auth.require_provider_tokens` provider-authentication mode. Default `false` preserves the v1.1.2 cooperative pinned-provider trust pool; `true` requires pinned providers to present a valid bearer token and rejects missing or invalid tokens with WS close 4005 `invalid_token`.
- § 6 / § 7.1 close-code semantics: coordinator-initiated provider WebSocket closes MUST be logged at WARN level with close code and reason so production rejections are observable in coordinator logs.
- § 11 audit category I: added the "always-non-nil gate" anti-pattern from Decision log Entry 19 so future audits check both configured and unconfigured branches for production gates.

**Change log v1.1.2:**
- § 7.1 FR-P2: validation wording changed from "validates all fields" to "validates all REQUIRED fields"; absent `endpoint_url` normalized to null before § 3 mode resolution (CRITICAL-2.1 fix).
- § 5 routing pseudocode: replaced undefined `all_filtered_by_quota` with explicit `quota_blocked_candidates` list for 429 vs 503 disambiguation (MAJOR-2.1 fix).
- `**Depends on:**` line corrected to SPEC-001 v1.2.1 (MINOR-2.1 fix).

**Change log v1.1 (absorbs SPEC-003 v0.1 Part B — dynamic admission + WS-tunneled relay):**
- § 3 Request forwarding model: added two-path mode resolution. HTTP-forwarding (legacy, for providers with `endpoint_url` via hello or config) and WS-tunneled (new default, for providers without `endpoint_url`). Mode determined at registration time.
- § 4 FR-P14 through FR-P21: new FRs for WS-tunneled inference relay, admission tiers, provisional rate limits.
- § 5 Routing algorithm: added admission-tier weight multiplier (pinned 1.0, provisional 0.3 configurable). Applied to `effective_throughput`.
- § 5 model_id matching: amended from exact string equality to case-insensitive comparison (D9 fix).
- § 7.1 Close codes: added 4007 `provisional_pool_full`, 4008 `provisional_rate_limited`, 4009 `banned`. Close code 4002 `unknown_provider_id` retired for v1.1+ coordinators.
- § 7.1 F-2 amendment: relaxed from "every provider_id must be in config.providers[]" to three-tier admission (pinned / provisional / rejected).
- § 7.5 (new): Admission state and operator endpoints — `GET /admin/provisional`, `POST /admin/promote/{provider_id}`, `POST /admin/reject/{provider_id}`.
- § 10 D7-D10: four new findings from Phase 4 deploy.
- § 11 AC-11 through AC-14: admission tier acceptance criteria.
- § 12 OQ-6 through OQ-10: redistributed open questions.
- No change to buyer-facing HTTP API (§ 7.2). POST /v1/chat/completions, GET /v1/models, GET /healthz are unchanged in observable behavior.

**Change log v1.1.1:**
- § 3 mode resolution: provisional providers with self-reported endpoint_url are forced to WS-tunneled mode (Q1 operator decision — anti-abuse).
- § 5 routing pseudocode: case-insensitive model_id comparison via `model_id_equal()` helper (M2 fix); provisional request quota integrated into routing paths (M1 fix).
- § 7.1 wire schemas: hello and hello_ack JSON examples updated to match SPEC-001 v1.2.1 § 6.5 (C1 fix); provider_id example corrected to stable operator-issued ID.
- § 7.1: special-case nak handling for § 6.6 routing-mode fallback (M5 fix).
- FR-P14: restored status-to-buyer-HTTP mapping table from SPEC-003 v0.1 FR-A8 (C2 fix).
- § 6.6 request_id lifecycle: unknown/duplicate/cleanup rules added (C3 fix, cross-ref to SPEC-001 v1.2.1 § 6.6).
- OQ-6, OQ-8, OQ-9: restored full rationale paragraphs (M6 fix).
- OQ-10: scoped to coordinator-side buffer only, distinct from SPEC-001 OQ-5 (M3 fix).
- AC-15: coordinator marks provider http_forwarding_only after § 6.6 nak (M5 fix).

**Change log since v1.0.3:**
- § 5 Tie-breaking: added "Operator-visible behavior" note on order-sticky routing under equal metrics (Finding F-1).
- § 7.4 Operator endpoints: explicit port placement — `/admin/*` and `/poolz` live on `provider_port` (default 8444), not `buyer_port` (Finding F-3).
- § 10 added D6 (Phase 4 local acceptance findings F-1, F-2, F-3).
- No FR changes; no normative-behavior changes. v1.0.4 is documentation-only — the implementation already exhibits these behaviors and the corresponding SPEC-002 prose now matches operator-visible reality.

---

## 0. Operator-paste invocation block

```
Implement SPEC-002. As you work, maintain a running
phase4-coordinator/implementation-notes.html that captures anything
I should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

The Phase 4 coordinator is a Go service that runs on a VPS and turns a
pool of Phase 3 Mac Provider binaries into a single OpenAI-compatible
inference endpoint for buyers. It accepts inbound WebSocket connections
from provider binaries (speaking the SPEC-001 section 6.5 protocol), maintains a
live registry of available providers with their advertised capacity and
health state, exposes an HTTPS API that accepts standard OpenAI chat
completion requests from buyers, and routes each request to the
best-matching provider in the pool based on model, capacity, and buyer
preference. It is the single point of contact for Antseed seller
integration (SPEC-003, out of scope) and the future public buyer API
(SPEC-006, out of scope). The coordinator does not perform inference
itself — it is a stateful reverse proxy with provider-aware routing
intelligence.

---

## 2. Scope

### In Tier 1 launch scope (build now)

- Go binary targeting Linux amd64 (VPS deployment)
- WebSocket server on `/ws/provider` accepting inbound connections from
  Phase 3 binaries
- Full implementation of the coordinator side of SPEC-001 section 6.5 wire
  protocol (hello/hello_ack, heartbeat, state_update, drain_status,
  preflight/preflight_ack, drain, warm_up, nak)
- Provider pool registry with live capacity tracking
- Provider state machine (ready, busy, degraded, draining, unavailable)
- Provider auth: offline token issuance via CLI, bearer token validation
  on WebSocket hello, token revocation, hashed storage in SQLite
- Buyer HTTP API: `/v1/models`, `/v1/chat/completions` (streaming and
  non-streaming), wire-compatible with SPEC-001 section 6.2
- Routing algorithm: model match, capacity check, buyer preference
  headers (`X-MacProvider-Pref`, `X-MacProvider-Provider`)
- Preflight check against chosen provider before forwarding
  context-heavy requests
- SSE streaming pass-through from provider to buyer
- Clean error responses (503 no provider, 502 provider failure, 504
  provider timeout)
- Request logging to SQLite: timestamp, model, tokens, provider,
  latency, status
- Operator endpoints: `/healthz`, `/poolz` (auth-gated), `/admin/blacklist`
- Graceful SIGTERM drain of in-flight buyer requests
- SQLite persistence for provider auth, request log, pool state
- Structured JSON logging to stdout
- Coordinator CLI: `coordinator-cli issue-token`, `coordinator-cli
  revoke-token`, `coordinator-cli list-tokens`

### In Tier 2 roadmap scope (designed-in but not implemented)

- `AttestationVerifier`: validate hardware attestation blob from
  provider hello (Tier 2 providers send `attestation` field)
- `BuyerEncryptionRelay`: forward buyer-encrypted payloads to Tier 2
  providers without coordinator decryption
- `TrustChainAuditor`: log attestation chain
  (buyer -> coordinator -> provider) for compliance
- Buyer-side API authentication and per-buyer rate limiting
- Multi-coordinator HA with leader election

Each of these is a named interface in the Go codebase with a Tier 1
no-op implementation. The request and routing pipelines have explicit
insertion points for each. See Section 3 for hook-point locations.

### Out of scope

- Smart router with sticky single-tenant caching (SPEC-004)
- Public direct buyer API with auth/billing (SPEC-006)
- Contributor reward distribution (SPEC-005)
- Antseed seller integration code (SPEC-003; the coordinator's buyer
  HTTP API is wire-compatible with what SPEC-003 will need)
- Buyer-side privacy stack (Tier 2)
- TLS termination (deployment concern; Caddy or nginx in front)
- Multi-model-per-provider support (SPEC-001 is single model per binary)
- Automatic scaling or auto-restart of provider binaries

---

## 3. Architecture overview

```
                          BUYERS (HTTPS)
                              |
                     TLS termination (Caddy)
                              |
    +----------------------------------------------------------+
    |                  COORDINATOR (Go)                         |
    |                                                          |
    |   BUYER SIDE                    PROVIDER SIDE            |
    |   ----------                    -------------            |
    |   Buyer HTTP Server (:8443)     Provider WS Server(:8444)|
    |         |                              |                 |
    |   Request Validator             Auth Validator (bearer)  |
    |   (SPEC-001 s6.2)                     |                  |
    |         |                       Hello Handler            |
    |         |                              |                  |
    |         |                       [AttestationVerifier]     |
    |         |                        TIER 2 HOOK              |
    |         |                              |                  |
    |         +------> Pool Registry <-------+                 |
    |         |        (provider_id -> state, model, capacity) |
    |         |              ^                                  |
    |   [BuyerEncryption     |  Heartbeat Processor            |
    |    Relay] TIER 2       |  State Machine                  |
    |         |              |  Wake Detector (gap >120s)      |
    |         v              |                                  |
    |   Router (model match, capacity, buyer pref)             |
    |         |                                                |
    |   Preflight Checker (WS preflight/preflight_ack)         |
    |         |                                                |
    |   Request Forwarder (HTTP to provider endpoint)          |
    |         |                                                |
    |   [TrustChainAuditor] TIER 2 HOOK                        |
    |         |                                                |
    |   Response Relay        Request Logger (SQLite)           |
    |   (SSE passthrough)                                      |
    |                                                          |
    |   Operator: /healthz  /poolz  /admin/blacklist           |
    |   Storage:  SQLite (WAL) — tokens, request_log, snapshots|
    +----------------------------------------------------------+
              ^                    ^
              |                    |
         WebSocket            WebSocket
         (outbound)           (outbound)
              |                    |
           Mac #1              Mac #2
         (M1 8GB)            (M4 16GB)
```

### Request forwarding model (v1.1 — two paths)

The coordinator supports two inference forwarding paths, selected
per-provider at registration time:

**Path A — HTTP-forwarding (legacy).** The coordinator sends the buyer's
request as a standard HTTP POST to the provider's reachable endpoint
(Cloudflare tunnel URL or direct IP). The WebSocket carries control
plane only (registration, heartbeats, state, preflight, commands).
This is the v1.0.x behavior, preserved for pinned providers with
operator-managed tunnels.

**Path B — WS-tunneled (v1.1 default for new providers).** The
coordinator sends the buyer's request as an `inference_request` message
over the provider's existing WebSocket (SPEC-001 v1.2 § 6.6). The
provider returns response chunks over the same WebSocket. No inbound
network required — provider needs only outbound WSS to the
coordinator. Works behind any NAT, firewall, or hotspot.

#### Mode resolution (normative)

The coordinator determines the forwarding mode at provider registration
time (on `hello`) using the following resolution:

```
if provider_id in config.providers[]:
    tier = pinned
    if hello.endpoint_url is present and non-empty:
        inference_path = HTTP_FORWARDING(hello.endpoint_url)
    elif config.providers[provider_id].endpoint_url is present:
        inference_path = HTTP_FORWARDING(config.providers[provider_id].endpoint_url)
    else:
        inference_path = WS_TUNNELED
else:
    tier = provisional  (subject to admission rate limits, FR-P16)
    if hello.endpoint_url is present and non-empty:
        # Q1 OPERATOR DECISION (v1.1.1): Provisional providers operate
        # EXCLUSIVELY in WS-tunneled mode. Self-reported endpoint_url
        # from unknown provider_ids is IGNORED to prevent abuse (a Sybil
        # attacker could register N provisional providers each pointing
        # endpoint_url at a target server to amplify traffic via the
        # coordinator). The coordinator logs at warn level:
        # "provisional provider <id> sent endpoint_url <url>; ignored,
        # forcing WS-tunneled mode."
        inference_path = WS_TUNNELED
    else:
        inference_path = WS_TUNNELED
```

**`endpoint_url` in hello (SPEC-001 v1.2 § 6.5).** The `hello`
message gains an OPTIONAL `endpoint_url` field. Existing v1.1.x
binaries do not send it; the coordinator treats absence as null and
falls back to the static `config.providers[]` map. Net: zero binary
changes required for existing providers.

**Endpoint discovery (v1.1 resolution, supersedes v1.0.x).** The
static `config.providers[]` map remains the mechanism for pinned-tier
admission and endpoint_url fallback. It is no longer the sole admission
mechanism — see § 7.5 for provisional admission.

### Tier 2 hook points summary

| Hook point | Location | Tier 1 behavior | Tier 2 behavior |
|---|---|---|---|
| `AttestationVerifier` | After hello parse, before pool registration | Skip (accept any Tier 1 provider) | Validate hardware attestation blob |
| `BuyerEncryptionRelay` | After router selects provider, before forwarding | Passthrough (plaintext request) | Forward encrypted payload without decryption |
| `TrustChainAuditor` | After response received from provider | No-op | Log full attestation chain for buyer verification |

Each hook point is a Go interface with a Tier 1 no-op struct
implementation. Tier 2 adds alternative implementations without
modifying the request pipeline.

---

## 4. Functional requirements

### Provider-side (matching SPEC-001 section 6.5)

**FR-P1. Accept WebSocket from provider.**
The coordinator listens on a configurable port (default: 8444) at path
`/ws/provider` for inbound WebSocket connections from Phase 3 binaries.

**Provider auth in v1: optional.** SPEC-001 v1.1.1 does not require
binaries to send credentials on WebSocket upgrade, and v1's trust model
comes from the operator's static `provider_id → endpoint_url` map (only
known providers can map to a forwarding URL anyway). The coordinator
therefore accepts the WebSocket upgrade with or without an
`Authorization` header in v1. After upgrade, it awaits the `hello`
message; trust is enforced by `provider_id` lookup in FR-P12.

When `auth.require_provider_tokens=true`, pinned providers must present
a valid `Authorization: Bearer <token>` header; missing, malformed,
invalid, or revoked tokens close the WebSocket with 4005
`invalid_token` (FR-P12). When the flag is false, bearer tokens are not
required for pinned providers.

Authenticated buyer-API and operator endpoints (sections 7.2, 7.4) still
require their own auth headers; this exemption is provider-side WebSocket
only.

**FR-P2. Validate hello message; respond hello_ack.**
On receiving a `hello` message (SPEC-001 section 6.5), the coordinator:
1. Validates that all REQUIRED fields are present and correctly typed:
   `type`, `version`, `tier`, `provider_id`, `hostname`, `model_id`,
   `model_params_b`, `ram_gb`, `max_context_tokens`, `max_concurrency`,
   `throughput_tps_estimate`, `binary_version`.
   OPTIONAL fields (`attestation`, `endpoint_url`) are validated when
   present. Absent `endpoint_url` MUST be normalized to null before
   passing to § 3 mode resolution; this preserves backward compatibility
   with v1.1.x binaries that do not include the field.
2. Checks `version` is 1 (the only supported protocol version).
3. Checks `tier` is 1 (FR-P13 rejects Tier 2 in v1).
4. Checks `provider_id` is not already registered in the active pool
   (duplicate ID = stale connection; close the older one).
5. Registers the provider in the pool with state `ready`.
6. Responds with `hello_ack`:
   ```json
   {
     "type": "hello_ack",
     "coordinator_version": 1,
     "assigned_id": "<pool-scoped-id>",
     "heartbeat_interval_s": 30
   }
   ```
   The `assigned_id` is a coordinator-assigned identifier (UUID) for
   this provider's pool session. It may differ from `provider_id` (which
   is the binary's self-assigned ID). The `heartbeat_interval_s` is
   configurable (default: 30 seconds).

If any validation fails, the coordinator closes the WebSocket using a
standard application close code with a human-readable reason. SPEC-001
§ 6.5 defines `nak` as provider-to-coordinator only; the coordinator
does not send a wire-level `nak` to the provider. See "Provider
rejection via WebSocket close codes" later in this section for the full
close-code table.

For an invalid hello, the coordinator closes with code `4001` and
reason `"invalid_hello: <field>"` (e.g. `"invalid_hello: missing
model_id"`).

**FR-P3. Maintain provider pool entry with last-heard timestamp.**
Each provider pool entry tracks: `provider_id`, `assigned_id`,
`ws_conn`, `state`, `model_id`, `model_params_b`, `ram_gb`,
`max_context_tokens`, `max_concurrency`, `slots_free`, `slots_total`,
`throughput_tps_estimate`, `endpoint_url` (looked up from coordinator
static config keyed by `provider_id`; not from hello),
`last_heartbeat_at`, `connected_at`, `binary_version`. Updated on every
heartbeat and state_update. Removed on WebSocket disconnect (after
grace period) or operator blacklisting.

**FR-P4. Process heartbeat messages, update capacity state.**
On receiving a `heartbeat`, update `last_heartbeat_at`, dynamic fields
(`slots_free`, `slots_total`, throughput metrics), and static fields
(`model_id`, `model_params_b`, `ram_gb`, `max_context_tokens`,
`max_concurrency` — repeated per SPEC-001 so coordinator can
re-establish state after restart without new handshake). If `status`
differs from pool state, treat as implicit state_update.

**FR-P5. Process state_update: react to state transitions.**
On receiving a `state_update`, the coordinator validates `state` is one
of `ready`, `busy`, `degraded`, `draining`, `unavailable`, updates the
pool entry, and adjusts routing eligibility:

| State | Routing eligible | Behavior |
|---|---|---|
| `ready` | Yes | Normal operation |
| `busy` | No | All slots occupied; in-flight continues |
| `degraded` | No | Warm-up or partial failure; in-flight continues |
| `draining` | No | Provider shutting down; will close WS |
| `unavailable` | No | Fatal error; MAY close WS after 60s timeout |

Logs state transition with `reason` and `since` fields at info level.

**FR-P6. Process drain_status: stop routing to draining providers.**
On receiving a `drain_status` message (SPEC-001 section 6.5), the coordinator:
1. Logs the drain progress (`phase`, `inflight_requests`,
   `estimated_drain_seconds`).
2. If `phase` is `"complete"`, expects the provider to close the
   WebSocket imminently. The coordinator removes the provider from
   the pool after the WebSocket closes.
3. Does NOT forcefully close the WebSocket during drain — the
   provider controls when to close.

**FR-P7. Send preflight queries before routing context-heavy requests.**
Before forwarding, the coordinator sends a `preflight` message with the
estimated token count (bytes/4 heuristic). Preflight is REQUIRED for
`estimated_tokens > 4096`; skipped for smaller requests (latency).
Coordinator waits up to 5s for `preflight_ack`. Timeout: skip provider
for this request, try next candidate. Timeout does NOT mark provider
unhealthy. Rejection: log reason, remove from candidates, re-route. No
candidates remaining: return 503 to buyer.

**FR-P8. Send warm_up after detected wake event.**
The coordinator detects wake events by monitoring heartbeat gaps. If
`last_heartbeat_at` gap > 120s and a new heartbeat arrives, the
coordinator sends `{"type": "warm_up"}`, marks the provider `degraded`
(overriding the heartbeat's `ready` — Phase 2 D2 found -12% throughput
on first post-wake request), and waits for a `state_update` to `ready`
before routing. If no `state_update` arrives within 60s, log a warning
and allow routing anyway.

**FR-P9. Send drain command on shutdown / blacklisting.**
The coordinator sends `{"type": "drain"}` when: (1) coordinator SIGTERM
(to all providers), or (2) operator blacklist (to specific provider).
After sending, marks provider `draining` and stops routing. Does NOT
close the WebSocket — waits for provider to send `drain_status` and
close when ready.

**FR-P10. Detect provider disconnect; remove from active pool.**
On WebSocket close, the coordinator marks the provider `unavailable` and
starts a grace period (configurable, default: 30s). If the provider
reconnects (same `provider_id`) within the grace period, the new
connection replaces the old entry seamlessly. If the grace period
expires, the provider is removed from the pool. In-flight buyer
requests to the disconnected provider fail with HTTP 502 (FR-B7). Clean
close after `drain_status: complete` is logged at info; all other
closes at warn.

**FR-P11. Distinguish provider failure modes.**
Informed by Phase 2 D1 (502 vs 530):

| Failure | Detection | Action | Recovery |
|---|---|---|---|
| WS disconnect (530-equivalent) | WS close, no prior drain | `unavailable`, grace period | Reconnects with new hello |
| HTTP 502 (MLX down) | Provider returns 502 on routed buyer request | `degraded`, 30s backoff | Recovery preflight after 30s |
| HTTP 504 (timeout) | No response in time | `degraded`, 30s backoff | Same as 502 |
| **HTTP 530 (Cloudflare tunnel daemon disconnected)** | Provider endpoint returns literal HTTP 530 on routed buyer request | `unavailable` immediately; log `state_update.reason = "http_530_observed"`; trigger WebSocket liveness probe (ping with 5s ack timeout) | Removed from pool until WebSocket reconnects with fresh hello, OR if WS is still alive, until next heartbeat confirms `state: ready` |

On 502/504 degraded: after 30s backoff, send a **recovery preflight**.
If accepted, mark `ready`. If rejected/timeout, extend to 60s and retry.
After 3 consecutive failures, mark `unavailable`.

**Literal HTTP 530 is normative in v1.** Phase 2 observed the M4
provider's Cloudflare tunnel emit HTTP 530 to a routed buyer request
while the WebSocket control plane briefly remained connected (mac
sleeping, cloudflared partially alive). The coordinator must treat this
as a stronger signal than 502: 502 is "mlx down, tunnel up, retry soon";
530 is "tunnel daemon itself disconnected, this provider is not
reachable until tunnel reconnects." The WebSocket liveness probe in this
row catches the case where the WS appears alive but cannot deliver
control messages.

**Recovery preflight shape (SPEC-001-legal health probe):**
```json
{
  "type": "preflight",
  "request_id": "recovery-probe-<uuid>",
  "estimated_tokens": 128
}
```

This is a strict subset of SPEC-001 § 6.5's `preflight` schema — no extra
fields, no protocol extension. The `request_id` prefix `recovery-probe-`
is a coordinator-side convention that lets the coordinator (and any
operator inspecting logs) distinguish health probes from real buyer
requests by string match. The binary cannot and need not distinguish
them — recovery probes are processed identically to buyer preflights.

**Important:** the recovery preflight is NOT followed by an HTTP request.
The provider responds with `preflight_ack` indicating whether it would
accept a 128-token request; the coordinator interprets `accepted: true`
as "provider is healthy" and immediately marks `ready`. No buyer was
involved; the probe is purely diagnostic.

The provider's binary MUST NOT special-case recovery probes — it should
respond exactly as it would for any preflight (capacity check, no side
effects). The `recovery-probe-` prefix is observable only in the
provider's own logs; the binary still treats it as a normal preflight
under SPEC-001 § 6.5.

**FR-P12. Identify provider; configurable bearer-token check.**

The coordinator supports two provider authentication modes, selected by
config field `auth.require_provider_tokens` (default: `false`).

When `auth.require_provider_tokens` is `false`:
- Pinned providers (those whose `provider_id` matches an entry in
  `config.providers[]`, see § 7.1 F-2) are admitted on `provider_id`
  match alone. The bearer token field in the WebSocket handshake is
  ignored.
- Provisional providers follow the provisional admission path in
  FR-P16 and § 7.5.

When `auth.require_provider_tokens` is `true`:
- Pinned providers MUST present a bearer token in the WebSocket
  handshake matching an operator-issued token registered in the
  coordinator token store. Mismatch or absence MUST result in WS close
  4005 `invalid_token`.
- Provisional providers continue to be admitted without a token. If a
  provisional provider presents a malformed or invalid bearer header,
  the coordinator MAY reject it before hello parsing because the tier is
  not known until after hello.

Tokens (when used) are 32-byte random (64 hex chars), stored as SHA-256
hashes (no plaintext). See Section 7.3.

The default `false` reflects the v1.1.2 tier-1 cooperative trust pool
(per § 2): pinned providers are trusted by `provider_id` alone, and the
token store exists for opt-in hardening. Operators who add a token store
SHOULD flip `require_provider_tokens` to `true` and re-issue tokens to
all pinned providers as one deployment step.

**Implementation invariant:** every code path that depends on the token
validator being configured MUST also handle the case where it is not.
Failure to do so caused the 2026-05-28 production outage cited in audit
category I (see § 11).

**v1 security note.** With optional auth, anyone who learns a valid
`provider_id` and the coordinator's WebSocket URL could attempt to
connect. The coordinator's static config map is the gating mechanism —
only IDs listed in config can be admitted. For production trust beyond
v1, SPEC-001 will be amended to require token-based auth (path B
mandatory). Deploy v1 coordinator behind Cloudflare or similar so the
provider endpoint is not publicly enumerable.

**FR-P13. Reject Tier 2 providers via WebSocket close.**
If a provider's `hello` message contains `tier: 2` (or any value other
than 1), the coordinator closes the WebSocket with application close
code `4003` and reason `"tier_unsupported: coordinator v1 supports tier 1 only"`.

This is a clean rejection — the provider should not retry until
upgraded. The coordinator logs the rejection at info level.

**FR-P14. WS-tunneled inference relay.**
When routing a buyer request to a WS-tunneled provider (mode
resolution: § 3), the coordinator sends an `inference_request` message
(SPEC-001 v1.2 § 6.6) over the provider's WebSocket. For streaming:
each `inference_response_chunk` is translated into one SSE `data:`
line and flushed to the buyer immediately. For non-streaming: chunks
are accumulated until `inference_response_end`, then assembled into a
single HTTP response. The coordinator MUST NOT buffer streaming
chunks — each is relayed as it arrives to preserve time-to-first-token
fidelity.

**FR-P14.1. Status-to-buyer-HTTP mapping for WS-tunneled responses.**
When a WS-tunneled provider sends `inference_response_end`, the
coordinator maps the `status` field to buyer-facing behavior:

| `inference_response_end.status` | Coordinator buyer-facing behavior |
|---|---|
| `"complete"` | Relay final response to buyer with HTTP 200 |
| `"cancelled"` | Close buyer connection cleanly (buyer already disconnected) |
| `"error_model_not_loaded"` | Return HTTP 503 to buyer; do NOT try next provider |
| `"error_context_exceeded"` | Return HTTP 413 to buyer |
| `"error_queue_full"` | Return HTTP 503 to buyer; try next provider in candidates list |
| `"error_internal"` | Return HTTP 502 to buyer; do NOT try next provider |
| (no message received within `request_timeout_s`) | Return HTTP 504 to buyer |

**Provider-internal error messages MUST NOT appear in the buyer-facing
response body.** The coordinator uses generic error descriptions from
the standard OpenAI error envelope (§ 7.2). The `error` field in
`inference_response_end` is logged at the coordinator but not forwarded.

**`error_queue_full` is the only status that triggers re-routing.**
On receiving `error_queue_full`, the coordinator treats this provider
as temporarily full and continues iterating through the § 5 candidate
list. All other error statuses result in an immediate error response
to the buyer per FR-B7 (no silent retry in v1).

**FR-P15. Admission tier assignment.**
The coordinator recognizes three admission tiers:

| Tier | Source | Admission | Routing weight |
|---|---|---|---|
| Pinned | `config.providers[]` | Operator pre-approved | 1.0 |
| Provisional | Unknown `provider_id` | Auto on hello, rate-limited | 0.3 (configurable) |
| Rejected | `rejected_providers` table | Never. WS close 4009. | N/A |

**FR-P16. Provisional admission rate limits.**
- Per-hour admission rate: max 10 new provisional providers per hour
  (sliding window). 11th → WS close 4008. Rationale: 10/hr allows
  ~240/day; at 40 KB per-connection state, 240 = ~9.6 MB on the
  3.8 GB Pearl VPS. Config: `admission.provisional_rate_per_hour`.
- Total provisional pool size: max 100 simultaneous. 101st → WS close
  4007. Rationale: 100 × 40 KB = 4 MB. Config:
  `admission.max_provisional_providers`.
- Per-provisional-provider request quota: max 100 buyer requests per
  hour. Over quota → skip provider in routing (invisible to buyer).
  Rationale: 100 req/hr at ~2.5 s each = ~4 min active inference,
  ~7% utilization. Config:
  `admission.provisional_request_quota_per_hour`.

**FR-P17. Provisional admission persistence.**
Provisional admissions are persisted to SQLite:

```sql
CREATE TABLE provisional_providers (
    provider_id TEXT PRIMARY KEY,
    first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_seen_at TEXT NOT NULL,
    hostname TEXT,
    model_id TEXT,
    binary_version TEXT,
    total_requests_served INTEGER NOT NULL DEFAULT 0,
    total_tokens_served INTEGER NOT NULL DEFAULT 0,
    promoted_at TEXT DEFAULT NULL,
    notes TEXT DEFAULT NULL
);

CREATE TABLE rejected_providers (
    provider_id TEXT PRIMARY KEY,
    rejected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    reason TEXT,
    rejected_by TEXT NOT NULL DEFAULT 'operator'
);
```

On restart, providers with `last_seen_at` older than 30 days are not
pre-loaded (configurable: `admission.provisional_retention_days`).
`rejected_providers` is always loaded — bans are permanent until
operator removes the row.

**FR-P18. WS-tunneled cancellation propagation.**
When a buyer disconnects mid-stream for a WS-tunneled request, the
coordinator detects the broken connection within 1 second, sends
`cancel_request` (SPEC-001 v1.2 § 6.6) to the provider, and frees the
request slot on `inference_response_end` or after 10 seconds (whichever
first). The coordinator MUST NOT close the WebSocket or mark the
provider unhealthy due to a slow cancellation.

**FR-P18.1. Request ID lifecycle (coordinator-side).**
The coordinator maintains an active request_id map per provider WS
connection. The following rules are normative:

1. **Unknown request_id.** If the coordinator receives an
   `inference_response_chunk` or `inference_response_end` with a
   `request_id` it did not issue (or that has already been cleaned up),
   the coordinator MUST log at warn level and discard the frame. MUST
   NOT propagate to any buyer. MUST NOT close the WebSocket.

2. **Duplicate active request_id.** The coordinator MUST NEVER reuse
   a `request_id` while the prior request with that ID is still
   in-flight. The UUID format of `request_id` makes accidental
   collision negligible.

3. **Cleanup.** The coordinator removes a `request_id` from its active
   map after receiving `inference_response_end` OR after
   `routing.request_timeout_s` expires (default 300 s).

See also SPEC-001 v1.2.4 § 6.6 "Request ID lifecycle and error
handling" for the provider-side rules.

**FR-P19. WS-tunneled backpressure — coordinator write buffer.**
Bounded write buffer of 64 messages per provider WebSocket. If full,
return HTTP 503 to buyer. Do NOT block the buyer goroutine. Do NOT
mark provider degraded. Config: `ws.write_buffer_size`.

Rationale: 64 messages at ~100 KB avg = ~6.4 MB, within coordinator
memory budget. Buffer absorbs brief TCP congestion.

**FR-P20. WS-tunneled response timeout.**
Per outstanding `inference_request`, coordinator starts a timer of
`routing.request_timeout_s` (default 300 s). On timeout: send
`cancel_request`, return HTTP 504 to buyer, free slot. After 3
consecutive timeouts without any successful response, mark provider
`degraded` and initiate recovery preflight (FR-P11).

**FR-P21. Tier visibility in /poolz.**
The `/poolz` response (FR-O2) gains `tier` (`"pinned"` or
`"provisional"`) and `inference_path` (`"http_forwarding"` or
`"ws_tunneled"`) fields per provider entry.

### Provider rejection via WebSocket close codes

Because SPEC-001 § 6.5 does not define a coordinator-to-provider `nak`
direction, all coordinator-initiated rejections use standard WebSocket
application close codes (RFC 6455, range 4000–4999). The provider's
binary already handles WebSocket close per SPEC-001 FR-13.

| Close code | Name | Sent when | Reason text format |
|---|---|---|---|
| `4001` | `invalid_hello` | Required field missing or malformed | `"invalid_hello: <field>"` |
| `4002` | `unknown_provider_id` | `provider_id` not in coordinator config map | `"unknown_provider_id: <id>"` |
| `4003` | `tier_unsupported` | `tier != 1` | `"tier_unsupported: tier <n> not supported"` |
| `4004` | `version_unsupported` | `version != 1` | `"version_unsupported: protocol version <n>"` |
| `4005` | `invalid_token` | Token validation is required and bearer token is absent, malformed, invalid, or revoked | `"invalid_token"` |
| `4429` | `pool_full` | Coordinator at configured max provider count | `"pool_full"` |
| `4007` | `provisional_pool_full` | Provisional provider connects when provisional pool at capacity | `"provisional_pool_full: max <N> provisional providers reached"` |
| `4008` | `provisional_rate_limited` | Provisional admission rate exceeded | `"provisional_rate_limited: max <N> admissions per hour"` |
| `4009` | `banned` | Provider's `provider_id` in `rejected_providers` table | `"banned: provider <id> has been rejected by operator"` |

**v1.1 amendment — close code 4002 retired.** In v1.0.x, close code
4002 `unknown_provider_id` rejected any `provider_id` not in
`config.providers[]`. In v1.1, unknown `provider_id` values are
admitted as provisional (subject to rate limits) or rejected with 4009
if banned. Close code 4002 is no longer sent by v1.1+ coordinators.

**F-2 amendment (v1.1, from SPEC-003 v0.1 § 6.4).** The original F-2
("every provider_id must be in config.providers[]") is relaxed:
`config.providers[]` remains the mechanism for pinned tier admission.
Unknown `provider_id` values are accepted as provisional (subject to
rate limits in FR-P16) or rejected with 4009 if in the
`rejected_providers` table.

Codes are mnemonic (4000-range maps to "rejected") and the reason text
provides operator-visible detail. Provider binaries log the close code
and reason per SPEC-001 standard logging; no special parsing required.

**WS-close logging requirement (v1.1.3).** The coordinator MUST emit a
WARN-level log entry for every provider WebSocket close it initiates,
including the numeric close code (for example `4005`) and a short
human-readable reason string (for example `"invalid_token"`,
`"drain_complete"`, or `"heartbeat_timeout"`). This requirement exists
because silent close paths conceal production-breaking misconfiguration.
A coordinator-initiated close is, by definition, a decision the
coordinator made; it MUST be observable in the coordinator's own logs
without correlating against external proxy logs.

When known at close time, close logs SHOULD also include the provider's
`provider_id` and remote address. The v1.1.3 hotfix implementation logs
`close_code` and `reason`; passing provider and remote context into the
shared close helper is a follow-up hardening item, not required for
v1.1.3 spec conformance.

### Buyer-side

**FR-B1. /v1/models endpoint returns aggregated model list.**
`GET /v1/models` returns a JSON response listing all unique models
available across the provider pool. Each model appears once, regardless
of how many providers serve it. The response shape matches the OpenAI
models endpoint:

```json
{
  "object": "list",
  "data": [
    {
      "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "object": "model",
      "created": 1716768000,
      "owned_by": "macprovider",
      "provider_count": 2,
      "max_context_tokens": 50000,
      "total_slots": 4,
      "degraded": false
    },
    {
      "id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "object": "model",
      "created": 1716768000,
      "owned_by": "macprovider",
      "provider_count": 1,
      "max_context_tokens": 20000,
      "total_slots": 1,
      "degraded": true
    }
  ]
}
```

The `provider_count`, `max_context_tokens` (maximum across providers
for that model), `total_slots` (sum across providers), and `degraded`
fields are non-standard extensions. Standard OpenAI clients will ignore
them.

A model is `degraded: true` if any of:

- all providers for this model are state `unavailable` or `draining`.
- fewer than 50% of registered providers for this model are `ready`.
- all providers' `slots_free` for this model equal 0.

Otherwise the model is `degraded: false`. SPEC-006 v0.3 gateway status
aggregation MUST use these same rules.

`created` is the coordinator's start time as a Unix timestamp.

If the pool is empty (no providers connected), the response is:
```json
{
  "object": "list",
  "data": []
}
```

This returns HTTP 200 with an empty list — not 503. The buyer should
check the list before sending requests.

**FR-B2. /v1/chat/completions (non-streaming).**
`POST /v1/chat/completions` with `stream: false` (or `stream` omitted)
accepts a standard OpenAI chat completion request per SPEC-001
section 6.2. The coordinator:
1. Validates the request schema (same validation as SPEC-001 section 6.2,
   steps 1-6).
2. Runs the routing algorithm (Section 5) to select a provider.
3. Optionally sends a preflight check to the selected provider (FR-P7).
4. Forwards the request as an HTTP POST to the provider's endpoint.
5. Receives the provider's JSON response.
6. Returns it to the buyer unmodified (the provider's response is
   already SPEC-001 section 6.2 compliant).

The coordinator adds two response headers:
- `X-MacProvider-Provider`: the stable `provider_id` of the provider
  that served the request (operator-meaningful identity).
- `X-MacProvider-Route`: the session `assigned_id` of the WebSocket
  session that served the request (for log correlation).

Full header list in § 7.2.

**FR-B3. /v1/chat/completions (streaming).**
`POST /v1/chat/completions` with `stream: true` returns an SSE stream.
The coordinator:
1. Validates and routes as in FR-B2.
2. Forwards the request to the provider with `stream: true`.
3. Receives the provider's SSE stream.
4. Relays each SSE event to the buyer in real-time (chunk-by-chunk
   passthrough).
5. Adds both `X-MacProvider-Provider` (stable provider_id) and
   `X-MacProvider-Route` (session assigned_id) response headers, same
   as FR-B2. See § 7.2 for full header list.

The coordinator does NOT buffer the entire stream — it relays each
`data: {...}` line as it arrives from the provider. This preserves
time-to-first-token fidelity.

**FR-B4. Route request to best provider.**
The coordinator selects a provider using the routing algorithm defined
in Section 5. If no eligible provider exists, the coordinator returns
HTTP 503:
```json
{
  "error": {
    "message": "No provider available for model mlx-community/Qwen2.5-7B-Instruct-4bit",
    "type": "service_unavailable",
    "code": "no_provider_available"
  }
}
```

**FR-B5. Preflight check before forwarding context-heavy requests.**
See FR-P7. Invisible to the buyer (adds latency only). If preflight
fails and no fallback exists, buyer receives 503 with rejection reason.

**FR-B6. Forward SSE stream from provider to buyer transparently.**
The coordinator relays SSE events without modification:
- Sets `Content-Type: text/event-stream; charset=utf-8`.
- Sets `X-Accel-Buffering: no` and `Cache-Control: no-cache`.
- Flushes each SSE event immediately.
- Passes through `data: [DONE]` and closes.

If the provider disconnects mid-stream, the coordinator emits:
```
data: {"error":{"message":"Provider disconnected during streaming","type":"server_error","code":"provider_disconnect"}}

data: [DONE]

```
Then closes the buyer's response and logs the failure.

**FR-B7. Clean error on provider failure mid-request — no retry in v1.**
If the selected provider fails at any point (connection error, 502, 504,
mid-stream disconnect), the coordinator does NOT retry with a different
provider. The buyer receives:

- **Streaming requests** (response headers already sent): error SSE event
  emitted (see FR-B6), then `data: [DONE]` and stream close.
- **Non-streaming requests** (no response bytes sent yet): HTTP 502 with
  body
  ```json
  {"error":{"message":"Selected provider failed; buyer should retry","type":"upstream_error","code":"provider_failed"}}
  ```

The buyer (or coordinator-aware client) decides whether to retry. This
preserves idempotency, attribution, and clean debugging in v1.

Visible retry policies (e.g. coordinator-managed retry with explicit
`X-MacProvider-Retry` header) are deferred to SPEC-004 (smart router)
or SPEC-006 (public API), where buyer expectations differ.

**FR-B8. Return HTTP 503 with descriptive body if no provider available.**
See FR-B4 for the response shape. Additional 503 scenarios:
- All providers for the requested model are `busy`, `degraded`,
  `draining`, or `unavailable`.
- All providers rejected the preflight check.
- The requested model is not served by any provider.

**FR-B9. Log every buyer request.**
Every buyer request is logged to the `request_log` table in SQLite:

| Column | Type | Description |
|---|---|---|
| `id` | INTEGER PK | Auto-increment |
| `ts_utc` | TEXT | ISO 8601 timestamp |
| `request_id` | TEXT | UUID v4 from inbound `X-Request-ID` when present, otherwise UUID assigned by coordinator |
| `model` | TEXT | Requested model |
| `provider_assigned_id` | TEXT | Pool ID of serving provider (null if 503) |
| `prompt_tokens` | INTEGER | From provider response usage (null if failed) |
| `completion_tokens` | INTEGER | From provider response usage (null if failed) |
| `total_tokens` | INTEGER | prompt + completion |
| `latency_ms` | REAL | Total wall time including routing |
| `routing_ms` | REAL | Time spent in routing + preflight |
| `status` | INTEGER | HTTP status returned to buyer |
| `stream` | INTEGER | 1 if streaming, 0 if not |
| `buyer_ip` | TEXT | Buyer's IP (for rate limiting in future) |
| `error` | TEXT | Error message if failed (null if success) |
| `pref_header` | TEXT | Value of X-MacProvider-Pref if present |
| `provider_header` | TEXT | Value of X-MacProvider-Provider if present |
| `retried` | INTEGER | Always 0 in v1 (no coordinator-managed retry). Column reserved for SPEC-004 / SPEC-006 retry policies. |

Token counts are extracted from the provider's response `usage` field.
For streaming responses, they come from the usage chunk (SPEC-001 FR-7).

`request_id` MUST be indexed. Any service in the request path that fails to propagate `X-Request-ID` degrades cross-layer debuggability; new buyer/request log surfaces MUST include X-Request-ID propagation.

### Routing logic

**FR-R1. Default selection: model match, utilization-favoring.**
The default routing algorithm selects a provider whose `model_id`
matches the request's `model` field exactly. If multiple providers
serve the same model, the coordinator prefers the one with the lowest
positive `slots_free` (utilization-favoring). This concentrates load on
fewer providers, leaving others fully idle for sleep/power savings.

Full algorithm in Section 5.

**FR-R2. Capacity preference via buyer header.**
The buyer can hint routing preference via the `X-MacProvider-Pref`
request header:

| Value | Meaning | Selection effect |
|---|---|---|
| `fast` | Maximize throughput | Prefer highest `throughput_tps_estimate` |
| `accurate` | Maximize model quality | Prefer highest `model_params_b` |
| (absent) | Default | Utilization-favoring (FR-R1) |

Unknown values are silently ignored (treated as absent).

**FR-R3. Provider pinning via buyer header.**
The buyer can pin to a specific provider via
`X-MacProvider-Provider: <provider_id>`. **The header value is the
stable `provider_id`** (the identifier the provider sends in `hello`,
matched by the coordinator's static config map). This is the
operator-meaningful identity that survives reconnects.

If a buyer needs to pin a specific WebSocket session for short-lived
debugging (e.g. "this exact instance, this run"), they may send
`X-MacProvider-Session: <assigned_id>` instead. The coordinator
resolves session ID to the current pool entry; if the session has ended,
returns 503 with `code: "session_ended"`.

If `X-MacProvider-Provider` is sent and the named provider is in the
pool in `ready` state with `slots_free > 0`, the coordinator routes to
it directly (bypassing the selection algorithm). If the pinned provider
is unavailable, the coordinator returns 503 (does NOT fall back — the
buyer explicitly requested this one).

If both headers are sent, `X-MacProvider-Session` takes precedence (more
specific). `/poolz` shows both `provider_id` and `assigned_id` for each
entry.

**FR-R4. Pool filtering: only ready providers with free slots.**
Before running the selection algorithm, the coordinator filters the pool
to only include providers where:
- `state` is `ready`
- `slots_free > 0`
- `model_id` matches the request's `model` field

**FR-R5. Context length check.**
The coordinator estimates the request's token count (bytes / 4
heuristic) and excludes providers whose `max_context_tokens` is less
than the estimated count. For requests where `estimated_tokens > 4096`,
the authoritative check is the preflight (FR-P7) — but the coordinator
pre-filters to avoid sending preflights to providers that will
obviously reject.

**FR-R6. Tier scope check.**
In v1, all providers are Tier 1 and all buyers are Tier 1. This check
is a no-op but exists as a hook point: in Tier 2, the coordinator would
match buyer trust requirements to provider attestation levels.

### Operations

**FR-O1. /healthz endpoint.**
`GET /healthz` returns coordinator self-health:

```json
{
  "status": "ok",
  "uptime_s": 3600,
  "pool_size": 3,
  "pool_ready": 2,
  "pool_degraded": 1,
  "pool_draining": 0,
  "pool_unavailable": 0,
  "requests_total": 1420,
  "requests_active": 2,
  "version": "0.1.0"
}
```

Returns HTTP 200 if the coordinator is running. Returns HTTP 503 if
the coordinator is draining (SIGTERM received).

No authentication required — intended for VPS-side monitoring
(systemd, uptime checks).

**FR-O2. /poolz endpoint (operator-only, auth-gated).**
`GET /poolz` returns the full pool state, including per-provider
details. Requires an operator API key in the `Authorization` header
(`Bearer <operator-key>`). The operator key is configured in the
coordinator's config file (not the same as provider tokens).

Response:
```json
{
  "pool": [
    {
      "assigned_id": "abc-123",
      "provider_id": "uuid-of-mac",
      "hostname": "Johns-MacBook-Pro.local",
      "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "model_params_b": 7.0,
      "ram_gb": 16,
      "state": "ready",
      "slots_free": 1,
      "slots_total": 2,
      "max_context_tokens": 50000,
      "throughput_tps_estimate": 19.8,
      "last_heartbeat_at": "2026-05-27T14:30:00Z",
      "connected_at": "2026-05-27T12:00:00Z",
      "binary_version": "0.1.0",
      "endpoint_url": "https://m4.streamvc.live"
    }
  ],
  "summary": {
    "total_providers": 2,
    "ready": 2,
    "draining": 0,
    "unavailable": 0,
    "total_slots": 4,
    "free_slots": 3,
    "models": ["mlx-community/Qwen2.5-7B-Instruct-4bit"],
    "by_model": {
      "mlx-community/Qwen2.5-7B-Instruct-4bit": {
        "providers": 2,
        "ready": 2,
        "slots_free_total": 3,
        "slots_total": 4
      }
    }
  }
}
```

The `summary` block is the SPEC-006 v0.3 gateway input for `/v1/status`; the detailed `pool` array is operator-only and MUST NOT be exposed to buyers by the gateway.

Returns HTTP 401 if the operator key is missing or invalid.

**FR-O3. SIGTERM gracefully drains in-flight buyer requests.**
On SIGTERM: stop accepting new connections, send `drain` to all
providers (FR-P9), wait for in-flight requests (up to 30s configurable
timeout), force-close remaining with 503, close all WebSockets, flush
SQLite WAL, exit 0. On SIGINT, same with 5s timeout.

**FR-O4. Provider auth token CLI.**
The coordinator ships with a `coordinator-cli` tool:

- `issue-token --provider-name "Name"` — generates 32-byte random
  token (64 hex chars), stores SHA-256 hash in SQLite, prints
  plaintext once (not recoverable).
- `revoke-token --token-prefix <prefix>` — sets `revoked_at` on
  matching token. Provider disconnected on next reconnection attempt.
- `list-tokens` — shows ID, prefix, name, created, revoked status.

Token storage schema: see Section 7.3.

**FR-O5. Persist durable state to SQLite.**
SQLite (WAL mode) persists, across coordinator restarts:
- `provider_tokens` (auth tokens; restored on restart)
- `request_log` (billing/attribution; append-only ledger)
- `pool_snapshots` (periodic debug history, every 5 min — **debugging
  only, not restored on restart**)

**Live pool routing state is in-memory only.** On coordinator restart,
the pool table is empty. Providers reconnect automatically (SPEC-001
FR-13 exponential backoff) and re-establish state via fresh hello +
heartbeats. This means a coordinator restart causes ~30s of buyer-facing
503s while providers reconnect, which is acceptable for v1 single-
instance deployment. The `pool_snapshots` table exists only to help an
operator debug "what did the pool look like 5 min before crash."

SQLite file: `coordinator.db` (configurable via `--db-path`). Daily
backup via cron + rsync to operator.

(Scope item in § 2 "SQLite persistence for provider auth, request log,
pool state" should be read as: auth + log persisted across restarts;
pool snapshots stored for debugging only.)

---

## 5. Routing algorithm

The routing algorithm runs for every buyer request to
`/v1/chat/completions`. It selects the best provider from the pool.

### Pseudocode

```
function route(request, pool, headers) -> provider | error:
    model = request.model
    estimated_tokens = estimate_tokens(request.messages)

    # v1.1.1 helper: case-insensitive model match (D9 fix)
    function model_id_equal(a: string, b: string) -> bool:
        return casefold(a) == casefold(b)
    # Canonical casing preserved in /poolz and /v1/models for display.

    # Step 1: Provider pinning (X-MacProvider-Session takes precedence)
    if headers["X-MacProvider-Session"] is set:
        provider = pool.get_by_assigned_id(headers["X-MacProvider-Session"])
        if provider is nil:
            return error(503, "code=session_ended")
    elif headers["X-MacProvider-Provider"] is set:
        provider = pool.get_by_provider_id(headers["X-MacProvider-Provider"])
        if provider is nil:
            return error(503, "Pinned provider not in pool")
    if provider is set:
        if provider.state != "ready" or provider.slots_free <= 0:
            return error(503, "Pinned provider not available")
        if not model_id_equal(provider.model_id, model):
            return error(404, "Pinned provider serves different model")
        # v1.1.1: check provisional quota even for pinned-by-header requests
        if not check_provisional_quota(provider):
            return error(429, "Pinned provisional provider is over request quota")
        return provider

    # Step 2: Filter candidates
    candidates = []
    for p in pool:
        if not model_id_equal(p.model_id, model):
            continue
        if p.state != "ready":
            continue
        if p.slots_free <= 0:
            continue
        if p.max_context_tokens < estimated_tokens:
            continue
        candidates.append(p)

    if len(candidates) == 0:
        return error(503, "No provider available for model " + model)

    # Step 2.3: Provisional request quota check (v1.1.1)
    function check_provisional_quota(provider) -> bool:
        if provider.tier == "pinned":
            return true  # pinned providers have no request quota
        quota = COUNT(requests where provider_id == provider.id
                      AND ts > now() - 1 hour)
        return quota < admission.provisional_request_quota_per_hour  # default 100

    pre_quota_candidates = candidates
    quota_blocked_candidates = [c for c in pre_quota_candidates
                                if not check_provisional_quota(c)]
    candidates = [c for c in pre_quota_candidates
                  if check_provisional_quota(c)]

    if len(candidates) == 0:
        if len(quota_blocked_candidates) > 0 and len(pre_quota_candidates) == len(quota_blocked_candidates):
            # All otherwise-eligible candidates are quota-blocked
            return error(429, code="provisional_quota_exceeded",
                         headers={"Retry-After": "3600"})
        else:
            # No eligible candidates for other reasons
            return error(503, "No provider available for model " + model)

    # Step 2.5: Apply admission-tier weight (v1.1)
    for candidate in candidates:
        candidate.effective_throughput = candidate.throughput_tps_estimate * tier_weight(candidate.tier)
    # where tier_weight(pinned) = 1.0, tier_weight(provisional) = 0.3 (configurable)

    # Step 3: Apply buyer preference
    pref = headers.get("X-MacProvider-Pref", "")

    if pref == "fast":
        # Sort by throughput descending, break ties by slots_free ascending
        sort(candidates, key=(-effective_throughput, slots_free))
    elif pref == "accurate":
        # Sort by model_params_b descending, break ties by slots_free ascending
        sort(candidates, key=(-model_params_b, slots_free))
    else:
        # Default: utilization-favoring
        # Prefer lowest positive slots_free (concentrate load)
        # Break ties by throughput descending
        sort(candidates, key=(slots_free, -effective_throughput))

    # Step 4: Select and preflight
    for provider in candidates:
        if estimated_tokens > 4096:
            ack = send_preflight(provider, request_id, estimated_tokens)
            if ack is nil:
                # Timeout — skip this provider for this request
                continue
            if not ack.accepted:
                # Provider rejected — skip
                continue
        return provider

    # All candidates failed preflight
    return error(503, "All providers rejected the request")
```

### Selection order detail

1. **Provider pinning** takes absolute precedence. If the buyer
   requests a specific provider, no other provider is considered. This
   enables A/B testing and debugging.

2. Model match is **case-insensitive** string comparison on `model_id` (v1.1 amendment, per D9). The canonical form (as sent by the provider in hello) is preserved in storage and returned in `GET /v1/models`. No fuzzy
   matching, no aliases in v1. The model ID is the HuggingFace
   identifier (e.g., `mlx-community/Qwen2.5-7B-Instruct-4bit`).

3. **State + capacity filter** removes any provider that cannot serve
   the request right now. Only `ready` providers with `slots_free > 0`
   and sufficient `max_context_tokens` are candidates.

4. **Buyer preference** changes the sort order but not the filter.
   All three sort strategies produce a total order — no random
   selection, fully deterministic for a given pool snapshot.

5. **Preflight** is the final gate. It only runs for estimated-large
   requests. The provider's own token counting is authoritative. If
   the first candidate rejects the preflight, the algorithm tries the
   next candidate in sorted order.

### Tie-breaking

- **Default mode (utilization-favoring):** If two providers have the
  same `slots_free`, the one with higher `throughput_tps_estimate`
  wins. If still tied, the one that connected earlier (`connected_at`)
  wins (stable sort).

- **Fast mode:** If two providers have the same
  `throughput_tps_estimate`, the one with fewer `slots_free` wins
  (pack load). If still tied, `connected_at`.

- **Accurate mode:** If two providers have the same `model_params_b`,
  the one with fewer `slots_free` wins. If still tied, `connected_at`.

**Operator-visible behavior under equal metrics (v1.0.4 clarification,
Finding F-1).** Because all tiebreaks ultimately fall back to
`connected_at` and the sort is stable, when two providers advertise
identical primary metrics in steady state, **all traffic deterministically
routes to whichever provider connected first**. This is by design — slot
counts are decremented only on heartbeat tick, not on dispatch, so
sub-heartbeat-interval bursts do not cause metric drift between
equivalent providers. Operators running pools of N≥2 identical providers
should expect skewed utilization until at least one provider's metrics
diverge (different `model_id`, different `throughput_tps_estimate` from
real traffic, or one being marked `degraded`/`draining`). Operators who
want active load distribution across equivalent providers should set
different `model_id` aliases or use `/admin/blacklist` to drain providers
in rotation. A future SPEC-004 (smart router) may introduce a randomized
tiebreak with tolerance ε on metric equality; v1.0.4 explicitly does NOT
randomize, to preserve reproducibility of routing decisions in audit
logs.

### Token estimation heuristic

The coordinator does NOT have access to the model's tokenizer (it does
not load models). It uses a byte-based heuristic:

```
estimated_tokens = total_bytes(serialize(request.messages)) / 4
```

This is intentionally conservative (overestimates for English text,
roughly accurate for code). The provider's preflight check uses the
real tokenizer and is authoritative. The coordinator's estimate is
only used for:
1. Pre-filtering providers by `max_context_tokens` (avoid obvious
   mismatches).
2. Deciding whether to send a preflight (skip for < 4096 estimated).

---

## 6. Non-functional requirements

**NFR-1. Coordinator overhead.**
The coordinator adds less than 50ms of latency to routed requests,
measured as the time between receiving the buyer's HTTP request and
sending the first byte to the provider's HTTP endpoint (excluding
preflight). This covers request validation, routing, and connection
setup. Preflight adds its own latency (up to 5s timeout, typically
<100ms on a healthy provider).

**NFR-2. Availability.**
Single-instance deployment in v1. No HA, no failover. If the
coordinator process crashes, providers reconnect automatically when it
restarts (SPEC-001 FR-13 exponential backoff). Buyer requests fail with
connection errors during downtime. HA is deferred to SPEC-002.next.

**NFR-3. Storage.**
SQLite in WAL mode. Single database file. Daily backup via file copy
(cp + rsync to operator's machine). No replication in v1. Expected
database size: <100MB after 6 months of moderate traffic (~10K
requests/day).

**NFR-4. Logging.**
JSON Lines to stdout, captured by systemd journal. Each log line
includes: ISO 8601 timestamp, level, message, and structured fields
(request_id, provider_id, model, latency_ms, etc.). Log level
configurable via `--log-level` (default: `info`).

The coordinator never logs buyer prompt content or response content
at `info` level. `debug` level may log request metadata (model,
token counts, headers) but not message bodies.

**NFR-5. Security.**
- TLS termination handled by Caddy or nginx in front of the
  coordinator (out of scope for the coordinator binary).
- Provider WebSocket auth via bearer token (FR-P12).
- Operator endpoints (/poolz, /admin/*) auth via operator API key.
- No buyer auth in v1 (single-tenant, Antseed-only).
- SQLite provider tokens stored as SHA-256 hashes.
- No secrets in environment variables at runtime (tokens loaded from
  SQLite; operator key from config file).

**NFR-6. Concurrency.**
The coordinator handles at least 100 concurrent buyer requests across
at least 4 connected providers without degradation. Go's goroutine
model handles this naturally — each buyer request is a goroutine, each
provider WebSocket is a goroutine.

**NFR-7. Memory.**
Less than 200MB RSS at idle (no providers, no active requests). Less
than 1GB RSS at peak (100 concurrent requests, 10 providers connected).
The coordinator does not buffer full inference responses in memory —
streaming responses are relayed chunk-by-chunk.

**NFR-8. Startup time.**
From `coordinator start` to listening on both HTTP and WebSocket ports:
under 2 seconds. No model loading, no heavy initialization. SQLite
open + table creation + listener bind.

---

## 7. Interface contracts

### 7.1. Provider WebSocket (server side of SPEC-001 section 6.5)

The coordinator is the WebSocket server. Providers (Phase 3 binaries)
connect as clients. The protocol is defined by SPEC-001 section 6.5 and is
LOCKED. This section replicates the message schemas and defines the
coordinator's behavior for each.

#### Connection lifecycle

```
Provider                         Coordinator
   |                                  |
   |--- WebSocket upgrade + Bearer -->|
   |                                  | FR-P12: validate token
   |<-------- 101 Switching ---------|
   |                                  |
   |--- hello ----------------------->|
   |                                  | FR-P2: validate, register in pool
   |<-------- hello_ack -------------|
   |                                  |
   |--- heartbeat (every 30s) ------>|
   |                                  | FR-P4: update pool state
   |                                  |
   |--- state_update (on change) --->|
   |                                  | FR-P5: update state, adjust routing
   |                                  |
   |                                  | FR-P7: preflight (before routing)
   |<-------- preflight -------------|
   |--- preflight_ack -------------->|
   |                                  |
   |                                  | FR-P8: after wake detection
   |<-------- warm_up ---------------|
   |--- state_update (degraded) ---->|
   |  ... warm-up inference ...      |
   |--- state_update (ready) ------->|
   |                                  |
   |                                  | FR-P9: shutdown or blacklist
   |<-------- drain -----------------|
   |--- drain_status (starting) ---->|
   |--- drain_status (in_progress) ->|
   |--- drain_status (complete) ---->|
   |--- WebSocket close ------------>|
   |                                  | FR-P10: remove from pool
```

#### Provider authentication mode (v1.1.3)

The coordinator supports two provider authentication modes, selected by
the config field `auth.require_provider_tokens` (default: `false`).

When `auth.require_provider_tokens` is `false`:
- Pinned providers (those whose `provider_id` matches an entry in
  `config.providers[]`, see § 7.1 F-2) are admitted on `provider_id`
  match alone. The bearer token field in the WebSocket handshake is
  ignored.
- Provisional providers follow the provisional admission path as normal.

When `auth.require_provider_tokens` is `true`:
- Pinned providers MUST present a bearer token in the WebSocket
  handshake matching the operator-issued token registered for that
  `provider_id` in the coordinator's token store. Mismatch or absence
  MUST result in WS close 4005 `invalid_token`.
- Provisional providers continue to be admitted without a token; the
  token requirement applies only to the pinned tier. A malformed or
  invalid bearer header MAY still be rejected before hello parsing
  because the coordinator cannot know the provider tier until after
  hello.

The default `false` reflects v1.1.2's tier-1 cooperative trust pool
(per § 2): pinned providers are trusted by `provider_id` alone, and the
token store exists for future expansion. Operators who add a token store
SHOULD flip `require_provider_tokens` to `true` and re-issue tokens to
all pinned providers as a single deployment step.

**Implementation invariant:** every code path that depends on the token
validator being configured MUST also handle the case where it is not.
Failure to do so caused the 2026-05-28 production outage cited in audit
category I (see § 11).

#### Message schemas (replicated from SPEC-001 section 6.5)

All messages are JSON objects with a `type` field.

**hello (P->C)** — sent by provider on WebSocket open:
```json
{
  "type": "hello",
  "version": 1,
  "tier": 1,
  "provider_id": "m4-anon",
  "hostname": "Johns-MacBook-Pro.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 2,
  "throughput_tps_estimate": 19.8,
  "binary_version": "1.2.0",
  "attestation": null,
  "endpoint_url": null
}
```

These schemas mirror SPEC-001 v1.2.4 § 6.5; SPEC-001 is the authoritative source.

Coordinator behavior:
- Validates all REQUIRED fields present and correctly typed; validates OPTIONAL fields (`attestation`, `endpoint_url`) when present. Absent `endpoint_url` normalized to null (FR-P2).
- Rejects `tier != 1` by closing the WebSocket with application close code 4003 `tier_unsupported` (FR-P13).
- Rejects duplicate `provider_id` by closing the older connection.
- Registers provider in pool with state `ready`.
- Responds with `hello_ack`.

**hello_ack (C->P)** — coordinator response to valid hello:
```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "provider-pool-id",
  "heartbeat_interval_s": 30,
  "tier": "pinned",
  "recommended_binary_version": "1.2.0"
}
```

Coordinator behavior:
- `assigned_id` is a UUID generated by the coordinator for this pool
  session. Used in routing logs and the `X-MacProvider-Route` header.
- `heartbeat_interval_s` is configurable (default: 30). The provider
  must send heartbeats at this interval. The coordinator uses
  `1.5 * heartbeat_interval_s` as the staleness threshold — if no
  heartbeat arrives within 45s, the provider is considered potentially
  stale (logged at warn but not removed; removal requires WebSocket
  close or explicit timeout).

**heartbeat (P->C)** — sent by provider every heartbeat_interval_s:
```json
{
  "type": "heartbeat",
  "status": "ready",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 2,
  "slots_free": 1,
  "slots_total": 2,
  "throughput_tps_estimate": 19.8,
  "requests_served_since_last": 12,
  "avg_latency_ms_since_last": 450.0,
  "throughput_tps_since_last": 18.5
}
```

Coordinator behavior:
- Updates pool entry with all fields (FR-P4).
- Updates `last_heartbeat_at`.
- If `status` differs from pool state, treats as implicit state_update.
- If `last_heartbeat_at` gap > 120s (wake detection), triggers FR-P8.
- Logs heartbeat at debug level.

**state_update (P->C)** — sent on provider state change:
```json
{
  "type": "state_update",
  "state": "degraded",
  "reason": "post-wake warm-up in progress",
  "since": "2026-05-27T14:30:00Z",
  "metrics_snapshot": {
    "slots_free": 2,
    "slots_total": 2,
    "requests_served_since_last": 0,
    "avg_latency_ms_since_last": null,
    "throughput_tps_since_last": null
  }
}
```

Coordinator behavior:
- Validates `state` is one of the 5 allowed values (FR-P5).
- Updates pool entry state and metrics.
- Adjusts routing eligibility immediately.
- Logs state transition at info level with `reason`.

**drain_status (P->C)** — sent during provider drain:
```json
{
  "type": "drain_status",
  "phase": "in_progress",
  "inflight_requests": 2,
  "estimated_drain_seconds": 15
}
```

Coordinator behavior:
- Logs drain progress (FR-P6).
- `phase: "starting"` — coordinator confirms provider is draining.
- `phase: "in_progress"` — informational; coordinator already stopped
  routing to this provider.
- `phase: "complete"` — coordinator expects WebSocket close imminently.

**preflight (C->P)** — coordinator asks provider before routing:
```json
{
  "type": "preflight",
  "request_id": "buyer-req-uuid",
  "estimated_tokens": 8500
}
```

When coordinator sends this:
- Before forwarding a buyer request to the provider, if
  `estimated_tokens > 4096` (FR-P7).
- The `request_id` is the coordinator's UUID for the buyer request,
  used to correlate the response.
- Coordinator waits up to 5 seconds for `preflight_ack`.

**preflight_ack (P->C)** — provider's response to preflight:
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "accepted": true,
  "estimated_wait_ms": 0
}
```

Rejection example:
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "accepted": false,
  "reason": "context_exceeds_capacity",
  "max_context_tokens": 50000
}
```

Coordinator behavior:
- If `accepted: true`: proceed to forward the buyer request.
- If `accepted: false`: log rejection reason, try next candidate
  provider (Section 5).
- If timeout (no response in 5s): skip this provider for this request,
  try next candidate. Do NOT mark provider as unhealthy.

Valid rejection reasons (from SPEC-001):
- `context_exceeds_capacity`
- `queue_full`
- `draining`
- `model_not_loaded`
- `unhealthy`
- `tier_mismatch`

**drain (C->P)** — coordinator tells provider to stop:
```json
{
  "type": "drain"
}
```

When coordinator sends this:
- On coordinator SIGTERM (to all providers) (FR-P9).
- On operator blacklist command (to specific provider).
- Coordinator marks provider as `draining` in pool immediately.
- Coordinator does NOT close the WebSocket — waits for provider.

**warm_up (C->P)** — coordinator triggers warm-up:
```json
{
  "type": "warm_up"
}
```

When coordinator sends this:
- After detecting a wake event (heartbeat gap > 120s then resumption)
  (FR-P8).
- Coordinator marks provider as `degraded` in pool.
- Coordinator waits for `state_update` with `state: "ready"` before
  routing to this provider.

**nak (P->C only)** — per SPEC-001 § 6.5, `nak` is provider-to-coordinator
only. Protocol error from provider:
```json
{
  "type": "nak",
  "in_reply_to": "preflight",
  "error": {
    "code": "unknown_message_type",
    "message": "Unrecognized message type: 'foo'"
  }
}
```

Coordinator behavior when receiving nak from provider:
- Log the nak at warn level.
- Do NOT disconnect the provider. A nak is informational — the
  provider does not understand a specific message but is otherwise
  healthy.

**Special case: nak `unknown_message_type` in response to § 6.6
message dispatch (v1.1.1, M5 fix).** When the coordinator dispatches
an `inference_request` (or other SPEC-001 v1.2 § 6.6 message) and the
provider replies with `nak code=unknown_message_type`, this indicates
a routing-mode resolution bug: the coordinator believed the provider
supported WS-tunneled mode when it does not. The coordinator MUST:
1. Mark the provider's effective routing mode as
   `http_forwarding_only` for the remainder of this WS session (until
   the provider reconnects with a fresh hello).
2. MUST NOT retry the failed request via § 6.6.
3. SHOULD return HTTP 503 to the buyer for this request.
4. Log at warn level: "routing-mode resolution bug: provider <id>
   does not support § 6.6; marking http_forwarding_only."

See SPEC-001 v1.2.4 backward-compat statement for the design rationale.

**Coordinator does NOT send `nak` to providers.** Coordinator-initiated
rejection (invalid hello, unknown provider_id, tier mismatch, version
mismatch, invalid token, pool full) uses WebSocket application close
codes 4001–4005, 4429 with descriptive reason strings. See FR-P13's
"Provider rejection via WebSocket close codes" table.

This preserves SPEC-001 § 6.5's locked one-directional `nak` semantics
exactly. Provider binaries do not need any new parser logic; standard
WebSocket close handling per SPEC-001 FR-13 is sufficient.

### 7.2. Buyer HTTP API

Wire-compatible with SPEC-001 section 6.2. The harness (`beta/harness.py`)
is the first buyer and generates SPEC-001-shaped requests.

Coordinator MUST honor any inbound `X-Request-ID` header on buyer-facing `/v1/*` requests and include it in the `request_log` row. If absent, coordinator MAY generate its own UUID v4. The `request_log` schema includes an indexed `request_id` field for this cross-service correlation key.

When forwarding work to a provider over the SPEC-001 § 6.6 `inference_request` message, coordinator MUST preserve the request ID it recorded for the buyer request. Providers MAY echo `X-Request-ID` back in usage reporting; this is OPTIONAL under SPEC-001 v1.2.4 and is filed as a SPEC-001 v1.2.3 candidate.

Gateway-originated traffic from SPEC-006 v0.3 uses `X-Request-ID` as the join key between gateway `usage_events`, gateway `audit_events`, and coordinator `request_log`. Direct legacy buyer traffic without this header remains supported.

#### GET /v1/models

**Request:** No body. No required headers.

**Response (200):** See FR-B1 for full schema.

#### POST /v1/chat/completions

**Request schema:** Wire-identical to SPEC-001 § 6.2. Detailed below
inline so this spec is self-contained for build session use; if SPEC-001
§ 6.2 ever updates, this section MUST be updated to match.

**Required fields:**

| Field | Type | Constraints |
|---|---|---|
| `model` | string | Must match a `model_id` known to the pool. 404 `model_not_found` if absent from pool history; 503 `no_provider_available` if known but no provider eligible. |
| `messages` | array | Non-empty. Per-message validation below. |

**Optional fields:**

| Field | Type | Default | Constraints |
|---|---|---|---|
| `max_tokens` | int | Remaining provider context capacity | Must be > 0. Coordinator may pass through; the provider's pre-flight enforces context cap. |
| `temperature` | float | 1.0 | 0.0 to 2.0 |
| `top_p` | float | 1.0 | 0.0 to 1.0 |
| `n` | int | 1 | MUST be 1. Values > 1 rejected 400 (single-tenant routing). |
| `stream` | bool | false | If true, response is SSE; see FR-B6. |
| `stream_options` | object | null | `{include_usage: bool}`. Per FR-B1/SPEC-001 FR-7, `include_usage=false` is silently ignored; coordinator always relays the provider's usage chunk. |
| `stop` | string or array | null | Max 4 stop sequences. |
| `presence_penalty` | float | 0.0 | -2.0 to 2.0 |
| `frequency_penalty` | float | 0.0 | -2.0 to 2.0 |
| `seed` | int | null | Passed through to provider. |
| `user` | string | null | Logged at DEBUG only. |
| `response_format` | object | `{type:"text"}` | `type` ∈ {`"text"`, `"json_object"`}. Other values rejected 400. `content_filter` is Tier 2-reserved; v1 rejects 400. |
| `tools` | array | null | Parsed syntactically; if any tool entry lacks `function.name` or has invalid `function.parameters` JSON Schema → 400 `invalid_tools`. |
| `tool_choice` | string or object | null | Parsed, forwarded to provider. v1 coordinator does not execute tools — it relays. |

**Per-message validation:**

| `role` | Required content shape |
|---|---|
| `system` | `content` must be a non-empty string |
| `user` | `content` must be a non-empty string (no multimodal content arrays in v1) |
| `assistant` | `content` may be a string OR `content: null` with `tool_calls` array. If both `content` and `tool_calls` are null/absent → 400. |
| `tool` | `tool_call_id` (string, required) and `content` (string, required) |

Roles other than the four above → 400 `invalid_request`.

**Tool-call shape (when present in assistant history):**
```json
{
  "id": "call_<id>",
  "type": "function",
  "function": {
    "name": "<string>",
    "arguments": "<string-encoded-JSON>"
  }
}
```
`arguments` must parse as valid JSON (string-encoded). Malformed → 400
`invalid_tools`.

**Unknown top-level fields:** ignored silently (forward-compat), logged
at DEBUG.

Validation order:
| Step | Check | Failure response |
|---|---|---|
| 1 | JSON parse | 400 `invalid_json` |
| 2 | Required fields present | 400 `invalid_request` |
| 3 | Field types and ranges | 400 `invalid_request` |
| 4 | Per-message role and content validation | 400 `invalid_request` |
| 5 | Tool/tool_call shape validation | 400 `invalid_tools` |
| 6 | Model exists in pool | 404 `model_not_found` |
| 7 | Provider available (routing) | 503 `no_provider_available` |
| 8 | Preflight (if applicable) | 503 `preflight_rejected` |

Note: steps 7-8 replace SPEC-001's steps 7-9 (Stage 1/2 pre-flight
and queue admission). The coordinator does not tokenize or queue —
the provider handles those.

**Non-streaming response (200):** Forwarded from provider. Same shape
as SPEC-001 section 6.2 non-streaming response. The coordinator adds:
- `X-MacProvider-Route: <assigned_id>` response header.
- `X-MacProvider-Provider: <provider_id>` response header (stable
  identifier; complements the session-scoped `assigned_id` route header).

(No retry header in v1 per FR-B7 — coordinator does not retry across
providers.)

**Streaming response (200):** SSE stream forwarded from provider. Same
shape as SPEC-001 section 6.3. The coordinator adds the same response
headers.

**Custom request headers (buyer → coordinator):**

| Header | Type | Description |
|---|---|---|
| `X-MacProvider-Pref` | string | Same-model preference; `fast` or `accurate` (FR-R2) |
| `X-MacProvider-Provider` | string | **Stable `provider_id`** for pinning across reconnects (FR-R3) |
| `X-MacProvider-Session` | string | Session-scoped `assigned_id` for pinning a specific WebSocket session (FR-R3). Takes precedence over `X-MacProvider-Provider` when both are sent (more specific). |

**Custom response headers (coordinator → buyer):**

| Header | Type | Description |
|---|---|---|
| `X-MacProvider-Provider` | string | Stable `provider_id` of the provider that served the request (operator-meaningful identity) |
| `X-MacProvider-Route` | string | Session `assigned_id` of the WebSocket session that served the request (correlation with coordinator logs) |

(`X-MacProvider-Provider` appears as both a request and response header.
On request it selects; on response it reports. The two semantics share
the same value space — the stable `provider_id`.)

**Reserved response headers (namespace reserved, not enforced in v1):**

| Header | Description |
|---|---|
| `X-RateLimit-Limit` | Future: requests per window |
| `X-RateLimit-Remaining` | Future: remaining in window |
| `X-RateLimit-Reset` | Future: window reset time |

**Error responses:**

| Status | Condition | Error code |
|---|---|---|
| 400 | Missing/invalid fields, malformed tools, n>1 | `invalid_request` or `invalid_tools` |
| 401 | Invalid buyer auth (future, not enforced in v1) | `invalid_auth` |
| 404 | No connected provider has ever advertised this `model_id` (model unknown to the pool) | `model_not_found` |
| 429 | Rate limit exceeded (future, not enforced in v1) | `rate_limit_exceeded` |
| 502 | Selected provider returned an error or disconnected mid-request | `provider_error` |
| 503 | Model is known to the pool but no eligible provider is currently available (all matching providers busy/degraded/draining/unavailable, or all failed preflight) | `no_provider_available` |
| 504 | Provider did not respond within timeout | `provider_timeout` |

**404 vs 503 split (clarified):**
- **404 `model_not_found`** — the requested `model_id` is not in the
  union of `model_id` fields across all currently-connected providers
  AND has not been seen in any provider's hello/heartbeat history during
  this coordinator process lifetime.
- **503 `no_provider_available`** — the `model_id` is recognized
  (some provider serves or has recently served it), but no currently-
  eligible provider can take the request right now. Retry-friendly.

This split matters because buyers should treat 404 as a misconfiguration
("pick a different model") and 503 as transient backoff ("retry soon").

All error responses use the OpenAI error envelope:
```json
{"error":{"message":"...","type":"...","param":null,"code":"..."}}
```

### 7.3. Auth

#### Token issuance flow (offline, CLI)

Operator runs `coordinator-cli issue-token`. CLI generates 32 random
bytes (hex-encoded, 64 chars), stores SHA-256 hash in
`provider_tokens`, prints plaintext once (not recoverable). Operator
delivers token to provider via secure channel.

#### Token validation (bearer in WebSocket auth header)

When `auth.require_provider_tokens=true`, a pinned provider connects
with `Authorization: Bearer <token>`. Coordinator computes SHA-256,
looks up in `provider_tokens`, checks `revoked_at IS NULL`, and updates
`last_used_at`. Valid: hello processing proceeds. Missing, malformed,
invalid, or revoked: WS close 4005 `invalid_token`.

#### Token rotation / revocation

Revocation via `coordinator-cli revoke-token --token-prefix <prefix>`.

**Revocation semantics in v1: future-connection only.** Marking a token
as revoked sets `revoked_at` and prevents any FUTURE WebSocket upgrade
that presents this token from succeeding. **Existing live WebSocket
sessions are NOT automatically disconnected** — they continue serving
buyer traffic until they disconnect for any other reason.

This is intentional in v1: revocation handles the "token leaked" case
on a delay, but the operator's immediate disconnect tool is
`POST /admin/blacklist` (see § 7.4), which closes the live WebSocket
synchronously. The two operations are deliberately separate:
- Revoke → "don't let this token reconnect."
- Blacklist → "kick this provider off now."

Combined: to fully terminate a leaked-token provider, the operator runs
revoke + blacklist. The CLI command `coordinator-cli revoke-and-kick
--token-prefix <prefix>` performs both in one call.

Rotation: issue new, deliver to provider, revoke old. No atomic rotation
in v1.

#### Token storage

```sql
CREATE TABLE provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);
CREATE INDEX idx_token_hash ON provider_tokens(token_hash);
```

No plaintext tokens stored. The `token_prefix` (first 6 hex chars) is
stored for display and revocation convenience only.

### 7.4. Operator endpoints

**Port placement (v1.1.4 clarification, cross-spec F-602-2).** Operator
endpoints `/poolz` and `/admin/*` are mounted on `listen.provider_port`
(default **8444**), the same listener that serves provider WebSocket
upgrades at `/ws/provider`. `/healthz` MAY be exposed on the coordinator
health surface. `GET /v1/pool/check` is a public operator/health
surface for installer verification and is intentionally mounted behind
`coordinator.streamvc.live`, not behind SPEC-006 gateway. Runbook
entries that previously implied "use the buyer URL" should distinguish
the public coordinator health surface from authenticated provider-port
admin actions.

#### GET /healthz

No authentication. Returns coordinator health (FR-O1).

**200 OK:**
```json
{
  "status": "ok",
  "uptime_s": 3600,
  "pool_size": 3,
  "pool_ready": 2,
  "pool_degraded": 1,
  "pool_draining": 0,
  "pool_unavailable": 0,
  "requests_total": 1420,
  "requests_active": 2,
  "version": "0.1.0"
}
```

**503 Service Unavailable** (coordinator draining):
```json
{
  "status": "draining",
  "uptime_s": 3600,
  "pool_size": 0,
  "pool_ready": 0,
  "pool_degraded": 0,
  "pool_draining": 3,
  "pool_unavailable": 0,
  "requests_total": 1420,
  "requests_active": 2,
  "version": "0.1.0"
}
```

#### GET /poolz

Requires `Authorization: Bearer <operator-key>`. Returns full pool
state (FR-O2). See FR-O2 for response schema.

**401 Unauthorized** if operator key missing or invalid.

#### GET /v1/pool/check

**Path:** `/v1/pool/check?provider_id=<provider_id>`

**Auth:** none. This is a publicly accessible operator/health surface,
not a buyer API surface.

**Response (200 OK):**

```json
{
  "provider_id": "<id>",
  "tier": "pinned",
  "state": "ready"
}
```

`tier` MUST be `"pinned"` or `"provisional"`. `state` MUST be one of
`"ready"`, `"draining"`, `"unavailable"`, or `"unknown"`.

Unknown providers return the same 200 shape with `"state": "unknown"`.

**Response (400 Bad Request):**

```json
{"error":{"code":"invalid_request","message":"provider_id is required"}}
```

**Response (429 Too Many Requests):**

```json
{"error":{"code":"rate_limited","message":"Pool check rate limit exceeded"}}
```

Purpose: SPEC-003 v0.6 `install.sh` self-test calls this endpoint after
first WebSocket connect to confirm that a freshly installed provider has
registered with the coordinator. It is also a generic provider-registered
health check.

This endpoint stays publicly accessible at `coordinator.streamvc.live`.
nginx routes `/v1/pool/check` to the coordinator directly, not to the
SPEC-006 gateway. SPEC-006 v0.3 gateway MUST NOT intercept this path.

#### POST /admin/blacklist

Requires `Authorization: Bearer <operator-key>`.

**Request:**
```json
{
  "provider_id": "m4-anon",
  "reason": "Provider operator requested removal"
}
```

The request key is the stable `provider_id`. For session-scoped
debugging, `assigned_id` may be sent INSTEAD — the coordinator accepts
either field name and resolves to the same pool entry. If both are sent,
`provider_id` takes precedence. If neither resolves to a current pool
entry, returns 404.

**Response (200):**
```json
{
  "status": "draining",
  "provider_id": "m4-anon",
  "assigned_id": "abc-123",
  "drain_sent": true
}
```

Both IDs are returned so the caller can correlate against either `/poolz`
column. `status: "draining"` reflects the immediate pool state after the
drain command is sent (matches AC-10 Phase 1); the entry transitions to
removed after the WebSocket closes (AC-10 Phase 2).

**404 Not Found** body:
```json
{"error": {"code": "provider_not_found", "message": "provider <id> not in pool"}}
```

The coordinator:
1. Sends `drain` to the provider.
2. Marks the provider as `draining` in the pool — stops routing
   immediately.
3. Closes the WebSocket within 60 seconds OR after `drain_status:
   complete`, whichever comes first.
4. Removes the provider from the pool on WebSocket close (per FR-P6
   normal disconnect path; not a special-case "immediate removal").
5. Logs the blacklist action at warn level.

`/poolz` continues to show the provider in `draining` state for the up-
to-60s window between drain command and WebSocket close. After close,
the entry is gone. AC-10 asserts this two-phase observable behavior
(not "removed immediately" — that would conflict with FR-P6's normal
disconnect-then-remove flow).

### 7.5. Admission state and operator endpoints (v1.1)

All endpoints in this section are mounted on `listen.provider_port`
(default 8444) per Finding F-3. All require
`Authorization: Bearer <operator-key>`.

#### GET /admin/provisional

Returns all current and historical provisional providers.

**Response (200):**
```json
{
  "provisional": [
    {
      "provider_id": "stranger-mac-001",
      "hostname": "Strangers-MacBook.local",
      "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "binary_version": "1.2.0",
      "first_seen_at": "2026-06-01T10:00:00Z",
      "last_seen_at": "2026-06-01T12:30:00Z",
      "total_requests_served": 42,
      "total_tokens_served": 8400,
      "currently_connected": true,
      "promoted_at": null
    }
  ],
  "summary": {
    "total_provisional": 3,
    "currently_connected": 2,
    "promoted": 1
  }
}
```

#### POST /admin/promote/{provider_id}

Promotes a provisional provider to pinned tier (runtime only — operator
must also add to `coordinator.yaml` for persistence across restarts).

**Response (200):**
```json
{
  "provider_id": "stranger-mac-001",
  "previous_tier": "provisional",
  "new_tier": "pinned",
  "note": "Runtime promotion only. Add to coordinator.yaml for persistence across restarts."
}
```

**Response (404):** `{"error": {"code": "provider_not_found", "message": "..."}}`
**Response (409):** `{"error": {"code": "already_pinned", "message": "..."}}`

#### POST /admin/reject/{provider_id}

Rejects a provider (any tier). Adds to `rejected_providers` and
disconnects.

**Request body (optional):**
```json
{"reason": "Suspected bad actor"}
```

**Response (200):**
```json
{
  "provider_id": "stranger-mac-001",
  "status": "rejected",
  "drain_sent": true,
  "note": "Future connections rejected with close code 4009."
}
```

**Tier state transitions:**
- Provisional → Pinned: `POST /admin/promote/{id}`. Updates routing
  weight to 1.0 immediately.
- Provisional → Rejected: `POST /admin/reject/{id}`. Sends drain,
  adds to `rejected_providers`, closes WS with 4009.
- Rejected → Provisional: Operator removes row from
  `rejected_providers` (SQL). Provider can reconnect.

### 7.6. SPEC-006 gateway deployment routing

When deployed alongside SPEC-006 v0.3 gateway, coordinator's buyer port
(8443) MUST be rebound from `0.0.0.0` to `127.0.0.1`. Public TLS
termination happens at nginx and the gateway. The provider port (8444)
MAY remain externally reachable if `coordinator.streamvc.live` serves
`/admin/*`, `/poolz`, `/healthz`, and `/ws/provider` directly with the
required auth controls.

The public route split is:

```nginx
# Rate limit and connection cap for /ws/provider (PG-2).
# Values are recommended defaults; operators MAY tune them, but the
# controls MUST run at the proxy before the coordinator performs the
# WebSocket upgrade.
limit_req_zone $binary_remote_addr zone=ws_provider_rate:10m rate=10r/m;
limit_conn_zone $binary_remote_addr zone=ws_provider_conn:10m;

# api.streamvc.live -> gateway (buyer surface)
location /v1/chat/completions { proxy_pass http://127.0.0.1:9443; }
location /v1/models { proxy_pass http://127.0.0.1:9443; }
location /v1/usage { proxy_pass http://127.0.0.1:9443; }
location /v1/feedback { proxy_pass http://127.0.0.1:9443; }
location /v1/status { proxy_pass http://127.0.0.1:9443; }

# coordinator.streamvc.live -> coordinator (operator + legacy buyer surface)
location /v1/pool/check { proxy_pass http://127.0.0.1:8443; }
location /healthz { proxy_pass http://127.0.0.1:8443; }
location /poolz { proxy_pass http://127.0.0.1:8444; }
location /admin/ { proxy_pass http://127.0.0.1:8444; }

# Provider WS - production invariants per § 7.7 PG-1 and PG-2.
location /ws/provider {
    limit_req zone=ws_provider_rate burst=5 nodelay;
    limit_conn ws_provider_conn 5;
    proxy_pass http://127.0.0.1:8444;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_read_timeout 86400;
}
```

### 7.7. Production invariants (public-launch gate)

The following invariants MUST be true before the coordinator is exposed
to public buyer traffic through any SPEC-006-style buyer-API gateway.
They are documented here as normative gates, not as v1.1.5 mandatory
defaults. Operators may continue to run the Tier 1 cooperative-trust
configuration for non-public deployments.

**PG-1: Provider authentication MUST be required.** Before any
public-buyer-facing service forwards requests to this coordinator,
`auth.require_provider_tokens` MUST be set to `true` in
`coordinator.yaml`. All pinned providers MUST have valid bearer tokens
issued and registered in the token store. Provisional providers MAY
continue without tokens per the provisional admission tier, but pinned
providers serving public traffic MUST be token-authenticated.

**PG-2: Pre-WS-upgrade rate limits MUST be enforced at the proxy
layer.** The nginx or equivalent reverse proxy in front of the
coordinator MUST enforce:
- Per-IP connection rate limit on `/ws/provider` before upgrade
  (recommended: 10/min).
- Per-IP concurrent connection cap on `/ws/provider` before upgrade
  (recommended: 5).
- Both controls MUST apply before the WebSocket upgrade handshake
  reaches the coordinator process.

**PG-3: Provisional admission MUST be rate-limited.** The coordinator's
existing `admission.provisional_admission_rate_per_hour` control (per
§ 7.1 F-2) provides this gate. The production value MUST be
conservative (recommended: 10/hour).

**PG-4: Unknown provider_id rejection MUST be aggressive in pinned-only
production mode.** When a hello includes an unknown `provider_id` and
`pinned_only=true`, the coordinator MUST close immediately and MUST NOT
fall through to provisional admission. For v1.1+ coordinators this uses
WS close 4009 `banned`; close 4002 `unknown_provider_id` remains retired
per § 7.1.

**PG-5: Provisional-admission spike alerting MUST be operator-facing.**
The coordinator MUST emit an operator-readable WARN log line, and MAY
also emit a webhook alert, when provisional admissions exceed 50% of
`admission.provisional_admission_rate_per_hour` in any rolling
10-minute window. The WARN event name MUST be
`provisional_admission_pressure`, with fields for the rolling-window
count, configured hourly limit, and threshold. This is the canary signal
for Sybil pressure.

Each invariant has an associated acceptance criterion in § 11.

---

## 8. Dependencies and references

### 8.1. Direct dependencies

| Dependency | License (SPDX) | Version pin | Purpose |
|---|---|---|---|
| Go | BSD-3-Clause | 1.22+ | Language runtime |
| [github.com/gobwas/ws](https://github.com/gobwas/ws) | MIT | v1.4.0 | WebSocket server (zero-alloc upgrade) |
| [github.com/go-chi/chi/v5](https://github.com/go-chi/chi) | MIT | v5.1.0 | HTTP routing (lightweight, stdlib-compatible) |
| [modernc.org/sqlite](https://gitlab.com/cznic/sqlite) | BSD-3-Clause | v1.33.0 | Pure-Go SQLite (no cgo, no C compiler needed) |
| [github.com/rs/zerolog](https://github.com/rs/zerolog) | MIT | v1.33.0 | Structured JSON logging |
| [github.com/google/uuid](https://github.com/google/uuid) | BSD-3-Clause | v1.6.0 | UUID generation for request IDs and assigned IDs |
| [gopkg.in/yaml.v3](https://github.com/go-yaml/yaml) | MIT | v3.0.1 | YAML config file parsing |

**Runtime requirements:** Go 1.22+, Linux amd64 (deployment target).
Cross-compilation from macOS: `GOOS=linux GOARCH=amd64 go build`.

**Deployment:** VPS at 165.22.182.207 (existing AntFeed VPS). The
coordinator runs on a different port than the existing AntFeed services.
Managed by systemd. TLS termination by Caddy reverse proxy.

**These are the required v1.0.1 pins.** The build session may bump only
with an explicit entry in `phase4-coordinator/implementation-notes.html`
documenting the new version, commit SHA, and a brief rationale (e.g.,
"security patch", "API I depend on shipped"). A bump without an entry is
a deviation that should be flagged on review.

### 8.2. Reference hygiene — strict clean-room for d-inference

This section is adapted from SPEC-001 § 7.2 with coordinator-specific
additions (Go-specific permitted dependencies and SQLite-related
references). The substantive policy is identical to SPEC-001 § 7.2.
Same policy applies
to the coordinator.

PROHIBITED references for this spec and the Phase 4 coordinator build:
- The d-inference GitHub repository
  (https://github.com/Layr-Labs/d-inference)
- Any d-inference source files, including the README and config files
- Any third-party analyses that quote or reproduce d-inference source
- Reverse-engineered analyses of any compiled Darkbloom binary

Reason: the DARKBLOOM LICENSE AGREEMENT (Eigen Labs, Inc., copyright
2026; SPDX NOASSERTION; canonical URL
https://github.com/Layr-Labs/d-inference/blob/master/LICENSE as
inspected 2026-05-27) explicitly prohibits in Section 3 the use of the
Software to "provide, operate, or enable any hosted service, platform,
marketplace, or product that offers AI inference coordination, private
inference services, or decentralized compute marketplace capabilities
that compete with Darkbloom." Mac Provider fits this description.

PERMITTED references:
- Darkbloom / Eigen Labs published academic papers (cite by URL/DOI)
- Darkbloom blog posts, conference talks, marketing pages (public)
- Third-party reviews that do NOT reproduce d-inference source
- SPEC-001 (this repo) — the Phase 3 binary spec
- Phase 1 results, Phase 2 decision criteria, harness.py
- OpenAI API reference
- WebSocket protocol RFC 6455
- Go standard library documentation
- Library documentation for dependencies listed in 8.1

Patent analysis: same as SPEC-001. Darkbloom holds patents around their
privacy/attestation model. Tier 1 of the coordinator does not implement
that model; Tier 2 hooks are designed-in but unimplemented. Patent risk
analysis for Tier 2 is deferred to its eventual SPEC.

If during implementation you are uncertain how Darkbloom solved a
problem, STOP and add an open question to
`implementation-notes.html`. Do not resolve it by reading their source.

### 8.3. Public spec sources

- SPEC-001 v1.1.1 (this repo) — Phase 3 binary protocol contract
- [OpenAI API reference](https://platform.openai.com/docs/api-reference/chat)
  — chat completions request/response schema
- [WebSocket protocol RFC 6455](https://tools.ietf.org/html/rfc6455)
  — wire protocol
- [HuggingFace model card schema](https://huggingface.co/docs/hub/model-cards)
  — model ID conventions

### 8.4. Internal sources

- `specs/SPEC-001-phase3-binary.md` — wire protocol contract
- `beta/DECISION_CRITERIA.md` — Phase 2 decision log
- `beta/harness.py` — first buyer implementation
- `beta/PHASE2_UPGRADED_PLAN.md` — routing mode evolution
- `results/REPORT.md` — Phase 1 evidence

---

## 9. SPEC-001 protocol compatibility

Coverage matrix listing every message in SPEC-001 section 6.5 and the
corresponding SPEC-002 coverage.

| SPEC-001 section 6.5 message | Direction | SPEC-002 coverage | Notes |
|---|---|---|---|
| `hello` | P->C | FR-P1, FR-P2, FR-P12, FR-P13 | Validate fields, check auth, check tier, register in pool |
| `hello_ack` | C->P | FR-P2 | Coordinator generates assigned_id, sets heartbeat interval |
| `heartbeat` | P->C | FR-P4, FR-P8 | Update pool state; detect wake events from heartbeat gaps |
| `state_update` | P->C | FR-P5 | Update state, adjust routing eligibility |
| `drain_status` | P->C | FR-P6 | Log progress, expect WebSocket close on "complete" |
| `preflight` | C->P | FR-P7, FR-B5, FR-R5 | Sent before routing large requests; 5s timeout |
| `preflight_ack` | P->C | FR-P7, FR-R5 | Accept or reject; rejection reasons per SPEC-001 |
| `drain` | C->P | FR-P9, FR-O3 | Sent on coordinator shutdown or operator blacklist |
| `warm_up` | C->P | FR-P8 | Sent after wake detection (heartbeat gap > 120s) |
| `nak` | P->C | § 7.1 (receive from provider) | Informational; coordinator logs at warn, does not disconnect provider |
| (WS close, not nak) | C→provider close | FR-P2, FR-P13 | Coordinator rejects invalid provider connections via WebSocket close codes 4001–4005 / 4429 (see FR-P13 table). SPEC-001 § 6.5 does not define a C→P `nak` direction; coordinator never sends one. |

**Verification:** Every message type in SPEC-001 section 6.5 maps to at least
one FR in SPEC-002. No gaps.

---

## 10. Phase 1 + Phase 2 findings that SPEC-002 must encode

### D1 — 502 vs 530 routing distinction

**Observation:** M4 sleep transition produced HTTP 502 (Cloudflare
tunnel up, mlx_lm.server down, persisted ~14 min) then HTTP 530 (full
tunnel disconnect). Tunnel API `conns_active_at` lagged actual
buyer-visible failure.

**SPEC-002 encoding:**
- **FR-P11** (failure mode distinction): Coordinator distinguishes
  WebSocket disconnect (530-equivalent) from HTTP 502 on routed
  requests. Different recovery strategies for each.
- **FR-P10** (disconnect detection): Grace period allows transient
  reconnection without pool removal.
- **Explicit rejection of `cfd_tunnel` polling.** The Phase 2 decision
  log suggested the coordinator could poll Cloudflare's tunnel API
  (`conns_active_at` field) to predict imminent provider drops. SPEC-002
  v1 deliberately does NOT do this. Rationale: (a) Cloudflare's API is
  rate-limited and would require credential management; (b) our own
  WebSocket health + per-request HTTP signals are sufficient for v1
  routing decisions; (c) `conns_active_at` lags actual buyer-visible
  failure by minutes anyway. Accepted failure mode: the coordinator may
  route to a provider in the brief window between `cloudflared` losing
  edge connection and the WebSocket close being detected (≤ heartbeat
  interval, ~15s). That window manifests as HTTP 502/530 on the routed
  request and is handled by FR-P11.
- **Literal HTTP 530** (Cloudflare-edge "tunnel daemon disconnected" code,
  observed directly on a routed buyer request) is treated as a distinct
  normative signal per FR-P11: mark `unavailable` immediately, log
  `state_update.reason = "http_530_observed"`, trigger a WebSocket
  liveness probe (5s ack timeout). Removed from pool until the
  WebSocket reconnects with fresh hello. This was previously open
  question OQ-1; resolved as normative in v1.0.2.

### D2 — Post-wake throughput dip

**Observation:** M4 post-wake first request was -12% throughput vs
baseline.

**SPEC-002 encoding:**
- **FR-P8** (warm_up dispatch): Coordinator detects wake events via
  heartbeat gap > 120s and sends `warm_up` command. Provider runs
  synthetic inference before accepting real traffic.
- Coordinator marks provider as `degraded` during warm-up even if the
  provider reports `ready` — Phase 2 data shows the first real request
  is still slower.

### D4 — Capacity-vs-quality routing tradeoff

**Observation:** Llama 3B on M1 8GB (22-25 tok/s) outperformed Qwen 7B
on M4 16GB (17-20 tok/s). Even TTFT favored M1.

**SPEC-002 encoding (scoped to "same model" tradeoff in v1):**
- **FR-R2** (buyer preference header): Among providers serving the
  SAME `model_id`, `X-MacProvider-Pref: fast` selects highest
  `throughput_tps_estimate`; `X-MacProvider-Pref: accurate` selects
  highest `model_params_b` (mostly relevant when one provider runs a
  quantization variant of the same family).
- **FR-R1** (default routing): Uses `throughput_tps_estimate` as a
  tie-breaker among same-model candidates, not `model_params_b`. The
  coordinator does NOT assume bigger hardware = faster.

**Explicitly deferred to SPEC-004 (smart router):** the broader D4
tradeoff — auto-routing between *different model families* (Llama 3B vs
Qwen 7B vs Qwen 14B) by latency/quality preference — requires a
model-class abstraction (aliases like `mlx-fast`, `mlx-balanced`,
`mlx-accurate`) that is properly a SPEC-004 concern. In v1, buyers
choose by exact `model_id` via `/v1/models` discovery, then optionally
refine within that model_id via `X-MacProvider-Pref`.

This means AC-9 in § 11 tests `X-MacProvider-Pref` behavior with two
providers serving the same `model_id` (a deliberately constrained test)
and explicitly does NOT validate cross-model routing.

### D5 — Timeline compression

**Classification:** Process-only. No coordinator behavior. Timeline
compressed from 14 days to 3 days. Phase 3 build started 11 days
sooner. No FR mapping.

### D6 — Phase 4 local acceptance findings (2026-05-28, v1.0.4)

**Source:** AC-2/AC-3/AC-6 closed locally via the Go mock-provider
toolkit at `phase4-coordinator/tools/mockprovider/`. All three findings
are operator-visible properties of the as-built coordinator, not bugs
and not FR changes — they are documented here so SPEC-002 prose matches
deployment reality.

**F-1 — Order-sticky routing under equal metrics.** The default sort
(`SlotsFree ASC, Throughput DESC, connected_at ASC`) is stable and slot
counts are decremented only on heartbeat tick. With two identical
providers in steady state, every primary key is equal and the
`connected_at` tertiary tiebreak fires every time, so all traffic routes
to whichever provider connected first until metrics diverge. See § 5
"Operator-visible behavior under equal metrics" for the normative
clarification. A future SPEC-004 may introduce a randomized tiebreak
with tolerance ε; v1 deliberately does not, to keep audit logs
reproducible.

**F-2 — Dynamic provider registration is not supported.** A `hello`
whose `provider_id` is not in `config.providers[]` is rejected with WS
close code **4002 `unknown_provider_id`** (already normative in § 7.1 +
FR-P13). The v1.0.4 clarification: this means every provider that may
ever connect to a given coordinator instance MUST be enumerated in the
operator's static config map before its first connection attempt;
adding a new provider requires editing the config and restarting (or
SIGHUP, when implemented). v1 does NOT support on-the-fly registration,
auto-discovery, or provider self-enrollment. This is by design —
operator approval of each `provider_id` is the v1 trust-pool admission
mechanism (per § 2 Tier 1 launch scope). SPEC-005/006 may relax this.

**F-3 — Operator endpoints live on the provider WS port.** All
operator-facing endpoints (`/healthz`, `/poolz`, `/admin/*`) are mounted
on `listen.provider_port` (default 8444), not `listen.buyer_port`
(default 8443). See § 7.4 "Port placement" for the normative
clarification.

**Why these surfaced in Phase 4 but not in spec audits.** All three
were latent in the audited spec text — F-1 was implicit in "stable sort
by connected_at" but not called out as an operator-visible behavior;
F-2 was implicit in close code 4002 but the operational implication for
deployment runbooks was not stated; F-3 was implicit in the architecture
diagram (§ 3) listing operator endpoints inside the same coordinator
box as the WebSocket server, but no section spelled out "same port as
provider WS." The Phase 4 local-acceptance harness made the operator
implications visible by forcing explicit decisions during test-script
authoring. Lesson for future specs: when an audit produces "this is
implicit in section X" answers to operator-runbook questions, prefer
to make the operator-visible behavior explicit in the user-facing
section (§ 5, § 7.4) even when it is a derived consequence of normative
text elsewhere.

### D7 — Static config-map relaxed to provisional tier (v1.1, from SPEC-003 v0.1)

**Source:** SPEC-002 v1.0.4 Finding F-2 + Decision log Entry 18.

**Finding:** F-2's "every provider_id must be in config.providers[]"
blocks supply-side growth beyond operator-vetted partners.

**SPEC-002 v1.1 encoding:**
- FR-P15 (three admission tiers): pinned / provisional / rejected.
- FR-P16 (rate limits): Prevents abuse of relaxed admission.
- § 7.1 (F-2 amendment): Formal relaxation.
- § 7.5 (operator endpoints): promote, reject.

### D8 — Coordinator drain MUST NOT terminate WS-tunneled inference

**Source:** Decision log Entry 15. phase3-binary v1.1.2 called exit()
on coordinator drain. Fixed in v1.1.3.

**SPEC-002 v1.1 encoding:**
- FR-P14 (WS relay): WS-tunneled providers complete in-flight
  inference before closing. Coordinator drain → provider finishes
  responses → WS close → reconnect.
- This is now load-bearing: WS-tunneled providers have no fallback
  path during coordinator drain (unlike pinned providers who serve
  via tunnel).

### D9 — model_id case-insensitive comparison

**Source:** Decision log Entry 18. M1 cron 404 storm from
case-sensitive model_id comparison.

**SPEC-002 v1.1 encoding:**
- § 5 routing algorithm: model match amended from exact string
  equality to case-insensitive comparison. Canonical form preserved
  in storage and GET /v1/models.

### D10 — Coordinator overhead for WS-tunneled path

**Source:** Decision log Entry 14. HTTP-forwarding adds <100 ms. WS-
tunneled adds estimated 10-50 ms on top (JSON serialization,
demultiplexing, SSE reassembly).

**SPEC-002 v1.1 encoding:**
- FR-P14 (WS relay): Validation method in AC-11 measures TTFT for
  WS-tunneled vs HTTP-forwarding. Delta SHOULD be <100 ms.

### D11 — Cross-service request correlation

**Source:** `specs/SPEC-CROSS-006-audit.md`, D-CROSS-3.

**SPEC-002 v1.1.4 encoding:**
Coordinator honors inbound `X-Request-ID` on buyer `/v1/*` requests,
records it in `request_log`, forwards it as the provider
`inference_request.request_id`, MAY generate a UUID v4 for legacy direct
traffic, and treats propagation gaps as audit findings.

---

## 11. Acceptance criteria

### Audit category I — production-config gates

**I.1 "Always-non-nil gate" anti-pattern.** Check for code paths gated
by a non-nil pointer or a boolean that is set to the gate-open value
unconditionally in every test setup. A test where the gate is in its
closed state must exist; if the closed-state behavior cannot be
exercised in unit tests, an integration test with the gate configured
closed MUST exist. The 2026-05-28 coordinator hotfix (Decision log Entry
19) is the reference example: `WithTokenValidator(tokenStore)` was
called unconditionally, `s.tokenValidator != nil` was therefore always
true, and no test exercised the "no token validator configured" path.
The production deployment with `auth.require_provider_tokens=false`
then caused unconditional pinned-provider rejection that no audit had
caught. Generalize: every conditional in production code needs at least
one test case for each branch, including the "this branch only fires
when the operator chooses the rare config" branch.

**I.2 "Default-permissive flag in production deployment" anti-pattern.**
Some configuration flags are correctly default-permissive for developer
convenience or backward-compatibility but MUST be set to the restrictive
value for any public production deployment. The flag's default is the
development or cooperative-trust setting; production deployment of
services exposing public interfaces MUST flip these flags as part of
the deployment runbook.

Reference example: `auth.require_provider_tokens` defaults `false` for
the Tier 1 cooperative pool but is a production invariant `true` per
§ 7.7 PG-1.

Auditors of future specs MUST identify default-permissive flags that
need production-invariant counterparts. If a flag's default differs
from its production-correct value, the spec MUST document the
production invariant explicitly using the § 7.7 pattern introduced in
v1.1.5.

**AC-1 through AC-10 must ALL pass for the coordinator to be considered
build-complete. No partial passes. No operator waivers without an
explicit waiver entry in `implementation-notes.html`.**

**AC-1. Provider lifecycle (mock).**
A mock Phase 3 binary connects via WebSocket, exchanges hello/hello_ack,
sends 5 heartbeats at the configured interval, receives a drain command
on coordinator shutdown, sends drain_status, and closes cleanly.

Run by: `phase4-coordinator/scripts/test-provider-lifecycle.sh`

**AC-2. Cooperative batch through coordinator.**
The buyer harness (`beta/harness.py`) with `tunnel_url` pointing at the
coordinator's HTTP endpoint runs a full cooperative batch against a pool
of 2 mock providers. Both mock providers respond with valid
SPEC-001-shaped responses. Result: 100% HTTP 200 from the coordinator.

Run by:
```
cd beta && python harness.py --config config-coord-test.yaml \
  --batch cooperative --verbose
```

The build session creates `config-coord-test.yaml` pointing
`tunnel_url` at the coordinator.

**AC-3. Adversarial workloads (mock pool).**
Adversarial workloads (`concurrent_burst_8way`, `retry_storm`,
`malformed_tool_call`) against a pool of 2 mock providers do not crash
the coordinator. `concurrent_burst_8way` traffic is distributed across
both providers. The coordinator remains healthy (passes `/healthz` with
200) within 10 seconds of workload completion. Zero HTTP 500 responses
from the coordinator.

Run by:
```
cd beta && python harness.py --config config-coord-test.yaml \
  --batch adversarial --verbose
```

**AC-4. Provider disconnect mid-buyer-request.**
During an in-flight streaming buyer request, the serving provider's
WebSocket disconnects. The coordinator returns a clean error SSE event
to the buyer and closes the stream (not a hang, not a silent retry).
The coordinator remains healthy.

Run by: `phase4-coordinator/scripts/test-provider-disconnect.sh`

**AC-5. Auth flow.**
1. Issue a token via `coordinator-cli issue-token`.
2. Connect a mock provider with the issued token — succeeds.
3. Revoke the token via `coordinator-cli revoke-token`.
4. Disconnect and reconnect the mock provider with the revoked token —
   rejected with 401.

Run by: `phase4-coordinator/scripts/test-auth-flow.sh`

**AC-6. Graceful SIGTERM drain.**
With 3 in-flight buyer requests (streaming), sending SIGTERM to the
coordinator causes it to:
1. Stop accepting new requests.
2. Send drain to all providers.
3. Complete all 3 in-flight requests (or timeout after 30s).
4. Exit with code 0.

No response truncation. No hang.

Run by: `phase4-coordinator/scripts/test-sigterm-drain.sh` — script the
build session must produce as part of AC delivery. Fires 3 streaming
requests, captures PID, sends SIGTERM, asserts all 3 complete and
process exits 0 within 35s.

**AC-7. 502 degraded recovery.**
1. Mock provider is serving traffic normally.
2. Configure mock provider to return HTTP 502 on the next request.
3. Coordinator marks provider as `degraded`.
4. After 30s backoff, coordinator sends preflight — mock provider
   accepts.
5. Coordinator marks provider as `ready`, resumes routing.

Run by: `phase4-coordinator/scripts/test-degraded-recovery.sh`

**AC-8. 530 reconnection.**
1. Mock provider is serving traffic normally.
2. Mock provider closes WebSocket unexpectedly (no drain).
3. Coordinator marks provider as `unavailable`.
4. Within grace period, mock provider reconnects with new hello.
5. Coordinator registers provider as `ready`, resumes routing.
6. After grace period (second test): coordinator removes provider
   from pool.

Run by: `phase4-coordinator/scripts/test-reconnection.sh`

**AC-8b. Warm-up dispatch on wake.**
1. Mock provider connects, runs normally for 2 minutes (heartbeats every 30s).
2. Mock provider stops sending heartbeats for 130 seconds (>120s gap,
   simulates Mac sleep).
3. Mock provider resumes heartbeats.
4. Assert: coordinator sends `{"type": "warm_up"}` to the provider
   within 5s of the resumption heartbeat.
5. Assert: coordinator marks provider as `degraded` until either (a) the
   mock provider sends `state_update: ready`, or (b) 60s elapse with
   continuous heartbeats — whichever first.
6. Assert: while provider is `degraded`, buyer requests for that
   provider's model are NOT routed to it (FR-R4 filters to `state=ready`
   only). If no other ready provider serves the same model, buyer
   receives 503 `no_provider_available` until this provider exits
   degraded state.

Run by: `phase4-coordinator/scripts/test-warmup-dispatch.sh`

**AC-9. Capacity preference routing.**
Pool has 2 mock providers:
- Provider A: Llama 3B, throughput 25 tok/s, model_params_b 3.0
- Provider B: Qwen 7B, throughput 18 tok/s, model_params_b 7.0

Both serve the same model ID for testing purposes.

1. Request with `X-MacProvider-Pref: fast` routes to Provider A.
2. Request with `X-MacProvider-Pref: accurate` routes to Provider B.
3. Request with no preference routes per utilization (FR-R1).

Run by: `phase4-coordinator/scripts/test-routing-preference.sh`

**AC-10. Operator endpoints.**
1. `GET /healthz` returns 200 with pool size.
2. `GET /poolz` without auth returns 401.
3. `GET /poolz` with valid operator key returns 200 with provider list
   showing both `provider_id` (stable) and `assigned_id` (session) per
   entry.
4. `POST /admin/blacklist` with a valid `provider_id` returns 200 with
   `{status: "draining", provider_id, assigned_id, drain_sent: true}`.
5. **Two-phase observable behavior** (per § 7.4):
   - **Phase 1 (immediate):** within 1s of the blacklist POST, the
     provider's `state` in `/poolz` transitions to `draining`. The
     provider is no longer routed to (FR-R4 filters out non-`ready`).
   - **Phase 2 (deferred):** within 60s — or sooner if the mock provider
     sends `drain_status: complete` — the provider's WebSocket closes
     and the entry disappears from `/poolz` entirely.
6. POSTing `/admin/blacklist` with an unknown `provider_id` returns 404.

Run by: `phase4-coordinator/scripts/test-operator-endpoints.sh`

**AC-11. Provisional admission.**
Connect a mock provider with `provider_id` NOT in `config.providers[]`
and NOT in `rejected_providers`. Coordinator responds with `hello_ack`
containing `tier: "provisional"`. `GET /poolz` shows the provider with
`tier: "provisional"`. Buyer requests are routed to it (with reduced
weight).

Run by: `phase4-coordinator/scripts/test-provisional.sh`

**AC-12. Provisional rate limit.**
Configure `admission.provisional_rate_per_hour: 10`. Connect 11
provisional providers within 60 seconds. First 10 get `hello_ack`.
11th gets WS close code 4008.

Run by: `phase4-coordinator/scripts/test-rate-limit.sh`

**AC-13. admin/promote.**
Connect a provisional provider. `POST /admin/promote/{provider_id}`.
Provider's tier changes to pinned in `/poolz`. Routing weight upgrades
to 1.0 immediately.

Run by: `phase4-coordinator/scripts/test-promote.sh`

**AC-14. admin/reject.**
Connect a provisional provider. `POST /admin/reject/{provider_id}`.
Provider receives drain. WS closes. `provider_id` in
`rejected_providers`. Subsequent hello → WS close 4009.

Run by: `phase4-coordinator/scripts/test-reject.sh`

**AC-15. Routing-mode fallback on nak.**
Coordinator dispatches `inference_request` to a mock provider that
responds `nak code=unknown_message_type`. Coordinator marks provider
routing mode `http_forwarding_only`, returns HTTP 503 to buyer.
Subsequent requests to that provider's model are NOT dispatched via
§ 6.6 for the remainder of the WS session.

Run by: `phase4-coordinator/scripts/test-nak-fallback.sh`

**AC-X1 (PG-1). Public-launch provider token gate.**
Deploy the coordinator with `auth.require_provider_tokens=true`.
A pinned provider WebSocket connection without a valid bearer token MUST
receive WS close 4005 `invalid_token` within 2s of upgrade.

Run by:
```
wscat -c wss://coordinator.streamvc.live/ws/provider \
  --execute 'hello-with-pinned-provider-id.json'
```

Expected result: close code 4005 before `hello_ack`. Repeat with
`-H 'Authorization: Bearer <valid-token>'` and the same pinned
`provider_id`; expected result is `hello_ack`.

**AC-X2 (PG-2). Pre-WS-upgrade proxy controls.**
With the § 7.6 proxy limits configured, more than 10 WebSocket upgrade
attempts per minute from one source IP MUST receive HTTP 429 from the
proxy before the request reaches the coordinator process.

Run by:
```
for i in $(seq 1 16); do
  curl -sk -o /dev/null -w '%{http_code}\n' \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    https://coordinator.streamvc.live/ws/provider
done
```

Expected result: at least one `429` after the configured burst is
exhausted, and coordinator logs contain no matching provider-upgrade
attempt for the rate-limited requests.

**AC-X3 (PG-3). Provisional admission rate limit.**
With `admission.provisional_admission_rate_per_hour=10`, the 11th new
provisional provider admission in one hour MUST be rejected with WS
close 4008 `provisional_rate_limited`.

Run by: `phase4-coordinator/scripts/test-rate-limit.sh`

Expected result: first 10 unknown provider IDs get `hello_ack`; the
11th gets close code 4008.

**AC-X4 (PG-4). Pinned-only unknown-provider rejection.**
With `admission.pinned_only=true`, a hello with an unknown `provider_id`
MUST receive WS close 4009 `banned` within 2s. Provisional admission
MUST NOT fire, and no provisional record may be created.

Run by:
```
phase4-coordinator/scripts/test-provisional.sh \
  --pinned-only --expect-close-code 4009 --expect-no-record
```

Expected result: close code 4009 and no new row in the provisional
provider listing.

**AC-X5 (PG-5). Provisional-admission pressure alert.**
When provisional admissions exceed 50% of
`admission.provisional_admission_rate_per_hour` in any rolling
10-minute window, the coordinator MUST emit a WARN log line with event
name `provisional_admission_pressure`.

Run by:
```
phase4-coordinator/scripts/test-rate-limit.sh --count 6 --limit 10
journalctl -u macprovider-coordinator --since -10m \
  | grep 'provisional_admission_pressure'
```

Expected result: a WARN-level log line containing
`provisional_admission_pressure`, `rolling_10m_count`, `limit_per_hour`,
and `threshold_count`.

---

## 12. Open questions for operator

**Defaults already chosen (no longer open):**

- **Provider endpoint discovery:** static `provider_id → endpoint_url`
  config map in coordinator. No SPEC-001 amendment. (See § 3, FR-P3,
  FR-P12.)
- **Provider auth on WebSocket upgrade:** optional in v1; trust comes
  from static config admission. (See FR-P1, FR-P12.)
- **TLS in front of coordinator:** Caddy with Let's Encrypt automatic
  HTTPS. (See NFR-Security in § 6.)
- **Provider token format (when used in path B):** opaque 32-byte
  random, hex-encoded. (See § 7.3.)
- **SQLite backup:** daily file copy via cron + rsync to operator. (See
  § 7.3 storage + NFR-Reliability.)
- **Buyer auth in v1:** none; trust delegated to Antseed seller
  integration (SPEC-003). Buyer API keys are SPEC-006 scope.

No open questions remain from v1.0.x. v1.0.2 resolved all prior open items into
normative requirements (see FR-P11 for the HTTP 530 handling that was
previously OQ-1).

**OQ-6. How to surface tier=provisional to buyers.**
Current design: the tier is invisible to buyers. A buyer cannot
distinguish a response from a pinned provider vs a provisional
provider. Should the coordinator add an `X-MacProvider-Tier` response
header?

**Current position:** Do NOT surface tier to buyers in v1. Buyers
should not need to care — the coordinator's routing weight handles
quality-of-service differentiation. If a buyer wants to avoid
provisional providers, they can pin to a specific provider via
`X-MacProvider-Provider`. Adding a tier header creates an implicit
SLA promise that is premature for v1.

**OQ-7. Version enforcement for provisional providers.**
Should the coordinator refuse to route to providers running versions
older than `recommended_binary_version`? Current position: no
enforcement in v1 — the nudge is informational. Enforcement risks
rejecting all provisional providers simultaneously on version bump.

**OQ-8. Automatic persistence of promotions.**
`POST /admin/promote` (§ 7.5) is runtime-only — the operator must
also edit `coordinator.yaml`. Should the coordinator automatically
append to `coordinator.yaml`?

**Current position:** No auto-edit of config files in v1. Config
files are operator-owned and may be version-controlled. The
coordinator should not mutate them. The operator adds promoted
providers to `coordinator.yaml` manually (same workflow as today's
pinned provider onboarding, but only for the subset the operator
chooses to promote). A future version may add a `coordinator-cli
promote --persist` flag that appends to the config file.

**OQ-9. Provisional provider identity verification.**
A provisional provider self-reports its `provider_id`. Nothing prevents
a malicious actor from impersonating another provider's ID. In the
pinned tier, the operator controls ID assignment. In the provisional
tier, the provider generates its own ID (UUID from `install.sh`).

**Current position:** For v1, self-reported UUIDs are sufficient
because: (a) UUIDs are 128-bit random — collision probability is
negligible, (b) the coordinator tracks `provider_id` → WS connection,
so a duplicate ID would close the older connection (same as FR-P2
step 4), (c) provisional providers have reduced routing weight and
request quotas, limiting the impact of impersonation. Stronger
identity verification (e.g., device attestation) is a Tier 2 concern.

**OQ-10. Coordinator-side WS write buffer sizing.**
FR-P19 specifies 64 messages as the coordinator-side write buffer per
provider. This is a starting estimate. In practice, the buffer should
rarely fill because the coordinator only sends `inference_request` (at
most N concurrent, where N = `max_concurrency`, typically 1) and
`cancel_request` (at most one per outstanding request). The 64-message
buffer is ~60× the expected steady-state depth.

**Scope:** This OQ concerns the **coordinator-side** buffer only
(per-provider outbound message queue in the Go coordinator). The
provider-side write buffer sizing is SPEC-001 v1.2.4 OQ-5.

**Current position:** 64 is a conservative default. Tune based on
production telemetry. Add a `/poolz` field showing per-provider
write buffer depth for operator visibility.

---

## 13. Implementation hand-off

### Step sequence for the build session

**Step 1. Init Go module.**
Initialize `phase4-coordinator/` as a Go module. Add dependencies per
Section 8.1 version pins. Verify the module compiles an empty main.
Deliverable: `go build ./...` succeeds.

**Step 2. WebSocket /ws/provider endpoint + hello/hello_ack.**
Implement the WebSocket server that accepts provider connections.
Parse `hello`, validate fields, generate `assigned_id`, respond with
`hello_ack`. Reject invalid hello by closing the WebSocket with FR-P13 close codes (4001 for invalid_hello, 4002 for unknown_provider_id, 4003 for tier_unsupported, 4004 for version_unsupported). Deliverable: mock provider
connects, exchanges hello/hello_ack.

**Step 3. Pool registry + heartbeat handling.**
Implement the pool data structure (concurrent-safe map). Process
`heartbeat` messages, update pool entries. Implement staleness
detection (warn on 1.5x heartbeat interval). Deliverable: pool shows
connected providers with live capacity data.

**Step 4. State machine for provider states.**
Implement state transitions from `state_update` messages. Implement
routing eligibility rules (only `ready` + `slots_free > 0`).
Implement wake detection (heartbeat gap > 120s -> warm_up). Implement
disconnect detection + grace period. Deliverable: provider state
transitions logged and reflected in pool.

**Step 5. /v1/models aggregation.**
Implement the buyer HTTP server. `GET /v1/models` returns aggregated
model list from pool. Deliverable: `curl /v1/models` returns JSON
with models from connected mock providers.

**Step 6. /v1/chat/completions non-streaming routing.**
Implement request validation (SPEC-001 section 6.2 subset), routing
algorithm (Section 5), request forwarding to provider HTTP endpoint,
response relay. Deliverable: non-streaming request routed to provider,
response returned to buyer.

**Step 7. SSE streaming pass-through.**
Add `stream: true` support. Implement SSE relay with immediate
flushing. Handle provider disconnect mid-stream (error event +
[DONE]). Deliverable: streaming response relayed chunk-by-chunk.

**Step 8. Preflight + capacity routing.**
Implement preflight send/receive over WebSocket. Integrate with routing
algorithm (skip for < 4096 estimated tokens, required above). Implement
buyer preference headers. Deliverable: preflight rejects correctly,
preference headers route as expected.

**Step 9. Auth (token issuance CLI + validation).**
Implement `coordinator-cli` subcommands: `issue-token`, `revoke-token`,
`list-tokens`. Implement bearer token validation on WebSocket upgrade.
Deliverable: token issued, used to connect, revoked, connection
rejected.

**Step 10. Operator endpoints (/healthz, /poolz, /admin/blacklist).**
Implement all three operator endpoints. Implement operator key auth for
/poolz and /admin/*. Deliverable: endpoints return correct JSON.

**Step 11. Acceptance testing.**
Run AC-1 through AC-10. Fix issues. Write test scripts in
`phase4-coordinator/scripts/`. Create `config-coord-test.yaml` for
the harness. Deliver a coordinator that passes all acceptance criteria.

### File structure (expected)

```
phase4-coordinator/
+-- go.mod
+-- go.sum
+-- cmd/
|   +-- coordinator/
|   |   +-- main.go                  # Entry point, flag parsing, startup
|   +-- coordinator-cli/
|       +-- main.go                  # Token management CLI
+-- internal/
|   +-- config/
|   |   +-- config.go                # YAML config + flag overrides
|   +-- pool/
|   |   +-- pool.go                  # Pool registry (concurrent-safe map)
|   |   +-- provider.go              # Provider entry struct
|   |   +-- state.go                 # State machine (ready/busy/degraded/...)
|   +-- ws/
|   |   +-- server.go                # WebSocket server, upgrade handler
|   |   +-- handler.go               # Message dispatch (hello, heartbeat, etc.)
|   |   +-- messages.go              # Message type definitions (JSON structs)
|   |   +-- wake.go                  # Wake detection + warm_up dispatch
|   +-- router/
|   |   +-- router.go                # Routing algorithm (Section 5)
|   |   +-- preflight.go             # Preflight send/receive
|   |   +-- estimator.go             # Token estimation heuristic
|   +-- buyer/
|   |   +-- server.go                # Buyer HTTP server
|   |   +-- models.go                # GET /v1/models handler
|   |   +-- completions.go           # POST /v1/chat/completions handler
|   |   +-- validator.go             # Request validation (SPEC-001 s6.2)
|   |   +-- relay.go                 # Response relay (JSON + SSE)
|   +-- auth/
|   |   +-- tokens.go                # Token issuance, validation, revocation
|   +-- operator/
|   |   +-- healthz.go               # GET /healthz
|   |   +-- poolz.go                 # GET /poolz
|   |   +-- blacklist.go             # POST /admin/blacklist
|   +-- store/
|   |   +-- sqlite.go                # SQLite setup, migrations, request_log
|   +-- logging/
|       +-- logger.go                # zerolog setup
+-- scripts/
|   +-- test-provider-lifecycle.sh   # AC-1
|   +-- test-provider-disconnect.sh  # AC-4
|   +-- test-auth-flow.sh            # AC-5
|   +-- test-degraded-recovery.sh    # AC-7
|   +-- test-reconnection.sh         # AC-8
|   +-- test-routing-preference.sh   # AC-9
|   +-- test-operator-endpoints.sh   # AC-10
+-- implementation-notes.html        # Populated by build session
+-- coordinator.yaml.example         # Example config file
```

### Configuration file schema (coordinator.yaml)

```yaml
listen:
  buyer_port: 8443           # HTTP port for buyer API
  provider_port: 8444        # WebSocket port for provider connections
  bind_address: "127.0.0.1"  # Listen address; TLS terminated by Caddy in front

pool:
  heartbeat_interval_s: 30
  disconnect_grace_period_s: 30
  wake_gap_threshold_s: 120
  degraded_backoff_s: 30      # Initial backoff after 502/504
  degraded_max_retries: 3     # After N consecutive failed recovery preflights, mark unavailable
  degraded_probe_after_502: true   # Send recovery preflight after 502/504 backoff (default true)
                                    # Set to false to skip auto-recovery probing for debug

routing:
  preflight_threshold_tokens: 4096   # Skip preflight for prompts under this size
  preflight_timeout_s: 5
  request_timeout_s: 300

auth:
  operator_key: "<required>"   # Bearer token for /poolz and /admin/blacklist

storage:
  db_path: "coordinator.db"
  snapshot_interval_s: 300

logging:
  level: "info"
  format: "json"

# Provider endpoint map (required; coordinator refuses to start if empty)
providers:
  - provider_id: "m4-anon"
    endpoint_url: "https://m4.streamvc.live"
    display_name: "M4 partner (Qwen 7B)"    # optional; used in /poolz
  - provider_id: "m1-anon"
    endpoint_url: "https://m1.streamvc.live"
    display_name: "M1 partner (Llama 3B)"
```

**Startup validation rules** (coordinator exits with error on any failure):
- `providers` must be non-empty (no providers = no routing possible).
- Each `provider_id` must be unique across the list (duplicates rejected).
- Each `endpoint_url` must be a syntactically valid `https://` URL (the
  v1 coordinator only forwards over TLS).
- Each `provider_id` must match the regex `[a-zA-Z0-9_.-]{1,64}`
  (filesystem-and-URL-safe identifier).
- `auth.operator_key` must be set and non-empty (operator endpoints
  require auth).

An example `coordinator.yaml.example` is included in the repo. The
example MUST be kept in sync with this schema as part of the build
session deliverable.

(Note: `routing.retry_on_502` from earlier drafts was renamed to
`pool.degraded_probe_after_502` to reflect what it actually controls —
the degraded recovery probe behavior, not buyer-visible retry. The
buyer never sees coordinator-managed retry in v1 per FR-B7.)

---

## Appendix A — References used during spec writing

| Source | What was taken |
|---|---|
| `specs/SPEC-001-phase3-binary.md` v1.1.1 | Full wire protocol (section 6.5), request schema (section 6.2), health states (FR-15), capacity fields (FR-17), handshake fields, preflight reasons, drain lifecycle |
| `HANDOFF.md` | Project context: pooled Mac network architecture, VPS at 165.22.182.207, Antseed seller integration, Darkbloom differentiation, coordinator design intent |
| `beta/PHASE2_UPGRADED_PLAN.md` | Routing mode evolution table (mirror -> specialization -> stress), pre-committed decision criteria concept |
| `beta/DECISION_CRITERIA.md` | Decision log D1 (502/530 routing), D2 (post-wake dip), D4 (capacity-vs-quality routing), D5 (timeline compression), pre-launch baselines |
| `beta/harness.py` | First buyer behavior: SSE parsing, workload runner, SQLite logging, the HTTP contract the coordinator must serve |
| `results/REPORT.md` | Phase 1 evidence: VPS SSH tunnel validation (Step 6.7), tunnel latency data (Step 7), Metal OOM at ~26K tokens, SSE quirks, concurrent serving |
| `phase3-binary/implementation-notes.html` | Scaffold format for implementation-notes.html |
| OpenAI API reference | Chat completions request/response schema, SSE streaming format, error envelope, models endpoint |
| WebSocket protocol RFC 6455 | Upgrade handshake, close codes, frame format |

**Clean-room note:** No d-inference source files were read during spec
writing. The coordinator design is informed by the project's own Phase 1
and Phase 2 findings, SPEC-001's wire protocol, and standard
WebSocket/HTTP patterns. This is documented here for transparency per
the strict clean-room policy inherited from SPEC-001 section 7.2.
