# Implementation BUILD prompt — SPEC-014 Phase 1B (Setup & Updates + version feed)

Operator-paste prompt for Codex GPT-5 to land the **second** of three
implementation sub-phases of SPEC-014 v0.8. Phase 1B extends the
single-file bundle from Phase 1A with Surface B (Setup & Updates):
the static requirements grid, the RAM-to-model sizing card, the
numbered setup steps with copy-to-clipboard CTAs, and the GitHub
Releases-driven version feed with rate-limit + CORS handling.

**Prerequisite:** Phase 1A merged to `main`. Branch off `main` into
`feat/spec-014-portal-phase-1b`. The bundle at
`frontdoor/provider-portal/index.html` already contains the AUTH-3
loader, the sign-in screen, the AUTH-2 fetch layer, Surface A, and
stub renderers for B/C/D/E. Phase 1B replaces the B stub with the
real surface.

**Scope: SPEC-014 §11 Phase 1B only.** Concretely:
- §4.2 B.1 requirements grid (4 cards, FR-D1 verbatim).
- §4.2 B.1a RAM-to-model sizing card (FR-D2 + FR-D2.1).
- §4.2 B.2 numbered setup steps (3 steps; each a static
  copy-to-clipboard CTA; NO autotune banner per SPEC-013 NFR-4).
- §4.2 B.3 GitHub Releases-driven version feed with:
  - 5 min in-memory cache TTL (§5.4).
  - `X-RateLimit-Remaining: 0` fallback notice (loud, NOT silent
    retry).
  - `fetch()` rejection (CORS failure / network error) loud
    user-visible notice (NOT silently hidden).
  - NO read of `Access-Control-Allow-Origin` as application
    header (§4.2 B.3 + §5.1 table (a)).
- B.4 coordinator broadcasts panel — DEFERRED to v0.2; NOT
  rendered (§4.2 B.4 + §5 table (c)).

OUT OF SCOPE for Phase 1B: Surfaces C / D / E (still stubbed),
build-time grep guard `check-bundle.sh` (Phase 1C).

**One-line summary.** Replace the Phase 1A "Coming in Phase 1B" stub
for the Setup & Updates surface with the four B-cluster components
(B.1 grid + B.1a sizing + B.2 steps + B.3 release feed), wire a
GitHub Releases poller with strict rate-limit + CORS fail-loud
handling, and update §5 table (a) coverage for B.3.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-014 v0.8 (§4.2 Surface B, §5.1 table (a) B.3 rows, §5.2
  table (b) B.1/B.1a/B.2 rows, §5.4 thresholds, §7 non-goals,
  §8(a) Surface B ACs, §8(e) Q2 AC).
- SPEC-003 v0.9.2 (§5 FR-D1 requirements verbatim; §5 FR-D2 +
  FR-D2.1 sizing table; §4 FR-C2 install one-liner; §6.2 CLI
  subcommand table — `macprovider-cli status`, `macprovider-cli
  update`, `macprovider-cli autotune`).
- SPEC-013 v0.3 §6 / NFR-4 — autotune local-only egress contract
  binds B.2 step 3 (no autotune banner, only CTA).

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` after edits — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~60-90 min
(append ~200-300 lines to `index.html`).

Branch: `feat/spec-014-portal-phase-1b` (operator creates + checks
out before pasting). Codex MUST NOT create a new branch.

---

```
=== BEGIN PROMPT ===

You are implementing Phase 1B of SPEC-014 v0.8 in the single-file
web bundle at /Users/augstar/macprovider-poc/frontdoor/provider-portal/.
SPEC-014 v0.8 is LOCKED. Phase 1A is on `main` (read its commit to
understand the existing scaffolding before you start editing).

You will edit ONLY this file:

  frontdoor/provider-portal/index.html  (extend)

You will NOT create or edit any other file in this phase. Verify
with `git status --porcelain` — only `index.html` may show as
modified.

## Critical constraints

**1. Keep all Phase 1A guarantees intact.** Re-read the Phase 1A
constraints in `specs/BUILD_SPEC_014_IMPL_PHASE_1A_PROMPT.md`
("Critical constraints" section). Every one of them still binds:
single file, no CDN, no `localStorage`/`sessionStorage`/cookie,
no operator-keyed route, no remote command execution, no
multi-machine copy, AUTH-3 fail-CLOSED still works, AUTH-2
401/403/404 handling unchanged, same-origin proxy fail-loud
banner still triggers on Phase-1A surfaces.

**2. B.1 requirements grid (§4.2 B.1).** Render exactly 4 cards
in a responsive grid, each carrying the SPEC-003 §5 / FR-D1
README block VERBATIM:

  - Hardware: "Apple Silicon Mac (M1, M2, M3, M4)"
  - OS:       "macOS 14 (Sonoma) or later"
  - Disk:     "~4-8 GB free disk space"
  - Network:  "Internet connection"

The text MUST match these strings character-for-character (the
spec calls these "STATIC spec-backed"). Cite SPEC-003 §5 / FR-D1
in the section header — not FR-C2.

**3. B.1a RAM-to-model sizing card (§4.2 B.1a).** One visually
distinct card adjacent to B.1, with this 3-row table sourced from
SPEC-003 §5 / FR-D2 (+ FR-D2.1):

| RAM   | Recommended model              | Default       |
|-------|--------------------------------|---------------|
| 8 GB  | Llama 3.2 3B                   | Llama 3.2 3B  |
| 16 GB | Llama 3.2 3B / Qwen 2.5 7B     | Qwen 2.5 7B   |
| 24 GB+| + Qwen 2.5 14B                 | Qwen 2.5 14B  |

Include a one-line footer "FR-D2 is a recommendation, not a
hard requirement." (per §4.2 B.1a "the card MUST present it as
a hint").

**4. B.2 numbered setup steps (§4.2 B.2).** Three steps, each a
card with a title, a 1-2-line description, and a single
copy-to-clipboard snippet:

  Step 1 — "Install":
    Snippet: `curl -fsSL https://get.streamvc.live/install.sh | bash`
    Cite: SPEC-003 §4 / FR-C2.

  Step 2 — "Verify routable":
    Snippet: `macprovider-cli status`
    Cite: SPEC-003 §4 / FR-C4 (per SPEC-003 §6.2 — verify the
    verb exists in that table; do NOT invent `macprovider-cli
    install`, which is NOT in §6.2).

  Step 3 — "(Optional) Autotune":
    Snippet: `macprovider-cli autotune`
    Body: "Run before serving to pick conservative kv-bits /
    context / batch values. The portal cannot render autotune
    results — SPEC-013 §6 / NFR-4 forbids non-HF egress during
    autotune."
    AUTOTUNE BANNER PROHIBITED. The bundle MUST NOT contain ANY
    string like "your latest autotune recommended", "autotune
    result", "tuning complete", etc. Only the CTA.

**5. B.3 GitHub Releases feed (§4.2 B.3 + §5.1 table (a) +
§5.4 thresholds).**

  - Endpoint:
    `GET https://api.github.com/repos/${cfg.releases_repo_owner_name}/releases`
    (the cfg field was validated in Phase 1A's AUTH-3 loader to
    match `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`).
  - Trigger: fetch on first mount of Surface B AND on a 5 min
    in-memory TTL refresh. Do NOT poll on a wall-clock interval;
    only on mount + manual revisit after TTL expiry.
  - Cache: in-memory only (NOT `localStorage`).
  - **`X-RateLimit-Remaining: 0` handling:** read the response
    header (GitHub exposes rate-limit headers to browser code
    via Access-Control-Expose-Headers). When it reads `"0"`,
    set a `state.releases.rateLimited = true` flag and render a
    fallback notice:
    `"GitHub API rate limit reached — release feed paused;
     refresh later."`
    Do NOT silently retry. Do NOT blank out any previously-cached
    list (continue showing what you had).
  - **CORS / `fetch()` rejection handling:** if the `fetch()`
    promise REJECTS (TypeError "Failed to fetch", opaque
    response, network error), set a loud user-visible notice:
    `"GitHub Releases unavailable — release feed disabled; see
     SPEC-014 Open Q2."`
    DO NOT silently hide. DO NOT attempt to read
    `Access-Control-Allow-Origin` as an application header (the
    spec is explicit: a successful, readable fetch IS the CORS
    confirmation; reading ACAO is forbidden because browsers
    don't expose it unless listed in Access-Control-Expose-
    Headers, which GitHub does not list).
  - **Non-2xx non-0-remaining responses:** show an error notice
    `"HTTP <N> from GitHub Releases."`.
  - **Response shape:** array root; iterate up to first 12
    entries. Per entry render:
    - `tag_name` (or fallback `name`) in monospace.
    - `published_at` ISO date sliced to YYYY-MM-DD.
    - An expandable release-notes panel rendered from the
      raw `body` text. RENDER AS PLAIN TEXT (no markdown
      parser, no `innerHTML` of remote content). A simple
      `<pre>`-style block in `white-space: pre-wrap; word-break:
      break-word; max-height: 200px; overflow: auto;` is fine.
    - A copy-to-clipboard CTA for `macprovider-cli update`
      (per SPEC-003 §4 / FR-C3, per §6.2).
  - **No "currently installed" badge** — DEFERRED to v0.2; the
    installed `binary_version` is WS-only (§5 table (c) Open Q5).
  - **Section header** cites the resolved owner/name string from
    `state.cfg.releases_repo_owner_name`.

**6. B.4 coordinator broadcasts panel — NOT RENDERED (§4.2 B.4).**
Do not add this section at all. It is entirely deferred behind
Open Q5; the §5 table (c) row owns it.

**7. No new dependencies, no new event listeners outside the
existing render flow.** Phase 1B is purely additive UI + one
new fetch helper. Do NOT add a service worker. Do NOT preload
any cross-origin asset. Do NOT introduce `<link rel="preconnect">`
to GitHub (preconnect would trigger an unnecessary cross-origin
handshake even when the user never visits Surface B).

**8. Re-confirm grep cleanliness.** After your edit:
  - `grep -En 'localStorage|sessionStorage|document\.cookie|window\.indexedDB|indexedDB' frontdoor/provider-portal/index.html`
    → ZERO matches.
  - `grep -E '/poolz|/admin/blacklist|/admin/provisional|/admin/promote|/admin/reject|/admin/ledger|operator[_-]?key' frontdoor/provider-portal/index.html`
    → ZERO matches.
  - `grep -iE 'your fleet|your machines|across machines|all machines|N machines|N/M|x3|machine grid' frontdoor/provider-portal/index.html`
    → ZERO matches.
  - `grep -iE 'your latest autotune|autotune result|tuning complete|withdrawable|withdraw now|link bank|stripe' frontdoor/provider-portal/index.html`
    → ZERO matches.
  - `grep -E 'Access-Control-Allow-Origin' frontdoor/provider-portal/index.html`
    → ZERO matches (we never read it as application data).
  - `grep -E 'innerHTML' frontdoor/provider-portal/index.html`
    → at most the same count as Phase 1A.

**9. Same-origin invariant for coordinator routes (§3).** B.3
calls `api.github.com` (cross-origin, public CORS) but Surface
A / E continue to call `/v1/pool/check` and `/providers/{id}/
earnings` SAME-ORIGIN. Do NOT introduce any code path that
calls `state.cfg.coordinator_base_url` as a fetch base for those
routes.

## Required reading (in this order — read fully before writing)

1. The current `/Users/augstar/macprovider-poc/frontdoor/provider-portal/index.html`
   end-to-end. Understand the existing `state` shape, the
   `el(...)` DOM helper, the `coordFetch()` / pool / earn
   pollers, the surface-routing switch.

2. `/Users/augstar/macprovider-poc/specs/SPEC-014-provider-portal.md`
   §4.2 (Surface B), §5.1 table (a) B.3 rows, §5.2 table (b)
   B.1/B.1a/B.2 rows, §5.4 thresholds rows for "Releases-feed
   GitHub API cache TTL" + "Releases-feed unauthenticated rate-
   limit", §8(a) Surface B ACs.

3. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   §5 FR-D1 (requirements list — copy verbatim) and §5 FR-D2 +
   FR-D2.1 (sizing table). §6.2 CLI subcommand table (verify
   `status`, `update`, `autotune` exist; do NOT cite `install`).

4. `/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md`
   §6 / NFR-4 — the autotune local-only egress contract. Phase 1B
   MUST NOT render any autotune-result banner.

5. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions.

## Required edits — exact shape

### A. Extend `state` shape

Add this top-level field (mirror existing pattern):

```javascript
releases: {
  list: null,        // array of release objects, last fetched
  ts: 0,             // ms epoch of last successful fetch
  err: null,         // string error notice, if any
  inflight: false,
  rateLimited: false // true when last fetch saw X-RateLimit-Remaining: 0
},
```

### B. Add `releasesFetch()` helper

```javascript
async function releasesFetch(){
  if (state.releases.inflight) return;
  if (state.releases.list && Date.now() - state.releases.ts < RELEASES_TTL_MS) return;
  state.releases.inflight = true;
  try {
    const u = `${RELEASES_HOST}/repos/${state.cfg.releases_repo_owner_name}/releases`;
    let resp;
    try {
      resp = await fetch(u, { cache: "no-store" });
    } catch (e) {
      state.releases.err = "GitHub Releases unavailable — release feed disabled; see SPEC-014 Open Q2.";
      return;
    }
    const remaining = resp.headers.get("X-RateLimit-Remaining");
    if (remaining === "0") {
      state.releases.rateLimited = true;
      state.releases.err = "GitHub API rate limit reached — release feed paused; refresh later.";
      return;
    }
    state.releases.rateLimited = false;
    if (!resp.ok) {
      state.releases.err = "HTTP " + resp.status + " from GitHub Releases.";
      return;
    }
    const arr = await resp.json();
    if (!Array.isArray(arr)) {
      state.releases.err = "Unexpected GitHub Releases response shape.";
      return;
    }
    state.releases.list = arr;
    state.releases.ts = Date.now();
    state.releases.err = null;
  } finally {
    state.releases.inflight = false;
    render();
  }
}
```

with module-scope constants:

```javascript
const RELEASES_TTL_MS = 5 * 60_000;
const RELEASES_HOST = "https://api.github.com";
```

### C. Replace the Phase 1A "Setup & Updates" stub

Replace the `renderStub("Phase 1B")` (or whatever Phase 1A used)
for the `setup` route with a real `renderSetup()` function that
returns a fragment composed of:
- A surface title + sub.
- Requirements section (B.1) — 4 cards using `<div class="row row-4">`.
- Sizing section (B.1a) — single card with the 3-row table.
- Setup steps section (B.2) — 3 step cards each with a
  copy-to-clipboard snippet.
- Releases section (B.3) — section header citing
  `state.cfg.releases_repo_owner_name`, followed by:
  - An error notice block when `state.releases.err`.
  - A "Loading releases…" line when first fetch is in flight and
    no cached list exists.
  - The list (up to first 12 entries), each rendered per
    constraint 5.
- On mount, if `!state.releases.list && !state.releases.inflight
  && !state.releases.err`, call `releasesFetch()`.

### D. Copy-to-clipboard helper

If Phase 1A already defines a `snippet(text)` helper, reuse it.
Otherwise add one:

```javascript
function snippet(text){
  const codeEl = el("code", null, text);
  const btn = el("button", { class:"copy-btn", onclick: async () => {
    try {
      await navigator.clipboard.writeText(text);
      btn.textContent = "Copied";
      btn.classList.add("copied");
      setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1200);
    } catch (e) {
      // Fallback selection-based copy
      const r = document.createRange();
      r.selectNode(codeEl);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
      btn.textContent = "Press ⌘C";
    }
  }}, "Copy");
  return el("div", { class:"snippet" }, codeEl, btn);
}
```

### E. README touch (optional but recommended)

Update `frontdoor/provider-portal/README.md` ONLY if Phase 1A's
"Phases 1B + 1C are not yet implemented" line needs to be moved
to "Phase 1C is not yet implemented." Single-line edit; do not
expand the README.

## Done criteria

You are done when:

- `git status --porcelain frontdoor/provider-portal/` lists at
  most `index.html` (and optionally `README.md` for the
  one-liner) as modified; nothing else.
- `git diff specs/ phase3-binary/ phase4-coordinator/
  phase5-gateway/ frontdoor/console/` is empty.
- Manual smoke (with `python3 -m http.server 8788 --directory
  frontdoor/provider-portal` and a dev fixture `portal-config.json`
  with `require_provider_tokens: true`):
  - Sign in with arbitrary credentials → navigate to "Setup &
    Updates" via the sidebar.
  - The requirements grid renders 4 cards with FR-D1 strings
    verbatim.
  - The sizing card renders the 3-row table with FR-D2 values.
  - The setup steps render 3 cards with copy-to-clipboard
    snippets that actually copy when clicked.
  - The release feed makes ONE fetch to
    `https://api.github.com/repos/<owner>/<name>/releases`.
    DevTools Network panel confirms the URL and no other GitHub
    hosts.
  - With network DevTools-throttled "Offline": revisiting Setup
    triggers the `fetch()`-rejection notice ("GitHub Releases
    unavailable …").
  - With a mock that returns `X-RateLimit-Remaining: 0`: revisiting
    Setup shows the rate-limit notice.
- Re-confirm grep checks (constraint 8) all return ZERO matches.
- The page parses with no `console.error` on first paint in
  the Setup surface flow.

## Out of scope (do NOT do these in Phase 1B)

- Surface C (Earn) — Phase 1C.
- Surface D (Monitoring placeholder) — Phase 1C.
- Surface E (Identity) — Phase 1C.
- Build-time grep guard `check-bundle.sh` — Phase 1C.
- "Currently installed" badge per release entry — DEFERRED to
  v0.2 (Open Q5).
- B.4 coordinator broadcasts panel — DEFERRED to v0.2 (Open Q5).
- Any markdown renderer for the release `body` — explicitly out
  of scope; plain `<pre>` only to avoid HTML injection from
  remote content.
- Any change to the AUTH-3 loader, AUTH-2 handler, polling
  cadence, or Surface A code — those are Phase 1A's surface.

## Self-check before reporting done

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
  grep -iE 'your fleet|your machines|across machines|all machines|N machines|N/M|x3|machine grid' frontdoor/provider-portal/index.html || echo "OK: single-machine hygiene" && \
  echo "----" && \
  grep -iE 'your latest autotune|autotune result|tuning complete|withdrawable|withdraw now|link bank|stripe' frontdoor/provider-portal/index.html || echo "OK: no autotune banner / no fiat UX" && \
  echo "----" && \
  grep -E 'Access-Control-Allow-Origin' frontdoor/provider-portal/index.html || echo "OK: ACAO never read"
```

Return:
- A brief diff summary (lines added/removed in `index.html`).
- Confirmation each self-check returned "OK" or zero.
- Any spec clause you were unable to satisfy exactly, with the
  binding clause number and your interpretation.

Do NOT commit. Do NOT push. The operator audits the working tree
via `omc ask codex` IMPL audit (separate prompt) before commit.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 60-90 min for Codex GPT-5 on a fresh
  context. Phase 1B is a smaller append than Phase 1A.
- After Phase 1B LOCKs (IMPL audit returns 0 CRITICAL / 0 HIGH /
  0 MEDIUM), commit on the feature branch and open the PR. Do
  NOT cascade to Phase 1C in the same PR.
- Phase 1C prompt drafts only after Phase 1B LOCKs and merges.
