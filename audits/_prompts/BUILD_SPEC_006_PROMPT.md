# Build prompt — SPEC-006 v0.1

Operator-paste prompt that drafts the normative SPEC-006 (Mac Provider's
first buyer-facing surface) against the locked design choices captured
below. The design exploration was completed in a previous run; its
output is at `specs/SPEC-006-design.md`. This prompt does NOT relitigate
the design — it locks the operator's decisions and asks a fresh session
to produce the spec.

Run in **Claude Code** or **Codex**. Expected duration: ~3-4 hours for a
thorough first draft. Output is `specs/SPEC-006-buyer-api.md` v0.1 plus
appended notes in `phase5-gateway/implementation-notes.html` (create the
directory if needed).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are drafting SPEC-006 v0.1, the normative specification for Mac
Provider's first buyer-facing surface. The design exploration is
complete at `specs/SPEC-006-design.md` and the operator has locked
specific decisions below. Your job is to convert those locked
decisions into a normative spec with the same rigor as SPEC-001 v1.2.2
and SPEC-002 v1.1.3.

Output location:
  /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md

Target length: ~1500-2500 lines. Same structural rigor as SPEC-002
v1.1.3. Numbered sections, MUST/SHOULD/MAY normative language per RFC
2119, explicit acceptance criteria with deterministic verification
steps, change log header.

You are NOT writing code in this run. You are writing the spec. A
separate BUILD_PHASE5_PROMPT.md (or BUILD_PHASE6) will drive the
implementation work AFTER the spec is audited and locked.

## Locked design choices (operator pre-commitments)

These are normative inputs. Do NOT relitigate them. Do NOT propose
alternatives. They are the answers to the ten questions in
`specs/SPEC-006-design.md` Section 5, decided.

### Architecture

- **Separate Go gateway service** at `phase5-gateway/` (consistent with
  the existing `phase3-binary/`, `phase4-coordinator/`, `phase5-onboarding/`
  naming). Binds its own port; separate systemd unit; its own
  deployment artifact.
- **Coordinator stays router-only.** SPEC-002 v1.1.3's "coordinator is a
  router" charter is preserved. Coordinator's buyer port (currently
  bound `0.0.0.0:8443`) MUST be rebound to `127.0.0.1:8443` as part of
  this migration. All public `/v1/*` traffic goes through gateway.
- **Designed for 10K-Mac scale.** Specifically:
    - Stateless request handlers. No in-process rate-limit counters,
      no in-process session caches, no in-process quota state.
    - Data layer abstracted behind a Go interface (`AuthStore`,
      `UsageStore`, etc.). Concrete v1 implementation: SQLite at Pearl
      VPS. Migration targets (Cloudflare D1, PostgreSQL, Workers KV)
      MUST require zero changes outside the storage package.
    - Schema designed for global replication. API keys MUST be
      immutable once issued. Usage events MUST be append-only with
      monotonic timestamps. No row updates in the hot path.
    - Coordinator backend MUST be a configurable list, not a hardcoded
      URL. v1 has one entry (`http://127.0.0.1:8443`); future entries
      will be regional coordinators.
    - No long-lived TCP connections in gateway. Each buyer HTTP request
      is one-shot. SSE streams flow through but the gateway handler
      is request-scoped (no shared goroutines holding socket state
      across requests).
    - Sub-millisecond auth check. Bearer token validated by indexed
      single-key lookup in the store.

### Public API surface

- Canonical buyer URL: `https://api.malibu.tech`.
- Internal coordinator URL: `https://coordinator.malibu.tech` stays
  in service for M4/M1 legacy direct-tunnel buyer paths and operator
  endpoints (`/admin/*`, `/poolz`, `/healthz`).
- Endpoints exposed at `api.malibu.tech`:
    - `GET /v1/models`
    - `POST /v1/chat/completions` (including SSE streaming via
      `stream: true`)
    - `GET /v1/usage`
    - `GET /v1/status`
    - `POST /v1/feedback`
    - OAuth callbacks at `/auth/github/callback` (and
      `/auth/email/callback` if email magic link is implemented)
    - Signup/key-management UI at `/account` (or operator-chosen path
      consistent with the Vercel demo's structure)
- Endpoints NOT exposed at `api.malibu.tech` (kept internal):
    - `/admin/*`, `/poolz`, `/healthz`, `/ws/provider` — all remain on
      coordinator port

### Identity

- **GitHub OAuth is the primary identity method.** Web-app credentials,
  one-click flow, account created on first successful callback.
- **Email magic link is the secondary method** if it can be implemented
  cheaply on a free tier (Resend, SendGrid, Postmark; choose whichever
  has the lowest operator-onboarding cost). If no free tier is
  practical for v1, defer email magic link to v0.2 and ship GitHub
  OAuth only.
- One account per identity. Multiple API keys per account permitted
  (default: one active key on signup, regeneration/revocation
  available).
- Key shape: prefix `mp_`, followed by high-entropy random secret.
  Server stores only a hash (SHA-256 or HMAC). Full key shown once at
  issuance, never re-displayable.

### Quotas

- **Default daily quota: 100,000 total tokens per account per day.**
  Adjustable in `gateway.yaml` without code change.
- **Unauthenticated demo quota: 1,000 total tokens per IP per day.**
  Demo traffic is allowed via specific endpoints (chat playground
  through front door) and a tiny `X-Demo-Token` header sourced from
  the Vercel demo's session cookie.
- **Per-account concurrency cap: 2 concurrent requests** at v1.
  Adjustable.
- **Per-IP signup issuance: 3 accounts per IP per day** (Sybil
  defense).
- **Per-request `max_tokens` cap: 4,096** at v1. Adjustable.

### Provider transparency

- Buyers see: model identifiers, `provider_count`, `total_slots`,
  `max_context_tokens`, aggregated degraded state.
- Buyers do NOT see: stable provider IDs (`m4-anon`,
  `augustass-macbook-air`, etc.), hostnames, IP addresses, geographic
  location of providers.
- Provider metadata in `/v1/models` MUST be aggregated. If 3 providers
  serve the same model, the buyer sees one entry with
  `provider_count: 3`, not three entries.

### Status transparency

- `GET /v1/status` returns:
    - Coordinator health (up/degraded/down)
    - List of available models with current `provider_count`,
      `total_slots`, `slots_free`
    - Aggregate pool state: total providers, ready count, draining
      count, unavailable count
    - Network-wide degraded flag (true if `ready < some_threshold`)
- Status MUST NOT expose:
    - Individual provider hostnames or IDs
    - Provider RAM/CPU specs
    - Operator identity

### Kill switches

Two operator-controlled flags, both stored in `gateway.yaml` (or
runtime via a `/admin/kill-switch` endpoint requiring operator key):

- `kill_switch.demo_only` — when true, unauthenticated demo traffic
  returns 503 immediately; authenticated API traffic continues.
- `kill_switch.all_public_api` — when true, ALL public API requests
  return 503 with a friendly "beta paused" message. Used for capacity-
  burst Tier 3 and incident response.

Both flags MUST be togglable without restarting the gateway.

### Capacity-burst protection

The operator has pre-committed:

- **Monthly cash absorption cap: $500/month.** Encoded in
  `gateway.yaml` as `capacity.monthly_budget_usd: 500`.
- **NO Tier-3 deprecation clause.** The spec does NOT contain a
  MUST-execute-shutdown branch. The operator chooses iteration over
  deprecation.
- **Replacement falsification mechanism: in-session user rating.**
  See "User feedback" below.

Tiered escalation (these MUST be normative, executed mechanically by
monitoring jobs, NOT discretionary operator decisions):

- **Tier 1 (close signups)** fires when ANY of:
    - Pearl VPS sustained CPU >70% for 4 hours
    - Coordinator memory >80%
    - Bandwidth >70% of VPS quota
    - Any provider explicitly requests reduced load (signaled via
      `/admin/provider-feedback` endpoint or operator email)
    - Projected monthly cost reaches 80% of `capacity.monthly_budget_usd`
  Action: signup page returns "closed" status; existing users continue
  at current quotas.

- **Tier 2 (quota tighten)** fires when Tier 1 is active for 7+ days
  AND any signal still firing.
  Action: reduce all account daily quotas by 50% (via config); banner
  on front door indicates capacity tightening.

- **Tier 3 (hard pause)** fires when ANY of:
    - Monthly cost exceeds `capacity.monthly_budget_usd`
    - 2 or more providers drop within a 48-hour window
    - Operator self-reports reactive-ops time >70% of any week
      (via `/admin/operator-load` endpoint)
  Action: `kill_switch.all_public_api` set true; API returns 503 with
  beta-paused message; pool gets to rest.

- **Capacity expansion (optional positive branch)** is available at
  any tier: operator can raise budget cap, upgrade Pearl VPS, recruit
  more providers. Choosing this branch reverses the tier without
  requiring root cause resolution.

### User feedback (replaces Tier-3 deprecation as the iteration signal)

- **Rating scale: 1-4** (1=bad, 2=average, 3=good, 4=excellent).
- **Capture mechanisms (both required for v1):**
    - **(B) API endpoint `POST /v1/feedback`** — optional, per-session
      or per-request. Request body: `{ "rating": 1-4, "comment":
      "optional free text", "request_id": "optional reference to a
      prior completion" }`. Authenticated (bearer token required).
      Idempotent if `request_id` is provided.
    - **(C) Dashboard widget at `/v1/usage` (or front-door /account
      page)** — persistent 1-4 rating widget, captures "how is your
      experience overall" not per-request.
- **Chat playground bonus capture (not normative but recommended):**
  the existing Vercel demo MAY prompt the user for a 1-4 rating after
  N exchanges. Implementation deferred to front-door work.
- **Aggregation:** ratings are stored as append-only events with
  timestamp, account_id (or anonymous for chat playground), rating,
  comment. Operator-readable aggregation endpoint at
  `/admin/feedback-summary`.
- **Iteration signal:** if the 7-day rolling distribution shifts
  toward 1-2 (bad/average) for any 2-week window, the operator MUST
  review root cause. No MUST-pivot trigger (operator chose
  iteration), but the rating data is the primary feedback channel
  replacing the falsification framework's "deprecate" clause.

### Donation link

Not in v1. Do not include a donation button, "support us" link, or
any payment-adjacent UI element. If users ask, operator can point
them at a future SPEC-005 (rewards) discussion.

### North-star metric

Time to first successful API call (visit → key issuance → first
successful `/v1/chat/completions` 200 response). Instrumented in the
gateway from the front door's "Get API key" click through the first
non-error completion. MUST be reportable as a 7-day rolling
distribution (median, p50, p95).

### Failure modes (status codes)

- `404` — model unknown (model not in any provider's served list)
- `503` — model known but no provider available (pool empty or all
  busy)
- `502` — selected provider failed mid-request
- `504` — provider exceeded timeout
- `401` — invalid or missing bearer token
- `403` — valid token but disabled/blocked
- `429` — quota exhausted (with `X-RateLimit-Reset` header)
- All error responses MUST use OpenAI-shaped error envelope:
  `{"error": {"message": "...", "type": "invalid_request_error" |
  "rate_limit_exceeded" | etc., "code": "..."}}`
- All responses MUST include rate-limit headers when applicable:
  `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`

No long queueing. If no slot is immediately available, return 503.
Streaming cancellation: when client disconnects mid-SSE, gateway
MUST cancel the upstream request to coordinator within 500ms.

### Provider-relationship hooks

- No compensation change in v1.
- Add provider contribution counters (per-provider: requests served,
  prompt tokens, completion tokens) if the data already exists in
  coordinator's request log. Expose at `/admin/provider-contributions`
  for operator visibility only.
- Do NOT expose provider earnings, individual revenue, or any payout
  fields. Those are SPEC-005 scope.

### Front door (Vercel demo)

- Existing demo at `web-three-lime-59.vercel.app` becomes the front
  door.
- Updates required:
    - Repoint chat backend from `m4.malibu.tech` / `m1.malibu.tech`
      direct tunnels to `https://api.malibu.tech/v1/chat/completions`
      (via demo-only unauthenticated quota).
    - Add "Get API key" flow (GitHub OAuth, optionally email).
    - Add `/account` page showing usage, quota remaining, regenerate
      key, revoke key.
    - Add single-page docs section: curl examples, OpenAI Python and
      JavaScript SDK snippets, error code explanations, quota docs,
      "real Macs, sometimes asleep" caveats.
    - Add /status panel showing live pool state.
    - Add rating widget (capture mechanism C).
- The spec MUST define the front-door contract (what data it consumes
  from gateway, what URLs it calls). Front-door IMPLEMENTATION is a
  separate work item; spec only defines the contract.

### Documentation

Single-page docs inside the front door. Required content:
- Get a key (OAuth flow walkthrough)
- List models (`GET /v1/models` curl + OpenAI SDK)
- Chat completion (`POST /v1/chat/completions` curl + OpenAI Python +
  OpenAI JavaScript)
- Streaming example
- Usage check (`GET /v1/usage`)
- Error code explanations (each HTTP status code mapped to user-
  meaningful action)
- Quota explanation and reset behavior
- Network-state caveat (this is a live Mac pool; expect occasional
  503s)
- Feedback (how to call `POST /v1/feedback`)

Do NOT adopt a docs platform (Mintlify, ReadMe, GitBook). Single page
is sufficient.

## Explicit out-of-scope for v1

Do not specify (defer to v0.2, SPEC-005, SPEC-007, or later):

- Stripe / billing / metered payment / paid plans / invoicing /
  refunds
- Provider payout, revenue share, tipping
- Captcha-first signup
- Full chart-based dashboard
- Email reports / weekly digests
- Vision endpoints
- Embeddings endpoints
- Reranking endpoints
- Batch jobs
- Dedicated capacity reservation
- Tool execution (we accept tool fields syntactically but do not
  execute)
- Strict schema-enforced structured outputs
- Prompt moderation / content classification systems
- Complex abuse-scoring ML
- Long buyer-side queueing
- Mintlify-style docs platform
- Multi-region coordinator deployment
- Cloudflare Workers / Vercel Functions / Lambda@Edge deployment
- Multi-surface brand architecture (separate docs subdomain, separate
  status subdomain)
- BYOK / custom model upload
- Enterprise tier / SOC 2 / HIPAA / compliance certifications

These belong in v0.2 or later specs. Naming them explicitly in the
out-of-scope section is REQUIRED.

## Critical constraints

**1. SPEC-001 and SPEC-002 are locked and unchanged.** SPEC-006 layers
on top of SPEC-002 v1.1.3's coordinator. Do NOT propose changes to
SPEC-001 or SPEC-002 in this spec. Cross-spec dependencies are
read-only references.

**2. OpenAI compatibility is normative.** Any OpenAI Python or
JavaScript SDK call against `https://api.malibu.tech/v1/chat/completions`
with a valid bearer key MUST succeed for supported models. Deviation
from OpenAI's chat completion request/response shape MUST be
documented as a known divergence.

**3. d-inference clean-room.** Do NOT inspect d-inference source.

**4. No buyer-visible secrets.** Provider hostnames, internal
coordinator URLs, operator keys, signing keys MUST NOT appear in any
buyer-facing response.

**5. Gateway MUST be horizontally scalable from day 1.** Spec MUST
forbid in-process state for rate-limiting, quota, or session data.
Spec MUST require data layer abstraction.

**6. Append-only schema.** Usage events, feedback events, audit logs
MUST be append-only. No UPDATE statements in hot paths.

**7. Sub-ms auth check.** Spec MUST require that bearer-token
validation is achievable in <1ms at p95 against the storage layer.
(This is a design constraint that informs schema indexing decisions.)

**8. Backward-compat for legacy direct-tunnel buyers.** M4 and M1
partner Macs currently serve direct buyers at `m4.malibu.tech` and
`m1.malibu.tech` outside the coordinator. Those paths stay
operational. Gateway does NOT intercept them.

## Required reading

In order:

1. `/Users/augstar/macprovider-poc/specs/SPEC-006-design.md`
   — the design exploration. Treat its Section 4 ("Recommended
   Path") and Section 5 ("Open Questions") as resolved by the
   "Locked design choices" header above. Section 6 ("Falsification")
   is partially superseded by the user-rating mechanism but the
   instrumentation list (Section 6's "Metrics To Instrument") is
   directly normative.

2. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   — the underlying router. Focus on § 3 (mode resolution), § 5
   (routing), § 7 (HTTP surfaces), § 11 (audit categories). SPEC-006
   inherits SPEC-002's audit categories; add the gateway-specific
   ones as new entries.

3. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   — focus on § 6.2 (`/v1/models` shape, JSON-escape tolerance),
   § 6.4 (`/v1/chat/completions` model field semantics, case-
   insensitive match). The gateway MUST preserve these contracts
   when forwarding.

4. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   — the parallel pattern. SPEC-003 made provider onboarding
   `curl-pipe-bash` easy; SPEC-006 makes buyer onboarding equally
   easy via web.

5. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   — read Entries 19-21 carefully. Critical context: production
   incidents, ship-then-spec lessons, hardware-verification gate
   discipline. SPEC-006 inherits the audit-pattern lessons.

6. `/Users/augstar/macprovider-poc/beta/web/` (if it exists; check
   the file tree)
   — the existing Vercel demo source. SPEC-006's front-door work
   modifies this codebase.

7. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/`
   — read enough of the Go coordinator to understand the HTTP
   contract gateway will forward to. Do not propose coordinator
   changes; just understand the surface.

## Output structure

```
# SPEC-006 — Buyer API Gateway: Mac Provider's first public buyer surface

**Version:** 0.1 (2026-05-28, initial design from locked operator decisions)
**Depends on:** SPEC-001 v1.2.2, SPEC-002 v1.1.3, SPEC-003 v0.5

**Change log v0.1:**
- Initial draft following design exploration in specs/SPEC-006-design.md
- Locked design choices captured from operator pre-commitments
  (see § 2 Locked decisions).

[main body sections — see structure below]
```

Section structure:

1. **Scope** — what SPEC-006 covers, what it doesn't, relationship to
   SPEC-001/002/003/004/005/007.
2. **Locked decisions** — restate the operator's pre-commitments
   verbatim from this prompt's "Locked design choices" header. This
   section is read-only documentation; do NOT propose changes.
3. **Terms and definitions** — gateway, account, key, quota, demo
   traffic, rating, tier, capacity-burst, etc.
4. **Architecture** — gateway as service; coordinator as router;
   data flow diagrams; scalability constraints (stateless, data
   abstraction, append-only schema, sub-ms auth).
5. **Public HTTP API** — normative endpoint specifications.
   Subsections per endpoint: request schema, response schema,
   error envelopes, rate-limit headers, OpenAI-compat notes.
6. **Identity and auth** — OAuth flow (GitHub primary, email
   secondary), key issuance, key rotation, key revocation, demo
   traffic, bearer token shape.
7. **Quotas and rate limits** — defaults, configuration,
   enforcement points, header reporting, per-account vs per-IP
   distinctions.
8. **Provider transparency** — what gateway exposes vs hides,
   aggregation rules, status endpoint shape.
9. **Kill switches** — operator controls, configuration mechanisms,
   semantic differences between demo-only and all-public-api.
10. **Capacity-burst protection** — tiered escalation, signals,
    thresholds, mechanical execution requirement.
11. **User feedback** — rating endpoints, capture mechanisms,
    aggregation, iteration-signal use.
12. **Front door contract** — what data gateway provides to the
    Vercel demo, what URLs it expects to be called.
13. **Documentation contract** — required docs content;
    implementation responsibility split (spec defines what; front-
    door work delivers).
14. **Storage layer** — abstracted interface, schema, append-only
    requirements, migration targets, indexes for sub-ms auth.
15. **Configuration** — `gateway.yaml` shape, every operator-
    tunable parameter listed.
16. **Instrumentation and metrics** — every required metric from
    `specs/SPEC-006-design.md` Section 6, plus rating aggregation,
    plus capacity-burst signals.
17. **Failure modes** — every status code, every error envelope,
    every cancellation path.
18. **Acceptance criteria** — AC-1 through AC-N. Each AC MUST have
    deterministic verification steps. Cover: signup flow, key
    issuance, key revocation, OpenAI SDK drop-in, streaming, demo
    traffic, quota enforcement, kill switch activation, capacity-
    burst tier triggers, rating capture, status endpoint shape,
    failure modes, provider transparency rules.
19. **Audit categories** — inherit SPEC-002's audit categories, add
    gateway-specific ones. At minimum: identity correctness,
    quota arithmetic, kill-switch activation latency, rate-limit
    header accuracy, OAuth flow correctness.
20. **Operator questions** — any genuinely unresolved decisions
    surfaced during drafting. Should be small (operator pre-locked
    most decisions); if you find yourself wanting to add many,
    re-read the locked-design header.

## Self-verification checklist

Before declaring the spec complete, verify:

- [ ] Header reflects v0.1 + correct dependency line.
- [ ] § 2 (Locked decisions) restates the operator's pre-commitments
      verbatim and contains NO original recommendations or alternatives.
- [ ] § 4 (Architecture) makes explicit: stateless, data abstraction,
      append-only schema, sub-ms auth, multi-coordinator-ready.
- [ ] § 5 (Public HTTP API) covers every endpoint listed in the
      locked design.
- [ ] § 6 (Identity) names GitHub OAuth primary, email magic link
      secondary-if-cheap, and the deferral path if email isn't cheap.
- [ ] § 10 (Capacity-burst) makes Tier 1/2/3 escalations MECHANICAL,
      not discretionary.
- [ ] § 11 (User feedback) covers both B (API endpoint) and C
      (dashboard widget) capture mechanisms.
- [ ] Out-of-scope section explicitly names: Stripe, payments,
      vision, embeddings, batch, captcha, Mintlify docs platform,
      multi-region coordinator.
- [ ] AC section has at least 15 deterministically-verifiable
      acceptance criteria.
- [ ] No proposed changes to SPEC-001 or SPEC-002.
- [ ] No buyer-visible secrets (hostnames, provider IDs, operator
      keys).
- [ ] Implementation language is Go (consistent with phase4-
      coordinator).
- [ ] Implementation deployment target is Pearl VPS alongside
      coordinator (no Cloudflare Workers v1).

If you find yourself wanting to recommend an alternative to a locked
decision, STOP — the decision is locked. File the alternative as a
v0.2 candidate in § 20 (Operator questions) if relevant; do not edit
the locked decisions.

When done, print a 250-word handback summary covering:
- What the spec defines (one paragraph)
- What it explicitly defers (one paragraph)
- Estimated implementation scope in days (rough)
- Any genuine open questions surfaced during drafting (bulleted list)

Then stop. Do NOT begin implementation. The operator will audit the
spec before any code work begins.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~45 min):

1. Read `specs/SPEC-006-buyer-api.md` start to finish.
2. Verify § 2 (Locked decisions) matches the operator's pre-commitments
   without modification or "improvement."
3. Verify out-of-scope section names everything we agreed to defer.
4. Verify § 10 (Capacity-burst) tiers are mechanical, not "the operator
   will decide if X happens."
5. Verify § 11 covers both API feedback endpoint AND dashboard widget.
6. AC section has 15+ verifiable items.

If clean: draft `AUDIT_SPEC_006_PROMPT.md` for a cross-model audit pass
(Codex and Claude) following the SPEC-001/002 audit pattern.

If issues: file fix prompt under `FIX_SPEC_006_V0_2_PROMPT.md`.

After audit + fix cycles: spec locks to v1.0, then `BUILD_PHASE5_PROMPT.md`
drives the gateway implementation in a separate session.

## Why this prompt is structured this way

The "Locked design choices" header is the most important part. It
exists to prevent the executing session from re-doing the design work
the operator already did. The previous design-exploration session
correctly avoided being prescriptive; this BUILD session needs the
opposite — every decision pre-made, room only to draft.

The verification checklist forbids the executing session from
proposing alternatives to locked decisions. This is the difference
between BUILD prompts that produce drift ("we changed Q5 because we
thought it'd be better") and BUILD prompts that produce specs.
