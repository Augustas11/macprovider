# SPEC-014 — Provider Portal (seller-facing web surface)

**Version:** 0.9
**Status:** Draft (v0.9 GitHub-OAuth drift reconciliation — reconciled to shipped
config-gated dual-mode auth; pending codex 3-lane audit)
**Date drafted:** 2026-06-21 (v0.9 reconciliation 2026-07-13)
**Change log v0.9 (2026-07-13, GitHub-OAuth dual-mode drift reconciliation — spec matched to shipped code; code is source of truth):**
  The portal + coordinator shipped a full **config-gated GitHub-OAuth
  cookie-session** provider-binding flow in commit `0935d1e` (2026-06-22, one day
  after v0.8 froze the token-paste-only design). SPEC-014 was never reconciled, so
  v0.8 still *forbids* GitHub OAuth while the code ships it (gated OFF in current
  prod: `portal-config.json:github_oauth_enabled=false`, coordinator
  `GITHUB_OAUTH_ENABLED=false`). v0.9 documents the shipped **dual-mode** contract
  honestly: token-paste bearer (default, prod-active) **and** the opt-in
  GitHub-OAuth cookie-session mode. It specifies the previously-unowned OAuth
  **transport** (`/v1/auth/github/*`, `/v1/auth/me/*`, the `mp_session` cookie,
  CSRF origin-binding, `return_to` guard, `/claim` + `pair_ot`) as owner of last
  resort, cross-referencing **SPEC-003 FR-C10** for the coordinator mint/ownership
  *policy* and **SPEC-001 v1.5** for frame shapes rather than re-specifying them.
  No code change.
**Audit history:**
  - v0.1 → codex round 1 → 0 CRITICAL / 3 HIGH / 2 MEDIUM / 2 MINOR /
    0 QUESTION → all HIGH + MEDIUM addressed in v0.2.
  - v0.2 → codex round 2 → 0 CRITICAL / 2 HIGH / 1 MEDIUM / 2 MINOR /
    1 QUESTION → all HIGH + MEDIUM addressed in v0.3.
  - v0.3 → codex round 3 → 0 CRITICAL / 2 HIGH / 2 MEDIUM / 1 MINOR /
    0 QUESTION → all HIGH + MEDIUM addressed in v0.4.
  - v0.4 → codex round 4 → 0 CRITICAL / 2 HIGH / 3 MEDIUM / 1 MINOR /
    0 QUESTION → all HIGH + MEDIUM addressed in v0.5.
  - v0.5 → codex round 5 → 0 CRITICAL / 3 HIGH / 2 MEDIUM / 1 MINOR /
    0 QUESTION → all HIGH + MEDIUM addressed in v0.6.
  - v0.6 → codex round 6 → 0 CRITICAL / 2 HIGH / 0 MEDIUM / 1 MINOR /
    0 QUESTION → both HIGH addressed in v0.7.
  - v0.7 → codex round 7 → 0 CRITICAL / 2 HIGH / 1 MEDIUM / 2 MINOR /
    0 QUESTION → both HIGH addressed in v0.8 (audit loop paused per
    operator instruction; remaining MEDIUM/MINORs accepted as
    backlog for next audit cycle).
  - v0.9 → GitHub-OAuth dual-mode drift reconciliation (see change log
    above) → pending codex 3-lane audit.
**Depends on:**
  - SPEC-001 v1.5 (`hello` / `hello_ack` fields; local `/v1/health`;
    ownership frame shapes — `ownership_event` / `needs_claim` — consumed by
    the GitHub-OAuth bind flow)
  - SPEC-002 v1.3.5 (FR-P12 provider tokens; §7.3 token store; §7.4
    operator endpoints + `/v1/pool/check`; §7.5 provisional admission)
  - SPEC-003 v0.10 (FR-C2 install; §5 / FR-D1 + FR-D2 requirements
    + RAM sizing; FR-C7 advisory version nudge; FR-C9 provisional
    self-mint token path; **FR-C10 GitHub-OAuth coordinator mint/ownership
    policy** — pair_ot mint, `provider_ownership` anti-check, `ownership_event`
    on bind, `claim_url` shape — which the portal's GitHub-OAuth mode consumes)
  - SPEC-005 v0.3 (§1.3 out-of-scope; §2.1 D1 donation-only; §2.11
    D11 no-new-delivery-infra; §11.4
    `GET /providers/{id}/earnings`; §11.5 route-disabled mode)
  - SPEC-009 v0.1 (visual tokens, sidebar geometry, ASCII layout
    style)
  - SPEC-013 v0.3 (§6 / NFR-4 telemetry / privacy egress contract)

---

## 1. Goals, non-goals, scope cuts

### 1.1 Goals

`console.streamvc.live` (frontdoor/console, SPEC-009 v0.1) is the
buyer-facing surface. The seller side has no web surface today: a
provider runs `macprovider-cli serve` in a terminal, watches log
lines, and may hit `GET /v1/health` for a number. SPEC-014 introduces
**Provider Portal**, a single-pane read-only web surface that lets a
provider sign in and see THIS machine's coordinator-side status (`provider_id`,
`tier`, `state`) plus its aggregate earnings. **Sign-in is config-gated
dual-mode (reconciled v0.9):** the default and current-prod path is a per-Mac
`provider_id` + `provider_token` **paste-bearer** sign-in (§2.1); an opt-in
**GitHub-OAuth cookie-session** mode (§2.5), gated by
`portal-config.json:github_oauth_enabled` + coordinator `GITHUB_OAUTH_ENABLED`,
lets a provider sign in with GitHub and manage the Mac(s) bound to their GitHub
identity. Both are shipped; GitHub-OAuth is disabled in current prod.

Five surfaces ship in v0.1: **A Machine** (default), **B Setup &
Updates**, **C Earn**, **D Monitoring** (placeholder card, zero API
calls), and **E Identity** (read-only). The portal inherits SPEC-009
§6 visual tokens verbatim so a provider who also tries the buyer
console recognises the family.

The portal is **available ONLY when the coordinator runs with
`auth.require_provider_tokens = true`**. In any other deployment
mode the portal renders a single-page unavailable notice (§2,
AUTH-3). All-on or all-off; no per-surface conditional degradation.

### 1.2 Non-goals (v0.1) and scope cuts from the originating prompt

The following patterns from competitor reference screenshots and
prior portal sketches MUST NOT appear in v0.1. Each cut has an
explicit reason rooted in upstream specs:

- **Multi-Mac aggregation.** No `provider_id` is multi-Mac — each
  Mac mints its own at install (SPEC-003 §4 / FR-C2 step 10) and
  SPEC-005 §11.4 binds earnings on a single `provider_id`. No
  multi-Mac owner identity exists upstream. Cut: any "N/M machines
  online" header, "x3 machines" attention chip, or machine grid.
  See Open Q1.
- **Stripe / fiat / checkout / withdraw / card-link UX.**
  SPEC-005 §1.3 lists Stripe, checkout, and fiat invoices as
  out-of-scope; §2.1 D1 reiterates "no Stripe, no checkout, no
  credit card collection". Cut: country selector, "Link bank via
  Stripe" button, account-type picker, payout-now CTA. See
  Open Q3.
- **Autotune results banner.** SPEC-013 §6 / NFR-4 forbids non-HF
  egress during autotune; there is no data path from autotune to
  the portal. Cut: any "your latest autotune recommended X"
  card. Portal exposes the copy-to-clipboard CTA only (B.2).
- **Live request stream.** No browser-callable per-provider
  request-tail endpoint exists, and the privacy-redaction policy
  for buyer prompts has never been written. Cut: D.3 deferred
  unconditionally. See Open Q5.
- **Per-job activity feed.** SPEC-005 §11.4 returns aggregate
  credits + ancillary provider metadata (`provider_id`,
  `provider_share_bps`, `models_served`, `rate_card_excerpt`,
  `fault_count`); no per-row `ledger_request_credits` data is
  exposed on a provider-scoped browser-callable endpoint.
  Cut. See Open Q4.
- **Earnings breakdown.** Time bucketing (day/week/month),
  per-model credit breakdown, and per-day bar chart all need
  fields SPEC-005 §11.4 does not return — the response is
  aggregate-plus-ancillary, with no per-bucket or per-model
  credit decomposition. Cut. See Open Q4.
- **Provider token rotation.** SPEC-002 §7.3 issues tokens via
  `coordinator-cli issue-token`; there is no provider self-service
  rotation endpoint. Cut. See Open Q6.
- **"Remove this machine" UX.** Machine removal today is operator-
  only via `POST /admin/blacklist` (SPEC-002 §7.4, operator-keyed).
  Cut. See Open Q6.
- **Notifications (email / Slack / push / SMS).** SPEC-005 §2.11
  D11 forbids new delivery infrastructure. Cut. See Open Q11.
- **Multi-machine version-state UI.** Update pill, "you are N
  versions behind" badge, coordinator-broadcast panel. All require
  the installed `binary_version` and the coordinator's
  advertised `recommended_binary_version` — both flow only on the
  WS handshake (SPEC-001 §6.5; FR-C7 nudge is advisory only,
  never a hard floor). Deferred to v0.2 behind Open Q5.

### 1.3 What v0.1 ships (positive frame)

- Surface A header strip (provider_id + tier + state from
  `/v1/pool/check`), counters row (lifetime + window + last-payout
  credits from `/providers/{id}/earnings`), needs-attention panel
  driven by the `state` enum alone, manual refresh button.
- Surface B static requirements grid + sizing card + setup steps +
  GitHub Releases-driven version feed (no installed-version
  overlay).
- Surface C three aggregate credit cards + payout-rail-deferred
  status card (no withdrawal UX).
- Surface D single placeholder card naming the deferred sub-cards
  and the Open Q each lives behind. Zero API calls.
- Surface E identity card: pasted-`provider_id`, tier badge, state,
  coordinator base URL from operator config. No rotation, no
  removal, no hardware/runtime fields.

---

## 2. Auth & session model

### 2.1 AUTH-1 — How the provider signs in (paste-bearer mode; default)

**Mode selection (reconciled v0.9).** The portal has two shipped sign-in modes,
selected at load time by `portal-config.json:github_oauth_enabled`:

- `github_oauth_enabled` absent / `false` → **paste-bearer mode** (this section,
  AUTH-1/AUTH-2). This is the default and the mode running in current prod.
- `github_oauth_enabled: true` → **GitHub-OAuth cookie-session mode** (§2.5),
  which requires the coordinator to also run with `GITHUB_OAUTH_ENABLED=true`.

In **paste-bearer mode** the portal asks the provider to paste BOTH `provider_id`
AND `provider_token` at the sign-in screen. Both are required.

Rationale (paste-bearer mode is token-based, not token-only-derivable):

- SPEC-002 §7.3 token storage is `(token_hash, token_prefix,
  provider_id, ...)` with SHA-256 hashed storage; tokens are
  opaque 32-byte random and carry zero introspectable identity.
  Server-side, `/providers/{id}/earnings` resolves the subject by
  matching the bearer-token's stored `provider_id` to the path
  segment. The browser cannot derive `provider_id` from the bearer
  alone.
- SPEC-005 §11.4 / §11.5 explicitly bind FR-P12 subject equality:
  bearer + path component MUST both be in hand.
- Token provenance is two-path:
  - **Pinned** providers: operator-issued via `coordinator-cli
    issue-token --provider-id <id> --provider-name <name>` (SPEC-002
    §7.3 / FR-P12). The cleartext token is printed once and
    delivered out-of-band.
  - **Provisional** providers: self-minted by the coordinator on
    first admission per SPEC-003 FR-C9.1 / FR-C9.4 and persisted
    by the binary into the local config per FR-C9.3.
- Where the provider finds the values on disk:
  - `provider_id` is the contents of
    `~/.config/macprovider/provider_id` (SPEC-003 §4 / FR-C2
    step 10).
  - `provider_token` is the top-level `provider_token:` YAML key
    inside `~/.config/macprovider/config.yaml` (SPEC-003 FR-C9.3 —
    a single flat top-level key; nested `provider_token:` lines
    under other blocks are preserved verbatim by the persist
    routine).

Storage in the browser (paste-bearer mode): **in-memory only**. No
`localStorage`, no `sessionStorage`, no cookie. A page reload
returns the provider to the sign-in screen. (The GitHub-OAuth mode in §2.5 does
use an `HttpOnly` `mp_session` cookie — that is the mode's deliberate design, not
a violation of this paste-mode rule.)

**Reconciled v0.9 — GitHub OAuth is no longer forbidden; it shipped.** The v0.8
text declared GitHub OAuth (and Sign-in-with-Apple / email magic link) out of
scope as a v0.1 cut, citing SPEC-005 §2.11 D11 ("no new auth surface required").
That was accurate for the v0.1 paste-only portal — but a GitHub-OAuth
provider-binding surface was subsequently **built and shipped** (commit
`0935d1e`, 2026-06-22): the coordinator half is owned by **SPEC-003 FR-C10**
(pair_ot mint + `provider_ownership` binding + `ownership_event`), and the portal
+ OAuth transport half is documented here in §2.5. It ships **gated off by
default** (two independent flags, §2.3) and is off in current prod, so it adds no
new *always-on* auth surface; when an operator opts in, it is a real,
intentional second auth path. The alternatives not built remain out of scope:

- **Sign-in-with-Apple** — not shipped; an Apple-developer-account dependency
  unrelated to the portal's value.
- **Email magic link** — not shipped; would require email delivery infrastructure
  that SPEC-005 §2.11 D11 forbids and that no coordinator service speaks.

### 2.2 AUTH-2 — Trust boundary against impersonation (paste-bearer mode)

- In paste-bearer mode the browser sends `Authorization: Bearer <provider_token>`
  on every authenticated call and embeds the pasted `provider_id` in
  the request path (`/providers/{provider_id}/earnings`).
- In paste-bearer mode the coordinator's existing FR-P12 bearer middleware is the
  SOLE authority. **Reconciled v0.9:** the earlier absolute "SPEC-014 introduces
  no new server-side auth path" holds **only for paste-bearer mode**. The
  GitHub-OAuth mode (§2.5) *does* add a new server-side auth path — an OAuth
  cookie-session authenticated by the `mp_session` cookie rather than the FR-P12
  bearer — which is off by default and off in current prod; see §2.5 for its
  trust boundary.
- In **either** mode the portal MUST NOT possess, request, prompt for, or transmit
  the operator key, and MUST NEVER call `/poolz`,
  `/admin/blacklist`, `/admin/provisional`, `/admin/promote/*`,
  `/admin/reject/*`, `/admin/ledger/*`, or any other operator-keyed
  route. AC group (b) enforces this via a build-time grep. The GitHub-OAuth
  endpoints the portal *may* call are the closed allowlist in §2.5 (the
  `/v1/auth/*` set), and no others.
- HTTP status handling (per SPEC-005 §11.5):
  - **401** (missing or malformed token) → sign-in prompt; do not
    leak that the token was malformed vs absent.
  - **403** (subject != path or token revoked) → "sign-in
    rejected" message; do not reveal which mismatch.
  - **404** (unknown `provider_id`) → identical "sign-in rejected"
    message to 403; SPEC-005 §11.5 explicitly does not enumerate
    valid providers and the portal MUST preserve that property.

### 2.3 AUTH-3 — Operator-declared deployment mode

SPEC-005 §11.5 does not expose a browser-readable "current mode"
endpoint. Deployment mode in v0.1 is therefore **operator-
declared** (not "detected" — that word would imply a runtime API
discovery the upstream specs do not support).

Mechanism:

- The operator deploys `/portal-config.json` at the portal host
  root. Shape (reconciled v0.9 — adds `github_oauth_enabled`):
  ```json
  {
    "coordinator_base_url": "https://coordinator.streamvc.live",
    "releases_repo_owner_name": "Augustas11/macprovider",
    "require_provider_tokens": true,
    "github_oauth_enabled": false
  }
  ```
  The loader accepts exactly these four keys and rejects any unknown top-level key
  (`unknown-key:<k>`). `require_provider_tokens` MUST be `true` or the portal
  hard-fails to the unavailable page (fail-closed). `github_oauth_enabled` is
  **optional**, defaults to `false`, and MUST be boolean when present
  (`invalid-github_oauth_enabled` otherwise); it selects paste-bearer (false) vs
  GitHub-OAuth (true) mode per §2.1 / §2.5.

- **Two-flag consistency (reconciled v0.9).** GitHub-OAuth mode is gated by **two
  independent flags** that the operator MUST set together: the portal's
  `portal-config.json:github_oauth_enabled` and the coordinator's own
  `auth.github_oauth.enabled` (env `GITHUB_OAUTH_ENABLED`). The coordinator mounts
  the `/v1/auth/*` routes **only** when its flag is on (otherwise they 404). If
  the portal flag is `true` but the coordinator flag is off, the `/v1/auth/*`
  calls 404 and the portal surfaces a misconfiguration banner directing the
  operator to deploy the OAuth-enabled coordinator. The portal MUST NOT fall back
  to paste-bearer mode when its flag is `true`.
- The portal fetches `/portal-config.json` on load BEFORE any
  authenticated call.
- **Missing file OR HTTP non-200 → fail-CLOSED.** Render the
  unavailable-mode page naming the missing file path. Never fall
  through to a permissive default. Never silently retry against a
  hard-coded URL.
- **`require_provider_tokens: false` → unavailable-mode page.**
  Render the explanation: "The portal needs the coordinator to run
  with `auth.require_provider_tokens=true` (SPEC-002 FR-P12 defines
  the flag and its enforcement semantics; SPEC-005 §11.5 is the
  binding route-disablement clause that makes the portal's earnings
  call unavailable in `false` mode). The current deployment runs
  with this flag set to false, which disables `GET /providers/
  {id}/earnings` at the route layer." Make ZERO API calls.
- The portal MUST never read or display the operator key, even if
  one were accidentally placed in `portal-config.json`. The
  loader rejects unknown top-level keys.

Stale-config guard:

- The operator runbook (§10 dependencies) names
  `portal-config.json`, names the coordinator config key
  (`auth.require_provider_tokens`), and prescribes a verification
  step before flipping either: "compare
  `portal-config.json.require_provider_tokens` to the coordinator's
  deploy config; both MUST match before flipping."
- AC group (b) requires: when an authenticated API call returns
  401, 403, or 404 in `require_provider_tokens: true` mode, the
  portal MUST NOT silently fall back to the unavailable-mode page.
  Persistence threshold (binding for v0.1): **after two
  consecutive authenticated provider-endpoint failures on the
  same surface within the same signed-in session**, the portal
  surfaces an explicit "your deployment may be misconfigured —
  ask your operator to verify `portal-config.json`" notice. The
  first failure routes through AUTH-2 (401 → sign-in prompt;
  403 / 404 → the 403/404-identical "sign-in rejected" copy).
  The second consecutive failure adds the misconfiguration notice
  without changing the 403/404-identical user-visible copy.

Future runtime discovery (probe-based; new SPEC-002 / SPEC-005
amendment exposing mode) is deferred behind **Open Q8** —
recommended action: file in SPEC-002 v-next.

### 2.4 Deployment-mode gating restated (binding)

`auth.require_provider_tokens = true` is the ONLY supported mode.
Rationale: SPEC-005 §11.5 disables `GET /providers/{id}/earnings`
at the route layer when the flag is false. The only remaining
economics surface is the operator-keyed `/admin/ledger/providers`,
which the portal MUST NEVER expose to a browser. Therefore the
portal has no callable data path in `false` mode and renders the
unavailable-mode page.

Note: FR-C9.5 says **tokenless admission is allowed and tokens get
minted** under `false`; under `true` tokenless admission is
rejected pre-admission. The portal unavailability rationale is the
ROUTE disablement (§11.5), not "no token exists."

### 2.5 AUTH-4 — GitHub-OAuth cookie-session mode (config-gated, shipped; reconciled v0.9)

When `github_oauth_enabled: true` (portal) **and** `GITHUB_OAUTH_ENABLED=true`
(coordinator), the portal runs a GitHub-OAuth cookie-session sign-in instead of
paste-bearer. This mode is **shipped** (commit `0935d1e`) and **off in current
prod**. SPEC-014 owns the **OAuth transport** documented here; the coordinator
**mint/ownership policy** (pair_ot mint, `provider_ownership` binding,
`ownership_event`, `claim_url` shape) is owned by **SPEC-003 FR-C10** and the
ownership frame shapes by **SPEC-001 v1.5** — this section cross-references those
and does not re-specify them. On any conflict, the owner spec governs.

#### 2.5.1 Purpose and identity model

GitHub-OAuth mode authenticates the *person* (their GitHub identity) and lists
the provider Mac(s) **bound** to that identity, rather than authenticating a
single Mac by its pasted token. A GitHub user is linked to `provider_id`(s)
through the coordinator's `provider_ownership` table (SPEC-003 FR-C10); a Mac is
bound by claiming a one-time `pair_ot` minted at install/admission.

#### 2.5.2 Transport endpoints (portal → coordinator)

Mounted by the coordinator **only** when its flag is on (else 404). The portal
calls exactly this closed set and no others (AUTH-2 allowlist):

| Method + path | Purpose | Auth |
|---|---|---|
| `GET /v1/auth/github/start?return_to=<path>[&pair_ot=<ot>]` | Begin OAuth; 302 to GitHub | none (mints CSRF state) |
| `GET /v1/auth/github/callback?state=&code=` | OAuth callback; sets session cookie; 302 to `return_to` | validated `state` |
| `GET /v1/auth/me/providers` | List providers owned by the session's GitHub identity | `mp_session` cookie |
| `POST /v1/auth/me/providers/bind` | Bind a `pair_ot` to the session identity | `mp_session` cookie |
| `POST /v1/auth/logout` | Delete session, clear cookie (204) | `mp_session` cookie |

(The coordinator additionally exposes a bearer-authed
`POST /v1/install/pair/refresh` to mint a fresh `pair_ot` + `claim_url`; that is a
provider-CLI/install surface, not called by the portal.) The `callback` is
reached by the browser via GitHub's 302 redirect, not by a portal `fetch`.

#### 2.5.3 Session cookie (`mp_session`)

- Name `mp_session`; value is an **opaque server-side session id** (not a
  signed/JWT payload) — the session row lives in the coordinator DB.
- Flags: `HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=2592000` (30 days),
  optional `Domain=<MP_SESSION_COOKIE_DOMAIN>` scoped to the portal host.
- Sliding re-issue ~every 24h; `POST /v1/auth/logout` deletes the session row and
  clears the cookie.
- The portal's cookie-mode fetch uses `credentials: "include"`, `cache:
  "no-store"`, and **strips any `Authorization` header** — cookie mode never
  sends a bearer token. Same-origin path-only requests rely on the operator
  reverse-proxying the coordinator under the portal origin.

#### 2.5.4 CSRF / open-redirect protections (transport-owned here)

- **OAuth `state`** is a 32-byte random single-use token, TTL-bounded and
  rate-limited, bound to an **origin hash** = HMAC-SHA256 over
  `sha256(peer-IP) || sha256(User-Agent)` keyed by the operator key (fallback
  OAuth client secret). The callback consumes it single-use and rejects a
  mismatch. `Referrer-Policy: no-referrer` is set on the start redirect.
- **`return_to`** MUST be a local path: it MUST start with `/`, MUST NOT start
  with `//` or `/\`, is regex-constrained, and is double-decode-checked to reject
  open redirects.
- Logs redact `ot` / `pair_ot` / `code` / `state` / nested `return_to`.

#### 2.5.5 Portal sign-in state machine

`githubAuthState` ∈ { `idle`, `loading`, `signin`, `waiting`, `providers`,
`dashboard`, `claim` }:

- Load → `loading` → `GET /v1/auth/me/providers`: `401`/error → `signin`
  (offer "Sign in with GitHub" → `/v1/auth/github/start`); empty list →
  `waiting` (no Mac bound yet); >1 with no `?p=` match → `providers` (chooser);
  single or matched → `dashboard`.
- `/claim` route: captures `?ot=<pair_ot>` and immediately `history.replaceState`
  to strip it from the URL; `GET /v1/auth/me/providers` (401 → OAuth start with
  `return_to=/claim`); then `POST /v1/auth/me/providers/bind {pair_ot}` →
  success redirects to `/`; error codes `pair_ot_invalid` (410),
  `already_owned` (409), `session_invalid` (401).
- On a `401` from a data call in cookie mode, the portal clears the session and
  re-launches OAuth (`return_to` preserved) — it does not show the paste form.

#### 2.5.6 Bind semantics (cross-ref SPEC-003 FR-C10)

`POST /v1/auth/me/providers/bind` consumes the `pair_ot` and inserts
`provider_ownership(provider_id, github_user_id)` in one transaction, emitting an
`ownership_event` (SPEC-001 v1.5 frame) on commit; a `pair_ot` already owned by a
different identity returns `409 already_owned` (SPEC-003 FR-C10 anti-check). Body
parsing is strict (only the `pair_ot` key; trailing tokens rejected).
**There is no unbind/unlink path** in v0.9 — neither the portal nor the
coordinator exposes one; FR-C10.1 reserves an `unbound` ownership event for a
future operator-driven unlink flow. Document this as a known gap, not a control.

#### 2.5.7 Security disclosures (carried, honest)

- GitHub scope requested is `read:user` only.
- The session is a bearer-equivalent **cookie** — its theft grants access to the
  bound providers' read-only surfaces until logout/expiry; `HttpOnly` + `Secure`
  + `SameSite=Lax` + origin-bound CSRF state are the mitigations. This is a
  strictly larger auth surface than paste-bearer mode and is why it is
  opt-in/off-by-default.
- The two independent flags (§2.3) MUST be set together; a portal-on /
  coordinator-off split yields 404s + a misconfig banner, never a silent
  downgrade.

---

## 3. Layout and host string

ASCII layout in the style of SPEC-009 §2 — same 220 px sidebar,
same brand mark, same dark surface palette:

```
┌──────────────┬──────────────────────────────────────────┐
│   SIDEBAR    │                  MAIN                    │
│   220 px     │                                          │
│              │  Active surface renders here.            │
│ brand        │                                          │
│ ──────────── │  A. Machine (default)                    │
│ • Machine    │     header strip + counters row +        │
│ • Setup &    │     needs-attention panel                │
│   Updates    │                                          │
│ • Earn       │  B. Setup & Updates                      │
│ • Monitoring │     requirements grid + setup steps +    │
│ • Identity   │     version feed                         │
│              │                                          │
│ (spacer)     │  C. Earn                                 │
│ ──────────── │     credit totals + payout-status card   │
│ ↗ API Docs   │                                          │
│ ⎋ Sign out   │  D. Monitoring                           │
└──────────────┴──────────────────────────────────────────┘
                  E. Identity (rendered in same MAIN slot)
```

Sidebar items (v0.1, in this order):

1. Machine (default landing surface)
2. Setup & Updates
3. Earn
4. Monitoring
5. Identity
6. (spacer)
7. API Docs (external link to `https://api.streamvc.live/docs`)
8. Sign out (clears in-memory session; returns to AUTH-1 prompt)

**Mobile (< 720 px) breakpoint (SPEC-014 normative).** Below
720 px viewport width, the sidebar MUST collapse behind a
hamburger control OR hide gracefully (implementer's choice; both
satisfy this clause). The breakpoint and the hamburger-or-hide
choice are specified in SPEC-014; SPEC-009's own mobile handling
is similar but SPEC-014 does NOT inherit it normatively (no
"verbatim" claim).

**Host string.** The spec MAY propose `provider.streamvc.live` for
discussion but flags it as **Open Q7**: Pearl VPS nginx config and
DNS provisioning are operator decisions outside SPEC-014's scope.
Implementation MUST be host-agnostic (work at any host the
operator provisions).

**Browser-to-coordinator topology.** The portal calls
`/providers/{id}/earnings` and `/v1/pool/check` on the coordinator
from a different origin than `coordinator.streamvc.live`.
SPEC-002 / SPEC-005 do NOT document a CORS policy for these
routes. See **Open Q9**; recommended solution (a) is an operator-
owned reverse proxy at the portal origin that strips browser CORS
concerns by colocating portal and proxied coordinator routes on
the same origin. Recommendation is binding for v0.1: the
implementation MUST fail loudly (not silently fall back to other
origins) if the expected same-origin proxy is missing.

---

## 4. Surface inventory

### 4.1 Surface A — Machine dashboard (default)

Single-pane status of THIS machine.

**A.1 Header strip.** Fields:

- `provider_id` — pasted session value (no API).
- `tier` — from `GET /v1/pool/check?provider_id=<id>` (SPEC-002
  §7.4); enum `"pinned"` or `"provisional"`.
- `state` — from same response; enum `"ready"` / `"draining"` /
  `"unavailable"` / `"unknown"`.
- "Last refreshed Xs ago" / "stale" stamp on the `/v1/pool/check`
  poll. Cadence per §5 table (a).
- Manual refresh button (re-issues `/v1/pool/check`).

All other identity / runtime fields (hostname, model_id,
model_params_b, ram_gb, max_context_tokens, max_concurrency,
throughput_tps_estimate, binary_version, attestation,
endpoint_url, Apple model, GPU cores, serial prefix) are DEFERRED;
see §5 table (c) and Open Q5.

Online / offline pill: derived from `state ∈ {"ready",
"draining"}` (online) vs `state ∈ {"unavailable", "unknown"}`
(offline). The portal MUST NOT label this "heartbeat-current" —
`/v1/pool/check` does not expose heartbeat age (Open Q5).

"Update available" pill: DEFERRED to v0.2. Both ingredients
(`binary_version` and `recommended_binary_version`) flow only on
SPEC-001 §6.5 hello / hello_ack and have no browser-callable
source today. See §5 table (c) and Open Q5.

**A.2 Counters row (3 cards).** Single-machine. Source:
`GET /providers/{provider_id}/earnings` (SPEC-005 §11.4):

- Total credits earned (lifetime): `total_credits` (integer).
- Current window credits: `current_window_credits` (integer).
- Last payout-ready window: `last_payout_ready.window_start_utc`,
  `last_payout_ready.window_end_utc`, `last_payout_ready.
  provider_credits`.

Display units MUST match wire shape verbatim — integer credits in
the units SPEC-005 §11.4 emits. The portal MUST NOT invent fiat
conversions, "withdrawable balance", or USD amounts. SPEC-005
§1.3 lists fiat as out of scope.

**A.3 Needs-attention panel.** One row per active issue on THIS
machine; no machine-count chips (v0.1 is single-machine).

Issue taxonomy (v0.1) is restricted to existing observable
signals:

- **Unavailable** — `/v1/pool/check.state` returns `"unavailable"`
  or `"unknown"` (SPEC-002 §7.4). Row text: "This machine is
  currently `<state>`." Remediation hint: "Run `macprovider-cli
  status` to inspect local state; if the binary is healthy,
  re-check in a few seconds." Copy-to-clipboard CTA:
  `macprovider-cli status`. Heartbeat-miss diagnosis ("offline
  for N seconds, threshold M") is DEFERRED to v0.2 because
  `/v1/pool/check` exposes only the enum, not the heartbeat age.
  See Open Q5.
- **Update available** — DEFERRED to v0.2 alongside the A.1
  pill. SPEC-003 FR-C7 is explicit that the coordinator does NOT
  enforce versions; the advisory nudge has no browser-callable
  source today. The portal MUST NOT introduce a "below minimum /
  hard floor" variant.
- **Self-signed binary** — DEFERRED to v0.2. The only
  browser-callable per-provider STATUS / IDENTITY endpoint today
  is `/v1/pool/check`, which returns only `{provider_id, tier,
  state}`. Earnings (`/providers/{id}/earnings`) is a separate
  browser-callable endpoint but does not expose signing tier.
  Owning amendment: Open Q5 (signing tier is in the Q5 omnibus).
  Q10 (browser-local bridge) is NOT an owning Q for this row.
- **Model load failed** — DEFERRED to v0.2. The only place this
  signal exists today is the local CLI's `GET /v1/health`
  (SPEC-001 §6.4), which has no documented browser-CORS / port-
  discovery / mixed-content contract. See Open Q10 (browser-local
  bridge).

Each row MUST carry a one-line remediation hint AND a
copy-to-clipboard `macprovider-cli` invocation. The portal MUST
NEVER execute commands remotely (§7 non-goals). Each row MUST
cite its source endpoint + JSON path in §5 table (a) or its
deferred row in §5 table (c).

**A.4 Live metrics panel — DEFERRED to v0.2.** Current loaded
model exists in the local CLI surface (SPEC-003 §4 / FR-C4
status; SPEC-001 §6.4 `/v1/health`) but has no documented
browser-CORS / port-discovery / mixed-content contract — Open
Q10. Requests/min, tokens/min, p50 / p95 latency are NOT exposed
on either side today: SPEC-001 §6.4 `/v1/health` carries
liveness + capacity, not per-window rate or latency histograms;
SPEC-002 has no provider-scoped read endpoint for these. The
spec MUST NOT cite `/v1/health` as a source for fields it does
not return. `/poolz` is NOT a fallback source — it is operator-
keyed and forbidden from browser code. A.4 lives entirely in §5
table (c).

### 4.2 Surface B — Setup & updates

Two halves: static onboarding guide and a dynamic "what's new"
feed.

**B.1 Requirements grid (4 cards).** Mirrors SPEC-003 §5 / FR-D1
exactly — the FR-D1 README block reproduced verbatim inside that
clause is the canonical requirements list:

| Card | Value |
|---|---|
| Hardware | Apple Silicon Mac (M1, M2, M3, M4) |
| OS | macOS 14 (Sonoma) or later |
| Disk | ~4-8 GB free disk space |
| Network | Internet connection |

All four values are STATIC spec-backed — §5 table (b), no runtime
API call. (SPEC-003 §4 / FR-C2 covers install command + side
effects only; it does NOT define requirements. Do not cite FR-C2
for the requirements grid.)

**B.1a RAM-to-model sizing hint.** One adjacent card visually
distinct from the requirements grid. Source: SPEC-003 §5 / FR-D2
(and FR-D2.1 for the custom-id branch). FR-D2 is a recommendation,
not a hard requirement; the card MUST present it as a hint.

| RAM | Recommended model | Default |
|---|---|---|
| 8 GB | Llama 3.2 3B | Llama 3.2 3B |
| 16 GB | Llama 3.2 3B / Qwen 2.5 7B | Qwen 2.5 7B |
| 24 GB+ | + Qwen 2.5 14B | Qwen 2.5 14B |

§5 table (b), static spec-backed.

**B.2 Setup steps (numbered).**

1. **Install** via the `install.sh` one-liner (SPEC-003 §4 /
   FR-C2). The installer itself handles model selection (FR-D2 /
   FR-D2.1) and optionally offers launchd auto-start (FR-C5).
   `macprovider-cli install` is **not** a real subcommand — verify
   against SPEC-003 §6.2 before citing any CLI verb; `install` is
   not in that table.
2. **Verify routable** with `macprovider-cli status` (SPEC-003 §4
   / FR-C4). Local state comes from the binary's in-process
   metrics; provider tier shown by `status` originates from the
   most recent `hello_ack.tier`.
3. **(Optional)** "Consider running `macprovider-cli autotune`
   before serving." **AUTOTUNE BANNER PROHIBITED.** SPEC-013 §6 /
   NFR-4 forbids any non-HF egress during autotune (no telemetry,
   no recipe upload). The portal therefore CANNOT render autotune
   results — there is no data path. v0.1 surface is the
   copy-to-clipboard CTA only.

All snippets in B.2 are static spec-backed (§5 table (b)).

**B.3 Version feed (changelog reader).** Reverse-chronological
list of binary releases.

- SPEC-003 leaves the releases repository identity open
  (`macprovider-poc` or a dedicated `macprovider-releases` repo).
  See **Open Q2** for owner/name. Until resolved, the spec
  assumes `Augustas11/macprovider` (the mockup default) and
  records two implications:
  - **Rate limit.** The unauthenticated GitHub Releases API is
    capped at 60 requests / IP / hour. Browser polling MUST be
    cached and rate-limit-aware; the implementation MUST surface
    a fallback when `X-RateLimit-Remaining: 0` is observed,
    NOT silently retry.
  - **CORS posture.** GitHub Releases API supports CORS for
    public repos. The implementation MUST verify CORS by
    SUCCESSFUL BROWSER FETCH — i.e. if the `fetch()` promise
    resolves with a readable response body, CORS is working. A
    rejected `fetch()` (TypeError "Failed to fetch", opaque
    response, or other CORS-failure pathway) MUST surface as a
    loud, user-visible failure (not silently hidden). The portal
    MUST NOT attempt to read `Access-Control-Allow-Origin` as an
    application response header (browsers do not expose it
    unless listed in `Access-Control-Expose-Headers`, which
    GitHub does not list).
- Each entry: version, ship date, expandable release notes
  (markdown rendered from the GitHub release body), and a
  copy-to-clipboard `macprovider-cli update` CTA. No remote
  execution from the portal (§7).
- "You are N versions behind" badge: DEFERRED to v0.2 alongside
  A.1 update pill and A.3 update row. Installed `binary_version`
  is only carried on the SPEC-001 §6.5 hello WS frame and has no
  browser-callable source today. The version feed v0.1 lists
  releases without per-entry "currently installed" comparison.
  See Open Q5.

**B.4 Coordinator broadcasts panel — DEFERRED to v0.2.** The
coordinator-advertised version nudge (SPEC-003 FR-C7 / SPEC-001
§6.5 `hello_ack.recommended_binary_version`) flows only through
the provider WS handshake; no browser-callable broadcast endpoint
exists today. See Open Q5.

### 4.3 Surface C — Earn

**No fiat, no Stripe, no checkout, no card collection.** SPEC-005
§1.3 lists Stripe and fiat as explicitly out of scope, and §2.1
D1 says "no Stripe, no checkout, no credit card collection".
Surface C mirrors that constraint verbatim — any UI implying
imminent fiat payout is a contract violation.

**C.1 Credit totals row (3 cards).** Source: SPEC-005 §11.4
response JSON.

| Card | JSON path | Type |
|---|---|---|
| Lifetime | `total_credits` | integer |
| Current window | `current_window_credits` | integer |
| Last payout-ready window | `last_payout_ready.window_start_utc`, `last_payout_ready.window_end_utc`, `last_payout_ready.provider_credits` | string / string / integer |

§5 table (a), endpoint-backed dynamic.

**C.2 Payout-ready status card (no withdrawal UX).** Single
status badge:

> **Fiat payout rail not yet specified — future spec.**

The card MUST NOT include: country selector, "Link bank via
Stripe" button, account-type picker, or any other flow that
implies imminent withdrawal. See **Open Q3** (owner: operator +
legal, not the SPEC-014 author).

**C.3 Earnings breakdown — DEFERRED to v0.2.** Time bucketing
day/week/month, per-model credit breakdown, and per-day bar chart
all require fields `GET /providers/{id}/earnings` does NOT
currently return. SPEC-005 §11.4 returns aggregate credits plus
ancillary provider metadata (`provider_id`, `provider_share_bps`,
`models_served`, `rate_card_excerpt`, `fault_count`); the
ancillary fields are intentionally omitted from v0.1 because they
are not the per-bucket / per-model credit decomposition C.3
requires. See **Open Q4** for the SPEC-005 amendment that would
expose the missing breakdowns. v0.1 ships C.1 aggregate cards
only. Do NOT invent a new endpoint inside SPEC-014.

**C.4 Per-job activity feed — DEFERRED to v0.2.** SPEC-005 §11.4
returns the aggregate-plus-ancillary shape described in C.3 — no
per-row `ledger_request_credits` data is exposed. Same
disposition as C.3; covered by Open Q4.

**C.5 API surface (recap).**

- Authoritative endpoint: `GET /providers/{provider_id}/earnings`
  (SPEC-005 §11.4).
- Auth: FR-P12 provider bearer token, subject == path
  `provider_id` (SPEC-005 §11.5).
- Deployment-mode dependency: §2.4 above.

### 4.4 Surface D — Monitoring (placeholder)

Every D-class signal (uptime ribbon, per-provider routing weight,
live request stream) is unsourced by any browser-callable,
provider-scoped endpoint that exists today. Rather than dropping
the surface entirely, Surface D renders a SINGLE placeholder card
titled:

> **Monitoring — coming after SPEC-002 amendment**

with three bullets (static text, no API call):

- **Uptime history (24 h / 7 d / 30 d)** — needs Open Q5.
- **Current routing weight** — needs Open Q5.
- **Live request tail** — needs Open Q5 **and** a privacy-
  redaction policy decision (which fields the provider may see;
  what redaction applies to buyer prompts, completions,
  identity, API keys, and IPs).

Each bullet links to its §9 Open Q. AC group (a) verifies the
placeholder card emits ZERO network requests. Sub-cards D.1,
D.2, D.3 are defined informationally below so a future v0.2 has a
target to wire against:

- D.1 Uptime ribbon (24 h / 7 d / 30 d) — Open Q5.
- D.2 Current routing weight — Open Q5.
- D.3 Live request stream — Open Q5 + privacy-redaction policy.

### 4.5 Surface E — Identity (read-only)

Notifications dropped entirely; SPEC-005 §2.11 D11 forbids
adding email or Slack delivery infrastructure.

**E.1 Identity card.** Fields:

- `provider_id` — pasted session value (also persisted on the Mac
  at `~/.config/macprovider/provider_id`, SPEC-003 §4 / FR-C2
  step 10; no runtime API call here).
- Provider tier badge — `tier` field from `GET /v1/pool/check`
  (SPEC-002 §7.4). NOT from `hello_ack.tier`, which is WS traffic
  the browser cannot read.
- Current state — `state` from same `/v1/pool/check` response.
- Coordinator base URL — from operator-declared
  `portal-config.json.coordinator_base_url` (AUTH-3); §5 table
  (b).

All hardware / runtime fields are DEFERRED — see the A.1
deferral rationale and Open Q5. The UI grouping labels used
informally in this paragraph map to the SPEC-001 §6.5 hello
wire fields as follows: "model" → `model_id` + `model_params_b`;
"RAM" → `ram_gb`; "capacity" → `max_context_tokens` +
`max_concurrency` + `throughput_tps_estimate`. The §5 table
(c) row for E.1 enumerates every wire field by name; Open Q5
owns them.

**Out of scope for v0.1 (Surface E):**

- Notifications of any delivery channel (email, Slack, push,
  SMS). v0.1 may include in-portal visual flags (e.g. the A.1
  offline pill) but MUST NOT include opt-in toggles for
  out-of-portal delivery. See Open Q11.
- Provider auth token rotation. See Open Q6.
- "Remove this machine." See Open Q6.

---

## 5. API contract + field-source tables + thresholds

Three tables are mandatory; every UI field in §4 MUST appear in
exactly one of them.

### 5.1 Table (a) — Endpoint-backed dynamic fields

| Surface | Field | Source endpoint | JSON path | Poll cadence | Cache policy | Source citation |
|---|---|---|---|---|---|---|
| A.1 | tier | `GET /v1/pool/check?provider_id=<id>` | `tier` | 30 s + manual refresh | in-memory; invalidated on refresh | SPEC-002 §7.4 |
| A.1 | state | `GET /v1/pool/check?provider_id=<id>` | `state` | 30 s + manual refresh | in-memory; invalidated on refresh | SPEC-002 §7.4 |
| A.1 | online/offline pill | derived from `state` (see A.1) | n/a (derived) | 30 s + manual refresh | derived | SPEC-002 §7.4 |
| A.1 | "Last refreshed Xs ago" / "stale" stamp | derived from the local Date.now() at `/v1/pool/check` response receipt | n/a (derived from local clock + response timestamp) | re-rendered every 1 s; reset on each successful poll | in-memory; no persistence | SPEC-002 §7.4 (poll endpoint); §5.4 stale-threshold row |
| A.2 | total credits | `GET /providers/{id}/earnings` | `total_credits` | 60 s | in-memory; 60 s TTL | SPEC-005 §11.4 |
| A.2 | current window credits | `GET /providers/{id}/earnings` | `current_window_credits` | 60 s | in-memory; 60 s TTL | SPEC-005 §11.4 |
| A.2 | last payout-ready window | `GET /providers/{id}/earnings` | `last_payout_ready.{window_start_utc, window_end_utc, provider_credits}` | 60 s | in-memory; 60 s TTL | SPEC-005 §11.4 |
| A.3 | "Unavailable" row | `GET /v1/pool/check?provider_id=<id>` | `state` (when `"unavailable"` or `"unknown"`) | 30 s + manual refresh | in-memory; invalidated on refresh | SPEC-002 §7.4 |
| B.3 | release list | `GET https://api.github.com/repos/{owner}/{name}/releases` | array root (`tag_name`, `published_at`, `body`); also reads response header `X-RateLimit-Remaining` (which GitHub does expose to browser code) | on demand + 5 min TTL | in-memory; rate-limit aware | Open Q2 (host) + GitHub Releases API |
| B.3 | rate-limit fallback notice | derived from the B.3 release-list response header `X-RateLimit-Remaining: 0` | n/a (header-derived); rendered as static notice text "GitHub API rate limit reached — release feed paused; refresh later." | re-evaluated on each B.3 fetch | in-memory; cleared on next non-zero remaining | GitHub Releases API rate-limit posture (Open Q2 records the 60 req/IP/hr cap) |
| B.3 | CORS / fetch-failure notice | derived from a rejected B.3 release-list `fetch()` (TypeError / opaque response / other CORS-failure pathway) | n/a (fetch-rejection-derived); rendered as static notice text "GitHub Releases unavailable — release feed disabled; see SPEC-014 Open Q2." | re-evaluated on each B.3 fetch | in-memory; surfaced as a loud, user-visible failure (NOT silently hidden) | GitHub Releases CORS posture (Open Q2) |
| C.1 | lifetime / window / last-payout credit cards | `GET /providers/{id}/earnings` | `total_credits`, `current_window_credits`, `last_payout_ready.{window_start_utc, window_end_utc, provider_credits}` | 60 s | in-memory; 60 s TTL | SPEC-005 §11.4 |
| E.1 | tier badge | `GET /v1/pool/check?provider_id=<id>` | `tier` | 30 s + manual refresh | in-memory; invalidated on refresh | SPEC-002 §7.4 |
| E.1 | state | `GET /v1/pool/check?provider_id=<id>` | `state` | 30 s + manual refresh | in-memory; invalidated on refresh | SPEC-002 §7.4 |

### 5.2 Table (b) — Static / spec-backed fields (no runtime API call)

| Surface | Field | Source artifact | Display mode |
|---|---|---|---|
| A.1 | `provider_id` | pasted session value (AUTH-1) | inline text |
| A.1 | manual refresh button | static UI control; on click, re-issues the A.1 `/v1/pool/check` call (table (a) row) | static button + click handler |
| A.3 | "Unavailable" row text | literal "This machine is currently `<state>`." (state interpolated from the A.3 table (a) row) | static text with one interpolation |
| A.3 | "Unavailable" row remediation hint | literal "Run `macprovider-cli status` to inspect local state; if the binary is healthy, re-check in a few seconds." | static text |
| A.3 | "Unavailable" row copy-to-clipboard CTA | `macprovider-cli status` (SPEC-003 §4 / FR-C4, per SPEC-003 §6.2) | code snippet + copy-to-clipboard |
| B.3 | per-entry `macprovider-cli update` copy-to-clipboard CTA | SPEC-003 §4 / FR-C3 (per SPEC-003 §6.2) | code snippet + copy-to-clipboard |
| E.1 | `provider_id` | pasted session value (AUTH-1; also persisted on the Mac at `~/.config/macprovider/provider_id`, SPEC-003 §4 / FR-C2 step 10) | inline text |
| B.1 | "Apple Silicon Mac (M1, M2, M3, M4)" | SPEC-003 §5 / FR-D1 README block | static card |
| B.1 | "macOS 14 (Sonoma) or later" | SPEC-003 §5 / FR-D1 README block | static card |
| B.1 | "~4-8 GB free disk space" | SPEC-003 §5 / FR-D1 README block | static card |
| B.1 | "Internet connection" | SPEC-003 §5 / FR-D1 README block | static card |
| B.1a | RAM-to-model sizing table | SPEC-003 §5 / FR-D2 + FR-D2.1 | static table |
| B.2 step 1 | `install.sh` one-liner | SPEC-003 §4 / FR-C2 | code block + copy-to-clipboard |
| B.2 step 2 | `macprovider-cli status` snippet | SPEC-003 §4 / FR-C4 (per SPEC-003 §6.2) | code block + copy-to-clipboard |
| B.2 step 3 | `macprovider-cli autotune` snippet | SPEC-013 §7 (CLI surface summary) | code block + copy-to-clipboard |
| C.2 | "Fiat payout rail not yet specified — future spec." | SPEC-005 §1.3 + §2.1 D1 + Open Q3 | static badge |
| D placeholder card | "Monitoring — coming after SPEC-002 amendment" + 3 bullets | Open Q5 + privacy-redaction policy TBD | static card |
| E.1 | coordinator base URL | `portal-config.json.coordinator_base_url` (AUTH-3) | inline text |
| (all) | sign-in screen copy | AUTH-1 narrative | static |
| (all) | unavailable-mode page copy | AUTH-3 narrative | static |

### 5.3 Table (c) — Deferred fields

| Surface | Field | Why deferred (one line) | Owning spec amendment | Open Q |
|---|---|---|---|---|
| A.1 | hostname | SPEC-001 §6.5 hello field is WS-only, not browser-callable | SPEC-002 (machine-detail endpoint) | Q5 |
| A.1 | model_id | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | model_params_b | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | ram_gb | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | max_context_tokens | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | max_concurrency | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | throughput_tps_estimate | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | binary_version | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | attestation | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | endpoint_url | SPEC-001 §6.5 hello field is WS-only | SPEC-002 | Q5 |
| A.1 | Apple model / GPU cores / serial prefix | not in SPEC-001 hello at all | SPEC-002 + SPEC-001 schema add | Q5 |
| A.1 | "Update available" pill | needs installed `binary_version` and coordinator `recommended_binary_version`; both WS-only | SPEC-002 broadcast relay; advisory-only per SPEC-003 FR-C7 | Q5 |
| A.1 | heartbeat-current label | `/v1/pool/check` does not expose heartbeat age | SPEC-002 (heartbeat-history endpoint) | Q5 |
| A.3 | "Update available" row | same as A.1 update pill | SPEC-002 broadcast relay | Q5 |
| A.3 | "Self-signed binary" row | signing tier WS-only; `/v1/pool/check` does not expose it | SPEC-002 (machine-detail endpoint; "signing tier" is in the Q5 enumeration) | Q5 |
| A.3 | "Model load failed" row | only source is local `/v1/health`; no browser-CORS / port-discovery contract | browser-local bridge | Q10 |
| A.4 | current loaded model | only source is local `/v1/health`; no browser-CORS contract | browser-local bridge | Q10 |
| A.4 | requests/min, tokens/min | not exposed on `/v1/health`; no coordinator surface | SPEC-001 metrics-shape amend + SPEC-002 browser-callable endpoint | Q5 |
| A.4 | latency p50 / p95 | same as rates | SPEC-001 metrics-shape amend + SPEC-002 | Q5 |
| B.3 | per-entry "currently installed" badge | needs installed `binary_version`; WS-only | SPEC-002 machine-detail endpoint | Q5 |
| B.4 | coordinator broadcasts panel | nudge flows on WS handshake only | SPEC-002 broadcast relay | Q5 |
| C.3 | day/week/month bucketed earnings | `/providers/{id}/earnings` returns aggregate only | SPEC-005 earnings-breakdown amendment | Q4 |
| C.3 | per-model breakdown | aggregate-only endpoint | SPEC-005 amendment | Q4 |
| C.3 | per-day bar chart | aggregate-only endpoint | SPEC-005 amendment | Q4 |
| C.4 | per-job activity feed | aggregate-only endpoint | SPEC-005 amendment | Q4 |
| D.1 | uptime ribbon | no uptime-history endpoint | SPEC-002 amendment | Q5 |
| D.2 | current routing weight | no per-provider weight endpoint | SPEC-002 amendment | Q5 |
| D.3 | live request stream | no request-tail endpoint + no privacy-redaction policy | SPEC-002 amendment + policy decision | Q5 |
| E.1 | hostname / model_id / model_params_b / ram_gb / max_context_tokens / max_concurrency / throughput_tps_estimate / binary_version / attestation / endpoint_url | SPEC-001 §6.5 hello fields, WS-only; identical deferral rationale to the matching A.1 rows above (the §4.5 prose uses the labels "model", "RAM", "capacity" as UI groupings; the underlying wire fields are the ones named here and enumerated in Open Q5) | SPEC-002 (machine-detail endpoint) | Q5 |
| E.1 | provider auth token rotation | no provider-self-service rotation endpoint | SPEC-002 amendment (provider-side rotation) | Q6 |
| E.1 | "Remove this machine" | machine removal today is operator-only via `POST /admin/blacklist` | SPEC-002 + SPEC-005 ledger-snapshot policy | Q6 |
| (any) | notifications (email / Slack / push / SMS) | SPEC-005 §2.11 D11 forbids new delivery infra | future notification spec | Q11 |

### 5.4 Thresholds table

| Variable | Default value | Source SPEC-002 config key (or "new") | Owner | Override path |
|---|---|---|---|---|
| `/v1/pool/check` poll cadence | 30 s | new (portal-side; not configurable in v0.1) | portal author | not configurable in v0.1 — operator edits source if needed |
| `/providers/{id}/earnings` poll cadence | 60 s | new (portal-side; not configurable in v0.1) | portal author | not configurable in v0.1 — operator edits source if needed |
| Earnings cache TTL | 60 s | new (portal-side; not configurable in v0.1) | portal author | not configurable in v0.1 |
| `/providers/{id}/earnings` rate-limit per provider | 60 / min | `endpoints.provider_earnings.rate_limit_per_minute` (SPEC-005 §13) | operator | coordinator config |
| Releases-feed GitHub API cache TTL | 5 min | new (portal-side; not configurable in v0.1) | portal author | not configurable in v0.1 |
| Releases-feed unauthenticated rate-limit | 60 / IP / hr | GitHub-imposed (not configurable) | GitHub | n/a (Open Q2 may move to authenticated rail) |
| "Stale" stamp threshold on A.1 | 2 × poll cadence (60 s) | new (portal-side; not configurable in v0.1) | portal author | not configurable in v0.1 |
| Heartbeat-miss threshold (for A.3 rich offline reason) | TBD — DEFERRED | new — Open Q5 | TBD | TBD |

No threshold is left unresolved in §4 prose — every threshold has
either a config-key source above or a TBD pointing at a specific
Open Q. v0.1 deliberately keeps portal-side thresholds non-
configurable to stay consistent with the strict `portal-config.
json` allowlist in §2.3 (AUTH-3 loader rejects unknown top-level
keys); a future v0.2 may add override keys, in which case those
keys MUST be added to the AUTH-3 allowlist in the same change.
The `/v1/pool/check` per-IP rate limit is owned by the coordinator
(SPEC-002 §7.4 documents HTTP 429 but no normative numeric
default); SPEC-014 does not own it, so v0.1 omits it from this
table. The 30 s portal poll cadence is well under any plausible
coordinator default. JSON-path column is required only for table
(a) rows.

---

## 6. Visual design tokens

Inherits SPEC-009 §6 verbatim; deviations enumerated below.

**Deviations:** none in v0.1.

Type families, dark surface palette, accent purple, sidebar
geometry (220 px), and the empty-state hero layout are all
imported as-is from SPEC-009 §6 + §2.

---

## 7. Non-goals for v0.1

In addition to the §1.2 scope cuts:

- **No remote command execution.** The portal renders CTAs as
  copy-to-clipboard shell snippets only. There is no "click here
  to update" button that talks to the Mac, the coordinator, or
  any agent on either side.
- **No multi-Mac aggregation.** See Open Q1.
- **No fiat payout UX of any kind.** SPEC-005 §1.3 + §2.1 D1.
  See Open Q3.
- **No anomaly-detection ML.** Thresholds-only diagnostics.
- **No mobile-native app.** Responsive web only.
- **No `localStorage` of the provider auth token in v0.1.**
  In-memory only. Closing the tab discards the session.

---

## 8. Acceptance criteria

Layered, NOT a flat checklist. Six required groups.

### 8(a) Per-surface ACs

**Surface A (Machine).**

- [ ] A.1 header strip renders `provider_id` (pasted), `tier`
      (from `/v1/pool/check`), `state` (from same), and a "last
      refreshed Xs ago" stamp.
- [ ] A.1 manual refresh button re-issues `/v1/pool/check` and
      updates the stamp.
- [ ] A.1 online/offline pill maps `/v1/pool/check.state` per
      §4.1: `"ready"` → online; `"draining"` → online;
      `"unavailable"` → offline; `"unknown"` → offline. A fixture
      iterates all four enum values and asserts the rendered
      pill label.
- [ ] A.1 "stale" stamp transition: after the last successful
      `/v1/pool/check` response, advancing a fake clock past
      `2 × poll cadence` (60 s with the v0.1 default 30 s
      cadence) MUST flip the stamp label to "stale". A
      subsequent successful poll MUST reset the label to
      "Last refreshed Xs ago".
- [ ] A.1 shows no hostname / model / RAM / binary_version fields
      (all deferred per §5 table (c)).
- [ ] A.2 renders three credit cards from `/providers/{id}/
      earnings` JSON paths verbatim; no fiat conversion.
- [ ] A.3 renders one row when `/v1/pool/check.state ∈
      {"unavailable", "unknown"}`, with the literal text "This
      machine is currently `<state>`." and a copy-to-clipboard
      `macprovider-cli status` CTA.
- [ ] A.3 row never executes a command remotely.
- [ ] A.4 is not rendered in v0.1 (entirely in §5 table (c)).

**Surface B (Setup & Updates).**

- [ ] B.1 renders exactly four cards matching FR-D1 verbatim.
- [ ] B.1a renders the FR-D2 sizing card adjacent to B.1.
- [ ] B.2 step 1 cites SPEC-003 §4 / FR-C2 and renders the
      `install.sh` one-liner.
- [ ] B.2 step 2 renders the `macprovider-cli status` snippet
      with a copy-to-clipboard control and cites SPEC-003 §4 /
      FR-C4 (per the §5 table (b) row).
- [ ] B.2 step 3 does NOT render an autotune-results banner (only
      the copy-to-clipboard CTA per SPEC-013 §6 / NFR-4).
- [ ] B.3 lists GitHub Releases entries; no "currently installed"
      comparison badge appears in v0.1.
- [ ] B.3 honors the GitHub Releases 60 req/IP/hr rate limit:
      surfaces a fallback notice when the response header
      `X-RateLimit-Remaining` reads `0`, AND surfaces a loud
      user-visible "GitHub Releases unavailable" notice when the
      `fetch()` promise rejects (CORS failure or other network
      error). The portal MUST NOT attempt to read
      `Access-Control-Allow-Origin` as an application header.
- [ ] B.4 panel is not rendered (deferred per §5 table (c)).

**Surface C (Earn).**

- [ ] C.1 renders three credit cards from SPEC-005 §11.4 JSON
      paths verbatim.
- [ ] C.2 renders the "Fiat payout rail not yet specified — future
      spec." badge and NOTHING ELSE.
- [ ] C.2 contains no country selector, no "Link bank", no
      account-type picker, no Stripe button, no payout-now CTA.
- [ ] C.3 and C.4 are not rendered.

**Surface D (Monitoring).**

- [ ] D renders ONE placeholder card with three bullets linked to
      Open Q5.
- [ ] D emits ZERO network requests (verified by a network panel
      observation or a unit-test mocking the fetch layer).

**Surface E (Identity).**

- [ ] E.1 renders `provider_id`, `tier`, `state`, and
      `coordinator_base_url` only.
- [ ] E.1 renders no hostname / model / RAM / binary_version /
      capacity / attestation / endpoint_url fields.
- [ ] No notification toggle, rotation button, or remove-machine
      CTA appears anywhere in v0.1.

### 8(b) Auth ACs

- [ ] On load with `portal-config.json` missing, portal renders
      the unavailable-mode page naming the missing file path AND
      makes ZERO network calls after the failed
      `/portal-config.json` fetch (verified by a network-panel
      observation or a spy on the fetch layer that asserts no
      calls to `/v1/pool/check`, `/providers/{id}/earnings`,
      `/v1/auth/*`, or the GitHub Releases host). This fail-closed check runs
      before mode selection, so it holds regardless of `github_oauth_enabled`.
- [ ] On load with `portal-config.json.require_provider_tokens =
      false`, portal renders the unavailable-mode page AND makes
      ZERO network calls after the `/portal-config.json` fetch
      (verified by the same spy targets: `/v1/pool/check`,
      `/providers/{id}/earnings`, `/v1/auth/*`, GitHub Releases). The public
      `/v1/pool/check` and the unauthenticated GitHub Releases
      endpoint MUST NOT be polled in either of the two
      unavailable-mode entry points.
- [ ] **Paste-bearer mode** — authenticated call returning 401 → portal returns
      to the sign-in prompt; error message does not distinguish "missing"
      vs "malformed".
- [ ] **Paste-bearer mode** — 403 → portal renders a
      "sign-in rejected" message identical to the 404 case; 404 → the same
      "sign-in rejected" message (does NOT reveal that the `provider_id` is
      unknown).
- [ ] In `require_provider_tokens: true` **paste-bearer** mode, after **two
      consecutive authenticated provider-endpoint failures on
      the same surface within the same signed-in session**, the
      portal surfaces the explicit "deployment may be
      misconfigured" notice AND does NOT silently fall back to
      the unavailable-mode page. The first failure follows
      AUTH-2 handling.
- [ ] Static grep / build-time check: bundle contains zero
      references to `/poolz`, `/admin/blacklist`,
      `/admin/provisional`, `/admin/promote`, `/admin/reject`,
      `/admin/ledger` (matches the §10 dependency table). The only coordinator
      paths the bundle may reference are the paste-mode data paths
      (`/v1/pool/check`, `/providers/{id}/earnings`) and, for GitHub-OAuth mode,
      the §2.5.2 `/v1/auth/*` allowlist — no other `/v1/auth/*` or `/admin/*`.
- [ ] Portal never prompts for, parses, or transmits the operator
      key. The loader accepts exactly the four `portal-config.json` keys
      (`coordinator_base_url`, `releases_repo_owner_name`,
      `require_provider_tokens`, `github_oauth_enabled`) and rejects any unknown
      top-level key; `github_oauth_enabled` must be boolean when present.

**GitHub-OAuth mode ACs (reconciled v0.9; verified only when
`github_oauth_enabled: true`):**

- [ ] Mode selection: with `github_oauth_enabled: true`, load calls
      `GET /v1/auth/me/providers` (cookie, `credentials:"include"`, no
      `Authorization` header) and NOT the paste sign-in form; with the flag
      absent/`false`, load renders the paste form and never calls `/v1/auth/*`.
- [ ] Cookie-mode `401` on a data or `me/providers` call re-launches
      `GET /v1/auth/github/start` (preserving `return_to`) — it does NOT show
      the paste form and does NOT fall back to bearer.
- [ ] `/claim?ot=<pair_ot>` strips `?ot=` from the URL via `history.replaceState`
      before any render, then binds via `POST /v1/auth/me/providers/bind`;
      `410 pair_ot_invalid` / `409 already_owned` / `401 session_invalid` render
      distinct claim-error copy; success redirects to `/`.
- [ ] `return_to` rejects a value that does not start with `/`, or starts with
      `//` or `/\`, or fails the double-decode check (open-redirect guard).
- [ ] Coordinator sets the `mp_session` cookie `HttpOnly; Secure; SameSite=Lax;
      Path=/; Max-Age=2592000`; `POST /v1/auth/logout` clears it (204).
- [ ] OAuth `state` is single-use and origin-bound; a replayed or
      mismatched-origin `state` at `/v1/auth/github/callback` is rejected.
- [ ] Two-flag misconfig: portal `github_oauth_enabled:true` + coordinator flag
      off → `/v1/auth/*` 404 → misconfiguration banner; the portal does NOT fall
      back to paste-bearer mode.
- [ ] Coordinator mounts `/v1/auth/*` ONLY when `GITHUB_OAUTH_ENABLED=true`
      (routes absent → 404 when off).

### 8(c) Field-source ACs

- [ ] Every UI field shown in §4 appears as a row in exactly one
      §5 table: (a) endpoint-backed, (b) static / spec-backed, or
      (c) deferred.
- [ ] Each (c) row cites its Open Q **inside the deferred-table
      row**, not in place of the row.
- [ ] No UI field in §4 is rendered without a corresponding §5
      row; the portal's component map can be enumerated and
      cross-checked.
- [ ] Smoke check: rendered bundle ships zero references to
      `/poolz` or `/admin/*` (composes with 8(b)).

### 8(d) Privacy ACs

- [ ] No buyer-identifying field (buyer `request_id`, buyer
      account id, buyer prompt text, buyer completion text, buyer
      IP, buyer API key) appears anywhere in the portal in v0.1.
- [ ] Explicit list of fields the portal displays from upstream
      endpoints, each with a one-line "this is provider-only
      data" justification:
      - `provider_id` (path subject; provider-owned identity).
      - `tier` (provider's pool tier; not buyer-derived).
      - `state` (provider's pool state; not buyer-derived).
      - `total_credits`, `current_window_credits`,
        `last_payout_ready.*` (provider's earnings rollups; no
        per-request data; no buyer attribution).
      - GitHub Releases body (public artifact; no buyer data).
- [ ] D.3 live request stream is NOT rendered in v0.1, closing
      the privacy-redaction policy gap by deferral (Open Q5).

### 8(e) Open-Q assumption ACs

Each Open Q has an "if not answered, portal does X" line; the AC
asserts X actually happens.

- [ ] Q1 (multi-Mac): portal contains no "N machines" copy and no
      machine grid; all copy uses singular "this Mac" / "this
      machine".
- [ ] Q2 (releases repo): until answered, portal reads from
      `Augustas11/macprovider` and surfaces a rate-limit fallback
      when GitHub returns 0 remaining.
- [ ] Q3 (fiat payout rail): portal renders the "future spec"
      badge in C.2; no withdrawal flow exists anywhere.
- [ ] Q4 (earnings breakdown): C.3 + C.4 are not rendered.
- [ ] Q5 (omnibus SPEC-002 / SPEC-001 amendments): every §5(c)
      row pointing at Q5 has its associated UI element
      not-rendered in v0.1.
- [ ] Q6 (rotation + removal): no rotation button, no remove-
      machine CTA exists.
- [ ] Q7 (host string): implementation works at any host the
      operator provisions (no `provider.streamvc.live` hard-code
      in the bundle).
- [ ] Q8 (deployment-mode discovery): portal trusts
      `portal-config.json` and fails CLOSED on missing / non-200.
- [ ] Q9 (CORS / reverse proxy): implementation fails loudly when
      the expected same-origin proxy is absent.
- [ ] Q10 (browser-local bridge): A.4 + the A.3 model-load row
      are not rendered; portal never attempts to call
      `http://localhost:<port>/v1/health` from the page.
- [ ] Q11 (notification infra): no notification opt-in toggle
      exists anywhere in v0.1.

### 8(f) Single-machine ACs

- [ ] UI has NO concept of "N machines" — no machine count
      header, no machine grid, no "x3" chip on attention rows.
- [ ] Copy uses "this Mac" or "this machine"; the strings
      "your fleet", "your machines", "across machines", "all
      machines" do NOT appear anywhere in the bundle.
- [ ] Build-time grep enforces the union of bullet 1 + bullet 2
      prohibited strings: at minimum `"your fleet"`,
      `"your machines"`, `"across machines"`, `"all machines"`,
      `"N machines"`, `"N/M"`, `"x3"`, `"machine grid"`, plus
      any locale-specific variant the implementation introduces.
      The grep MUST be run against the rendered bundle (HTML +
      JS + CSS), and the CI step MUST fail loudly when any
      prohibited string appears.

---

## 9. Open questions

Each Q has: question, why it matters, who decides, what the spec
assumes in the meantime, what the portal renders if the answer is
not yet available.

### Q1 — Multi-Mac owner identity

- **Question:** Is there (or will there be) a first-class
  multi-Mac owner identity that aggregates several `provider_id`s
  under one person?
- **Why:** Without it, the portal cannot show a fleet view.
  Adding one requires a new identity model in SPEC-002 (or a new
  spec); this would also reshape SPEC-005 §11.4 to support
  multi-subject aggregation.
- **Who decides:** operator + SPEC-002 author + SPEC-005 author.
- **Spec assumes:** single-machine v0.1; no aggregation.
- **Portal renders if unanswered:** the single-machine layout in
  §4 (no machine count, no grid).

### Q2 — Releases repository + GitHub API rate limit + CORS posture

- **Question:** Which GitHub repo hosts `macprovider-cli`
  releases (current or `macprovider-releases`)?
- **Why:** B.3 polls GitHub Releases for the version feed;
  unauthenticated browser polling is capped at 60 req/IP/hr;
  CORS must be confirmed for the chosen repo.
- **Who decides:** operator + SPEC-003 author.
- **Spec assumes:** `Augustas11/macprovider`; GitHub Releases
  CORS supports public repos.
- **Portal renders if unanswered:** version feed from the assumed
  repo, with a rate-limit fallback notice on
  `X-RateLimit-Remaining: 0`.

### Q3 — Fiat payout rail (future spec)

- **Question:** What spec governs the fiat / crypto payout rail
  that consumes `ledger_payout_ready`?
- **Why:** Surface C.2 needs to point somewhere; SPEC-005 §1.3 +
  §2.1 D1 keep it out of v1.
- **Who decides:** operator + legal (NOT SPEC-014 author).
- **Spec assumes:** no rail in v0.1.
- **Portal renders if unanswered:** "Fiat payout rail not yet
  specified — future spec." badge in C.2.

### Q4 — SPEC-005 earnings breakdown amendment

- **Question:** Does SPEC-005 expose a per-bucket / per-model /
  per-job breakdown of provider earnings on a browser-callable
  endpoint?
- **Why:** Surface C.3 + C.4 need fields not in SPEC-005 §11.4
  today. SPEC-014 MUST NOT invent a new endpoint.
- **Who decides:** SPEC-005 author.
- **Spec assumes:** no breakdown in v0.1.
- **Portal renders if unanswered:** C.3 + C.4 not rendered;
  Surface C is C.1 + C.2 only.

### Q5 — Upstream-spec amendments omnibus

The "v0.1 needs this but the upstream spec does not expose it"
bucket. Q5 in §9 MUST list every item below verbatim so a writer
cannot cite Q5 against a deferred field without an explicit
owning amendment.

- **SPEC-002 — provider-scoped browser-callable surface for
  per-machine detail.** Specifically: `hostname`, `model_id`,
  `model_params_b`, `ram_gb`, `max_context_tokens`,
  `max_concurrency`, `throughput_tps_estimate`, `binary_version`,
  `attestation`, `endpoint_url` (all the SPEC-001 hello fields
  that exist but flow only over the provider WS); signing tier;
  Apple model / GPU cores / serial prefix (these three are NOT in
  SPEC-001 hello today and would also require a SPEC-001 schema
  amendment to populate the new SPEC-002 surface); heartbeat
  history; per-provider routing weight; request tail + privacy-
  redaction policy; coordinator-broadcast relay for the advisory
  `recommended_binary_version` nudge (SPEC-003 FR-C7 — advisory
  only, NOT a hard floor).
- **SPEC-001 — metrics-shape amendment** to expose rate
  (requests/min, tokens/min) and latency histograms (p50 / p95)
  on the local health endpoint, which §6.4 does not currently
  return.
- **Why:** Surface A.1 hardware fields, A.1 update pill, A.3
  update + self-signed rows, A.4 metrics panel, B.3 currently-
  installed badge, B.4 broadcasts, D.1 uptime, D.2 routing weight,
  D.3 request tail, and E.1 hardware fields all need surfaces
  upstream specs do not currently provide. (The A.3 model-load-
  failed row and A.4 current-loaded-model card belong to Open Q10,
  not Q5 — the gap is the browser-local bridge to `/v1/health`,
  not a coordinator amendment.)
- **Who decides:** SPEC-002 author + SPEC-001 author.
- **Spec assumes:** none of these surfaces exist in v0.1.
- **Portal renders if unanswered:** the §5 table (c) deferrals
  hold; those UI elements do not render.

### Q6 — Provider-side token rotation + self-service removal

- **Question:** Does SPEC-002 add a provider-self-service token
  rotation endpoint, and does it (plus a SPEC-005 ledger-snapshot
  policy) enable a provider-self-service "remove this machine"
  flow?
- **Why:** Surface E.1 cannot expose either action without these
  endpoints. Operator-only removal via `/admin/blacklist`
  (SPEC-002 §7.4) is not browser-safe.
- **Who decides:** SPEC-002 author + SPEC-005 author.
- **Spec assumes:** no rotation, no self-service removal in v0.1.
- **Portal renders if unanswered:** Surface E.1 omits both
  actions.

### Q7 — Portal host string + nginx + DNS

- **Question:** What hostname does the portal live at, and which
  nginx + DNS configuration does Pearl VPS get?
- **Why:** SPEC-014 is host-agnostic; operator decisions live
  outside its scope.
- **Who decides:** operator.
- **Spec assumes:** mockup proposes `provider.streamvc.live`;
  binding decision is the operator's.
- **Portal renders if unanswered:** implementation works at any
  host the operator provisions.

### Q8 — Deployment-mode discovery mechanism

- **Question:** Should the portal continue to rely on
  operator-declared `portal-config.json`, or should SPEC-002 /
  SPEC-005 expose a runtime mode probe?
- **Why:** Operator-declared mode has a stale-config risk (the
  flag flips on the coordinator but `portal-config.json` is not
  updated). A runtime probe closes that risk.
- **Who decides:** SPEC-002 author (recommended) — file in v-next.
- **Spec assumes:** operator-declared mode in v0.1 (§2.3,
  AUTH-3).
- **Portal renders if unanswered:** AUTH-3 mechanism stays.

### Q9 — Browser-to-coordinator CORS / reverse-proxy topology

- **Question:** Does the portal call the coordinator via (a) an
  operator-owned reverse proxy at the portal origin, or (b) a
  coordinator-side `Access-Control-Allow-Origin` policy?
- **Why:** SPEC-002 / SPEC-005 do not currently document a CORS
  policy for `/providers/{id}/earnings` or `/v1/pool/check`.
- **Who decides:** operator (for (a)) or SPEC-002 author (for (b)).
- **Spec assumes:** option (a) — operator-owned reverse proxy on
  the portal origin; the implementation MUST fail loudly when the
  proxy is missing.
- **Portal renders if unanswered:** (a) is the recommended
  topology; operator deploys nginx accordingly.

### Q10 — Browser-local bridge for the local CLI

- **Question:** What CORS + port-discovery + HTTPS mixed-content
  contract governs the browser reaching `http://localhost:
  <port>/v1/health`?
- **Why:** Surface A.4 current-model card and A.3 model-load row
  need this; SPEC-001 §6.4 has no documented browser-facing
  contract.
- **Who decides:** SPEC-001 author + operator.
- **Spec assumes:** no bridge in v0.1; A.4 + the relevant A.3
  rows are deferred.
- **Portal renders if unanswered:** the deferrals hold; the
  portal never attempts to call localhost.

### Q11 — Notification delivery infrastructure

- **Question:** Which spec governs email / Slack / push / SMS
  delivery to providers?
- **Why:** SPEC-005 §2.11 D11 forbids adding such infrastructure
  inline; surfacing a notification opt-in toggle without it
  would be a contract violation.
- **Who decides:** operator + future notification-spec author.
- **Spec assumes:** no delivery infra in v0.1.
- **Portal renders if unanswered:** no notification toggle
  anywhere; in-portal visual flags (e.g. A.1 offline pill) only.

---

## 10. Dependencies & coupling

### 10.1 Specs SPEC-014 reads from without modifying

| Spec | What SPEC-014 uses |
|---|---|
| SPEC-001 v1.3 | §6.5 hello / hello_ack field set (referenced for Q5 deferral rationale); §6.4 `/v1/health` shape (referenced for A.4 / A.3 deferral rationale). No edits required for v0.1. |
| SPEC-002 v1.3.5 | §7.3 token storage opacity; §7.4 `/v1/pool/check` (the portal's ONLY status/identity endpoint — the `tier` label exposed there originates in §7.5 provisional admission state, but the portal MUST NOT call §7.5's operator-keyed endpoints directly); FR-P12 bearer auth. No edits required for v0.1. |
| SPEC-003 v0.9.2 | §4 / FR-C2 install flow; §5 / FR-D1 + FR-D2 + FR-D2.1 requirements & sizing; §6.2 CLI subcommand table; FR-C7 advisory version nudge; FR-C9 provisional self-mint token path. No edits required for v0.1. |
| SPEC-005 v0.3 | §1.3 out-of-scope; §2.1 D1 donation-only; §2.11 D11 no-new-auth-or-delivery surface; §11.4 `/providers/{id}/earnings`; §11.5 route-disabled mode + 401/403/404 contract; §13 `endpoints.provider_earnings.rate_limit_per_minute`. No edits required for v0.1. |
| SPEC-009 v0.1 | §2 ASCII layout precedent; §6 visual tokens (inherited verbatim). No edits required for v0.1. |
| SPEC-013 v0.3 | §6 / NFR-4 telemetry / privacy egress contract (binds B.2 autotune CTA). No edits required for v0.1. |

### 10.2 Specs SPEC-014 would force amendments to (if Open Qs resolve a certain way)

- **SPEC-002** for D.1 (uptime), D.2 (routing weight), D.3
  (request tail + privacy-redaction policy), A.1 hardware fields,
  E.1 rotation / removal, B.4 broadcasts panel — all under
  Open Q5 + Q6.
- **SPEC-005** for C.3 (earnings breakdown) and C.4 (per-job
  feed) — Open Q4.
- **SPEC-001** for the metrics-shape amendment exposing rate +
  latency histograms on `/v1/health` — Open Q5.
- **SPEC-001** also for the hardware-field schema amendment adding
  Apple model, GPU cores, and serial prefix to the hello payload
  (none of those three are in SPEC-001 §6.5 today; populating the
  SPEC-002 machine-detail surface for those fields requires the
  SPEC-001 side first) — Open Q5.
- **New spec** for the fiat payout rail — Open Q3.
- **New spec** for notification delivery — Open Q11.

### 10.3 Clean-room hygiene (Darkbloom screenshots)

The user shared screenshots from a competitor seller portal
(Darkbloom) when commissioning SPEC-014. Treatment:

- The screenshots are NOT normative. The repo specs are
  normative. Multi-machine status patterns (e.g. "N/M instances
  online" headers, attention chips, monitoring sub-tabs) are
  industry-convergent (AWS EC2 instances, Cloudflare Tunnels,
  Tailscale machines view, GitHub Actions runners) and SPEC-014
  MAY reference them as convergent patterns.
- SPEC-014 MAY use the screenshots as loose visual inspiration
  for panel taxonomy and status pills.
- SPEC-014 MUST NOT copy strings verbatim from Darkbloom. The
  implementing PR MUST NOT inspect any Darkbloom source code at
  any point.
- This stance is documented here per Constraint #6 of the
  originating BUILD prompt.

### 10.4 Operator runbook (mandatory)

- Name the file: `portal-config.json` at the portal host root.
- Name the matching coordinator config key:
  `auth.require_provider_tokens` in `coordinator.yaml`.
- Verification step: before flipping either side, the operator
  diffs `portal-config.json.require_provider_tokens` against the
  coordinator's deploy config; both MUST match.
- Reverse-proxy step (Open Q9 option a): operator nginx config
  proxies the portal origin's `/v1/pool/check` and
  `/providers/{id}/earnings` to the coordinator. Bundle MUST
  fail loudly when the proxy is absent.

---

## 11. Implementation phasing

v0.1 is intentionally narrow. The phasing below sizes each phase
to a single PR; each phase ends with its own IMPL audit gate per
the project's audit-loop rule (memory:
[`feedback-build-audit-loop`]).

### Phase 1A — Scaffolding + auth + deployment-mode + Machine A.1/A.2/A.3

- `frontdoor/provider-portal/` scaffolding (single-file
  `index.html` with inline JS + CSS, no build step, matching
  SPEC-009 §7 AC).
- `portal-config.json` loader (AUTH-3); fail-CLOSED on missing
  or non-200; unavailable-mode page render.
- Sign-in screen (AUTH-1): `provider_id` + `provider_token` paste,
  in-memory only.
- Authenticated request layer: `Authorization: Bearer ...` +
  path `provider_id`; 401 / 403 / 404 handlers per AUTH-2.
- Surface A.1 header strip + manual refresh.
- Surface A.2 counters row.
- Surface A.3 single state-derived attention row + copy-to-
  clipboard CTA.
- IMPL audit gate.

### Phase 1B — Setup & Updates + version feed

- Surface B.1 static requirements grid + B.1a sizing card.
- Surface B.2 numbered setup steps + copy-to-clipboard CTAs.
- Surface B.3 GitHub Releases feed (under Open Q2 assumed repo;
  rate-limit + CORS handling).
- IMPL audit gate.

### Phase 1C — Earn + Monitoring placeholder + Identity + sidebar polish

- Surface C.1 credit totals row.
- Surface C.2 deferred-payout status card.
- Surface D placeholder card (zero API calls).
- Surface E.1 identity card.
- Sidebar nav + sign-out + mobile collapse.
- IMPL audit gate (final pre-PR).

### v0.2

Reopens audit only after the Open Qs land their owning-spec
amendments. v0.2 build phases are out of scope for SPEC-014 v0.1.
