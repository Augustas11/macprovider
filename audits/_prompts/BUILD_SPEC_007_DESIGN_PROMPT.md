# Build prompt — SPEC-007 design exploration

Operator-paste prompt that drafts `specs/SPEC-007-explorer-design.md` — the
design-exploration document for **Mac Provider's internal operator-only
protocol explorer**. The output is *not* a normative spec. It is a structured
exploration that ends with a numbered list of locked decisions the operator
must commit to before SPEC-007 v0.1 is drafted (same two-stage pattern used
for SPEC-005 and SPEC-006).

Scope is **internal operator dashboard only**. A public antfeed.org-style
explorer is explicitly out of scope for SPEC-007; the design must, however,
mark each data field with a "public-safe / operator-only" tag so a future
SPEC can promote a redacted subset without rework.

Run in **Codex** (or Claude Code). Expected duration: ~2-3 hours. Output is
a single new file at `specs/SPEC-007-explorer-design.md`. Do not modify any
other file. Do not write code.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are drafting `specs/SPEC-007-explorer-design.md`, the design-exploration
document for Mac Provider's internal operator-only protocol explorer. This
is a DESIGN document, not a normative spec. Your job is to map the decision
space, surface trade-offs, and end with a numbered list of locked-decision
questions the operator must answer before SPEC-007 v0.1 is written.

Output location:
  /Users/augstar/macprovider-poc/specs/SPEC-007-explorer-design.md

Target length: 800-1400 lines. Match the structure and rigor of
`specs/SPEC-006-design.md` (read it first). Do NOT write code. Do NOT
modify any other file. Do NOT propose a normative spec — that comes in a
later run after the operator locks decisions.

## Problem framing (operator's words, verbatim)

  "We have built the macprovider protocol — but I as operator don't have
   any visibility into what's happening inside the protocol: buyers,
   sessions, tokens, providers. I want a protocol explorer like
   antfeed.org, but internal-only for now."

## Hard constraints (do not relitigate)

1. **Internal-only for v1.** Single-operator access. No multi-tenant auth,
   no public-facing redaction logic, no rate limiting. Treat the dashboard
   as if it were `/admin/*` — the operator is the only viewer. Public
   explorer is a future SPEC.
2. **Read-only.** No mutating endpoints. The explorer observes; it does
   not act on the protocol. Settlement, key issuance, provider admission,
   etc. remain on existing `/admin/*` surfaces.
3. **Coordinator is already the source of truth.** SPEC-005 v0.1 landed a
   ledger, settlement, reconciliation, and billing endpoints on the
   coordinator. The explorer reads from the coordinator's existing SQLite
   state (and any new read-only endpoints it adds) — it does NOT introduce
   a parallel data store.
4. **Coordinator stays router-only in spirit.** Per SPEC-002 v1.1.3, the
   coordinator's charter is routing + billing state. Adding read-only
   `/admin/explorer/*` endpoints is in-charter. Adding a separate
   long-lived analytics service is out of charter for v1; if you propose
   one, mark it as a "later SPEC" trade-off and do not lock it.
5. **Reuse existing infrastructure where possible.** The Vercel demo at
   `web-three-lime-59.vercel.app` already exists and already proxies to
   M1/M4 tunnels — explore whether it can host the explorer UI as a
   protected route, vs. a separate deployment.
6. **Privacy commitment forward-compatibility.** Every data field surfaced
   in the explorer must be tagged in the design as one of:
     - `operator-only` — never safe to expose publicly
     - `public-aggregate` — safe in aggregate (e.g., total sessions today)
     - `public-redacted` — safe with a specific redaction (e.g., buyer
       address shown as `0x1234…abcd`)
     - `public-raw` — safe to expose as-is
   This tagging is the seed for a future public explorer SPEC and MUST
   appear in the data-model section.

## Required structure (numbered sections)

The design document MUST have these top-level sections, in order. Use the
same heading style and altitude as `specs/SPEC-006-design.md`.

### 1. Operator's framing
Restate the operator's problem in operator-grade prose. What visibility
is missing? Why does it matter now (SPEC-005 just landed; there are real
sessions, real ledger movements, real settlements happening that the
operator cannot see at a glance)? What does "I want to know what's
happening" actually decompose into for a single-operator P2P protocol?

### 2. What the coordinator already knows
Inventory, by reading the repo:
  - `phase4-coordinator/` — what tables, endpoints, and in-memory state
    exist? List every `/admin/*` and SPEC-005 billing endpoint with a
    one-line description of what it returns.
  - `phase5-gateway/` — what does the gateway know that the coordinator
    does not (e.g., API keys, buyer accounts, per-account usage)?
  - SQLite schemas: enumerate every table the explorer might read (sessions,
    request log, ledger, settlements, reconciliation, providers, buyer
    accounts, usage events). For each, list columns and note which the
    explorer needs.
This section is the "data inventory" — be exhaustive. If you find a column
the explorer needs but it does not yet exist, flag it explicitly with
**[GAP]** so the locked-decisions section can include "add column X to
table Y" as an operator decision.

### 3. What the operator wants to see
Decompose "visibility" into concrete views. Suggested (not exhaustive):
  - **Live state**: sessions currently open, providers currently
    connected, gateway requests in flight.
  - **Activity feed**: chronological stream of recent sessions, requests,
    settlements, provider connects/disconnects.
  - **Buyers**: list of API keys / accounts, per-buyer usage, top spenders,
    quota status, last-active timestamp.
  - **Providers**: list of currently-pinned and currently-connected Macs,
    per-provider revenue, model served, uptime, last-served request.
  - **Tokens / economics**: aggregate token throughput, USDC ledger
    balance, pending settlements, settled totals, reconciliation status.
  - **Health**: SPEC-005 reconciliation drift, gateway error rate,
    coordinator restart count, provider WS reconnect rate.
Propose additional views if the data-inventory section reveals them. For
each view, list the data sources (which tables/endpoints feed it).

### 4. Endpoint surface
Propose the coordinator-side read-only endpoint surface. Suggested shape:
  `GET /admin/explorer/overview`        — single snapshot for landing page
  `GET /admin/explorer/sessions`        — paginated session list + filter
  `GET /admin/explorer/sessions/:id`    — single session deep view
  `GET /admin/explorer/providers`       — provider directory + per-provider stats
  `GET /admin/explorer/buyers`          — buyer/API-key directory (if gateway exposes)
  `GET /admin/explorer/ledger`          — recent ledger entries, balances
  `GET /admin/explorer/settlements`     — settlement history + pending
  `GET /admin/explorer/health`          — reconciliation drift, error counters
  `GET /admin/explorer/stream` (SSE)    — optional live event feed
Explore the trade-off of one fat `/overview` endpoint vs. many small ones.
Explore SSE vs. polling for the live view. Explore whether gateway-owned
data (API keys, buyer accounts) should be proxied through the coordinator
or fetched directly by the explorer from the gateway's `/admin/*`.

### 5. Frontend surface
Three candidate hosting paths — explore each and recommend:
  a) New route in the existing Vercel project (`web-three-lime-59.vercel.app`)
     behind operator auth. Pro: zero new infra. Con: mixes demo and ops.
  b) Separate Vercel project (`explorer.streamvc.live`). Pro: clean
     separation. Con: extra deploy target, extra DNS.
  c) Coordinator-served static dashboard at
     `coordinator.streamvc.live/admin/explorer/`. Pro: no external
     dependency, operator auth piggy-backs on existing `/admin/*` gate.
     Con: Pearl VPS now serves UI assets; coordinator binary grows.

Discuss frontend technology constraints. Operator preference (infer from
the existing Vercel demo and decision log) leans toward Next.js. Do not
propose a SPA framework the rest of the codebase does not use.

### 6. Auth
Single-operator dashboard. Explore:
  - Reuse the existing `/admin/*` token (whatever SPEC-002/SPEC-005 use).
  - Add a separate `OPERATOR_EXPLORER_TOKEN` env var.
  - Cloudflare Access / Tailscale / IP allowlist in front of the route.
  - GitHub OAuth (single allowed login: the operator's account) for the
    Vercel-hosted UI.
Recommend a default. State explicitly what the threat model is NOT
(public abuse, multi-tenant, key theft mitigation) so the operator does
not over-engineer.

### 7. Refresh model
For each view in §3, propose: page-load fetch, periodic poll (interval),
SSE stream, or manual refresh. Bound the coordinator's incremental load:
a single operator hitting the dashboard once a minute is fine; a five-tab
auto-refreshing dashboard polling every second is not. Propose a per-view
budget.

### 8. Performance & operational budget
Estimate the worst-case extra query load the explorer adds to the
coordinator's SQLite. Identify any query that would require a new index
or a materialized cache (e.g., "top buyers by spend last 24h" over a
growing ledger). Mark each as **[INDEX]** or **[CACHE]** if so.

### 9. Forward path to public explorer
Reiterate the privacy-tagging requirement (operator-only / public-aggregate
/ public-redacted / public-raw). For each view in §3, list which fields
would survive promotion to a public explorer, and which would not. This
section is the cheap insurance against having to redesign when the
public explorer SPEC arrives.

### 10. Open questions for operator (LOCKED-DECISIONS section)
End with a numbered list of 8-15 yes/no or A/B/C questions the operator
must answer before SPEC-007 v0.1 is written. Each question MUST:
  - have a default recommendation (your strongest single choice)
  - state the trade-off in one sentence
  - reference the section above where it was explored
Example format:
  **Q1. Hosting (§5).** Coordinator-served `/admin/explorer/` (recommended)
  or separate Vercel project? Trade-off: coordinator-served is one less
  moving part; Vercel-hosted is faster to iterate on UI.
This section is the deliverable the operator will paste into a follow-up
prompt that locks the decisions and asks for SPEC-007 v0.1.

## Inputs to read before writing

Read these files first. Cite them by path when referencing decisions.

  - specs/SPEC-005-billing.md          — ledger, settlement, reconciliation
  - specs/SPEC-005-operator-decisions.md — locked decisions for SPEC-005
  - specs/SPEC-006-design.md            — design-doc structural template
  - specs/SPEC-006-buyer-api.md         — gateway surface (where buyers/keys live)
  - specs/SPEC-002-coordinator.md       — coordinator charter (router-only)
  - phase4-coordinator/                 — current coordinator state and endpoints
  - phase5-gateway/                     — current gateway state and endpoints
  - beta/DECISION_CRITERIA.md           — recent decisions; especially Entry 39
                                          (SPEC-005 complete) and any
                                          observability-related entries

## What "done" looks like

  - One new file at `specs/SPEC-007-explorer-design.md`, 800-1400 lines,
    matching SPEC-006-design.md structural style.
  - All ten numbered sections present.
  - §2 data inventory enumerates real tables and columns by name, not
    speculative ones.
  - §3 views are each backed by named data sources from §2.
  - Every field referenced in §3 is tagged operator-only /
    public-aggregate / public-redacted / public-raw in §9.
  - §10 ends with 8-15 numbered locked-decision questions with defaults.
  - No other file in the repo is modified.
  - No code is written.
  - No claims are made that are not grounded in the files you read.

When you are done, print the absolute path of the file you wrote and a
one-paragraph summary of which decisions you most strongly recommend the
operator NOT relitigate (i.e., where the design space is genuinely
narrow). Do not commit. Do not push. Do not modify the decision log.

=== END PROMPT ===
```

---

## After Codex finishes

1. Read `specs/SPEC-007-explorer-design.md` end-to-end.
2. Answer the §10 locked-decision questions inline in a new file
   `specs/SPEC-007-operator-decisions.md` (mirroring SPEC-005's pattern).
3. Hand that file plus the design doc to a follow-up
   `BUILD_SPEC_007_IMPL_PROMPT.md` (to be written) that drafts the
   normative `specs/SPEC-007-explorer.md` v0.1.
4. Audit per house style (`AUDIT_SPEC_007_PROMPT.md`) before any code is
   written.

No code is written from this prompt. No coordinator endpoints are added.
No frontend is deployed. This run produces one design document.
