# Cross-spec coherence audit (SPEC-001 v1.2.2 + SPEC-002 v1.1.3 + SPEC-003 v0.5 + SPEC-006 v0.2)

## Round 1 (Codex, 2026-05-28T23:08:46Z)

### Summary
- 0 CRITICAL findings
- 5 MAJOR findings
- 3 MINOR findings
- 1 QUESTION

### CRITICAL findings

None.

### MAJOR findings

**M1 - Provider onboarding still depends on a public `/v1/pool/check` surface that SPEC-006 hides.**

Locations across multiple specs:
- SPEC-006 § 4.2-4.3 says `api.malibu.tech` exposes only the public buyer allowlist and that public `/v1/*` traffic must flow through the gateway; coordinator buyer listener moves to `127.0.0.1:8443`.
- SPEC-003 § 5 requires the installer/status path to prove coordinator visibility.
- Current `phase3-binary/dist/install.sh` defaults to `https://coordinator.malibu.tech` and polls `/v1/pool/check?provider_id=...`.
- Current coordinator code exposes `GET /v1/pool/check` on the buyer server and returns `provider_id`, `tier`, and `state`.

Finding:
The stranger-install path now relies on `GET /v1/pool/check`, but that endpoint is not normatively defined in SPEC-002 or SPEC-003 and is not listed in SPEC-006's public gateway allowlist. After the SPEC-006 migration, the coordinator buyer listener is local-only, so a clean provider install can succeed locally and still fail the coordinator visibility step because its only public check endpoint disappeared.

Why it matters:
This is the same class as the prior install false-negative bugs: the production install path can report degraded/failure even when the provider is actually connected. It is also an implicit public surface carrying provider identity state.

Recommended fix:
Patch SPEC-002 v1.1.4 and SPEC-003 v0.6 together. SPEC-002 should normatively define `GET /v1/pool/check?provider_id=...` if it remains a supported provider-onboarding endpoint, including status codes, response shape, rate limiting, and whether it is public after the gateway migration. SPEC-003 should point the installer at that normative endpoint. If the endpoint should not remain public, patch SPEC-003 v0.6 to use a different visibility proof, and patch SPEC-006 v0.3 to document the migration behavior.

**M2 - Streaming client-disconnect quota settlement asks for actual partial tokens, but upstream contracts do not deliver them.**

Locations across multiple specs:
- SPEC-006 § 7.2 and § 17.6-17.7 require client-disconnect settlement to `prompt + actual completion` generated before disconnect.
- SPEC-001 § 6.6 says `usage` is present when `inference_response_end.status == "complete"`; `cancel_request` produces a cancelled end, not a partial-usage contract.
- Current coordinator streaming relay cancels upstream and returns immediately on buyer disconnect; relay cancellation removes active state and does not wait for a final usage-bearing end frame.

Finding:
SPEC-006's quota rule depends on a token signal that SPEC-001 and SPEC-002 do not guarantee on cancellation. The gateway can count bytes/chunks it already relayed, but "actual tokens generated up to disconnect" is not available as a cross-layer contract.

Why it matters:
This can produce quota/accounting bugs in the first public API implementation: either disconnects block waiting for impossible usage, or the gateway silently estimates while the spec claims actual accounting.

Recommended fix:
Patch SPEC-006 v0.3 to state that disconnect settlement uses provider-reported partial usage when present, otherwise a deterministic gateway estimate from relayed content. If exact partial usage is required, patch SPEC-001 v1.2.3 and SPEC-002 v1.1.4 to add `usage` on cancelled `inference_response_end` and require the coordinator/gateway path to wait for that terminal frame within a bounded timeout.

**M3 - Gateway usage/audit events and coordinator `request_log` have no correlation contract.**

Locations across multiple specs:
- SPEC-002 FR-B9 defines coordinator `request_log.request_id` as a UUID assigned by the coordinator.
- SPEC-006 § 5.1 requires gateway `X-Request-ID`; § 14.3 defines `usage_events` and `audit_events`.
- SPEC-006 § 1.5 says the coordinator remains responsible for request logging while the gateway owns buyer identity, quota, public errors, and audit events.

Finding:
The specs define two operator log streams but do not say whether they are independent, synchronized, or joinable. SPEC-006 does not require forwarding gateway `X-Request-ID` to the coordinator, and SPEC-002 does not accept or record that ID. A provider failure can therefore have buyer quota/audit evidence in one store and provider route evidence in another with no normative join key.

Why it matters:
Operator investigations into 502/504, quota disputes, provider reliability, and abuse need a full request picture. Without a join contract, the first production incident will require ad hoc log archaeology.

Recommended fix:
Patch SPEC-006 v0.3 and SPEC-002 v1.1.4. Make gateway `X-Request-ID` the cross-layer correlation ID, forward it to the coordinator under a documented header such as `X-Request-ID`, and have SPEC-002 record it alongside its internal `request_id`. State that gateway `usage_events` are authoritative for buyer quota/accounting, while coordinator `request_log` is authoritative for routing/provider diagnostics.

**M4 - SPEC-006 capacity tiers are not explicitly independent from SPEC-002 provider/admission tiers.**

Locations across multiple specs:
- SPEC-006 § 10 defines Tier 1/2/3 capacity-burst actions: close signups, tighten quota, hard pause.
- SPEC-002 § 5 and § 7.5 define provider admission tiers and routing weights: pinned/provisional/rejected.
- SPEC-003 onboarding uses provisional admission for new providers.

Finding:
The term "tier" now names two independent state machines. SPEC-006 never explicitly says capacity Tier 1/2/3 is gateway-side only and does not mutate SPEC-002 provider admission tier, provisional routing weight, or provider eligibility.

Why it matters:
This is not an implementation blocker by itself, but it is a likely first-month patch: an implementer could incorrectly cascade capacity Tier 1 "close signups" into coordinator provisional admission or provider routing weights.

Recommended fix:
Patch SPEC-006 v0.3. Add a short "relationship to SPEC-002 admission tiers" paragraph in § 10: capacity tiers affect buyer signup/quota/kill-switch behavior only; they do not alter SPEC-002 provider admission tier, provider routing weight, or existing provider eligibility unless a future spec says so.

**M5 - SPEC-006 promises `logprobs` syntactic support, but SPEC-001/SPEC-002 only cover it via unknown-field tolerance.**

Locations across multiple specs:
- SPEC-006 § 5.4 lists `logprobs` as a supported request field and says it is accepted syntactically.
- SPEC-001 § 6.2 and SPEC-002 § 7.2 list supported optional chat fields but do not list `logprobs`; they say unknown top-level fields are ignored.
- Current coordinator forwards the original request body, and current binary ignores unknown top-level fields.

Finding:
End-to-end behavior is probably safe because the body is forwarded and unknown fields are ignored, but the spec contract is imprecise: `logprobs` is not actually a syntactically validated field in SPEC-001/002, only an ignored unknown field.

Why it matters:
OpenAI SDKs may send `logprobs`/`top_logprobs`. If SPEC-006 calls this "supported", tests may assert validation or response semantics that upstream layers do not provide.

Recommended fix:
Patch SPEC-006 v0.3 to downgrade the promise to "accepted as an ignored forward-compatible field" unless provider support is added. Alternatively patch SPEC-001 v1.2.3 and SPEC-002 v1.1.4 to list `logprobs` and `top_logprobs` as optional ignored fields with exact type tolerance.

### MINOR findings

**m1 - Dependency lines are stale in SPEC-002 and SPEC-003.**

Locations across multiple specs:
- SPEC-002 line 4 says `Depends on: SPEC-001 v1.2.1`.
- SPEC-003 line 4 says `Depends on: SPEC-001 v1.2.1, SPEC-002 v1.1.2`.
- SPEC-006 correctly depends on SPEC-001 v1.2.2, SPEC-002 v1.1.3, SPEC-003 v0.5.

Finding:
The corpus dependency declarations do not all point at the locked versions being composed in this audit.

Recommended fix:
Patch SPEC-002 v1.1.4 dependency line to SPEC-001 v1.2.2. Patch SPEC-003 v0.6 dependency line and stale internal cross-references to SPEC-001 v1.2.2 and SPEC-002 v1.1.3.

**m2 - SPEC-006 inherits SPEC-002 audit vocabulary but not SPEC-003's shell-script integration-test category.**

Locations across multiple specs:
- SPEC-003 § 10 requires integration tests for shell-script paths touching real OS resources.
- SPEC-006 § 19 inherits the SPEC-002 always-non-nil gate lesson but does not mention the SPEC-003 shell-script lesson.
- SPEC-006 § 12 and § 13 include front-door/docs/account user-shaped paths that will interact with the provider installer story.

Finding:
The cross-spec audit-category vocabulary is not fully carried forward. SPEC-006 captures the Entry 19 gate lesson but not the Entry 20 stranger-install lesson.

Recommended fix:
Patch SPEC-006 v0.3 § 19 to add an audit category for user-shaped integration paths that cross shell/web/API boundaries, explicitly referencing SPEC-003's "real OS resources require integration tests" lesson.

**m3 - SPEC-006's "do not modify upstream specs" rule conflicts with cross-spec patch routing.**

Locations across multiple specs:
- SPEC-006 § 1.8 says SPEC-001 and SPEC-002 are locked, read-only references, and SPEC-006 must not propose changes to them.
- Cross-spec findings M1, M2, and M3 have cleaner fixes when SPEC-002 and sometimes SPEC-001 are patched in their next versions.

Finding:
This was appropriate for the per-SPEC-006 audit, but it is too rigid for corpus composition. Cross-spec drift can require small upstream spec patches.

Recommended fix:
Patch SPEC-006 v0.3 to scope that rule to SPEC-006-only implementation/fix passes, not corpus-level cross-spec audits or coordinated version bumps.

### QUESTIONS

**Q1 - Should `/v1/pool/check` be treated as provider-private, buyer-public, or gateway-public?**

This audit found the endpoint in current code and install flow, but not as a normative endpoint in the four locked specs. The operator should decide its long-term ownership before Phase 5: either make it a SPEC-002 provider-onboarding endpoint that remains reachable at `coordinator.malibu.tech`, move it behind the gateway with a redacted response, or remove it from the installer/status path.

### Category coverage notes

- α: Wire-contract continuity mostly composes; see M2 for cancellation usage and M5 for `logprobs` precision.
- β: Implicit surfaces found; see M1/Q1 for `/v1/pool/check`. Header stripping covers the known provider pinning headers.
- γ: Failure-mode story mostly composes for drain/reconnect/restart; see M2 for disconnect settlement and M4 for capacity-tier ambiguity.
- δ: Operator-decision consistency mostly composes; see m1 for stale dependency lines.
- ε: Backward compatibility preserved for legacy providers and direct tunnels; no finding.
- ζ: Distribution-channel story has one important gap; see M1.
- η: Audit-log coherence has a gap; see M3.
- θ: Network state ownership mostly composes; see M3 for usage/request-log authority wording.
- κ: SPEC-006 v0.2 regression findings remain single-spec AC text issues; no additional cross-spec implication found.

### Self-verification

- [x] Read all four spec documents at their current versions.
- [x] Walked all categories α through κ.
- [x] For each finding, the proposed fix specifies WHICH spec(s) to patch and at what next version.
- [x] Code-surface verifications consulted: coordinator buyer server, WS server/messages/relay, `/poolz`, coordinator main, Swift coordinator client, Swift request/HTTP server, and install.sh.
- [x] Severity applied per cross-spec definitions: no production-incident-class CRITICAL; MAJORs are first-month patch risks; MINORs are dependency/vocabulary/governance drift.

### Verdict

READY WITH NARROW PATCHES

The four-spec corpus is architecturally coherent: gateway/coordinator/provider ownership boundaries are sound, provider identity is hidden from public buyers by SPEC-006, and the main chat/model/status paths have plausible end-to-end contracts. It is not ready to lock unchanged because the provider onboarding visibility endpoint, disconnect usage accounting, log correlation, and a few vocabulary/version drifts need narrow spec patches before Phase 5 implementation.

## Round 2 (Claude, 2026-05-29T14:30:00Z)

### Summary
- 0 CRITICAL findings
- 7 MAJOR findings
- 6 MINOR findings
- 2 QUESTIONS

### CRITICAL findings

None.

### MAJOR findings

**M2.1 - Coordinator response headers not explicitly named in SPEC-006 strip list (provider ID leak risk).**

Locations across multiple specs:
- SPEC-002 § 7.2 normatively defines two coordinator-to-buyer response headers: `X-MacProvider-Provider: <provider_id>` and `X-MacProvider-Route: <assigned_id>`.
- SPEC-006 § 5.4 explicitly lists request headers to strip (`X-MacProvider-Provider`, `X-MacProvider-Session`, and `X-MacProvider-*` catch-all) but only for INBOUND buyer requests.
- SPEC-006 § 8.3 says "The gateway MUST remove any upstream header that discloses provider identity before returning the response to buyers" — this is the RESPONSE-side catch-all, but it does not name the specific headers.

Finding:
SPEC-006 creates an asymmetry between the explicit request-side strip list (which names specific headers) and the implicit response-side strip requirement (which is a catch-all). An implementer working from § 5.4's explicit list could miss stripping the coordinator's response headers. If `X-MacProvider-Provider` leaks to buyers in the response, provider IDs (e.g., `m4-anon`) are exposed, violating SPEC-006 § 8.2.

Why it matters:
Provider identity is explicitly hidden from buyers (SPEC-006 § 8.2). The coordinator adds `X-MacProvider-Provider` and `X-MacProvider-Route` to every response (SPEC-002 § 7.2). If the gateway passes these through, provider identity leaks on every API call.

Recommended fix:
SPEC-006 v0.3 § 8.3: add an explicit response header strip list naming `X-MacProvider-Provider`, `X-MacProvider-Route`, and any other `X-MacProvider-*` response header, mirroring the specificity of the request-side list in § 5.4.

**M2.2 - Streaming client-disconnect quota settlement requires actual tokens that upstream specs do not guarantee.**

(Confirms Round 1 M2.)

Locations across multiple specs:
- SPEC-006 § 17.7 refund matrix: client disconnect debits "prompt + actual completion at disconnect."
- SPEC-001 § 6.6 `inference_response_end`: `usage` field is "Present when `status` is `complete`." On `status: "cancelled"`, usage is not guaranteed.
- SPEC-002 relay: on buyer disconnect, coordinator sends `cancel_request` and does not wait for a usage-bearing terminal frame.

Finding:
The gateway cannot settle to "actual completion tokens generated before disconnect" because the cancellation path does not deliver provider-reported token counts. The gateway would need to count relayed bytes/chunks as a proxy, but SPEC-006 claims "actual" accounting.

Recommended fix:
Same as Round 1 M2. Patch SPEC-006 v0.3 to allow deterministic gateway estimate from relayed content as the settlement value on disconnect, with provider-reported partial usage used only when present. Optionally patch SPEC-001 v1.2.3 to include `usage` on cancelled `inference_response_end` when partial token counts are available.

**M2.3 - Cross-service request ID correlation undefined.**

(Confirms Round 1 M3.)

Locations across multiple specs:
- SPEC-006 § 5.1: gateway generates `X-Request-ID` on every response.
- SPEC-002: coordinator assigns internal `request_id` (UUID) per buyer request, used in WS protocol (`inference_request.request_id`) and `request_log`.
- Neither spec requires the gateway to forward `X-Request-ID` to the coordinator, nor the coordinator to accept or record it.

Finding:
Two independent audit logs cover the same buyer request with no shared key. Gateway `usage_events` record buyer identity, quota, and public errors. Coordinator `request_log` records routing, provider selection, and inference timing. An operator investigating a 502 incident cannot join the two by request.

Recommended fix:
Same as Round 1 M3. SPEC-006 v0.3: require gateway to forward `X-Request-ID` to coordinator. SPEC-002 v1.1.4: accept `X-Request-ID` and record alongside internal `request_id` in `request_log`.

**M2.4 - Per-model `degraded` boolean has no normative definition across specs.**

Locations across multiple specs:
- SPEC-006 § 5.3 `/v1/models` response includes `"degraded": false` per model entry.
- SPEC-006 § 5.6 `/v1/status` response includes `"degraded": false` per model entry.
- SPEC-002 defines per-PROVIDER state (ready, busy, degraded, draining, unavailable) in the pool registry.
- Neither SPEC-006 nor SPEC-002 defines when a MODEL (as opposed to a provider) is considered degraded.

Finding:
The gateway must compute a per-model `degraded` boolean from per-provider states in /poolz, but the aggregation rule is unspecified. Is a model degraded when any provider is degraded? When all are? When ready providers drop below a threshold? The network-wide `degraded` boolean in § 5.6 is defined ("true if ready providers are below the configured threshold"), but the per-model boolean is not.

Why it matters:
Different implementations could produce different per-model degraded values for the same pool state. Buyers relying on the field for client-side logic would see inconsistent behavior.

Recommended fix:
SPEC-006 v0.3: define per-model `degraded` computation. Suggested: "A model is degraded if all providers currently serving that model have state `degraded` or if no provider for that model has state `ready`."

**M2.5 - Gateway `gateway.yaml` config lacks coordinator /poolz access fields.**

Locations across multiple specs:
- SPEC-006 § 5.6: "The gateway MUST source pool status for `/v1/status` by consuming the coordinator's internal `/poolz` endpoint at `http://127.0.0.1:{coordinator_provider_port}/poolz`, typically `:8444`."
- SPEC-006 § 5.6: "/poolz requires the coordinator operator bearer key when `auth.operator_key` is configured."
- SPEC-002 § 7.4: /poolz is on `listen.provider_port` (default 8444), requires `Authorization: Bearer <operator-key>`.
- SPEC-006 § 15.2 `gateway.yaml`: `coordinators[].base_url` is `http://127.0.0.1:8443` (buyer port). No field for provider port URL. No field for coordinator operator key.

Finding:
The gateway config defines the coordinator's buyer port for inference forwarding but not the coordinator's provider port or operator key needed for /poolz. The gateway literally cannot authenticate to /poolz with the current config shape.

Why it matters:
/poolz is the only data source for /v1/status and the per-model aggregation in /v1/models. Without config fields for the /poolz URL and operator key, the gateway implementation must invent its own config shape, creating spec/implementation divergence.

Recommended fix:
SPEC-006 v0.3 § 15.2: extend coordinator config entry with `poolz_url` (default `http://127.0.0.1:8444/poolz`) and `operator_key` (the coordinator's operator bearer key).

**M2.6 - Provider onboarding visibility endpoint `/v1/pool/check` not normatively defined.**

(Confirms Round 1 M1.)

Locations across multiple specs:
- SPEC-003 § 5 install flow verifies coordinator visibility.
- `install.sh` code calls `GET /v1/pool/check?provider_id=...` on coordinator.
- Coordinator code exposes this endpoint on the buyer port.
- SPEC-002 does not normatively define this endpoint.
- SPEC-006 hides coordinator buyer port from public access.

Finding:
The install flow depends on an endpoint that exists in code but not in any spec. After SPEC-006's coordinator buyer port rebind to 127.0.0.1, this endpoint is unreachable from a stranger's Mac.

Recommended fix:
Same as Round 1 M1. SPEC-002 v1.1.4: normatively define `/v1/pool/check` or an equivalent on the provider port (8444). SPEC-003 v0.6: update installer to use the new endpoint URL. SPEC-006 v0.3: document that provider-onboarding verification uses the coordinator's provider port, not the buyer port.

**M2.7 - Error code terminology mismatch between gateway and coordinator for HTTP 502.**

Locations across multiple specs:
- SPEC-006 § 17.4: HTTP 502 uses error code `provider_failed`.
- SPEC-002 § 7.2: HTTP 502 uses error code `provider_error`.
- SPEC-006 does not document how it translates coordinator error codes to gateway error codes.

Finding:
When the coordinator returns 502 with `{"error": {"code": "provider_error"}}`, the gateway either passes it through (buyer sees `provider_error`, contradicting SPEC-006's `provider_failed`) or translates it (needs a mapping table not in any spec). Other status codes are consistent (503 `no_provider_available` matches; 504 `provider_timeout` matches).

Why it matters:
Buyers writing error-handling code against SPEC-006's documented error codes would not match the actual error code if the gateway passes through coordinator responses without normalization.

Recommended fix:
SPEC-006 v0.3: add an error-code normalization table mapping coordinator error codes to gateway error codes. At minimum: `provider_error` (SPEC-002) → `provider_failed` (SPEC-006).

### MINOR findings

**m2.1 - SPEC-002 v1.1.3 dependency line stale.**

(Confirms Round 1 m1.)

SPEC-002 line 4: "Depends on: SPEC-001 v1.2.1." Current: SPEC-001 v1.2.2.

Fix: SPEC-002 v1.1.4.

**m2.2 - SPEC-003 v0.5 dependency lines stale.**

(Confirms Round 1 m1.)

SPEC-003 line 4: "Depends on: SPEC-001 v1.2.1, SPEC-002 v1.1.2." Current: v1.2.2 and v1.1.3.

Fix: SPEC-003 v0.6.

**m2.3 - `logprobs` listed in SPEC-006 but absent from SPEC-001/SPEC-002 field tables.**

(Partially confirms Round 1 M5, but downgraded to MINOR.)

SPEC-006 § 5.4 lists `logprobs` as "accepted syntactically." SPEC-001 § 6.2 and SPEC-002 § 7.2 do not list it. The field is silently ignored via the "unknown top-level fields are silently ignored" rule in both upstream specs. Behavior is correct; the normative gap is documentation-only.

Fix: SPEC-001 v1.2.3 and SPEC-002 v1.1.4: list `logprobs` as an optional field with "forwarded to provider; behavior model-dependent." Or SPEC-006 v0.3: downgrade wording from "supported" to "accepted as forward-compatible unknown field."

**m2.4 - /poolz summary lacks per-state counts needed by SPEC-006.**

SPEC-002 FR-O2 `/poolz` summary has `total_providers`, `ready`, `total_slots`, `free_slots`, `models`. Does not include `draining`, `degraded`, or `unavailable` counts. SPEC-006 /v1/status needs ready/draining/unavailable aggregates. Gateway can compute from the per-provider `pool[]` array entries, but /poolz summary enrichment would reduce gateway computation.

Fix: SPEC-002 v1.1.4: extend /poolz summary with `degraded`, `draining`, `unavailable` counts (matching /healthz's existing breakdowns).

**m2.5 - Status endpoint cache staleness during coordinator restart.**

SPEC-006 § 5.6 /poolz cache TTL is 10 seconds. During a coordinator restart, /v1/status may return stale "up" status while /v1/chat/completions returns 503 for up to 10 seconds. This is an acceptable v1 trade-off but the implication is not documented.

Fix: SPEC-006 v0.3: add a note in § 5.6 that /v1/status reflects cached /poolz state and may lag behind real-time coordinator state by up to the cache TTL.

**m2.6 - Coordinator buyer port rebind not documented in SPEC-002.**

SPEC-006 § 2.1 mandates coordinator buyer port rebind from `0.0.0.0:8443` to `127.0.0.1:8443`. SPEC-002 v1.1.3 does not mention this deployment change. The rebind is a SPEC-006 deployment requirement, not a SPEC-002 normative change, but a SPEC-002 deployment note would prevent confusion.

Fix: SPEC-002 v1.1.4: add deployment note that SPEC-006 requires buyer port rebind to loopback.

### QUESTIONS

**Q2.1 - SPEC-006 § 5.4 and § 8.3 have inconsistent explicit strip lists (within-spec).**

§ 5.4 lists `X-MacProvider-Provider` and `X-MacProvider-Session` explicitly plus the `X-MacProvider-*` catch-all for request stripping. § 8.3 adds `X-MacProvider-Pref` to the explicit list. Both sections have the catch-all which covers `Pref`, so behavior is identical. This is an editorial inconsistency within SPEC-006, not a cross-spec issue. Defer to FIX_SPEC_006_V0_3.

**Q2.2 - SPEC-006 § 10 capacity tiers should explicitly state independence from SPEC-002 admission tiers.**

(Confirms Round 1 M4 finding but reclassified as QUESTION.)

The term "tier" now names two independent state machines: SPEC-006 capacity-burst tiers (buyer-side signups/quota/kill-switch) and SPEC-002 admission tiers (provider-side pinned/provisional/rejected). They operate on different principals (buyers vs. providers) and different state. SPEC-006 should state the independence explicitly. However, I classify this as QUESTION rather than MAJOR because the two systems operate on such different domains (buyer signup vs. provider WebSocket admission) that conflation by an implementer is unlikely.

### Category coverage notes
- α: Wire contracts compose end-to-end for all supported fields; `logprobs` has a normative gap (m2.3); cancel/disconnect usage has no cross-layer token contract (M2.2).
- β: Two implicit-surface findings: response header strip gap (M2.1), /v1/pool/check (M2.6). /poolz schema sufficient for aggregation with per-provider iteration (m2.4).
- γ: Drain/reconnect/restart failure modes compose coherently. Disconnect settlement has a gap (M2.2). Cache staleness documented (m2.5).
- δ: Stale dependency lines (m2.1, m2.2). Capacity/admission tier terminology overlap (Q2.2).
- ε: Backward compatibility preserved for legacy providers, direct tunnels, and pre-v1.2.2 buyers. No finding.
- ζ: Provider-side URLs unchanged after SPEC-006 (provider connects to coordinator, not gateway). /v1/pool/check visibility gap (M2.6).
- η: Two separate audit logs with no join contract (M2.3).
- θ: State ownership clear — SPEC-002 owns pool/provider state, SPEC-006 owns account/key/usage/feedback state. Usage events overlapping but on separate services (M2.3).
- κ: SPEC-006 v0.2 regression findings remain single-spec; no additional cross-spec implication found.

### Self-verification

- [x] Read all four spec documents at their current versions (SPEC-001 v1.2.2, SPEC-002 v1.1.3, SPEC-003 v0.5, SPEC-006 v0.2).
- [x] Walked all categories alpha through kappa.
- [x] For each finding, the proposed fix specifies WHICH spec(s) to patch and at what next version.
- [x] Code-surface verifications consulted: coordinator buyer server handler (headers, fields, /poolz), coordinator WS server (message types, drain, auth), Swift coordinator client (drain/reconnect lifecycle), Swift ChatCompletionRequest (case-insensitive match), install.sh (URLs, self-test).
- [x] Severity per cross-spec definitions: no production-incident-class CRITICAL; MAJORs are first-month-patch-class; MINORs are terminology/version/documentation drift.
- [x] Verdict reflects corpus composition state.

### Verdict

**READY WITH NARROW PATCHES**

The four-spec corpus is architecturally coherent. Provider/coordinator/gateway ownership boundaries are sound. Provider identity is properly hidden from the buyer surface. Wire contracts (chat fields, streaming, model matching, JSON escapes) compose correctly end-to-end. Backward compatibility for legacy providers and direct-tunnel buyers is preserved.

Seven MAJOR findings need narrow spec patches before Phase 5 implementation:
- Five in SPEC-006 v0.3 (response header strip list, per-model degraded definition, /poolz config fields, error normalization table, disconnect settlement wording)
- Two requiring SPEC-002 v1.1.4 coordination (request ID correlation, /v1/pool/check normative definition)
- One requiring SPEC-003 v0.6 coordination (/v1/pool/check installer update)

No architectural redesign is needed. All findings are narrow text patches that can be bundled into a single FIX session across SPEC-006 v0.3 + SPEC-002 v1.1.4 + SPEC-003 v0.6.

### Round 2 notes on Round 1

**Findings I confirm:**
- **M1 (/v1/pool/check):** Confirmed as M2.6. Valid cross-spec finding — the install flow depends on an implicit endpoint that SPEC-006 hides. Agree with MAJOR severity.
- **M2 (disconnect usage):** Confirmed as M2.2. Valid — SPEC-001's cancelled `inference_response_end` does not carry usage. The settlement rule is aspirational without upstream support. Agree with MAJOR severity.
- **M3 (request ID correlation):** Confirmed as M2.3. Valid — two audit logs, no join key. Agree with MAJOR severity and fix direction.
- **m1 (stale dependency lines):** Confirmed as m2.1 + m2.2. Agree.
- **m2 (audit vocabulary):** Partially confirmed. SPEC-003's shell-script audit category is specifically about shell scripts touching real OS resources; SPEC-006 is a Go gateway service and wouldn't trigger that category directly. However, the broader lesson (user-shaped integration paths need integration tests) does apply. Agree it should be noted.
- **m3 (spec lock rule):** Agree this is a governance observation. The per-spec "don't modify upstream specs" rule is correct for per-spec audits but breaks for cross-spec composition audits. Worth noting in SPEC-006 v0.3.

**Findings I disagree with (severity):**
- **M4 (capacity/admission tier terminology):** Reclassified to Q2.2 (QUESTION). The two "tier" systems operate on entirely different domains (buyer signup vs. provider WebSocket admission), different principals (buyers vs. providers), and different state. While the terminology overlap is worth documenting, an implementer would need to misread both specs significantly to conflate them. The fix (add an independence statement) is trivial and correct, but the severity is lower than MAJOR.
- **M5 (logprobs):** Reclassified to m2.3 (MINOR). The end-to-end behavior is correct — `logprobs` is forwarded through the body and silently ignored by the provider per SPEC-001's "unknown top-level fields are silently ignored" rule. The gap is normative documentation, not behavior. A SPEC-006 wording adjustment or upstream field-table addition closes it.

**New findings Round 1 missed:**
- **M2.1 (response header strip):** Codex noted that "header stripping covers the known provider pinning headers" in category beta, but did not flag the asymmetry between the explicit request-side strip list and the implicit response-side strip requirement. The coordinator adds `X-MacProvider-Provider` and `X-MacProvider-Route` to EVERY response (SPEC-002 § 7.2). If the gateway doesn't strip these, provider IDs leak on every API call. This is the highest-impact finding Round 1 missed.
- **M2.4 (per-model degraded undefined):** SPEC-006 exposes a per-model `degraded` boolean in /v1/models and /v1/status, but no spec defines the computation rule. Round 1 did not flag this.
- **M2.5 (/poolz config gap):** The gateway config lacks the coordinator provider-port URL and operator key needed to call /poolz. Without these, /v1/status and /v1/models aggregation cannot be implemented from the normative config shape. Round 1 did not flag this.
- **M2.7 (error code mismatch):** SPEC-006 uses `provider_failed` for 502 while SPEC-002 uses `provider_error`. Gateway error normalization is undocumented. Round 1 did not flag this.
- **m2.4 (/poolz summary gap):** /poolz summary lacks per-state counts. Round 1 did not flag this.
- **m2.5 (cache staleness):** /v1/status 10s cache creates a brief window of stale data during coordinator restart. Round 1 did not flag this.
- **m2.6 (coordinator rebind):** Coordinator buyer port rebind mandated by SPEC-006 but not documented in SPEC-002. Round 1 did not flag this.

**Verdict (mine, independent):**

READY WITH NARROW PATCHES

Same verdict as Round 1. The corpus is architecturally sound with no design-level drift. All findings are narrow text patches addressable in a single combined FIX session. Round 2 adds 4 new MAJOR findings Round 1 missed (response header strip, per-model degraded, /poolz config, error code mismatch) while reclassifying 2 of Round 1's MAJORs to lower severity (capacity tier terminology → QUESTION, logprobs → MINOR). Net across both rounds: 0 CRITICAL, 9 unique MAJOR findings (Round 1: 5, confirmed 3, reclassified 2; Round 2 added 4 new), 7 unique MINOR findings, 2 QUESTIONS.
