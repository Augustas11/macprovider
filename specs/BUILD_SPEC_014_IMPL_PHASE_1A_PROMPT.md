# Implementation BUILD prompt — SPEC-014 Phase 1A (Provider Portal scaffolding + auth + deployment-mode + Surface A)

Operator-paste prompt for Codex GPT-5 to land the **first** of three
implementation sub-phases of SPEC-014 v0.8 in
`frontdoor/provider-portal/`. This phase establishes the single-file
bundle, the operator-declared deployment-mode loader, the sign-in
screen, the authenticated request layer, and Surface A (Machine).
Phases 1B (Setup & Updates + version feed) and 1C (Earn + Monitoring
+ Identity + sidebar polish + build-time grep guard) build on it.

**Scope: SPEC-014 §11 Phase 1A only.** Concretely:
- §2 AUTH-1 / AUTH-2 / AUTH-3 (sign-in + bearer + path subject +
  operator-declared `portal-config.json` fail-CLOSED loader).
- §3 layout shell (220 px sidebar + main; mobile breakpoint).
- §4.1 Surface A (Machine dashboard): A.1 header strip + A.2
  counters row + A.3 single-row needs-attention panel.
- §5.4 thresholds (30 s pool poll, 60 s earnings poll, 60 s
  earnings cache TTL, 2× cadence stale stamp).
- §6 visual tokens (SPEC-009 §6 verbatim).
- §7 non-goals enforced (no remote command execution, no
  `localStorage`/`sessionStorage`/cookie session, no operator key
  prompted/parsed/transmitted).

OUT OF SCOPE for Phase 1A: Surface B / C / D / E (sidebar items
exist and switch the active surface, but non-Machine surfaces
render a one-line "coming in phase 1B/1C" stub). GitHub Releases
feed lives in Phase 1B; build-time grep guard `check-bundle.sh`
lives in Phase 1C.

**One-line summary.** Create `frontdoor/provider-portal/index.html`
(single file, inline JS+CSS, no build step, no CDN) implementing
the AUTH-3 loader, the AUTH-1 sign-in screen, the AUTH-2 fetch
layer, and Surface A — with all polling, caching, stale-stamp, and
401/403/404 handling per SPEC-014 §2 + §4.1 + §5.4.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-014 v0.8 (this is the spec — §1, §2, §3, §4.1, §5.1, §5.2,
  §5.4, §6, §7, §8(a)/8(b)/8(c)/8(d)/8(f) ACs are binding for
  Phase 1A; §8(e) Open-Q ACs Q1/Q5/Q7/Q8/Q9/Q10/Q11 are binding
  in this phase).
- SPEC-002 v1.3.5 (`GET /v1/pool/check?provider_id=<id>` shape;
  FR-P12 bearer; §7.3 token opacity).
- SPEC-005 v0.3 (`GET /providers/{provider_id}/earnings` shape +
  §11.5 401/403/404 contract + §1.3 / §2.1 D1 / §2.11 D11
  scope-cuts that bind UI).
- SPEC-003 v0.9.2 (FR-C4 `macprovider-cli status` CLI verb cited
  by the A.3 remediation snippet).
- SPEC-009 v0.1 (§6 visual tokens; §2 sidebar geometry).

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` after edits — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~75-120 min
(one new HTML file ~700-900 lines including inline JS + CSS, one
small JSON example file).

Branch: `feat/spec-014-provider-portal` — the single unified branch
that carries the SPEC commit, all three implementation phases
(1A/1B/1C), their IMPL audit prompts, and their audit outputs.
The operator creates + checks out before pasting. Codex MUST NOT
create a new branch. **All three phases land as ONE PR**; the
audit gates between phases stop merges *within* this branch
(commit fixes until 0 CRITICAL/HIGH/MEDIUM, then proceed to the
next phase), not separate PRs.

---

```
=== BEGIN PROMPT ===

You are implementing Phase 1A of SPEC-014 v0.8 in the single-file
web bundle at /Users/augstar/macprovider-poc/frontdoor/provider-portal/.
SPEC-014 v0.8 is LOCKED. The scaffold directory exists; today it
holds only `.gitkeep` and a one-line README.md.

You will create/edit ONLY these files:

  frontdoor/provider-portal/index.html                  (NEW)
  frontdoor/provider-portal/portal-config.json.example  (NEW)
  frontdoor/provider-portal/README.md                   (extend)

You will NOT edit any file under specs/, phase3-binary/,
phase4-coordinator/, phase5-gateway/, frontdoor/console/, or
elsewhere. Verify with `git diff specs/ phase3-binary/
phase4-coordinator/ phase5-gateway/ frontdoor/console/` — must be
empty before you finish.

## Critical constraints

**1. Single file, no build step, no CDN.** `index.html` is the
ENTIRE bundle. All JS is inline `<script>`; all CSS is inline
`<style>`. NO `<script src=...>` to any third-party CDN, NO
`<link rel="stylesheet" href=...>` to any CDN, NO npm, NO bundler
output. This matches SPEC-009 §7's "no external runtime
dependencies" AC and SPEC-014's §11 Phase 1A "single-file
index.html with inline JS + CSS, no build step" requirement.

**2. AUTH-3 fail-CLOSED loader (§2.3).** On page load, BEFORE any
other network request:

  - `fetch("/portal-config.json", { cache: "no-store" })`.
  - On network rejection OR non-200 → render the unavailable-mode
    page naming the missing file path; do NOT make any other
    network call.
  - On successful JSON parse, validate STRICTLY:
    - Object only (not array, not null, not scalar).
    - Top-level keys MUST be a subset of EXACTLY:
      `{ "coordinator_base_url", "releases_repo_owner_name",
         "require_provider_tokens" }`.
      Any extra top-level key → fail-CLOSED with the unknown-key
      name in the error.
    - `coordinator_base_url`: non-empty string.
    - `releases_repo_owner_name`: non-empty string matching
      `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` (one slash, no scheme).
    - `require_provider_tokens`: strict `=== true` boolean. Any
      other value (including `false`, `"true"`, `1`, `null`) →
      render the unavailable-mode page with the §2.3 explanation
      ("the portal needs the coordinator to run with
      `auth.require_provider_tokens=true`; SPEC-002 FR-P12 +
      SPEC-005 §11.5 disable `GET /providers/{id}/earnings` at the
      route layer in `false` mode").
  - On ANY failure branch the bundle MUST make ZERO subsequent
    network calls — no `/v1/pool/check`, no `/providers/{id}/
    earnings`, no GitHub Releases. (Per AC 8(b): verified by
    network-panel observation or a fetch spy.)
  - The loader MUST NEVER read or display an operator key, even
    if one is present in `portal-config.json`. The unknown-key
    rejection above closes this hole.

**3. AUTH-1 sign-in (§2.1).** When the config validates,
render a sign-in screen with two REQUIRED inputs:
`provider_id` (text) and `provider_token` (password). Both
required; empty submit shows an inline error.

  - Session is stored ONLY in a JS module-scope object. Bundle
    MUST NEVER call `localStorage`, `sessionStorage`,
    `document.cookie`, or `window.indexedDB`. A grep for those
    identifiers MUST return zero from the rendered bundle.
  - On submit, transition to Surface A (Machine, default) and
    start the pollers.
  - "Sign out" (sidebar footer) clears the in-memory session,
    stops pollers, and returns to the sign-in screen.
  - A page reload returns the provider to the sign-in screen
    (no persistence) — this is explicit in §2.1 + §7.

**4. AUTH-2 status handling (§2.2).** Authenticated calls to
`/providers/{provider_id}/earnings`:

  - 401 → sign user back out to the sign-in prompt with copy
    that does NOT distinguish missing-vs-malformed token.
  - 403 OR 404 → render IDENTICAL "sign-in rejected" copy. The
    user MUST NOT be able to tell which status fired. Do NOT
    branch on 403 vs 404 in any user-visible way.
  - 5xx / other non-2xx → render an inline error on the
    earnings card; do NOT sign the user out.

**5. Stale-config guard (§2.3 final paragraph).** Track
`state.authFailBySurface[surface]` (incremented on 401/403/404 to
an authenticated provider endpoint; reset on success). After
TWO consecutive failures on the SAME surface within the SAME
signed-in session, ALSO show the explicit
`"Your deployment may be misconfigured — ask your operator to
verify portal-config.json against the coordinator's
auth.require_provider_tokens setting."` notice on the sign-in
screen. The first failure follows AUTH-2 (no misconfig notice).
The second consecutive failure ADDS the notice WITHOUT changing
the 403/404-identical copy.

**6. Same-origin proxy fail-loud (§3 + Open Q9).** All calls
to `/v1/pool/check` and `/providers/{id}/earnings` MUST use
SAME-ORIGIN relative paths (the operator's reverse proxy at the
portal origin colocates those routes — recommended option (a) in
§9 Q9). On a `fetch()` network-level rejection (TypeError /
DNS / connection refused) for either route, set a global
`state.proxyMissing = true` and render a loud red banner on
every surface naming SPEC-014 §3 / Open Q9. Do NOT fall back to
an absolute coordinator URL. Do NOT silently retry.

**7. Operator-key isolation (§2.2, §8(b)).** The bundle MUST
contain ZERO references to the strings `/poolz`, `/admin/blacklist`,
`/admin/provisional`, `/admin/promote`, `/admin/reject`, or
`/admin/ledger`. The bundle MUST NEVER prompt for, parse, or
transmit an `operator_key`. (The build-time grep guard is in
Phase 1C; Phase 1A still MUST satisfy the constraint.)

**8. Single-machine hygiene (§8(f)).** No copy may contain
"your fleet", "your machines", "across machines", "all
machines", "N machines", "N/M", "x3", or "machine grid". All
user-facing copy uses singular "this Mac" or "this machine".
There is no machine-count chip, no machine grid, no aggregation
header.

**9. Polling + cache + stale stamp (§5.4 thresholds).**
  - `/v1/pool/check` polled every 30 s, plus on manual refresh
    button (A.1).
  - `/providers/{id}/earnings` polled every 60 s; in-memory cache
    with 60 s TTL (do not re-fetch within TTL even if surface
    re-renders).
  - "Last refreshed Xs ago" stamp re-renders every 1 s; once
    `now - lastSuccessfulPoolPoll > 2 × 30_000 ms` the stamp text
    flips to literal `"stale"` with a warning color. A subsequent
    successful poll resets the label to `"Last refreshed Xs ago"`.

**10. Surface A — Machine (§4.1).**

  - **A.1 header strip**: shows `provider_id` (pasted session
    value, not from API), `tier` (from `/v1/pool/check.tier`),
    `state` (from `/v1/pool/check.state`), the stale stamp, and
    a manual refresh button. Online/offline pill maps
    `state ∈ {"ready","draining"}` → Online; `state ∈
    {"unavailable","unknown"}` → Offline. MUST NOT label the pill
    "heartbeat-current".
  - **A.2 counters row** (3 cards) from
    `/providers/{provider_id}/earnings`:
    - "Lifetime credits" ← `total_credits` (integer; en-US
      thousands separator OK).
    - "Current window" ← `current_window_credits` (integer).
    - "Last payout-ready window" ← `last_payout_ready.
      provider_credits` (integer) PLUS `window_start_utc` /
      `window_end_utc` in the card footer.
    - NO fiat conversion. NO "withdrawable balance" label. NO
      "$" symbol. Display units MUST match wire shape verbatim.
  - **A.3 needs-attention panel** — single issue type in v0.1:
    - When `/v1/pool/check.state ∈ {"unavailable","unknown"}`,
      render ONE row with the LITERAL text
      `"This machine is currently <state>."` (interpolate the
      state enum) and a one-line remediation hint
      `"Run macprovider-cli status to inspect local state; if
      the binary is healthy, re-check in a few seconds."` plus a
      copy-to-clipboard CTA for `macprovider-cli status`.
    - When state is online or unknown-not-yet-loaded, render a
      muted "Nothing to do — this Mac looks healthy." line.
    - No other issue types in v0.1 ("Update available",
      "Self-signed binary", "Model load failed" are all
      DEFERRED — see §5 table (c)).
  - **A.4** is NOT rendered at all (§5 table (c), entirely
    deferred behind Open Q5 / Q10).

**11. Sidebar shell (§3).**

  - 220 px fixed sidebar (matches SPEC-009 §2 verbatim).
  - Nav items in this order: Machine (default), Setup & Updates,
    Earn, Monitoring, Identity. All five render — but in Phase
    1A only Machine is implemented; Setup/Earn/Monitor/Identity
    render a one-line stub `"Coming in Phase 1B"` /
    `"Coming in Phase 1C"` so the user can click around.
  - Sidebar footer: external link to `https://api.streamvc.live/docs`
    (`target="_blank" rel="noopener noreferrer"`) and a "Sign out"
    button that clears the in-memory session.
  - Mobile breakpoint at 720 px: sidebar collapses behind a
    hamburger control OR hides gracefully (implementer's choice
    per §3). A scrim overlays the main pane when the sidebar is
    open on mobile.

**12. No remote command execution (§7).** EVERY CTA in the
bundle is a copy-to-clipboard shell snippet. There is no button
that POSTs / PUTs / DELETEs to the coordinator, the Mac, or any
agent. The bundle MUST NOT use `fetch()` with method other than
GET. There is no `XMLHttpRequest`, no `navigator.sendBeacon`, no
WebSocket.

**13. No autotune banner (§4.2 B.2 step 3 / SPEC-013 NFR-4).**
Phase 1A does not render Surface B yet, but for forward-
compatibility the bundle MUST NOT contain any string like "your
latest autotune recommended" anywhere.

**14. Visual tokens (§6 / SPEC-009 §6 verbatim).** Inline
`:root` CSS variables MUST be the SPEC-009 §6 set:
`--bg:#0c0d10; --sb:#111316; --surface:#16181d; --border:#252830;
--border2:#323743; --text:#e1e3e8; --muted:#878d99;
--hint:#4a5060; --accent:#7c6af6; --accent-dim:rgba(124,106,246,.14);
--ok:#22c55e; --warn:#f59e0b; --bad:#ef4444;` plus
`color-scheme:dark;`. Body font is
`-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Inter",
sans-serif`; code/labels use `ui-monospace, SFMono-Regular,
Menlo, Consolas, monospace`. No deviations.

## Required reading (in this order — read fully before writing)

1. `/Users/augstar/macprovider-poc/specs/SPEC-014-provider-portal.md`
   end-to-end. §2 (AUTH-1/2/3), §3 (layout + topology), §4.1
   (Surface A), §5.1 table (a) — every row Phase 1A renders,
   §5.4 thresholds, §6 visual tokens, §7 non-goals, §8(a)/8(b)/
   8(c)/8(d)/8(e Q1/Q7/Q8/Q9/Q10/Q11)/8(f) ACs.

2. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   §7.4 — `/v1/pool/check` request + response shape; specifically
   the `tier` enum (`"pinned"` / `"provisional"`) and the
   `state` enum (`"ready"` / `"draining"` / `"unavailable"` /
   `"unknown"`).

3. `/Users/augstar/macprovider-poc/specs/SPEC-005-billing.md`
   §11.4 — `/providers/{id}/earnings` response JSON shape
   (`total_credits`, `current_window_credits`,
   `last_payout_ready.{window_start_utc, window_end_utc,
   provider_credits}`); §11.5 401/403/404 contract.

4. `/Users/augstar/macprovider-poc/specs/SPEC-009-console-v2.md`
   §6 visual tokens (verbatim source) and §2 sidebar geometry
   (220 px). DO NOT inherit any other section normatively.

5. `/Users/augstar/macprovider-poc/frontdoor/console/index.html`
   — DO NOT copy code. Use as a reference for inline-CSS style,
   sidebar layout proportions, and `el(...)` DOM helper patterns
   you may want to mirror.

6. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions
   (commit identity is already correct on this branch; do NOT
   change git config). Note especially the "no money-path
   shortcuts" tone; the Provider Portal is read-side but it
   inherits the same audit discipline.

## Required edits — exact shape

### A. `frontdoor/provider-portal/portal-config.json.example` — NEW

Exactly this content (one trailing newline):

```json
{
  "coordinator_base_url": "https://coordinator.streamvc.live",
  "releases_repo_owner_name": "Augustas11/macprovider",
  "require_provider_tokens": true
}
```

### B. `frontdoor/provider-portal/index.html` — NEW

Single self-contained HTML file. Suggested top-level structure:

```
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>MacProvider — Provider Portal</title>
  <style> /* :root tokens + .shell + .sidebar + .main + .topbar +
            .surface chrome + .headstrip + .card + .pill + .stamp +
            .notice + .signin-* + .unavail-* + mobile @media */ </style>
</head>
<body>
  <div id="app"></div>
  <script> "use strict";
    /* State container, DOM helpers, loadConfig(), coordFetch(),
       poolCheck(), earnFetch(), handleAuthRejection(), renderers
       for sign-in / unavailable / shell / surface A, bootstrap(). */
  </script>
</body>
</html>
```

Suggested state shape (you may rename keys; the SHAPE is what
matters):

```javascript
const state = {
  cfg: null,                       // validated portal-config.json
  session: null,                   // { provider_id, provider_token } or null
  route: "machine",                // active surface id
  pool: { data: null, ts: 0, err: null, inflight: false },
  earn: { data: null, ts: 0, err: null, inflight: false },
  authFailBySurface: {},           // surface -> consecutive 401/403/404 count
  proxyMissing: false,
  sidebarOpen: false,              // mobile hamburger
  signinErr: null,
  signinMisconfigNotice: null,
};
```

`coordFetch(pathAndQuery, { auth, surface })`:
- Same-origin relative path only.
- On `fetch()` rejection: set `state.proxyMissing = true`, render,
  re-throw.
- On 401/403/404 with `auth === true` and `surface` set:
  increment `state.authFailBySurface[surface]`; otherwise on 2xx
  reset to 0.

`poolCheck()` — 30 s timer + manual refresh. Updates
`state.pool.{data, ts, err, inflight}`. NOT authenticated
(SPEC-002 §7.4 `/v1/pool/check` is public).

`earnFetch()` — 60 s timer + on-demand (Machine / Earn surface
mount). Skips if cache fresh (< 60 s). Authenticated (FR-P12
bearer + path subject). On 401/403/404 calls
`handleAuthRejection(status)`.

`handleAuthRejection(status)`:
- Save current `state.authFailBySurface[state.route]` BEFORE
  clearing session.
- Set `state.signinErr` to the 401-specific copy OR the 403/404-
  identical copy.
- If the prior fail count was ≥ 2 (i.e. this is the second-or-
  later consecutive failure), set
  `state.signinMisconfigNotice` to the §2.3 stale-config notice
  text.
- Clear `state.session`, stop pollers, render.

`bootstrap()`:
- `await loadConfig()`; on failure render unavailable-mode.
- Else `render()` (which renders the sign-in screen).

Render functions:
- `renderUnavailable_Config(reason)` — file-missing / unknown-key
  / non-200 / malformed-JSON page. Names the file path. Makes
  ZERO subsequent network calls (no pollers started, no surface
  reachable).
- `renderUnavailable_FlagFalse()` — `require_provider_tokens=false`
  page. Same zero-network rule.
- `renderSignIn()` — two-field form.
- `renderShell()` — sidebar + main; routes by `state.route`.
- `renderMachine()` — Surface A.
- `renderStub(phaseName)` — for Setup/Earn/Monitor/Identity in
  Phase 1A, renders `"Coming in <phaseName>"`.

DOM construction MUST avoid `innerHTML` for any user-controlled
data. A small `el(tag, attrs, ...kids)` helper that uses
`document.createElement` and `document.createTextNode` is the
expected pattern. The ONLY safe use of `innerHTML` is for fixed
SVG icons (and Phase 1A does not need any).

### C. `frontdoor/provider-portal/README.md` — extend

Replace the existing one-liner with a short README that:
- Names the spec link `[SPEC-014](../../specs/SPEC-014-provider-portal.md)`.
- Lists the files in the directory.
- Tells the operator to copy `portal-config.json.example` to
  `portal-config.json` and edit it before deploying.
- Notes the strict allowlist of top-level keys.
- Mentions that the bundle expects an operator-owned reverse
  proxy on the same origin forwarding `/v1/pool/check` and
  `/providers/{id}/earnings` to the coordinator (SPEC-014 §3 /
  Open Q9), and that the bundle fails LOUDLY if the proxy is
  missing.
- Notes that Phases 1B + 1C are not yet implemented and which
  surfaces are stubbed.

## Done criteria

You are done when:

- `git diff specs/ phase3-binary/ phase4-coordinator/
  phase5-gateway/ frontdoor/console/` is empty.
- Only these three files appear in `git status --porcelain`:
  `frontdoor/provider-portal/index.html`,
  `frontdoor/provider-portal/portal-config.json.example`,
  `frontdoor/provider-portal/README.md`.
- Opening `index.html` directly via `file://` shows a page that
  renders the unavailable-mode "portal-config.json missing" page
  (because file:// can't fetch /portal-config.json) and makes no
  other network calls. (You can sanity-check with `python3 -m
  http.server 8788 --directory frontdoor/provider-portal` and
  visiting `http://localhost:8788/` — without `portal-config.json`
  present, the unavailable page renders.)
- Drop a fixture `portal-config.json` (NOT committed) with
  `require_provider_tokens: true` and the page advances to the
  sign-in screen. Type fake credentials; the page issues
  `/v1/pool/check?provider_id=...` and `/providers/.../earnings`
  to the same origin; both fail (no proxy in dev) and the
  proxy-missing banner appears on Surface A. Confirm via browser
  DevTools that NO call is made when `require_provider_tokens:
  false` or when the file is absent.
- `grep -En 'localStorage|sessionStorage|document\.cookie|window\.indexedDB|indexedDB' frontdoor/provider-portal/index.html`
  returns ZERO matches.
- `grep -E '/poolz|/admin/blacklist|/admin/provisional|/admin/promote|/admin/reject|/admin/ledger|operator[_-]?key' frontdoor/provider-portal/index.html`
  returns ZERO matches.
- `grep -iE 'your fleet|your machines|across machines|all machines|N machines|N/M|x3|machine grid' frontdoor/provider-portal/index.html`
  returns ZERO matches.
- `grep -E 'innerHTML' frontdoor/provider-portal/index.html`
  returns at most one occurrence (and only for a trusted static
  SVG, if you used one).
- The page parses with no `console.error` on first paint in
  the unavailable, sign-in, and Surface A flows.

## Out of scope (do NOT do these in Phase 1A)

- Surface B (Requirements grid, sizing card, setup steps,
  GitHub Releases feed) — Phase 1B.
- Surface C (Earn credit totals + payout status) — Phase 1C.
- Surface D (Monitoring placeholder card) — Phase 1C.
- Surface E (Identity card) — Phase 1C.
- `frontdoor/provider-portal/check-bundle.sh` build-time grep
  guard — Phase 1C.
- Any localStorage / sessionStorage / cookie session persistence
  — explicitly forbidden by §7 in ALL phases.
- ANY operator-keyed endpoint reference — forbidden in ALL
  phases.
- Any UI implying fiat withdrawal — forbidden in ALL phases.

## Self-check before reporting done

Run this command and confirm all checks pass:

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat specs/ phase3-binary/ phase4-coordinator/ phase5-gateway/ frontdoor/console/ && \
  echo "----" && \
  git status --porcelain frontdoor/provider-portal/ && \
  echo "----" && \
  grep -En 'localStorage|sessionStorage|document\.cookie|window\.indexedDB|indexedDB' frontdoor/provider-portal/index.html || echo "OK: no browser-storage" && \
  echo "----" && \
  grep -E '/poolz|/admin/blacklist|/admin/provisional|/admin/promote|/admin/reject|/admin/ledger|operator[_-]?key' frontdoor/provider-portal/index.html || echo "OK: no operator routes" && \
  echo "----" && \
  grep -iE 'your fleet|your machines|across machines|all machines|N machines|N/M|x3|machine grid' frontdoor/provider-portal/index.html || echo "OK: single-machine hygiene"
```

Return:
- A brief diff summary (files touched, +/- lines).
- Confirmation each self-check command returned "OK" or zero.
- Any spec clause you were unable to satisfy exactly, with the
  binding clause number and your interpretation.

Do NOT commit. Do NOT push. The operator audits the working tree
via `omc ask codex` IMPL audit (separate prompt) before commit.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 75-120 min for Codex GPT-5 on a fresh
  context. Phase 1A is the foundation; Phases 1B and 1C are
  smaller appends that extend the same `index.html` file.
- After Phase 1A LOCKs (IMPL audit returns 0 CRITICAL / 0 HIGH /
  0 MEDIUM via `specs/AUDIT_SPEC_014_IMPL_PHASE_1A_PROMPT.md`),
  the operator proceeds to Phase 1B on the SAME branch
  (`feat/spec-014-provider-portal`). No PR is opened between
  phases. The single PR opens after Phase 1C LOCKs.
- Audit-loop discipline (memory: `feedback-build-audit-loop`)
  still binds: fix findings + re-audit until 0 CRITICAL/HIGH/
  MEDIUM BEFORE moving to the next phase. The discipline lives
  inside the branch as additional commits, not as additional
  PRs.
