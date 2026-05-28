# SPEC-003 — Open Onboarding: WS-Tunneled Inference, Dynamic Admission, Distribution & Lifecycle

**Version:** 0.1.0 (2026-05-28, initial draft)
**Depends on:** SPEC-001 v1.1.4, SPEC-002 v1.0.4

---

## 0. Operator-paste invocation block

```
Implement SPEC-003. As you work, maintain a running
phase5-onboarding/implementation-notes.html that captures anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

The Mac Provider network works. Two providers, two models, real
multi-model routing, ~2.5 s end-to-end inference through
`https://coordinator.streamvc.live`. But the supply side is
operator-locked. A stranger reading a GitHub README today cannot
become a provider without three operator interventions:

1. **Subdomain on `streamvc.live`** — the operator must create a DNS
   record and configure a Cloudflare tunnel pointing at the
   contributor's Mac.
2. **Cloudflare tunnel token** — the operator must issue and deliver a
   tunnel credential.
3. **`config.providers[]` enumeration** — the operator must SSH into
   the coordinator VPS, add the new `provider_id` and `endpoint_url`
   to `coordinator.yaml`, and restart the coordinator (SPEC-002 v1.0.4
   Finding F-2).

This works for 2 vetted partners. It breaks at 5. It is impossible at
50.

SPEC-003 is the architectural pivot to make Mac Provider a
**downloadable product**. After SPEC-003 ships, the user experience
for joining the network is:

```bash
curl -fsSL https://get.streamvc.live/install.sh | bash
```

One line. Zero operator action. Provider in the pool within 2 minutes
(excluding the multi-GB model download on first run).

Four tightly-coupled changes make this work, and they MUST ship as one
spec because each fails without the others:

- **Part A — WS-tunneled inference.** Inference traffic flows through
  the existing provider WebSocket instead of HTTPS-to-public-URL.
  Provider needs zero inbound network — only outbound WSS to the
  coordinator. Works behind any NAT, firewall, hotspot.
- **Part B — Dynamic admission.** Relax SPEC-002 v1.0.4 Finding F-2
  (the "every `provider_id` must be in `config.providers[]`"
  invariant) with a three-tier model: pinned (M4/M1 today),
  provisional (strangers accepted automatically with lower routing
  weight), rejected (banned).
- **Part C — Distribution + lifecycle.** GitHub Releases, curl-pipe-bash
  install script at `get.streamvc.live`, `macprovider-cli update`
  subcommand, launchd plist for reboot survival, optional
  coordinator-advertised version nudge.
- **Part D — Onboarding UX.** The README flow, `install.sh` prompts,
  first-run behavior, status check, uninstall.

Decision log Entry 18 (2026-05-28) is the direct rationale for why
this spec exists: "the network works, the product doesn't yet exist."

---

## 2. Scope

### In scope (Parts A–D, shipped together)

**Part A — WS-tunneled inference:**
- New WS message types: `inference_request`, `inference_response_chunk`,
  `inference_response_end`, `cancel_request`
- Per-provider multiplexing of N concurrent requests over one WS
- Backpressure: bounded WS write buffers, coordinator-side response
  timeouts
- Cancellation propagation: buyer disconnect → coordinator detects →
  provider aborts inference
- SSE-to-WS and WS-to-SSE translation at the coordinator
- Backward-compatible detection: `endpoint_url` in hello → legacy
  HTTP-forwarding; absent → WS-tunneled

**Part B — Dynamic admission:**
- Three tiers: pinned, provisional, rejected
- Automatic provisional admission for unknown `provider_id` values
- Rate limits on provisional admission
- Routing weight multiplier by tier
- New WS close codes: 4007, 4008, 4009
- Persistence of provisional admissions in coordinator.db
- New operator endpoints: `GET /admin/provisional`,
  `POST /admin/promote/{provider_id}`,
  `POST /admin/reject/{provider_id}`

**Part C — Distribution + lifecycle:**
- GitHub Releases with tagged binaries, checksums, release notes
- `install.sh` at `get.streamvc.live`
- `macprovider-cli update` subcommand (self-update)
- `macprovider-cli status` subcommand (local + remote state)
- `macprovider-cli uninstall` subcommand (remove everything)
- launchd plist for reboot survival
- Coordinator-advertised `recommended_binary_version` in `hello_ack`

**Part D — Onboarding UX:**
- README-driven setup flow
- `install.sh` interactive prompts (model selection, coordinator URL)
- First-run self-test with user-visible output
- `macprovider-cli status` for contributor self-diagnostics

### Out of scope

- **Antseed seller integration** — deferred to SPEC-007. The
  coordinator's buyer HTTP API is already wire-compatible.
- **Smart router** — deferred to SPEC-004 (sticky caching, model
  aliases, cross-model routing).
- **Rewards / billing** — deferred to SPEC-005 (contributor payout
  mechanism).
- **Tier 2 attestation** — no privacy/attestation features in this
  spec.
- **Buyer-side privacy** — Tier 2 concern.
- **Changes to the buyer-facing HTTP API** — `POST /v1/chat/completions`,
  `GET /v1/models`, `GET /healthz` are unchanged in observable behavior.
  All changes are internal to the coordinator ↔ provider path.
- **Forcing pinned providers to migrate** — M4 (v1.1.4) and M1
  (v1.1.3) continue to work via their existing Cloudflare tunnels with
  zero required changes.

---

## 3. Architecture overview

### Two coexisting inference paths

```
                          BUYERS (HTTPS)
                              |
                     TLS termination (nginx)
                              |
    +----------------------------------------------------------+
    |                  COORDINATOR (Go)                         |
    |                                                          |
    |   BUYER SIDE                    PROVIDER SIDE            |
    |   ----------                    -------------            |
    |   Buyer HTTP Server (:8443)     Provider WS Server(:8444)|
    |         |                              |                 |
    |   Request Validator             Hello Handler            |
    |         |                       (admission tier check)   |
    |         |                              |                 |
    |         +------> Pool Registry <-------+                 |
    |         |        (provider_id -> state, tier, model)     |
    |         v                                                |
    |   Router (model match, capacity, tier-weight, buyer pref)|
    |         |                                                |
    |    +----+----+                                           |
    |    |         |                                           |
    |    v         v                                           |
    |  PATH A    PATH B                                        |
    |  (legacy)  (WS-tunneled)                                 |
    |    |         |                                           |
    |    v         v                                           |
    |  HTTP GET    WS frame                                    |
    |  provider    inference_request                            |
    |  tunnel      ─────────────>                              |
    |  (HTTPS)     inference_response_chunk                     |
    |    |         <─────────────                              |
    |    |         inference_response_end                       |
    |    |         <─────────────                              |
    |    v         v                                           |
    |   Response Relay        Request Logger (SQLite)           |
    |   (SSE / JSON)                                           |
    |                                                          |
    |   Operator: /healthz  /poolz  /admin/*                   |
    |   Storage:  SQLite (WAL) — tokens, request_log,          |
    |             provisional_providers, pool_snapshots         |
    +----------------------------------------------------------+
              ^                    ^                ^
              |                    |                |
         WebSocket            WebSocket        WebSocket
         (outbound)           (outbound)       (outbound)
              |                    |                |
           Mac #1              Mac #2           Mac #N
         (M1 8GB)            (M4 16GB)       (stranger)
         PINNED               PINNED         PROVISIONAL
         endpoint_url         endpoint_url   WS-tunneled
         in hello             in hello       no endpoint_url
```

### Path selection logic

The coordinator determines the inference path at provider registration
time based on the presence of `endpoint_url` in the `hello` message:

| `hello` contains `endpoint_url`? | Admission tier | Inference path | Notes |
|---|---|---|---|
| Yes (non-empty URL) | Pinned (from `config.providers[]`) | PATH A: HTTP-forwarding to `endpoint_url` | Legacy path. M4/M1 today. |
| Yes (non-empty URL) | Provisional | PATH A: HTTP-forwarding to self-reported URL | Provider claims its own tunnel. Coordinator verifies with a health probe. |
| No (absent or null) | Provisional | PATH B: WS-tunneled inference | Default for new installs. No inbound network required. |
| No (absent or null) | Pinned (operator promoted) | PATH B: WS-tunneled inference | Operator promoted a WS-tunneled provider to pinned. |

**SPEC-001 amendment.** The `hello` message gains an OPTIONAL
`endpoint_url` field (type: string or null). Absence or null means
"I have no public URL; route inference through this WebSocket."
Presence of a non-empty string means "I am reachable at this HTTPS
URL; use HTTP-forwarding." This field is backward-compatible: existing
v1.1.4 binaries do not send it, so they are treated as having no
`endpoint_url` — but because they are in `config.providers[]` (pinned),
the coordinator falls back to the static config map's `endpoint_url`.
Net: zero changes required for existing binaries.

**Backward-compatibility detection rule (normative):**

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
    tier = provisional  (subject to admission rate limits)
    if hello.endpoint_url is present and non-empty:
        inference_path = HTTP_FORWARDING(hello.endpoint_url)
        # coordinator MUST verify reachability before first route
    else:
        inference_path = WS_TUNNELED
```

### Admission tier interaction with routing

The routing algorithm (SPEC-002 § 5) gains a tier-based weight
multiplier applied after the existing sort. The multiplier affects
candidate ranking, not filtering — provisional providers are still
eligible for routing, but ranked lower than equivalent pinned providers.

| Tier | Weight multiplier | Effect |
|---|---|---|
| Pinned | 1.0 | No penalty. Full routing priority. |
| Provisional | 0.3 | Ranked behind any pinned provider with the same model. |
| Rejected | N/A | Never in pool. WS closed on hello. |

The multiplier is applied as: `effective_throughput = throughput_tps_estimate * tier_weight`. This means a provisional provider advertising 25 tok/s is ranked equivalently to a pinned provider advertising 7.5 tok/s. The multiplier is configurable in `coordinator.yaml` (`routing.provisional_weight`, default 0.3).

**Rationale:** The 0.3 default means a provisional provider must be
roughly 3× faster than a pinned provider to be preferred. This ensures
operator-vetted providers handle the majority of traffic while
strangers build trust. The operator can promote high-performing
provisional providers to pinned via `POST /admin/promote/{provider_id}`.

---

## 4. Functional requirements

### Part A — WS-tunneled inference

**FR-A1. Inference request delivery over WebSocket.**
When the coordinator routes a buyer request to a WS-tunneled provider,
the coordinator sends an `inference_request` message over the
provider's existing WebSocket connection. The message contains the full
buyer request body (serialized as a JSON string within the envelope),
the coordinator-assigned `request_id`, and streaming preference. The
provider receives the message, runs inference locally, and returns
results over the same WebSocket via `inference_response_chunk` and
`inference_response_end` messages.

**FR-A2. Streaming response relay.**
For `stream: true` buyer requests, each `inference_response_chunk` WS
message from the provider is translated by the coordinator into one
SSE `data:` line and flushed to the buyer immediately. The coordinator
MUST NOT buffer chunks — each chunk is relayed as it arrives to
preserve time-to-first-token fidelity. The final
`inference_response_end` message triggers the coordinator to emit
`data: [DONE]\n\n` and close the buyer's SSE stream.

**FR-A3. Non-streaming response relay.**
For `stream: false` buyer requests, the coordinator accumulates all
`inference_response_chunk` messages until `inference_response_end`
arrives, assembles the complete response JSON, and returns it as a
single HTTP response body to the buyer. If the assembled response is
malformed or incomplete (e.g., provider disconnected before sending
`inference_response_end`), the coordinator returns HTTP 502 to the
buyer.

**FR-A4. Request ID correlation.**
Every `inference_request` carries a `request_id` (UUID). All
corresponding `inference_response_chunk` and `inference_response_end`
messages MUST carry the same `request_id`. The coordinator uses
`request_id` to demultiplex responses from a provider handling multiple
concurrent requests. Messages with an unknown `request_id` are logged
at warn level and discarded.

**FR-A5. Multiplexing.**
A single provider WebSocket carries up to N concurrent inference
requests, where N is the provider's advertised `max_concurrency` (from
`hello`/`heartbeat`). The coordinator MUST NOT send more than N
concurrent `inference_request` messages to a single provider. If all N
slots are occupied (determined by counting outstanding `request_id`
values without a corresponding `inference_response_end`), the provider
is treated as `slots_free = 0` and excluded from routing for new
requests.

**Multiplexing framing:** Each WS text frame is one complete JSON
message. Messages are self-contained — no multi-frame messages, no
fragmentation at the application layer. WebSocket-level fragmentation
(RFC 6455 § 5.4) is handled by the transport and is transparent to the
application protocol. The `request_id` field is the sole demultiplexing
key.

**FR-A6. Cancellation propagation.**
When a buyer disconnects mid-stream (TCP reset, HTTP client abort),
the coordinator:
1. Detects the broken buyer connection (Go `http.CloseNotifier` /
   `context.Done()`) within 1 second.
2. Sends a `cancel_request` message to the provider over the
   WebSocket, specifying the `request_id` of the cancelled buyer
   request.
3. The provider MUST abort the in-flight inference for that
   `request_id` within 5 seconds of receiving `cancel_request`.
4. The provider sends `inference_response_end` with
   `status: "cancelled"` to acknowledge cancellation.
5. The coordinator discards any further
   `inference_response_chunk` messages for the cancelled `request_id`.

If the provider does not acknowledge cancellation within 10 seconds
(no `inference_response_end` received), the coordinator logs a warning
and considers the request slot freed. The coordinator MUST NOT close
the WebSocket or mark the provider unhealthy due to a slow
cancellation — the provider may be finishing a long generation. The
slot is freed either way after 10 seconds.

**FR-A7. Provider-side inference handler.**
On receiving `inference_request`, the provider's phase3-binary:
1. Parses the embedded buyer request body.
2. Runs inference through the existing HTTP handler pipeline
   (validation, pre-flight, queue, inference engine, response
   formatter) but captures output internally instead of writing to an
   HTTP response writer.
3. For streaming requests: emits each SSE chunk as an
   `inference_response_chunk` WS message.
4. For non-streaming requests: emits the complete response as a
   single `inference_response_chunk` followed by
   `inference_response_end`.
5. On completion or error, sends `inference_response_end` with the
   appropriate status.

The provider's local HTTP server continues to run (for direct-tunnel
traffic from pinned providers and for `GET /v1/health` diagnostics).
WS-tunneled inference is an additional code path, not a replacement.

**FR-A8. Error semantics.**
Inference errors map to `status` values in `inference_response_end`:

| Error condition | `status` value | Coordinator behavior |
|---|---|---|
| Successful completion | `"complete"` | Relay final response to buyer |
| Client cancelled (FR-A6) | `"cancelled"` | Discard; buyer already disconnected |
| Model not loaded | `"error_model_not_loaded"` | Return HTTP 503 to buyer |
| Context length exceeded | `"error_context_exceeded"` | Return HTTP 413 to buyer |
| Queue full | `"error_queue_full"` | Return HTTP 503 to buyer; try next provider |
| Internal inference error | `"error_internal"` | Return HTTP 502 to buyer |
| Provider timeout | (no message received) | Return HTTP 504 to buyer after `request_timeout_s` |

The `inference_response_end` MAY include an `error` field with a
human-readable message for logging. The coordinator logs the error but
does not expose provider-internal error messages to buyers — it
returns the standard OpenAI error envelope per SPEC-002 § 7.2.

**FR-A9. Backpressure — coordinator-side write buffer.**
The coordinator maintains a bounded write buffer per provider
WebSocket. The buffer holds outgoing `inference_request` and
`cancel_request` messages waiting to be written to the WS.

- **Buffer size:** 64 messages per provider. Rationale: each
  `inference_request` is at most ~10 MB (SPEC-001 FR-8 Stage 1
  envelope limit); in practice, most requests are <100 KB. 64 messages
  at 100 KB average = ~6.4 MB, which is within the coordinator's
  memory budget (SPEC-002 NFR-7: <1 GB at peak with 100 concurrent
  requests and 10 providers). The buffer exists primarily to absorb
  bursts when the provider's WS connection is briefly slow.
- **High-water behavior:** If the buffer reaches capacity, the
  coordinator MUST NOT block the buyer-facing goroutine. Instead, the
  coordinator returns HTTP 503 `provider_busy` to the buyer and logs a
  warning. The provider is NOT marked degraded — a full write buffer is
  transient and does not indicate provider failure.
- **Provider-side read pressure:** The provider reads WS messages in a
  tight loop. If the provider cannot process messages fast enough
  (inference engine saturated), the provider's `slots_free` will be 0
  and the coordinator will not route to it (FR-A5). The write buffer is
  a defense against brief TCP-level congestion, not sustained overload.

**FR-A10. Backpressure — coordinator-side response timeout.**
For each outstanding `inference_request`, the coordinator starts a
timer equal to `routing.request_timeout_s` (default: 300 seconds, per
SPEC-002 config). If `inference_response_end` is not received within
this timeout:
1. The coordinator sends `cancel_request` to the provider.
2. Returns HTTP 504 `provider_timeout` to the buyer (if still
   connected).
3. Frees the request slot in the coordinator's tracking.
4. Does NOT mark the provider unhealthy — a single timeout may be
   caused by an extremely long generation. After 3 consecutive
   timeouts (without any successful responses), the coordinator marks
   the provider `degraded` and initiates the recovery preflight
   sequence from SPEC-002 FR-P11.

**FR-A11. Backpressure — provider-side write buffer.**
The provider maintains a bounded write buffer for outgoing
`inference_response_chunk` messages per active `request_id`:

- **Buffer size:** 256 chunks per request. Rationale: a typical
  streaming response emits one chunk per token; a 4096-token response
  is 4096 chunks. 256 is sufficient to absorb WS write latency for
  several seconds at 30 tok/s. If the buffer fills (WS write blocked
  for >8 seconds at 30 tok/s), the inference is generating faster than
  the network can deliver.
- **High-water behavior:** If the per-request buffer fills, the
  provider pauses token generation for that request (backpressure from
  WS to inference engine). The provider does NOT drop chunks — every
  generated token must be delivered or the response is corrupt. Pausing
  generation is acceptable because the buyer cannot consume tokens
  faster than the WS can deliver them.
- **Buffer drain:** The provider resumes generation when the buffer
  drops below 50% capacity (128 chunks). This hysteresis prevents
  rapid pause/resume oscillation.

**FR-A12. WS-tunneled path coexistence with HTTP-forwarding.**
Both paths coexist indefinitely in v1. The coordinator selects the
path per-provider at registration time (§ 3 path selection logic).
A single buyer request is routed to exactly one provider via exactly
one path — no fallback from WS-tunneled to HTTP-forwarding or vice
versa within a single request. If the selected provider fails, the
coordinator returns an error to the buyer per SPEC-002 FR-B7 (no
silent retry in v1).

### Part B — Dynamic admission

**FR-B1. Three admission tiers.**
The coordinator recognizes three admission tiers for providers:

| Tier | Source | Admission mechanism | Routing eligible |
|---|---|---|---|
| **Pinned** | `config.providers[]` in `coordinator.yaml` | Operator pre-approved. Static config. | Yes (weight 1.0) |
| **Provisional** | Unknown `provider_id` not in config or rejected list | Automatic on `hello`, subject to rate limits | Yes (weight 0.3, configurable) |
| **Rejected** | `rejected_providers` table in coordinator.db | Operator-rejected via `/admin/reject`. Permanent until operator removes. | No. WS close code 4009 on hello. |

**FR-B2. Provisional admission on unknown provider_id.**
When a provider sends `hello` with a `provider_id` that is:
- NOT in `config.providers[]` (not pinned), AND
- NOT in `rejected_providers` table (not banned)

...the coordinator admits the provider as **provisional**, subject to
the rate limits in FR-B3. The coordinator:
1. Generates an `assigned_id` as usual.
2. Registers the provider in the pool with `tier: provisional`.
3. Persists the admission to the `provisional_providers` table
   (FR-B6).
4. Responds with `hello_ack` containing an additional field
   `tier: "provisional"` so the provider knows its status.
5. Logs the admission at info level: `"provisional provider admitted"`,
   `provider_id`, `hostname`, `model_id`, `binary_version`.

**Amendment to SPEC-002 v1.0.4 § 7.1 / Finding F-2:** "F-2 applies
to pinned providers only. Provisional providers are accepted
dynamically subject to rate limits defined in SPEC-003 FR-B3. The
`config.providers[]` static map remains the mechanism for pinned-tier
admission; it is no longer the sole admission mechanism."

**FR-B3. Provisional admission rate limits.**
To prevent abuse (sock-puppet providers, DDoS via connection flood),
provisional admission is rate-limited:

- **Per-hour admission rate:** Maximum 10 new provisional providers
  per hour (sliding window). The 11th attempt within a 60-minute
  window is rejected with WS close code `4008
  provisional_rate_limited`.
  - Rationale: 10/hr allows organic growth (~240/day max) while
    limiting flood attacks. At 40 KB per-connection state (§ 3), 240
    providers = ~9.6 MB — well within the coordinator's 3.8 GB VPS
    (Pearl). Adjust via `admission.provisional_rate_per_hour` config.
- **Total provisional pool size:** Maximum 100 simultaneous
  provisional providers. The 101st connection is rejected with WS
  close code `4007 provisional_pool_full`.
  - Rationale: 100 providers × 40 KB per-connection state = 4 MB.
    Pearl VPS has 3.8 GB RAM; 100 leaves >96 MB headroom for
    coordinator state + SQLite + OS. Adjust via
    `admission.max_provisional_providers` config.
- **Per-provisional-provider request quota:** Each provisional provider
  may serve at most 100 buyer requests per hour (tracked by the
  coordinator per `provider_id`). After 100, the coordinator stops
  routing to that provider until the window resets. This prevents a
  single provisional provider from dominating buyer traffic.
  - Rationale: 100 requests/hr at ~2.5 s each = ~4 min of active
    inference per hour, or ~7% utilization of a single-slot provider.
    Enough to demonstrate value; not enough to displace pinned
    providers. Adjust via
    `admission.provisional_request_quota_per_hour` config.

**FR-B4. New WS close codes for admission.**

| Close code | Name | Sent when | Reason text |
|---|---|---|---|
| `4007` | `provisional_pool_full` | Provisional provider attempts to connect when the provisional pool is at capacity | `"provisional_pool_full: max <N> provisional providers reached"` |
| `4008` | `provisional_rate_limited` | Provisional admission rate exceeded | `"provisional_rate_limited: max <N> admissions per hour"` |
| `4009` | `banned` | Provider's `provider_id` is in `rejected_providers` table | `"banned: provider <id> has been rejected by operator"` |

These codes extend the SPEC-002 v1.0.4 close code table (4001–4005,
4429). The provider binary logs the close code and reason per SPEC-001
FR-13 standard logging. The binary SHOULD display a user-friendly
message for these codes:
- 4007: "The network is currently full. Try again later."
- 4008: "Too many connection attempts. Wait an hour and try again."
- 4009: "Your provider has been banned from this network. Contact
  the operator."

**FR-B5. Routing weight integration.**
The routing algorithm (SPEC-002 § 5) is amended as follows:

In Step 3 (Apply buyer preference), before sorting candidates, the
coordinator applies the tier weight multiplier to each candidate's
`throughput_tps_estimate`:

```
for each candidate in candidates:
    candidate.effective_throughput = candidate.throughput_tps_estimate * tier_weight(candidate.tier)
```

Where `tier_weight(pinned) = 1.0` and `tier_weight(provisional) = 0.3`
(configurable).

The sort then uses `effective_throughput` instead of raw
`throughput_tps_estimate`:

- **Default mode:** `sort(candidates, key=(slots_free, -effective_throughput))`
- **Fast mode:** `sort(candidates, key=(-effective_throughput, slots_free))`
- **Accurate mode:** unchanged (sorts by `model_params_b`, which is
  independent of tier)

This means a provisional provider with 25 tok/s has effective
throughput of 7.5 tok/s for routing purposes — it will be ranked
behind any pinned provider with >7.5 tok/s. The buyer receives the
response from whichever provider is selected; the tier distinction is
transparent to buyers.

**FR-B6. Persistence of provisional admissions.**
Provisional admissions are persisted to SQLite so they survive
coordinator restarts:

```sql
CREATE TABLE provisional_providers (
    provider_id TEXT PRIMARY KEY,
    first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
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

On coordinator restart, the coordinator reads `provisional_providers`
to pre-populate the admission cache. Providers whose
`last_seen_at` is older than 30 days are considered stale and are
NOT pre-loaded (configurable via
`admission.provisional_retention_days`, default 30).

The `rejected_providers` table is always loaded on restart — bans
are permanent until the operator removes the row.

**FR-B7. Tier visibility in /poolz.**
The `/poolz` operator endpoint (SPEC-002 § 7.4) gains a `tier` field
per provider entry:

```json
{
  "assigned_id": "abc-123",
  "provider_id": "stranger-mac-001",
  "hostname": "Strangers-MacBook.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "tier": "provisional",
  "inference_path": "ws_tunneled",
  "requests_served_total": 42,
  ...
}
```

The `tier` field is one of `"pinned"`, `"provisional"`. The
`inference_path` field is one of `"http_forwarding"`, `"ws_tunneled"`.
Both are informational for the operator.

### Part C — Distribution + lifecycle

**FR-C1. GitHub Releases.**
Each release of `macprovider-cli` is published as a GitHub Release on
the `macprovider-poc` repository (or a dedicated `macprovider-releases`
repo if the operator prefers to separate release artifacts from source).

Release shape:
- **Tag format:** `v{major}.{minor}.{patch}` (e.g., `v1.2.0`).
  Follows semantic versioning. The tag is created on the `main` branch.
- **Asset naming:** `macprovider-cli-{version}-{os}-{arch}.tar.gz`
  (e.g., `macprovider-cli-v1.2.0-darwin-arm64.tar.gz`). Only
  `darwin-arm64` is shipped in v1 (Apple Silicon only).
- **Checksums:** A `checksums.txt` file containing SHA-256 hashes for
  all assets, formatted as `{hash}  {filename}` (GNU coreutils style).
- **Release notes:** Markdown body with: version, date, summary of
  changes, breaking changes (if any), link to spec version this release
  implements.

**FR-C2. install.sh contract.**
The install script at `https://get.streamvc.live/install.sh` is the
primary distribution mechanism for new providers. It is a POSIX-
compatible shell script (no bashisms) that:

1. Detects the platform (`uname -s`, `uname -m`). Exits with error if
   not `Darwin` + `arm64`.
2. Checks for required tools: `curl`, `tar`, `shasum` (or `sha256sum`).
3. Fetches the latest release tag from the GitHub API
   (`GET /repos/{owner}/{repo}/releases/latest`).
4. Downloads the binary tarball and `checksums.txt`.
5. Verifies the SHA-256 checksum. Exits with error on mismatch.
6. Extracts the binary to `~/.local/bin/macprovider-cli` (creates
   directory if needed).
7. Adds `~/.local/bin` to `$PATH` in `~/.zshrc` (if not already
   present) with a comment marker: `# Added by macprovider-cli`.
8. Prompts the user for model selection (offers 3 recommended models
   based on detected RAM via `sysctl hw.memsize`).
9. Prompts for coordinator URL (default:
   `wss://coordinator.streamvc.live/ws/provider`).
10. Generates a stable `provider_id` (UUID v4, persisted to
    `~/.config/macprovider/provider_id`).
11. Writes `~/.config/macprovider/config.yaml` with the selected model,
    coordinator URL, and generated provider_id.
12. Optionally installs a launchd plist for reboot survival (FR-C5).
    User is prompted: "Install as a background service? [Y/n]"
13. Runs `macprovider-cli self-test` to verify the installation.
14. Prints a summary: binary version, model, coordinator URL,
    provider_id, and a "you're in the pool!" confirmation if the
    coordinator link succeeded.

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Platform not supported |
| 2 | Missing required tool |
| 3 | Download failed |
| 4 | Checksum mismatch |
| 5 | Extraction failed |
| 6 | Self-test failed |
| 7 | User aborted |

**Side effects (files written):**

| Path | Purpose |
|---|---|
| `~/.local/bin/macprovider-cli` | Binary |
| `~/.config/macprovider/config.yaml` | Configuration |
| `~/.config/macprovider/provider_id` | Stable identity |
| `~/Library/LaunchAgents/live.streamvc.macprovider.plist` | launchd plist (if opted in) |
| `~/.local/share/macprovider/logs/` | Log directory (created by binary on first run) |

**Environment variables (override defaults):**

| Variable | Effect |
|---|---|
| `MACPROVIDER_MODEL` | Skip model selection prompt |
| `MACPROVIDER_COORDINATOR_URL` | Skip coordinator URL prompt |
| `MACPROVIDER_INSTALL_DIR` | Override `~/.local/bin` |
| `MACPROVIDER_NO_LAUNCHD` | Skip launchd prompt (no plist) |
| `MACPROVIDER_NO_PROMPT` | Non-interactive mode (uses all defaults) |

**FR-C3. macprovider-cli update subcommand.**
`macprovider-cli update` performs an atomic self-update:

1. Queries the GitHub API for the latest release.
2. Compares the remote version to the running binary's version.
3. If newer: downloads the tarball and checksums, verifies checksum.
4. Extracts the new binary to a temporary path.
5. Runs `macprovider-cli self-test` with the new binary (sanity check
   before swap).
6. Atomically replaces the old binary with the new one (rename on same
   filesystem; if cross-filesystem, copy + rename + remove old).
7. If a launchd plist is installed, runs
   `launchctl bootout gui/$UID/live.streamvc.macprovider` then
   `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/live.streamvc.macprovider.plist`
   to restart the service with the new binary.
8. If no launchd plist, prints "Update complete. Restart macprovider-cli
   to use the new version."

If already at the latest version, prints "Already up to date
(v{version})" and exits 0.

`macprovider-cli update --check` performs only step 1-2 and prints the
comparison without downloading.

**FR-C4. macprovider-cli status subcommand.**
`macprovider-cli status` displays local and remote state:

```
macprovider-cli v1.2.0

Local:
  Model:       mlx-community/Qwen2.5-7B-Instruct-4bit
  Status:      ready
  Uptime:      2h 34m
  Requests:    142 served, 0 errors
  RAM:         16 GB (M4)
  Context cap: 50,000 tokens

Coordinator:
  URL:         wss://coordinator.streamvc.live/ws/provider
  Connected:   yes (session abc-123)
  Tier:        provisional
  Pool models: Qwen2.5-7B (2 providers), Llama-3.2-3B (1 provider)

Update:
  Current:     v1.2.0
  Latest:      v1.2.1 (run 'macprovider-cli update' to upgrade)
```

Local state comes from the binary's in-process metrics (same data as
`GET /v1/health`). Coordinator state comes from the most recent
`hello_ack` and heartbeat exchange. Update state comes from the
GitHub API (cached for 1 hour to avoid rate limits).

**FR-C5. launchd plist.**
The plist ensures `macprovider-cli` starts on login and restarts on
crash:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>live.streamvc.macprovider</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/.local/bin/macprovider-cli</string>
    <string>serve</string>
    <string>--config</string>
    <string>$HOME/.config/macprovider/config.yaml</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>$HOME/.local/share/macprovider/logs/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/.local/share/macprovider/logs/stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
```

Notes:
- `$HOME` is expanded at install time by `install.sh`, not by launchd.
  The plist contains literal absolute paths.
- `KeepAlive.SuccessfulExit = false` means launchd restarts the binary
  only on crash (non-zero exit), not on clean SIGTERM shutdown.
  This prevents restart loops when the user deliberately stops the
  service.
- `ThrottleInterval = 10` prevents launchd from restarting the binary
  faster than once every 10 seconds (crash loop protection).
- `ProcessType = Background` tells macOS this is a background task,
  reducing scheduling priority and power impact.
- Log rotation is NOT handled by launchd. The binary's log output goes
  to files that grow unbounded. FR-C8 addresses log rotation.

**FR-C6. macprovider-cli uninstall subcommand.**
`macprovider-cli uninstall` removes all installed artifacts:

1. If launchd plist exists: `launchctl bootout
   gui/$UID/live.streamvc.macprovider` (stop the service).
2. Remove `~/Library/LaunchAgents/live.streamvc.macprovider.plist`.
3. Remove `~/.local/bin/macprovider-cli`.
4. Prompt: "Remove configuration and logs? [y/N]"
   - If yes: remove `~/.config/macprovider/` and
     `~/.local/share/macprovider/`.
   - If no: keep config and logs (allows re-install with same identity).
5. Remove the `PATH` addition from `~/.zshrc` (the line with the
   `# Added by macprovider-cli` marker).
6. Print "macprovider-cli has been uninstalled."

**FR-C7. Coordinator-advertised version nudge.**
The `hello_ack` message gains an optional `recommended_binary_version`
field:

```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "abc-123",
  "heartbeat_interval_s": 30,
  "recommended_binary_version": "1.2.0",
  "tier": "provisional"
}
```

If the provider's `binary_version` (from `hello`) is older than
`recommended_binary_version`, the provider SHOULD log a warning:
"A newer version is available (v1.2.0). Run 'macprovider-cli update'
to upgrade."

The coordinator does NOT enforce the version — providers running older
binaries continue to function. Enforcement is deferred to a future
spec (see OQ-4).

The `recommended_binary_version` is configured in `coordinator.yaml`
(`versions.recommended_binary_version`). If not set, the field is
omitted from `hello_ack`.

**FR-C8. Log rotation.**
The binary's log files (`stdout.log`, `stderr.log`) are rotated by the
binary itself on startup:
1. If a log file exceeds 50 MB, rename it to `{name}.1.log`.
2. If `{name}.1.log` already exists, delete it first (keep only one
   rotated file).
3. Open a fresh log file.

This provides simple 2-file rotation (~100 MB max disk usage for logs).
More sophisticated rotation (e.g., daily, compressed) is deferred.

### Part D — Onboarding UX

**FR-D1. README-driven setup flow.**
The project README includes a "Join the Network" section with:

```markdown
## Join the Network

Run this on any Apple Silicon Mac (M1 or newer, macOS 14+):

\`\`\`bash
curl -fsSL https://get.streamvc.live/install.sh | bash
\`\`\`

The installer will:
1. Download the latest macprovider-cli binary
2. Ask you to choose a model (based on your Mac's RAM)
3. Connect you to the network
4. Optionally set up auto-start on login

**Requirements:**
- Apple Silicon Mac (M1, M2, M3, M4)
- macOS 14 (Sonoma) or later
- ~4-8 GB free disk space (for the model)
- Internet connection

**Check your status:**
\`\`\`bash
macprovider-cli status
\`\`\`

**Update:**
\`\`\`bash
macprovider-cli update
\`\`\`

**Uninstall:**
\`\`\`bash
macprovider-cli uninstall
\`\`\`
```

**FR-D2. install.sh model selection.**
The installer detects available RAM and presents appropriate model
options:

| RAM | Recommended models | Default |
|---|---|---|
| 8 GB | `mlx-community/Llama-3.2-3B-Instruct-4bit` (~2 GB) | Llama 3.2 3B |
| 16 GB | Llama 3.2 3B (~2 GB), `mlx-community/Qwen2.5-7B-Instruct-4bit` (~4 GB) | Qwen 2.5 7B |
| 24 GB+ | Llama 3.2 3B, Qwen 2.5 7B, `mlx-community/Qwen2.5-14B-Instruct-4bit` (~8 GB) | Qwen 2.5 14B |

The installer prints the model name, approximate download size, and
estimated context window. The user selects by number. If the model is
not already downloaded, the installer runs
`huggingface-cli download {model}` (or prints instructions if
`huggingface-cli` is not installed). Model download is the longest
step and is NOT included in the "2 minutes to pool" target.

**FR-D3. First-run self-test.**
On first run (or when invoked via `macprovider-cli self-test`), the
binary:
1. Loads the model (this is the slowest step).
2. Runs the SPEC-001 FR-20 self-test (short inference, verify output).
3. Connects to the coordinator, sends `hello`, waits for `hello_ack`.
4. Prints results:
   ```
   Self-test results:
     Model loaded:     OK (mlx-community/Qwen2.5-7B-Instruct-4bit)
     Inference:        OK (18.3 tok/s)
     Coordinator:      OK (connected as provisional, session abc-123)
     Ready to serve!
   ```
5. If any step fails, prints the failure with a suggested fix:
   ```
   Self-test results:
     Model loaded:     OK
     Inference:        OK (18.3 tok/s)
     Coordinator:      FAILED - connection refused
       → Check your internet connection
       → Verify coordinator URL: wss://coordinator.streamvc.live/ws/provider
   ```

**FR-D4. Status check (macprovider-cli status).**
See FR-C4 for the full output format. The status subcommand is the
primary diagnostic tool for contributors. It answers: "Is my Mac
serving? Am I in the pool? What tier am I?"

**FR-D5. Graceful degradation on coordinator unavailability.**
If the coordinator is unreachable (DNS failure, connection refused,
timeout), the binary:
1. Continues running the local HTTP server (for direct-tunnel access
   if configured).
2. Logs a warning every 60 seconds: "Coordinator unreachable. Local
   server running. Retrying in {backoff}s."
3. Follows the existing reconnect-with-backoff logic (SPEC-001 FR-13).
4. Does NOT exit or stop serving. A contributor whose Mac is behind a
   temporary network outage should not need to manually restart.

---

## 5. Wire protocol (Part A details)

### 5.1. New WS message types

Four new message types are added to the coordinator ↔ provider
WebSocket protocol. These extend the existing SPEC-001 § 6.5 envelope.
All existing message types (`hello`, `hello_ack`, `heartbeat`,
`state_update`, `drain_status`, `preflight`, `preflight_ack`, `drain`,
`warm_up`, `nak`) continue to work exactly as specified.

#### 5.1.1. inference_request (C→P)

Sent by the coordinator when routing a buyer request to a WS-tunneled
provider.

```json
{
  "type": "inference_request",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "stream": true,
  "body": "{\"model\":\"mlx-community/Qwen2.5-7B-Instruct-4bit\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100,\"stream\":true}"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_request"` |
| `request_id` | string | Yes | UUID assigned by coordinator. Format: `req-{uuid}`. Used for response correlation and cancellation. |
| `stream` | boolean | Yes | Whether the buyer requested streaming. Determines whether the provider sends `inference_response_chunk` per token (true) or a single chunk with the full response (false). |
| `body` | string | Yes | The buyer's original request body, JSON-serialized as a string. The provider parses this as if it were a `POST /v1/chat/completions` request body. |

**Why `body` is a string, not an embedded object:** The buyer's
request may contain fields the coordinator does not parse
(forward-compat). Serializing as a string preserves the exact byte
sequence, avoiding any JSON round-trip lossy-ness (e.g., floating-point
precision, key ordering). The provider parses `body` through its
existing request validation pipeline (SPEC-001 § 6.2).

**Size limit:** The coordinator MUST NOT send an `inference_request`
whose total WS frame size exceeds 16 MB. This is a conservative limit
that accommodates the largest legal request body (10 MB per SPEC-001
FR-8 Stage 1) plus envelope overhead. Requests exceeding this limit
should have been rejected by the coordinator's own validation before
reaching the WS relay. See OQ-1 for discussion of larger frames.

#### 5.1.2. inference_response_chunk (P→C)

Sent by the provider for each SSE chunk (streaming) or for the
complete response (non-streaming).

```json
{
  "type": "inference_response_chunk",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "seq": 0,
  "data": "data: {\"id\":\"chatcmpl-abc123\",\"object\":\"chat.completion.chunk\",\"created\":1716768000,\"model\":\"mlx-community/Qwen2.5-7B-Instruct-4bit\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_response_chunk"` |
| `request_id` | string | Yes | Matches the `inference_request.request_id` |
| `seq` | integer | Yes | Zero-based monotonically increasing sequence number within this `request_id`. Used by the coordinator to detect gaps and reorder if WS delivery is out-of-order (see § 5.3). |
| `data` | string | Yes | For streaming: one SSE event line (including `data: ` prefix and trailing `\n\n`). For non-streaming: the complete JSON response body (no SSE framing). |

**Streaming (`stream: true`):** The provider emits one
`inference_response_chunk` per SSE event that it would have written
to an HTTP response. This includes the `data: [DONE]\n\n` event, which
is sent as the final chunk before `inference_response_end`. The
coordinator strips the SSE framing if needed (it usually doesn't —
it relays `data` directly to the buyer's SSE stream).

**Non-streaming (`stream: false`):** The provider emits a single
`inference_response_chunk` with `seq: 0` containing the complete JSON
response body (same shape as SPEC-001 § 6.2 non-streaming response).
The `data` field contains the raw JSON string (no `data: ` prefix, no
SSE framing).

#### 5.1.3. inference_response_end (P→C)

Sent by the provider when inference is complete, cancelled, or failed.

```json
{
  "type": "inference_response_end",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "status": "complete",
  "chunks_sent": 47,
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 46,
    "total_tokens": 71
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_response_end"` |
| `request_id` | string | Yes | Matches the `inference_request.request_id` |
| `status` | string | Yes | One of: `"complete"`, `"cancelled"`, `"error_model_not_loaded"`, `"error_context_exceeded"`, `"error_queue_full"`, `"error_internal"` |
| `chunks_sent` | integer | Yes | Total number of `inference_response_chunk` messages sent for this request. Coordinator uses this to verify it received all chunks. |
| `usage` | object | No | Token usage. Present when `status` is `"complete"`. Contains `prompt_tokens`, `completion_tokens`, `total_tokens`. |
| `error` | string | No | Human-readable error message. Present when `status` starts with `"error_"`. |

**Invariant:** After sending `inference_response_end`, the provider
MUST NOT send any more `inference_response_chunk` messages for that
`request_id`. The coordinator frees the request slot on receipt of
`inference_response_end`.

#### 5.1.4. cancel_request (C→P)

Sent by the coordinator when the buyer disconnects or the request
times out.

```json
{
  "type": "cancel_request",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "reason": "buyer_disconnected"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"cancel_request"` |
| `request_id` | string | Yes | The `request_id` of the inference to cancel |
| `reason` | string | Yes | One of: `"buyer_disconnected"`, `"timeout"`, `"coordinator_shutdown"` |

**Provider behavior on receipt:**
1. If the `request_id` is currently being processed: abort inference,
   release the slot, send `inference_response_end` with
   `status: "cancelled"`.
2. If the `request_id` is unknown (already completed or never
   received): send `inference_response_end` with
   `status: "cancelled"` and `chunks_sent: 0`. This is idempotent.
3. If the `request_id` is in the provider's request queue (not yet
   started): remove from queue, send `inference_response_end` with
   `status: "cancelled"` and `chunks_sent: 0`.

### 5.2. SPEC-001 hello amendment

The `hello` message gains one new optional field:

```json
{
  "type": "hello",
  "version": 1,
  "tier": 1,
  "provider_id": "stranger-mac-001",
  "hostname": "Strangers-MacBook.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 1,
  "throughput_tps_estimate": 18.3,
  "binary_version": "1.2.0",
  "attestation": null,
  "endpoint_url": null
}
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `endpoint_url` | string or null | No | null | If non-null: the provider's HTTPS endpoint for HTTP-forwarding. If null or absent: inference is routed through this WebSocket (WS-tunneled mode). |

**Backward compatibility:** Existing v1.1.4 binaries do not send this
field. The coordinator treats absence as null (WS-tunneled). But
because v1.1.4 binaries are pinned (in `config.providers[]`), the
coordinator falls back to `config.providers[].endpoint_url` per the
path selection logic in § 3. Net: zero binary changes required for
existing providers.

### 5.3. Ordering guarantees

**Within a single `request_id`:** The provider MUST send
`inference_response_chunk` messages in `seq` order (0, 1, 2, ...).
The coordinator MUST relay them to the buyer in `seq` order. If a
chunk arrives out of order (seq N+2 before N+1), the coordinator
buffers it for up to 5 seconds waiting for the missing chunk. If the
gap is not filled within 5 seconds, the coordinator treats it as a
provider error, sends `cancel_request`, and returns HTTP 502 to the
buyer.

**Rationale for out-of-order possibility:** In practice, a single
WebSocket connection delivers messages in order (TCP guarantees). The
`seq` field exists as a defense against future transport changes (e.g.,
QUIC-based WebSocket) and as a debugging aid (the coordinator can
assert `chunks_sent` matches the highest `seq + 1`).

**Across `request_id` values:** No ordering guarantee. Chunks from
request A and request B may interleave freely on the WebSocket. The
`request_id` field is the demultiplexing key.

### 5.4. Retransmission policy

**No retransmission at the application layer.** If a WS frame is lost
(WebSocket connection drops), all outstanding requests on that
connection are considered failed. The coordinator:
1. Returns HTTP 502 to all buyers whose requests were in-flight on the
   dropped connection.
2. Removes the provider from the pool (per SPEC-002 FR-P10 disconnect
   handling).
3. The provider reconnects via SPEC-001 FR-13 backoff.

Rationale: TCP guarantees in-order delivery on an established
connection. WS frame loss only happens on connection failure, at which
point all in-flight state is lost anyway. Application-layer
retransmission adds complexity without benefit for the v1 single-WS
architecture.

### 5.5. Wire protocol version negotiation

The `hello` message already contains `version: 1`. SPEC-003 does NOT
increment the protocol version. The new message types are additive —
a coordinator that does not understand `inference_response_chunk` would
never send `inference_request` in the first place. Old coordinators
reject old binaries via existing mechanisms; new coordinators handle
both old and new binaries via the path selection logic in § 3.

If a future spec introduces breaking wire changes, it MUST increment
`version` and the coordinator MUST reject providers with incompatible
versions via close code 4004 `version_unsupported` (already defined in
SPEC-002).

---

## 6. Admission tiers (Part B details)

### 6.1. Tier definitions

| Property | Pinned | Provisional | Rejected |
|---|---|---|---|
| Source | `config.providers[]` | Unknown `provider_id` | `rejected_providers` table |
| Admission | On coordinator start (static config) | On `hello`, rate-limited | Never. WS close 4009. |
| Routing weight | 1.0 | 0.3 (configurable) | N/A |
| Request quota | Unlimited | 100/hr (configurable) | N/A |
| Persistence | Config file (operator-managed) | `provisional_providers` table | `rejected_providers` table |
| Promotion | N/A (already highest tier) | Operator calls `POST /admin/promote` | Operator removes row from `rejected_providers` |
| Inference path | HTTP-forwarding or WS-tunneled | HTTP-forwarding or WS-tunneled | N/A |

### 6.2. State transitions

```
                    Unknown provider_id
                           │
                           ▼
                  ┌─────────────────┐
                  │  Rate limit OK?  │
                  └────────┬────────┘
                     yes   │   no
                     │     └──→ WS close 4007 or 4008
                     ▼
              ┌──────────────┐
              │  PROVISIONAL  │◄──── Operator removes from rejected_providers
              └──────┬───────┘
                     │
            ┌────────┴────────┐
            │                  │
            ▼                  ▼
     POST /admin/         POST /admin/
     promote/{id}         reject/{id}
            │                  │
            ▼                  ▼
      ┌──────────┐      ┌──────────┐
      │  PINNED   │      │ REJECTED  │
      └──────────┘      └──────────┘
```

- **Provisional → Pinned:** Operator calls
  `POST /admin/promote/{provider_id}`. The coordinator:
  1. Adds the provider to `config.providers[]` in memory (runtime only;
     the operator must also add to `coordinator.yaml` for persistence
     across restarts).
  2. Updates the pool entry's tier to `pinned`.
  3. Sets `provisional_providers.promoted_at` to now.
  4. Increases routing weight to 1.0 immediately.
  5. Responds with 200 and the updated provider entry.
  Note: the operator MUST separately edit `coordinator.yaml` and add
  the provider to `config.providers[]` for the promotion to survive
  coordinator restart. The API promotion is runtime-only. A future
  version may persist this automatically (see OQ-6).

- **Provisional → Rejected:** Operator calls
  `POST /admin/reject/{provider_id}`. The coordinator:
  1. Adds the `provider_id` to `rejected_providers` table.
  2. If the provider is currently connected: sends `drain`, waits for
     `drain_status: complete` (or 60s timeout), then closes WS with
     code 4009.
  3. Removes the provider from the pool.
  4. Responds with 200.
  Future connection attempts from this `provider_id` are immediately
  closed with 4009.

- **Rejected → Provisional:** Operator manually deletes the row from
  `rejected_providers` (SQL or a future admin endpoint). The provider
  can then reconnect and be re-admitted as provisional.

### 6.3. Admission tier in hello_ack

The `hello_ack` message gains a `tier` field:

```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "abc-123",
  "heartbeat_interval_s": 30,
  "tier": "provisional",
  "recommended_binary_version": "1.2.0"
}
```

The `tier` field is one of `"pinned"` or `"provisional"`. The provider
uses this for display purposes (FR-C4 status output) and MAY adjust
behavior based on tier (e.g., logging the tier on startup). The
provider MUST NOT change its inference behavior based on tier — all
providers serve the same quality responses.

### 6.4. SPEC-002 v1.0.4 F-2 amendment

**Original F-2 (SPEC-002 v1.0.4 § 10):** "Dynamic provider
registration is not supported. A `hello` whose `provider_id` is not in
`config.providers[]` is rejected with WS close code 4002
`unknown_provider_id`."

**SPEC-003 amendment:** F-2 is relaxed as follows:
- `config.providers[]` remains the mechanism for **pinned** tier
  admission.
- Unknown `provider_id` values are NO LONGER rejected with 4002.
  Instead, they are admitted as **provisional** (subject to FR-B3 rate
  limits) or rejected with **4009** if the `provider_id` is in the
  `rejected_providers` table.
- Close code 4002 `unknown_provider_id` is **retired** for v1.1+
  coordinators. It is replaced by the admission tier logic. Existing
  v1.0.x coordinators continue to use 4002 as specified.

### 6.5. Provisional request quota enforcement

The coordinator tracks per-provisional-provider request counts using a
sliding 1-hour window. The counter is stored in memory (not SQLite)
and resets on coordinator restart.

When a buyer request is about to be routed to a provisional provider:
1. Check if `requests_this_hour >= quota` (default 100).
2. If over quota: skip this provider in the routing loop (same as
   `slots_free = 0`). Try the next candidate.
3. If under quota: route normally, increment counter.

If ALL eligible providers for the requested model are provisional AND
all are over quota, the coordinator returns HTTP 503
`no_provider_available` to the buyer. This is the same error the buyer
would receive if no providers were available at all — the quota
mechanism is invisible to buyers.

---

## 7. Interface contracts

### 7.1. New WS message types

Full JSON schemas are defined in § 5.1. Summary:

| Message | Direction | Purpose |
|---|---|---|
| `inference_request` | C→P | Deliver buyer request to WS-tunneled provider |
| `inference_response_chunk` | P→C | SSE chunk or complete response from provider |
| `inference_response_end` | P→C | Completion/error/cancellation signal |
| `cancel_request` | C→P | Abort in-flight inference |

All four messages use the `request_id` field for correlation. All
four are JSON text frames on the existing provider WebSocket.

### 7.2. New operator endpoints

All new endpoints are mounted on `listen.provider_port` (default
8444), consistent with existing operator endpoints per SPEC-002 v1.0.4
Finding F-3. All require `Authorization: Bearer <operator-key>`.

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

Promotes a provisional provider to pinned tier (runtime only).

**Request:** No body required. The `provider_id` is in the URL path.

**Response (200):**
```json
{
  "provider_id": "stranger-mac-001",
  "previous_tier": "provisional",
  "new_tier": "pinned",
  "note": "Runtime promotion only. Add to coordinator.yaml for persistence across restarts."
}
```

**Response (404):**
```json
{
  "error": {
    "code": "provider_not_found",
    "message": "Provider stranger-mac-001 is not in the provisional tier"
  }
}
```

**Response (409):**
```json
{
  "error": {
    "code": "already_pinned",
    "message": "Provider stranger-mac-001 is already pinned"
  }
}
```

#### POST /admin/reject/{provider_id}

Rejects a provider (any tier). Adds to rejected list and disconnects.

**Request body (optional):**
```json
{
  "reason": "Suspected bad actor"
}
```

**Response (200):**
```json
{
  "provider_id": "stranger-mac-001",
  "status": "rejected",
  "drain_sent": true,
  "note": "Provider will be disconnected. Future connections will be rejected with close code 4009."
}
```

**Response (404):**
```json
{
  "error": {
    "code": "provider_not_found",
    "message": "Provider stranger-mac-001 not found"
  }
}
```

### 7.3. install.sh contract

Defined in FR-C2. Summary:

- **URL:** `https://get.streamvc.live/install.sh`
- **Hosting:** Cloudflare Pages (static site, free tier, global CDN).
  The `get.streamvc.live` subdomain is a CNAME pointing to Cloudflare
  Pages.
- **Arguments:** None (all configuration via interactive prompts or
  env vars).
- **Exit codes:** 0-7 (see FR-C2).
- **Side effects:** See FR-C2 file table.

### 7.4. macprovider-cli new subcommands

| Subcommand | Description | Requires running service |
|---|---|---|
| `serve` | Start the inference server (existing) | N/A (this IS the service) |
| `self-test` | Run model load + inference + coordinator check | No |
| `status` | Show local + remote state (FR-C4) | Yes (reads from running process) |
| `update` | Self-update to latest release (FR-C3) | No (stops service if needed) |
| `update --check` | Check for updates without downloading | No |
| `uninstall` | Remove all artifacts (FR-C6) | No (stops service if running) |

### 7.5. launchd plist schema

Defined in FR-C5. Key properties:

| Property | Value | Rationale |
|---|---|---|
| Label | `live.streamvc.macprovider` | Reverse-domain per Apple convention |
| RunAtLoad | true | Start on login |
| KeepAlive.SuccessfulExit | false | Restart on crash, not on clean stop |
| ThrottleInterval | 10 | Prevent crash-loop restart storms |
| ProcessType | Background | Reduce scheduling priority |

### 7.6. GitHub Releases shape

Defined in FR-C1. Summary:

| Property | Format | Example |
|---|---|---|
| Tag | `v{semver}` | `v1.2.0` |
| Asset | `macprovider-cli-{version}-{os}-{arch}.tar.gz` | `macprovider-cli-v1.2.0-darwin-arm64.tar.gz` |
| Checksums | `checksums.txt` (SHA-256, GNU format) | `a1b2c3...  macprovider-cli-v1.2.0-darwin-arm64.tar.gz` |
| Release notes | Markdown body | Version, date, changes, breaking changes, spec version |

---

## 8. Dependencies + clean-room hygiene

### 8.1. Coordinator changes (Part A + Part B)

**No new Go dependencies.** The existing `gobwas/ws` library handles
the new message types — they are JSON payloads on the same WebSocket.
No new framing, no new transport library. The new SQLite tables
(`provisional_providers`, `rejected_providers`) use the existing
`modernc.org/sqlite` dependency.

The coordinator changes are:
- New message handlers in `internal/ws/handler.go` for
  `inference_response_chunk`, `inference_response_end` (inbound from
  provider).
- New message constructors for `inference_request`, `cancel_request`
  (outbound to provider).
- Modified buyer server (`internal/buyer/server.go`) to use WS relay
  instead of HTTP forwarding when the selected provider is WS-tunneled.
- New admission logic in `internal/ws/handler.go` (provisional tier
  check, rate limits).
- New admin endpoints (`internal/operator/`) for provisional, promote,
  reject.
- New SQLite tables (`internal/store/`).

### 8.2. Binary changes (Part A provider side + Part C + Part D)

**No new Swift dependencies.** The new WS message types are handled
by the existing `URLSessionWebSocketTask` (Swift standard library).
The `update` subcommand uses `URLSession` for HTTP (already available).
The launchd plist is a static file written by `install.sh`, not by the
binary.

The binary changes are:
- New message handlers in `CoordinatorClient.swift` for
  `inference_request`, `cancel_request` (inbound from coordinator).
- New message constructors for `inference_response_chunk`,
  `inference_response_end` (outbound to coordinator).
- Internal refactor: extract the inference pipeline from the HTTP
  handler into a shared function callable from both HTTP and WS paths.
- New subcommands: `update`, `status`, `uninstall`, `self-test`.
- New `endpoint_url` field in `hello` message (FR-5.2).
- Log rotation logic (FR-C8).

### 8.3. Distribution dependencies

| Dependency | Purpose | License | Notes |
|---|---|---|---|
| GitHub API | Release discovery, download | N/A (public API) | No API key needed for public repos. Rate limit: 60 req/hr unauthenticated. `install.sh` makes 2 API calls; `update` makes 1-2. |
| Cloudflare Pages | Hosting `get.streamvc.live` | Free tier | Static site. Only serves `install.sh` and a landing page. |
| `huggingface-cli` | Model download | Apache-2.0 | NOT a hard dependency. `install.sh` prints manual download instructions if not installed. |
| `shasum` / `sha256sum` | Checksum verification | OS-provided | macOS ships `shasum` (BSD). Fallback to `openssl dgst -sha256` if neither found. |

### 8.4. d-inference clean-room separation

This section reaffirms the strict clean-room policy from SPEC-001
§ 7.2 and SPEC-002 § 8.2.

**PROHIBITED references for SPEC-003 and its implementation:**
- The d-inference GitHub repository
  (https://github.com/Layr-Labs/d-inference)
- Any d-inference source files, README, or config files
- Any third-party analyses that quote or reproduce d-inference source
- Reverse-engineered analyses of any compiled Darkbloom binary

**Reason:** The DARKBLOOM LICENSE AGREEMENT (Eigen Labs, Inc.,
copyright 2026; SPDX NOASSERTION) explicitly prohibits in Section 3
the use of the Software to "provide, operate, or enable any hosted
service, platform, marketplace, or product that offers AI inference
coordination, private inference services, or decentralized compute
marketplace capabilities that compete with Darkbloom." Mac Provider
fits this description.

**PERMITTED references:** Same as SPEC-001 § 7.2 and SPEC-002 § 8.2
(public papers, blog posts, Apple MLX docs, OpenAI API reference,
this repository's own materials).

**cloudflared is NOT a hard dependency for SPEC-003.** Provisional
providers using WS-tunneled inference need only outbound WSS — no
Cloudflare tunnel, no public URL, no DNS. `cloudflared` remains
available as an option for pinned providers who prefer HTTP-forwarding,
but it is not required or installed by `install.sh`.

### 8.5. WS-tunneled inference: prior art and convergent design

The WS-tunneled inference architecture — where a worker connects
outbound to a coordinator and receives work over that connection — is
an industry-standard pattern for outbound-only worker pools:

| System | Pattern | Transport |
|---|---|---|
| **Tor relay** | Relay connects outbound to directory authority, receives circuits | TLS |
| **Tailscale** | Node connects outbound to coordination server (DERP), relays traffic | WireGuard over HTTPS |
| **GitHub Actions self-hosted runner** | Runner connects outbound to GitHub, receives job assignments | HTTPS long-poll |
| **Cursor agents** | Agent connects outbound to Cursor server, receives edit commands | WebSocket |
| **AWS IoT Core** | Device connects outbound to AWS, receives commands | MQTT over WSS |
| **Cloudflare Workers** | Isolate connects outbound to Cloudflare edge, receives requests | Internal |

Mac Provider's WS-tunneled inference is convergent design driven by
the same constraint: **the worker has no inbound network**. A Mac
behind a home NAT, corporate firewall, or mobile hotspot cannot accept
incoming connections. The only viable architecture is outbound
connection + inbound work delivery. This is documented here for
transparency per the clean-room policy — the design follows from the
constraint, not from any examination of d-inference's implementation.

---

## 9. Phase 4 findings + Day 2 lessons that SPEC-003 encodes

This section maps Decision log entries 13–18 to SPEC-003 requirements,
following the same pattern as SPEC-001 § 8 and SPEC-002 § 10.

### D7 (was F-2): Static config-map relaxed to provisional tier

**Source:** SPEC-002 v1.0.4 Finding F-2 + Decision log Entry 18.

**Finding:** "Dynamic provider registration is not supported. A
`hello` whose `provider_id` is not in `config.providers[]` is rejected
with WS close code 4002 `unknown_provider_id`." This was by design in
v1 — operator approval of each provider is the trust-pool admission
mechanism. But at 5+ providers, the operator becomes the bottleneck.

**SPEC-003 encoding:**
- **FR-B1** (three admission tiers): The `config.providers[]` static
  map becomes the pinned tier. Unknown providers get provisional tier.
- **FR-B2** (provisional admission): Unknown `provider_id` values are
  accepted automatically.
- **FR-B3** (rate limits): Prevents abuse of the relaxed admission.
- **§ 6.4** (F-2 amendment): Formal relaxation of the invariant.

### D8 (drain conflation): Coordinator drain MUST NOT terminate provider

**Source:** Decision log Entry 15 (2026-05-28). phase3-binary v1.1.2
called `exit()` on coordinator drain, breaking tunnel-direct buyer
traffic. Fixed in v1.1.3.

**SPEC-003 encoding:**
- **FR-A7** (provider-side inference handler): "The provider's local
  HTTP server continues to run." WS-tunneled inference is an additional
  code path, not a replacement.
- This finding is now **load-bearing** for WS-tunneled mode: if the
  coordinator drains, WS-tunneled providers have no fallback path
  (unlike pinned providers who can still serve via tunnel). The
  provider MUST reconnect to the coordinator after drain, and the
  coordinator MUST re-admit it (subject to tier rules).

### D9 (case-sensitivity regression): model_id comparison

**Source:** Decision log Entry 18 (2026-05-28). M1 cron 404 storm
caused by case-sensitive `model_id` comparison (provider sent
`Llama-3.2-3B-Instruct-4bit`, buyer sent `llama-3.2-3b-instruct-4bit`).

**SPEC-003 encoding:**
- Coordinator `model_id` comparison in the routing algorithm MUST be
  **case-insensitive** for the purpose of matching buyer requests to
  providers. The canonical form (as sent by the provider in `hello`) is
  preserved in storage and returned in `GET /v1/models`.
- Implementation: use `strings.EqualFold()` in Go for model matching.
  The `pool.ModelKnown()` function and the routing filter both apply
  case-insensitive comparison.
- This is an amendment to SPEC-002 § 5 Step 2 ("model match is exact
  string equality on `model_id`"). The amendment: model match is
  **case-insensitive** string comparison. The `model_id` returned in
  `GET /v1/models` and in response JSON preserves the provider's
  canonical casing.

### D10 (coordinator overhead measurement)

**Source:** Decision log Entry 14 (2026-05-28). First production
end-to-end: 2.5 s round-trip, coordinator adds <100 ms of
routing+proxy overhead. But this was measured on the HTTP-forwarding
path.

**SPEC-003 encoding:**
- The WS-tunneled path adds overhead from JSON serialization of
  `inference_request`, WS frame encapsulation, demultiplexing, and
  SSE reassembly at the coordinator. Expected additional overhead:
  10–50 ms per request on top of the HTTP-forwarding baseline.
- **Validation method:** During AC-1/AC-2 testing, measure
  time-to-first-token for the same prompt via:
  1. Direct HTTP to provider (baseline).
  2. HTTP-forwarding through coordinator (existing path).
  3. WS-tunneled through coordinator (new path).
  The WS-tunneled path SHOULD be within 100 ms of the HTTP-forwarding
  path for a short prompt. If the delta exceeds 200 ms, investigate
  serialization or buffering inefficiency before accepting.

---

## 10. Acceptance criteria

**AC-1 through AC-12 must ALL pass for SPEC-003 to be considered
build-complete. No partial passes. No operator waivers without an
explicit entry in `phase5-onboarding/implementation-notes.html`.**

---

**AC-1. WS-tunneled inference (non-streaming).**

**Setup:** Start coordinator with one WS-tunneled mock provider
(no `endpoint_url` in hello, not in `config.providers[]`).

**Action:** Send `POST /v1/chat/completions` with `stream: false` to
the coordinator's buyer API.

**Expected:** Mock provider receives `inference_request` over WS,
sends `inference_response_chunk` with the complete response, sends
`inference_response_end` with `status: "complete"`. Buyer receives
HTTP 200 with a valid OpenAI-format JSON response.

**How to verify:** `phase5-onboarding/scripts/test-ws-inference.sh`

---

**AC-2. Streaming SSE through WS multiplexing.**

**Setup:** Same as AC-1 but with `stream: true`.

**Action:** Send streaming `POST /v1/chat/completions` to the
coordinator.

**Expected:** Mock provider sends multiple
`inference_response_chunk` messages (one per SSE event). Coordinator
relays each as a `data: {...}\n\n` SSE line to the buyer in real-time.
Time-to-first-token delta between WS-tunneled and direct-HTTP is
<100 ms. The final `data: [DONE]\n\n` is relayed. Buyer receives
complete SSE stream.

**How to verify:** `phase5-onboarding/scripts/test-ws-streaming.sh`

---

**AC-3. Cancellation propagation.**

**Setup:** Start coordinator with one WS-tunneled mock provider
configured to generate tokens slowly (1 tok/s).

**Action:**
1. Send a streaming request.
2. Wait for at least 2 SSE events to arrive at the buyer.
3. Disconnect the buyer (TCP close).

**Expected:**
1. Coordinator detects buyer disconnect within 1 second.
2. Coordinator sends `cancel_request` to the provider within 1 second
   of detection.
3. Provider sends `inference_response_end` with
   `status: "cancelled"` within 5 seconds.
4. Provider's request slot is freed (verifiable via `GET /v1/health`
   or next heartbeat showing `slots_free` incremented).

**How to verify:** `phase5-onboarding/scripts/test-cancellation.sh`

---

**AC-4. Concurrent multiplexing.**

**Setup:** Start coordinator with one WS-tunneled mock provider that
advertises `max_concurrency: 3`.

**Action:** Send 3 concurrent streaming requests to the coordinator,
all for the mock provider's model.

**Expected:** All 3 requests are delivered as `inference_request`
messages over the SAME WebSocket. All 3 produce interleaved
`inference_response_chunk` messages. All 3 complete successfully.
The coordinator correctly demultiplexes responses by `request_id`.

**How to verify:** `phase5-onboarding/scripts/test-multiplexing.sh`

---

**AC-5. Backward compatibility: pinned provider via HTTP-forwarding.**

**Setup:** Start coordinator with config containing a pinned provider
(in `config.providers[]` with `endpoint_url`). Start a mock HTTP
server at the configured URL.

**Action:** Send `POST /v1/chat/completions` to the coordinator.

**Expected:** Coordinator routes via HTTP-forwarding (not WS-tunneled).
The request is sent as a standard HTTP POST to the mock provider's
URL. Response is relayed to the buyer. This is the existing SPEC-002
behavior — SPEC-003 MUST NOT break it.

**How to verify:** `phase5-onboarding/scripts/test-pinned-compat.sh`

---

**AC-6. Provisional admission.**

**Setup:** Start coordinator. Connect a mock provider with a
`provider_id` NOT in `config.providers[]` and NOT in
`rejected_providers`.

**Action:** Mock provider sends `hello`.

**Expected:**
1. Coordinator responds with `hello_ack` containing
   `tier: "provisional"`.
2. `GET /poolz` shows the provider with `tier: "provisional"`.
3. Buyer requests are routed to the provisional provider (with
   reduced weight).

**How to verify:** `phase5-onboarding/scripts/test-provisional.sh`

---

**AC-7. Provisional rate limit.**

**Setup:** Configure coordinator with
`admission.provisional_rate_per_hour: 10`.

**Action:** Connect 11 provisional providers within 60 seconds.

**Expected:** First 10 get `hello_ack`. 11th gets WS close code
`4008 provisional_rate_limited`.

**How to verify:** `phase5-onboarding/scripts/test-rate-limit.sh`

---

**AC-8. install.sh from clean Mac.**

**Setup:** A Mac with no previous macprovider-cli installation. Model
already downloaded (to isolate install time from download time).

**Action:** `curl -fsSL https://get.streamvc.live/install.sh | bash`
(or local `bash install.sh` during testing).

**Expected:**
1. Binary installed to `~/.local/bin/macprovider-cli`.
2. Config written to `~/.config/macprovider/config.yaml`.
3. `provider_id` generated and persisted.
4. Self-test passes (model loads, inference works, coordinator
   connection succeeds).
5. Total time from script start to "Ready to serve!" message: <2
   minutes (excluding model download).

**How to verify:** Manual test on a clean user account.

---

**AC-9. macprovider-cli update.**

**Setup:** Install v1.2.0. Publish v1.2.1 to GitHub Releases.

**Action:** `macprovider-cli update`

**Expected:**
1. New version detected and downloaded.
2. Checksum verified.
3. Binary atomically swapped.
4. If launchd plist installed: service restarted with new binary.
5. `macprovider-cli --version` shows `1.2.1`.

**How to verify:** `phase5-onboarding/scripts/test-update.sh`

---

**AC-10. launchd plist reboot survival.**

**Setup:** Install macprovider-cli with launchd plist. Verify service
is running (process visible in `launchctl list | grep macprovider`).

**Action:** `sudo reboot` (or `launchctl bootout` + `launchctl
bootstrap` to simulate).

**Expected:**
1. After reboot, `macprovider-cli serve` is running automatically.
2. Provider reconnects to coordinator (visible in `/poolz`).
3. `macprovider-cli status` shows healthy state.

**How to verify:** Manual test.

---

**AC-11. admin/promote.**

**Setup:** Connect a provisional provider.

**Action:** `POST /admin/promote/{provider_id}`

**Expected:**
1. Provider's tier changes from `provisional` to `pinned` in `/poolz`.
2. Routing weight upgrades to 1.0 immediately.
3. Subsequent buyer requests route to this provider with full weight.

**How to verify:** `phase5-onboarding/scripts/test-promote.sh`

---

**AC-12. admin/reject.**

**Setup:** Connect a provisional provider.

**Action:** `POST /admin/reject/{provider_id}`

**Expected:**
1. Provider receives `drain` message.
2. Provider disconnects (or coordinator closes WS with 4009 after
   timeout).
3. Provider's `provider_id` is in `rejected_providers` table.
4. Subsequent `hello` from this `provider_id` → WS close 4009
   `banned`.

**How to verify:** `phase5-onboarding/scripts/test-reject.sh`

---

## 11. Open questions (OQs)

**OQ-1. WS frame size limit for large completions.**
A 32K-token streaming response at ~5 bytes/token generates ~160 KB of
SSE data, split across ~32,000 `inference_response_chunk` messages
(one per token). Each chunk is small (~200-500 bytes including
envelope). The concern is not individual frame size but total message
count and WS throughput. At 30 tok/s, that's 30 WS frames/s — well
within typical WS capacity. But a non-streaming response for a 32K
completion would be a single `inference_response_chunk` with a ~200 KB
`data` field, which fits in one WS text frame (gobwas/ws default max:
unbounded; network MTU handles fragmentation).

**Current position:** No explicit frame size limit in the protocol.
The 16 MB coordinator-side limit on `inference_request` (§ 5.1.1) is
sufficient. Non-streaming responses are bounded by `max_tokens`
(provider-enforced) and should not exceed a few MB. Monitor during
AC-2 testing. If WS throughput is a bottleneck, consider chunking
non-streaming responses.

**OQ-2. Per-provider WS write buffer high-water mark.**
FR-A9 specifies 64 messages as the coordinator-side write buffer per
provider. This is a starting estimate. In practice, the buffer should
rarely fill because the coordinator only sends `inference_request` (at
most N concurrent, where N = `max_concurrency`, typically 1) and
`cancel_request` (at most one per outstanding request). The 64-message
buffer is ~60× the expected steady-state depth.

**Current position:** 64 is a conservative default. Tune based on
production telemetry. Add a `/poolz` field showing per-provider
write buffer depth for operator visibility.

**OQ-3. How to surface tier=provisional to buyers.**
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

**OQ-4. Should `recommended_binary_version` enforcement apply to
provisional or only pinned providers?**
FR-C7 defines a version nudge (log warning). Should the coordinator
refuse to route to providers running versions older than
`recommended_binary_version`?

**Current position:** No enforcement in v1. The nudge is informational.
Enforcement is risky because it could reject all provisional providers
simultaneously if the coordinator's recommended version is bumped
before most providers update. A future spec may introduce a
`minimum_binary_version` with a grace period (e.g., "providers below
v1.1.0 will be rejected after 2026-07-01"). Not in SPEC-003 scope.

**OQ-5. Code signing strategy.**
Apple Developer ID signing ($99/yr) vs `xattr -d com.apple.quarantine`
workaround. SPEC-001 NFR-6 says "signed with Developer ID, not
notarized." This is still the plan for pinned providers (operator can
tell M4/M1 to run `xattr`). For `install.sh` strangers, the xattr
workaround is acceptable in v1 (the script runs `xattr -d` after
extraction). Long-term, notarization is needed for a true
"double-click to install" experience.

**Current position:** v1.2 ships unsigned. `install.sh` runs
`xattr -d com.apple.quarantine` on the extracted binary. Document this
in the README with a note: "macOS may warn about an unidentified
developer. This is expected for the current release." Apple Developer
ID signing is a Phase 6+ concern.

**OQ-6. Automatic persistence of promotions.**
FR-B2's `POST /admin/promote` is runtime-only — the operator must
also edit `coordinator.yaml`. Should the coordinator automatically
append to `coordinator.yaml`?

**Current position:** No auto-edit of config files in v1. Config
files are operator-owned and may be version-controlled. The
coordinator should not mutate them. The operator adds promoted
providers to `coordinator.yaml` manually (same workflow as today's
pinned provider onboarding, but only for the subset the operator
chooses to promote). A future version may add a `coordinator-cli
promote --persist` flag that appends to the config file.

**OQ-7. Provider identity verification for provisional tier.**
A provisional provider self-reports its `provider_id`. Nothing prevents
a malicious actor from impersonating another provider's ID. In the
pinned tier, the operator controls ID assignment. In the provisional
tier, the provider generates its own ID (UUID from `install.sh`).

**Current position:** For v1, self-reported UUIDs are sufficient
because: (a) UUIDs are 128-bit random — collision probability is
negligible, (b) the coordinator tracks `provider_id` → WS connection,
so a duplicate ID would close the older connection (same as SPEC-002
FR-P2 step 4), (c) provisional providers have reduced routing weight
and request quotas, limiting the impact of impersonation. Stronger
identity verification (e.g., device attestation) is a Tier 2 concern.

---

## 12. Build steps (paste-ready prompts)

### 12.1. phase3-binary v1.2 — WS inference + new subcommands

```
=== BEGIN BUILD PROMPT: phase3-binary v1.2 ===

Read SPEC-003 §§ 4-5 (FR-A1 through FR-A12, wire protocol), § 7.4
(new subcommands), FR-C3 through FR-C8 (update, status, uninstall,
launchd, log rotation), and the SPEC-001 hello amendment (§ 5.2).

You are modifying the existing phase3-binary (Swift, macOS, Apple
Silicon). The codebase is at phase3-binary/.

Changes to make:

1. **CoordinatorClient.swift** — Add handlers for two new inbound
   message types: `inference_request` (C→P) and `cancel_request` (C→P).
   On `inference_request`: parse the embedded `body`, run it through
   the existing inference pipeline, emit `inference_response_chunk`
   and `inference_response_end` back over the WebSocket.

2. **Inference pipeline refactor** — Extract the core inference logic
   from the HTTP handler into a shared function that can be called
   from both the HTTP path and the WS path. The function takes a
   parsed request and returns a stream of response chunks.

3. **hello message** — Add optional `endpoint_url` field. If the
   provider has a configured endpoint URL (from config or Cloudflare
   tunnel), send it. Otherwise send null.

4. **hello_ack handling** — Parse new `tier` and
   `recommended_binary_version` fields. Log tier. Warn if
   binary_version < recommended_binary_version.

5. **New subcommands:**
   - `macprovider-cli update` (FR-C3)
   - `macprovider-cli status` (FR-C4)
   - `macprovider-cli uninstall` (FR-C6)
   - `macprovider-cli self-test` (FR-D3)

6. **Log rotation** (FR-C8): On startup, rotate log files >50 MB.

7. **Cancellation handling**: On `cancel_request`, abort the in-flight
   inference task, send `inference_response_end` with
   status=cancelled.

Acceptance criteria: AC-1 through AC-4 from SPEC-003 § 10.

Do NOT modify the coordinator. Binary changes only.

=== END BUILD PROMPT ===
```

### 12.2. coordinator v0.2 — WS relay + admission + admin endpoints

```
=== BEGIN BUILD PROMPT: coordinator v0.2 ===

Read SPEC-003 §§ 3-6 (architecture, FRs, wire protocol, admission
tiers), § 7.1-7.2 (new messages, new endpoints), and § 9 (D7-D10
amendments).

You are modifying the existing phase4-coordinator (Go). The codebase
is at phase4-coordinator/.

Changes to make:

1. **WS message types** — Add Go structs and parsers for:
   `inference_request`, `inference_response_chunk`,
   `inference_response_end`, `cancel_request` in
   internal/ws/messages.go.

2. **WS-tunneled inference relay** — In internal/buyer/server.go,
   when the selected provider has no `endpoint_url` (WS-tunneled):
   instead of HTTP forwarding, send `inference_request` over the
   provider's WS, await response chunks, relay to buyer.
   For streaming: relay each `inference_response_chunk` as SSE.
   For non-streaming: accumulate chunks, assemble response JSON.

3. **Multiplexing** — Track outstanding request_ids per provider.
   Limit to max_concurrency. Demux responses by request_id.

4. **Cancellation** — Detect buyer disconnect, send cancel_request.
   Free slot on inference_response_end or 10s timeout.

5. **Backpressure** — Per-provider write buffer (64 messages).
   Per-request response timeout (request_timeout_s).

6. **Dynamic admission** — In internal/ws/handler.go, on hello:
   if provider_id in config → pinned. If in rejected_providers →
   close 4009. Otherwise → provisional (rate-limited).

7. **New SQLite tables** — provisional_providers, rejected_providers
   in internal/store/.

8. **New admin endpoints** — GET /admin/provisional,
   POST /admin/promote/{id}, POST /admin/reject/{id} in
   internal/operator/.

9. **Routing weight** — Apply tier_weight multiplier to
   effective_throughput in routing algorithm.

10. **model_id case-insensitive matching** (D9 amendment).

11. **hello_ack amendments** — Add `tier` and
    `recommended_binary_version` fields.

12. **Path selection** — endpoint_url in hello → HTTP-forwarding;
    absent → WS-tunneled. Backward compat with config.providers[]
    endpoint_url fallback.

Acceptance criteria: AC-1 through AC-7, AC-11, AC-12 from SPEC-003
§ 10.

=== END BUILD PROMPT ===
```

### 12.3. install.sh + get.streamvc.live hosting

```
=== BEGIN BUILD PROMPT: install.sh ===

Read SPEC-003 FR-C2 (install.sh contract), FR-C5 (launchd plist),
FR-D2 (model selection), FR-D3 (first-run self-test).

Create:
1. phase5-onboarding/install.sh — POSIX shell script per FR-C2.
2. phase5-onboarding/site/ — static site for get.streamvc.live
   (index.html landing page + install.sh).
3. phase5-onboarding/site/_redirects — Cloudflare Pages redirect
   rules: /install.sh → serve the script with
   Content-Type: text/plain.

The install.sh must:
- Detect platform (Darwin arm64 only)
- Fetch latest GitHub Release
- Verify SHA-256 checksum
- Install binary to ~/.local/bin/
- Interactive model selection based on RAM
- Generate provider_id (UUID)
- Write config.yaml
- Optionally install launchd plist
- Run self-test
- Print summary

Exit codes 0-7 per FR-C2.

Test by running on a local Mac. No coordinator connection needed for
the install flow (self-test coordinator check can warn-only).

Acceptance criteria: AC-8 from SPEC-003 § 10.

=== END BUILD PROMPT ===
```

### 12.4. macprovider-cli update + status + uninstall

```
=== BEGIN BUILD PROMPT: CLI subcommands ===

Read SPEC-003 FR-C3 (update), FR-C4 (status), FR-C6 (uninstall),
FR-C8 (log rotation).

These are Swift subcommands added to the existing phase3-binary CLI.
Modify phase3-binary/Sources/macprovider-cli/ to add:

1. `update` — GitHub API query, download, checksum verify, atomic
   swap, launchd restart if applicable. See FR-C3.

2. `status` — Read local metrics + coordinator state + GitHub API
   version check. Pretty-print. See FR-C4.

3. `uninstall` — Stop launchd, remove files, clean PATH. See FR-C6.

4. `self-test` — Load model, inference, coordinator check. See FR-D3.

5. Log rotation — On startup, rotate files >50 MB. See FR-C8.

Acceptance criteria: AC-9 (update), AC-10 (launchd) from SPEC-003
§ 10.

=== END BUILD PROMPT ===
```

### 12.5. GitHub Releases automation

```
=== BEGIN BUILD PROMPT: GitHub Releases ===

Read SPEC-003 FR-C1 (GitHub Releases shape).

Create:
1. .github/workflows/release.yml — GitHub Action that:
   - Triggers on tag push matching v*
   - Builds macprovider-cli for darwin-arm64
   - Computes SHA-256 checksums
   - Creates GitHub Release with:
     * Tag name as title
     * Auto-generated release notes (from commits since last tag)
     * Binary tarball as asset
     * checksums.txt as asset

2. phase5-onboarding/scripts/release.sh — Manual release script
   (alternative to CI) that:
   - Builds the binary locally
   - Creates the tarball
   - Generates checksums.txt
   - Creates the GitHub Release via gh CLI

Tag format: v{major}.{minor}.{patch}
Asset: macprovider-cli-{version}-darwin-arm64.tar.gz

Acceptance criteria: A release created by the workflow/script matches
FR-C1 shape and is discoverable by install.sh and update subcommand.

=== END BUILD PROMPT ===
```

---

## Appendix A — References used during spec writing

| Source | What was taken |
|---|---|
| `CONTINUE_RUNBOOK.md` | Project state, Phase 1 completion context |
| `HANDOFF.md` | Overall architecture, roadmap, strategic decisions, VPS details |
| `specs/SPEC-001-phase3-binary.md` v1.1.4 | Wire protocol (§ 6.5), hello message fields, drain semantics (v1.1.3/v1.1.4 changes), request validation (§ 6.2), health states, capacity fields, dependencies, clean-room policy |
| `specs/SPEC-002-coordinator.md` v1.0.4 | Request forwarding model (§ 3), routing algorithm (§ 5), static config map (§ 7.1), operator endpoints (§ 7.4), close codes, Finding F-1/F-2/F-3, acceptance criteria pattern |
| `beta/DECISION_CRITERIA.md` | Decision log entries 5–18, Phase 2 baselines, go/no-go criteria, day-2 findings |
| `phase4-coordinator/internal/ws/messages.go` | Existing Go structs (Hello, HelloAck, Heartbeat, StateUpdate, PreflightAck, DrainStatus), parser functions |
| `phase4-coordinator/internal/buyer/server.go` | Current HTTP-forwarding path (handleChatCompletions, forwardStreaming, selectProvider, routing logic) |
| `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` | Existing Swift WS handler (handle(), drainFromCoordinator, helloMessage, reconnect loop) |
| `specs/BUILD_SPEC_002_PROMPT.md` | Structural template, rigor expectations, section ordering |
| `phase3-binary/implementation-notes.html` | Scaffold format for implementation-notes.html |
| OpenAI API reference | SSE streaming format, error envelope shape |
| WebSocket protocol RFC 6455 | Frame format, close codes, fragmentation |

**Clean-room note:** No d-inference source files were read during spec
writing. The WS-tunneled inference architecture is derived from the
"provider has no inbound network" constraint and industry-standard
outbound-worker-pool patterns (documented in § 8.5). The distribution
and lifecycle design follows standard macOS CLI distribution patterns
(Homebrew, Tailscale, Fly.io CLI).
