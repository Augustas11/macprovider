# SPEC-007 operator pre-commitments

Lock each decision below before drafting normative `specs/SPEC-007-explorer.md` v0.1.
These answers follow `specs/SPEC-007-explorer-design.md` §10 and keep SPEC-007 scoped to an
internal, read-only, single-operator protocol explorer.

The BUILD session should encode these as normative § 2 pre-commitments with no further
design space unless a later audit identifies a contradiction with the locked spec corpus.

| # | Design question | Options (from explorer-design.md) | Operator Decision |
|---|---|---|---|
| D1 | Hosting | A) **Coordinator-served `/admin/explorer/` (recommended)** / B) separate Vercel project / C) old Vercel route | **A** - coordinator-served `/admin/explorer/` for v1; same origin as coordinator admin endpoints; no new public app, DNS target, or Vercel admin-to-backend bridge. Do not put explorer routes in the public buyer console. |
| D2 | Frontend technology | A) **Static dashboard (recommended)** / B) Next.js | **A** - static dashboard for v1; dense operational tables, filters, status strips, and manual refresh are enough; no SPA framework or charting dependency unless a later measured workflow requires it. |
| D3 | Auth | A) **Existing coordinator operator bearer (recommended)** / B) separate explorer token / C) GitHub OAuth | **A** - reuse the existing coordinator operator bearer for v1; the explorer is equivalent to `/admin/*`; no RBAC, OAuth, multi-tenant sessions, or separate read-only token in v1. If the route is exposed outside the operator's private path, Cloudflare Access or Tailscale may be used as an outer gate without changing the application auth contract. |
| D4 | Gateway buyer data path | A) **Coordinator proxy to gateway read-only endpoints (recommended)** / B) UI calls gateway directly / C) omit buyers from v1 | **A** - add bounded read-only gateway admin endpoints for buyer/account/key/usage data and proxy the explorer-facing summaries through coordinator `/admin/explorer/*`; keep gateway ownership of buyer data; do not copy buyer tables into coordinator storage. |
| D5 | Buyer endpoints | A) **Add gateway read-only buyer endpoints in v1 (recommended)** / B) defer buyer directory | **A** - include buyer/API-key directory visibility in v1 through read-only gateway endpoints; the operator's original ask explicitly includes buyers and tokens, so deferring this would leave the cockpit incomplete. |
| D6 | Provider event history | A) **Rely on live `/poolz` plus logs for v1 (recommended)** / B) add durable provider event table | **A** - v1 shows current provider state from `/poolz` and recent request/ledger-derived activity only; no new durable provider session/event table, reconnect counter table, or uptime history in v1. Mark reconnect and restart history as explicit gaps for a later observability spec. |
| D7 | In-flight requests | A) **Show completed attempts only in v1 (recommended)** / B) add in-flight endpoint | **A** - v1 session views are based on durable completed attempts from `request_log` plus ledger/gateway joins; no in-flight request table or live in-flight endpoint in v1. |
| D8 | Activity transport | A) **Polling (recommended)** / B) SSE in v1 | **A** - polling in v1: overview/health/activity use bounded intervals and pause when hidden; no SSE endpoint in v1. Design activity cursors so SSE can wrap the same feed later if needed. |
| D9 | Public-safe tagging | A) **Keep tags in spec/design (recommended)** / B) include tags in endpoint schemas now | **A** - keep operator-only/public-aggregate/public-redacted/public-raw tags in the normative spec and design notes, but do not add tag metadata to v1 endpoint responses. Endpoint schemas stay operationally lean while preserving future public-explorer guidance. |
| D10 | Operator economics | A) **Show operator share internally (recommended)** / B) hide operator share from dashboard | **A** - show operator share, provider share, gross credits, reconciliation deltas, fault/quarantine counts, and settlement-ready totals internally; public explorer promotion must remove or aggregate operator-only economics. |
| D11 | Settlement rows | A) **Include settlement-ready rows in v1 (recommended)** / B) wait for payout rail design | **A** - include read-only settlement-ready rows and settlement history in v1; SPEC-005 already emits `ledger_payout_ready`, and SPEC-007 explorer may observe but must not claim, consume, void, or pay rows. |
| D12 | Index posture | A) **Add only measured-needed indexes (recommended)** / B) proactively add provider/time and buyer rollup indexes | **A** - start with existing indexes plus bounded date windows, cursors, limits, and query timeouts; add only indexes required by implementation tests or measured slow queries. No materialized rollups or proactive analytics indexes in v1. |
| D13 | Public explorer scope | A) **Treat public explorer as later SPEC (recommended)** / B) include redaction endpoints now | **A** - public explorer is a later SPEC; v1 is internal-only and may expose operator-only fields behind admin auth. Do not build redaction endpoints, public schemas, or public rate limits in SPEC-007 v1. |
| D14 | V1 success bar | A) **One operator can answer live state, recent activity, buyers, providers, ledger, settlements, and health in under two minutes (recommended)** / B) analytics-grade charts | **A** - v1 succeeds when the operator can answer the core operational questions in under two minutes using tables, status strips, filters, and detail views; analytics-grade charts, long-horizon BI, and public explorer polish are later work. |

---

## Gate checks before moving to BUILD

- [x] All 14 rows have a decision.
- [x] Internal-only v1 is preserved: no public explorer, no public redaction endpoints, no multi-tenant auth.
- [x] Read-only boundary is preserved: explorer observes; payout claim/consume/void, provider admission, key issuance, and kill switches stay on existing non-explorer admin surfaces.
- [x] Coordinator remains the explorer origin for v1, but buyer data remains gateway-owned.
- [x] No parallel analytics data store, materialized cache, or durable provider-event table is introduced in v1.
- [x] SPEC-005 settlement handoff is respected: `ledger_payout_ready` rows are visible but not mutated.
- [x] Refresh model is polling-first with hidden-tab pause and bounded server-side limits.
- [x] Public-safe tags remain design/spec metadata only; endpoint schemas do not carry tag metadata in v1.
- [ ] File committed to git before drafting `specs/BUILD_SPEC_007_IMPL_PROMPT.md`.
