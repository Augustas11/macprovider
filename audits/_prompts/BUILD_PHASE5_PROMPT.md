# Build prompt — Phase 5 buyer-API gateway implementation

Operator-paste prompt to implement the Go buyer-API gateway against the
locked spec corpus:

  SPEC-001 v1.2.3 — phase3-binary provider protocol
  SPEC-002 v1.1.4 — phase4-coordinator router
  SPEC-003 v0.6   — open onboarding + distribution
  SPEC-006 v0.5   — buyer API gateway (THIS implementation)

All 9 operator pre-commitments (D1/D2/D3 + D-CROSS-1 through D-CROSS-6)
are encoded in spec text. This prompt does NOT relitigate design — it
implements what the spec already specifies.

Output: working Go gateway in `phase5-gateway/` (compiles, passes 37
ACs from SPEC-006 v0.5 § 18, deploys alongside coordinator on Pearl VPS).

Run in **Claude Code** (Sonnet recommended for code volume; Opus for
the trickier auth + quota + streaming-reservation paths). Expected
duration: **~7-10 days of focused work**, broken into 5 phases with
checkpoint reports for incremental review.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are implementing the Mac Provider buyer-API gateway in Go,
following SPEC-006 v0.5 normatively. The spec is locked; your job
is to make code that matches it.

You will produce:
  /Users/augstar/macprovider-poc/phase5-gateway/  (new Go module)

Including:
- cmd/gateway/main.go — entrypoint, config loading, signal handling
- internal/auth/ — OAuth (GitHub + optional email magic link),
  bearer-token validation, key issuance, HMAC demo tokens
- internal/quota/ — reservation ledger, atomic decrement,
  prefer-actuals streaming settlement with byte-estimation fallback
- internal/feedback/ — POST /v1/feedback endpoint, scope handling,
  /admin/feedback-summary aggregation
- internal/storage/ — `AuthStore` / `UsageStore` / `FeedbackStore`
  Go interfaces; concrete SQLite implementation
- internal/coordinator/ — /poolz consumption, status redaction,
  buyer-API forwarding
- internal/capacity/ — Tier 1/2/3 escalation, signal measurement
- internal/router/ — chi or net/http handlers; OpenAI-compatible
  routing
- internal/middleware/ — X-Request-ID generation, panic recovery,
  request logging, header strip (inbound + outbound)
- gateway.yaml.example — full config schema
- README.md — local dev + deployment instructions
- tests/ — integration tests covering all 37 ACs

## Critical constraints

**1. The spec is the design.** Do NOT propose alternative designs.
If you find an ambiguity, file as an operator question in the
phase-end handback summary; do NOT decide unilaterally.

**2. SPEC-001 v1.2.3, SPEC-002 v1.1.4, SPEC-003 v0.6 are locked
upstream specs.** Do NOT propose changes. If integration requires
upstream changes, file as a candidate finding in the handback.

**3. The gateway runs alongside coordinator on Pearl VPS.** Do NOT
push auth/quota/billing into the coordinator. Per SPEC-002 v1.1.3
§ 1, coordinator stays "router-only."

**4. SQLite is the v1 storage implementation.** Per D1, v1 is
single-gateway-instance. The storage layer MUST be abstracted via
Go interfaces so future PostgreSQL / Cloudflare D1 / Workers KV
migrations need no handler-code changes.

**5. Stateless handlers.** No in-process rate limit counters, no
in-process quota state, no in-process session cache. All state in
storage layer.

**6. Append-only schema in hot paths.** Usage events, audit events,
feedback events all append-only. No UPDATE statements in
performance-critical code.

**7. Sub-millisecond auth check at p95.** Schema and indexing MUST
support this. Profile the auth path and tune.

**8. Backward-compat for pre-v1.2.4 providers (M4 + M1).** Per
SPEC-006 v0.5 § 7.2, streaming-disconnect settlement prefers
provider-reported actuals when present, falls back to
`ceil(bytes_emitted_so_far / 4)` estimation when absent.

**9. d-inference clean-room.** Do not inspect d-inference source.

**10. No premium positioning.** The spec already locks "no buyer
personas, no premium pricing" — do not introduce them in error
messages, documentation, or marketing copy.

## Required reading

In order:

1. `specs/SPEC-006-buyer-api.md` v0.5 — full document (~2,968 lines,
   20 sections, 37 ACs). This is your implementation contract.

2. `specs/SPEC-001-phase3-binary.md` v1.2.3 — § 6.2 (/v1/models
   response shape, unescaped slashes), § 6.4 (chat completions
   request shape, case-insensitive model match), § 6.6 (WS-tunneled
   inference messages including cancel-usage in v1.2.3).

3. `specs/SPEC-002-coordinator.md` v1.1.4 — § 3 (mode resolution),
   § 5 (routing), § 7.1 (auth modes), § 7.5 (operator endpoints
   including /v1/pool/check, /poolz with summary block, degraded
   boolean rules per F-602-3), § 4 FR-B1 (degraded boolean
   normative definition).

4. `specs/SPEC-003-open-onboarding.md` v0.6 — § 4 (distribution-
   channel decoupling, useful for the gateway's own deployment
   thinking), § 5 (installer cross-references).

5. `specs/BUILD_SPEC_006_PROMPT.md` — operator's pre-commitments
   header. SPEC-006 § 2 mirrors this verbatim; both are the locked
   inputs.

6. `specs/SPEC-CROSS-006-audit.md` — both rounds. Helpful for
   understanding the boundary contracts between gateway and
   coordinator.

7. `beta/DECISION_CRITERIA.md` Entries 18 through 22 — production
   context, audit-pattern lessons, capacity-burst rationale.

8. `phase4-coordinator/internal/buyer/server.go` — actual
   coordinator buyer HTTP handler the gateway will forward to.
   Verify the forward path is realistic before writing.

9. `phase4-coordinator/internal/poolz/` (if it exists) — the
   /poolz handler the gateway consumes for /v1/status.

10. `phase4-coordinator/cmd/coordinator/main.go` + `internal/ws/`
    — understand the upstream so forwards stay aligned.

11. `beta/web/` (if it exists) — the existing Vercel demo that
    becomes the SPEC-006 v0.5 front door. The gateway exposes
    the contract this front door consumes. (Frontend changes are
    OUT OF SCOPE for this prompt — only the gateway-side contract
    must be implemented correctly.)

## Implementation phases (with checkpoint reports)

After each phase, print a handback summary covering: what shipped,
test coverage, open questions, next phase's first task. Stop, wait
for operator review, resume when they say "continue."

### Phase A — Scaffolding + storage interfaces (Day 1)

Goals:
- Initialize Go module `phase5-gateway/` with reasonable package
  layout
- Define `AuthStore`, `UsageStore`, `FeedbackStore`, `AuditStore`
  Go interfaces in internal/storage/
- Concrete SQLite implementations behind each interface
- Schema design with explicit indexes for sub-ms auth lookups
- Append-only constraints enforced at schema level where possible
- `gateway.yaml.example` with all config fields populated
- `cmd/gateway/main.go` entrypoint that loads config, opens
  storage, and exits cleanly (no handlers yet)
- README.md skeleton with local-dev instructions

Phase A deliverables checklist:
- [ ] `go build ./...` succeeds
- [ ] `go test ./internal/storage/...` covers basic CRUD + ledger
  semantics (>=80% coverage)
- [ ] Schema migration applies cleanly to a fresh SQLite file
- [ ] Auth lookup measured under 1ms p95 against 10K-account fixture

Checkpoint report A. STOP. Wait for operator review.

### Phase B — Auth + identity (Days 2-3)

Goals:
- GitHub OAuth flow per SPEC-006 v0.5 § 6.1
  - State parameter generation (>=128-bit CSPRNG, session-bound)
  - Strict callback URL allowlist from `gateway.yaml`
  - Scope minimization (`read:user` + optional `user:email`)
  - Account creation on first successful callback
- Email magic link via Resend (if free tier configured) per § 6.1
  - Fall back gracefully if Resend not configured (defer to v0.2)
- Bearer token issuance per § 6.4
  - `mp_` prefix
  - >=256-bit CSPRNG entropy before base64url
  - SHA-256 or HMAC-SHA-256 hash storage
  - Full key shown once at issuance
- Token validation middleware per § 6.5
  - Sub-ms p95 against the storage layer
  - 401 envelope on invalid/missing per § 17.x
- Token revocation per § 6.6
  - Bounded latency <60s
  - Audit event written per § 14.3
- Key rotation preserves usage history per F-m2-5
- Demo token HMAC mechanism per D2 / F-M14
  - HMAC-SHA256 with operator-secret + client IP + expiry
  - `POST /auth/demo-session` rate-limited 10/IP/hour
  - Validation middleware for `X-Demo-Token` header

Phase B deliverables checklist:
- [ ] OAuth flow tested end-to-end against a test GitHub app
- [ ] Bearer token issuance/validation/revocation passes ACs
  AC-2 through AC-6, AC-27, AC-31
- [ ] Demo token forgery rejected per AC-35
- [ ] OAuth CSRF defense tested per AC-29
- [ ] OAuth scope minimization tested per AC-30
- [ ] Sub-ms auth check confirmed under load

Checkpoint report B. STOP. Wait for operator review.

### Phase C — Quota + streaming + buyer surface (Days 4-5)

Goals:
- Quota reservation ledger per § 7.2 + F-M6
  - `BEGIN IMMEDIATE` transaction for SQLite v1
  - Reservation row keyed by (account_id, request_id)
  - Settlement to actual usage on completion
- Streaming-aware quota per § 7.2 + D-CROSS-1 (v0.5)
  - Reserve `max_tokens` (or per-request cap) before forwarding
  - On 200: settle to actual usage from provider response
  - On 503 (no provider reached): no debit, refund reservation
  - On 502/504 with 0 completion: prompt only
  - On 502/504 with partial: prompt + actual
  - On client disconnect:
    - If `usage` present in provider's
      `inference_response_end` (v1.2.4+ provider): settle to
      actual completion tokens (exact)
    - If `usage` absent (pre-v1.2.4 provider): fall back to
      `ceil(bytes_emitted_so_far / 4)` estimation
- Rate-limit headers per § 5.1 + § 7.3
  - `X-RateLimit-Limit`, `X-RateLimit-Remaining`,
    `X-RateLimit-Reset` (Unix timestamp)
  - Post-decision values
- Buyer endpoint forwards:
  - `POST /v1/chat/completions` to coordinator buyer port
    (configured per `coordinator.buyer_url`)
  - `GET /v1/models` aggregated from coordinator
  - Streaming SSE pass-through `data: {json}\n\n` framing
    explicit per F-m2-9
- Inbound header strip per F-M21 / F-606-1
  - Strip `X-MacProvider-Provider`, `X-MacProvider-Session`,
    undocumented `X-MacProvider-*` BEFORE auth
- Outbound header strip per F-606-1
  - Strip `X-MacProvider-Provider`, `X-MacProvider-Route` from
    coordinator responses
- X-Request-ID generation per D-CROSS-3
  - UUID v4 per buyer-incoming request
  - Forward as `X-Request-ID` header to coordinator
  - Include in usage_events, audit_events rows
- Supported request fields per F-M2: `n` (MUST be 1 in v1),
  `stream_options.include_usage`, `user` (opaque), `logprobs`
  (forwarded with unknown-field tolerance per D-CROSS-6)
- Case-insensitive model match per SPEC-001 v1.2.3 § 6.4
  preserved through gateway
- JSON `\/` and `/` tolerance in /v1/models per SPEC-001 v1.2.3 § 6.2

Phase C deliverables checklist:
- [ ] AC-37 (streaming reservation + settlement) Branch A and B
  both pass
- [ ] AC-36 (quota refund on 504 zero completion) passes
- [ ] AC-34 (provider-pinning header strip, both directions) passes
- [ ] AC-33 (feedback summary aggregation shape) — wait for Phase D
- [ ] AC-26 OAuth callback enforcement — done in Phase B
- [ ] OpenAI Python SDK + JS SDK drop-in test passes
- [ ] Streaming SSE framing matches OpenAI exactly
- [ ] Concurrent-request quota arithmetic test (10 concurrent
  near-limit requests, no overshoot beyond ~max_tokens_per_request)

Checkpoint report C. STOP. Wait for operator review.

### Phase D — Status, feedback, capacity tiers, kill switches (Days 6-7)

Goals:
- `GET /v1/status` per § 5.6 + § 12.2 + F-M19
  - Consume coordinator `/poolz` from `coordinator.operator_url`
    with `coordinator.operator_key`
  - 10s cache TTL; flush on coordinator-not-reachable
  - Redact: stable provider IDs, hostnames, RAM/CPU, operator
    identity
  - Expose: model list, provider_count, total_slots, slots_free,
    per-state aggregate counts, degraded boolean (computed per
    SPEC-002 v1.1.4 § 4 FR-B1)
- `POST /v1/feedback` per § 5.7 + F-M11
  - Bearer or demo-token auth per scope:
    - `request`/`session`/`account` → bearer required
    - `playground` → demo token required
  - Schema: rating 1-4, comment <=2000 bytes, request_id, scope
  - Stored XSS defense per F-M20 (treat comment as untrusted at
    output time)
- `GET /v1/usage` per § 5.5
  - Daily window state per § 7.2
  - Rate-limit headers reflect post-decision values per F-m2-3
- `GET /admin/feedback-summary` per § 11.5 + F-M12
  - 7d and 14d window aggregation
  - by_scope breakdown
  - Comment samples (top 20 most recent non-empty)
  - Iteration trigger calculation per F-M13 (7d share of 1-2
    ratings > 40% with >=20 events)
- Capacity tier escalation per § 10 + F-M9 + F-M10
  - Signal measurement (CPU via /proc/stat or host_processor_info,
    memory via /proc/meminfo, bandwidth via nginx logs, provider
    feedback via /admin/provider-feedback, cost projection vs
    capacity.monthly_budget_usd, provider drops via /poolz delta,
    operator load via /admin/operator-load)
- Cron job or in-process monitor at 10s/60s/hourly cadences per
  signal table
- Tier escalation: Tier 0 → 1 → 2 → 3 with thresholds per § 10.2
- Tier de-escalation per F-M10 with 1h cooldown default
- Kill switches per § 9 + F-M8
  - `kill_switch.demo_only` and `kill_switch.all_public_api`
  - <5s activation MUST per F-M8
  - Persist to `gateway.yaml` on admin endpoint mutation
  - SIGHUP fallback for file edits
- Audit logging per § 14.3 + F-M17
  - All kill switch toggles, quota changes, key
    revocations/regenerations, account blocks, capacity tier
    transitions, budget cap mutations

Phase D deliverables checklist:
- [ ] AC-28 kill switch persistence across restart passes
- [ ] AC-32 capacity tier de-escalation passes
- [ ] AC-33 feedback summary shape passes
- [ ] /v1/status redaction verified — no provider hostnames or
  IDs in any buyer-facing response
- [ ] /poolz cache TTL respected; flush-on-unreachable verified
- [ ] Audit log contains all required event types

Checkpoint report D. STOP. Wait for operator review.

### Phase E — Integration test + deployment + docs (Days 8-10)

Goals:
- End-to-end integration test against a local coordinator + a mock
  provider (or real Llama 3B provider if convenient)
- Stranger-shaped key issuance test — sign up, get key, paste into
  OpenAI SDK, send chat, get response, check /v1/usage
- Quota exhaustion test — burn through 100K tokens, verify 429 +
  correct rate-limit headers
- Provider-unavailable test — kill coordinator/provider, verify
  503 + meaningful error envelope
- Streaming-cancel test — start stream, kill client mid-stream,
  verify upstream cancel within bound + quota settled correctly
  (actuals path with v1.2.4+ provider, estimation path with mock
  pre-v1.2.4 provider)
- Capacity tier trigger test — simulate CPU >70% via stress, verify
  Tier 1 activation
- Deployment manifest: systemd unit file or equivalent for Pearl
  VPS (mirroring phase4-coordinator/dist/macprovider-coordinator.service)
- nginx config block for the gateway/coordinator path split per
  SPEC-002 v1.1.4 § 7 (the routing block already specified in the
  spec — implement the nginx side)
- `gateway.yaml.example` reviewed against actual config usage
- README.md complete with: local dev setup, deployment to Pearl,
  troubleshooting playbook
- All 37 ACs from SPEC-006 v0.5 § 18 passing (or documented
  exceptions)

Phase E deliverables checklist:
- [ ] All 37 ACs run as automated tests or have documented manual
  verification
- [ ] systemd unit file deploys + survives reboot on Pearl
- [ ] nginx config tested in dry-run mode (`nginx -t`)
- [ ] OpenAI Python SDK + JS SDK drop-in confirmed against deployed
  gateway
- [ ] /v1/status served correctly through nginx
- [ ] /poolz consumption uses correct port (8444) and operator key
- [ ] Documentation complete

FINAL handback summary. STOP.

## Self-verification checklist (across all phases)

- [ ] Every spec section in SPEC-006 v0.5 that's normative has a
  corresponding code path implementing it.
- [ ] No upstream spec edits (SPEC-001 v1.2.3, SPEC-002 v1.1.4,
  SPEC-003 v0.6 stay untouched).
- [ ] No SPEC-006 edits — the spec is locked.
- [ ] All 9 operator pre-commitments (D1/D2/D3 + D-CROSS-1 through
  D-CROSS-6) preserved in code behavior.
- [ ] All 37 ACs pass (or operator-approved exceptions documented).
- [ ] No buyer-visible secrets (provider IDs, hostnames, operator
  keys, signing keys).
- [ ] No premium positioning in code, errors, or docs.
- [ ] No Tier-3 deprecation logic (operator chose iteration).
- [ ] User-feedback rating mechanism captures via both API
  endpoint (B) and dashboard-widget contract (C).
- [ ] OpenAI Python + JavaScript SDKs work drop-in against
  `https://api.streamvc.live/v1` with `api_key = "mp_..."`.
- [ ] Pre-v1.2.4 provider compatibility verified via mock provider
  that omits `usage` in cancel-response.

## What you must NOT do

- Do NOT optimize the spec. The spec is locked through 4 audit
  cycles plus 53 closed findings.
- Do NOT add features beyond what the spec requires (no "wouldn't
  it be nice" additions).
- Do NOT propose a different architecture if you find the gateway
  pattern awkward — it's the locked decision.
- Do NOT push state into the coordinator (it's router-only).
- Do NOT bundle billing/Stripe/payment code (deferred per
  operator pre-commitments).
- Do NOT introduce buyer personas, marketing copy, or premium
  framing.
- Do NOT change provider partner upgrade paths (they're handled
  separately, not by the gateway).
- Do NOT skip the AC verification.
- Do NOT continue past phase checkpoints without operator review.

## When you finish

Print the FINAL handback summary (~300 words) covering:
- Architecture as built (file/package layout, key abstractions)
- All 37 AC pass/fail status
- Deployment artifacts produced
- Any operator questions surfaced during implementation
- Any known limitations (e.g., "pre-v1.2.4 estimation path
  reproduces ±5 token error per SPEC-006 v0.5 § 17 acknowledgement")
- Suggested next steps:
  - Production deployment runbook
  - Cross-spec audit on the deployed gateway (new pattern)
  - Eventual SPEC-006 v0.6 candidate (remove estimation fallback
    once all providers are v1.2.4+)
- Filed for SPEC-003 v0.7 (separate cycle, NOT in this prompt):
  the 6 install.sh findings from M4's v1.2.4 upgrade.

Then stop. Do NOT begin production deployment without operator
authorization.

=== END PROMPT ===
```

---

## After running this prompt

The prompt is designed for 5 checkpoint-style phases (~7-10 days total
elapsed). After each phase, you'll get a handback summary; review and
say "continue" to resume into the next phase.

### Operator's per-phase review checklist (~10 min each)

**After Phase A (scaffolding):**
- Storage interface signatures match what the spec implies
- SQLite schema designed for migration to PostgreSQL/D1 (no
  SQLite-specific column types in surface API)
- `go test ./internal/storage/...` reports >=80% coverage
- README scaffolds the deployment story

**After Phase B (auth):**
- OAuth flow works against your test GitHub app
- Bearer keys round-trip cleanly
- AC-27, AC-29, AC-30 all pass automated tests

**After Phase C (quota + streaming):**
- AC-37 both branches (v1.2.4+ actuals and pre-v1.2.4 estimation)
  pass
- Concurrent-quota race test passes (10 parallel requests, no
  overshoot)
- OpenAI Python SDK smoke test against the gateway works

**After Phase D (status + capacity + feedback):**
- /v1/status served correctly with redaction
- Kill switch toggles take effect <5s
- Feedback summary aggregation produces correct shape

**After Phase E (integration + deployment):**
- All 37 ACs reported with status
- Deployment manifest + nginx config drafted (deploy is separate)
- Documentation complete

### What gets deployed

Phase E produces a runnable Go gateway + deployment artifacts. **Actual
production deployment is a separate operator-authorized step** — NOT
part of this prompt's scope. After Phase E handback, decide:

- **Deploy to Pearl VPS** alongside the existing coordinator with
  nginx routing for path split per SPEC-002 v1.1.4. ~30 min operator
  work.
- **Self-canary the gateway** against your own API key + a small
  manual test before exposing it publicly. ~60 min.
- **Cross-spec implementation audit** — review the gateway code
  against the spec corpus, same pattern as the SPEC-006 v0.1 audit
  but pointed at code instead of spec text. Codex + Claude rounds,
  ~2-3 hours per round.

After whatever level of pre-launch verification you want, set DNS for
`api.streamvc.live`, flip the `kill_switch.demo_only` to off, and
SPEC-006's user-rating instrumentation begins producing the data the
falsification framework (§ 6 of `specs/SPEC-006-design.md`) needs to
either validate or invalidate the product hypothesis over the next 90
days.

The spec-design phase ends; the product-validation phase begins.
