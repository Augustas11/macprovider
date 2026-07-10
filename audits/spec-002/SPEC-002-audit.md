# SPEC-002 Audit Report

Auditor: Codex GPT-5
Spec audited: SPEC-002 v1.0.0 commit 2d8106e
Audit completed: 2026-05-27T00:15:57Z

## TL;DR verdict

NEEDS REVISION. I found 3 CRITICAL, 9 MAJOR, 5 MINOR, and 1 QUESTION findings. The top risk is that SPEC-002 cannot actually forward buyer traffic without a provider HTTP endpoint, and its preferred fix adds a required `endpoint_url` field to the locked SPEC-001 `hello` message. That is both a build blocker and a protocol-compatibility break unless SPEC-001 is amended before implementation.

## Findings by severity

### CRITICAL (3)

**C1 - Provider endpoint discovery is unresolved and the preferred default changes locked SPEC-001 hello.**

Severity: CRITICAL  
Category: A, E, H  
Section ref: SPEC-002 sections 3, 4, 12; SPEC-001 section 6.5

Quoted spec text:
- "The WebSocket is control plane only ... Inference requests are forwarded as standard HTTP to the provider's reachable endpoint" (section 3).
- "Each provider pool entry tracks ... `endpoint_url`" (FR-P3).
- "SPEC-001 section 6.5 `hello` message does not include the provider's HTTP endpoint URL ... The coordinator needs to know where to forward buyer requests."
- "My default: (a) - propose a SPEC-001 v1.1.2 amendment to add `endpoint_url` (string, required) to the `hello` message."

What is wrong: SPEC-002's core request-forwarding path needs `endpoint_url`, but no Tier 1 requirement defines how the coordinator obtains it without changing SPEC-001. The default answer is to add a required field to the locked `hello` schema. SPEC-001 section 6.5 lists the `hello` fields and does not include `endpoint_url`. Implementing SPEC-002 as written either cannot forward traffic or breaks wire compatibility with the Phase 3 binary.

Fix direction: Patch SPEC-002 in place to choose static config mapping for v1, with a concrete schema and validation behavior. Move the `endpoint_url` amendment idea to a non-default future question unless the operator explicitly amends SPEC-001 first.

**C2 - Provider auth on WebSocket upgrade breaks the current SPEC-001 binary connection contract.**

Severity: CRITICAL  
Category: A, E  
Section ref: SPEC-002 FR-P1, FR-P12, section 7.3; SPEC-001 FR-13

Quoted spec text:
- "The WebSocket upgrade request must include a bearer token in the `Authorization` header (`Bearer <token>`). If the token is missing or invalid, the coordinator rejects the upgrade with HTTP 401" (FR-P1).
- "Provider connects with `Authorization: Bearer <token>`" (FR-P12).
- SPEC-001 says: "Provider authentication to the coordinator is out of scope for this binary (deferred to SPEC-002)."

What is wrong: SPEC-002 defines the server-side auth requirement, but SPEC-001 v1.1.1 has no provider-side token field, config setting, or handshake-header requirement. A Phase 3 binary built strictly from SPEC-001 will open a WebSocket and send `hello`; SPEC-002 will reject it before `hello`. That is a connection-level compatibility break, even though it is outside the JSON message body.

Fix direction: Either define v1 provider auth as optional until SPEC-001 is amended, or add a coordinated SPEC-001 amendment that gives the binary a token config and says it sends `Authorization: Bearer <token>` on the WebSocket upgrade. Do not leave this as a coordinator-only assumption.

**C3 - FR-B7 says "no silent retry" and then permits silent retry for non-streaming requests.**

Severity: CRITICAL  
Category: B, E, I  
Section ref: SPEC-002 FR-B7

Quoted spec text:
- "Clean error on provider failure mid-request (no silent retry)."
- "For non-streaming requests where no response bytes have been sent, the coordinator MAY retry exactly once with a different eligible provider if the failure was a 502 or connection error."

What is wrong: This is an internal contradiction at the level of buyer-visible semantics. The build prompt required "no silent retry to a different provider in v1"; SPEC-002 repeats that in the FR title, then allows a hidden one-hop retry for non-streaming requests. The behavior affects idempotency, provider attribution, latency, and buyer debugging.

Fix direction: Pick one rule. For v1, align with the prompt: no retry to a different provider after a selected provider fails. If retry is intentionally desired, rename the FR, make retry opt-in or visible before routing, and update acceptance criteria.

### MAJOR (9)

**M1 - D1 tunnel-signal requirement is explicitly rejected, not implemented.**

Severity: MAJOR  
Category: A  
Section ref: SPEC-002 section 10; beta decision log D1

Quoted spec text:
- "Coordinator does NOT poll Cloudflare tunnel API - that was a Phase 2 investigation approach."
- Decision log: "Poll `cfd_tunnel` connection count to predict imminent drops."

What is wrong: The SPEC-002 build prompt called out D1 as "coordinator backoff strategy + tunnel polling." SPEC-002 covers HTTP 502 and WebSocket disconnect recovery, but explicitly drops the tunnel polling / `conns_active_at` signal from the source decision log. That may be a defensible simplification, but it is not acknowledged as a rejected requirement with consequences.

Fix direction: Either add a v1 `TunnelHealthProbe` / optional Cloudflare signal hook, or record a clear rejection with why WebSocket plus HTTP status is sufficient and what failure mode is accepted.

**M2 - Capacity-vs-quality routing does not implement the decision-log tradeoff across different model IDs.**

Severity: MAJOR  
Category: A, H  
Section ref: SPEC-002 FR-R1, FR-R2, FR-R4, AC-9

Quoted spec text:
- "model_id matches the request's `model` field exactly."
- "`X-MacProvider-Pref: accurate` routes to Provider B."
- AC-9: "Both serve the same model ID for testing purposes."

What is wrong: D4 was about Llama 3B versus Qwen 7B, meaning different model IDs and a real buyer-facing model-quality tradeoff. SPEC-002's preference header only sorts candidates after exact model filtering, so it cannot auto-route between a faster smaller model and a slower larger model unless the test fakes both providers as the same model. `/v1/models` exposes model choices, but there is no contract for "accurate" to choose a larger model family or for aliases/model classes.

Fix direction: Either state that D4 is covered only by explicit buyer model selection through `/v1/models`, or define a limited model-class/alias mechanism for `fast` versus `accurate`. AC-9 should test the real intended behavior, not a same-model workaround.

**M3 - Provider pinning uses `assigned_id`, but the build prompt and stable operator use case say provider ID.**

Severity: MAJOR  
Category: B, E  
Section ref: SPEC-002 FR-P2, FR-R3, section 7.2

Quoted spec text:
- "`assigned_id` is a coordinator-assigned identifier ... It may differ from `provider_id`."
- "`X-MacProvider-Provider: <assigned_id>`."
- Build prompt: "`X-MacProvider-Provider: <provider_id>` (for testing/A/B)."

What is wrong: Pinning to `assigned_id` makes pin values pool-session-scoped and unstable across reconnects/restarts. That may be useful for debugging one session, but A/B testing usually wants the stable provider identity. SPEC-002 also stores both IDs, so implementers need a rule for which identity buyers and operator tools use.

Fix direction: Decide whether the header accepts stable `provider_id`, session `assigned_id`, or both with explicit precedence. If both are supported, make `/poolz` show both and define ambiguity handling.

**M4 - FR-O5 contradicts the scope item that says pool state is persisted.**

Severity: MAJOR  
Category: B  
Section ref: SPEC-002 section 2, FR-O5

Quoted spec text:
- Scope: "SQLite persistence for provider auth, request log, pool state."
- FR-O5: "SQLite (WAL mode) persists: `provider_tokens`, `request_log`, and `pool_snapshots`."
- FR-O5: "Pool state is NOT persisted for restart restoration. On restart, the pool starts empty."

What is wrong: "Pool state persistence" can mean restorable live routing state, periodic snapshots, or only debugging history. SPEC-002 says both that pool state is in scope and that it is not restored. A build session can satisfy either interpretation and still claim compliance.

Fix direction: Rename the scope item to "periodic pool snapshots for debugging" or define actual restorable pool-state behavior. Do not call snapshots "pool state persistence" if restart restoration is intentionally out.

**M5 - Buyer HTTP API is not a full interface contract; it delegates too much to SPEC-001.**

Severity: MAJOR  
Category: E, H  
Section ref: SPEC-002 section 7.2

Quoted spec text:
- "Request schema: Identical to SPEC-001 section 6.2."
- "Per-message validation: same as SPEC-001 section 6.2."
- "Tool-call validation: same as SPEC-001 section 6.2."

What is wrong: The build prompt required full schemas in SPEC-002 because the coordinator is its own build target. Section 7.2 lists field names but omits the detailed type/range table, message-role rules, tool-call shape, response examples, and context/error differences needed to implement without flipping between specs. This is less severe than SPEC-001's original schema gap because the source exists, but it still fails the "full interface contracts" deliverable.

Fix direction: Copy or summarize the SPEC-001 section 6.2 validation tables into SPEC-002, then explicitly list coordinator-specific replacements for provider Stage 1/2 preflight and queue admission.

**M6 - Warm-up behavior lacks acceptance coverage.**

Severity: MAJOR  
Category: A, F  
Section ref: SPEC-002 FR-P8, AC-8

Quoted spec text:
- FR-P8: "If `last_heartbeat_at` gap > 120s and a new heartbeat arrives, the coordinator sends `{\"type\": \"warm_up\"}`."
- AC-8 tests reconnection and removal, but does not mention `warm_up`.
- Build prompt AC-8 expected "530 from provider -> coordinator removes from pool, sends warm_up after reconnection."

What is wrong: Warm-up dispatch is one of the coordinator-deferred items from the audit prompt. SPEC-002 specifies it, but no acceptance criterion proves it. AC-8 was the natural place to cover post-gap reconnect/wake behavior, yet it only covers reconnection and pool removal.

Fix direction: Add an AC that simulates a heartbeat gap or reconnect-after-gap, asserts `warm_up` is sent, verifies provider is marked `degraded`, and verifies routing resumes only after `state_update: ready` or the 60s fallback.

**M7 - Revocation does not disconnect active revoked providers.**

Severity: MAJOR  
Category: E  
Section ref: SPEC-002 section 7.3, AC-5

Quoted spec text:
- "Existing WS connection persists until next reconnection attempt (which fails). For immediate disconnect, use `/admin/blacklist`."
- AC-5 only tests "Disconnect and reconnect the mock provider with the revoked token - rejected with 401."

What is wrong: Token revocation is specified, but active sessions continue serving traffic indefinitely until a reconnect or manual blacklist. That is a surprising auth contract and weakens "token revocation" as an operator control. If a token leaks while connected, revocation alone does not stop the provider.

Fix direction: Either define revocation as "future connection revocation only" everywhere, or require the coordinator to disconnect active sessions whose token hash is revoked. Add acceptance for the chosen behavior.

**M8 - 502/504 degraded recovery preflight is underspecified for non-request health recovery.**

Severity: MAJOR  
Category: E, H  
Section ref: SPEC-002 FR-P11

Quoted spec text:
- "On 502/504 degraded: after 30s backoff, send preflight. If accepted, mark `ready`."
- SPEC-001 `preflight` requires `request_id` and `estimated_tokens`.

What is wrong: SPEC-001 preflight is a per-buyer-request capacity check, not a standalone health probe. SPEC-002 does not define what `request_id` or `estimated_tokens` the coordinator sends for a recovery probe, nor whether the provider should interpret that as a real pending request. Implementers will invent incompatible sentinel values.

Fix direction: Define a concrete recovery preflight shape that remains legal under SPEC-001, for example a generated `request_id` and a small positive `estimated_tokens`, and state that it is a health probe with no subsequent HTTP request.

**M9 - Operator blacklist removal semantics conflict with drain semantics.**

Severity: MAJOR  
Category: B, E  
Section ref: SPEC-002 FR-P6, FR-P9, AC-10, section 7.4

Quoted spec text:
- FR-P9: "After sending, marks provider `draining` and stops routing. Does NOT close the WebSocket."
- FR-P6: "The coordinator removes the provider from the pool after the WebSocket closes."
- AC-10: "`POST /admin/blacklist` with valid assigned_id removes provider from pool and sends drain."

What is wrong: The requirements say blacklist marks-draining-and-waits, while acceptance says blacklist removes the provider from the pool. Those are different observable `/poolz` behaviors and different routing/debugging semantics.

Fix direction: Define blacklist as either immediate removal plus drain best-effort, or draining state until close. Update AC-10 and `/admin/blacklist` response fields to match.

### MINOR (5)

**m1 - Section 8.2 is not verbatim from SPEC-001 section 7.2.**

Severity: MINOR  
Category: D  
Section ref: SPEC-002 section 8.2

Quoted spec text:
- "This section is replicated from SPEC-001 section 7.2."
- The permitted-reference list is coordinator-specific and differs from SPEC-001's list.

What is wrong: The build prompt requested a verbatim copy. The policy is substantively conservative, but this is not a verbatim replication.

Fix direction: Either copy SPEC-001 section 7.2 exactly and add a short coordinator addendum, or change the claim from "replicated" to "adapted" and accept that it did not meet the prompt's strict wording.

**m2 - Dependency pins are weakened by "starting points" language.**

Severity: MINOR  
Category: H  
Section ref: SPEC-002 section 8.1

Quoted spec text:
- "Version pins are starting points. The build session may bump versions after testing."

What is wrong: The dependency table gives exact module versions, which is good. Calling them "starting points" weakens the implementability guarantee and may let the build session drift without a spec patch.

Fix direction: Say these are the required v1.0 pins unless changed with an explicit implementation-notes entry and a go.mod diff review.

**m3 - AC-6 is still a manual test instead of a reusable command or script.**

Severity: MINOR  
Category: F  
Section ref: SPEC-002 AC-6

Quoted spec text:
- "Run by: Manual test during build. Start 3 concurrent streaming requests, send `kill -TERM <pid>`..."

What is wrong: Most ACs name scripts. AC-6 leaves an important shutdown behavior to ad hoc manual setup.

Fix direction: Add `phase4-coordinator/scripts/test-sigterm-drain.sh` or explicitly mark the manual test as a temporary build-session script requirement.

**m4 - Error-code mapping uses both 404 and 503 for model-not-served cases.**

Severity: MINOR  
Category: B, E  
Section ref: SPEC-002 FR-B8, routing pseudocode, section 7.2

Quoted spec text:
- FR-B8 includes "The requested model is not served by any provider" under 503 scenarios.
- Section 7.2 validation step 6 says "Model exists in pool | 404 `model_not_found`."
- Routing pseudocode returns 503 when candidate list is empty.

What is wrong: A missing model can be "no provider serves this model" or "providers serve it but none are available." SPEC-002 states both 404 and 503 for overlapping cases.

Fix direction: Define the split: 404 when no connected or known provider advertises the model; 503 when the model exists but all matching providers are busy/degraded/draining/unavailable or fail preflight.

**m5 - Open questions include defaults that are no longer really blocking.**

Severity: MINOR  
Category: G  
Section ref: SPEC-002 section 12

Quoted spec text:
- OQ-2: "My default: Caddy."
- OQ-3: "My default: Opaque 32-byte random."
- OQ-4: "My default: Daily file copy."
- OQ-5: "My default: None in v1."

What is wrong: The count is healthy at 5, but four of the questions are defaults dressed as questions. OQ-1 is truly blocking; the others can be moved into requirements or deployment notes.

Fix direction: Keep only unresolved, build-shaping questions in section 12. Move defaults to NFR/security/deployment sections.

### QUESTIONS (1)

**Q1 - Should 530 be modeled as WebSocket disconnect, HTTP 530, or both?**

Severity: QUESTION  
Category: A, E  
Section ref: SPEC-002 FR-P11

Quoted spec text:
- "WS disconnect (530) | WS close, no prior drain"
- Decision log says the observed sequence was "HTTP 502 ... then HTTP 530 (full tunnel disconnect)."

What is uncertain: SPEC-002 equates 530 with WebSocket close, but the Phase 2 observation was an HTTP 530 from the tunnel. If the provider WebSocket and provider HTTP endpoint use different network paths, the coordinator may see HTTP 530 before or without WS close.

Fix direction: Operator should decide whether FR-P11 must handle literal provider HTTP 530 responses as unavailable in addition to unclean WebSocket close.

## SPEC-001 protocol compatibility matrix

| SPEC-001 section 6.5 message | Direction | SPEC-001 shape | SPEC-002 coverage | Auditor verdict |
|---|---|---|---|---|
| `hello` | P->C | `type`, `version`, `tier`, `provider_id`, `hostname`, `model_id`, `model_params_b`, `ram_gb`, `max_context_tokens`, `max_concurrency`, `throughput_tps_estimate`, `binary_version`, `attestation` | FR-P1, FR-P2, FR-P12, FR-P13 | Silent mismatch risk: SPEC-002 needs endpoint/auth data not present in the locked message/connection contract. |
| `hello_ack` | C->P | `type`, `coordinator_version`, `assigned_id`, `heartbeat_interval_s` | FR-P2 | Matches. |
| `heartbeat` | P->C | status plus capacity fields | FR-P4, FR-P8 | Matches; coordinator behavior is defined. |
| `state_update` | P->C | state, reason, since, metrics_snapshot | FR-P5 | Matches. |
| `drain_status` | P->C | phase, inflight_requests, estimated_drain_seconds | FR-P6 | Matches, but blacklist removal semantics conflict elsewhere. |
| `preflight` | C->P | request_id, estimated_tokens | FR-P7, FR-B5, FR-R5 | Matches for buyer requests; recovery preflight in FR-P11 is under-specified. |
| `preflight_ack` | P->C | request_id, accepted, optional reason/context | FR-P7, FR-R5 | Matches. |
| `drain` | C->P | type only | FR-P9, FR-O3 | Matches. |
| `warm_up` | C->P | type only | FR-P8 | Matches, but not covered by ACs. |
| `nak` | P->C | in_reply_to, error code/message | section 7.1 | Matches for receiving provider `nak`. |
| `nak` | C->P | same shape | FR-P2, FR-P13, section 7.1 | Matches. |

## Coverage of Phase 2 decision log

| Decision item | Source requirement | SPEC-002 coverage | Auditor verdict |
|---|---|---|---|
| D1 - 502 vs 530 | Route around 502 with short backoff; remove 530 from pool; poll `cfd_tunnel` connection count | FR-P10, FR-P11, section 10 | Partially covered. Backoff is covered; tunnel polling is explicitly rejected; literal HTTP 530 handling is unclear. |
| D2 / post-wake warm-up | Fire synthetic warm-up after detecting wake/resumption before routing real traffic | FR-P8 | Covered in requirements, but missing acceptance coverage. |
| D4 - capacity-vs-quality | Expose model-size choice or auto-route by latency/quality preference | FR-B1, FR-R2, AC-9 | Partially covered. Explicit model choice exists via `/v1/models`; `accurate` preference only sorts same-model candidates and AC-9 fakes same model ID. |

## What SPEC-002 does well

1. The SPEC-001 section 6.5 message schemas are mostly reproduced accurately; the `preflight_ack` naming regression from the build prompt did not leak into the spec.
2. Provider state handling is concrete: ready/busy/degraded/draining/unavailable have routing eligibility and operational meaning.
3. The routing algorithm is detailed enough for a first implementation once endpoint discovery is fixed.
4. The operator surface is usefully scoped: `/healthz`, `/poolz`, and `/admin/blacklist` are enough for v1 operations.
5. The clean-room policy remains conservative and avoids d-inference source dependency.

## Final verdict recommendation

NEEDS REVISION - patch SPEC-002 in place before coordinator build.

Patch these items first:

1. Resolve provider endpoint discovery without silently changing SPEC-001, preferably static `provider_id -> endpoint_url` config for v1.
2. Resolve provider auth compatibility with SPEC-001: optional in v1 or coordinated SPEC-001 amendment.
3. Remove the FR-B7 retry contradiction; v1 should either have no retry or an explicit visible retry policy.
4. Fix D1/D4 coverage: either implement tunnel-signal/model-choice behavior or explicitly reject/defer it with rationale.
5. Add acceptance for warm-up dispatch and normalize inconsistent pool-removal/model-error semantics.
