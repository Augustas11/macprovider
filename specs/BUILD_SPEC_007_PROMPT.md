# Build prompt — SPEC-007 v0.1 (normative explorer spec)

Operator-paste prompt that drafts the normative `specs/SPEC-007-explorer.md`
v0.1 against the locked decisions captured in
`specs/SPEC-007-operator-decisions.md`. The design exploration was
completed in a previous run; its output is at
`specs/SPEC-007-explorer-design.md`. This prompt does NOT relitigate the
design — it locks the operator's 14 decisions and asks a fresh session
to produce a normative spec.

Scope: **internal, read-only, single-operator protocol explorer.** A
public antfeed.org-style surface is explicitly deferred to a later SPEC
per D13.

Run in **Codex** or **Claude Code**. Expected duration: ~3-4 hours for a
thorough first draft. Output is `specs/SPEC-007-explorer.md` v0.1. Do
not write code. Do not modify any other file.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are drafting SPEC-007 v0.1, the normative specification for Mac
Provider's internal operator-only protocol explorer. The design
exploration is complete at `specs/SPEC-007-explorer-design.md` and the
operator has locked 14 decisions at `specs/SPEC-007-operator-decisions.md`.
Your job is to convert those locked decisions into a normative spec with
the same rigor as SPEC-005 v0.3 and SPEC-006 v0.1.

Output location:
  /Users/augstar/macprovider-poc/specs/SPEC-007-explorer.md

Target length: 1500-2500 lines. Same structural rigor as SPEC-005-billing.md
and SPEC-006-buyer-api.md. Numbered sections, MUST/SHOULD/MAY normative
language per RFC 2119, explicit acceptance criteria with deterministic
verification steps, change log header.

You are NOT writing code in this run. You are writing the spec. A
separate `BUILD_SPEC_007_IMPL_PROMPT.md` will drive the implementation
work AFTER the spec is audited and locked.

## Hard scope guardrails (do not relitigate)

These are the inviolable boundaries. If you find yourself wanting to
expand any of them, file the alternative as a v0.2 candidate in the
"Operator questions" section. Do not edit the locked guardrails.

1. **Internal-only.** Single operator. No multi-tenant, no public
   redaction logic, no rate limiting beyond bounded query timeouts.
2. **Read-only.** No mutating endpoints. Settlement claim/consume/void,
   provider admission, key issuance, kill switches stay on existing
   `/admin/*` surfaces. The explorer observes; it does not act.
3. **Coordinator is the explorer origin.** All explorer routes live
   under `/admin/explorer/*` on the coordinator's existing admin port.
   No new public DNS, no new Vercel project, no separate service.
4. **No parallel data store.** The explorer reads from existing
   coordinator and gateway SQLite. No analytics warehouse, no
   materialized rollups, no durable provider-event table in v1.
5. **Gateway owns buyer data.** Buyer/account/key/usage data stays in
   the gateway's SQLite. The explorer reaches it via new read-only
   gateway admin endpoints, proxied through coordinator
   `/admin/explorer/*`. No buyer-table copy into the coordinator.
6. **SPEC-002 charter preserved.** The coordinator remains a router
   plus billing state owner. Adding read-only `/admin/explorer/*` is
   in charter; adding analytics-grade ETL or charting is not.
7. **SPEC-005 ledger is canonical.** The explorer reads ledger tables;
   it MUST NOT write, settle, void, or modify any `ledger_*` row.
   `ledger_payout_ready` rows are visible but immutable through this
   surface.

## Locked operator decisions (verbatim from operator-decisions.md)

These are normative inputs. Restate them verbatim in § 2 of the spec.
Do NOT relitigate. Do NOT propose alternatives. Do NOT "improve" the
phrasing — operator wrote it; operator owns it.

  D1  Hosting: coordinator-served `/admin/explorer/`; same origin as
      coordinator admin endpoints; no new public app or Vercel project.
  D2  Frontend technology: static dashboard; dense operational tables,
      filters, status strips, manual refresh; no SPA framework.
  D3  Auth: reuse existing coordinator operator bearer; Cloudflare
      Access / Tailscale permitted as outer gate without changing the
      application auth contract.
  D4  Gateway buyer data path: coordinator proxies to bounded read-only
      gateway admin endpoints; no buyer-table copy into coordinator.
  D5  Buyer endpoints: included in v1 via new read-only gateway endpoints.
  D6  Provider event history: live `/poolz` plus logs only in v1; no
      durable provider session / event / reconnect table.
  D7  In-flight requests: completed attempts only in v1 (from
      `request_log` plus ledger/gateway joins); no in-flight endpoint.
  D8  Activity transport: polling with bounded intervals and hidden-tab
      pause; no SSE in v1. Activity cursors MUST be designed so SSE can
      wrap the same feed in a later SPEC without endpoint redesign.
  D9  Public-safe tagging: tags live in spec/design metadata only;
      v1 endpoint schemas carry no tag metadata.
  D10 Operator economics: operator share, provider share, gross
      credits, reconciliation deltas, fault/quarantine counts, and
      settlement-ready totals are visible internally.
  D11 Settlement rows: read-only visibility of `ledger_payout_ready`
      and settlement history in v1; explorer MUST NOT claim, consume,
      void, or pay rows.
  D12 Index posture: existing indexes plus bounded date windows,
      cursors, limits, and query timeouts; new indexes only when a
      measured query in implementation tests requires one.
  D13 Public explorer scope: deferred to a later SPEC; v1 is
      internal-only and may expose operator-only fields.
  D14 V1 success bar: one operator can answer live state, recent
      activity, buyers, providers, ledger, settlements, and health
      in under two minutes using tables, status strips, filters, and
      detail views.

## Inputs to read before writing

Read these files first. Cite them by path when referencing decisions
or data sources.

  - specs/SPEC-007-explorer-design.md         — design exploration; § 2
                                                data inventory is the
                                                ground truth for what
                                                the coordinator and
                                                gateway already store.
  - specs/SPEC-007-operator-decisions.md      — the 14 locked decisions.
  - specs/SPEC-005-billing.md                 — ledger / settlement /
                                                reconciliation schema;
                                                cite by section when
                                                describing read sources.
  - specs/SPEC-006-buyer-api.md               — gateway endpoint surface
                                                and table inventory.
  - specs/SPEC-002-coordinator.md             — coordinator charter
                                                (router + billing state).
  - phase4-coordinator/internal/requestlog/store.go     — request_log schema
  - phase4-coordinator/internal/billing/store.go        — ledger_* schemas
  - phase4-coordinator/internal/billing/endpoints.go    — existing /admin/ledger/*
  - phase4-coordinator/internal/pool/provider.go        — live provider struct
  - phase4-coordinator/internal/auth/tokens.go          — provider_tokens
  - phase4-coordinator/internal/ws/server.go            — coordinator mux
  - phase5-gateway/internal/router/server.go            — gateway mux
  - phase5-gateway/internal/storage/sqlite/migrate.go   — gateway schemas

If any cited file disagrees with a claim in the design doc, trust the
code and flag the design-doc drift in the spec's "Operator questions"
section. Do not silently rely on a design-doc claim that does not
match current code.

## Required spec structure

Use these top-level sections in this order. Match SPEC-006-buyer-api.md
heading altitude and the SPEC-005-billing.md normative-language rigor.

### 1. Change log
Standard table header: version, date, author, summary. First row is
v0.1, today's date, operator, "initial draft against locked decisions
D1-D14".

### 2. Locked decisions
Restate D1-D14 verbatim from operator-decisions.md. One subsection per
decision. No alternatives. No "we considered..." prose. This section
is read-only documentation of the operator's pre-commitments.

### 3. Terms and definitions
Define every term the spec uses non-trivially: explorer, view,
overview, activity feed, session detail, buyer directory, provider
directory, ledger view, settlement view, health view, operator bearer,
outer gate (Cloudflare Access / Tailscale), bounded window, cursor,
polling interval, hidden-tab pause, operator-only / public-aggregate /
public-redacted / public-raw tag classes (deferred from v1 endpoint
schemas per D9 but defined here for forward use).

### 4. Architecture
Diagram-grade prose. Cover:
  - Operator browser → outer gate (optional) → coordinator
    `/admin/explorer/*` (bearer-authenticated) → either local SQLite
    read OR HTTPS proxy to gateway `/admin/buyers/*` (bearer-authenticated
    again, separate gateway secret).
  - No new long-lived process. The explorer is a set of new handlers
    inside the existing coordinator binary plus a small set of new
    read-only gateway endpoints.
  - State boundaries: coordinator owns request_log, ledger_*,
    provider_tokens, live pool; gateway owns accounts, api_keys,
    usage_events, quota_reservations, feedback_events, audit_events,
    capacity_signal_events.
  - Static-asset surface: small bundle of HTML/CSS/JS served from
    coordinator binary (embed via `embed.FS` per Go convention used
    elsewhere in this repo; verify by reading the code).

### 5. Read-only endpoint surface (coordinator)
Normative endpoint specifications under `/admin/explorer/*`. One
subsection per endpoint. Each subsection MUST include:
  - HTTP method and path
  - Request parameters (query string, headers)
  - Response JSON schema with every field named and typed
  - Error envelopes (status codes, body shape)
  - Cursor / pagination contract where applicable
  - Bounded window contract (max date range, max page size)
  - Query timeout (server-side budget)
  - Which underlying tables / endpoints feed the response
  - Auth requirement (operator bearer)

At minimum, define endpoints for: overview, sessions list, session
detail (by request_id), providers list, provider detail (by
provider_id), buyers list (proxied), buyer detail (proxied), ledger
recent entries, settlements list (settled + pending), health snapshot,
activity feed (cursor-paginated). The design doc § 4 names the
candidate set; this spec MUST lock the exact set, paths, and
parameters.

### 6. Read-only endpoint surface (gateway)
Normative specifications for the new read-only gateway endpoints the
explorer needs (per D4 / D5). Each subsection follows the same
schema as § 5. Endpoints MUST be:
  - Bounded (cursor + limit + window).
  - Bearer-authenticated with a gateway-side operator secret distinct
    from the coordinator operator bearer; document the secret name.
  - Idempotent and side-effect-free.
  - Documented as "explorer-facing only" — not part of the public
    buyer-facing surface in SPEC-006.

Locate these endpoints under `/admin/explorer/` on the gateway as well,
so the coordinator's proxy layer is a verbatim path rewrite without
verb or query translation.

### 7. Data sources and joins
For each view in § 8, name the source tables (coordinator and gateway)
and the join keys. Cite the columns by name from the design doc's
data inventory. Document `request_id` as the cross-component join
key; document `provider_id` and `account_id` as intra-component join
keys. Flag SPEC-007's lack of a shared durable `session_id` as a known
limitation surfaced for a later SPEC (do not introduce one in v1).

### 8. Views (internal cockpit)
One subsection per view, mirroring the design doc's § 3:
  8.1 Overview, 8.2 Live state, 8.3 Activity feed, 8.4 Sessions and
  requests, 8.5 Buyers, 8.6 Providers, 8.7 Tokens and economics,
  8.8 Health, 8.9 Feedback and quality.

For each view, MUST specify:
  - The operator question it answers (one sentence).
  - The endpoints from §§ 5-6 that feed it.
  - Every field shown, by name.
  - The privacy tag per field (operator-only / public-aggregate /
    public-redacted / public-raw) — this is the forward-compatibility
    insurance from D9. Tags live in the spec, not in v1 endpoint
    schemas.
  - The refresh model (interval in seconds, or "manual only").
  - Hidden-tab behavior (pause / continue).

### 9. Refresh and polling contract
Bounded per-view polling intervals. Global guardrails:
  - All polling MUST pause when the tab is hidden.
  - Server-side query timeout per endpoint MUST be specified.
  - A single operator session MUST NOT generate more than N requests
    per minute across all views (specify N).
  - Activity cursors MUST be monotonic and resumable, so a later SPEC
    can layer SSE on the same feed without re-design.

### 10. Auth
Coordinator bearer = existing operator bearer (cite the env var name
used by `/admin/*` today, after reading the coordinator code). Gateway
bearer = new explorer-only secret (name it, e.g., GATEWAY_EXPLORER_BEARER).
Outer-gate composition (Cloudflare Access / Tailscale) is permitted
and MUST NOT change the application auth contract. Document the
threat model the auth is NOT defending against (multi-tenant, public
abuse, key theft mitigation) so an implementer does not over-engineer.

### 11. Static asset surface
Where the HTML/CSS/JS lives in the repo, how it is embedded into the
coordinator binary, cache headers, CSP headers, no external network
calls from the bundle, no third-party JS frameworks. The bundle MUST
be small enough that a fresh operator session loads under 200ms over
a typical home connection.

### 12. Performance and operational budget
Per-endpoint query budget. Bounded windows for ledger and request_log
queries. Cursor-based pagination for any unbounded set. Document
which endpoints might require an index in implementation; per D12
indexes are added only when a measured query in implementation tests
requires one. List candidate indexes by name + columns so the audit
can validate them later, but mark each as "v1: not added unless
measured."

### 13. Configuration
`coordinator.yaml` additions: `explorer.enabled`, `explorer.bind_path`,
`explorer.bearer_env`, `explorer.gateway_base_url`,
`explorer.gateway_bearer_env`, `explorer.query_timeout_ms`,
`explorer.poll_min_interval_seconds`, plus any view-specific knobs
identified during drafting. Every operator-tunable parameter MUST be
listed with its type, default, and behavior at the boundary values.

### 14. Failure modes
Every status code the explorer endpoints emit, every error envelope
shape, every cancellation path. Specifically: gateway unreachable (the
proxy view degrades gracefully, surfaces "gateway unavailable" in the
buyer panels), ledger query timeout, request_log query timeout, bearer
missing or invalid, outer-gate rejection (operator never sees the
explorer at all), partial data (one panel fails, others render).

### 15. Acceptance criteria
AC-1 through AC-N (target: 18-25). Each AC MUST have deterministic
verification steps. Cover at minimum:
  - Auth: bearer required, bad bearer rejected.
  - Overview loads in under 500ms with seeded ledger / request_log.
  - Sessions list paginates with stable cursor across new inserts.
  - Session detail joins request_log + ledger + gateway usage by
    request_id correctly for a known seeded request.
  - Provider list reflects live `/poolz` state.
  - Ledger view shows seeded entries and respects bounded window.
  - Settlements view shows `ledger_payout_ready` rows read-only;
    attempts to mutate via this surface MUST return 405 or 404.
  - Health view surfaces reconciliation delta from
    `ledger_reconciliation_runs`.
  - Activity feed cursor is monotonic; replay from cursor returns
    a contiguous slice.
  - Polling pauses on hidden tab.
  - Gateway-unreachable degradation: explorer renders without buyer
    panels and surfaces a single visible error strip.
  - D14 success bar: operator can navigate from overview to one
    seeded session, one seeded buyer, one seeded provider, and one
    seeded settlement row in under two minutes via the rendered UI.

### 16. Audit categories
Inherit SPEC-005's audit categories where applicable; add explorer-
specific ones. At minimum:
  - read-only invariant (no endpoint mutates state)
  - bearer enforcement on every route
  - bounded-window enforcement on every list endpoint
  - cursor monotonicity
  - gateway-side bearer is distinct from coordinator bearer
  - ledger row immutability through this surface
  - polling guardrails (hidden-tab pause, per-session rate cap)
  - forward-compatibility: every field in § 8 has a privacy tag

### 17. Out of scope (explicit)
Name every adjacent thing the spec does NOT cover:
  - Public explorer / antfeed-style surface (deferred per D13).
  - Mutating settlement, key issuance, provider admission.
  - In-flight request visibility (per D7).
  - Durable provider event / session table (per D6).
  - SSE / WebSocket transport for the activity feed (per D8).
  - Analytics-grade charts, BI rollups, long-horizon dashboards.
  - Per-buyer impersonation tools or buyer-side admin actions.
  - Multi-operator RBAC.
  - Rate limiting beyond the per-session polling cap.
  - Vercel-hosted UI.
  - Next.js or any SPA framework.
  - Multi-region or multi-coordinator deployment.
  - Email / Slack / PagerDuty alert wiring on top of the health view.

### 18. Operator questions (open, post-locked)
Any genuinely unresolved decisions surfaced during drafting. Should be
small. If you find yourself wanting to add many, re-read § 2 — the
operator pre-locked 14 decisions for a reason. Surface only items that
were not answerable from the locked set, the design doc, or the code
you read.

## Self-verification checklist

Before declaring the spec complete, verify:

- [ ] Header reflects v0.1 + correct dependency lines (SPEC-002, SPEC-005,
      SPEC-006, SPEC-007-explorer-design, SPEC-007-operator-decisions).
- [ ] § 2 restates D1-D14 verbatim and contains NO original
      recommendations or alternatives.
- [ ] § 5 names every endpoint with method, path, params, response
      schema, errors, cursor contract, window contract, timeout.
- [ ] § 6 lists at least one new gateway read-only endpoint per D4 / D5
      with a distinct gateway-side bearer.
- [ ] § 7 names every join key by column and notes the absence of a
      shared durable `session_id`.
- [ ] § 8 has nine views; every field carries a privacy tag.
- [ ] § 9 names a per-session request cap and a hidden-tab pause rule.
- [ ] § 11 specifies static-asset embedding and no third-party JS.
- [ ] § 13 lists every new `coordinator.yaml` key with type and default.
- [ ] § 15 has 18+ deterministically-verifiable acceptance criteria,
      including the D14 two-minute traversal AC.
- [ ] § 16 audit categories include read-only invariant, bearer
      enforcement, cursor monotonicity, ledger immutability.
- [ ] § 17 names every deferral from the guardrails and D-rows.
- [ ] No proposed changes to SPEC-002, SPEC-005, or SPEC-006.
- [ ] No mutating endpoints anywhere.
- [ ] No analytics rollups, no SSE, no SPA framework, no Vercel.
- [ ] Implementation language stays Go (coordinator) + small static
      bundle.

If you find yourself wanting to recommend an alternative to a locked
decision, STOP — the decision is locked. File the alternative as a
v0.2 candidate in § 18 (Operator questions) if relevant; do not edit
the locked decisions.

## Handback

When done, print a 250-word handback summary covering:
  - What the spec defines (one paragraph)
  - What it explicitly defers (one paragraph)
  - Estimated implementation scope in days (rough)
  - Any genuine open questions surfaced during drafting (bulleted list)
  - Confirmation that no other files were modified

Then stop. Do NOT begin implementation. Do NOT commit. Do NOT modify
the decision log. The operator will audit the spec before any code
work begins.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~45 min):

1. Read `specs/SPEC-007-explorer.md` start to finish.
2. Verify § 2 (Locked decisions) matches D1-D14 verbatim from
   `specs/SPEC-007-operator-decisions.md` with no rewording.
3. Verify § 17 (Out of scope) names everything the guardrails and the
   D-rows deferred.
4. Verify § 15 has 18+ acceptance criteria including the D14
   two-minute traversal AC.
5. Verify no mutating endpoints exist anywhere in §§ 5-6.
6. Verify § 6 introduces a gateway-side bearer distinct from the
   coordinator bearer.

If clean: draft `AUDIT_SPEC_007_PROMPT.md` for a cross-model audit
pass following the SPEC-005 / SPEC-006 audit pattern. Codex audits
the Claude draft; Claude audits the Codex draft. Reconcile findings
into a v0.2 if anything material surfaces.

If issues: file fix prompt under `FIX_SPEC_007_V0_2_PROMPT.md`.

After audit + fix cycles: spec locks to v1.0. Then draft
`BUILD_SPEC_007_IMPL_PROMPT.md` to drive the Go + static-bundle
implementation in a separate session.

## Why this prompt is structured this way

The "Locked operator decisions" section is the load-bearing part. It
exists to prevent the executing session from re-doing the design work
the operator already did across the design exploration plus 14
locked answers. The previous design-exploration session correctly
avoided being prescriptive; this BUILD session needs the opposite —
every decision pre-made, room only to draft normative prose.

The self-verification checklist forbids the executing session from
proposing alternatives to locked decisions. That is the difference
between BUILD prompts that produce drift ("we changed D4 because we
thought it'd be better") and BUILD prompts that produce specs that
audit cleanly.
