# Build prompt — Phase 6 front-door (console.streamvc.live)

Operator-paste prompt to ship a credible buyer-facing surface on top of
the live Phase 5 gateway. Closes the UX gap surfaced in Decision log
Entry 27: the gateway is OpenAI-compatible and live at
`api.streamvc.live`, but the `/account` page is a 3-line HTML string,
there is no demo-without-signup surface on a real branded URL, no docs,
no Copy button, no trust signal for the Tier 1 disclosure.

Locked spec corpus this prompt builds against (do NOT modify):

  SPEC-001 v1.2.4 — phase3-binary provider protocol
  SPEC-002 v1.1.5 — phase4-coordinator router
  SPEC-003 v0.7   — open onboarding + distribution
  SPEC-006 v0.6   — buyer API gateway

This prompt does NOT relitigate spec design. It implements front-door
UX against the spec corpus as-is, with one scoped gateway code change
(CORS) tracked as an audit-category-A finding in advance.

Output: living infrastructure plus committed code:

- `frontdoor/console/` — new repo subdir with the static HTML/CSS/JS
  served at `console.streamvc.live`
- `phase5-gateway/internal/router/server.go` — CORS middleware for
  4 demo-path endpoints (strict origin allowlist)
- `phase5-gateway/internal/router/server.go` — `/account` HTML
  template hardened with copy button, "I saved it" checkbox, three
  code snippets, collapsible Tier 1 disclosure
- `phase5-gateway/internal/router/server.go` — `/docs` route serving
  a static markdown-rendered page
- `frontdoor/console/dist/nginx-console.streamvc.live.conf` — nginx
  vhost
- `beta/DECISION_CRITERIA.md` — Entry 28 capturing the arc

Architecture decision **Bδ** is locked:

  Browser at `https://console.streamvc.live` →
    static HTML served by nginx on Pearl from `/var/www/console` →
    direct `fetch()` calls to `https://api.streamvc.live/v1/...` →
    gateway with strict-allowlist CORS for the 4 demo endpoints

No Vercel functions. No proxy hop. No new vendors. Direct browser →
gateway path is the fastest perceived UX and the most credible network
tab impression for evaluating developers.

Run in **Claude Code** (Sonnet for the bulk; Opus for the CORS code
change and audit-response cycle). Expected duration: **~3 days of
focused work**, broken into 5 sub-phases (6a → 6e) with checkpoint
reports.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are shipping the Mac Provider front-door at console.streamvc.live,
following the SPEC-006 v0.6 buyer-API contract that is already live on
api.streamvc.live. The gateway works, the API works, the OAuth signup
works, an `mp_` key was minted live in Decision log Entry 27. What is
missing is the buyer-facing UX layer.

You will produce changes in two trees:

  /Users/augstar/macprovider-poc/frontdoor/console/  (NEW static site)
  /Users/augstar/macprovider-poc/phase5-gateway/     (CORS + /account
                                                      template + /docs)

## Critical constraints

**1. SPEC-001 v1.2.4, SPEC-002 v1.1.5, SPEC-003 v0.7, SPEC-006 v0.6
are LOCKED.** Do NOT modify any spec text in this phase. The Tier 1
disclosure properties in SPEC-006 v0.6 § 1.6 are the single source of
truth — your UI surfaces them verbatim, you do not paraphrase.

**2. The gateway code change is scoped to CORS + /account template +
/docs route.** Do NOT add new endpoints, do NOT change auth, do NOT
touch the streaming path, do NOT modify the quota or feedback or admin
surfaces. Drift outside this scope is grounds for audit rejection.

**3. CORS allowlist is strict.** Allowed origins are EXACTLY:
   - `https://console.streamvc.live`
   - `https://streamvc.live`
No wildcards. No `null`. No localhost in production builds. Local dev
allowlist (e.g. `http://localhost:5173`) is gated by a build-time flag
or by env var; never in production binary.

**4. CORS scope is endpoint-specific.** Allowed endpoints are EXACTLY:
   - `POST /auth/demo-session`
   - `POST /v1/chat/completions` (demo-token or bearer)
   - `GET  /v1/models`
   - `GET  /v1/status`
Admin endpoints, OAuth callbacks, and account/key endpoints are NOT
CORS-enabled. They remain same-origin only.

**5. The static console must work without JavaScript frameworks.**
Vanilla HTML + CSS + JS. No React, no Vue, no Svelte, no build step.
The page must be < 30KB compressed. This is a constraint, not a
suggestion — it forces the demo to be a single auditable file.

**6. The demo token never enters the URL.** Use the `X-Demo-Token`
header per SPEC-006 v0.6 § 7. Tokens in URLs leak through referrer
headers, logs, and CDN traces.

**7. The Tier 1 disclosure block in SPEC-006 v0.6 § 1.6 surfaces in
the UI verbatim** as a collapsible "Privacy notes" section, with the
four properties (plaintext_to_provider, model_identity,
hardware_attestation, tier2_milestone) displayed. The wording in the
spec is the wording in the UI.

**8. Operator never sees the API key client-side.** The `/account`
page is the only surface that displays the raw `mp_` key, and only on
the one-shot post-signup render where the `mp_new_api_key` cookie is
present. After this render, the key is unrecoverable — confirm via
the existing one-shot cookie unset on read.

**9. The gateway binary stays single-binary.** /docs is rendered by
the gateway from an embedded template or `embed.FS` filesystem — no
new files at runtime, no NFS, no S3. Per SPEC-006 v0.6 § 4 the gateway
remains self-contained.

## Phase 6a — Gateway /account UX hardening (1 day)

### Scope

Replace `phase5-gateway/internal/router/server.go` handleAccount
inline HTML (current state: 3-line string) with a templated page:

- Go `html/template` (NOT `text/template` — XSS protection mandatory)
- Embedded template via `embed.FS`, located at
  `phase5-gateway/internal/router/templates/account.html`
- Inline CSS only (no external stylesheets, no font CDN, no analytics)
- System UI font stack: `-apple-system, BlinkMacSystemFont, "Segoe UI",
  Roboto, sans-serif`
- Dark theme matching the eventual console aesthetic (gh-style colors:
  bg `#0d1117`, panel `#161b22`, border `#30363d`, text `#c9d1d9`,
  accent `#58a6ff`, ok `#3fb950`)
- Mobile responsive (single-column under 720px)

### Two states

**State A: signed-in, cookie `mp_new_api_key` present (one-shot key
display):**

- Heading: "Welcome to Mac Provider"
- Subheading: "Your API key is shown once. Save it now."
- API key in a `<code>` block with a "Copy to clipboard" button
  (Clipboard API, fallback to `document.execCommand` for older Safari)
- A required `<input type=checkbox id=saved>` "I have saved my key
  somewhere safe" — the "Continue to docs" CTA is `disabled` until
  the checkbox is checked
- Below the key: three tabbed code snippets (curl, openai-python,
  openai-node) — tabs are vanilla CSS+JS (no framework). Each snippet
  uses the actual key the buyer just minted via template interpolation
- Collapsible "Privacy notes" `<details>` with the Tier 1 disclosure
  block surfaced verbatim
- Footer with links: `Documentation` (→ /docs), `Status` (→ /v1/status
  rendered as JSON in a new tab), `Disclosures` (→ /docs#disclosures)

**State B: signed-in, no `mp_new_api_key` cookie (no key to display):**

- Heading: "Mac Provider account"
- Body: "No new API key to display. If you have lost your key, you can
  mint a new one by signing in again." Link to `/auth/github/start`.
- Footer same as State A

### Acceptance criteria

**AC-1 PASS:** `go test ./internal/router/...` passes including a new
test that GETs `/account` with the cookie set and asserts the template
renders the key in a `<code>` block, the checkbox is present, all
three code snippet tabs are present.

**AC-2 PASS:** A new test that GETs `/account` without the cookie
asserts the State B rendering and confirms the API key is NOT present
anywhere in the response body.

**AC-3 PASS:** Lighthouse Accessibility score ≥ 90 (run via
`npx --yes lighthouse https://api.streamvc.live/account
--only-categories=accessibility --output=json` against the deployed
binary; verification is MANUAL after deploy).

**AC-4 PASS:** Page weight (HTML + inline CSS + inline JS) under 20KB
uncompressed. Measure with `curl -s
https://api.streamvc.live/account | wc -c`.

**AC-5 PARTIAL acceptable:** Copy button works via Clipboard API in
modern browsers; document the fallback path explicitly in a code
comment.

**AC-6 PASS:** `/account` template references the four Tier 1
disclosure properties from SPEC-006 v0.6 § 1.6 verbatim. A spec-link
unit test diffs the displayed text against the spec text and fails on
drift.

## Phase 6b — Gateway CORS for 4 demo endpoints (0.5 day)

### Scope

Add CORS handling to the gateway HTTP server. Implementation MUST be:

- A new middleware in `phase5-gateway/internal/router/cors.go`
- Applied only to the 4 demo-allowed endpoints listed in the
  Critical Constraints § 4 (NOT globally — wrapping the whole mux
  with permissive CORS is grounds for audit rejection)
- Origin allowlist sourced from a new gateway.yaml block:
  ```
  cors:
    allowed_origins:
      - https://console.streamvc.live
      - https://streamvc.live
  ```
- The allowlist is matched EXACTLY (case-sensitive string match, no
  prefix matching, no wildcard expansion).
- Preflight `OPTIONS` requests respond with 204 and the correct
  `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers`,
  `Access-Control-Max-Age: 3600` headers.
- Actual cross-origin requests have:
  - `Access-Control-Allow-Origin: <echoed-origin>` (NEVER `*`)
  - `Vary: Origin` (mandatory for cache-correctness)
  - `Access-Control-Allow-Credentials: false` (demo path is stateless)
- Mismatched origins receive NO CORS headers (browser blocks
  client-side; gateway never reveals the allowlist by error message)

### Acceptance criteria

**AC-7 PASS:** Unit test in `phase5-gateway/internal/router/cors_test.go`
covering: allowed origin → headers present; disallowed origin →
headers absent; preflight OPTIONS → 204 with correct allow-methods;
allowlist case-sensitive (mixed case fails).

**AC-8 PASS:** Curl-based integration test from a non-allowed origin:
`curl -i -H "Origin: https://attacker.com"
https://api.streamvc.live/v1/status` returns the response WITHOUT
`Access-Control-Allow-Origin` header.

**AC-9 PASS:** Curl preflight from allowed origin: `curl -i -X OPTIONS
-H "Origin: https://console.streamvc.live" -H
"Access-Control-Request-Method: POST"
https://api.streamvc.live/v1/chat/completions` returns 204 with
correct allow-methods including POST.

**AC-10 PASS:** Endpoints not in the demo allowlist (e.g. `/account`,
`/auth/github/callback`, `/admin/feedback-summary`) do NOT add CORS
headers even for allowed origins. Test by curling from
`https://console.streamvc.live` Origin.

**AC-11 PASS:** Audit category A (CORS misconfiguration) is added to
the phase-end handback. Specifically scan for: wildcard `*`,
prefix-match, missing `Vary`, credentials-with-wildcard, allow-list
leakage via error message.

## Phase 6c — frontdoor/console/ static site (1 day)

### Scope

New repo subdir:

  /Users/augstar/macprovider-poc/frontdoor/console/
    index.html
    dist/nginx-console.streamvc.live.conf
    README.md

`index.html` is a single self-contained file (HTML + inline CSS +
inline JS). Total < 30KB.

### Page content (anonymous state — no signed-in dashboard in this phase)

**Header (sticky):**
- Logo / wordmark: "Mac Provider"
- Right side: `Status: ● up` (live from `/v1/status`), `Sign in`
  button → `https://api.streamvc.live/auth/github/start`

**Main column (left, ~70%):**
- Chat interface:
  - Single textarea for prompt entry (Cmd-Enter to send)
  - Send button
  - Streamed response area below (SSE rendered as plain text, no
    markdown rendering — this is a try-it-now surface, not a chat app)
  - Per-message footer showing: model used, tokens used, wall time
- "Suggested prompts" pills above the textarea: 3 prompts that
  demonstrate non-trivial inference (translation, summarization, a
  simple code generation). Click pill = fill textarea.

**Sidebar (right, 360px on desktop, below on mobile):**
- Trust banner section "Privacy notes" with the four Tier 1 properties
  rendered as a list, copied verbatim from SPEC-006 v0.6 § 1.6
- "Free during beta — 1000 tokens/IP/day" quota note
- "Like this? Get an API key →" CTA → `/auth/github/start`
- Status box: pool size (from `/v1/status`), models available, when
  data was last refreshed

**Footer:**
- Links: `Documentation` (→ api.streamvc.live/docs),
  `Status` (→ api.streamvc.live/v1/status),
  `API reference` (→ docs#api),
  `Disclosures` (→ docs#disclosures)

### Client-side flow

1. On page load:
   - `GET https://api.streamvc.live/v1/status` to populate sidebar
   - `GET https://api.streamvc.live/v1/models` to learn which models
     are available (no auth — but wait, `/v1/models` currently
     requires bearer — see open question O-6c-1 below)
   - `POST https://api.streamvc.live/auth/demo-session` to mint a
     demo token, store in memory only (NOT localStorage, NOT cookies)
2. On user prompt:
   - `POST https://api.streamvc.live/v1/chat/completions` with
     `X-Demo-Token: <token>`, `Accept: text/event-stream`
   - Render SSE chunks into the response area
3. On error:
   - Display human-readable error from the OpenAI envelope
   - Surface `request_id` from response header for support handoff

### Open questions raised by this phase (to file in phase-end handback,
do NOT decide unilaterally)

**O-6c-1:** `/v1/models` currently requires bearer auth (handleModels
calls `s.authenticateAny(w, r)` and returns 401 without). The console
demo state needs `/v1/models` without auth — either:
  (a) add demo-token support to `/v1/models` (gateway code change,
      spec-aligned per SPEC-006 v0.6 § 9 if demo-token-allowed-on-models
      can be added without contradicting other SPEC text)
  (b) replace `/v1/models` call with parsing the `/v1/status` response,
      which already lists models without auth
  (c) hardcode the model list in the static HTML (fragile, drifts)

Recommended: (b) — `/v1/status` already includes per-model
`provider_count`, `total_slots`, `slots_free`, `max_context_tokens`.
Use that, no gateway change needed.

**O-6c-2:** Suggested prompts must NOT execute by themselves on click —
they fill the textarea but require explicit Send click. Otherwise
fast clicks across pills could rapidly burn demo quota and confuse
buyers about token usage.

**O-6c-3:** The free-tier quota (1000 tokens/IP/day) is per-IP — make
this explicit in the sidebar so buyers behind shared NATs are not
confused when they hit quota faster than expected.

### Acceptance criteria

**AC-12 PASS:** `frontdoor/console/index.html` is a single file under
30KB. Measure with `wc -c`.

**AC-13 PASS:** Page loads with NO requests to third-party origins
(no Google Fonts, no analytics, no CDN-hosted JS). Verify in dev tools
Network tab → only requests to `api.streamvc.live`.

**AC-14 PASS:** First-render does NOT make any API calls until either
(a) page is interactive or (b) the user scrolls into the sidebar. The
initial `/v1/status` call is acceptable; the `/auth/demo-session`
call MUST be deferred until first user input event.

**AC-15 PASS:** Chat round-trip works end-to-end against
`https://api.streamvc.live` via CORS, for at least 3 consecutive
prompts. Measure that demo-token quota is decremented (verify by
hitting `/v1/usage` with the demo token — if that endpoint accepts
demo tokens; otherwise PARTIAL with a manual SQL check on
`/var/lib/macprovider/gateway.db`).

**AC-16 PASS:** Tier 1 disclosure block in sidebar matches SPEC-006
v0.6 § 1.6 text exactly. A grep-based test in the audit cycle diffs
the visible HTML text against the spec text.

**AC-17 PASS:** Mobile breakpoint at 720px: sidebar moves below main
column, chat area takes full width. Verify with browser dev tools
mobile emulation.

**AC-18 PASS:** Page passes Lighthouse Accessibility ≥ 90 and
Performance ≥ 90 (the Performance bar is loose on intentionally
minimal pages; mainly verifying we don't ship a 5MB image). MANUAL.

## Phase 6d — console.streamvc.live infrastructure (0.5 day)

### Scope

- Cloudflare DNS A record: `console.streamvc.live` →
  `159.223.165.194`, DNS-only (proxied:false), TTL 300s
- nginx vhost at `/etc/nginx/sites-available/console.streamvc.live`
  serving `/var/www/console/index.html` over TLS
- Let's Encrypt cert via certbot --webroot bootstrap pattern (proven
  in Entry 27 — reuse the same procedure)
- HTTP→HTTPS 301 redirect
- HSTS `max-age=31536000; includeSubDomains`
- Cache-Control `public, max-age=300` on the static HTML (5 min cache
  is short enough for fast iteration, long enough to absorb traffic)

### Acceptance criteria

**AC-19 PASS:** `curl -sI https://console.streamvc.live/` returns
HTTP 200, valid TLS cert, HSTS header, `Cache-Control: public,
max-age=300`. MANUAL verification.

**AC-20 PASS:** `curl -sI http://console.streamvc.live/` returns
HTTP 301 with `Location: https://console.streamvc.live/`. MANUAL.

**AC-21 PASS:** `certbot renew --dry-run` passes for the
`console.streamvc.live` cert. MANUAL.

## Phase 6e — Gateway /docs page (0.5 day)

### Scope

New gateway route `GET /docs` rendering a single static page from an
embedded markdown source via `embed.FS`. The markdown is at
`phase5-gateway/internal/router/templates/docs.md`. Conversion via
the `github.com/yuin/goldmark` library (already a stdlib-adjacent
choice for self-contained Go binaries; if not already a dep, add it
to `go.mod` with version pinning).

### Content (single page, ~400 lines markdown)

- **# Getting started**
  - Sign up via GitHub
  - Save your `mp_` key
  - Use any OpenAI SDK with `base_url=https://api.streamvc.live/v1`
- **# Quickstart code samples**
  - curl
  - openai-python
  - openai-node
  - openai-go
- **# Models**
  - Current model list (auto-populated from `/v1/models` at build
    time, OR statically listed with a note "see /v1/models for
    current list")
- **# Quotas and limits**
  - Free beta: 100,000 tokens/account/day, 4096 tokens/request,
    2 concurrent requests/account
  - Demo: 1000 tokens/IP/day, 512 tokens/request, 10 sessions/IP/hour
- **# Streaming vs non-streaming**
  - Both supported; non-streaming has a 120s upper bound (per G1
    from Entry 27); streaming chunks can take up to 120s end-to-end
- **# Disclosures**
  - Tier 1 disclosure block from SPEC-006 v0.6 § 1.6 verbatim
  - "What this means for your prompts and outputs"
  - Tier 2 roadmap (currently "future")
- **# Status and reliability**
  - Link to `/v1/status`
  - Current pool size, known limitations
  - "Found a bug? Contact: ..."
- **# Errors**
  - OpenAI-envelope error structure
  - Common error codes with example responses

### Acceptance criteria

**AC-22 PASS:** `GET /docs` returns HTTP 200 with HTML rendered from
embedded markdown. Test by curling and asserting `<h1>Getting
started</h1>` appears in body.

**AC-23 PASS:** No external CSS/JS/fonts. Inline only. Page weight
under 50KB.

**AC-24 PASS:** Anchor links work for `#disclosures`, `#getting-started`,
`#quotas-and-limits` (these are referenced from console sidebar and
account page CTA).

**AC-25 PASS:** Lighthouse Accessibility ≥ 90, Performance ≥ 90.
MANUAL.

## Cross-cutting acceptance criteria

**AC-26 PASS:** `go build ./...` passes from `phase5-gateway/` root.

**AC-27 PASS:** `go test ./...` passes from `phase5-gateway/` root.

**AC-28 PASS:** No new gateway endpoints beyond `/docs`. The mux
registration in `setupRoutes` adds exactly one new HandleFunc.

**AC-29 PASS:** Decision log Entry 28 drafted in `beta/DECISION_CRITERIA.md`
capturing this arc, in the same three-column format as Entries 26-27.

## Audit categories for the post-implementation cycle

After all 5 phases are implemented and unit tests pass, run an audit
cycle in a separate session (Codex preferred per the pattern from
Entry 27) covering:

**Category A (CORS misconfiguration):** Specifically scan for:
- Wildcard `*` in any CORS header
- Prefix-match (e.g. `https://*.streamvc.live`) which is exploitable
- Credentials + permissive origins
- Missing `Vary: Origin`
- Allowlist leakage via error message
- Demo-token endpoints reachable from non-allowlist origins

**Category B (Demo token abuse):** Specifically scan for:
- Demo token in URL (referrer leak)
- Demo token persisted in localStorage or cookies (XSS leak)
- Demo token from console reusable from another IP
- Demo signing secret recoverable from gateway binary (it shouldn't
  be; it's an env var, but confirm)
- Demo quota bypassable by IP spoofing in X-Forwarded-For (gateway
  must use the nginx-set X-Real-IP per Entry 27 PG-1)

**Category C (Account page UX):** Specifically scan for:
- API key reflected back in response for non-cookie-bearing requests
  (state B should never show the key)
- API key persisted to logs
- API key visible in browser history (URL fragment)
- Copy button works without JS (graceful degradation acceptable but
  documented)
- Checkbox not enforceable server-side (it's client-side gating;
  document this)

**Category D (Static frontend XSS):** Specifically scan for:
- Any `innerHTML =` assignment using user input or API responses
- Any `eval()` or `Function()` constructor
- Any `dangerouslySetInnerHTML` equivalent
- SSE chunk rendering: chunks must be inserted as `textContent` not
  `innerHTML`

**Category E (Quota enforcement on demo path):** Specifically scan for:
- Demo path bypassing standard quota middleware
- Demo token replay attacks (token reuse from same IP after expiry)
- Demo session reuse across IPs

**Category F (Spec compliance):** Specifically scan for:
- Tier 1 disclosure text drift between SPEC-006 v0.6 § 1.6 and the
  rendered UI (run `diff` between spec text and template strings)
- Quota numbers in docs page drifting from gateway.yaml
- SPEC-006 v0.6 § 22 launch gate checklist item references that
  should now be satisfied (8 items) — update item status if so

## Operator checkpoint protocol

After each phase 6a-6e is implemented and its ACs pass, report back to
operator with:

1. List of files created or modified
2. Each AC marked PASS / PARTIAL / MANUAL with one-line justification
3. Open questions raised during implementation (file in phase-end
   handback summary)
4. Approximate token spend so far
5. STOP and wait for operator review before starting the next phase

After Phase 6e and the cross-cutting ACs pass, prepare the BUILD →
AUDIT handback (file as `specs/PHASE6_FRONTDOOR_BUILD_REPORT.md`) so
the audit session has a clean starting point.

After the audit cycle (separate session) returns findings, prepare a
`specs/FIX_PHASE6_FRONTDOOR_PROMPT.md` per the Entry 27 pattern.

After the FIX cycle and one regression audit (V2 if needed),
operator deploys: cross-compile gateway, SCP to Pearl, swap binary,
SCP `frontdoor/console/index.html` to `/var/www/console/`,
SCP nginx vhost, enable, reload, smoke.

Decision log Entry 28 captures the full arc.

=== END PROMPT ===
```

---

## Operator notes (not part of pasted prompt)

**Recommended model split for this phase:**

- Phases 6a, 6c, 6d, 6e: Sonnet (template work, static HTML, nginx
  config, markdown)
- Phase 6b (CORS code change): Opus (security-sensitive; one mistake
  = audit-category-A finding)
- Audit cycle: Codex (cross-tool review per Entry 27 pattern)
- FIX cycle: Sonnet for mechanical patches, Opus if findings require
  architectural decisions

**Estimated cost: ~$15-25 in API spend across BUILD + AUDIT + FIX.**

**Dependencies that must be true before starting:**

- `api.streamvc.live` live with valid TLS (✅ as of Entry 27)
- Gateway G1+G2+G3 deployed (✅ as of Entry 27)
- Pool with N≥2 healthy providers (✅ as of last check)
- Cloudflare API token available for the DNS step (✅ stored at
  `~/.config/macprovider/cloudflare-api-token` per Entry 27; revoke
  + recreate if TTL has expired)

**What this phase does NOT include (file as Phase 7 backlog):**

- Buyer dashboard (key list, regenerate, revoke, usage chart)
- Marketing landing at `streamvc.live` root
- Billing / metering surface
- Pricing decision (currently "free during beta")
- Multiple keys per account
- Email magic-link signup (currently GitHub-only per gateway.yaml)
- API embedding / SSO partner integrations

**What this phase ALSO does NOT include (file as Phase 6 backlog if
discovered during implementation):**

- The underlying coordinator fast-fail on dead provider WS (Entry 27
  Phase 6 backlog item)
- The phase3-binary keepalive root cause for air5's 3-5 min reconnect
  cycle (Entry 27 Phase 6 backlog item)
- Audit category Z fault-injection test rig (Entry 27 Phase 6 backlog
  item)

Those are engineering, not UX. They can ship independently in parallel.

---

## Filing this prompt

After reviewing this draft, the operator workflow is:

1. Read top-to-bottom; flag any constraints to soften or tighten
2. Decide on the open-question recommendations (O-6c-1 (b) is
   pre-committed in the prompt; O-6c-2, O-6c-3 should be operator-
   confirmed before paste)
3. Paste the `=== BEGIN PROMPT === ... === END PROMPT ===` block into
   a fresh Claude Code session rooted at the repo
4. Walk through phase-by-phase checkpoints
5. Run audit cycle after Phase 6e completes
6. Iterate FIX → regression-audit → deploy
7. Entry 28 in DECISION_CRITERIA.md

Expected calendar duration: **3 working days** at focused-session pace,
plus 1 audit cycle + 1 FIX cycle = total ~4-5 days end-to-end before
console.streamvc.live ships green.
