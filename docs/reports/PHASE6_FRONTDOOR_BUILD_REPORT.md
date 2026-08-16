# Phase 6 front-door build report

Date: 2026-05-29

## Summary

Implemented the buyer-facing front door for `console.malibu.tech` and the scoped gateway support work:

- New static console in `frontdoor/console/`
- Endpoint-scoped CORS for the four demo/browser endpoints
- Embedded `/account` template with one-shot key UX, copy button, save checkbox, snippets, and Tier 1 disclosures before key presentation
- Embedded `/docs` markdown page rendered by the gateway with `goldmark`
- nginx vhost for `console.malibu.tech`
- Decision log Entry 28

No locked spec files were modified.

## Files created or modified

- `frontdoor/console/index.html`
- `frontdoor/console/README.md`
- `frontdoor/console/dist/nginx-console.malibu.tech.conf`
- `phase5-gateway/gateway.yaml.example`
- `phase5-gateway/go.mod`
- `phase5-gateway/go.sum`
- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/cors.go`
- `phase5-gateway/internal/router/cors_test.go`
- `phase5-gateway/internal/router/pages.go`
- `phase5-gateway/internal/router/pages_test.go`
- `phase5-gateway/internal/router/templates/account.html`
- `phase5-gateway/internal/router/templates/docs.md`
- `beta/DECISION_CRITERIA.md`
- `specs/PHASE6_FRONTDOOR_BUILD_REPORT.md`

## Acceptance criteria

| AC | Status | Evidence |
|---|---|---|
| AC-1 | PASS | `TestAccountTemplateDisplaysKeyAndSnippets` checks key `<code>`, checkbox, and three tabs. |
| AC-2 | PASS | `TestAccountTemplateWithoutCookieDoesNotLeakKey` checks State B and no `mp_` text. |
| AC-3 | MANUAL | Requires deployed Lighthouse run against `https://api.malibu.tech/account`. |
| AC-4 | PASS | Account template is 6,425 bytes unrendered, below 20KB. |
| AC-5 | PASS | Copy button uses Clipboard API with `document.execCommand` Safari fallback comment. |
| AC-6 | PASS | `TestTier1DisclosureMatchesSpecSection16` compares disclosure text against SPEC-006 section 1.6. |
| AC-7 | PASS | `cors_test.go` covers allowed, disallowed, preflight, and case-sensitive origins. |
| AC-8 | MANUAL | Requires public curl after deploy. |
| AC-9 | MANUAL | Requires public curl after deploy. |
| AC-10 | PASS | `TestCORSNotAppliedToNonDemoEndpoints` covers `/account`, OAuth callback, and admin summary. |
| AC-11 | PASS | Static scan found no wildcard CORS, no prefix match, `Vary: Origin` is set, credentials is `false`, and disallowed origins get no CORS headers. |
| AC-12 | PASS | `frontdoor/console/index.html` is 10,076 bytes. |
| AC-13 | PASS | Static URL scan shows only `https://api.malibu.tech` external references. |
| AC-14 | PASS | Console calls `/v1/status` on load; `/auth/demo-session` is deferred until first prompt input or send. |
| AC-15 | MANUAL | Requires deployed CORS + live demo-token smoke. |
| AC-16 | PASS | Console sidebar contains the SPEC-006 section 1.6 disclosure text. |
| AC-17 | PASS | CSS breakpoint `@media(max-width:720px)` moves the grid to one column. |
| AC-18 | MANUAL | Requires deployed Lighthouse run. |
| AC-19 | MANUAL | Requires DNS, TLS, nginx deployment. |
| AC-20 | MANUAL | Requires DNS, TLS, nginx deployment. |
| AC-21 | MANUAL | Requires certbot on Pearl. |
| AC-22 | PASS | `TestDocsRouteRendersMarkdown` checks rendered `<h1 id="getting-started">Getting started</h1>`. |
| AC-23 | PASS | Docs source is 5,187 bytes; route wrapper is inline CSS only. |
| AC-24 | PASS | Docs test checks `#getting-started`, `#disclosures`, and `#quotas-and-limits`. |
| AC-25 | MANUAL | Requires deployed Lighthouse run. |
| AC-26 | PASS | `GOCACHE=/private/tmp/macprovider-go-build-cache GOPATH=/private/tmp/macprovider-go go build ./...` passed. |
| AC-27 | PASS | `GOCACHE=/private/tmp/macprovider-go-build-cache GOPATH=/private/tmp/macprovider-go go test ./...` passed. |
| AC-28 | PASS | `server.go` adds exactly one new route, `/docs`; CORS wraps existing four demo-allowed routes. |
| AC-29 | PASS | Entry 28 drafted in `beta/DECISION_CRITERIA.md`. |

## Open questions and handback notes

- O-6c-1 resolved with recommendation (b): console derives models from `/v1/status`; no extra gateway endpoint or auth behavior change.
- O-6c-2 resolved as specified: suggested prompts only fill the textarea.
- O-6c-3 resolved as specified: quota copy says `1000 tokens/IP/day` and mentions shared NATs.
- Deployment ACs remain manual because DNS, certbot, nginx enablement, and live Lighthouse runs are operator-side infrastructure steps.
- The Phase 6 `/account` page is a one-shot key handoff surface. A full buyer dashboard remains a Phase 7 backlog item and is not claimed by this build.

## Audit focus

- Category A: CORS is endpoint-scoped and exact-origin only.
- Category B: demo token is in memory only, never URL/localStorage/cookie.
- Category C: one-shot key display remains cookie-gated and unset on read.
- Category D: console SSE rendering uses `textContent`/text nodes; no `innerHTML`.
- Category F: disclosure text is tested against SPEC-006 section 1.6.
