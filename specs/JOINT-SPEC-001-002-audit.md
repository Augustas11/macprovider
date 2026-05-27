# Joint Audit - SPEC-001 v1.1.1 + SPEC-002 v1.0.1

Auditor: Codex GPT-5  
Audit completed: 2026-05-27T00:38:33Z  
Specs audited: SPEC-001 v1.1.1 (commit 2d8106e), SPEC-002 v1.0.1 (commit c3a1476)

## TL;DR verdict

**REVISE SPEC-002 ONLY**

SPEC-002 v1.0.1 addresses the largest architectural blockers, but the patch did not land cleanly everywhere. Patch verification result: 13 ADDRESSED / 1 DEFERRED / 4 NOT ADDRESSED / 0 RESOLVED. Cross-spec findings: 0 CRITICAL, 6 MAJOR, 2 MINOR, 1 QUESTION. Top risk: SPEC-002 still extends or contradicts the locked SPEC-001 protocol in small but build-shaping places (`preflight.purpose`, coordinator-to-provider `nak`, and provider pinning header semantics). These are SPEC-002-local fixes; I found no reason to reopen SPEC-001 v1.1.1.

## Part 1 - SPEC-002 v1.0.1 patch verification table

| Finding | Severity | Status | SPEC-002 ref | One-line justification |
|---|---|---|---|---|
| C1 | CRITICAL | ADDRESSED | Section 3, FR-P1, FR-P3, FR-P12, Section 12 | Static `provider_id -> endpoint_url` map chosen; no SPEC-001 `hello` amendment. Config hand-off still needs a schema field, tracked as M-J5. |
| C2 | CRITICAL | ADDRESSED | FR-P1, FR-P12, Section 7.3, Section 12 | WebSocket provider auth is optional in v1; SPEC-001-strict binaries can connect without `Authorization`. |
| C3 | CRITICAL | ADDRESSED | FR-B7, Section 7.2 | Coordinator-managed retry across providers removed from the request path. Config still has stale `routing.retry_on_502`, tracked as M-J6. |
| M1 | MAJOR | ADDRESSED | Section 10 D1 | `cfd_tunnel` polling is explicitly rejected with rationale and accepted failure mode. |
| M2 | MAJOR | DEFERRED | FR-B1, FR-R2, Section 10 D4, AC-9 | Cross-model latency/quality routing is explicitly deferred to SPEC-004; v1 supports exact model selection plus same-model preference. |
| M3 | MAJOR | NOT ADDRESSED | FR-R3, Section 7.2 | FR-R3 fixes stable `provider_id`, but Section 7.2 still says `X-MacProvider-Provider` is `assigned_id`, reintroducing the ambiguity. |
| M4 | MAJOR | ADDRESSED | FR-O5, Section 7.4 | Pool state is reframed as snapshots/history, not restart restoration. |
| M5 | MAJOR | ADDRESSED | Section 7.2 | Buyer request schema and validation tables are now inline and mostly self-contained. |
| M6 | MAJOR | ADDRESSED | AC-8b | Warm-up dispatch has acceptance coverage. A degraded-routing conflict in AC-8b is tracked as m-J2. |
| M7 | MAJOR | ADDRESSED | Section 7.3 | Revocation is explicitly future-connection-only; blacklist/revoke-and-kick handle active sessions. |
| M8 | MAJOR | NOT ADDRESSED | FR-P11 | Recovery preflight shape is concrete, but adds `purpose`, which SPEC-001 Section 6.5 does not tolerate explicitly. |
| M9 | MAJOR | NOT ADDRESSED | Section 7.4, AC-10 | Section 7.4 defines two-phase blacklist removal, but AC-10 still says "removes provider from pool and sends drain." |
| m1 | MINOR | ADDRESSED | Section 8.2 | Clean-room section now says "adapted" rather than claiming verbatim replication. |
| m2 | MINOR | ADDRESSED | Section 8.1 | Required pins are stated; bumps require implementation-notes justification. |
| m3 | MINOR | ADDRESSED | AC-6 | SIGTERM drain now names `phase4-coordinator/scripts/test-sigterm-drain.sh`. |
| m4 | MINOR | ADDRESSED | Section 7.2 | 404 unknown model vs 503 known-but-unavailable split is clarified. |
| m5 | MINOR | ADDRESSED | Section 12 | Defaults moved under "Defaults already chosen"; only HTTP 530 remains as an open item. |
| Q1 | QUESTION | NOT ADDRESSED | Section 10, Section 12 | Literal HTTP 530 still appears as OQ-1; the default is stated, but the spec has not resolved it into a requirement. |

## Part 2 - Cross-spec consistency findings

### CRITICAL (0)

No CRITICAL joint mismatch found. The remaining defects are serious enough to block a clean parallel build start, but they are patchable inside SPEC-002 without changing SPEC-001's locked wire protocol.

### MAJOR (6)

**M-J1 - Recovery preflight adds `purpose`, but SPEC-001 does not explicitly tolerate extra WebSocket fields.**  
Severity: MAJOR  
Subsection: 2.1, 2.5  
Section refs: SPEC-001 Section 6.5; SPEC-002 FR-P11 / Section 7.1

SPEC-001 defines `preflight` as:
```json
{
  "type": "preflight",
  "request_id": "buyer-req-uuid",
  "estimated_tokens": 8500
}
```

SPEC-002 defines recovery preflight as:
```json
{
  "type": "preflight",
  "request_id": "recovery-probe-<uuid>",
  "estimated_tokens": 128,
  "purpose": "health_recovery"
}
```

What's wrong: SPEC-002 says "`purpose` field is additive metadata (SPEC-001 Section 6.5 tolerates extra fields)", but SPEC-001 Section 6.5 does not say unknown WebSocket fields are tolerated. SPEC-001 only explicitly tolerates unknown top-level fields for the HTTP chat request in Section 6.2. A Swift builder using a strict decoder could reject or `nak` the recovery probe.

Fix direction: Patch SPEC-002 to remove `purpose` from the wire message and keep `recovery-probe-` as the only discriminator, or explicitly state that the coordinator MUST NOT rely on provider-side interpretation of extra fields. Do not amend SPEC-001 for this.

**M-J2 - SPEC-002 introduces coordinator-to-provider `nak`, while SPEC-001 defines `nak` only as provider-to-coordinator.**  
Severity: MAJOR  
Subsection: 2.1  
Section refs: SPEC-001 Section 6.5; SPEC-002 FR-P2, FR-P12, FR-P13, Section 7.1

SPEC-001 says "`Negative acknowledgement (P->C) - protocol error response`" and "Sent when the binary receives a malformed or unrecognized coordinator message." SPEC-002 says "`nak` (P->C or C->P)" and also sends `nak` for invalid `hello`, unknown `provider_id`, and unsupported tier.

What's wrong: The locked SPEC-001 message catalog does not define a C->P `nak`. Rejection behavior is needed, but SPEC-002 cannot claim exact SPEC-001 compatibility while adding a reverse-direction message.

Fix direction: Patch SPEC-002 to reject invalid provider handshakes with WebSocket close codes/reasons, or mark C->P `nak` as coordinator-local best-effort that SPEC-001 binaries are not required to parse. Prefer close reason plus log over a new locked-protocol message.

**M-J3 - Provider pinning header semantics still contradict themselves.**  
Severity: MAJOR  
Subsection: 2.2  
Section refs: SPEC-001 Section 6.0-6.4; SPEC-002 FR-R3, Section 7.2

SPEC-002 FR-R3 says "`X-MacProvider-Provider: <provider_id>`" and "The header value is the stable `provider_id`." SPEC-002 Section 7.2 later says "`X-MacProvider-Provider` | string | Provider `assigned_id` for pinning (FR-R3)." The same Section 7.2 table omits `X-MacProvider-Session`, even though FR-R3 defines it.

What's wrong: This is the exact M3 ambiguity reintroduced in the build-facing HTTP API section. A Go builder following Section 7.2 could implement the old assigned_id behavior.

Fix direction: Patch Section 7.2 custom request headers: `X-MacProvider-Provider` = stable `provider_id`; add `X-MacProvider-Session` = session `assigned_id`; restate precedence from FR-R3.

**M-J4 - HTTP 530 remains an open question despite the patch log claiming it was resolved.**  
Severity: MAJOR  
Subsection: 2.7, 2.10  
Section refs: SPEC-001 FR-15 / Section 8 D1; SPEC-002 FR-P11, Section 10 D1, Section 12

SPEC-001 says "A WebSocket close without a prior `draining` message indicates an unclean disconnect (the 530-equivalent from D1)." SPEC-002 Section 10 says "v1 default is yes (logged via `state_update.reason = \"http_530_observed\"`)." But Section 12 still has "OQ-1. HTTP 530 vs WebSocket close - should the coordinator handle literal HTTP 530 as a distinct failure signal?"

What's wrong: The joint prompt required Q1 to be RESOLVED. SPEC-002 still labels it open and gives options, so a coordinator builder must decide whether literal HTTP 530 is requirement (a), fallback (b), or merely a default.

Fix direction: Patch SPEC-002 to remove OQ-1 and make option (a) a normative FR-P11 requirement: literal provider HTTP 530 marks provider unavailable, logs `http_530_observed`, and triggers WebSocket liveness check.

**M-J5 - Static endpoint discovery lacks a concrete config schema in the implementation hand-off.**  
Severity: MAJOR  
Subsection: 2.3  
Section refs: SPEC-001 FR-13 / Section 6.5; SPEC-002 Section 3, FR-P3, FR-P12, Section 13

SPEC-001 `hello` intentionally has no `endpoint_url`, which matches SPEC-002's static-map design. SPEC-002 says the coordinator obtains endpoint URLs from a "static configuration map keyed by `provider_id`." However Section 13 `coordinator.yaml` key list does not include any `providers`, `provider_endpoints`, or `provider_id -> endpoint_url` field.

What's wrong: The cross-spec design is coherent, but implementability is not. The required C1 fix asked for "a concrete schema and validation behavior." Validation behavior is present; config shape is not in the hand-off.

Fix direction: Patch SPEC-002 Section 13 with a concrete YAML shape, for example `providers: [{provider_id, endpoint_url, display_name?}]`, and require startup validation for duplicate IDs and invalid URLs.

**M-J6 - `routing.retry_on_502` contradicts the no-retry v1 contract.**  
Severity: MAJOR  
Subsection: 2.7  
Section refs: SPEC-001 Section 6.2 error responses; SPEC-002 FR-B7, Section 7.2, Section 13

SPEC-002 FR-B7 says "no retry in v1" and "does NOT retry with a different provider." SPEC-002 Section 7.2 also says "No retry header in v1." But Section 13 lists `routing.retry_on_502` with default `true`.

What's wrong: The config key reopens C3. A builder could reasonably implement coordinator-managed retries because the hand-off exposes a true retry flag.

Fix direction: Remove `routing.retry_on_502` from v1 config, or rename it to the recovery behavior it actually controls, such as `pool.degraded_probe_after_502`.

### MINOR (2)

**m-J1 - Header namespace section misses two headers that SPEC-002 now defines.**  
Severity: MINOR  
Subsection: 2.2  
Section refs: SPEC-001 Section 6.0-6.4; SPEC-002 FR-R3, Section 7.2

SPEC-001 does not reserve or emit any `X-MacProvider-*` headers, so there is no collision. SPEC-002 defines request `X-MacProvider-Session` in FR-R3 and response `X-MacProvider-Provider` in Section 7.2, but the Section 7.2 custom-header table only lists `X-MacProvider-Pref` and `X-MacProvider-Provider`.

Fix direction: Normalize one header table in SPEC-002 covering request and response headers.

**m-J2 - AC-8b's degraded fallback wording conflicts with the main routing rules.**  
Severity: MINOR  
Subsection: 2.1, 2.10  
Section refs: SPEC-001 FR-15/FR-16; SPEC-002 FR-P8, FR-R4, AC-8b

SPEC-001 treats `degraded` as warm-up in progress. SPEC-002 FR-P8 says it waits for `state_update: ready` or 60s before routing. FR-R4 filters to "`state` is `ready`." AC-8b says while degraded, requests route to it "ONLY if no other ready provider serves the same model."

What's wrong: AC-8b introduces a last-resort degraded routing policy that the requirements do not define. This is less severe than the retry/header issues because implementers will likely follow FR-R4, but tests would be ambiguous.

Fix direction: Change AC-8b to assert no routing while `degraded` until ready or 60s fallback, or add a normative degraded-last-resort rule to FR-R4 and FR-P8.

### QUESTIONS (1)

**Q-J1 - Is the accepted v1 rule for literal HTTP 530 option (a)?**  
Severity: QUESTION  
Subsection: 2.7, 2.10  
Section refs: SPEC-002 Section 10, Section 12

I infer the intended answer is yes, option (a), because Section 10 says the v1 default is to log `http_530_observed` and mark unavailable. But because Section 12 still labels this as OQ-1, the spec content alone does not make it fully normative.

Fix direction: Resolve by editing SPEC-002 only; no operator architecture choice appears necessary.

### No-finding coverage notes

| Subsection | Result |
|---|---|
| 2.4 Auth posture | No finding. SPEC-001 says provider authentication is out of binary scope and deferred to SPEC-002; SPEC-002 path A accepts no `Authorization` header, so SPEC-001-strict binaries remain valid. |
| 2.6 Tier 2 hook compatibility | No finding. SPEC-001 hook locations (`TrustGate`, `InputDecryptor`, `ResponseSeal`, `AttestationProvider`) and SPEC-002 hook locations (`AttestationVerifier`, `BuyerEncryptionRelay`, `TrustChainAuditor`) use different names but compose by layer: coordinator relays buyer payload, binary decrypts before Stage 2 tokenization, coordinator audits after provider response. |
| 2.8 Dependency family consistency | No finding. The stacks are intentionally separate: Swift/macOS provider binary and Go/Linux coordinator. I did not perform network tag verification; no shared wire-protocol library mismatch appears in the specs. |
| 2.9 Reference hygiene | No finding. Both specs use the same NOASSERTION / DARKBLOOM LICENSE AGREEMENT rationale and prohibit d-inference source, README/config files, and source-quoting third-party analyses. |

### Joint decision-log coverage

| Decision log item | SPEC-001 side | SPEC-002 side | Verdict |
|---|---|---|---|
| D1 - 502 vs 530 | FR-13/FR-15 report state and unclean disconnect | FR-P10/FR-P11 handle 502 backoff and WS disconnect; literal HTTP 530 still open | PARTIAL |
| D2 - post-wake throughput dip | FR-16 warm-up hook and degraded state | FR-P8 dispatches `warm_up`; AC-8b covers dispatch but has degraded-routing wording drift | PARTIAL |
| D3 - stop-token leakage | FR-6 defensive stripping | Not coordinator behavior | COVERED |
| D4 - capacity-vs-quality | FR-17/FR-20 advertise model, capacity, throughput | FR-B1/FR-R2 expose models and same-model preference; broader cross-model routing deferred | COVERED for v1 scope |
| D5 - timeline compression | Process-only, explicitly excluded | Process-only, explicitly excluded | COVERED |

## Part 3 - Implementability gate verdict

### Per-spec clarifications a builder would still need

SPEC-001 v1.1.1:
1. None required for the joint build beyond normal implementation detail. SPEC-001's remaining open questions are binary-local and do not block coordinator integration.

SPEC-002 v1.0.1:
1. What exact `coordinator.yaml` schema carries the static `provider_id -> endpoint_url` map?
2. Is `X-MacProvider-Provider` stable `provider_id` everywhere, with `X-MacProvider-Session` for `assigned_id`?
3. Is literal upstream HTTP 530 a normative unavailable signal, and should `routing.retry_on_502` be removed?

### Cross-spec clarifications

Target was 0. Current count: 2.

1. Can the coordinator send extra fields in SPEC-001 WebSocket messages? SPEC-001 does not say yes; SPEC-002 assumes yes for `preflight.purpose`.
2. Can the coordinator send `nak` to the provider? SPEC-001 defines only provider-to-coordinator `nak`.

### Mock infra sufficiency verdict

Not sufficient yet for parallel build start. The mock coordinator for SPEC-001 can be built from SPEC-001 Section 6.5. The mock provider for SPEC-002 can be built for the happy path, but AC-7, AC-8b, and AC-10 are ambiguous until `preflight.purpose`, degraded routing, HTTP 530, and blacklist removal assertions are normalized.

## Joint protocol/header/error matrices

### SPEC-001 Section 6.5 message field x SPEC-002 handling

| Field path | SPEC-001 says | SPEC-002 says | Verdict |
|---|---|---|---|
| `hello.type` | `hello` | required, validates | match |
| `hello.version` | required number `1` | only supported protocol version `1` | match |
| `hello.tier` | required `1`; Tier 2 future | rejects `tier != 1` | match |
| `hello.provider_id` | required string | static config key and stable provider identity | match |
| `hello.hostname` | required string | required typed field | match |
| `hello.model_id` | required string | pool model key | match |
| `hello.model_params_b` | required number | capacity/routing field | match |
| `hello.ram_gb` | required number | capacity field | match |
| `hello.max_context_tokens` | required number | routing prefilter | match |
| `hello.max_concurrency` | required number | pool capacity | match |
| `hello.throughput_tps_estimate` | required number | `fast` preference input | match |
| `hello.binary_version` | required string | stored in pool | match |
| `hello.attestation` | `null` in Tier 1 | accepted, Tier 2 rejected by `tier` | match |
| `hello_ack.type` | `hello_ack` | sent after valid hello | match |
| `hello_ack.coordinator_version` | required number | `1` | match |
| `hello_ack.assigned_id` | pool-scoped ID | generated UUID, session ID | match |
| `hello_ack.heartbeat_interval_s` | may override interval | configurable default 30 | match |
| `heartbeat.status` | state string | implicit state update if changed | match |
| `heartbeat.model_id` | repeated static field | updates pool | match |
| `heartbeat.model_params_b` | repeated static field | updates pool | match |
| `heartbeat.ram_gb` | repeated static field | updates pool | match |
| `heartbeat.max_context_tokens` | repeated static field | updates pool | match |
| `heartbeat.max_concurrency` | repeated static field | updates pool | match |
| `heartbeat.slots_free` | dynamic capacity | routing eligibility | match |
| `heartbeat.slots_total` | dynamic capacity | pool state | match |
| `heartbeat.throughput_tps_estimate` | repeated measured estimate | preference routing | match |
| `heartbeat.requests_served_since_last` | metric | stored/logged | match |
| `heartbeat.avg_latency_ms_since_last` | metric | stored/logged | match |
| `heartbeat.throughput_tps_since_last` | metric | stored/logged | match |
| `state_update.state` | ready/busy/degraded/draining/unavailable | same enum | match |
| `state_update.reason` | free-form string | logs values including `http_530_observed` | match |
| `state_update.since` | timestamp string | logged | match |
| `state_update.metrics_snapshot.*` | slots and metrics | updates pool metrics | match |
| `drain_status.phase` | starting/in_progress/complete | same phases | match |
| `drain_status.inflight_requests` | number | logged | match |
| `drain_status.estimated_drain_seconds` | number | logged | match |
| `preflight.type` | `preflight` | `preflight` | match |
| `preflight.request_id` | string | buyer UUID or `recovery-probe-<uuid>` | match |
| `preflight.estimated_tokens` | number | buyer estimate or 128 recovery probe | match |
| `preflight.purpose` | not defined | `health_recovery` in FR-P11 | finding M-J1 |
| `preflight_ack.request_id` | echo request ID | correlates response | match |
| `preflight_ack.accepted` | boolean | routing decision | match |
| `preflight_ack.estimated_wait_ms` | present on success/queue | used/logged | match |
| `preflight_ack.reason` | optional known reasons | same reasons | match |
| `preflight_ack.max_context_tokens` | optional for context reject | used/logged | match |
| `drain.type` | C->P `drain` | sent on SIGTERM/blacklist | match |
| `warm_up.type` | C->P `warm_up` | sent after wake detection | match |
| `nak.in_reply_to` | P->C only | P->C or C->P | finding M-J2 |
| `nak.error.code` | protocol error string | also `unknown_provider_id`, `tier_unsupported` | finding M-J2 |
| `nak.error.message` | string | string | match shape, direction mismatch |

### Custom HTTP header x spec that defines x spec that references

| Header | Direction | SPEC-001 | SPEC-002 definition/reference | Verdict |
|---|---|---|---|---|
| `X-MacProvider-Pref` | Buyer request | Not used/reserved | FR-R2, Section 7.2 | match, no collision |
| `X-MacProvider-Provider` | Buyer request | Not used/reserved | FR-R3 says stable `provider_id`; Section 7.2 says `assigned_id` | finding M-J3 |
| `X-MacProvider-Session` | Buyer request | Not used/reserved | FR-R3 defines `assigned_id`; Section 7.2 table omits | finding M-J3/m-J1 |
| `X-MacProvider-Route` | Coordinator response | Provider binary does not emit | Section 7.2 response header with `assigned_id` | match |
| `X-MacProvider-Provider` | Coordinator response | Provider binary does not emit | Section 7.2 response header with stable `provider_id` | match, table should include |
| `Authorization` | Provider WS upgrade | SPEC-001 says provider auth out of scope | SPEC-002 optional path A/B | match |
| `Authorization` | Operator endpoints | Not applicable | required for `/poolz`, `/admin/blacklist` | match |

### HTTP status code x meaning in SPEC-001 x meaning in SPEC-002

| Status | SPEC-001 meaning | SPEC-002 meaning | Verdict |
|---|---|---|---|
| 200 | Successful models/chat/health when ready | Successful aggregated models/chat/operator health | compatible |
| 400 | Invalid JSON/request/tool shape | Same request/tool validation | compatible |
| 401 | Not used for provider binary HTTP | Buyer auth future; operator auth; provider token path B | compatible, different surfaces |
| 404 | Unknown path or model mismatch | Unknown model (`model_not_found`) or operator target missing | compatible |
| 405 | Wrong method with `Allow` | Not prominently repeated | minor omission only |
| 413 | Provider context too large | Coordinator prefilters/preflights instead of returning 413 in routing path | compatible by design; provider 413 is upstream failure if reached |
| 429 | Provider queue full | Future rate limiting, not v1 | compatible, different layer |
| 500 | Not expected; bug if escaped | AC requires zero coordinator 500s | compatible |
| 502 | Provider HTTP layer/inference failure if escaped through endpoint | Coordinator selected provider failed; buyer gets `provider_failed`/`provider_error` | compatible if no retry; config M-J6 conflicts |
| 503 | Provider model not loaded or draining | No eligible provider / known model unavailable | compatible, coordinator abstracts provider availability |
| 504 | Not defined by SPEC-001 table | Provider timeout at coordinator | compatible, coordinator-only |
| 530 | Observed Cloudflare edge signal, 530-equivalent WS close in SPEC-001 | Still open as literal HTTP 530 vs WS close | question Q-J1 |

## What this spec pair does well

1. The core provider WebSocket schema is mostly aligned: `hello`, `hello_ack`, `heartbeat`, `state_update`, `drain_status`, `preflight_ack`, `drain`, and `warm_up` all compose cleanly.
2. Endpoint discovery is architecturally resolved the right way for v1: SPEC-001 does not need to know its public endpoint URL.
3. Provider WebSocket auth is now compatible with SPEC-001-strict binaries while leaving a clear token path for a later amendment.
4. The decision-log split is mostly coherent: SPEC-001 advertises health/capacity, SPEC-002 routes, backs off, and exposes buyer/operator controls.
5. The clean-room policy is materially consistent across both specs and uses the same NOASSERTION / DARKBLOOM LICENSE AGREEMENT rationale.

## Final verdict recommendation

**REVISE SPEC-002 ONLY.** Do an in-place SPEC-002 v1.0.2 patch round; do not modify SPEC-001.

Patch items, in order:

1. Remove or legalize `preflight.purpose`; do not send fields outside SPEC-001 Section 6.5 unless SPEC-002 explicitly treats them as non-required and best-effort.
2. Remove C->P `nak` from the compatibility contract, or replace it with WebSocket close codes/reasons for provider rejection.
3. Normalize all header tables and routing text: stable `X-MacProvider-Provider`, session `X-MacProvider-Session`, response `X-MacProvider-Route`.
4. Resolve HTTP 530 into a normative FR-P11 rule and delete OQ-1.
5. Add concrete static endpoint-map YAML schema and remove stale `routing.retry_on_502`.
6. Update AC-8b and AC-10 so tests match the normative routing and blacklist semantics.

Builds may start: **NO**. Builds blocked on: **SPEC-002 v1.0.2 patch pass**.
