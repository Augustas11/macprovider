# SPEC-006 - Buyer API Gateway: Mac Provider's first public buyer surface

**Version:** 0.9.13 (2026-07-30, experimental default-off Anthropic Messages facade)
**Depends on:** SPEC-001 v1.2.4, SPEC-002 v1.5.4, SPEC-003 v0.7, SPEC-004 v0.3.2

**Change log v0.9.13 (2026-07-30, issue #829 — experimental Anthropic Messages facade):**
- Adds an operator-gated `features.anthropic_messages_enabled` flag, default `false`. When disabled, `POST /v1/messages` is not mounted. When enabled, the gateway accepts a narrow Anthropic Messages compatibility subset and translates it through the existing billed `POST /v1/chat/completions` path; it is not a separate proxy, ledger, routing, or settlement implementation.
- Supported Anthropic request features are text `system`, text `messages[]`, assistant `tool_use`, user `tool_result`, `tools[].input_schema`, `max_tokens`, `stream`, `tool_choice`, `stop_sequences`, `temperature`, and `top_p`. Unsupported Anthropic features such as images, documents/files, server tools, beta headers, thinking, and `top_k` fail before provider dispatch.
- The facade best-effort infers `stop_reason: "stop_sequence"` for OpenAI-compatible providers that collapse custom stop matches to `finish_reason: "stop"` only when the returned visible text still has a request `stop_sequences[]` suffix to match and remove. If the provider strips the stop string before returning text and reports only `finish_reason: "stop"`, the matched sequence is not derivable and the facade reports `end_turn` with `stop_sequence: null`.
- Settlement disclosure includes `POST /v1/messages` only when the feature is enabled, because the facade reuses the same reservation, quota, settlement, sticky routing, cancellation, request-id, and id-less replay path as chat completions. This does not certify full Claude Code or Anthropic SDK product compatibility beyond the supported wire subset.

**Change log v0.9.12 (2026-07-15, runbook item 22 — cross-spec 404/known-model reconciliation):**
- § 17.2 clarified: a provider's "seen" model list is the union of its served `model_id` and its declared `supported_models` (SPEC-010 v1.5 R-3.3.4, authoritative; SPEC-002 v1.5.4 R-3.X.6). A declared-but-cold model is therefore *known* → `503 no_provider_available` via § 17.3, not `404 model_not_found`. § 17.3 and § 2.12 name declared models alongside served/seen. Already the shipped coordinator behavior (`ModelKnown()` unions declared `supported_models`; #555); changes no dispatch outcome, only the error code a declared-but-cold request receives. Docs-only. Resolves the SPEC-010 R-3.3.4 carried cross-spec-inconsistency note. **(v0.9.11 is the in-flight item-20 change on PR #594; this v0.9.12 entry sequences after it — merge #594 first.)**

**Change log v0.9.11 (2026-07-14, runbook item 20 — retryability classification + transport symmetry):**
- § 5.2 abuse-limit exception gains `signup_rate_limited` (gateway): a per-IP daily account-creation cap (`oauth.go createSignupAccount`, `SignupAccountsPerIPPerDay` over a 24h window) that ships **no** `Retry-After`/reset header and sits **outside** the `/v1/chat/completions` 30-RPS account clamp — the same shape as `feedback_rate_limited` / `oauth_state_rate_limited` / `demo_session_rate_limited`. Reclassified from `retryable:true` to `false` (moved from `gatewayRetryableByCode` to `gatewayPermanentCodes`); #548 left it `true` only because the round-3 SECURITY-MEDIUM revert didn't name it. **Buyer-visible envelope change:** the `signup_rate_limited` 429 now carries `retryable:false`. The header-agreement note's "converse does not hold" example was repointed from `signup_rate_limited` to the retryable `502` availability codes (`provider_error` / `upstream_provider_error`), which genuinely carry no `Retry-After` because `setGatewayRetryAfter` attaches one only to `503`/`504` and the fixed-window codes; the note now also records that the capacity-pause codes DO ship `Retry-After: 30` (they are not headerless).
- § 5.2 Overrides + "Known carried items" (2): the coordinator's **streaming** SSE terminal-error writer now honors the provider-supplied `inference_response_end.retryable` override the **non-streaming** writer (`writeProviderStructuredOutputError`) already did — via new `writeSSEErrorWithRetryable` at the synthesized-terminal-error site — so a buyer sees the identical `retryable` verdict for the same terminal structured-output outcome on both transports. Carried item (2) marked RESOLVED. Mirrors SPEC-019 §8. No settlement/money-path change.

**Change log v0.9.10 (2026-07-14, runbook item 18 — pre-dispatch route_snapshot_failed settlement):**
- § 17.7 quota-refund matrix gains a `500 route_snapshot_failed` row: a genuine no-provider failure is a **no-charge refund** (was: settled on the prompt estimate — SPEC-022 "Known limitations (A)", now resolved), gated on the coordinator's POSITIVE `X-MacProvider-Settlement-No-Prior-Dispatch` marker plus no finality header plus no gateway-retry prior dispatch. The coordinator stamps that marker centrally (`noPriorDispatchResponseWriter`) on any terminal response written while no provider has been **billably credited** for the request. "Credited" is the LEDGER-EXACT signal, not a request-log ordinal: `providerCredited` is set inside `recordRow` the instant a provider-bound billable row persists (`providerAssignedID != "" AND status != 503`), and `dispatchedThisAttempt` (reset per attempt, set before the provider relay) covers the current terminal attempt whose own billing row is recorded AFTER its write on the WS paths — a dispatched attempt whose terminal status is non-503 WILL be billed, so it is left unmarked; a dispatched attempt that terminates 503 (queue-full / relay-unavailable) is NOT billed and stays marked. This replaces the earlier `attemptN == 0` source, which over-counted (incremented on non-billed 503 rows → over-charge) and under-covered (incremented after the terminal WS write → under-charge). The positive-marker design (not absence-of-negative) makes a gateway-first deploy / coordinator rollback safe — an unmarked response settles on the estimate. Two unmarked/settled cases preserve provider work credited in `observe` mode: (1) coordinator-internal failover (marker withheld once a provider is credited); (2) gateway retry of an unmarked earlier response — a provider-dispatched `provider_*` 502 or a `no_provider` 503 from failover exhaustion after a billed attempt (a genuinely cold retried 502/503 is marked and does not poison the refund). § 17.1 notes the coordinator `500 route_snapshot_failed` is passed through verbatim. **Coordinator + gateway behavior change — deploy coordinator first, roll back in reverse.** SPEC-022 item (A) reconciled to resolved.

**Change log v0.9.9 (2026-07-14, SPEC-018 AC-45 gateway-strip reconciliation):**
- Added `X-MacProvider-Streaming-Mode` to the § 5.4 response-pass-through allowlist (and its outbound-strip-summary duplicate). The coordinator has always set this SPEC-018 AC-45 buyer-visible streaming-mode diagnostic on streaming `200` responses, but the gateway's blanket `X-MacProvider-*` strip removed it before the buyer on `api.streamvc.live`, making AC-45's "header absent" fail condition live in production. The gateway now forwards it, validated against AC-45's closed enum (`incremental` / `buffered_kill_switch` / `buffered_provider_downgrade`) and dropped otherwise (defense-in-depth against header-content injection past the strip). Resolves runbook item 15 / the SPEC-018 v0.2.4 "Known open gap" note. No wire-contract change beyond un-stripping an already-specified header; the header remains observation-only.

**Change log v0.9.8 (2026-07-12, SPEC-024 prefix-cache provider-visibility carve-out):**
- Narrowed § 1.3 Tier-2 survivability invariant (b): the raw buyer tag / `account_id` remain unrecoverable by the provider (one-way HMAC, non-side-channel-derivable), but the *derived opaque* `conv:` value MAY be provided to the provider in the inference request for provider-local prefix caching (SPEC-004 v0.3.2 FR-SR-2 / SPEC-008 v0.4.1 §2.2). No wire-contract change.
- **R2-audit reconciliation (2026-07-12, spec-only).** Swept residual text that still forbade the carve-out: the § 1.3 "provider-side caching remains guarded" clause now permits derived-key-scoped provider-local prefix caching; the `DELETE /v1/sticky` lifecycle bullet distinguishes the coordinator sticky **map** (buyer-purgeable) from the **provider-local** KV cache (independent TTL, not buyer-purgeable); the tag-trim step records the shipped Go `strings.TrimSpace` **Unicode** semantics (vs an ASCII-only reimplementation); invariant (b) and § 5.3.1 now disclose **cross-provider linkability**; § 5.3.1 adds a disclosure-completeness MUST-close item for provider receipt/retention. Bumped the SPEC-004 dependency to v0.3.2.
- **R3-audit reconciliation (2026-07-12, spec-only).** Two residual occurrences fixed: § 5.4.1's tag-trim rule still said "ASCII whitespace" (now Unicode `strings.TrimSpace`, matching § 1.3); and the § 1.3 "buyer-triggered deletion" lifecycle precondition addressed for the not-directly-purgeable provider KV cache.
- **R4-audit correction (2026-07-12, spec-only).** The R3 buyer-deletion reconciliation **overstated** the control (it claimed `DELETE /v1/sticky` "severs routing" / "halts extension" of the provider cache). Corrected to the honest position: because the derived key is deterministic and post-delete normal selection (SPEC-004 FR-SR-3) can re-route to the same provider and re-populate under the same key, buyer deletion is **neither a direct nor a reliable indirect** provider-cache purge — the provider entry's only dependable bound is its own TTL/LRU. Recorded as a genuine § 1.3 lifecycle-guard residual gap under option (a) (SPEC-024 v0.2 §13 / FR-CI10a), not papered over.
- **R5-audit correction (2026-07-12, spec-only).** The R4 honesty fix exposed that the § 1.3 terminal "any cache not meeting ALL conditions MUST NOT ship" rule would then forbid the very design option (a) ratifies. Carved that rule for the option-(a) provider-local cache.
- **R6-audit correction (2026-07-12, spec-only).** The R5 carve-out named only **one** partially-met condition (deletion); the audit noted **disclosure** is a **second** partial residual — the base sticky-affinity disclosure ships and stays hard-required, but the option-(a)-specific extensions (provider receipt/retention/non-purgeability + cross-provider linkability) are not yet disclosed (§ 5.3.1 MUST-close). The carve-out now names **both** residuals as knowingly-accepted/tracked, keeps the base disclosure + all crypto/scoping conditions hard-required, and drops a drifted hard line-number citation.

**Change log v0.9.7 (2026-07-06, issue #375 — gateway per-account admission guard):**
- Gateway enforces a per-account request-start token bucket before
  forwarding `/v1/chat/completions` to the coordinator. Default steady
  rate is `quotas.account_request_rate_per_second: 30` per gateway
  instance; default
  authenticated account concurrency is now `quotas.account_concurrency:
  4`. Both remain operator-configurable in `gateway.yaml`.
- The request-start token bucket is a non-authoritative abuse-shedding
  guard. Persistent daily token quota and in-flight concurrency
  reservations remain storage-backed and authoritative for money-path
  accounting. Process restart may reset the request-start bucket; it
  MUST NOT mint quota, bypass auth, or affect settlement.
- Fast request-start rejection returns `429` with `Retry-After` and
  OpenAI-compatible `X-RateLimit-*-Requests` headers; the gateway emits a
  structured log line with `request_id`, `account_id`, `limit_rps`, and
  `retry_after_s` for operator triage.

**Change log v0.9.6 (2026-07-06, issue #374 — bounded coordinator slot queue):**
- Non-pinned no-slot routing may use SPEC-002 v1.5.3's bounded
  coordinator-side pre-dispatch slot queue before returning 503. The
  queue is not unbounded gateway queueing; it is capped per
  `provider_id`, FIFO, and deadline-bound.
- Pinned provider/session requests retain immediate 503 behavior when
  the pinned target has no free slot.
- `queue_wait_ms` is a latency diagnostic and refund/billing-neutral:
  queue dwell does not create token usage, buyer debit, or provider
  payout by itself; expired queued 503s remain failed/refunded requests.

**Change log v0.9.5 (2026-07-02, issue #295):**
- § 17.7.1 clause 1 tightened: the standalone envelope now literally forbids the `choices` and `usage` KEYS (regardless of value shape), plus duplicate top-level keys and duplicate immediate `error.*` fields (including `error.code`, `error.type`), plus trailing garbage. Duplicate keys DEEPER inside `error.*` sub-objects (e.g. `error.details.foo.k` twice) are outside the corroboration trust gate and NOT required to reject — no smuggling risk. Earlier "no usage field with non-zero token counts" wording drifted from the gateway's producer-side enforcement and from the #232 harness-side corroboration, opening JSON smuggling shapes (`usage:null`, `usage:{}`, duplicate `choices`/`usage`/`error.code`, non-enumerated usage subfields like `total_tokens`, invalid trailing bytes). Aligned to what the token-level parser and buyer's OpenAI SDK actually see.
- Dropped hard-coded line-number citation on `writeProviderDisconnectedSSE` reference (function-name reference only, matching clause 4 pattern; line numbers drift as code around them changes).

**Change log v0.9.4 (2026-07-01, SPEC-015 v0.4):**
- § 1.6 and § 5.3.1 now disclose the SPEC-015 v0.4 / SPEC-022 model-verification limit: v0.4 settlement receipts verify the provider-reported request-start model hash against the route-time catalog snapshot, but do not detect a provider falsifying its own loaded-model hash measurement.
- The `/v1/models tier1_disclosure` example adds `model_verification_limit` so buyer/product surfaces can show the caveat alongside model identity and Tier 2 disclosure text.

**Change log v0.9.3 (2026-06-30, issue #278):**
- § 7.2 streaming settlement now also clamps the *upward*-correction direction (provider's reported completion_tokens is *under* the gateway's byte-based observation) using the SAME pure-absolute window `2 < overshoot ≤ 20`. In-window upward gaps settle at the provider-reported count with `token_source = "provider_reported"` (the provider's tokenizer is authoritative on its own output when the disagreement is small). Below 2 tokens: still trust the byte estimate (existing behavior, byte-based observation drives settlement). Above 20 tokens: still trust the byte estimate (stream-truncation / zero-report-fraud guard). Clamp window constants `clampFloorTokens=2`, `clampCeilingTokens=20` are shared between both directions — no direction-specific tuning.
- § 17.7 settlement matrix row 200 and § AC-37 acceptance criteria updated to describe the symmetric clamp shape in both directions.
- Live surfacing: scenario 07 of the 2026-06-30 v0.4 baseline rerun caught +6 / +7 / +9 / +9 over-bills across 4 of 40 successful streaming pairs on `augustass-macbook-air × Qwen3-32B-4bit` after PR #262 closed the downward channel. Gateway's `ceil(content_bytes / 4)` estimator runs ~7-15% high on English Qwen3-32B output; provider's tokenizer is authoritative. Surfaced as `token_source = "gateway_estimated"` rows that override the (correct) provider report. Fix mirrors PR #262 on the opposite branch of `settleReported`.

**Change log v0.9.2 (2026-06-29, issue #255):**
- § 7.2 streaming settlement now clamps provider-reported completion_tokens down to the gateway's byte-based observed value when the over-report falls inside the pure-absolute window `2 < overshoot ≤ 20` ("Streaming over-report clamp" subsection). Below 2 tokens: trusted as benign tokenizer noise. Above 20 tokens: trusted as density mismatch (byte-based observation is unreliable on dense content; clamping would risk under-billing). Clamped rows record `token_source = "gateway_estimated"` and preserve provider-reported `prompt_tokens`; gateway emits a structured log line carrying `request_id`, `account_id`, `reported`, `observed`, `overshoot`, `window_floor`, `window_ceiling`, `outcome` for audit triage.
- § 17.7 settlement matrix row 200 and § AC-37 acceptance criteria updated to reference the new clamp policy.
- Live surfacing: scenario 07 of the 2026-06-29 v0.3 baseline rerun caught +4 / +5 / +7 over-bills on `air5 × Qwen2.5-Coder-7B-Instruct-4bit`. Provider-side tokenizer counted EOS / chat-template stop tokens that never streamed as delta content.

**Change log v0.9.1 (2026-06-29, issue #211):**
- Gateway MUST forward `X-MacProvider-Account: <subject.AccountID>` on
  every forwarded buyer request — both the sticky and non-sticky
  routing paths. The pre-v0.9.1 gateway emitted this header only
  inside the sticky-routing conditional, leaving the non-sticky hot
  path account-blind; the coordinator could not attribute the
  resulting `request_log` row to the gateway account, breaking the
  composite `(account_id, external_request_id)` reconciliation key
  introduced in SPEC-002 v1.5.0. Bearer subjects forward
  `subject.AccountID = authn.Bearer.AccountID`; demo subjects
  forward `subject.AccountID = "demo:" + authn.DemoPayload.IP`.
- Gateway MUST pair `X-MacProvider-Account` with the upstream
  `Authorization: Bearer <UpstreamCoordinatorBearer>` header on
  every forward. The coordinator treats `X-MacProvider-Account` as
  an internal-routing header (see
  `phase4-coordinator/internal/buyer/server.go`
  `hasInternalRoutingHeader` / `internalBearerAuthorized` /
  `selectProviderExcluding`) and rejects buyer-port requests
  carrying it without the gateway-service-token bearer with
  `400 invalid_request`. Pre-v0.9.1 only the sticky path set the
  bearer (because only the sticky path set the account header);
  v0.9.1 hoists both together. Sticky-specific state — the
  `X-MacProvider-Internal-Conv` conversation key — remains gated
  by the sticky conditional and is still suppressed for demo
  traffic. (Caught by the issue-#211 R1 security audit; without
  this pairing every non-sticky chat would 400 against any
  v0.9.x+-aware coordinator.)
- Dependency bump SPEC-002 v1.3.4 → v1.5.0 to record the
  coordinator-side composite-key contract.

**Change log v0.9:**
- SPEC-015 v0.1.3 absorption: adds `X-MacProvider-Receipt` to the
  documented response-pass-through allowlist so the gateway forwards
  provider-issued non-streaming inference receipt headers unchanged.
  The inbound buyer request header strip rules are unchanged, and no
  second receipt-related `X-MacProvider-*` response header is added.

**Change log v0.8.3:**
- Enumerates the § 17.7 context-cancel refund invariant already enforced by gateway code: cancelled or timed-out buyer connections at quota or concurrency reservation gates MUST refund reservations before return and MUST NOT write a 500 to the dead connection.

**Change log v0.8.2:**
- Adds the SPEC-005 v0.3 X-1 quota-settlement row for SPEC-001 null-usage errors (`error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal`): buyer quota debit is none, matching SPEC-005 zero provider credit and preserving H-005 zero-delta. Adds AC-NULL-USAGE-REFUND.

**Change log v0.8.1:**
- Audit-driven patch closing findings from the independent v0.8 audit. (A1, MAJOR) Restored the v0.7 "**before authentication**" header-strip rule that v0.8 had inadvertently weakened to "before coordinator forwarding"; added a normative WARN audit event on observed buyer-supplied `X-MacProvider-Internal-Conv`. (M1) Replaced the "ignore or reject" ambiguity with a normative **silent ignore** when `sticky_enabled: false`, so portable buyer SDKs that always include the header don't break against operators on the default-off posture. (M2) Constrained the HMAC secret-rotation overlap window to `DELETE /v1/sticky` lookups only; routing-time sticky-key derivation MUST use only the current secret (closes a silent TTL-extension path during rotation). (A2) Operationalized the F-1.5 Tier-2 survivability clause with four concrete invariants a future SPEC-008 audit MUST verify. No new wire-contract changes; no SPEC-001 movement.

**Change log v0.8:**
- Enables SPEC-004 v0.2 Pillar A by satisfying the § 1.3 sticky-caching guard for coordinator-internal sticky affinity: single-account ownership, explicit lifecycle, HMAC-SHA256 account-scoped key derivation, conditional buyer disclosure, and Tier-2 survivability are now normative requirements.
- Chooses `X-MacProvider-Conversation` as the buyer-supplied opaque conversation tag, derives `routing_internal.conversation_key` in the reserved `conv:` namespace, and transports it only on the gateway-to-coordinator hop as `X-MacProvider-Internal-Conv` with external nginx/header-stripping requirements.
- Refreshes the Tier 1 disclosure surfaces in § 1.6 and § 5.3.1 so sticky affinity disclosure is conditional on `routing.sticky_enabled: true`, while the default `sticky_enabled: false` posture preserves v0.7 buyer-visible behavior.
- Adds PG-9 to the production launch gate checklist for sticky disclosure parity across signup, docs, `/v1/models`, and SDK README surfaces before production operators enable sticky affinity.
- Adds the SPEC-004 v0.2 sibling relationship note: SPEC-004 owns routing-side sticky behavior, while SPEC-006 v0.8 owns gateway derivation, transport, disclosure, and satisfaction of the v0.7 preconditions.

**Change log v0.7:**
- Adds sleep-tolerant `/v1/status` semantics for Phase 7 P1: coordinator reachable with zero ready providers is `status: "idle"`, not `down`; `down` is reserved for coordinator/control-plane unreachability. Per-model status rows now include `ready_provider_count`, `available`, and `availability` so front doors can distinguish "available", "no awake provider", and "no free slots" without deriving competing rules. Front-door copy MUST render `idle` as a friendly no-awake-provider state, not as an outage.

**Change log v0.6:**
- Closes H-001 (privacy claims exceed enforcement), H-004 (model integrity is provider-reported), and H-006 (sticky caching forward-looking guard) from the 2026-05-29 independent security audit. Six additions: § 1.6 plaintext-to-provider disclosure (4 normative properties); § 5.3.1 `/v1/models` extension with `tier1_disclosure` block; § 5.3 model identity provider-reported note; § 1.3 sticky-caching guard; § 19 expectation-drift audit category; § 22 production launch gate checklist (8 items adapted from audit recommendations). Sibling patches (SPEC-001 v1.2.4 + SPEC-002 v1.1.5) close H-002 and H-003. H-005 (billing settlement) is largely already covered by D-CROSS-1 (refund matrix) + SPEC-001 v1.2.3 cancel-usage normative; verification deferred to BUILD_PHASE5 Phase C end-to-end test. No code changes; v0.6 implementation contract for BUILD_PHASE5 expanded by these additions.

**Change log v0.5:**
- Closes F-606-V3-1 and F-606-V3-2 from `specs/FIX_SPEC_006_V0_5_PROMPT.md`, the SPEC-006 follow-up filed by `specs/FIX_SPEC_001_V1_2_3_PROMPT.md`: streaming cancellation settlement now prefers SPEC-001 v1.2.3 provider-reported cancel `usage` from phase3-binary v1.2.4 (commit c94da11, tag v1.2.4) and falls back to byte estimation for pre-v1.2.4 providers; AC-37 now covers both actuals and fallback branches.

**Change log v0.4:**
- Closes SPEC-006-only regression findings F-606-V2-1 and F-606-V2-2 from `specs/SPEC-CROSS-006-v2-audit.md`: per-model degraded now cites SPEC-002 v1.1.4 § 4, FR-B1 without restating the rule, and AC-26, AC-29, AC-30, and AC-34 now spell out both branches with status, body shape, and verification commands.

**Change log v0.3:**
- Closes SPEC-006 cross-spec findings F-606-1 through F-606-8 from `specs/SPEC-CROSS-006-audit.md`: outbound coordinator header scrubbing, streaming disconnect estimation, per-model degraded cross-reference, `/poolz` gateway config, 502 error normalization, SPEC-003 audit-category inheritance, cross-spec governance wording, and status cache staleness.
- Encodes D-CROSS-1, D-CROSS-2, D-CROSS-3, D-CROSS-4, D-CROSS-5, and D-CROSS-6 for the coordinated release set, and folds in the narrow `specs/SPEC-006-v0-2-audit.md` AC fixes: AC-26 uses `GET`, AC-27 proves the 60-second bound, and AC-26 through AC-37 state status codes, response bodies, and verification commands.

**Change log v0.2:**
- Closes the cross-model audit in `specs/SPEC-006-audit.md`: 1 CRITICAL, 21 MAJOR, 9 MINOR findings, and 2 operator questions.
- Locks D1 v1 single-instance SQLite deployment, D2 HMAC-SHA256 demo tokens, and D3 streaming/error quota reservation and settlement policy.
- Adds precision for OAuth callback allowlisting and scopes, OpenAI request fields, API key entropy, revocation latency, feedback scope and summaries, capacity signal measurement, quota reservations, kill-switch persistence, provider-pinning header stripping, and failure-mode accounting.
- Adds AC-26 through AC-37 for the new security, lifecycle, feedback, capacity, provider-transparency, demo-token, and quota-settlement requirements.

**Change log v0.1:**
- Initial draft following design exploration in specs/design/spec-006/SPEC-006-design.md.
- Locked design choices captured from operator pre-commitments (see Section 2).
- Defines the separate Go gateway service at phase5-gateway/ and the buyer-facing HTTP surface at https://api.streamvc.live.
- Defines authentication, key issuance, quota enforcement, usage accounting, feedback capture, status transparency, kill switches, capacity-burst protection, storage contracts, front-door contracts, instrumentation, failure modes, audit categories, and acceptance criteria.
- Defers implementation to a later BUILD_PHASE5 or BUILD_PHASE6 prompt.

---

## 1. Scope

### 1.1 Mission

SPEC-006 defines Mac Provider's first public buyer-facing surface.

The buyer-facing surface is a free, capped, OpenAI-compatible API for a live volunteer Mac pool.

The public API is served by a separate Go gateway service in `phase5-gateway/`.

The canonical buyer URL is:

```text
https://api.streamvc.live
```

The gateway fronts the Phase 4 coordinator and exposes only buyer-safe endpoints.

The coordinator remains a router.

The coordinator remains responsible for provider WebSocket admission, provider pool state, routing, preflight, request forwarding, SSE relay, and request logging.

The gateway is responsible for buyer identity, buyer API keys, quota, public status shaping, user feedback, kill switches, capacity-burst controls, and public error normalization.

### 1.2 In scope

SPEC-006 covers:

- A separate Go gateway service under `phase5-gateway/`.
- Public endpoint routing at `api.streamvc.live`.
- Public `/v1/models`.
- Public `/v1/chat/completions`.
- Experimental operator-gated public `/v1/messages` facade.
- Public `/v1/usage`.
- Public `/v1/status`.
- Public authenticated `/v1/feedback`.
- GitHub OAuth account creation.
- Optional email magic-link account creation if a practical free tier is available.
- API key issuance, hashing, revocation, and regeneration.
- Default account daily token quota.
- Unauthenticated demo quota.
- Per-account concurrency cap.
- Per-IP signup issuance limit.
- Per-request `max_tokens` cap.
- Public provider transparency rules.
- Status endpoint aggregation rules.
- Gateway kill switches.
- Capacity-burst tier escalation.
- User feedback rating capture and aggregation.
- Front-door contract for the existing Vercel demo.
- Single-page documentation contract.
- Storage interface and SQLite v1 schema requirements.
- Configuration shape in `gateway.yaml`.
- Instrumentation and metrics.
- Failure-mode mapping and OpenAI-shaped error envelopes.
- Acceptance criteria and deterministic verification steps.
- Audit categories for future review.

### 1.3 Out of scope for v1

SPEC-006 v1 explicitly does not specify:

- Stripe.
- Billing.
- Metered payment.
- Paid plans.
- Invoicing.
- Refunds.
- Provider payout.
- Revenue share.
- Provider tipping.
- Donations.
- Donation button.
- "Support us" link.
- Payment-adjacent UI.
- Captcha-first signup.
- Full chart-based dashboard.
- Email reports.
- Weekly digests.
- Vision endpoints.
- Embeddings endpoints.
- Reranking endpoints.
- Batch jobs.
- Dedicated capacity reservation.
- Tool execution.
- Strict schema-enforced structured outputs.
- Prompt moderation.
- Content classification systems.
- Complex abuse-scoring ML.
- Long buyer-side queueing.
- Mintlify-style docs platform.
- ReadMe-style docs platform.
- GitBook-style docs platform.
- Multi-region coordinator deployment.
- Cloudflare Workers deployment.
- Vercel Functions deployment.
- Lambda@Edge deployment.
- Multi-surface brand architecture.
- Separate docs subdomain.
- Separate status subdomain.
- Bring-your-own-key support.
- Custom model upload.
- Enterprise tier.
- SOC 2.
- HIPAA.
- Compliance certifications.

These items belong to v0.2, SPEC-005, SPEC-007, or later specs.

**Provider-side caching remains guarded.** Prompt-result cache, arbitrary provider-side request state retention, or any cache not explicitly covered by this section remains OUT OF SCOPE. SPEC-006 permits SPEC-004 coordinator-internal sticky affinity, using a gateway-derived `routing_internal.conversation_key` in the reserved `conv:` namespace. **(Narrowed, v0.9.8 — SPEC-024 prefix-cache carve-out:)** provider-*local* prefix caching **keyed on that derived `conv:` value** is now additionally permitted (SPEC-024 v0.2 §11–§12; SPEC-004 v0.3.2 FR-SR-2 / SPEC-008 v0.4.1 §2.2). The guard below still applies to it: the derived key remains account-scoped and unforgeable, the provider never learns the raw tag/`account_id`, and the provider cache carries no account dimension of its own (SPEC-024 v0.2 §11). Sticky affinity is disabled by default (`routing.sticky_enabled: false`) and MUST NOT change buyer-visible behavior unless an operator explicitly enables it.

The § 1.3 guard is satisfied for SPEC-004 v0.2 Pillar A only if all of the following remain true:

- The cache is buyer-owned, single-tenant, non-transferable across buyers. **(v0.9.8 precision:)** "buyer-owned" here is the **account-scoping** sense — a cache entry holds exactly one account's data and is non-transferable across buyers — **not** literal buyer custody or deletion-control: the option-(a) provider-local KV is provider-retained and not buyer-purgeable (see the deletion bullet below).
  - v0.8 satisfaction: `routing_internal.conversation_key` MUST be scoped to exactly one authenticated `account_id`. The gateway MUST refuse to derive or forward a conversation key when the request cannot be attributed to one account or when any input attempts to bind the key to more than one account. Cross-account spoofing MUST be structurally impossible at the gateway by deriving the `conv:` value from the authenticated `account_id`, not from buyer-trusted account claims.
- The cache has explicit lifecycle: creation, eviction, and buyer-triggered deletion. **(v0.9.8 — provider-local prefix cache; honest limitation:)** this precondition is fully satisfied only for the **coordinator sticky map** (`DELETE /v1/sticky` purges it directly). It is **NOT** fully satisfied for the **provider-local KV cache**, and v0.2 does not pretend otherwise: because the derived `conv:` key is **deterministic** (same account + tag ⇒ same key, next bullet) and post-deletion **normal** selection (SPEC-004 FR-SR-3) MAY still route to the same provider, that provider can reuse and **re-populate** its entry under the same key after a delete. So buyer deletion is **neither a direct nor a reliable indirect** purge of provider-local state — the provider entry's **only** dependable bound is the provider's own TTL/LRU (SPEC-024 v0.2 §11 FR-CI4). This is a genuine **residual gap in the § 1.3 lifecycle guard under option (a)**, recorded (not papered over) as the SPEC-024 v0.2 §13 / FR-CI10a disclosure-completeness item; closing it would require a provider-side conv-key purge primitive (not shipped).
  - v0.8 satisfaction: the gateway MUST create a conversation key on an authenticated buyer request that includes a valid `X-MacProvider-Conversation` tag when `routing.sticky_enabled: true`, and MUST NOT create one otherwise. Coordinator eviction is governed by SPEC-004 v0.2 `routing.sticky_ttl_s`, `routing.sticky_max_entries`, TTL expiry, and LRU behavior; the gateway MUST cite that coordinator TTL as the authoritative sticky retention window in buyer-facing disclosure. Buyers MUST be able to trigger account-scoped deletion with `DELETE /v1/sticky`, which is authenticated, idempotent, purges all sticky entries for the caller's account, and returns `{ "purged": true, "entries": N }`. **(v0.9.8 clarification:)** `DELETE /v1/sticky` purges the **coordinator sticky map** only. The **provider-local** prefix-cache entry keyed on the same `conv:` value is a separate store bounded by the provider's own TTL and LRU (SPEC-024 v0.2 §11 FR-CI4, shipped default 900 s); it is **not** buyer-purgeable and is not governed by the coordinator TTL — its reuse-eligibility ends when the provider TTL/eviction lapses, independent of the sticky-map deletion. This lifecycle split is a SPEC-024 v0.2 §13 disclosure-completeness item.
- Tenant isolation is cryptographically enforced; cache keys include account ID plus per-request entropy.
  - v0.8 satisfaction: the gateway MUST derive the opaque suffix with HMAC-SHA256 over the authenticated `account_id` and buyer-supplied conversation tag; the tag is the buyer-provided per-request entropy for this guard. Two gateway instances MUST derive byte-identical keys for identical inputs and different keys across accounts. The normative algorithm is:
    1. Authenticate the request and obtain canonical `account_id`.
    2. Read the buyer tag from `X-MacProvider-Conversation`.
    3. Reject tags shorter than 1 byte, longer than 128 bytes after trimming leading/trailing whitespace, or containing characters outside `[A-Za-z0-9._:-]`. **(v0.9.8 byte-fidelity note:)** the shipped gateway trims with Go `strings.TrimSpace`, which strips **Unicode** whitespace (e.g. NBSP `U+00A0`), not only ASCII; a reimplementation that trims only ASCII whitespace can diverge on tags wrapped in Unicode whitespace (accepted+normalized by the shipped gateway, rejected by an ASCII-only trimmer). This affects only within-account tag canonicalization; cross-account isolation is unaffected because `account_id` is inside the HMAC regardless.
    4. Construct `scope = "spec006-v0.8-sticky-conversation-v1"`.
    5. Construct `message = scope || "\n" || account_id || "\n" || buyer_tag`.
    6. Compute `digest = HMAC-SHA256(MACPROVIDER_KEY_HASH_SECRET, message)`.
    7. Encode the digest with unpadded base64url and emit `routing_internal.conversation_key = "conv:" || encoded_digest`.
    `MACPROVIDER_KEY_HASH_SECRET` rotation MUST follow the existing gateway key-hash secret rotation cadence. During rotation, implementations MAY accept the previous secret for `DELETE /v1/sticky` lookups only (so a buyer can purge keys derived under the prior secret), provided single-account scope is preserved; **routing-time sticky-key derivation MUST use only the current secret** so the rotation overlap window cannot silently extend the effective sticky TTL. The raw buyer tag and raw account ID MUST NOT appear in coordinator logs as the opaque suffix. Because `account_id` is inside the HMAC message and the secret is gateway-held, a tag collision between account A and account B cannot create the same `conv:` value by construction.
- Buyer-facing disclosure explicitly states cache existence and retention semantics.
  - v0.8 satisfaction: when and only when `routing.sticky_enabled: true`, the § 1.6 production disclosure, `/v1/models tier1_disclosure.sticky_affinity`, single-page docs, signup flow, and operator-distributed SDK READMEs MUST disclose sticky affinity, the `sticky_ttl_s` retention window, and the privacy tradeoff that related requests are preferentially routed to one provider during that window.
- The cache survives the Tier 1 to Tier 2 transition with privacy guarantees that match Tier 2 trust controls.
  - v0.8 satisfaction: sticky semantics MUST NOT depend on plaintext-only provider assumptions. A future SPEC-008 Tier-2 attestation/encryption regime MUST preserve account scoping, TTL expiry, buyer-triggered deletion, and the `conv:` namespace without exposing raw buyer tags or account IDs to providers. Concrete invariants a Tier-2 audit MUST verify survive: (a) `account_id` remains inside the HMAC message and cross-account `conv:` collision remains structurally impossible; (b) **(narrowed, v0.9.8 — SPEC-024 prefix-cache carve-out)** the raw buyer tag and `account_id` remain **unrecoverable** by the provider — the `conv:` value is a one-way account-scoped HMAC and is NOT reconstructable by the provider from side-channel traffic — **but** the *derived opaque `conv:` value* MAY be explicitly provided to the provider in the inference request for provider-local prefix caching (SPEC-024 v0.2 §11–§12; SPEC-004 FR-SR-2 / SPEC-008 §2.2 carve-out); the provider thereby learns a stable per-conversation identifier (the correlation sticky affinity already grants, and — because the key is forwarded on cache misses and re-routes — potentially across more than one provider over the conversation's life) but never the raw values; (c) `DELETE /v1/sticky` remains account-scoped and authenticated (coordinator sticky map only — the provider-local prefix cache has an independent, non-buyer-purgeable TTL, see the lifecycle bullet above and SPEC-024 v0.2 §13); (d) TTL expiry remains coordinator-enforced (not provider-self-reported). Tier-2 work MAY change provider-leg confidentiality, but it MUST NOT weaken (a), (c), or (d), nor the raw-value-unrecoverability half of (b).

Any partial implementation of caching that does not meet ALL of the above MUST NOT ship. This is a forward-looking guard against the H-006 audit finding. **(v0.9.8 — option (a) carve-out, resolving the guard-vs-ratification tension:)** this MUST-NOT-ship rule governs the v0.8 **coordinator-internal sticky affinity** in full — all conditions above remain hard requirements for it. For the **option-(a) provider-local prefix cache**, the account-scoping, key-unforgeability, no-independent-account-dimension, and Tier-1→Tier-2 survivability conditions all hold and remain hard-required. **Two conditions are only partially met, and both are knowingly-accepted, operator-ratified (option (a), 2026-07-12), and explicitly tracked — not treated as unmet guards that block shipping:**
1. **Buyer-triggered deletion** — fully enforced for the coordinator sticky **map** (`DELETE /v1/sticky`); the provider-KV layer has **no** direct buyer purge (deterministic key + post-delete same-provider re-population), bounded only by provider TTL/LRU (see the lifecycle bullet above).
2. **Buyer-facing disclosure** — the **base** disclosure (sticky affinity exists, the `sticky_ttl_s` retention window, and the preferential-routing/correlation tradeoff) **is** shipped and remains **hard-required**. The **option-(a)-specific extensions** — provider *receipt* and *independent, non-purgeable retention* of the derived identifier, and *cross-provider linkability* — are **not yet** in the shipped buyer disclosure and are tracked as a **MUST-close** completeness item (§ 5.3.1; SPEC-024 v0.2 §13 / FR-CI10a).

Both residuals are recorded (not papered over) as SPEC-024 v0.2 §13 / FR-CI10a disclosure-completeness items; closing them needs a provider-side conv-key purge primitive and the extended disclosure copy (neither shipped). The MUST-NOT-ship rule continues to bar in full any provider-side cache that fails account-scoping, key unforgeability, the no-independent-account-dimension property, or the **base** disclosure obligation.

### 1.4 Relationship to SPEC-001

SPEC-001 defines the provider-side Phase 3 binary and the local OpenAI-compatible inference shape.

SPEC-006 MUST preserve SPEC-001 v1.2.2 behavior for:

- `/v1/models` model identifiers.
- Tolerance for `/` and `\/` in model IDs.
- `/v1/chat/completions` request body semantics.
- ASCII case-insensitive model identifier matching.
- Streaming SSE behavior.
- Syntactic acceptance of normal OpenAI chat fields forwarded to providers.

SPEC-006 MUST NOT modify SPEC-001.

SPEC-006 MAY add stricter public gateway limits before forwarding, including `max_tokens` caps, quota checks, auth checks, and kill switches.

### 1.5 Relationship to SPEC-002

SPEC-002 defines the Phase 4 coordinator.

SPEC-006 layers on top of SPEC-002. The base relationship was established in SPEC-002 v1.1.5; the current SPEC-006 v0.9.12 depends on SPEC-002 v1.5.4 (bounded slot queue plus the account-scoped reconciliation key lineage — see header `Depends on` line and §6 forward-header rule).

SPEC-006 MUST preserve SPEC-002's router-only charter.

SPEC-006 MUST NOT move buyer identity, quota state, account session state, or public signup flows into the coordinator.

SPEC-006 MUST require the coordinator buyer listener to be reachable only from localhost after migration.

SPEC-006 MUST require the gateway to use a configurable coordinator backend list.

SPEC-006 MUST NOT expose SPEC-002 operator endpoints at `api.streamvc.live`.

SPEC-006 normatively cannot mutate SPEC-001 or SPEC-002 during SPEC-006-only implementation or fix cycles.

Cross-spec audit cycles MAY propose coordinated patches across multiple specs. When those patches land, all affected specs bump versions in lockstep; the cross-spec FIX prompt is the governance vehicle, not unilateral SPEC-006 edits.

### 1.6 Tier 1 disclosure: plaintext cooperative inference

SPEC-006 v0.8 is a Tier 1 cooperative inference product. The following properties hold:

1. **Buyer prompts and provider responses are processed as plaintext on provider hardware.** Providers can technically observe prompts and outputs that route through their machine. This is acceptable for cooperative deployments where buyer and provider have an established trust relationship; it is NOT a private-inference guarantee.
2. **There is no hardware attestation or runtime integrity check on providers.** The coordinator admits providers based on `provider_id` match (pinned tier) or rate-limited provisional admission. Once admitted, the provider runtime is trusted to faithfully serve requests; SPEC-006 v0.8 does NOT cryptographically verify this.
3. **Model identity is provider-reported.** `/v1/models` distinguishes provider-reported model IDs, catalog-known hash status, and settlement-enforced receipt matching. Settlement enforcement applies only to included paid entrypoints in enforce mode after a receipt matches the route-time catalog snapshot; excluded legacy/direct paths are named separately. Mixed pools are not described as fully verified.
4. **v0.4 settlement receipts verify the provider-reported request-start model hash against the route-time catalog snapshot.** They do not detect a provider falsifying its own loaded-model hash measurement.
5. **Observe mode may record receipt and model-hash diagnostics, but it cannot claim verified model integrity and it does not change buyer debit or provider payout.** Enforce mode may settle only covered paid entrypoints listed in this disclosure whose settlement-capable receipt reaches verified finality; mixed pools are not described as fully verified.
6. **Pending means quota or balance can remain reserved while receipt verification is incomplete.** Non-verified terminal outcomes release or refund that reservation. pending: receipt verification is still incomplete and the reservation is not final usage. verified: a settlement-capable receipt matched the route-time catalog snapshot and can finalize buyer debit and provider settlement. quarantined: not charged because model-integrity or receipt verification failed; this is not labeled as buyer fault. zero_settled: not charged because no billable verified work was produced; this is not labeled as buyer fault.
7. **Buyer cancel, gateway timeout, provider error, or upstream disconnect can create a partial charge only when a settlement-capable receipt binds the delivered output prefix and partial usage.** Transparent streaming failover bills only delivered, verified output across attempts and does not double-charge overlapping output; verified here means receipt-bound under the provider-reported-hash caveat above.
8. **Buyer receipt and status surfaces expose pending, verified, quarantined, and zero_settled labels without raw prompts or raw outputs.**
9. **The product makes NO private-inference, hardware-attestation, runtime-binary-attestation, provider-private-prompt, untrusted-provider, malicious-output-prevention, or provider-falsified-model-measurement detection claims.** Any buyer-facing language, including front-door copy, docs, error messages, API responses, marketing material, and this spec, MUST be consistent with these limitations.
10. **When sticky affinity is enabled for an account, related requests are preferentially routed to one provider for up to `routing.sticky_ttl_s`.** That provider can observe and correlate more of the buyer's traffic than under default round-robin routing. This disclosure is required only when `routing.sticky_enabled: true`; with the default `routing.sticky_enabled: false`, there is no sticky routing and no new sticky-specific privacy posture beyond properties 1-9.

These limitations are deliberate. Tier 2, a future SPEC-008 milestone and not in v0.8 scope, would add hardware attestation, provider-leg encryption, model catalog enforcement, and untrusted-provider safety. Until Tier 2 ships, all ten limitations are normative and MUST be preserved in product language, with property 10 conditional on `routing.sticky_enabled: true`.

Production gate: this disclosure MUST appear in substantively equivalent language in:

- The front-door signup flow before the user receives an API key: one prominent paragraph.
- The single-page docs: the curl plus SDK examples page.
- The `/v1/models` response as a top-level `tier1_disclosure` field with the same plaintext-to-provider wording.
- The README.md of any client SDK distributed by the operator.

When `routing.sticky_enabled: true`, the same appearance points MUST also include the sticky affinity disclosure in property 6. When `routing.sticky_enabled: false`, operators are not required to surface sticky-specific disclosure language beyond `/v1/models tier1_disclosure.sticky_affinity.enabled: false`.

### 1.7 Relationship to SPEC-003

SPEC-003 made provider onboarding easy through distribution and lifecycle tooling.

SPEC-006 makes buyer onboarding easy through web identity, immediate key issuance, examples, and low-friction quota-limited API access.

SPEC-006 inherits SPEC-003's lesson that the actual user-shaped path must be integration-tested, not only code-reviewed.

### 1.8 Relationship to SPEC-004, SPEC-005, and SPEC-007

SPEC-004 v0.2 defines the routing-side contract for smart routing and sticky affinity, including `routing_internal.conversation_key`, the reserved `conv:` namespace, ε-cohort sticky promotion, breaker composition, sticky TTL, and the rule that sticky keys MUST NOT be accepted from direct buyer traffic. SPEC-006 v0.8 fulfills the gateway side of that contract: deriving the account-scoped conversation key, transporting it to the coordinator, disclosing the privacy posture, and satisfying the v0.7 § 1.3 sticky-caching preconditions. Pillar A implementation may proceed only when SPEC-004 v0.2 and SPEC-006 v0.8 are both audited ACCEPT and a SPEC-004 build prompt for Pillars B/C/D/A is run.

SPEC-005 rewards, payouts, provider contribution economics, and any payment-adjacent flows remain out of scope.

SPEC-007 marketplace or Antseed integration remains out of scope.

SPEC-006 MAY record data that later specs use, such as provider contribution counters and user feedback ratings.

SPEC-006 MUST NOT create buyer-visible payout, earning, donation, or payment promises.

### 1.9 Critical constraints

SPEC-001 and SPEC-002 are locked and unchanged during SPEC-006-only implementation and fix passes.

SPEC-006 layers on top of the SPEC-002 coordinator. (Current dependency: SPEC-002 v1.5.4; base relationship established in v1.1.5 — see §1.5 and the document header `Depends on` line.)

Cross-spec dependencies are read-only references.

SPEC-006 MUST NOT propose unilateral changes to SPEC-001 or SPEC-002 outside a coordinated cross-spec audit/fix cycle.

OpenAI compatibility is normative.

Any OpenAI Python or JavaScript SDK call against `https://api.streamvc.live/v1/chat/completions` with a valid bearer key MUST succeed for supported models.

Deviation from OpenAI's chat completion request/response shape MUST be documented as a known divergence.

The d-inference source is clean-room for SPEC-006.

SPEC-006 authors and implementers MUST NOT inspect d-inference source while drafting or implementing this gateway.

Buyer-facing responses MUST NOT include provider hostnames, internal coordinator URLs, operator keys, signing keys, stable provider IDs, or any other buyer-visible secret.

The gateway MUST be horizontally scalable from day 1.

The gateway MUST forbid in-process authoritative quota, concurrency, billing, or session state. Non-authoritative process-local request-start buckets are allowed only for preflight abuse shedding as described in §4.6 and §7.3.

The gateway MUST require data layer abstraction.

SPEC-006 v1 deploys as a single gateway instance with SQLite on Pearl VPS.

The stateless-handlers requirement preserves multi-instance feasibility but is not exercised in v1.

See Section 14.2 for the storage layer's role in this constraint.

Usage events, feedback events, and audit logs MUST be append-only.

No hot-path storage design MAY require row updates for usage, feedback, or audit history.

Bearer-token validation MUST be achievable in less than 1 ms p95 against the storage layer.

M4 and M1 partner Macs currently serving direct buyers at `m4.streamvc.live` and `m1.streamvc.live` remain operational.

Gateway does not intercept those legacy direct-tunnel paths.

---

## 2. Locked decisions

This section reproduces the operator's pre-commitments from `specs/BUILD_SPEC_006_PROMPT.md` "Locked design choices."

Cross-references have been updated to match this document's section numbering.

Punctuation has been normalized for prose flow.

Substantive content is unchanged.

Any apparent semantic divergence from the BUILD prompt is a bug to be fixed in subsequent revisions.

This section is read-only design input and MUST NOT be treated as a place to propose alternatives.

### 2.1 Architecture

- **Separate Go gateway service** at `phase5-gateway/` (consistent with the existing `phase3-binary/`, `phase4-coordinator/`, `phase5-onboarding/` naming). Binds its own port; separate systemd unit; its own deployment artifact.
- **Coordinator stays router-only.** SPEC-002 v1.1.3's "coordinator is a router" charter is preserved. Coordinator's buyer port (currently bound `0.0.0.0:8443`) MUST be rebound to `127.0.0.1:8443` as part of this migration. All public `/v1/*` traffic goes through gateway.
- **Designed for 10K-Mac scale.** Specifically:
  - Stateless request handlers. No in-process rate-limit counters, no in-process session caches, no in-process quota state.
  - Data layer abstracted behind a Go interface (`AuthStore`, `UsageStore`, etc.). Concrete v1 implementation: SQLite at Pearl VPS. Migration targets (Cloudflare D1, PostgreSQL, Workers KV) MUST require zero changes outside the storage package.
  - Schema designed for global replication. API keys MUST be immutable once issued. Usage events MUST be append-only with monotonic timestamps. No row updates in the hot path.
  - Coordinator backend MUST be a configurable list, not a hardcoded URL. v1 has one entry (`http://127.0.0.1:8443`); future entries will be regional coordinators.
  - No long-lived TCP connections in gateway. Each buyer HTTP request is one-shot. SSE streams flow through but the gateway handler is request-scoped (no shared goroutines holding socket state across requests).
  - Sub-millisecond auth check. Bearer token validated by indexed single-key lookup in the store.

### 2.2 Public API surface

- Canonical buyer URL: `https://api.streamvc.live`.
- Internal coordinator URL: `https://coordinator.streamvc.live` stays in service for M4/M1 legacy direct-tunnel buyer paths and operator endpoints (`/admin/*`, `/poolz`, `/healthz`).
- Endpoints exposed at `api.streamvc.live`:
  - `GET /v1/models`
  - `POST /v1/chat/completions` (including SSE streaming via `stream: true`)
  - `POST /v1/messages` only when `features.anthropic_messages_enabled` is true
  - `GET /v1/usage`
  - `GET /v1/status`
  - `POST /v1/feedback`
  - OAuth callbacks at `/auth/github/callback` (and `/auth/email/callback` if email magic link is implemented)
  - Signup/key-management UI at `/account` (or operator-chosen path consistent with the Vercel demo's structure)
- Endpoints NOT exposed at `api.streamvc.live` (kept internal):
  - `/admin/*`, `/poolz`, `/healthz`, `/ws/provider` -- all remain on coordinator port.

### 2.3 Identity

- **GitHub OAuth is the primary identity method.** Web-app credentials, one-click flow, account created on first successful callback.
- **Email magic link is the secondary method** if it can be implemented cheaply on a free tier (Resend, SendGrid, Postmark; choose whichever has the lowest operator-onboarding cost). If no free tier is practical for v1, defer email magic link to v0.2 and ship GitHub OAuth only.
- One account per identity. Multiple API keys per account permitted (default: one active key on signup, regeneration/revocation available).
- Key shape: prefix `mp_`, followed by high-entropy random secret (specified in Section 6.4). Server stores only a hash (SHA-256 or HMAC). Full key shown once at issuance, never re-displayable.

### 2.4 Quotas

- **Default daily quota: 100,000 total tokens per account per day.** Adjustable in `gateway.yaml` without code change.
- **Unauthenticated demo quota: 1,000 total tokens per IP per day.** Demo traffic is allowed via specific endpoints (chat playground through front door) and a tiny `X-Demo-Token` header sourced from the Vercel demo's session cookie.
- **Per-account concurrency cap: 2 concurrent requests** at v1. Adjustable.
- **Per-IP signup issuance: 3 accounts per IP per day** (Sybil defense).
- **Per-request `max_tokens` cap: 4,096** at v1. Adjustable.

### 2.5 Provider transparency

- Buyers see: model identifiers, `provider_count`, `total_slots`, `max_context_tokens`, aggregated degraded state.
- Buyers do NOT see: stable provider IDs (`m4-anon`, `augustass-macbook-air`, etc.), hostnames, IP addresses, geographic location of providers.
- Provider metadata in `/v1/models` MUST be aggregated. If 3 providers serve the same model, the buyer sees one entry with `provider_count: 3`, not three entries.

### 2.6 Status transparency

- `GET /v1/status` returns:
  - Coordinator health (up/degraded/down)
  - List of available models with current `provider_count`, `total_slots`, `slots_free`
  - Aggregate pool state: total providers, ready count, draining count, unavailable count
  - Network-wide degraded flag (true if `ready < some_threshold`)
- Status MUST NOT expose:
  - Individual provider hostnames or IDs
  - Provider RAM/CPU specs
  - Operator identity

### 2.7 Kill switches

Two operator-controlled flags, both stored in `gateway.yaml` (or runtime via a `/admin/kill-switch` endpoint requiring operator key):

- `kill_switch.demo_only` -- when true, unauthenticated demo traffic returns 503 immediately; authenticated API traffic continues.
- `kill_switch.all_public_api` -- when true, ALL public API requests return 503 with a friendly "beta paused" message. Used for capacity-burst Tier 3 and incident response.

Both flags MUST be togglable without restarting the gateway.

### 2.8 Capacity-burst protection

The operator has pre-committed:

- **Monthly cash absorption cap: $500/month.** Encoded in `gateway.yaml` as `capacity.monthly_budget_usd: 500`.
- **NO Tier-3 deprecation clause.** The spec does NOT contain a MUST-execute-shutdown branch. The operator chooses iteration over deprecation.
- **Replacement falsification mechanism: in-session user rating.** See Section 11.

Tiered escalation requirements:

- **Tier 1 (close signups)** fires when ANY of:
  - Pearl VPS sustained CPU >70% for 4 hours
  - Coordinator memory >80%
  - Bandwidth >70% of VPS quota
  - Any provider explicitly requests reduced load (signaled via `/admin/provider-feedback` endpoint or operator email)
  - Projected monthly cost reaches 80% of `capacity.monthly_budget_usd`
  Action: signup page returns "closed" status; existing users continue at current quotas.

- **Tier 2 (quota tighten)** fires when Tier 1 is active for 7+ days AND any signal still firing.
  Action: reduce all account daily quotas by 50% (via config); banner on front door indicates capacity tightening.

- **Tier 3 (hard pause)** fires when ANY of:
  - Monthly cost exceeds `capacity.monthly_budget_usd`
  - 2 or more providers drop within a 48-hour window
  - Operator self-reports reactive-ops time >70% of any week (via `/admin/operator-load` endpoint)
  Action: `kill_switch.all_public_api` set true; API returns 503 with beta-paused message; pool gets to rest.

- **Capacity expansion (optional positive branch)** is available at any tier: operator can raise budget cap, upgrade Pearl VPS, recruit more providers. Choosing this branch reverses the tier without requiring root cause resolution.

### 2.9 User feedback

- **Rating scale: 1-4** (1=bad, 2=average, 3=good, 4=excellent).
- **Capture mechanisms (both required for v1):**
  - **(B) API endpoint `POST /v1/feedback`** -- optional, per-session or per-request. Request body: `{ "rating": 1-4, "comment": "optional free text", "request_id": "optional reference to a prior completion" }`. Authenticated (bearer token required). Idempotent if `request_id` is provided.
  - **(C) Dashboard widget at `/v1/usage` (or front-door /account page)** -- persistent 1-4 rating widget, captures "how is your experience overall" not per-request.
- **Chat playground bonus capture (not normative but recommended):** the existing Vercel demo MAY prompt the user for a 1-4 rating after N exchanges. Implementation deferred to front-door work.
- **Aggregation:** ratings are stored as append-only events with timestamp, account_id (or anonymous for chat playground), rating, comment. Operator-readable aggregation endpoint at `/admin/feedback-summary`.
- **Iteration signal:** if the 7-day rolling distribution shifts toward 1-2 (bad/average) for any 2-week window, the operator MUST review root cause. The mechanical threshold is specified in Section 11.6. No MUST-pivot trigger (operator chose iteration), but the rating data is the primary feedback channel replacing the falsification framework's "deprecate" clause.

### 2.10 Donation link

Not in v1.

Do not include a donation button, "support us" link, or any payment-adjacent UI element.

If users ask, operator can point them at a future SPEC-005 rewards discussion.

### 2.11 North-star metric

Time to first successful API call (visit -> key issuance -> first successful `/v1/chat/completions` 200 response).

The gateway MUST instrument this from the front door's "Get API key" click through the first non-error completion.

The metric MUST be reportable as a 7-day rolling distribution with median (p50) and p95.

### 2.12 Failure modes

- `404` -- model unknown (model not in any provider's served, declared `supported_models`, or recently-seen list — see § 17.2).
- `503` -- model known but no provider available (pool empty or all busy; a declared-but-cold model is *known*, so 503 here, not 404).
- `502` -- selected provider failed mid-request.
- `504` -- provider exceeded timeout.
- `401` -- invalid or missing bearer token.
- `403` -- valid token but disabled/blocked.
- `429` -- quota exhausted, with `X-RateLimit-Reset` header.
- All error responses MUST use OpenAI-shaped error envelope:

```json
{"error":{"message":"...","type":"invalid_request_error","code":"..."}}
```

- All responses MUST include rate-limit headers when applicable:
  - `X-RateLimit-Limit`
  - `X-RateLimit-Remaining`
  - `X-RateLimit-Reset`

No unbounded queueing.

For non-pinned requests, the coordinator MAY wait in the bounded
pre-dispatch slot queue described in section 7.8. If no slot becomes
available before that deadline, return 503.

Streaming cancellation: when client disconnects mid-SSE, gateway MUST cancel the upstream request to coordinator within 500ms.

### 2.13 Provider-relationship hooks

- No compensation change in v1.
- Add provider contribution counters (per-provider: requests served, prompt tokens, completion tokens) if the data already exists in coordinator's request log. Expose at `/admin/provider-contributions` for operator visibility only.
- Do NOT expose provider earnings, individual revenue, or any payout fields. Those are SPEC-005 scope.

### 2.14 Front door

- Existing demo at `web-three-lime-59.vercel.app` becomes the front door.
- Updates required:
  - Repoint chat backend from `m4.streamvc.live` / `m1.streamvc.live` direct tunnels to `https://api.streamvc.live/v1/chat/completions` (via demo-only unauthenticated quota).
  - Add "Get API key" flow (GitHub OAuth, optionally email).
  - Add `/account` page showing usage, quota remaining, regenerate key, revoke key.
  - Add single-page docs section: curl examples, OpenAI Python and JavaScript SDK snippets, error code explanations, quota docs, "real Macs, sometimes asleep" caveats.
  - Add /status panel showing live pool state.
  - Add rating widget (capture mechanism C).
- The spec MUST define the front-door contract (what data it consumes from gateway, what URLs it calls). Front-door implementation is a separate work item; spec only defines the contract.

### 2.15 Documentation

Single-page docs inside the front door are required.

Required content:

- Get a key (OAuth flow walkthrough).
- List models (`GET /v1/models` curl + OpenAI SDK).
- Chat completion (`POST /v1/chat/completions` curl + OpenAI Python + OpenAI JavaScript).
- Streaming example.
- Usage check (`GET /v1/usage`).
- Error code explanations.
- Quota explanation and reset behavior.
- Network-state caveat.
- Feedback (`POST /v1/feedback`).

Do NOT adopt a docs platform.

---

## 3. Terms and definitions

### 3.1 Gateway

The gateway is the public Go service deployed from `phase5-gateway/`.

The gateway accepts buyer HTTP requests, authenticates or classifies them, enforces quotas and kill switches, forwards eligible inference requests to a coordinator backend, and shapes public responses.

### 3.2 Coordinator

The coordinator is the SPEC-002 router service in `phase4-coordinator/`.

The coordinator maintains the provider pool and routes inference to providers.

The coordinator is not the public account system.

### 3.3 Buyer

A buyer is any external user or integration calling the public gateway.

The term "buyer" does not imply payment in SPEC-006 v1.

### 3.4 Account

An account is a stable identity record created through GitHub OAuth or optional email magic link.

An account owns API keys, quota, usage events, and feedback events.

### 3.5 API key

An API key is a bearer secret with prefix `mp_`.

The gateway shows the full key once at issuance.

The storage layer stores only a hash or HMAC of the secret.

### 3.6 Demo traffic

Demo traffic is unauthenticated traffic initiated by the front door chat playground.

Demo traffic MUST include `X-Demo-Token`.

Demo traffic MUST be quota-limited by IP and demo token.

Demo traffic MUST NOT receive account privileges.

### 3.7 Quota

Quota is the maximum allowed token usage, request count, signup count, or concurrency count for a principal over a configured time window.

Quota enforcement state MUST be persisted outside the process.

### 3.8 Usage event

A usage event is an append-only record of a request's measured or estimated token usage, status, latency, account, key, model, and request ID.

Usage events MUST NOT be updated in the hot path.

### 3.9 Rating

A rating is a 1-4 user feedback score.

A rating may be per request, per session, or overall account experience.

### 3.10 Capacity-burst tier

A capacity-burst tier is a mechanically triggered operating posture that closes signups, tightens quota, or pauses public API traffic when capacity, cost, provider comfort, or operator load crosses configured thresholds.

### 3.11 Hot path

The hot path is the synchronous path required to accept or reject and forward a buyer request.

The hot path includes auth lookup, kill-switch check, quota check, concurrency reservation, request validation, coordinator forwarding, response relay, and append-only event writes.

---

## 4. Architecture

### 4.1 Service topology

The v1 deployment MUST contain:

- `phase4-coordinator` running the SPEC-002 router.
- `phase5-gateway` running the SPEC-006 public gateway.
- TLS termination for `api.streamvc.live` in front of the gateway.
- TLS termination for `coordinator.streamvc.live` in front of coordinator operator/provider paths.
- SQLite storage for gateway v1 state on Pearl VPS.
- Front-door Vercel demo calling the gateway.

The gateway MUST have its own systemd unit.

The gateway MUST have its own deployment artifact.

The gateway MUST bind its own local port.

The gateway MUST be restartable independently of the coordinator.

### 4.2 Public and private boundaries

`https://api.streamvc.live` MUST expose only:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/messages` only when `features.anthropic_messages_enabled` is true
- `GET /v1/usage`
- `GET /v1/status`
- `POST /v1/feedback`
- `/auth/github/callback`
- `/auth/email/callback` if email magic link ships
- `/account` or equivalent account UI path

`https://api.streamvc.live` MUST NOT expose:

- `/admin/*`
- `/poolz`
- `/v1/pool/check`
- `/healthz`
- `/ws/provider`
- Coordinator debug paths.
- Provider identifiers.
- Provider hostnames.
- Provider endpoint URLs.
- Operator keys.
- Internal coordinator backend URLs.

`https://coordinator.streamvc.live` MAY remain in service for:

- M4/M1 legacy direct-tunnel buyer paths.
- Operator endpoints.
- Provider WebSocket endpoint.
- Coordinator health and pool operations.
- `GET /v1/pool/check` provider registration verification, owned by SPEC-002 v1.1.4 and used by SPEC-003 v0.7 installers.

### 4.3 Coordinator listener migration

As part of the SPEC-006 migration, the coordinator buyer listener currently bound on `0.0.0.0:8443` MUST be rebound to `127.0.0.1:8443`.

Public `/v1/*` traffic MUST flow through the gateway.

Direct public access to coordinator `/v1/*` MUST NOT be required for new buyers.

Legacy direct-tunnel buyers at `m4.streamvc.live` and `m1.streamvc.live` remain outside gateway interception.

### 4.4 Request flow: authenticated chat

Authenticated chat flow:

```text
Buyer
  -> TLS api.streamvc.live
  -> gateway auth middleware
  -> kill-switch check
  -> request validation
  -> quota check
  -> concurrency reservation
  -> coordinator backend selection
  -> coordinator POST /v1/chat/completions
  -> provider route through coordinator
  -> response relay through gateway
  -> append-only usage/audit events
```

The gateway MUST forward supported OpenAI chat completion fields without semantic rewriting except for configured gateway caps.

The gateway MUST NOT add buyer-visible provider identifiers to the response.

The gateway MUST remove or suppress coordinator route headers that disclose provider identity.

### 4.5 Request flow: demo chat

Demo chat flow:

```text
Browser front door
  -> demo session cookie
  -> X-Demo-Token header
  -> gateway demo classifier
  -> demo-only kill switch
  -> IP/demo-token quota check
  -> reduced request caps
  -> coordinator forwarding
  -> response relay
  -> append-only demo usage event
```

Demo traffic MUST be limited to chat playground use.

Demo traffic MUST NOT call `/v1/usage`.

Demo traffic MUST NOT create API keys.

Demo traffic MUST NOT bypass account signup issuance limits.

### 4.6 Stateless handlers

Gateway request handlers MUST be stateless.

The gateway MUST NOT keep authoritative quota, concurrency, billing, or
session state in-process.

The gateway MAY keep a best-effort process-local request-start token
bucket for abuse shedding before coordinator forwarding. That bucket is
scoped to one gateway instance; multi-replica deployments multiply the
effective aggregate request-start rate unless they add a shared
admission layer. The bucket
MUST be keyed by authenticated `account_id` or demo subject identity,
MUST NOT be used for billing or settlement, and MUST NOT be the only
guard for daily quota or in-flight concurrency. Daily quota and
concurrency remain storage-backed authoritative controls.

The gateway MUST NOT keep in-process quota state.

The gateway MUST NOT keep in-process account sessions as authoritative state.

The gateway MUST NOT require sticky load balancing.

The gateway MAY use short-lived local variables for one request.

The gateway MAY use process-local caches only for non-authoritative static config if cache invalidation is deterministic and documented.

### 4.7 Data layer abstraction

Gateway storage MUST be behind Go interfaces.

Required interface families:

- `AuthStore`
- `AccountStore`
- `KeyStore`
- `UsageStore`
- `QuotaStore`
- `FeedbackStore`
- `AuditStore`
- `ConfigStore` or reloadable config provider
- `CapacityStore`

SQLite MUST be the concrete v1 implementation.

Migration to Cloudflare D1, PostgreSQL, or Workers KV MUST require no changes outside the storage package and config wiring.

### 4.8 Append-only storage

Usage events MUST be append-only.

Feedback events MUST be append-only.

Audit events MUST be append-only.

Capacity signal events MUST be append-only.

Append-only audit events in v0.2 are not required to be tamper-evident; hash-chain or Merkle-tree integrity SHOULD be considered for v0.3 if the attack surface grows.

API key issuance records MUST be immutable once created.

Revocation MUST be represented by a new revocation event or by a non-hot-path status table mutation that is explicitly outside usage event recording.

No hot-path request MUST depend on updating a usage row after insert.

### 4.9 Sub-millisecond auth

Bearer-token validation MUST be achievable in less than 1 ms p95 against the storage layer under v1 expected load.

The key lookup MUST be a single indexed lookup by key hash or key HMAC.

The lookup result MUST contain enough account/key status information to decide:

- key exists or not.
- key is active or revoked.
- account is active or blocked.
- account quota class.
- account concurrency class.

If the v1 SQLite implementation cannot prove p95 under 1 ms locally, the implementation MUST add an index or adjust schema before launch.

### 4.10 Coordinator backend list

Gateway config MUST define coordinator backends as a list.

The v1 list contains one entry:

```yaml
coordinators:
  - name: pearl-local
    base_url: http://127.0.0.1:8443
    weight: 1
    enabled: true
```

The gateway MUST NOT hardcode `http://127.0.0.1:8443`.

The gateway MUST be structured so future regional coordinators can be added through config.

### 4.11 No long-lived gateway TCP state

Each buyer HTTP request MUST be request-scoped.

The gateway MUST NOT hold shared goroutines that own socket state across unrelated buyer requests.

SSE streams MAY remain open for the lifetime of the buyer request.

When an SSE client disconnects, the gateway MUST cancel the upstream coordinator request within 500 ms.

### 4.12 OpenAI compatibility

Any OpenAI Python or JavaScript SDK call against:

```text
https://api.streamvc.live/v1/chat/completions
```

with a valid bearer key and supported model MUST succeed for supported request shapes.

Known v1 divergences MUST be documented in Section 5 and front-door docs.

Known v1 divergences include:

- No tool execution.
- Tool fields may be syntactically accepted but are not executed.
- Strict schema-enforced structured outputs are not guaranteed.
- Multimodal `messages[].content` parts are not supported in v1. For `system`
  and `user` messages, text-only structured content arrays are accepted and
  normalized to a single string; non-text parts such as `image_url` return
  `unsupported_content_shape`.
- Provider availability can yield 503 immediately.
- Model lineup is live-pool dependent.
- Usage accounting may be gateway-estimated when provider token fields are absent.

---

## 5. Public HTTP API

### 5.1 Common requirements

All public API responses MUST set:

```text
Content-Type: application/json
```

except streaming responses, which MUST set:

```text
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache, no-transform
X-Accel-Buffering: no
```

All authenticated API requests MUST accept:

```text
Authorization: Bearer mp_...
```

All applicable quota responses MUST include:

```text
X-RateLimit-Limit
X-RateLimit-Remaining
X-RateLimit-Reset
```

When the request is authenticated, rate-limit headers describe the account daily token quota unless a more specific quota blocked the request.

When the request is demo traffic, rate-limit headers describe the demo daily token quota.

When request-start or concurrency admission blocks the request, the gateway MUST return `429`, SHOULD include `Retry-After`, and SHOULD include the OpenAI-compatible request-count headers:

```text
X-RateLimit-Limit-Requests
X-RateLimit-Remaining-Requests
X-RateLimit-Reset-Requests
```

The gateway MUST include:

```text
X-Request-ID
```

on all responses.

The gateway MUST generate a UUID v4 `X-Request-ID` per buyer-incoming request and use it as the `request_id` field in `usage_events` and `audit_events`. **Identity after #196 / SPEC-006 v0.9.1:** `request_id` alone is a correlation/join value, not a unique row identity. The physical primary key of `usage_events` is the composite `(account_id, request_id)`, and the gateway-to-coordinator reconciliation key is the composite `(account_id, external_request_id)` (where `external_request_id` is the inbound `X-Request-ID` carried verbatim across the gateway/coordinator boundary). The same `X-Request-ID` MAY legitimately appear in rows belonging to distinct accounts; reconciliation and uniqueness checks MUST be account-scoped.

The gateway MUST forward `X-Request-ID: <uuid>` to the coordinator on every forwarded buyer request. SPEC-002 v1.1.4 requires the coordinator to honor that ID in `request_log.external_request_id`; SPEC-002 v1.5.0 adds the composite-key requirement below.

The gateway MUST also forward `X-MacProvider-Account: <subject.AccountID>` on every forwarded buyer request — bearer-authenticated and demo subjects alike, both on the sticky and non-sticky routing paths. The coordinator persists this value into `request_log.account_id`. The composite `(account_id, external_request_id)` is the reconciliation key joining gateway `usage_events` to coordinator `request_log`; the gateway therefore MUST NOT gate `X-MacProvider-Account` on the sticky-routing conditional (pre-v0.9.1 gateways did, leaving the non-sticky hot path account-blind). See SPEC-002 v1.5.0 §7.2 for the coordinator-side contract; the gateway-side composite-PK addendum is recorded in SPEC-007 §6.4 once issue #212 / PR #221 merges (the two PRs are merge-order independent — this pointer describes relative state, not a strict ordering).

The gateway MUST pair `X-MacProvider-Account` with the upstream `Authorization: Bearer <UpstreamCoordinatorBearer>` header on every forward. The coordinator's `selectProviderExcluding` treats `X-MacProvider-Account` as an internal-routing header and `400`s buyer-port requests carrying it without the gateway-service-token bearer. The bearer is therefore hoisted out of the sticky conditional alongside the account header; sticky-specific state (`X-MacProvider-Internal-Conv`) remains sticky-gated.

The gateway MAY accept an inbound `X-Request-ID` only if it is a UUID v4 in 8-4-4-4-12 lowercase or uppercase hex format; otherwise it MUST generate its own.

`X-RateLimit-Remaining` MUST reflect post-decision remaining quota after admission, rejection, or reservation.

`X-RateLimit-Reset` MUST be a Unix timestamp for OpenAI SDK compatibility.

### 5.2 Error envelope

For OpenAI-compatible endpoints, all non-streaming errors MUST use this shape:

```json
{
  "error": {
    "message": "Human-readable message",
    "type": "invalid_request_error",
    "code": "machine_readable_code"
  }
}
```

The experimental Anthropic Messages facade (`POST /v1/messages`) is the
documented exception: its non-streaming errors MUST use an Anthropic-shaped
envelope with the same gateway `code` and `retryable` extension fields:

```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "Human-readable message",
    "code": "machine_readable_code",
    "retryable": false
  }
}
```

The `type` field MUST be one of:

- `invalid_request_error`
- `authentication_error`
- `permission_error`
- `rate_limit_exceeded`
- `api_error`
- `server_error`
- `service_unavailable`
- `upstream_error`

Streaming errors after headers are sent MUST be emitted as SSE data frames with an OpenAI-shaped error object, followed by `[DONE]`. The `/v1/messages` facade instead emits Anthropic SSE `event: error` frames with the Anthropic-shaped error object above, including `code` and `retryable`.

The gateway MUST install panic recovery middleware that converts unexpected panics into HTTP 500 responses in the endpoint's documented error envelope.

**Retryability (`retryable`).** Every coordinator- or gateway-ORIGINATED buyer error envelope (non-streaming JSON body and streaming SSE `error` frame alike, including the experimental Anthropic-shaped `/v1/messages` facade envelope) MUST carry a boolean `retryable` field alongside `code`. `retryable` is envelope metadata: for most codes it equals the code's fixed default classification below, but specific codes carry a documented per-response override — see "Overrides" below. A provider-originated error body forwarded verbatim is a documented exception to the MUST — see "Known carried items" (4).

**Retryable (`true`) — the same request may succeed later without changes, grouped by why:**

- Availability/timeout: `no_provider_available`, `provider_error`, `provider_timeout`, `provider_disconnected`, `provider_failed` (coordinator-generated); `coordinator_unavailable`, `upstream_provider_error` (§13.4's error-action table already directs buyers to retry this), `invalid_provider_usage`, `invalid_provider_response` (gateway-generated provider response-shape defects).
- Temporal 429s that ship a machine-readable backoff signal — a `Retry-After` or `X-RateLimit-Reset*` header the buyer can act on: `provisional_quota_exceeded`, `rate_limited` (coordinator); `account_request_rate_exceeded`, `account_concurrency_exceeded`, `demo_concurrency_exceeded`, `quota_exhausted` (gateway).
- Operator-controlled capacity pauses — the pause condition itself resolves with time, not with a different request: `public_api_paused`, `demo_paused`, `capacity_signup_closed`.
- Preflight/idempotency infrastructure availability: `preflight_rejected`, `idempotency_unavailable`.
- Route-snapshot durable-store availability: `route_snapshot_failed` — a pre-dispatch store write failure; a retry can succeed once storage recovers.
- Provider response-shape glitches where a re-attempt (possibly against a different provider) may not repeat the same defect: `malformed_tool_call_final_json`, `provider_stream_downgraded`, `malformed_json_response`, `json_schema_validation_failed`.

**Permanent (`false`) — retrying the identical request cannot succeed:** validation errors (e.g. `invalid_request`, `invalid_json`, `invalid_tools`), `model_not_found`, `context_exceeds_capacity`, `unsupported_content_shape`, byte/schema-cap and stream-cap violations (e.g. `byte_cap_exceeded`, `request_body_too_large`, `stream_output_exceeded`, the `json_schema_*` cap/shape codes), Tier-2/config lookup failures (e.g. `autotune_feed_not_found`), and auth/admin/oauth-signup client errors. Any code not explicitly classified — on either service — defaults to `retryable: false`.

**Abuse-limit exception (security).** `feedback_rate_limited`, `oauth_state_rate_limited`, `demo_session_rate_limited`, and `signup_rate_limited` (gateway) are 429s from the same `rate_limit_exceeded` family as the temporal 429s above, but are classified `false` rather than true: none ships a `Retry-After`/reset header, and none sits behind the gateway's 30-RPS per-account request clamp the way `/v1/chat/completions` does. Marking them `true` would tell a conforming SDK to auto-retry a 429 against an endpoint with no other throttle — a DoS-amplification risk, not a convenience. (`signup_rate_limited` is a per-IP daily account-creation cap; retrying the identical signup within the 24h window cannot succeed, so it is permanent from the buyer's perspective until the window rolls off — it was reclassified from `true` to `false` alongside its three siblings.) A future header-bearing fix on these paths should flip them to `true` alongside adding the header, not before.

**Header agreement.** A response that ships a positive `Retry-After` or `X-RateLimit-Reset*` header MUST be `retryable: true` — the two signals MUST NOT disagree, since a buyer honoring either one must reach the same conclusion. The converse does not hold in general: `retryable: true` does not by itself obligate a header — the gateway attaches `Retry-After` only to its `503`/`504` retryable responses and the fixed-window codes (`setGatewayRetryAfter` / `gatewayRetryAfterByCode`), so a retryable `502` availability code (e.g. `provider_error`, `upstream_provider_error`) legitimately carries no backoff hint. But the absence of a header on a `rate_limit_exceeded`-family 429 is a signal in the OTHER direction: without a backoff window and without an account-level throttle, that family is classified `false` (see the abuse-limit exception above). Codes with a backoff window materially longer than the generic fast-availability default carry that fixed value instead: `provisional_quota_exceeded` is 3600s; the capacity-pause codes (`public_api_paused`, `demo_paused`, `capacity_signup_closed`) are 30s (vs. 1s for a fast transient blip) — these three DO ship `Retry-After: 30`, so they are not headerless.

**Maintaining this list.** A newly introduced transient/availability code MUST be added to the retryable set on every service that emits it — the coordinator and gateway are separate Go modules with no shared package, so each maintains its own mirrored classification table (`spec018RetryableByCode` / `gatewayRetryableByCode`). Both modules carry a completeness test asserting every code literal an error writer can emit has been explicitly triaged, so an unclassified code fails CI instead of silently shipping a false default — see "Known carried items" (5) for that guard's limits. Buyers SHOULD honor `retryable` when deciding whether to re-issue a failed request.

**Overrides.** SPEC-019's structured-output terminal error carries a provider-reported `retryable` value (`end.Retryable`) that overrides `malformed_json_response` / `json_schema_validation_failed`'s default for that specific response; BOTH the coordinator's non-streaming writer (`writeProviderStructuredOutputError`) and its streaming SSE writer (`writeSSEErrorWithRetryable`, at the synthesized-terminal-error site) honor it, so the two transports agree on the buyer-visible value for the same terminal outcome.

Carried items (mixed carried / resolved): (1) `response_byte_cap_exceeded` has a locked cross-spec disagreement — SPEC-019's error-code table documents it as retryable, while this table and SPEC-018 document it as `false` (SPEC-019 §11 Open questions / audit hooks already tracks this as a v0.1.5 LOCKED drift); this note does not assert a value for it. (2) RESOLVED (runbook item 20): the coordinator's streaming SSE terminal-error writer now honors the `end.Retryable` override the non-streaming writer does — the synthesized-SSE-error site passes `end.Retryable` through `writeSSEErrorWithRetryable`, so both transports agree. (3) A legacy cross-version response body that predates this field entirely (and so omits `retryable`) falls back to the receiving service's own code-based classification rather than a value read from that body; current-to-current traffic is unaffected, since every current writer on both services stamps the field. (4) A provider-originated error body forwarded verbatim (e.g. the coordinator's null-usage provider-error passthrough, `internal/buyer/server.go:2429`; the gateway's receipt-eligible provider-error passthrough, `phase5-gateway/internal/router/chat_proxy.go`'s `passThroughReceiptEligibleProviderError`) is not rewritten to inject `retryable` — the provider, not the coordinator or gateway, authored that envelope, and mutating a verbatim pass-through body would itself be a fidelity bug. Such a body may omit `retryable` entirely; this is a documented exception to the MUST above, not a violation of it. (5) The completeness tests (`TestCoordinatorErrorCodeCompleteness`, `TestGatewayErrorCodeCompleteness`) guard only the current hand-curated code inventory in each test file — they do not parse source at test time and so cannot catch a brand-new write site with a brand-new code by construction; a genuine future-proof guard (AST-based or a compile-time registration requirement) is a separate, unimplemented follow-up.

### 5.3 `GET /v1/models`

`GET /v1/models` returns public model availability.

Authentication:

- SHOULD allow unauthenticated reads for docs and demo discovery.
- MUST NOT reveal sensitive provider information when unauthenticated.
- MAY include rate-limit headers only when a bearer token or demo token is present.

Request body:

- None.

Response status:

- `200` when gateway can reach a coordinator or serve a fresh enough public status snapshot.
- `503` when all coordinator backends are down and no acceptable snapshot exists.

Response shape:

```json
{
  "object": "list",
  "tier1_disclosure": {
    "version": "v0.8",
    "plaintext_to_provider": true,
    "model_identity": "provider_reported",
    "hardware_attestation": "none",
    "tier2_milestone": "future",
    "model_verification_limit": "v0.4 settlement receipts verify the provider-reported request-start model hash against the route-time catalog snapshot. They do not detect a provider falsifying its own loaded-model hash measurement.",
    "verified_model_settlement": {
      "included_paid_entrypoints": ["POST /v1/chat/completions"],
      "excluded_paid_entrypoints": [
        "legacy direct-tunnel buyer paths at coordinator.streamvc.live, m4.streamvc.live, and m1.streamvc.live unless separately disabled or migrated behind the gateway paid ledger"
      ],
      "model_identity": "/v1/models distinguishes provider-reported model IDs from catalog-known hash status and settlement-enforced receipt matching. Settlement enforcement applies only to included paid entrypoints in enforce mode after a receipt matches the route-time catalog snapshot; excluded legacy/direct paths are named separately.",
      "model_identity_caveat": "Verified model settlement means the provider-reported request-start model hash matched the route-time catalog snapshot and settlement receipt. It does not provide hardware attestation, runtime binary attestation, private prompts, malicious-output prevention, or detection of a provider falsifying its own loaded-model hash measurement.",
      "observe_mode": "Observe mode may record receipt and model-hash diagnostics, but it cannot claim verified model integrity and it does not change buyer debit or provider payout.",
      "enforce_mode": "Enforce mode may settle only covered paid entrypoints listed in this disclosure whose settlement-capable receipt reaches verified finality; mixed pools are not described as fully verified.",
      "pending_reservation": "Pending means quota or balance can remain reserved while receipt verification is incomplete. Non-verified terminal outcomes release or refund that reservation.",
      "outcomes": {
        "pending": "pending: receipt verification is still incomplete and the reservation is not final usage.",
        "verified": "verified: a settlement-capable receipt matched the route-time catalog snapshot and can finalize buyer debit and provider settlement.",
        "quarantined": "quarantined: not charged because model-integrity or receipt verification failed; this is not labeled as buyer fault.",
        "zero_settled": "zero_settled: not charged because no billable verified work was produced; this is not labeled as buyer fault."
      },
      "partial_charge": "Buyer cancel, gateway timeout, provider error, or upstream disconnect can create a partial charge only when a settlement-capable receipt binds the delivered output prefix and partial usage.",
      "streaming_failover": "Transparent streaming failover bills only delivered, verified output across attempts and does not double-charge overlapping output; verified here means receipt-bound under the provider-reported-hash caveat above.",
      "buyer_receipt_status": "Buyer receipt and status surfaces expose pending, verified, quarantined, and zero_settled labels without raw prompts or raw outputs."
    },
    "sticky_affinity": {
      "enabled": false,
      "ttl_seconds": 0,
      "description": "Sticky affinity is disabled; related requests are not preferentially routed to the same provider."
    }
  },
  "data": [
    {
      "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "object": "model",
      "created": 1710000000,
      "owned_by": "macprovider",
      "provider_count": 3,
      "total_slots": 5,
      "max_context_tokens": 8192,
      "degraded": false
    }
  ]
}
```

The gateway MUST aggregate providers by case-insensitive model identifier.

The gateway MUST preserve the canonical model ID spelling returned by the coordinator.

The `id` field returned by `/v1/models` reflects the model identifier as advertised by the serving provider binary. `/v1/models` may also expose catalog-known hash status and settlement-enforced receipt matching for covered enforce-mode traffic. Buyers SHOULD treat `id` as provider-reported and SHOULD NOT treat catalog or settlement fields as hardware attestation, runtime binary attestation, malicious-output prevention, private inference, or detection of a provider falsifying its own loaded-model hash measurement.

The gateway MUST tolerate `/` and `\/` escaped model IDs.

The gateway MUST NOT return individual provider rows.

The gateway MUST NOT forward or synthesize:

- `provider_id`
- `assigned_id`
- hostname
- IP address
- endpoint URL
- geographic location
- RAM GB
- CPU details
- operator identity

#### 5.3.1 Tier 1 disclosure surface: `/v1/models` extension

The `/v1/models` response MUST include a top-level field:

```json
"tier1_disclosure": {
  "version": "v0.8",
  "plaintext_to_provider": true,
  "model_identity": "provider_reported",
  "hardware_attestation": "none",
  "tier2_milestone": "future",
  "model_verification_limit": "v0.4 settlement receipts verify the provider-reported request-start model hash against the route-time catalog snapshot. They do not detect a provider falsifying its own loaded-model hash measurement.",
  "verified_model_settlement": {
    "included_paid_entrypoints": ["POST /v1/chat/completions"],
    "excluded_paid_entrypoints": [
      "legacy direct-tunnel buyer paths at coordinator.streamvc.live, m4.streamvc.live, and m1.streamvc.live unless separately disabled or migrated behind the gateway paid ledger"
    ],
    "model_identity": "/v1/models distinguishes provider-reported model IDs from catalog-known hash status and settlement-enforced receipt matching. Settlement enforcement applies only to included paid entrypoints in enforce mode after a receipt matches the route-time catalog snapshot; excluded legacy/direct paths are named separately.",
    "model_identity_caveat": "Verified model settlement means the provider-reported request-start model hash matched the route-time catalog snapshot and settlement receipt. It does not provide hardware attestation, runtime binary attestation, private prompts, malicious-output prevention, or detection of a provider falsifying its own loaded-model hash measurement.",
    "observe_mode": "Observe mode may record receipt and model-hash diagnostics, but it cannot claim verified model integrity and it does not change buyer debit or provider payout.",
    "enforce_mode": "Enforce mode may settle only covered paid entrypoints listed in this disclosure whose settlement-capable receipt reaches verified finality; mixed pools are not described as fully verified.",
    "pending_reservation": "Pending means quota or balance can remain reserved while receipt verification is incomplete. Non-verified terminal outcomes release or refund that reservation.",
    "outcomes": {
      "pending": "pending: receipt verification is still incomplete and the reservation is not final usage.",
      "verified": "verified: a settlement-capable receipt matched the route-time catalog snapshot and can finalize buyer debit and provider settlement.",
      "quarantined": "quarantined: not charged because model-integrity or receipt verification failed; this is not labeled as buyer fault.",
      "zero_settled": "zero_settled: not charged because no billable verified work was produced; this is not labeled as buyer fault."
    },
    "partial_charge": "Buyer cancel, gateway timeout, provider error, or upstream disconnect can create a partial charge only when a settlement-capable receipt binds the delivered output prefix and partial usage.",
    "streaming_failover": "Transparent streaming failover bills only delivered, verified output across attempts and does not double-charge overlapping output; verified here means receipt-bound under the provider-reported-hash caveat above.",
    "buyer_receipt_status": "Buyer receipt and status surfaces expose pending, verified, quarantined, and zero_settled labels without raw prompts or raw outputs."
  },
  "sticky_affinity": {
    "enabled": false,
    "ttl_seconds": 0,
    "description": "Sticky affinity is disabled; related requests are not preferentially routed to the same provider."
  }
}
```

Buyers consuming this field SHOULD display its content in human-readable form before sending sensitive prompts.

Gateway implementations MUST set this field automatically.

Operator override is forbidden; there MUST be no config opt-out.

The `sticky_affinity` sub-object MUST be present. When `routing.sticky_enabled: false`, implementations MUST return `enabled: false`, `ttl_seconds: 0`, and a description that states no sticky routing is active. When `routing.sticky_enabled: true`, implementations MUST return `enabled: true`, `ttl_seconds` equal to the coordinator's effective SPEC-004 v0.2 `routing.sticky_ttl_s`, and this plain-language privacy tradeoff in substantively equivalent form: "Related requests with the same conversation tag are preferentially routed to one provider for up to this many seconds, so that provider can observe and correlate more of your traffic than under default routing."

**Disclosure-completeness item (v0.9.8, SPEC-024 v0.2 §13 — MUST close).** The
shipped disclosure above describes preferential routing and correlation, but
does **not** yet disclose two consequences of the SPEC-024 prefix-cache
carve-out: (i) the provider **receives** the derived opaque conversation
identifier and **retains** it in a provider-local KV cache under its own TTL
that `DELETE /v1/sticky` does not clear; and (ii) because that identifier is
forwarded on cache misses and re-routes, it MAY reach **more than one**
provider over a conversation's life (cross-provider linkability). Extending the
buyer-facing disclosure (this field, `/v1/models tier1_disclosure`, and
`disclosure.go`) to cover (i)–(ii) is a tracked completeness follow-up; it is
recorded here as a known gap, not silently omitted.

### 5.4 `POST /v1/chat/completions`

`POST /v1/chat/completions` is the primary OpenAI-compatible inference endpoint.

Authentication:

- Bearer token required for normal API traffic.
- Demo traffic MAY omit bearer token only when it includes a valid `X-Demo-Token` from the front door and passes demo quota checks.

Required request fields:

- `model`
- `messages`

Supported request fields:

- `model`
- `messages`
- `max_tokens`
- `temperature`
- `top_p`
- `n`
- `stream`
- `stream_options`
- `stop`
- `presence_penalty`
- `frequency_penalty`
- `seed`
- `user`
- `response_format`
- `logprobs`
- `tools` syntactically only
- `tool_choice` syntactically only

`n` is accepted for OpenAI SDK compatibility and MUST be 1 in v1. Values greater than 1 MUST be rejected with HTTP 400, `type: "invalid_request_error"`, and `code: "n_must_be_1"`.

`stream_options` MUST be accepted and forwarded to the provider. When `stream_options.include_usage = true`, the final SSE chunk MUST include a `usage` field so OpenAI SDK streaming token accounting works. `stream_options.include_usage = false` MUST be tolerated and MAY be ignored if the provider always emits usage.

`user` is accepted as opaque diagnostics, stored in usage events, and MUST NOT be exposed in buyer-visible responses.

`logprobs` is accepted syntactically and forwarded to the provider as part of the request body. SPEC-001 v1.2.2 § 6.4 specifies unknown-field tolerance, so the provider MAY ignore unknown OpenAI-compatible fields including `logprobs`. Behavior is model-dependent; the gateway MUST NOT enforce `logprobs`-specific semantics.

For `system` and `user` messages, `content` MAY be a non-empty JSON string
or a text-only structured content array such as
`[{"type":"text","text":"hello"}]`. The buyer boundary MUST normalize
text-only arrays into a single string before provider dispatch. Multimodal or
otherwise non-text content parts MUST be rejected with HTTP 400,
`type: "invalid_request_error"`, and `code: "unsupported_content_shape"`.

Gateway request caps:

- `max_tokens` MUST be capped at `limits.max_tokens_per_request`, default 4096.
- Demo `max_tokens` SHOULD be further capped by `demo.max_tokens_per_request`, default 512.
- Requests exceeding configured caps MUST receive `400` or be clamped only if the clamping behavior is documented. v1 SHOULD reject rather than silently clamp authenticated API requests.

The gateway MUST match model IDs ASCII case-insensitively when interpreting coordinator availability.

### 5.4a `POST /v1/messages` experimental facade

`POST /v1/messages` is a default-off Anthropic Messages compatibility facade.
It MUST be mounted only when `features.anthropic_messages_enabled` is true. It
MUST NOT introduce a parallel provider proxy, quota ledger, reservation path,
settlement path, sticky-routing path, cancellation path, or request-id path.
The gateway MUST translate supported requests into the existing
`POST /v1/chat/completions` handler and translate the resulting OpenAI-shaped
response back to Anthropic Message JSON or Anthropic SSE events.

Authentication:

- Bearer token MUST be accepted.
- `X-Api-Key` MUST be accepted as an alias for bearer authentication when
  `Authorization` is absent.
- Browser demo tokens are not part of the `/v1/messages` facade.

Supported Anthropic request fields:

- `model`
- `system` as a string or text-only content blocks
- `messages[]` with user/assistant text blocks
- assistant `tool_use`
- user `tool_result`
- `tools[].input_schema`
- `max_tokens`
- `stream`
- `tool_choice`
- `stop_sequences`
- `temperature`
- `top_p`

Unsupported Anthropic-only features MUST be rejected before reservation or
provider dispatch with an Anthropic-shaped error envelope that still carries
the gateway extension fields `code` and `retryable`. This includes image,
document, or file content blocks; server tools; malformed or unsupported
`tool_result.content[]` blocks; `Anthropic-Beta` headers or body beta fields;
`thinking`; `top_k`; and unknown content-block types.

For non-streaming responses, OpenAI chat choices MUST be converted to
Anthropic `message` envelopes with text and `tool_use` content blocks. For
streaming responses, OpenAI SSE chunks MUST be converted to Anthropic
`message_start`, `content_block_*`, `message_delta`, and `message_stop` events.
Tool-call argument deltas MUST be emitted as `input_json_delta` fragments.
When a request supplied `stop_sequences` and the upstream response reports
`finish_reason: "stop"` without a provider `stop_sequence`, the facade SHOULD
infer Anthropic `stop_reason: "stop_sequence"` only from a terminal suffix match
against returned visible text and SHOULD omit that matched suffix from emitted
text. If the upstream provider already stripped the sequence, the matched
sequence is not recoverable from the OpenAI-shaped response and the facade MUST
fall back to `stop_reason: "end_turn"` with `stop_sequence: null`.

The facade's settlement and retry semantics are exactly the underlying chat
completion semantics. Successful translated requests MUST reserve quota,
settle usage, honor sticky conversation headers, propagate cancellation, carry
gateway request IDs, and replay id-less duplicate requests through the same
mechanisms as `POST /v1/chat/completions`. `GET /v1/usage` and `/v1/models`
settlement disclosures MUST include `POST /v1/messages` only when the feature
flag is enabled.

The facade does not certify full Claude Code, Claude Agent SDK, or Anthropic SDK
product compatibility. Compatibility claims MUST be limited to the supported
wire subset above until a live end-to-end smoke explicitly proves a wider
client workflow.

The gateway MUST strip these inbound buyer request headers before forwarding to the coordinator:

- `X-MacProvider-Provider`
- `X-MacProvider-Session`
- any header starting with `X-MacProvider-` that is not on a documented allowlist

The documented buyer request allowlist is:

- `X-MacProvider-Conversation`, consumed only by the gateway for sticky conversation-key derivation.
- `X-MacProvider-Retry`, if SPEC-004 retry exposure is enabled by the operator.

Stripping MUST occur **before authentication** so a malicious buyer cannot influence provider selection or any pre-forwarding decision (auth, rate-limit, routing) by header injection. The gateway MUST emit an audit event at WARN level when a buyer-supplied `X-MacProvider-Internal-Conv` is observed and stripped; attempted injection is a high-signal security event. `X-MacProvider-Conversation` MUST NOT be forwarded to the coordinator as a buyer header; it is gateway input only.

The gateway MAY emit an audit event when an inbound request carried these headers.

The gateway MUST forward the request to the selected coordinator backend without adding buyer-visible provider preference headers. When `routing.sticky_enabled: true` and the request includes a valid `X-MacProvider-Conversation` value, the gateway MUST derive `routing_internal.conversation_key` per § 1.3 and transport it on the gateway-to-coordinator hop using `X-MacProvider-Internal-Conv: conv:<opaque-id>`.

`X-MacProvider-Internal-Conv` is an internal deployment header, not a buyer API header. The coordinator's externally reachable nginx vhost, proxy layer, or equivalent edge boundary MUST strip `X-MacProvider-Internal-Conv` and any other `X-MacProvider-Internal-*` header from every path that could be reached outside the gateway. The coordinator MUST treat `X-MacProvider-Internal-Conv` as valid only on authenticated or network-restricted gateway-originated traffic; it MUST NEVER accept this header from direct buyer traffic. A deployment where buyer-reachable requests can supply or preserve this header is non-compliant with SPEC-006 v0.8 and SPEC-004 v0.2.

The gateway MUST NOT expose coordinator route headers to the buyer.

The gateway MUST strip these upstream coordinator response headers before returning to the buyer:

- `X-MacProvider-Provider`
- `X-MacProvider-Route`
- any response header starting with `X-MacProvider-` that is not on a documented response-pass-through allowlist

The documented response-pass-through allowlist is:

- `X-MacProvider-Receipt`, emitted by SPEC-015 v0.1.3 non-streaming
  receipt-capable providers and forwarded unchanged by the gateway.
- `X-MacProvider-Streaming-Mode`, the SPEC-018 AC-45 buyer-visible
  streaming-mode diagnostic set by the coordinator on streaming `200`
  responses. The gateway MUST forward it only when its value is one of
  the three canonical AC-45 values — `incremental`, `buffered_kill_switch`,
  or `buffered_provider_downgrade` — and MUST drop any other value rather
  than forward it verbatim (defense-in-depth: the value is coordinator-set,
  but the allowlist prevents a compromised or misconfigured upstream from
  smuggling arbitrary header content past the `X-MacProvider-*` strip). The
  header is observation-only (SPEC-018 §10d.4); buyers MUST NOT use it for
  negotiation.

The gateway MUST return 503 when no provider slot is available after
any allowed bounded pre-dispatch slot queue expires.

The gateway MUST NOT queue buyer requests indefinitely waiting for
future capacity. Pinned provider or session requests MUST NOT enter the
bounded slot queue and MUST return 503 when the pinned target has no
immediately available slot.

Non-streaming success response:

- MUST preserve OpenAI-compatible chat completion shape from the coordinator/provider.
- MUST include rate-limit headers.
- MUST include `X-Request-ID`.

Streaming success response:

- MUST preserve OpenAI-compatible SSE chunks from coordinator/provider.
- MUST frame each JSON chunk as `data: {json}\n\n` per OpenAI streaming behavior.
- MUST pass through `data: [DONE]`.
- MUST flush chunks promptly.
- MUST cancel upstream request within 500 ms after buyer disconnect.
- MUST append a usage event when usage can be measured or estimated.

#### 5.4.1 Sticky affinity buyer controls and internal transport

Sticky affinity is an operator-enabled extension and MUST default to disabled through `routing.sticky_enabled: false`.

Buyer opt-in source:

- Buyers MAY send `X-MacProvider-Conversation: <opaque-tag>` on `POST /v1/chat/completions`.
- The tag is buyer-chosen and opaque. It is not an account identifier, provider identifier, session ID, or security credential.
- The gateway MUST trim leading/trailing whitespace, reject empty tags, reject tags longer than 128 bytes, and reject tags containing characters outside `[A-Za-z0-9._:-]` with HTTP 400, `type: "invalid_request_error"`, and `code: "invalid_conversation_tag"`. **(v0.9.8:)** trimming is Go `strings.TrimSpace` **Unicode**-whitespace semantics (matching § 1.3 step 3 and shipped `chat_proxy.go`), not ASCII-only — a reimplementation that trims only ASCII whitespace diverges on Unicode-whitespace-wrapped tags.
- The gateway MUST silently ignore the tag when `routing.sticky_enabled: false` (200 OK, no error); it MUST NOT derive or forward a sticky key in the default config. Silent ignore (rather than rejection) lets portable buyer SDKs always include the header without breaking against operators running the default-off posture.
- The gateway MUST derive the internal `conv:` value with the HMAC-SHA256 algorithm in § 1.3. Gateway-managed deterministic request-shape hashing and gateway-managed sticky cookies are intentionally rejected for v0.8 because they are less explicit, harder to audit, and broaden the auth/session surface.

Gateway-to-coordinator transport:

- The gateway MUST send the derived value to the coordinator only as `X-MacProvider-Internal-Conv: conv:<opaque-id>`.
- The gateway MUST NOT forward raw `X-MacProvider-Conversation`.
- The gateway MUST NOT accept a buyer-supplied `X-MacProvider-Internal-Conv`; inbound buyer copies of that header MUST be stripped before auth/routing and SHOULD generate an audit event.
- The coordinator boundary MUST strip `X-MacProvider-Internal-*` headers on buyer-reachable paths and MUST reject or ignore values outside the `conv:` namespace for sticky purposes, matching SPEC-004 v0.2.

Buyer-triggered deletion:

- `DELETE /v1/sticky` is authenticated with the same bearer-token account identity as normal API traffic.
- The operation is account-scoped and idempotent. It MUST purge all sticky entries attributable to the caller's `account_id` and MUST NOT affect other accounts.
- Success MUST return HTTP 200 and:

```json
{
  "purged": true,
  "entries": 0
}
```

`entries` is the number of account-scoped sticky entries deleted. A repeated request after prior deletion MUST still return `purged: true` and MAY return `entries: 0`.

### 5.5 `GET /v1/usage`

`GET /v1/usage` returns account usage and quota state.

Authentication:

- Bearer token required.

Request query parameters:

- `window` MAY be `today`, `7d`, or `30d`.
- Missing `window` defaults to `today`.

Response shape:

```json
{
  "account_id": "acct_public_...",
  "window": "today",
  "quota": {
    "daily_token_limit": 100000,
    "daily_tokens_used": 12000,
    "daily_tokens_reserved": 0,
    "daily_tokens_remaining": 88000,
    "resets_at": "2026-05-29T00:00:00Z",
    "concurrency_limit": 2,
    "concurrency_in_use": 0
  },
  "keys": [
    {
      "key_id": "key_...",
      "label": "default",
      "prefix": "mp_abcd",
      "created_at": "2026-05-28T00:00:00Z",
      "last_used_at": "2026-05-28T02:00:00Z",
      "status": "active"
    }
  ],
  "models": [
    {
      "model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "requests": 4,
      "prompt_tokens": 1000,
      "completion_tokens": 600,
      "total_tokens": 1600
    }
  ],
  "rating": {
    "latest": 3,
    "updated_at": "2026-05-28T02:10:00Z"
  },
  "settlement_disclosure": {
    "included_paid_entrypoints": ["POST /v1/chat/completions"],
    "excluded_paid_entrypoints": [
      "legacy direct-tunnel buyer paths at coordinator.streamvc.live, m4.streamvc.live, and m1.streamvc.live unless separately disabled or migrated behind the gateway paid ledger"
    ],
    "model_identity": "/v1/models distinguishes provider-reported model IDs from catalog-known hash status and settlement-enforced receipt matching. Settlement enforcement applies only to included paid entrypoints in enforce mode after a receipt matches the route-time catalog snapshot; excluded legacy/direct paths are named separately.",
    "model_identity_caveat": "Verified model settlement means the provider-reported request-start model hash matched the route-time catalog snapshot and settlement receipt. It does not provide hardware attestation, runtime binary attestation, private prompts, malicious-output prevention, or detection of a provider falsifying its own loaded-model hash measurement.",
    "observe_mode": "Observe mode may record receipt and model-hash diagnostics, but it cannot claim verified model integrity and it does not change buyer debit or provider payout.",
    "enforce_mode": "Enforce mode may settle only covered paid entrypoints listed in this disclosure whose settlement-capable receipt reaches verified finality; mixed pools are not described as fully verified.",
    "pending_reservation": "Pending means quota or balance can remain reserved while receipt verification is incomplete. Non-verified terminal outcomes release or refund that reservation.",
    "outcomes": {
      "pending": "pending: receipt verification is still incomplete and the reservation is not final usage.",
      "verified": "verified: a settlement-capable receipt matched the route-time catalog snapshot and can finalize buyer debit and provider settlement.",
      "quarantined": "quarantined: not charged because model-integrity or receipt verification failed; this is not labeled as buyer fault.",
      "zero_settled": "zero_settled: not charged because no billable verified work was produced; this is not labeled as buyer fault."
    },
    "partial_charge": "Buyer cancel, gateway timeout, provider error, or upstream disconnect can create a partial charge only when a settlement-capable receipt binds the delivered output prefix and partial usage.",
    "streaming_failover": "Transparent streaming failover bills only delivered, verified output across attempts and does not double-charge overlapping output; verified here means receipt-bound under the provider-reported-hash caveat above.",
    "buyer_receipt_status": "Buyer receipt and status surfaces expose pending, verified, quarantined, and zero_settled labels without raw prompts or raw outputs."
  }
}
```

The response MUST NOT include the full API key.

The response MAY include a key prefix for identification.

The endpoint MUST provide enough data for the `/account` page to show usage, remaining quota, key status, and rating widget state.

The response MUST include `settlement_disclosure` when SPEC-022 settlement
labels or reservations are exposed. That disclosure MUST explain pending
verification reservations, non-verified reservation release/refund behavior,
and the provider-reported-hash caveat without exposing raw prompts or raw
outputs.

### 5.6 `GET /v1/status`

`GET /v1/status` returns buyer-safe network status.

Authentication:

- SHOULD be public.

Response shape:

```json
{
  "status": "up",
  "degraded": false,
  "coordinator": {
    "status": "up",
    "checked_at": "2026-05-28T00:00:00Z"
  },
  "pool": {
    "total_providers": 4,
    "ready": 3,
    "draining": 0,
    "unavailable": 1
  },
  "models": [
    {
      "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "provider_count": 2,
      "ready_provider_count": 2,
      "total_slots": 3,
      "slots_free": 2,
      "max_context_tokens": 8192,
      "degraded": false,
      "available": true,
      "availability": "available"
    }
  ]
}
```

Allowed top-level `status` values:

- `up`
- `degraded`
- `idle`
- `down`

`down` is reserved for coordinator/control-plane unreachability: `/poolz` is unreachable, returns a non-2xx response, or cannot be decoded. A reachable coordinator with zero ready providers MUST NOT produce `down`.

`idle` means the coordinator is reachable but no provider is currently ready for buyer routing. This is a normal sleep-tolerant capacity state and MUST be rendered by front doors as non-alarming "no providers awake right now" copy.

`degraded` means the coordinator is reachable and at least one provider is ready, but ready providers are below the configured threshold.

The network-wide degraded flag MUST be true only for the `degraded` status. It MUST be false for `up`, `idle`, and `down`.

Per-model `degraded` is defined normatively in SPEC-002 v1.1.4 § 4, FR-B1. The gateway MUST compute per-model degraded values from `/poolz` aggregation using SPEC-002's rules.

Per-model rows MUST include:

- `ready_provider_count`: ready providers currently serving that model.
- `available`: true only when at least one ready provider has an immediately routable free slot.
- `availability`: one of `available`, `no_awake_provider`, or `no_free_slots`.

A model with `availability: "no_awake_provider"` is known to the coordinator but currently has no awake ready provider. A model with `availability: "no_free_slots"` has at least one ready provider but no immediate free slot. Front doors MUST use these fields rather than deriving availability from top-level status alone.

The endpoint MUST NOT expose:

- individual provider hostnames.
- individual provider IDs.
- provider RAM/CPU specs.
- operator identity.
- endpoint URLs.

Gateway-internal coordinator status bridge:

- The gateway MUST source pool status for `/v1/status` by consuming the coordinator's internal `/poolz` endpoint at `http://127.0.0.1:{coordinator_provider_port}/poolz`, typically `:8444`.
- `/poolz` requires the coordinator operator bearer key when `auth.operator_key` is configured.
- This is an internal contract; the gateway MUST NOT proxy raw `/poolz` content to buyers.
- The gateway MUST redact `provider_id`, `assigned_id`, `hostname`, endpoint URLs, per-provider RAM/CPU specs, and operator identity metadata.
- The gateway MAY aggregate counts for ready, degraded, draining, unavailable providers, per-model slot totals, degraded-state booleans, and per-model availability fields.
- Cache TTL for `/poolz` polling is 10 seconds.
- The status cache MAY serve stale data for up to 10 seconds during coordinator restart after coordinator returns.
- The gateway MUST flush cached `/poolz` data when `/poolz` is not reachable or returns an HTTP error.
- SPEC-002 v1.1.4 defines the `/poolz` summary fields consumed by the gateway for these aggregation rules.

### 5.7 `POST /v1/feedback`

`POST /v1/feedback` records authenticated feedback.

Authentication:

- Bearer token required for `request`, `session`, and `account` feedback.
- Demo token required in `X-Demo-Token` for `playground` feedback.
- The gateway SHOULD check bearer auth first, then demo token auth.
- A request with neither valid bearer token nor valid demo token MUST return 401.

Request shape:

```json
{
  "rating": 4,
  "comment": "optional free text",
  "request_id": "optional prior request id",
  "scope": "request"
}
```

Validation:

- `rating` MUST be an integer from 1 through 4.
- `comment` MUST be optional.
- `comment` MUST be length-limited by config, default 2000 bytes.
- `request_id` MUST be optional.
- `request_id` MUST be validated as a bounded safe identifier.
- `scope` MUST be optional and, when present, one of `request`, `session`, `account`, or `playground`.
- `scope` defaults to `request` when `request_id` is present.
- `scope` defaults to `account` when `request_id` is absent.
- `request`, `session`, and `account` feedback MUST require a valid `mp_*` bearer token.
- `playground` feedback MUST require a valid demo token per Section 6.8.

The `comment` field MUST be treated as untrusted input.

Storage writes preserve raw UTF-8 bytes.

Rendering surfaces, including dashboard, account page, and admin views, MUST escape HTML entities at output time.

The gateway's JSON responses MUST NOT include pre-rendered HTML for feedback content.

Comments MAY contain newlines; clients rendering as text MUST preserve them.

Idempotency:

- If `request_id` is present, repeated submissions from the same account with the same `request_id` MUST be idempotent.
- Idempotency MUST NOT require updating a hot-path usage event row.

Response shape:

```json
{
  "ok": true,
  "feedback_id": "fb_...",
  "received_at": "2026-05-28T00:00:00Z"
}
```

Storage:

- Feedback MUST be append-only.
- Duplicate idempotent submissions MAY return the original `feedback_id`.
- Playground feedback events MUST store the demo token's IP hash and expire from queryable feedback summaries after 30 days.

### 5.8 OAuth callbacks

`GET /auth/github/callback` handles GitHub OAuth callback.

`GET /auth/email/callback` MAY exist only if email magic link ships in v1.

Callbacks MUST:

- validate `state`.
- generate `state` values with at least 128 bits from a CSPRNG.
- bind `state` to the user's browser session.
- reject callbacks whose `redirect_uri` does not exactly match an allowlisted value.
- exchange provider code server-side.
- create account on first successful identity.
- enforce per-IP signup issuance limit.
- issue one default active API key on signup.
- show the full key once.
- never log the full key.
- never re-display the full key.

The GitHub OAuth app MUST be configured with a strict callback URL allowlist containing only:

```text
https://api.streamvc.live/auth/github/callback
```

Local development MAY use `http://localhost:{port}/auth/github/callback` as a separate OAuth app with its own callback registration.

The callback allowlist MUST be defined in `gateway.yaml` under `auth.oauth.callback_allowlist` and validated at gateway startup.

An empty callback allowlist MUST cause startup failure.

### 5.9 `/account`

The account UI path is part of the public surface.

The implementation MAY serve it from the gateway or front door, but the contract MUST support:

- current account identity.
- default active key shown only at creation.
- key list with prefixes and status.
- key regeneration.
- key revocation.
- usage summary.
- quota remaining.
- rating widget.
- capacity/signup closed banner.

If the front door owns rendering, the gateway MUST provide API endpoints sufficient for these functions.

---

## 6. Identity and auth

### 6.1 GitHub OAuth

GitHub OAuth is the primary identity method.

The gateway MUST use web-app OAuth credentials, not device-flow credentials.

The gateway MUST create an account on first successful callback.

The gateway MUST bind exactly one account to each GitHub identity.

The account identity key MUST be stable across username changes.

The account record SHOULD store a provider-specific immutable ID, not only username.

The gateway MUST request only the `read:user` GitHub OAuth scope.

The `user:email` scope MAY be requested if email magic link is deferred and verified email is needed from GitHub.

Scopes for repository, organization, gist, or write access MUST NOT be requested.

The OAuth app's registered scope list MUST match this minimum scope set.

The GitHub OAuth app MUST be configured with a strict callback URL allowlist containing only `https://api.streamvc.live/auth/github/callback` for production.

The gateway MUST reject callbacks whose `redirect_uri` does not exactly match an allowlisted value.

Local development MUST use a separate OAuth app when using `http://localhost:{port}/auth/github/callback`.

The allowlist MUST be configured at `auth.oauth.callback_allowlist`, and an empty list MUST fail gateway startup.

### 6.2 Email magic link

Email magic link is secondary.

Email magic link MUST ship only if a practical free tier is available with low operator-onboarding cost.

Acceptable candidate providers include Resend, SendGrid, and Postmark.

If no practical free tier is available for v1, the spec-compliant behavior is:

- ship GitHub OAuth only.
- omit `/auth/email/callback`.
- document email magic link as deferred to v0.2.

### 6.3 Account uniqueness

The gateway MUST enforce one account per identity.

Multiple identities MAY be linked to one account in a later version.

v1 MAY keep GitHub and email accounts separate if identity linking is deferred.

### 6.4 API key shape

API keys MUST start with:

```text
mp_
```

The random portion of every API key MUST contain at least 256 bits of entropy drawn from a cryptographically secure pseudo-random number generator before base64url encoding.

The encoded form MUST preserve at least 256 bits of effective entropy and MUST NOT truncate the random portion.

The fixed `mp_` prefix is in addition to the random portion.

The full key MUST be shown once at issuance.

The full key MUST NOT be logged.

The full key MUST NOT be stored.

The full key MUST NOT be redisplayed.

### 6.5 Key hashing

The server MUST store only a SHA-256 hash or HMAC of the secret.

HMAC is preferred if an operator-managed secret is available.

The hash lookup column MUST be indexed.

The key prefix MAY be stored for UI identification.

### 6.6 Key lifecycle

On signup, the gateway MUST issue one active key by default.

The account MAY have multiple active keys.

Regeneration MUST create a new key.

Key regeneration MUST NOT affect usage history, quota state, or feedback history.

Revocation MUST make the old key unusable.

Revocation MUST take effect within 60 seconds across all gateway components.

Storage-layer revocation MUST be observed by validation immediately on the next request.

Any caches MUST invalidate within 60 seconds.

Multi-instance deployments after the D1 storage migration MUST honor the same bound across all instances.

Revocation MUST NOT reveal the full key.

Key issuance records MUST be immutable.

### 6.7 Auth failure semantics

Missing bearer token on an authenticated-only endpoint MUST return 401.

Invalid bearer token MUST return 401.

Revoked key MUST return 403.

Blocked account MUST return 403.

Disabled signup does not disable existing keys unless a kill switch says so.

### 6.8 Demo token semantics

`X-Demo-Token` identifies front-door demo sessions.

The demo token MUST NOT be treated as an account key.

Demo tokens MUST use HMAC-SHA256 signatures with an operator secret stored at `auth.demo.signing_secret` in `gateway.yaml`.

Static shared demo secrets are forbidden.

Token format:

```text
{base64url(payload)}.{base64url(hmac)}
```

Payload JSON MUST include:

```json
{"v":1,"ip":"1.2.3.4","iat":1710000000,"exp":1710086400}
```

For IPv6 clients, the `ip` value MAY be the /64 prefix instead of the full address.

The HMAC MUST be computed over the payload bytes using `auth.demo.signing_secret`.

The gateway MUST issue tokens from:

```text
POST /auth/demo-session
```

`POST /auth/demo-session` MUST be rate-limited per IP, default 10 requests per IP per hour.

The token maximum TTL is 24 hours.

Validation MUST check signature, expiry, and client IP or IPv6 /64 prefix match.

The operator MAY rotate `auth.demo.signing_secret`; existing demo tokens invalidate immediately.

The gateway MUST combine demo token identity with client IP for quota enforcement.

---

## 7. Quotas and rate limits

### 7.1 Defaults

Default quotas:

- Account daily total tokens: 100,000.
- Demo daily total tokens per IP: 1,000.
- Per-account concurrent requests: 4.
- Per-account request-start rate: 30 requests per second per gateway instance.
- Per-IP signup issuance per day: 3 accounts.
- Authenticated max tokens per request: 4,096.
- Demo max tokens per request: 512 unless configured otherwise.

All defaults MUST be configurable in `gateway.yaml`.

### 7.2 Token accounting

The gateway MUST record prompt tokens, completion tokens, and total tokens when available.

If the provider response lacks usage, the gateway MUST estimate usage deterministically.

The estimation method MUST be documented in implementation notes.

Quota decisions MAY use preflight estimates before forwarding.

Final usage events MUST record whether token counts were provider-reported or gateway-estimated.

Coordinator-side slot queue wait is routing latency, not token usage or provider billable work. If a coordinator waits for an otherwise eligible provider's `slots_free` to recover before dispatch, the wait MAY be recorded for latency diagnostics, but it MUST NOT create buyer debit, provider payout, prompt tokens, completion tokens, or non-zero usage settlement by itself. Expired queued requests that return 503 remain failed requests under the refund policy below.

Quota enforcement MUST use a reservation ledger to prevent concurrent over-spend.

For each admitted request, the gateway:

1. Reads the account's current daily reservation total via a transactional `SELECT ... FOR UPDATE` or storage-layer equivalent atomic primitive.
2. If `current_reserved + max_tokens_for_request <= daily_quota`, inserts a reservation row keyed by `(account_id, request_id)` and commits.
3. If the request completes, settles the reservation to actual `prompt_tokens + completion_tokens` and writes an immutable usage event.
4. If the request fails, refunds or settles the reservation according to the streaming and upstream-error policy below.

For SQLite v1, the storage-layer equivalent of `SELECT ... FOR UPDATE` MUST be `BEGIN IMMEDIATE` transactions around the reservation check and insert.

Minor overshoot up to `max_tokens_per_request` is acceptable only in the event of system failure between reservation and settlement.

Failed reservations MUST expire and be reclaimed by a reaper job within 24 hours.

For streaming requests (`stream: true`), the gateway MUST reserve `max_tokens` or the configured per-request cap, whichever is smaller, before forwarding.

On SSE completion after a provider `[DONE]` chunk, settlement MUST adjust the reservation to actual usage as reported by the provider, subject to the symmetric streaming clamp policy below.

#### Streaming completion-token symmetric clamp (#255 downward, #278 upward)

The gateway runs two checks on every successful streaming settlement, sharing the SAME pure-absolute clamp window:

- Let `observed = ceil(bytes_emitted_so_far / 4)` (the existing § 7.2 disconnect-fallback heuristic).
- Let `reported = usage.completion_tokens` (provider's tokenizer count from the final usage chunk).
- Let `clampFloorTokens = 2`, `clampCeilingTokens = 20` (shared constants; no direction-specific tuning).

**Downward direction (#255, 2026-06-29): provider reported more than observed.**

- Let `overshoot_down = reported - observed`.
- Clamp DOWN to `observed` iff `clampFloorTokens < overshoot_down ≤ clampCeilingTokens`.
- In-window: usage event records `token_source = "gateway_estimated"`, preserves provider's reported `prompt_tokens`.

**Upward direction (#278, 2026-06-30): byte-estimator ran higher than reported.**

- Let `overshoot_up = observed - reported`.
- Clamp UP to `reported` (i.e. trust the provider's tokenizer) iff `clampFloorTokens < overshoot_up ≤ clampCeilingTokens`.
- In-window: usage event records `token_source = "provider_reported"`, preserves provider's reported `prompt_tokens` AND `completion_tokens`.

**Outside the window the gateway MUST NOT clamp:**

- `overshoot ≤ 2` (either direction): benign tokenizer noise (EOS / chat-template stop tokens that count as completion but never stream as delta content; or sub-byte rounding noise in the `ceil(N/4)` estimator). Existing settlement source applies — downward branch trusts the provider (`provider_reported`); upward branch trusts the byte estimate (`gateway_estimated`).
- `overshoot > 20` (either direction): too large to be tokenizer noise. Downward: density mismatch — byte-based estimate is unreliable on dense content (CJK, code, short-token text where 1 token < 4 bytes); clamping would risk under-billing the provider for legitimately generated content; trust provider (`provider_reported`). Upward: stream truncation or zero-report-fraud guard — the provider's usage chunk plausibly under-reports content actually generated; trust byte estimate (`gateway_estimated`).

When EITHER clamp fires, the gateway SHOULD emit a structured log line carrying `request_id`, `account_id`, `reported`, `observed`, `overshoot`, `window_floor`, `window_ceiling`, and `outcome` for audit visibility. The log MESSAGE field MUST distinguish direction (e.g. "clamped over-reported" vs "clamped under-reported").

The pure-absolute window is a deliberate trade and applies symmetrically. A percentage-scaled ceiling (50% × observed in earlier #255 drafts) was rejected because it still false-positive-clamped moderate-density legitimate reports (e.g. observed=225 byte-tokens with a legitimate 300-token actual count fell inside a percentage window and got clamped). The fixed 20-token ceiling caps the per-request adversarial exposure at 20 tokens regardless of completion size in EITHER direction, and trusts the more-reliable source for any overshoot large enough to plausibly reflect a real disagreement.

Skim surfaces NOT closed by the clamp (symmetric in both directions):

- `overshoot ≤ 2`: trusted as benign noise. Bounded; no structured-log emission. A provider can over- or under-report by up to 2 tokens per request without triggering the clamp.
- `overshoot > 20`: trusted as legitimate density / truncation. A provider can over- or under-report by any amount above 20 tokens (bounded only by `max_tokens`) without triggering the clamp.

Only the `3 ≤ overshoot ≤ 20` band (either direction) is both clamped and structured-log-visible for triage. Closing the residual skim surfaces requires a tokenizer-grounded observation (replacing the byte heuristic) — out of scope.

For streaming requests where the buyer disconnects mid-stream, the gateway settles the daily-quota reservation as follows:

1. The gateway sends a `cancel_request` to the coordinator, which forwards it to the provider, per the existing cancellation path.
2. The provider responds with `inference_response_end` carrying a `usage` field per SPEC-001 v1.2.3 § 6.6. The gateway MUST settle the reservation to `usage.prompt_tokens + usage.completion_tokens`, the exact tokens the provider actually consumed and emitted.
3. If the provider's `inference_response_end` omits the `usage` field, the gateway MUST fall back to `estimated_completion_tokens = ceil(bytes_emitted_so_far / 4)` plus the original prompt-token reservation. This fallback covers pre-v1.2.4 phase3-binaries, including v1.2.0 through v1.2.3, which do not guarantee usage on cancel. The 4-bytes-per-token constant remains the documented coarse approximation for English-leaning content.

Once all production-active providers run phase3-binary v1.2.4 or later, the estimation fallback path becomes unreachable in practice. A future SPEC-006 patch, v0.6 candidate, may remove the fallback when the operator confirms no pre-v1.2.4 binaries remain in the pool.

On 502 or 504 from the provider, Section 17's refund matrix applies.

On 503 where no provider was reached and the request was never forwarded, the reservation MUST be refunded in full.

The guiding rule is that quota is debited only for work the provider actually performed.

Disconnect fallback estimation is a coarse approximation for English-leaning content. The gateway MUST record in the usage event whether completion tokens were provider-reported or gateway-estimated.

### 7.3 Daily windows

The default daily quota window MUST be UTC calendar day unless configured otherwise.

`X-RateLimit-Reset` MUST identify the reset time as a Unix timestamp.

The docs MUST explain reset behavior.

Rate-limit headers MUST reflect post-decision quota state. For admitted requests this means after reservation; for rejected requests this means after the failed admission decision without subtracting rejected work.

Request-start token buckets are preflight abuse-shedding controls, not quota ledgers. A request rejected by the request-start bucket MUST NOT create a quota reservation, usage event, coordinator request, buyer debit, or provider payout. In v1 the bucket is process-local, so the limit applies per gateway instance rather than globally across all replicas.

### 7.4 Quota enforcement order

The gateway SHOULD enforce in this order:

1. all-public-api kill switch.
2. demo-only kill switch for demo traffic.
3. request body size limit.
4. auth or demo classification.
5. account/key status.
6. request-start rate bucket for chat completions.
7. signup closed state for signup paths.
8. per-request caps.
9. quota availability.
10. concurrency reservation.
11. coordinator availability.

### 7.5 Concurrency

The gateway MUST enforce per-account concurrency outside in-process memory.

The v1 implementation MAY use SQLite transactional reservations.

A reservation MUST expire or be released on request completion, timeout, or cancellation.

If the account has 4 active requests and the cap is 4, the fifth request MUST return 429 by default. Operators MAY tune the cap in `gateway.yaml`.

### 7.6 Request-start rate exceeded response

When the per-account request-start token bucket is exhausted before the first coordinator attempt, the gateway MUST return 429 before forwarding to the coordinator. If an already-admitted request exhausts the bucket while deciding whether to retry a transient coordinator response, the gateway MUST NOT make the extra retry attempt and MAY relay the current coordinator response.

The error code SHOULD be:

```text
account_request_rate_exceeded
```

The response MUST include `Retry-After`.

The gateway SHOULD emit a structured log line with at least `request_id`, `account_id`, `limit_rps`, and `retry_after_s`.

### 7.7 Quota exhausted response

When quota is exhausted, the gateway MUST return 429.

The error code SHOULD be:

```text
quota_exhausted
```

The response MUST include `X-RateLimit-Reset`.

### 7.8 Bounded slot queueing

The gateway MUST NOT queue requests indefinitely waiting for provider slots.

For non-pinned requests, the coordinator MAY hold a request in a bounded pre-dispatch slot queue when at least one otherwise eligible `ready` provider for the model reports `slots_free=0`. The queue MUST be FIFO per `provider_id`, MUST cap pending waiters at 4 per `provider_id`, and MUST use a total deadline no longer than 750 ms.

If no slot becomes available before the bounded queue deadline, or if the candidate provider leaves `ready` state, return 503.

Pinned provider or session requests MUST NOT enter this queue. If the pinned target has no immediately available slot, return 503.

If the account concurrency cap is reached, return 429.

---

## 8. Provider transparency

### 8.1 Publicly visible provider data

Buyers MAY see:

- model identifiers.
- provider_count.
- total_slots.
- slots_free on `/v1/status`.
- max_context_tokens.
- aggregate degraded state.
- aggregate pool counts.

### 8.2 Hidden provider data

Buyers MUST NOT see:

- stable provider IDs.
- assigned session IDs.
- provider hostnames.
- provider IP addresses.
- geographic location.
- provider RAM.
- provider CPU.
- endpoint URLs.
- tunnel URLs.
- operator identity.
- individual provider contribution counters.
- provider earnings.
- provider payouts.

### 8.3 Header scrubbing

The gateway MUST strip inbound buyer-supplied coordinator routing headers before forwarding:

- `X-MacProvider-Provider`
- `X-MacProvider-Session`
- `X-MacProvider-Pref`
- any other `X-MacProvider-*` header not on a documented allowlist

Buyers MUST NOT be able to influence provider selection through these headers.

The current coordinator may emit route headers such as provider or route identifiers.

The gateway MUST remove any upstream header that discloses provider identity before returning the response to buyers.

The explicit outbound strip list is:

- `X-MacProvider-Provider`
- `X-MacProvider-Route`
- any other `X-MacProvider-*` response header not on a documented response-pass-through allowlist

The documented response-pass-through allowlist is:

- `X-MacProvider-Receipt`, emitted by SPEC-015 v0.1.3 non-streaming
  receipt-capable providers and forwarded unchanged by the gateway.
- `X-MacProvider-Streaming-Mode`, the SPEC-018 AC-45 buyer-visible
  streaming-mode diagnostic set by the coordinator on streaming `200`
  responses. The gateway MUST forward it only when its value is one of
  the three canonical AC-45 values — `incremental`, `buffered_kill_switch`,
  or `buffered_provider_downgrade` — and MUST drop any other value rather
  than forward it verbatim (defense-in-depth: the value is coordinator-set,
  but the allowlist prevents a compromised or misconfigured upstream from
  smuggling arbitrary header content past the `X-MacProvider-*` strip). The
  header is observation-only (SPEC-018 §10d.4); buyers MUST NOT use it for
  negotiation.

The gateway MAY expose a public request ID.

The gateway MAY expose a public model ID.

### 8.4 Aggregation

If multiple providers serve the same model, the buyer sees one model entry.

`provider_count` is the count of eligible providers for that model.

`total_slots` is the sum of total slots across eligible providers for that model.

`slots_free` is the sum of free slots across eligible providers for status responses.

`max_context_tokens` is the maximum advertised context across eligible providers for that model.

---

## 9. Kill switches

### 9.1 `kill_switch.demo_only`

When `kill_switch.demo_only` is true:

- unauthenticated demo chat MUST return 503.
- authenticated API traffic MUST continue.
- `/v1/status` MAY remain available.
- `/v1/models` MAY remain available.
- signup MAY remain available unless a capacity tier closes it.

The response message SHOULD say the demo is paused while API keys still work.

### 9.2 `kill_switch.all_public_api`

When `kill_switch.all_public_api` is true:

- all public API requests MUST return 503.
- chat completions MUST return 503.
- demo traffic MUST return 503.
- authenticated traffic MUST return 503.
- signup SHOULD show beta paused or closed.
- `/v1/status` MAY return a minimal status explaining beta paused, but MUST NOT leak internals.

The response message SHOULD be friendly and explicit:

```text
Mac Provider beta is paused while capacity catches up. Please retry later.
```

### 9.3 Runtime toggling

Kill switches MUST be togglable without restarting the gateway.

Acceptable mechanisms:

- reload `gateway.yaml` on signal or file watch.
- operator-only `/admin/kill-switch` endpoint.
- storage-backed runtime config row.

The implementation MUST document the chosen mechanism.

Kill-switch activation latency MUST be measurable.

Activation MUST take effect within 5 seconds across all in-flight and new requests.

Kill-switch state MUST persist across gateway restarts.

Admin endpoint mutations MUST write the new state to `gateway.yaml` and update in-memory state.

On gateway startup, kill-switch state MUST be read from `gateway.yaml`.

SIGHUP MUST trigger re-read of `gateway.yaml`.

---

## 10. Capacity-burst protection

### 10.1 Mechanical tiers

Capacity-burst tiers MUST be executed mechanically by monitoring jobs.

Capacity-burst tiers MUST NOT depend on discretionary operator judgment once signals are recorded.

Operator input may be a signal only where explicitly defined, such as operator self-reported reactive-ops time.

### 10.2 Tier 1: close signups

Tier 1 fires when any configured signal is true:

- Pearl VPS sustained CPU over 70% for 4 hours.
- Coordinator memory over 80%.
- Bandwidth over 70% of VPS quota.
- Any provider explicitly requests reduced load.
- Projected monthly cost reaches 80% of `capacity.monthly_budget_usd`.

Signal measurement MUST follow this table:

| Signal | Source | Sample cadence | Aggregation window | Threshold | Hysteresis |
|---|---|---:|---:|---|---|
| CPU | `/proc/stat` on Linux or `host_processor_info` on macOS | 10s | rolling 4h mean | 70% | 5% below for de-escalation |
| Memory | `/proc/meminfo` available_kb / total_kb | 10s | rolling 1h mean | 80% | 5% below |
| Bandwidth | nginx access logs `bytes_sent` aggregated | 60s | rolling 24h | 70% of VPS quota | 10% below |
| Provider feedback | `/admin/provider-feedback` POST events | event-driven | 7-day count | 1+ event | manual clear required |
| Cost | sum of VPS, email, and storage projected against `capacity.monthly_budget_usd` | hourly | current month | 80% / 100% | 10% below |
| Provider drops | coordinator `/poolz` `summary.total_providers` series | 60s | rolling 48h | 2+ drops | 48h since last drop |
| Operator load | `/admin/operator-load` POST events | event-driven | 7-day | >70% of any week | manual clear |

Every signal MUST emit an audit event on threshold crossing.

Tier 1 action:

- signup page returns closed status.
- OAuth callbacks MUST NOT issue new accounts unless they complete an already-started flow within a short grace window.
- existing users continue at current quotas.
- front door shows signup closed state.

### 10.3 Tier 2: quota tighten

Tier 2 fires when:

- Tier 1 has been active for 7 or more days.
- at least one Tier 1 signal is still firing.

Tier 2 action:

- all account daily quotas reduce by 50% through config or capacity policy.
- front door shows capacity tightening banner.
- existing users remain authenticated.
- usage endpoint reports the effective lowered quota.

### 10.4 Tier 3: hard pause

Tier 3 fires when any configured signal is true:

- monthly cost exceeds `capacity.monthly_budget_usd`.
- two or more providers drop within a 48-hour window.
- operator self-reports reactive-ops time over 70% of any week.

Tier 3 action:

- set `kill_switch.all_public_api` true.
- public API returns 503 with beta-paused message.
- pool gets to rest.
- signup is closed.

Tier 3 MUST NOT contain a deprecation clause.

Tier 3 MUST NOT require project shutdown.

### 10.5 Capacity expansion branch

At any tier, operator may choose to:

- raise budget cap.
- upgrade Pearl VPS.
- recruit more providers.

Choosing capacity expansion MAY reverse the active tier without requiring root-cause resolution.

The reversal MUST be recorded as an audit event.

If capacity expansion raises `capacity.monthly_budget_usd`, the budget-cap mutation MUST emit an audit event with old value, new value, and actor.

Automatic de-escalation: when all signals that triggered a tier stop firing for a configurable cooldown, default 1 hour, the monitoring job MUST de-escalate to the previous tier.

De-escalation from Tier 3 to Tier 2 requires the additional condition that the capacity-expansion off-ramp was not taken; otherwise the system may return directly to Tier 0.

Manual de-escalation by the operator is permitted via `/admin/capacity-tier` POST with operator key.

Every de-escalation MUST emit an audit event with signal state and elapsed time below threshold.

### 10.6 Capacity signal storage

Capacity signals MUST be recorded as append-only events.

Tier changes MUST be recorded as audit events.

The gateway MUST expose enough operator-only data to explain which signal triggered the tier.

SPEC-006 gateway capacity-burst tiers (Tier 0/1/2/3) are independent from SPEC-002 coordinator admission tiers (`pinned`, `provisional`, `rejected`). SPEC-006 capacity tiers control buyer-side admission, quotas, signup state, and kill switches at the gateway. SPEC-002 admission tiers control provider-side admission at the coordinator. A SPEC-006 Tier 3 hard pause MUST NOT mutate SPEC-002 admission state. SPEC-002 provider exhaustion MUST NOT trigger SPEC-006 tier escalation directly; SPEC-006 observes provider-availability signals through `/poolz` and escalates only under its own thresholds.

---

## 11. User feedback

### 11.1 Rating scale

Rating scale is:

- 1 = bad.
- 2 = average.
- 3 = good.
- 4 = excellent.

The gateway MUST reject ratings outside 1 through 4.

### 11.2 API endpoint capture

`POST /v1/feedback` is required for v1.

It is authenticated.

It captures optional per-session or per-request ratings.

It is idempotent when `request_id` is provided.

### 11.3 Dashboard widget capture

A persistent dashboard or account widget is required for v1.

The widget captures overall experience.

The widget MUST call `POST /v1/feedback` with `scope: "account"` explicitly, or MAY use a thin account-specific feedback endpoint if implementation documents it.

The storage result MUST still be an append-only feedback event.

### 11.4 Chat playground capture

The Vercel demo MAY prompt the user for a rating after N exchanges.

This is recommended but not normative for v1.

Anonymous playground ratings MUST be stored as anonymous or demo-principal feedback events.

### 11.5 Aggregation

Feedback aggregation MUST support:

- 7-day rolling distribution.
- 14-day window comparison.
- count by rating.
- share of ratings that are 1 or 2.
- optional comment sampling for operator review.

Operator-readable aggregation endpoint:

```text
/admin/feedback-summary
```

This endpoint MUST NOT be exposed publicly at `api.streamvc.live` without operator auth.

The endpoint MUST support `?window=7d` and `?window=14d`; missing `window` defaults to `7d`.

Response shape:

```json
{
  "window_start": "2026-05-21T00:00:00Z",
  "window_end": "2026-05-28T00:00:00Z",
  "rating_count": 42,
  "mean": 3.1,
  "distribution": {"1": 3, "2": 6, "3": 20, "4": 13},
  "by_scope": {
    "request": {"rating_count": 10, "mean": 3.0},
    "session": {"rating_count": 5, "mean": 2.8},
    "account": {"rating_count": 20, "mean": 3.2},
    "playground": {"rating_count": 7, "mean": 3.0}
  },
  "trend": {
    "7d_share_1_2": 0.21,
    "14d_share_1_2": 0.18,
    "delta_pct": 16.7
  },
  "comment_samples": [
    {"rating": 2, "comment": "optional text", "scope": "request", "timestamp": "2026-05-28T00:00:00Z"}
  ]
}
```

A single account submitting multiple ratings with the same `request_id` counts only the most recent event for aggregation.

Each distinct rating event has equal weight after idempotency.

`comment_samples` MUST contain the 20 most recent non-empty comments at most.

### 11.6 Iteration signal

The operator MUST review root cause when the 7-day share of ratings 1-2 exceeds 40% in any window containing at least 20 distinct rating events.

This trigger fires automatically via an `/admin/feedback-summary?window=7d` poll executed by the monitoring job at minimum hourly cadence.

There is no MUST-pivot trigger.

There is no MUST-deprecate trigger.

The rating data replaces the previous falsification deprecation mechanism.

---

## 12. Front door contract

### 12.1 Existing state

The existing Vercel demo under `beta/web/` currently calls direct provider tunnel URLs for M1 and M4.

SPEC-006 front-door work MUST repoint demo chat traffic to:

```text
https://api.streamvc.live/v1/chat/completions
```

### 12.2 Gateway endpoints consumed by front door

The front door MUST be able to consume:

- `GET /v1/models` for model list.
- `GET /v1/status` for status panel.
- `POST /auth/demo-session` to obtain HMAC-signed demo tokens.
- `POST /v1/chat/completions` with `X-Demo-Token` for demo chat.
- GitHub OAuth start URL for "Get API key".
- `/account` or account API endpoints for usage and keys.
- `GET /v1/usage` for authenticated usage.
- `POST /v1/feedback` for rating widget.

For status-panel model rows, per-model `degraded` is defined normatively in SPEC-002 v1.1.4 § 4, FR-B1. The front door consumes the gateway's computed field and MUST NOT derive a competing definition.

The front door MUST render top-level `status: "idle"` as friendly no-awake-provider copy. It MUST NOT present `idle` as a hard outage, red infrastructure error, or coordinator-down condition. When model rows are present, the front door SHOULD display per-model `availability` detail so buyers can distinguish "no provider awake for this model" from "provider busy".

### 12.3 Demo token contract

The front door MUST create or obtain a demo session token.

The front door MUST send:

```text
X-Demo-Token: <token>
```

with demo chat requests.

The token MUST be tiny enough for browser headers.

The token MUST not be a bearer API key.

### 12.4 Account page contract

The account page MUST show:

- identity provider.
- key creation result once.
- active/revoked keys by prefix.
- regenerate key action.
- revoke key action.
- daily quota used.
- daily quota remaining.
- reset time.
- rating widget.
- capacity closed or paused state if active.

### 12.5 Docs section contract

The front door MUST include a single-page docs section.

Docs MUST include curl, Python, and JavaScript examples.

Docs MUST explain that this is a live Mac pool and occasional 503s are expected.

Docs MUST include the Tier 1 plaintext-to-provider disclosure from Section 1.6.

When `routing.sticky_enabled: true`, docs MUST include the sticky affinity disclosure from Section 1.6 before the first example that uses `X-MacProvider-Conversation`.

Docs MUST include the model identity caveat from Section 13.5.

Docs MUST avoid premium inference positioning.

Docs MUST not include donation or payment links.

### 12.6 Signup disclosure contract

The front-door signup flow MUST show a prominent Tier 1 disclosure before the user receives an API key.

The disclosure MUST state, in substantively equivalent language:

> MacProvider Tier 1 is cooperative inference. Buyer prompts and provider responses are processed as plaintext on provider hardware, so providers can technically observe prompts and outputs routed through their machine. Model identity is provider-reported. Verified model settlement, when enforce-active for covered paid traffic, means the provider-reported request-start model hash matched the route-time catalog snapshot and settlement receipt; it does not provide hardware attestation, runtime binary attestation, private prompts, malicious-output prevention, or detection of a provider falsifying its own loaded-model hash measurement.

The signup flow MUST require this disclosure to be visible before key issuance.

When `routing.sticky_enabled: true`, the signup flow MUST also state, in substantively equivalent language: "If you use a conversation tag, related requests may be routed to the same provider for up to the configured sticky TTL, so that provider can observe and correlate more of your traffic than under default routing." Operators running the default `routing.sticky_enabled: false` posture MUST NOT be required to show sticky-specific language.

The signup flow MUST NOT describe Tier 1 as provider-private, attested, encrypted-to-provider, malicious-provider-resistant, or model-integrity-verified without the provider-reported-hash caveat in the same view.

---

## 13. Documentation contract

### 13.1 Required docs content

The single-page docs MUST include:

- how to get a key.
- OAuth flow walkthrough.
- `GET /v1/models` curl example.
- `GET /v1/models` SDK-compatible example.
- `POST /v1/chat/completions` curl example.
- OpenAI Python SDK example.
- OpenAI JavaScript SDK example.
- streaming example.
- `GET /v1/usage` example.
- every HTTP error code and user action.
- quota explanation.
- reset behavior.
- live Mac pool caveat.
- Tier 1 plaintext-to-provider disclosure.
- conditional sticky affinity disclosure when `routing.sticky_enabled: true`.
- model identity caveat.
- `POST /v1/feedback` example.

### 13.2 OpenAI Python example

Docs MUST include an example equivalent to:

```python
from openai import OpenAI

client = OpenAI(
    api_key="mp_replace_me",
    base_url="https://api.streamvc.live/v1",
)

resp = client.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[{"role": "user", "content": "Say hello from a Mac"}],
)
print(resp.choices[0].message.content)
```

### 13.3 OpenAI JavaScript example

Docs MUST include an example equivalent to:

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: process.env.MACPROVIDER_API_KEY,
  baseURL: "https://api.streamvc.live/v1",
});

const resp = await client.chat.completions.create({
  model: "mlx-community/Qwen2.5-7B-Instruct-4bit",
  messages: [{ role: "user", content: "Say hello from a Mac" }],
});

console.log(resp.choices[0].message.content);
```

### 13.4 Error action table

Docs MUST map:

- 400 to request fix.
- 401 to missing or invalid key.
- 403 to revoked or blocked key.
- 404 to unknown model.
- 429 to quota or concurrency limit.
- 502 to upstream provider error (`upstream_provider_error`); retry.
- 503 to no provider/capacity/beta paused.
- 504 to provider timeout; retry later.

### 13.5 Tier 1 and model identity caveats

The single-page docs MUST include a "Tier 1 disclosure" subsection explaining that buyer prompts and provider responses are processed as plaintext on provider hardware; providers can technically observe prompts and outputs routed through their machine; hardware attestation is not performed; model identity is provider-reported; verified settlement language is constrained by the provider-reported-hash caveat; and Tier 1 makes no private-inference, hardware-attestation, runtime-binary-attestation, provider-private-prompt, untrusted-provider, malicious-output-prevention, or provider-falsified-model-measurement detection claims.

When `routing.sticky_enabled: true`, the single-page docs MUST include a "Sticky affinity" subsection explaining `X-MacProvider-Conversation`, `DELETE /v1/sticky`, the configured `sticky_ttl_s`, and the privacy tradeoff that related requests may be preferentially routed to the same provider during the TTL. When `routing.sticky_enabled: false`, this subsection is optional and, if present, MUST clearly state sticky affinity is disabled.

The single-page docs MUST include a "Model identity caveat" subsection explaining that model `id` is provider-reported, catalog-known hash status is distinct from settlement enforcement, and neither detects a provider falsifying its own loaded-model hash measurement.

The single-page docs MUST avoid wording that invites buyers to infer provider-private prompts from statements about avoiding AWS, GCP, Azure, or other hyperscalers.

Any README.md for an operator-distributed client SDK MUST include the same Tier 1 disclosure and model identity caveat before its first sensitive-prompt example. When `routing.sticky_enabled: true`, that README MUST also include the sticky affinity disclosure before its first `X-MacProvider-Conversation` example.

---

## 14. Storage layer

### 14.1 Interfaces

The gateway MUST define storage interfaces before concrete SQLite details leak into handlers.

Handlers MUST depend on interfaces, not SQLite-specific types.

### 14.2 SQLite v1

SQLite is the concrete v1 implementation.

SPEC-006 v1 is a single-gateway-instance deployment when using SQLite.

Multi-instance horizontal scaling requires migrating the `AuthStore`, `UsageStore`, and `FeedbackStore` interface implementations to a multi-writer-safe backend such as PostgreSQL, Cloudflare D1, or similar.

Handler code MUST require zero changes for this migration.

SQLite v1 MUST use WAL mode unless deployment evidence shows WAL is unsafe.

v1 does not require SQLite encryption at rest because storage runs on an operator-only VPS.

Migration to multi-tenant storage MUST require encryption at rest or an equivalent platform guarantee.

SQLite v1 MUST define indexes for:

- key hash lookup.
- identity provider + provider user ID.
- account daily usage by account and date.
- demo daily usage by IP/token and date.
- request ID lookup for idempotent feedback.
- usage event timestamp.
- audit event timestamp.

### 14.3 Required logical tables

Required logical storage:

- accounts.
- account_identities.
- api_keys.
- api_key_events.
- usage_events.
- quota_reservations or concurrency_reservations.
- feedback_events.
- signup_events.
- demo_usage_events.
- audit_events.
- capacity_signal_events.
- runtime_config or config_snapshot events if runtime toggles are storage-backed.

The `audit_events` table MUST record:

- every kill-switch toggle, including switch name, new state, and actor.
- every quota configuration change, including account_id when applicable, old value, new value, and actor.
- every key revocation and regeneration, including account_id, key_hash_prefix, and actor.
- every account block and unblock.
- every capacity tier transition, including signal state and audit-event chain.
- every budget cap mutation.

`usage_events` and `audit_events` MUST use the gateway `X-Request-ID` UUID v4 as the request correlation value for request-scoped entries. The physical row identity is the composite `(account_id, request_id)` (per #196); `request_id` alone is a logical join key, ambiguous on cross-account collisions. All request-scoped log surfaces that flow through the gateway MUST include the same `X-Request-ID`; uniqueness assertions and reconciliation joins MUST be account-scoped.

Events are append-only, immutable, and queryable through `/admin/audit-log` with operator-key authentication.

v0.2 records append-only audit events; v0.3 SHOULD add hash-chain tamper evidence if attack surface grows.

### 14.4 Hot path writes

Hot path writes MUST be append-only except for bounded reservation acquire/release mechanics.

If concurrency reservations use updates, they MUST be isolated to reservation state and MUST be safe on crash through expiry.

Quota reservations MUST use storage-backend-specific atomic semantics.

SQLite v1 MUST acquire token quota reservations with `BEGIN IMMEDIATE` before reading daily reservation totals and inserting the reservation row.

Usage event rows MUST NOT be updated after insertion.

Feedback event rows MUST NOT be updated after insertion.

Audit event rows MUST NOT be updated after insertion.

### 14.5 Global replication readiness

Schemas MUST avoid mutable counters as source of truth.

Aggregates SHOULD be derived from append-only events.

Configurable rollups MAY exist as caches but MUST be rebuildable.

API keys MUST be immutable once issued.

Timestamps MUST be monotonic enough for deterministic ordering.

---

## 15. Configuration

### 15.1 `gateway.yaml`

The gateway MUST load `gateway.yaml`.

All operator-tunable limits in SPEC-006 MUST be configurable without code changes.

### 15.2 Required configuration shape

The config MUST support fields equivalent to:

```yaml
listen:
  bind_address: 127.0.0.1
  port: 9443

public:
  base_url: https://api.streamvc.live
  account_path: /account

coordinators:
  - name: pearl-local
    base_url: http://127.0.0.1:8443
    weight: 1
    enabled: true

coordinator:
  # Buyer-facing coordinator URL for inference forwarding in single-host deploys.
  buyer_url: http://127.0.0.1:8443
  # Provider/operator listener for /poolz, /healthz, and /admin/* consumption.
  operator_url: http://127.0.0.1:8444
  # Operator key for /poolz authentication; value comes from env, not YAML.
  operator_key: env:COORDINATOR_OPERATOR_KEY
  # /poolz polling cadence.
  poolz_poll_interval_s: 10

storage:
  driver: sqlite
  db_path: gateway.db

auth:
  key_prefix: mp_
  key_hash: hmac_sha256
  github_oauth_enabled: true
  email_magic_link_enabled: false
  oauth:
    callback_allowlist:
      - https://api.streamvc.live/auth/github/callback
  demo:
    signing_secret: env:MACPROVIDER_DEMO_SIGNING_SECRET

quotas:
  account_daily_tokens: 100000
  demo_daily_tokens_per_ip: 1000
  demo_sessions_per_ip_per_hour: 10
  account_concurrency: 4
  account_request_rate_per_second: 30
  signup_accounts_per_ip_per_day: 3

limits:
  max_tokens_per_request: 4096
  demo_max_tokens_per_request: 512
  max_feedback_comment_bytes: 2000
  request_body_bytes: 1048576

kill_switch:
  demo_only: false
  all_public_api: false

capacity:
  monthly_budget_usd: 500
  ready_provider_degraded_threshold: 1
  projected_cost_tier1_percent: 80

timeouts:
  coordinator_request_seconds: 300
  streaming_cancel_ms: 500

settlement:
  reconcile_enabled: true
  reconcile_interval_s: 30
  reconcile_batch_limit: 100
  reconcile_request_timeout_s: 10
```

The gateway MUST authenticate `/poolz` requests with `coordinator.operator_key`.

If `coordinator.operator_url` or `coordinator.operator_key` is missing, gateway startup MUST fail with an explicit configuration error.

`coordinators[].base_url` remains the inference forwarding backend list. `coordinator.operator_url` is the operator/control-plane URL used for `/poolz` and MUST NOT be exposed to buyers.

### 15.3 Runtime reload

The implementation MUST document which config fields reload at runtime.

Kill-switch fields MUST reload without restart.

Quota defaults SHOULD reload without restart.

OAuth client secret changes MAY require restart if documented.

---

## 16. Instrumentation and metrics

### 16.1 Access metrics

The gateway MUST instrument:

- visit to key issuance conversion.
- key issuance to first `/v1/models`.
- key issuance to first successful completion.
- time to first successful completion.

### 16.2 Usage metrics

The gateway MUST instrument:

- daily active keys.
- requests per key.
- tokens per key.
- streaming vs non-streaming share.
- models requested.
- quota exhaustion count.

### 16.3 Reliability metrics

The gateway MUST instrument:

- 200/4xx/5xx by endpoint.
- 503 rate by model.
- 502/504 rate by provider internally.
- median and p95 time to first token.
- median and p95 total latency.

Provider-specific reliability metrics MUST remain operator-only.

### 16.4 Capacity metrics

The gateway MUST expose or record:

- connected provider count.
- ready provider count.
- total slots.
- provider utilization.
- request rejection due to no slots.
- capacity tier state.
- monthly projected cost.

Capacity metric collection MUST use the signal sources, cadences, aggregation windows, thresholds, hysteresis, and audit events defined in Section 10.2.

### 16.5 Abuse metrics

The gateway MUST record:

- signup attempts per IP.
- keys per IP.
- disabled keys.
- top token consumers.
- repeated high-output requests.
- error-heavy accounts.

### 16.6 Learning metrics

The operator workflow SHOULD capture:

- first prompt category by rough operator review.
- repeat prompt category.
- docs pages copied from.
- support questions.
- capability requests.

If these are manual at v1, the manual process MUST be documented.

### 16.7 Feedback metrics

The gateway MUST compute:

- rating counts by value.
- 7-day rating distribution.
- 14-day trend toward ratings 1-2.
- account-level latest overall rating.
- feedback count by endpoint source.

---

## 17. Failure modes

### 17.1 Status code map

The gateway MUST use:

- `400` for malformed JSON, invalid schema, invalid field value, or request over configured request cap.
- `401` for missing or invalid bearer token.
- `403` for valid token with revoked key, disabled key, blocked account, or forbidden action.
- `404` for unknown model.
- `405` for wrong method.
- `413` for request body too large.
- `429` for quota exhausted, signup issuance exceeded, or account concurrency exceeded.
- `502` for selected provider failed mid-request.
- `503` for known model with no provider available, demo paused, public API paused, coordinator unavailable, or no immediate slot.
- `504` for provider timeout.

A coordinator-issued `500` with `code: "route_snapshot_failed"` (a SPEC-022 pre-dispatch durable route-snapshot write failure — no provider reached) is passed through to the buyer verbatim rather than re-mapped, and is settled per § 17.7 (no charge on a genuine first-attempt failure). See § 17.7 for the cross-attempt exception.

405 Method Not Allowed MUST use `type: "invalid_request_error"` and `code: "method_not_allowed"`.

413 Payload Too Large MUST use `type: "invalid_request_error"` and `code: "request_too_large"`.

### 17.2 Model unknown

If a model is not in any provider's served, **declared** (`supported_models`), or recently seen model list, return 404. **(v0.9.12 clarification — runbook item 22:)** a provider's "seen" model list is the union of its served `model_id` and every model it declared in `supported_models` (SPEC-010 v1.5 R-3.3.4, authoritative; SPEC-002 v1.5.4 R-3.X.6). So a model some connected provider **declares supported but has not warmed** is *known* and falls through to § 17.3's `503 no_provider_available` (retryable), not 404 — matching the shipped `ModelKnown()` gate (#555). This changes no dispatch outcome, only the error code a declared-but-cold request receives (404 → 503).

Code:

```text
model_not_found
```

### 17.3 Model unavailable

If a model is known — served, **declared in `supported_models`**, or recently seen (§ 17.2 / SPEC-010 R-3.3.4) — but no provider slot is available after any allowed bounded pre-dispatch slot queue expires, return 503.

Code:

```text
no_provider_available
```

### 17.4 Provider failure

If the selected provider fails mid-request, return 502 before response headers are sent.

Code:

```text
upstream_provider_error
```

HTTP 502 means the upstream coordinator returned an error from the selected provider. The gateway MUST forward an OpenAI-shaped error envelope with `type: "api_error"` and `code: "upstream_provider_error"`.

If the coordinator returns SPEC-002 v1.1.4 `provider_error`, the gateway MUST normalize it to SPEC-006 `upstream_provider_error`. This matches SPEC-002 v1.1.4 provider-failure close-code semantics while keeping buyer-facing gateway terminology stable.

If failure occurs after streaming headers are sent, emit an SSE error frame and `[DONE]`.

Quota settlement MUST follow Section 17.7.

### 17.5 Provider timeout

If provider exceeds timeout, return 504 before response headers are sent.

Code:

```text
provider_timeout
```

Quota settlement MUST follow Section 17.7.

### 17.6 Streaming cancellation

When the buyer disconnects from an SSE stream, the gateway MUST cancel the upstream coordinator request within 500 ms.

The gateway MUST release concurrency reservation.

The gateway MUST append a cancellation usage or audit event and settle quota according to Section 17.7.

### 17.7 Quota refund and settlement matrix

The gateway MUST reserve quota before forwarding as defined in Section 7.2 and settle reservations using this matrix:

| Status | Completion tokens | Quota debited | Rationale |
|---|---:|---|---|
| 200 | as reported, subject to § 7.2 symmetric clamp | prompt + completion | Successful work performed; streaming `completion_tokens` symmetric-clamped within `2 < overshoot ≤ 20`: downward (#255) clamps to gateway observed (`token_source = "gateway_estimated"`); upward (#278) clamps to provider reported (`token_source = "provider_reported"`) |
| 503 | 0 | none | No provider was reached; request never forwarded |
| 500 `route_snapshot_failed` (pre-dispatch, marked no-prior-dispatch) | 0 | **none** | Coordinator failed to durably persist the SPEC-022 route snapshot before dispatching any provider; no provider was reached. Gateway refunds the reservation, writes a zero-token audit row, and passes the coordinator body through verbatim (item 18) — but **only** when the coordinator sets the POSITIVE `X-MacProvider-Settlement-No-Prior-Dispatch` marker AND the gateway saw no prior provider-billed retry. The coordinator stamps that marker centrally on **any** terminal response written while no provider has been **billably credited** in the request. "Credited" is ledger-exact, derived from two recorder signals rather than a request-log ordinal: `providerCredited` (set inside `recordRow` when a provider-bound billable row persists — `providerAssignedID != "" AND status != 503`; covers every attempt whose billing lands before the write, i.e. coordinator-internal failover attempts) and `dispatchedThisAttempt && terminalStatus != 503` (covers the current terminal attempt, whose own billing row is recorded AFTER its terminal write on the WS paths — a dispatched non-503 terminal WILL be billed, so it is left unmarked; a dispatched 503 terminal is not billed and stays marked). This supersedes the earlier `attemptN == 0` source, which over-counted non-billed 503 rows (over-charge) and incremented after the terminal WS write (under-charge). Requiring the positive marker (not the absence of a negative one) keeps a gateway-first deploy / coordinator rollback safe: an **unmarked** `route_snapshot_failed` settles on the prompt estimate per the 502 rows instead. Two cases are unmarked/settled so provider work credited in `observe` mode is not erased: (1) *coordinator-internal failover* — the marker is withheld on a `route_snapshot_failed` after an earlier credited provider (`providerCredited`); (2) *gateway retry* — the gateway retried an earlier **unmarked** response (a provider-dispatched `provider_*` 502, or a `no_provider` 503 from failover exhaustion after a billed attempt), setting `priorProviderDispatch`. A genuinely cold retried 502/503 is marked, so it does not poison a later refund. A settlement-finality header also disqualifies the refund. **Deploy the coordinator before the gateway; roll back in reverse.** **Carried limitation (documented):** on the coordinator's *write-before-bill* streaming / WS-tunneled terminal paths the marker is decided from the OUTWARD wire status, which can render a non-billable `503` (queue-full / relay-unavailable) as a `502 provider_error`. Such a response is left unmarked, so if the gateway retries it and later receives a `route_snapshot_failed`, it settles the estimate instead of refunding — the SAME behavior as pre-item-18 (where `route_snapshot_failed` was ALWAYS settled), i.e. this multi-attempt edge is pre-existing and NOT worsened by item 18. A fully ledger-exact marker on these paths requires carrying the canonical billing status (not the wire status) across every write-before-bill terminal site, or reordering terminal billing before the write; tracked as a follow-up. |
| Context cancelled (buyer disconnects mid-reservation) | n/a | none; reservation refunded before return | Gateway MUST exit silently without writing a 500 to the dead connection |
| Context cancelled (buyer disconnects at concurrency gate) | n/a | none; quota reservation refunded before return | Same as above |
| SPEC-001 null-usage error (`error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal`) | 0 (NULL) | **none** | Provider was reached but performed no countable work; no buyer debit |
| 502 | 0 | prompt only | Provider was reached, processed prompt, then failed |
| 502 | >0 partial stream | prompt + actual completion | Provider performed partial work |
| 504 | 0 | prompt only | Provider was reached, processed prompt, then timed out |
| 504 | >0 partial stream | prompt + actual completion | Provider performed partial work |
| Client disconnect (v1.2.4+ provider) | provider-reported actual | prompt + actual completion, exact from `usage` field | Provider performed exactly this much work; report is normative per SPEC-001 v1.2.3 |
| Client disconnect (pre-v1.2.4 provider, usage absent) | byte-estimated | prompt + `ceil(bytes_emitted_so_far / 4)` completion, estimated with +/-5 tokens typical | Fallback when usage is not yet normatively guaranteed |

The gateway MUST debit only work the provider actually performed.

SPEC-001 null-usage errors are distinguished from 502/504 with 0 completion (which DO debit prompt only) because the null-usage error states indicate the provider returned a structured "did not even start work" signal. SPEC-005 v0.3 § 6.9 mirrors this row with zero provider credit. H-005 reconciliation requires both sides to agree: buyer 0, provider 0.

The client-disconnect rows intentionally prefer provider-reported actuals and preserve deterministic estimation as a backward-compatibility fallback for pre-v1.2.4 providers.

#### 17.7.1 Buyer-visible terminal SSE error envelope contract (#232)

**Scope.** This clause applies to streaming fallback settlements whose `usage_events.outcome` is non-`"ok"` AND where the buyer connection remains writable at settle time (the harness-success stream surface — the buyer received an HTTP 2xx, the gateway is mid-stream, settlement happens before the response closes). The contract does NOT apply to client-disconnect rows in §17.7 where the buyer has already left the wire; those settle on the gateway side without a buyer-visible terminal frame by definition.

Streaming fallback settlements in scope MUST emit a buyer-visible OpenAI-style terminal SSE error envelope to the byte stream BEFORE the closing `data: [DONE]` frame (or before EOF for paths that cannot emit `[DONE]`):

```text
data: {"error": {"message": "...", "type": "...", "code": "<error-code>"}}
```

Constraints on the envelope:

1. The envelope MUST be a STANDALONE SSE data frame. No `choices` field. No `usage` field. Presence of either key — regardless of value shape (empty array, empty object, `null`, zero token counts) — disqualifies the frame as a terminal envelope. Additionally, top-level JSON keys and the immediate keys of the `error` object MUST be unique; duplicate `choices`, `usage`, `error`, or any immediate `error.code`/`error.type`/other `error.*` field MUST cause a spec-compliant parser to reject the frame. Duplicates deeper inside `error.*` values (e.g. inside `error.details` sub-objects, provider-metadata trees) are NOT normatively required to reject — they carry no smuggling risk against the corroboration trust gate. Trailing bytes after the object (anything other than JSON whitespace up to EOF) MUST cause rejection. (Tightened by #295: literal absence of `choices`/`usage` keys, byte-strict rejection of top-level/`error`-surface duplicates and trailing garbage — earlier "no usage field with non-zero token counts" wording allowed JSON smuggling shapes the buyer's SDK would still see as valid.)
2. `error.code` MUST be non-empty. The relationship between `error.code` and `usage_events.outcome` is normatively bound:
   - DEFAULT: `error.code` MUST equal the settled `usage_events.outcome` value. Examples of values where gateway writes both sides identically: `stream_truncated`, `stream_malformed`, `stream_output_exceeded`, `upstream_error`, `provider_timeout`.
   - PASS-THROUGH EXCLUSION: terminal envelopes the gateway FORWARDS verbatim without writing its own `usage_events` row (the SPEC-019 v0.2 pass-through allow-list, e.g. `response_byte_cap_exceeded`, `malformed_json_response`, `json_schema_validation_failed`, and the provider-emitted `provider_timeout` variant) have no settlement row to match — this mapping clause does not apply to them. Their shape/position rules still apply (per §17.7.1 clauses 1, 3, 4).
   - NAMED MAPPING EXCEPTIONS — each entry below is a named gateway divergence (gateway writes a `usage_events` row AND the buyer-visible `error.code` is different) that this clause permits explicitly:
     - `error.code = "provider_disconnected"` ↔ `usage_events.outcome = "stream_truncated"`. Reference: `writeProviderDisconnectedSSE` in `phase5-gateway/internal/router/chat_proxy.go`, which calls `writeSSEError(..., "server_error", "provider_disconnected")` for the SPEC-002 FR-B6 envelope while the gateway settles as `stream_truncated`.
   - Any future divergence MUST be added to this list as a named mapping (with reference implementation citation) BEFORE the divergent code path ships. Unlisted divergences MUST be treated by the harness as uncorroborated overbill candidates.
3. The envelope MUST be the LAST data frame on the stream before `[DONE]` or EOF. Content frames MUST NOT follow the envelope. Additional data frames sent AFTER `[DONE]` are invisible to OpenAI-style clients; the harness MUST stop reading at the first `[DONE]` and MUST NOT count post-`[DONE]` content (envelope or otherwise) as part of buyer-side corroboration evidence. (#232 R3 SEC HIGH.)
4. Reference implementations: `writeSSEError`, `writeStructuredOutputTimeoutSSE`, `writeProviderDisconnectedSSE` in `phase5-gateway/internal/router/chat_proxy.go`.

This contract is what the harness reconciler relies on to corroborate the gateway's `usage_events.outcome` label when suppressing fallback pairs from the I1 overbill check (`GatewayOverbillVsHarnessTokens` / `GatewayOverbillVsCoordinatorTokens` / `AbsGatewayCoordinatorMismatchTokens`). Without this clause the gateway's outcome label is a trust gate: a buggy or attacker-controlled gateway could label a real overbill as `stream_truncated` to hide it from I1 (#229 R6 security HIGH → #232).

A fallback row whose buyer never saw the standalone terminal envelope MUST be flagged by the harness as an uncorroborated overbill. Future money-path code paths that intentionally settle as a fallback outcome without emitting the envelope (e.g. a future code path that closes the stream silently) MUST update this SPEC clause with a named exception and version bump — a silent broad escape clause is not permitted.

SPEC-019 structured-output terminal frames inherit this same standalone / last-data-frame / no-content-after rule when settling streaming fallback outcomes (see SPEC-019 for the structured-output specific code list).

### 17.8 Kill-switch failure mode

Kill-switch responses MUST be 503.

The error type MUST be:

```text
service_unavailable
```

The code MUST distinguish:

- `demo_paused`
- `beta_paused`

---

## 18. Acceptance criteria

### AC-1: service boundary

Verification:

1. Inspect repo tree after implementation.
2. Confirm gateway code lives under `phase5-gateway/`.
3. Confirm coordinator code remains under `phase4-coordinator/`.
4. Confirm gateway has its own build artifact.
5. Confirm gateway has its own systemd unit or deployment template.

Pass condition:

- Gateway is separate from coordinator and can be restarted independently.

### AC-2: coordinator local binding

Verification:

1. Start coordinator with SPEC-006 deployment config.
2. Run `ss -ltnp` or equivalent on Pearl VPS.
3. Confirm coordinator buyer port listens on `127.0.0.1:8443`.
4. Confirm public `/v1/*` traffic reaches gateway, not coordinator.

Pass condition:

- Coordinator buyer port is not publicly bound.

### AC-3: public endpoint allowlist

Verification:

1. Call every allowed endpoint at `api.streamvc.live`.
2. Call `/admin/foo`, `/poolz`, `/healthz`, and `/ws/provider`.
3. Inspect responses.

Pass condition:

- Allowed endpoints behave per spec.
- Disallowed endpoints do not expose coordinator internals.

### AC-4: GitHub OAuth signup

Verification:

1. Start signup from front door.
2. Complete GitHub OAuth.
3. Confirm account is created.
4. Confirm one active API key is issued.
5. Confirm full key is displayed once.
6. Refresh account page.

Pass condition:

- Full key is not redisplayed after issuance.

### AC-5: key hash storage

Verification:

1. Issue an API key.
2. Inspect SQLite database.
3. Search for full key string.
4. Confirm only hash/HMAC and prefix are stored.

Pass condition:

- Full key is absent from storage and logs.

### AC-6: OpenAI SDK compatibility

Verification:

1. Use OpenAI Python SDK with `base_url=https://api.streamvc.live/v1`.
2. Call `chat.completions.create` with a valid model.
3. Use OpenAI JavaScript SDK with the same base URL.
4. Call the same endpoint.

Pass condition:

- Both SDKs receive successful OpenAI-shaped responses.

### AC-7: streaming

Verification:

1. Send `stream: true`.
2. Confirm `Content-Type: text/event-stream`.
3. Confirm chunks arrive incrementally.
4. Confirm `[DONE]` is received.
5. Disconnect client mid-stream.
6. Confirm upstream coordinator request is canceled within 500 ms.

Pass condition:

- Streaming works and cancellation is timely.

### AC-8: quota enforcement

Verification:

1. Configure daily token quota to a small value.
2. Exhaust quota with authenticated requests.
3. Send one more request.
4. Inspect rate-limit headers.

Pass condition:

- Request returns 429 with `X-RateLimit-Reset`.

### AC-9: demo quota

Verification:

1. Send demo requests with valid `X-Demo-Token`.
2. Exhaust demo quota for one IP.
3. Send another demo request.
4. Send authenticated request from same IP.

Pass condition:

- Demo request returns 429.
- Authenticated request is evaluated against account quota, not demo quota.

### AC-10: concurrency cap

Verification:

1. Configure per-account concurrency cap to 2.
2. Start two long streaming requests.
3. Start a third request with same account key.

Pass condition:

- Third request returns 429.
- Concurrency slots release after the first two complete or cancel.

### AC-11: provider transparency

Verification:

1. Call `/v1/models`.
2. Call `/v1/status`.
3. Call chat completion.
4. Inspect headers and body.

Pass condition:

- No provider ID, hostname, IP, route ID, endpoint URL, RAM, CPU, or operator identity appears.

### AC-12: model aggregation

Verification:

1. Register three providers for one model.
2. Call `/v1/models`.

Pass condition:

- One model row appears with `provider_count: 3`.

### AC-13: status shape

Verification:

1. Register ready, draining, and unavailable providers.
2. Call `/v1/status`.

Pass condition:

- Response reports aggregate counts and model slot counts without provider identity.
- Coordinator reachable with zero ready providers returns `status: "idle"` and `degraded: false`.
- Coordinator unreachable returns `status: "down"`.

### AC-14: demo-only kill switch

Verification:

1. Set `kill_switch.demo_only=true`.
2. Send demo chat request.
3. Send authenticated chat request.

Pass condition:

- Demo returns 503.
- Authenticated request continues if capacity exists.

### AC-15: all-public-api kill switch

Verification:

1. Set `kill_switch.all_public_api=true`.
2. Send demo request.
3. Send authenticated chat request.
4. Send usage request.

Pass condition:

- Public API traffic returns 503 beta-paused response.

### AC-16: capacity Tier 1

Verification:

1. Inject capacity signal for projected monthly cost at 80% of configured budget.
2. Run monitoring job.
3. Attempt new signup.
4. Use existing key.

Pass condition:

- Signup closes.
- Existing key continues at current quota.

### AC-17: capacity Tier 2

Verification:

1. Keep Tier 1 active for simulated 7 days.
2. Keep one Tier 1 signal firing.
3. Run monitoring job.
4. Call `/v1/usage`.

Pass condition:

- Effective daily quota is reduced by 50%.
- Front door status can show capacity tightening.

### AC-18: capacity Tier 3

Verification:

1. Inject monthly cost above budget or two provider drops within 48 hours.
2. Run monitoring job.
3. Send authenticated chat request.

Pass condition:

- `kill_switch.all_public_api` is set true.
- Chat returns 503 beta-paused response.

### AC-19: feedback endpoint

Verification:

1. POST rating 4 with a request ID.
2. Repeat same POST.
3. POST invalid rating 5.
4. Inspect feedback storage.

Pass condition:

- Valid request stores one idempotent feedback event.
- Invalid rating returns 400.

### AC-20: dashboard rating widget

Verification:

1. Load account page.
2. Submit overall rating.
3. Refresh account page.
4. Call feedback summary as operator.

Pass condition:

- Rating appears as latest account rating and contributes to aggregation.

### AC-21: error envelopes

Verification:

1. Trigger each status: 400, 401, 403, 404, 429, 502, 503, 504.
2. Inspect body.

Pass condition:

- Every non-streaming error uses OpenAI-shaped error envelope.

### AC-22: append-only usage

Verification:

1. Send successful and failed requests.
2. Inspect storage operations or database rows.
3. Confirm usage events are inserted, not updated.

Pass condition:

- Usage event history is append-only.

### AC-23: sub-ms auth lookup

Verification:

1. Seed enough keys to approximate v1 expected load.
2. Run auth lookup benchmark against SQLite.
3. Capture p95.

Pass condition:

- p95 key validation is under 1 ms or launch is blocked until schema/indexes are fixed.

### AC-24: front-door migration

Verification:

1. Inspect deployed front-door network calls.
2. Confirm chat calls `api.streamvc.live/v1/chat/completions`.
3. Confirm no direct browser or Vercel call goes to `m1.streamvc.live` or `m4.streamvc.live` for the main demo.

Pass condition:

- Front door uses gateway for demo chat.

### AC-25: docs completeness

Verification:

1. Open front-door docs.
2. Check for all required docs items in Section 13.

Pass condition:

- Docs cover key issuance, models, chat, streaming, usage, errors, quota, caveats, and feedback.

### AC-26: OAuth callback URL allowlist

Precondition:

- Gateway config contains only `https://api.streamvc.live/auth/github/callback` in `auth.oauth.callback_allowlist`.

Branches:

- Branch A, matching callback:
  - Action: `GET /auth/github/callback?code=<valid-code>&state=<valid-state>&redirect_uri=https://api.streamvc.live/auth/github/callback`
  - Expected: HTTP 302 redirect response with `Location: /account`; body MAY be empty and MUST NOT contain an OpenAI error envelope.
  - Verification: `curl -i -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://api.streamvc.live/auth/github/callback?code=<valid-code>&state=<valid-state>&redirect_uri=https://api.streamvc.live/auth/github/callback" | grep -Eq '^302 .*/account'`
- Branch B, mismatched callback:
  - Action: `GET /auth/github/callback?code=<valid-code>&state=<valid-state>&redirect_uri=https://evil.example/callback`
  - Expected: HTTP 400 with JSON `{"error":{"type":"invalid_request_error","code":"oauth_callback_not_allowed"}}`; no account or key is issued.
  - Verification: `curl -si "https://api.streamvc.live/auth/github/callback?code=<valid-code>&state=<valid-state>&redirect_uri=https://evil.example/callback" | grep -q "HTTP/.* 400" && curl -s "https://api.streamvc.live/auth/github/callback?code=<valid-code>&state=<valid-state>&redirect_uri=https://evil.example/callback" | jq -e '.error.type == "invalid_request_error" and .error.code == "oauth_callback_not_allowed"'`

Go verification: `go test ./phase5-gateway/... -run TestOAuthCallbackAllowlist`

### AC-27: token revocation latency

Precondition:

- One active `mp_*` API key exists and succeeds on `/v1/models`.

Action:

1. Revoke the key.
2. Poll `GET /v1/models` every 5 seconds starting at T+0 with the same key.

Expected outcome:

- The first revoked-key response MUST arrive by T+60s. A first 403 at T+65s fails this AC.
- Revoked-key response is HTTP 403 with JSON `{"error":{"type":"permission_error","code":"api_key_revoked"}}`.

Verification command:

```text
curl -i -H "Authorization: Bearer <revoked-key>" https://api.streamvc.live/v1/models
go test ./phase5-gateway/... -run TestKeyRevocationLatency
```

### AC-28: kill-switch persistence

Precondition:

- Gateway is running with `kill_switch.all_public_api=false`.

Action:

1. Toggle `kill_switch.all_public_api=true` through the operator path.
2. Restart the gateway.
3. Send an authenticated chat request.

Expected outcome:

- The restarted gateway reads the persisted kill-switch state.
- Chat returns HTTP 503 with OpenAI error envelope `type: "server_error"` and `code: "public_api_paused"`.

Verification command:

```text
curl -i -H "Authorization: Bearer <key>" https://api.streamvc.live/v1/chat/completions
go test ./phase5-gateway/... -run TestKillSwitchPersistsAcrossRestart
```

### AC-29: OAuth state CSRF defense

Precondition:

- A signup session has a stored OAuth `state` value generated by the gateway.

Branches:

- Branch A, forged or unbound state:
  - Action: `GET /auth/github/callback?code=<valid-code>&state=<forged-state>&redirect_uri=https://api.streamvc.live/auth/github/callback`
  - Expected: HTTP 400 with JSON `{"error":{"type":"invalid_request_error","code":"oauth_state_invalid"}}`; no account is created.
  - Verification: `curl -si "https://api.streamvc.live/auth/github/callback?code=<valid-code>&state=<forged-state>&redirect_uri=https://api.streamvc.live/auth/github/callback" | grep -q "HTTP/.* 400" && curl -s "https://api.streamvc.live/auth/github/callback?code=<valid-code>&state=<forged-state>&redirect_uri=https://api.streamvc.live/auth/github/callback" | jq -e '.error.type == "invalid_request_error" and .error.code == "oauth_state_invalid"'`
- Branch B, valid session-bound state:
  - Action: `GET /auth/github/callback?code=<valid-code>&state=<stored-state>&redirect_uri=https://api.streamvc.live/auth/github/callback`
  - Expected: HTTP 302 redirect response with `Location: /account`; body MAY be empty and MUST NOT contain `oauth_state_invalid`.
  - Verification: `curl -i -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://api.streamvc.live/auth/github/callback?code=<valid-code>&state=<stored-state>&redirect_uri=https://api.streamvc.live/auth/github/callback" | grep -Eq '^302 .*/account'`

Go verification: `go test ./phase5-gateway/... -run TestOAuthStateCSRF`

### AC-30: OAuth scope minimization

Precondition:

- GitHub OAuth callback simulation can include granted scope metadata.

Branches:

- Branch A, allowed `read:user` scope:
  - Action: simulate a callback with granted scope exactly `read:user`.
  - Expected: HTTP 302 redirect response with `Location: /account`; body MAY be empty and MUST NOT contain an OpenAI error envelope.
  - Verification: `curl -i -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://api.streamvc.live/auth/github/callback?code=<valid-code>&state=<valid-state>&redirect_uri=https://api.streamvc.live/auth/github/callback" | grep -Eq '^302 .*/account'`
- Branch B, elevated repository, organization, gist, or write scope:
  - Action: simulate a callback whose granted scope includes an elevated scope.
  - Expected: HTTP 403 with JSON `{"error":{"type":"permission_error","code":"oauth_scope_forbidden"}}` and an audit event with `event_type: "oauth_scope_rejected"`.
  - Verification: `curl -si "https://api.streamvc.live/auth/github/callback?code=<elevated-scope-code>&state=<valid-state>&redirect_uri=https://api.streamvc.live/auth/github/callback" | grep -q "HTTP/.* 403" && curl -s "https://api.streamvc.live/auth/github/callback?code=<elevated-scope-code>&state=<valid-state>&redirect_uri=https://api.streamvc.live/auth/github/callback" | jq -e '.error.type == "permission_error" and .error.code == "oauth_scope_forbidden"'`

Go verification: `go test ./phase5-gateway/... -run TestOAuthScopeMinimization`

### AC-31: key rotation preserves history

Precondition:

- An account has usage events, quota state, and feedback history.

Action:

1. Regenerate the account's API key.
2. Query `/v1/usage` and feedback summary.
3. Use the old key and the new key.

Expected outcome:

- Usage, quota, and feedback history remain associated with the account.
- Old key returns HTTP 403 with JSON `{"error":{"type":"permission_error","code":"api_key_revoked"}}`.
- New key returns HTTP 200 from `/v1/usage` with `account_id`, `quota`, `keys`, `models`, and `rating` fields.

Verification command:

```text
curl -i -H "Authorization: Bearer <old-key>" https://api.streamvc.live/v1/usage
curl -i -H "Authorization: Bearer <new-key>" https://api.streamvc.live/v1/usage
go test ./phase5-gateway/... -run TestKeyRotationPreservesHistory
```

### AC-32: capacity tier de-escalation

Precondition:

- Tier 1 or Tier 2 is active because a deterministic capacity signal crossed threshold.

Action:

1. Move all triggering signals below hysteresis thresholds.
2. Advance fake time past the configured cooldown.
3. Run the monitoring job.

Expected outcome:

- Operator job response is HTTP 200 with JSON containing `previous_tier`, `new_tier`, and `signals_below_threshold: true`.
- An audit event records `event_type: "capacity_tier_deescalated"`, signal state, and elapsed time.

Verification command:

```text
curl -i -H "Authorization: Bearer <operator-key>" -X POST http://127.0.0.1:9443/admin/capacity-tier/evaluate
go test ./phase5-gateway/... -run TestCapacityTierDeescalation
```

### AC-33: feedback summary aggregation shape

Precondition:

- Feedback events exist across `request`, `session`, `account`, and `playground` scopes, including duplicate `request_id` ratings.

Action:

1. Call `/admin/feedback-summary?window=7d`.
2. Call `/admin/feedback-summary?window=14d`.

Expected outcome:

- Authorized responses return HTTP 200 and match the Section 11.5 schema.
- Duplicate request ratings count only the most recent event.
- Comment samples contain at most 20 recent non-empty comments.
- Missing or invalid operator auth returns HTTP 401 with JSON `{"error":{"type":"authentication_error","code":"invalid_operator_token"}}`.

Verification command:

```text
curl -i -H "Authorization: Bearer <operator-key>" "http://127.0.0.1:9443/admin/feedback-summary?window=7d"
go test ./phase5-gateway/... -run TestFeedbackSummaryAggregation
```

### AC-34: provider-pinning header strip

Precondition:

- Coordinator has at least two providers and honors `X-MacProvider-Provider` or `X-MacProvider-Session` if received directly.

Branches:

- Branch A, successful upstream:
  - Action: send a gateway chat request containing `X-MacProvider-Provider`, `X-MacProvider-Session`, and `X-MacProvider-Pref`, then capture the forwarded coordinator request.
  - Expected: forwarded request contains none of those headers; buyer response is HTTP 200 with OpenAI chat completion JSON or SSE body, and response headers contain no `X-MacProvider-Provider`, `X-MacProvider-Route`, or undocumented `X-MacProvider-*`.
  - Verification: `curl -si -H "Authorization: Bearer <key>" -H "X-MacProvider-Provider: pinned" -H "X-MacProvider-Session: pinned" -H "X-MacProvider-Pref: fast" https://api.streamvc.live/v1/chat/completions | tee /tmp/ac34-success.txt && grep -q "HTTP/.* 200" /tmp/ac34-success.txt && ! grep -Eiq '^X-MacProvider-(Provider|Route|Session|Pref):' /tmp/ac34-success.txt`
- Branch B, upstream failure:
  - Action: repeat the same request while the mock upstream returns provider failure.
  - Expected: HTTP 502 with OpenAI error envelope `{"error":{"type":"api_error","code":"upstream_provider_error"}}`; response body and headers contain no provider or route identifiers.
  - Verification: `curl -si -H "Authorization: Bearer <key>" -H "X-MacProvider-Provider: pinned" -H "X-MacProvider-Session: pinned" -H "X-MacProvider-Pref: fast" https://api.streamvc.live/v1/chat/completions | tee /tmp/ac34-error.txt && grep -q "HTTP/.* 502" /tmp/ac34-error.txt && ! grep -Eiq 'X-MacProvider-|provider_id|route_id' /tmp/ac34-error.txt && sed -n '/^{/,$p' /tmp/ac34-error.txt | jq -e '.error.type == "api_error" and .error.code == "upstream_provider_error"'`

Go verification: `go test ./phase5-gateway/... -run TestProviderPinningHeadersStripped`

### AC-35: demo token forgery rejected

Precondition:

- Gateway has `auth.demo.signing_secret` configured.

Action:

1. Obtain a valid token from `POST /auth/demo-session`.
2. Mutate the payload or signature.
3. Replay the valid token from a different IP or after expiry.

Expected outcome:

- Valid token returns HTTP 200 on allowed demo request or HTTP 201 from `POST /auth/demo-session` with JSON containing `demo_token` and `expires_at`.
- Forged, cross-IP, and expired tokens return HTTP 401 with JSON `{"error":{"type":"authentication_error","code":"invalid_demo_token"}}`.

Verification command:

```text
curl -i -X POST https://api.streamvc.live/auth/demo-session
go test ./phase5-gateway/... -run TestDemoTokenValidation
```

### AC-36: quota refund on 504 with zero completion tokens

Precondition:

- Account quota is small and coordinator can simulate provider timeout after prompt processing with zero completion tokens.

Action:

1. Send a request that reserves quota and receives 504 with zero completion tokens.
2. Query `/v1/usage`.

Expected outcome:

- Timeout response is HTTP 504 with OpenAI error envelope `type: "api_error"` and `code: "provider_timeout"`.
- `/v1/usage` returns HTTP 200 and shows prompt tokens debited, completion tokens unchanged, and reservation released.

Verification command:

```text
curl -i -H "Authorization: Bearer <key>" https://api.streamvc.live/v1/usage
go test ./phase5-gateway/... -run TestQuotaSettlement504ZeroCompletion
```

### AC-37: streaming quota reservation and settlement

Precondition:

- Gateway is running with the default 100,000-token daily quota.
- One v1.2.4+ provider and one pre-v1.2.4 provider are available in the pool, or both provider behaviors can be simulated deterministically.

Action:

1. Start a streaming request with `stream=true` and `max_tokens=200`.
2. Verify quota reservation before first upstream byte.
3. Complete the stream with provider-reported actual usage.

Branches:

- Branch A, v1.2.4+ provider actuals:
  - Action: route the same streaming call to the v1.2.4+ provider; buyer disconnects after receiving about 30 completion tokens, about 120 bytes.
  - Expected: buyer stream starts with HTTP 200 and `Content-Type: text/event-stream; charset=utf-8`; gateway sends `cancel_request`; provider `inference_response_end` has `status:"cancelled"` and `usage={prompt_tokens:N, completion_tokens:30, total_tokens:N+30}`; `/v1/usage` returns HTTP 200 with daily quota decremented by exactly `N+30`.
  - Verification: `curl -i -N -X POST -H "Authorization: Bearer <key>" -H "Content-Type: application/json" -d '{"model":"<model>","stream":true,"max_tokens":200,"messages":[{"role":"user","content":"count slowly"}]}' https://api.streamvc.live/v1/chat/completions & sleep 2 && kill %1; curl -s -H "Authorization: Bearer <key>" https://api.streamvc.live/v1/usage | jq -e '.daily_used == <expected_exact>'`
- Branch B, pre-v1.2.4 provider fallback estimation:
  - Action: route the same streaming call to the pre-v1.2.4 provider; buyer disconnects after about 120 bytes of SSE chunk content.
  - Expected: buyer stream starts with HTTP 200 and `Content-Type: text/event-stream; charset=utf-8`; gateway sends `cancel_request`; provider `inference_response_end` has `status:"cancelled"` and omits `usage`; gateway estimates `ceil(120/4) = 30` completion tokens; `/v1/usage` returns HTTP 200 with daily quota decremented by `N+30`, with +/-5 token tolerance acknowledged for real text.
  - Verification: `curl -i -N -X POST -H "Authorization: Bearer <key>" -H "Content-Type: application/json" -d '{"model":"<model>","stream":true,"max_tokens":200,"messages":[{"role":"user","content":"count slowly"}]}' https://api.streamvc.live/v1/chat/completions & sleep 2 && kill %1; curl -s -H "Authorization: Bearer <key>" https://api.streamvc.live/v1/usage | jq -e '.daily_used >= <expected_estimated_minus_5> and .daily_used <= <expected_estimated_plus_5>'`

Expected outcome:

- Concurrent requests cannot oversubscribe the daily quota during the stream.
- Successful stream returns HTTP 200 with `Content-Type: text/event-stream; charset=utf-8`, emits `data: {json}\n\n` chunks followed by `data: [DONE]`, and settles to provider-reported usage subject to the § 7.2 symmetric clamp (#255 downward + #278 upward). The symmetric clamp shares the same `2 < overshoot ≤ 20` pure-absolute window in both directions but settles in opposite directions: downward gaps (reported > observed, in window) clamp DOWN to observed with `token_source = "gateway_estimated"`; upward gaps (observed > reported, in window) clamp UP to reported with `token_source = "provider_reported"`.
- Branch A releases concurrency and records usage source as `provider_reported` in two cases: (i) NO clamp fires (overshoot ≤ 2 in either direction, or > 20 downward), or (ii) the #278 upward clamp fires in-window (gateway estimate was inflated; provider tokenizer wins).
- Branch B releases concurrency and records usage source as `gateway_estimated` in two cases: (i) the #255 downward clamp fires in-window (provider over-reported; gateway estimate wins), or (ii) upward case with `overshoot > 20` (likely stream truncation / zero-report fraud; gateway estimate wins).
- `/v1/usage` returns HTTP 200 with reservation released and daily token fields reflecting settlement.

Verification command:

```text
go test ./phase5-gateway/... -run TestStreamingQuotaReservationSettlement
```

### AC-NULL-USAGE-REFUND: null-usage errors refund full reservation

Precondition:

- Account quota is small and coordinator can simulate both a SPEC-001 null-usage error and a non-null 502/504 zero-completion failure.

Action:

1. Send a request that reserves quota and receives HTTP 502 backed by SPEC-001 `error_model_not_loaded` with NULL usage.
2. Query `/v1/usage`.
3. Send a separate 502 zero-completion fixture that is not a SPEC-001 null-usage error.
4. Query `/v1/usage` again.

Expected outcome:

- The SPEC-001 null-usage error releases the full reservation and debits 0 prompt and 0 completion tokens.
- The non-null 502 zero-completion fixture debits prompt only per § 17.7.

Verification command:

```text
go test ./phase5-gateway/... -run TestNullUsageErrorRefundsReservation
```

---

## 19. Audit categories

SPEC-006 inherits SPEC-002 audit discipline and adds gateway-specific categories.

Required audit categories:

- A: identity correctness.
- B: API key secrecy.
- C: quota arithmetic.
- D: concurrency reservation lifecycle.
- E: rate-limit header accuracy.
- F: kill-switch activation latency.
- G: OAuth flow correctness.
- H: demo-token abuse resistance.
- I: provider transparency and header scrubbing.
- J: OpenAI compatibility.
- K: streaming cancellation.
- L: append-only storage invariants.
- M: sub-ms auth lookup evidence.
- N: capacity-tier mechanical execution.
- O: feedback idempotency and aggregation.
- P: front-door contract correctness.
- Q: docs completeness.
- R: no payment/donation leakage.
- S: coordinator charter preservation.
- T: integration tests for real user-shaped web/API paths.
- U: SPEC-003 v0.7 shell-script integration category inheritance: shell-script paths that touch real OS resources such as tty, file descriptors, ports, filesystem layout, or JSON over loopback need integration tests that actually exercise them, not code review alone. This applies to gateway operational scripts for deployment, backup, and kill-switch toggling via shell.
- V: sticky affinity account isolation, lifecycle, and disclosure parity when `routing.sticky_enabled: true`.
- Y: expectation drift between roadmap and current enforcement.

Category Y means SPEC-006 documents future Tier 2 capabilities, including hardware attestation, encrypted provider execution, and model catalog enforcement, as roadmap targets. Audit cycles MUST verify that spec text, front-door copy, API docs, error messages, and external positioning material do NOT promise these capabilities as currently shipping.

The discipline is:

- Tier 1 properties are normative.
- Tier 2 properties are roadmap: out of scope, but discussable as future.
- Anything that conflates the two is a MAJOR finding.

Reference: 2026-05-29 independent security audit H-001. The language "Your prompts never touch AWS, GCP, or Azure" is technically true but invites buyers to infer providers cannot see prompts. Both Tier 1 and Tier 2 statements must hold simultaneously; either-or framing is the drift class to catch.

Audits MUST explicitly check configured and unconfigured branches for production gates.

This inherits the SPEC-002 v1.1.4 anti-pattern lesson: an always-non-nil gate can look tested while the configured branch is broken.

When `routing.sticky_enabled: true`, audits MUST verify sticky disclosure parity everywhere the § 1.6 disclosure appears: the signup flow, single-page docs, `/v1/models tier1_disclosure.sticky_affinity`, and any operator-distributed SDK README. Audits MUST also verify the default branch: with `routing.sticky_enabled: false`, no sticky key is derived or forwarded, no sticky-specific buyer-visible privacy posture is implied, and v0.7 buyer-visible behavior is preserved.

---

## 20. Operator questions

Most decisions are locked.

The following implementation details remain genuinely open:

1. Which email provider, if any, has the lowest practical free-tier operator cost for v1 magic links?
2. Should `/account` be served by the gateway or entirely by the Vercel front door using gateway JSON endpoints?
3. Should token estimation use a lightweight tokenizer package in Go or a deterministic byte/word heuristic until provider usage is reliable?
4. Should runtime kill-switch toggling use config file reload, SQLite runtime config, or an operator admin endpoint first?
5. What exact public copy should the beta-paused and signup-closed states use?

These questions do not block the normative architecture.

They MUST NOT reopen the locked decisions in Section 2.

---

## 22. Production launch gate checklist

Adapted from the 2026-05-29 independent security audit's "Production Gate Recommendations" section.

The operator MUST execute all 9 items before SPEC-006 v0.8 is deployed to production with public buyer access at `api.streamvc.live`. PG-9 is conditional and applies before, not after, flipping `routing.sticky_enabled: true` in production.

1. Provider tokens MUST be mandatory in production. [SPEC-002 v1.1.5 § 7.X PG-1]
2. Provider WebSocket endpoints MUST be shielded by proxy-level rate limits and connection caps. [SPEC-002 v1.1.5 § 7.X PG-2]
3. The public gateway MUST expose only buyer API endpoints; it MUST NOT expose coordinator internals. [SPEC-002 v1.1.4 § 7 nginx routing block]
4. Advertised provider concurrency MUST equal enforced runtime concurrency. [SPEC-001 v1.2.4]
5. Model identity MUST be either cryptographically verified or clearly labeled as provider-reported. [§ 5.3 above]
6. Buyer disconnect, provider disconnect, timeout, and cancellation MUST produce exactly one accounting outcome. [§ 7.2 + § 17 in v0.5; SPEC-001 v1.2.3 § 6.6 cancel-usage]
7. Tier 1 documentation MUST clearly state that provider-side prompts are plaintext to the provider runtime. [§ 1.6 above]
8. Any privacy, attestation, or hardware-trust claim MUST be blocked until Tier 2 enforcement is live. [§ 1.6 above]
9. Sticky affinity disclosure parity MUST be complete before `routing.sticky_enabled` is set to `true` in production: the v0.8 § 1.6 and § 5.3.1 sticky disclosure language MUST appear in (a) the signup flow, (b) the single-page docs, (c) `/v1/models tier1_disclosure.sticky_affinity`, and (d) any SDK README the operator distributes. Operators who keep `routing.sticky_enabled: false` do NOT need to surface sticky-specific language. [§ 1.6 + § 5.3.1 above]

This checklist is the operator-side counterpart to SPEC-006 v0.8's spec-side disclosure language. Together they implement the audit's recommendation: keep Tier 1 narrow, explicit, and operationally hardened, while treating provider-private prompts, attestation, model integrity, sticky privacy disclosure, and marketplace-grade settlement as separate launch gates.
