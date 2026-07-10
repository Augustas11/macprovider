# Build prompt — SPEC-014 (Provider Portal — seller-facing web surface)

**Prompt version:** v0.12 (post round-11 codex audit; 2 additional findings applied + operator-direct edit: "fleet" jargon stripped in favour of "Mac" / "machine" / "multi-Mac")
**Audit history:**
  - v0.1 → codex round 1 → 2 CRITICAL + 6 HIGH + 5 MEDIUM → all addressed in v0.2.
  - v0.2 → codex round 2 → 0 CRITICAL + 7 HIGH + 3 MEDIUM → all addressed in v0.3.
  - v0.3 → codex round 3 → 0 CRITICAL + 3 HIGH + 4 MEDIUM → all addressed in v0.4.
  - v0.4 → codex round 4 → 0 CRITICAL + 2 HIGH + 4 MEDIUM → all addressed in v0.5.
  - v0.5 → codex round 5 → 0 CRITICAL + 1 HIGH + 3 MEDIUM → all addressed in v0.6.
  - v0.6 → codex round 6 → 0 CRITICAL + 0 HIGH + 3 MEDIUM → all addressed in v0.7.
  - v0.7 → codex round 7 → 0 CRITICAL + 0 HIGH + 3 MEDIUM → all addressed in v0.8.
  - v0.8 → codex round 8 → 0 CRITICAL + 0 HIGH + 5 MEDIUM → all addressed in v0.9.
  - v0.9 → codex round 9 → 0 CRITICAL + 0 HIGH + 2 MEDIUM → all addressed in v0.10.
  - v0.10 → codex round 10 → 0 CRITICAL + 0 HIGH + 2 MEDIUM → all addressed in v0.11.
  - v0.11 → codex round 11 → 0 CRITICAL + 0 HIGH + 2 MEDIUM → all addressed in v0.12.

This document contains the operator-paste prompt to produce
`specs/SPEC-014-provider-portal.md`. The receiving agent **writes the
spec document**; it does not build the system itself.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.
Expected duration: ~3-5 hours of focused writing + one self-audit pass.

After the spec lands, run the standard SPEC audit loop
(`specs/AUDIT_SPEC_014_PROMPT.md` → codex → fix → re-audit, loop until
0 CRITICAL/HIGH/MEDIUM) BEFORE opening a PR. Do not push v0.1 directly.

---

```
=== BEGIN PROMPT ===

You are writing SPEC-014 for the Mac Provider project. Your output is a
single markdown file at
/Users/augstar/macprovider-poc/specs/SPEC-014-provider-portal.md
plus a paired empty scaffold directory at
/Users/augstar/macprovider-poc/frontdoor/provider-portal/
(create the directory; leave a `.gitkeep` and a one-line `README.md`).

You are NOT building anything. You are writing the spec a future session
will implement. You MUST NOT add code under
`frontdoor/provider-portal/` beyond the scaffold above.

## Mandatory pre-write reading

Before drafting a single line, read these files end-to-end. The spec
you write will cite them by section number constantly, and getting the
upstream constraints wrong is the most common round-1 audit failure.

  - specs/SPEC-001-phase3-binary.md      (hello payload schema —
                                          which hardware fields the
                                          binary actually reports;
                                          local /v1/health surface)
  - specs/SPEC-002-coordinator.md        (FR-O2 /poolz operator key,
                                          FR-P12 provider auth tokens
                                          — opaque 32-byte random
                                          stored as SHA-256, no
                                          introspection possible;
                                          §7.3 token store; §7.4
                                          operator endpoints incl.
                                          /admin/blacklist + /poolz
                                          port placement; §7.5
                                          provisional admission
                                          endpoints; heartbeat
                                          config keys)
  - specs/SPEC-003-open-onboarding.md    (install flow §4 / FR-C2;
                                          §5 / FR-D1 Requirements
                                          list (Apple Silicon,
                                          macOS 14+, disk, network);
                                          §5 / FR-D2 RAM-to-model
                                          sizing table; per-Mac
                                          provider_id generation step,
                                          FR-C7 coordinator-advertised
                                          version nudge — NOT enforced,
                                          FR-C9 provisional self-mint
                                          token path)
  - specs/SPEC-005-billing.md            (§1.3 out-of-scope list,
                                          §2.1 D1 donation-only decision,
                                          §11.4 /providers/{id}/earnings
                                          response shape and auth,
                                          §11.5 route-disabled mode)
  - specs/SPEC-009-console-v2.md         (buyer console — visual tokens,
                                          layout, AC checklist style)
  - specs/SPEC-013-cli-autotune.md       (local-only egress contract,
                                          no recipe upload, no telemetry)
  - phase3-binary/README.md              (verify actual headings
                                          before citing — current
                                          top-level sections are
                                          "Join the Network",
                                          "Distribution Files",
                                          "Trust Caveat",
                                          "Provider economics".
                                          There is NO "Requirements"
                                          section in this README;
                                          the normative requirements
                                          list lives in
                                          SPEC-003 §5 / FR-D1
                                          (with RAM-to-model sizing
                                          in §5 / FR-D2). v0.1
                                          MUST NOT cite a README
                                          section that does not
                                          exist.)

When you cite any of these in the SPEC you write, cite the exact
section number (e.g. "SPEC-005 §11.4") so future audit rounds can grep.

## Mission of SPEC-014

The buyer-facing surface already exists:
  • `console.streamvc.live` (frontdoor/console/index.html) — chat,
    dashboard, API key flow. Normative spec: SPEC-009 v0.1.

The seller side has no web surface. A provider today runs
`macprovider-cli serve` in a terminal, watches log lines scroll, and
hits `GET /healthz` if they want a number. There is no:
  - place to see "is my machine being routed traffic right now?",
  - place to see "how much have I earned today / this week / lifetime?",
  - place to see "what model am I serving, at what utilisation?",
  - place to see "is my version out of date, and what changed in the
    new one?",
  - place to see "what does the coordinator think is wrong with my
    machine?" (the operator-facing equivalent of the "Needs attention"
    panel a buyer would never see).

SPEC-014 closes part of that gap for ONE machine at a time. After
SPEC-014 v0.1 ships, a provider can open the portal, sign in with
their per-Mac provider_id + auth token, and see a single-pane view
of THAT machine's coordinator-side status (provider_id, tier,
state) and aggregate earnings. Version-state UI (update pill,
"versions behind" badge, coordinator broadcast panel) is DEFERRED
to v0.2 because the underlying signals are only carried on the
WS handshake and no browser-callable source exists today — see
the version-state deferrals in Surfaces A.1, A.3, and B.4 plus
Open Q5. The bullet list above is the v0.2+ aspiration, not the
v0.1 surface.

This is the seller-side companion to SPEC-009 (buyer console). It
inherits SPEC-009's visual design tokens (§ 6) verbatim — same brand
colour, same typography, same dark surface palette — so a provider who
also tries the buyer console recognises the family.

## v0.1 scope is single-machine, single-provider_id

A `provider_id` is generated per Mac at install time
(SPEC-003 §4 / FR-C2 step 10). One provider auth token
(SPEC-002 FR-P12) gates
one `/providers/{id}/earnings` view (SPEC-005 §11.4 binds subject ==
path provider_id). There is no first-class multi-Mac owner identity
in the existing specs that aggregates multiple `provider_id`s under
one person.

The spec MUST therefore scope v0.1 to a single-machine view. Any
multi-Mac rollup requires a new identity model upstream (in SPEC-002
or a new spec) and is **Open Q1** below. Do NOT write multi-Mac
aggregation UI for v0.1.

This means several multi-machine patterns from the reference
screenshots (an "N/M machines online" header, an "x3 machines" chip
on an attention row, machine grid) MUST be dropped from v0.1 scope.
The spec MUST replace them with single-machine equivalents and call
out this scope cut in §1.2.

## Deployment-mode gating (binding)

SPEC-005 §11.5 disables `GET /providers/{id}/earnings` at the
route layer when `auth.require_provider_tokens = false`. That route
disablement is the binding rationale for portal unavailability —
not "no token exists" (the FR-C9 mint path is actually MOST active
in `false` mode, per SPEC-003 FR-C9.1 / FR-C9.5: tokenless
provisional admission is allowed and tokens get minted on first
connect; when the flag flips to `true`, FR-C9.5 says tokenless
connects are rejected pre-admission instead). When the route is
disabled, the only remaining economics surface is the operator-
keyed `/admin/ledger/providers`, which the portal MUST NOT
expose to a browser. Therefore the portal has no callable data
path in `false` mode.

The spec MUST therefore state, in §1 and §2, that the portal is
available ONLY when the coordinator runs with
`auth.require_provider_tokens = true`. When the coordinator is in
the legacy / route-disabled mode, the portal MUST return a
single-page error explaining the deployment-mode dependency and
linking to the coordinator config it depends on. No portal feature
is conditionally degraded — it is all-on or all-off based on this
flag.

## What the spec MUST cover

Five surfaces in the layout (A Machine, B Setup & Updates, C Earn,
D Monitoring placeholder, E Identity). Surface D ships as a
placeholder card with zero API calls; the live request stream
inside D (originally D.3) is dropped
to v0.2, see "scope cuts" below). Each surface is a tab/view inside
the portal, not a separate page. Every UI data field MUST appear in
exactly one of §5's three field-source tables — endpoint-backed,
static/spec-backed, or deferred (see Constraint #1).

### Surface A — Machine dashboard (default view)

Single-pane status of THIS machine (the one whose provider_id matches
the signed-in token).

  A.1 Header strip
      - Machine identity in v0.1 is restricted to fields that are
        ACTUALLY browser-callable. The SPEC-001 hello fields
        (hostname, model_id, ram_gb, binary_version, etc.) flow
        only over the provider WebSocket and are NOT exposed on
        any browser-callable endpoint today. The only browser-
        callable per-provider endpoint is `GET /v1/pool/check`
        (SPEC-002 §7.4, public/no-auth), and its response shape
        is exactly `{provider_id, tier, state}` — nothing else.
      - v0.1 header therefore shows:
          * `provider_id` (from the pasted session value)
          * `tier` (from /v1/pool/check)
          * `state` ("ready" | "draining" | "unavailable" |
            "unknown" per SPEC-002 §7.4)
          * Live/stale stamp on the /v1/pool/check poll
          * Manual refresh button
      - All other identity/runtime fields (hostname, model_id,
        ram_gb, binary_version, Apple model, GPU cores, serial,
        capacity, attestation, endpoint_url) are DEFERRED behind
        Open Q5 (SPEC-002 amendment for a provider-scoped
        machine-detail read endpoint).
      - Online / offline pill driven by the coordinator's view of the
        provider WS heartbeat
      - "Update available" pill — DEFERRED to v0.2. Both
        ingredients (installed `binary_version` and coordinator's
        advertised `recommended_binary_version`) currently flow
        only through the WS handshake (SPEC-001 §6.5 hello_ack;
        the warning is logged by the binary per SPEC-003 FR-C7);
        neither is exposed on any browser-callable endpoint today.
        v0.1 may show the installed `binary_version` ONLY IF §5
        cites a browser-callable source for it; if no such source
        exists, the whole pill defers behind Open Q5. v0.1 ships
        WITHOUT version-state UI when in doubt.
      - Live/stale indicator with "updated Xs ago" (poll cadence per §5)
      - Manual refresh button

  A.2 Counters row (single machine, 3 cards)
      - Total credits earned (lifetime; in the unit SPEC-005 §11.4
        returns — `total_credits`, integer)
      - Current window credits (`current_window_credits` from the
        same response)
      - Last payout-ready window (start/end UTC and amount from
        `last_payout_ready` in the same response)
      Display units MUST match the on-the-wire shape verbatim. The
      portal MUST NOT invent USD conversions, fiat denominations, or
      "withdrawable balance" — see §1.3 of SPEC-005 (Stripe, fiat,
      and checkout are explicitly out of scope for v1 billing).

  A.3 "Needs attention" panel
      - One row per active issue on THIS machine (no machine count
        chips since v0.1 is single-machine)
      - Issue taxonomy MUST come from existing observable signals
        only. At minimum:
          * Unavailable — `/v1/pool/check.state` returns
            `"unavailable"` or `"unknown"` (SPEC-002 §7.4 — the
            enum is `"ready" | "draining" | "unavailable" |
            "unknown"`). Heartbeat-miss diagnosis ("offline for
            N seconds, threshold M") is DEFERRED to v0.2 because
            /v1/pool/check exposes only the enum, not the
            heartbeat age — defer the rich offline reason behind
            Open Q5 (heartbeat-history endpoint). v0.1 row text
            says only "this machine is currently `<state>`" with
            a generic remediation hint.
          * Update available — DEFERRED to v0.2 alongside the
            A.1 update pill (same data-source gap). Do NOT
            introduce a "below minimum / hard floor" variant —
            SPEC-003 FR-C7 is explicit that the coordinator does
            NOT enforce versions.
          * Self-signed binary — DEFERRED to v0.2. Even if a
            signing-tier signal exists somewhere in SPEC-001's
            hello, the hello frame is not browser-callable today;
            the only browser-callable per-provider STATUS/
            IDENTITY endpoint (`/v1/pool/check`, SPEC-002 §7.4)
            returns only `{provider_id, tier, state}`. (Surface
            C earnings have a separate browser-callable endpoint
            at SPEC-005 §11.4; this constraint is about identity/
            status only.) Defer behind Open Q5 (provider-scoped
            machine-detail endpoint) and Open
            Q10 (browser-local bridge).
          * Model load failed — DEFERRED to v0.2. The only place
            this signal exists today is the local CLI's
            `GET /v1/health` (SPEC-003 FR-C4 (`macprovider-cli status` local-state surface)), which has no
            documented browser-CORS / port-discovery / mixed-
            content contract. See Open Q10 for the browser-local
            bridge.
        Each row MUST have a one-line remediation hint AND a
        copy-to-clipboard `macprovider-cli` invocation. The portal
        MUST NOT execute commands remotely (see §7 non-goals).
        Each row MUST cite the source endpoint+JSON path in §5.

  A.4 Live metrics panel — DEFERRED to v0.2
      - Current loaded model exists in the local CLI status surface
        (SPEC-003 §4 / FR-C4 `macprovider-cli status` / SPEC-001
        §6.4 health endpoint), but has no documented browser-CORS /
        port-discovery / mixed-content contract — see Open Q10.
      - Requests/min, tokens/min, latency p50/p95 are NOT exposed
        on either side today: SPEC-001 §6.4 `/v1/health` carries
        liveness + capacity, not per-window rate or latency
        histograms; SPEC-002 has no provider-scoped read endpoint
        for these. The spec MUST NOT claim "/v1/health" as a source
        for fields it does not return — A.4 needs BOTH a SPEC-002
        amendment (Open Q5) for browser-callable per-provider
        metrics AND a SPEC-001 amendment to expose rate/latency
        histograms at all. The spec MUST file the SPEC-001
        amendment under Open Q5 (which is the omnibus surface-gap
        bucket — its scope already covers "machine detail / status
        / version state" and is the right home for "metrics shape
        the binary should expose").
      - `/poolz` is NOT a valid fallback source: it is operator-
        keyed (SPEC-002 FR-O2 §7.4 — "operator key is not the
        same as provider tokens") and MUST NEVER be exposed to
        browser code.
      - v0.1 ships A.1 + A.2 + A.3 only. The spec MUST not include
        A.4 cards even greyed-out; A.4 lives entirely in §5's
        deferred table.

### Surface B — Setup & updates (with version feed)

Two halves: the static onboarding guide and a dynamic "what's new" feed.

  B.1 Requirements grid (4 cards mirroring SPEC-003 §5 / FR-D1
      exactly: hardware, OS, disk, network)
      - Normative source: SPEC-003 §5 / FR-D1 — the README
        "Requirements" block reproduced verbatim inside FR-D1 is
        the canonical requirements list. The four fields and ONLY
        these four fields are: Apple Silicon Mac (M1+), macOS 14
        (Sonoma) or later, ~4-8 GB free disk space, internet
        connection. The spec MUST mirror this set exactly — do
        not drop "internet connection" and do not promote RAM /
        model sizing into the requirements grid (those are a
        SEPARATE hint, B.1a below).
      - B.1a RAM-to-model sizing hint card (one extra card
        adjacent to the requirements grid, visually distinct).
        Source: SPEC-003 §5 / FR-D2 (and FR-D2.1 for the custom
        model id branch). FR-D2 is a sizing recommendation, not
        a hard requirement; the spec MUST present it that way.
      - All B.1 / B.1a values are STATIC spec-backed — they
        belong in §5 table (b), not (a). The portal MUST render
        them as static strings cited to FR-D1 / FR-D2; no
        runtime API call.
      - SPEC-003 FR-C2 covers install command + side effects only;
        it does NOT define requirements. Do not cite FR-C2 for
        the requirements grid.

  B.2 Setup steps (numbered)
      - Step 1: install via `install.sh` one-liner (SPEC-003 §4 /
        FR-C2); the installer itself handles model selection
        (FR-D2) and optionally offers launchd auto-start (FR-C5).
        `macprovider-cli install` is NOT a real subcommand —
        verify against SPEC-003 §6.2 (`macprovider-cli new
        subcommands`) before citing any CLI verb; `install` is
        not in that table.
      - Step 2: verify routable (`macprovider-cli status` per
        SPEC-003 §4 / FR-C4 — local state; provider tier comes
        from `hello_ack.tier`)
      - Optional step: "consider running `macprovider-cli autotune`
        before serving"
        AUTOTUNE BANNER PROHIBITED. SPEC-013 forbids any non-HF
        egress during autotune (no telemetry, no recipe upload).
        The portal therefore CANNOT render autotune results — there
        is no data path. v0.1 surface is the copy-to-clipboard CTA
        only. The spec MUST cite SPEC-013 §6 / NFR-4
        (telemetry/privacy) when documenting this limit.

  B.3 Version feed (changelog reader)
      - Reverse-chronological list of binary releases.
      - SPEC-003 leaves the releases repository identity open (could
        be `macprovider-poc` or a dedicated releases repo). The spec
        MUST therefore file **Open Q2** for repo owner/name and
        record three things until it is answered:
          * the spec's assumed repo path (the one used in the
            mockup),
          * the unauthenticated GitHub API rate limit (60 req/IP/hr)
            and the implication that browser polling MUST be cached
            and rate-limit-aware,
          * the CORS posture (GitHub Releases API supports CORS for
            public repos; cite the documented behavior).
      - Each entry: version, ship date, expandable release notes
        (markdown rendered from the GitHub release body), and a
        copy-to-clipboard `macprovider-cli update` CTA (no remote
        execution from portal — §7).
      - The "you are N versions behind" badge is DEFERRED to v0.2
        alongside the A.1 update pill and A.3 update row. Installed
        `binary_version` is only carried on the SPEC-001 hello WS
        frame and has no browser-callable source today; see Open
        Q5. The version feed therefore lists releases without per-
        entry "currently installed" comparison in v0.1.

  B.4 Coordinator broadcasts panel — DEFERRED to v0.2
      - The "coordinator-advertised version nudge" (SPEC-003 FR-C7
        / SPEC-001 §6.5 `hello_ack.recommended_binary_version`)
        flows only through the provider WS handshake — there is no
        browser-callable broadcast endpoint today. Defer the panel
        behind Open Q5 (SPEC-002 provider-scoped read endpoint
        amendment).

### Surface C — Earn (credits + payout-ready status)

Mirror of the reference "Earn" tab, grounded in SPEC-005 v1 billing.
**No fiat, no Stripe, no checkout, no card collection** —
SPEC-005 §1.3 lists Stripe and fiat as explicitly out of scope, and
§2.1 D1 says "no Stripe, no checkout, no credit card collection". The
spec MUST mirror that constraint verbatim and treat any UI that
implies imminent fiat payout as a contract violation.

  C.1 Credit totals row (3 cards)
      - `total_credits` (lifetime)
      - `current_window_credits` (in-flight settlement window)
      - Last payout-ready window: start/end + credits
      Source: SPEC-005 §11.4 response (cite the exact JSON keys).

  C.2 Payout-ready status card (no withdrawal UX)
      - Status badge: "Fiat payout rail not yet specified — future
        spec." The spec MUST flag the future payout rail spec as
        **Open Q3** (owner: operator + legal, not the SPEC-014
        author).
      - The card MUST NOT include: a country selector, a "Link bank
        via Stripe" button, an account-type picker, or any other
        flow that implies imminent withdrawal. Those elements are a
        breach of SPEC-005 §1.3.

  C.3 Earnings breakdown (deferred unless source exists)
      - Time bucketing day/week/month, per-model breakdown, and
        per-day bar chart all require fields that
        `GET /providers/{id}/earnings` does NOT currently return
        (the response is aggregate only — see SPEC-005 §11.4
        example).
      - The spec MUST therefore declare these UI elements deferred
        to v0.2 and file **Open Q4** for the SPEC-005 amendment
        that would expose the necessary breakdowns. v0.1 ships only
        the C.1 aggregate cards. Do NOT invent a new endpoint
        inside SPEC-014.

  C.4 Per-job activity feed (deferred for the same reason)
      - SPEC-005 §11.4 returns aggregate credits, not per-row
        `ledger_request_credits` data. Same disposition as C.3:
        deferred to v0.2, covered by Open Q4.

  C.5 API surface
      - Authoritative endpoint: `GET /providers/{id}/earnings`
        (SPEC-005 §11.4). The spec MUST quote the exact response
        shape and cite the section.
      - Auth: FR-P12 provider bearer token, subject == path
        `provider_id` (SPEC-005 §11.5).
      - Deployment-mode dependency: see "Deployment-mode gating"
        above.

### Surface D — Monitoring (placeholder; every sub-card deferred)

Every D-class signal (uptime ribbon, per-provider current routing
weight, live request stream) is unsourced by any browser-callable,
provider-scoped endpoint that exists today. Rather than dropping the
surface entirely, the spec MUST render Surface D as a SINGLE
placeholder card titled "Monitoring — coming after SPEC-002
amendment" that:
  - Names the missing data (uptime history, routing weight, request
    tail), one bullet each.
  - Links each bullet to its Open Q (Q5 for uptime + routing weight,
    Q5 also for request tail privacy policy).
  - Makes ZERO API calls.

Sub-cards once they exist:

  D.1 Uptime ribbon (24h / 7d / 30d) — Open Q5
  D.2 Current routing weight — Open Q5
  D.3 Live request stream — Open Q5 (PLUS a privacy-redaction
      policy decision: which fields the provider may see; what
      redaction applies to buyer prompts/completions/identity/API
      keys/IPs)

ACs MUST verify the placeholder card emits zero network requests
and renders the bullets as static text linked to §9 Open Qs.

### Surface E — Identity (read-only)

Reduced further in round-2: notifications dropped entirely (SPEC-005
§2.11 D11 forbids new email/Slack delivery infra). What ships in v0.1:

  E.1 Identity card (read-only)
      - `provider_id` (from the pasted session value; SPEC-003
        FR-C2 install flow generates it per-Mac into
        `~/.config/macprovider/provider_id`)
      - Provider tier badge (`tier` field from `GET /v1/pool/check`
        — SPEC-002 §7.4 — NOT from `hello_ack.tier`, which is WS
        traffic the browser cannot read)
      - Current state (`state` from /v1/pool/check)
      - Coordinator base URL (from operator-declared
        `portal-config.json.coordinator_base_url`, AUTH-3)
      - All hardware/runtime fields (hostname, model, RAM,
        binary_version) DEFERRED — see A.1 deferral rationale and
        Open Q5.

What is OUT of scope for v0.1 and MUST be deferred:

  - Notifications of any delivery channel (email, Slack, push,
    SMS). SPEC-005 §2.11 D11 explicitly forbids adding email or
    Slack delivery, and the prompt MUST NOT invent delivery
    infrastructure that does not exist. Defer with **Open Q11**
    for a future notification spec. v0.1 may include in-portal
    visual flags (e.g. an "offline" pill on the Machine surface)
    but MUST NOT include opt-in toggles for out-of-portal delivery.
  - Provider auth token rotation. SPEC-002 FR-P12 issues tokens; it
    does NOT today expose a provider-self-service rotation endpoint.
    The portal MUST NOT invent one. Defer with **Open Q6** for the
    SPEC-002 amendment that would add provider-side rotation.
  - "Remove this machine." Machine removal today is operator-only
    via `POST /admin/blacklist` (SPEC-002 §7.4 — operator key
    required; the §7.4 vs §7.5 distinction is binding: §7.4 covers
    `/admin/blacklist` and `/poolz`, §7.5 covers provisional
    admission endpoints). Provider self-service removal would
    require a new auth-gated endpoint AND a SPEC-005 ledger-
    snapshot policy decision (do historical credits remain
    attributable to the removed provider_id?). Defer with
    **Open Q6**.

## Auth & session model (§ 2 of the spec)

Three questions the spec MUST resolve in §2:

  AUTH-1: How does the provider sign in?
    Default recommendation (the spec SHOULD adopt this and justify
    it): paste-in of BOTH `provider_id` AND `provider_token`.
    Rationale:
      - SPEC-002 §7.3 says tokens are opaque 32-byte random
        strings stored as SHA-256 hashes — they carry zero
        introspectable identity. The portal therefore CANNOT
        derive `provider_id` from a token alone.
      - SPEC-005 §11.4 binds `/providers/{provider_id}/earnings` on
        the path `provider_id` with FR-P12 subject equality. The
        portal needs the path component AND the bearer in hand.
      - Provenance of the token is two-path: operator-issued for
        pinned providers (SPEC-002 FR-P12 + `coordinator-cli
        issue-token`), self-minted by the coordinator on first
        admission for provisional providers (SPEC-003 FR-C9.1,
        persisted by the provider per FR-C9.3). Both paths land the
        token in the provider's local config; the portal asks the
        provider to paste it. The spec MUST cite both source paths.
      - Where the provider finds these values: `provider_id` is
        in `~/.config/macprovider/provider_id`
        (SPEC-003 §4 / FR-C2 step 10); `provider_token` is the
        top-level `provider_token:`
        key inside `~/.config/macprovider/config.yaml` (SPEC-003
        FR-C9.3 — atomic top-level YAML key, NOT a separate file;
        the persist routine owns ONLY the top-level key and
        preserves any nested `provider_token:` entries verbatim).
    Storage: in-memory only for v0.1 (no localStorage) so a paste
    is required per session. The spec MUST justify this choice
    against GitHub OAuth, Sign-in-with-Apple, and email magic link,
    and explain why each alternative would require new server work
    (SPEC-005 §2.11 D11 binds "no new auth surface").

  AUTH-2: Trust boundary against impersonation
    The spec MUST confirm explicitly that:
      - Browser sends `Authorization: Bearer <provider_token>` and
        embeds the pasted `provider_id` in the request path.
      - The coordinator's existing FR-P12 middleware is the sole
        authority — no new server-side auth path is added.
      - The portal does NOT have access to any operator key, and
        MUST never attempt to call `/poolz`, `/admin/*`, or any
        operator-keyed endpoint.
      - 403 (subject != path), 401 (missing token), and 404
        (unknown provider_id — SPEC-005 §11.5 explicitly does not
        enumerate valid providers) are handled with prompts that
        do not leak whether the provider_id exists.

  AUTH-3: Operator-declared deployment mode
    Deployment-mode gating is binding (see "Deployment-mode gating"
    above), but SPEC-005 §11.5 ("Provider endpoint authorization")
    does NOT expose a browser-readable "current mode" endpoint.
    The spec MUST therefore treat deployment mode as an
    OPERATOR-DECLARED static value (NOT a "detection" — that word
    would imply a runtime API discovery that the upstream specs do
    not support). v0.1 mechanism:
      - Operator deploys `/portal-config.json` at the portal host
        root, containing `coordinator_base_url`,
        `releases_repo_owner_name` (covers Open Q2), and
        `require_provider_tokens: true|false`.
      - Portal fetches `/portal-config.json` on load. Missing file
        OR HTTP non-200 → fail-CLOSED: render an unavailable-mode
        page that names the missing file path. NEVER fall through
        to a permissive default.
      - `require_provider_tokens: false` → render the unavailable-
        mode page that explains the deployment dependency on
        `auth.require_provider_tokens=true`. Make ZERO API calls.
    Stale-config guard: operator owns the responsibility to keep
    `portal-config.json.require_provider_tokens` in sync with the
    coordinator's actual config. The spec MUST require:
      - A runbook section that names the file, the matching
        coordinator config key, and a verification step
        (e.g. "compare to coordinator deploy config before
        flipping").
      - An AC that asserts: when an API call returns 401/403/404
        in `require_provider_tokens: true` mode, the portal does
        NOT silently fall back; it surfaces an explicit
        "deployment may be misconfigured" error.
    Future runtime discovery (probe-based, or a new SPEC-002 /
    SPEC-005 amendment exposing mode) is deferred behind
    **Open Q8** — recommended action: file in SPEC-002 v-next.

## Layout (§ 3 of the spec)

ASCII layout diagram in the style of SPEC-009 §2 — same sidebar
geometry (220 px), same brand mark, same surface palette. Sidebar
items for v0.1:
  + Machine (default)
  + Setup & Updates
  + Earn
  + Monitoring
  + Identity
  + (spacer)
  + API Docs (external link)
  + Sign out

Right-hand main area renders the active surface. Mobile (< 720 px)
collapses sidebar to hamburger, identical to SPEC-009.

Host string: the spec MAY propose `provider.streamvc.live` for
discussion but MUST flag it as **Open Q7** — Pearl VPS nginx config
and DNS provisioning are operator decisions and out of scope for
SPEC-014. The implementation MUST be host-agnostic (works at any
host the operator provisions).

Browser-to-coordinator topology: the portal makes
`Authorization: Bearer` calls into the coordinator from a different
origin than `coordinator.streamvc.live`. SPEC-002 / SPEC-005 do NOT
document a CORS policy for `/providers/{id}/earnings`. The spec MUST
file **Open Q9** for the topology decision and recommend ONE of:
  (a) Operator-owned reverse proxy at the portal origin that strips
      browser CORS concerns by colocating portal and proxied
      coordinator routes on the same origin (nginx config — operator
      task, parallel with Open Q7).
  (b) New `Access-Control-Allow-Origin` policy on the coordinator
      (SPEC-002 amendment; defer with Open Q9).
The spec MUST recommend (a) for v0.1 because it requires zero
coordinator-side change, and MUST require the implementation to
fail loudly (not silently fall back to alternative origins) if the
expected same-origin proxy is missing.

## Sections the output spec MUST contain (in this order)

  § 1.  Goals, non-goals (§1.1), and explicit scope cuts from
        round-1 audit (§1.2: multi-Mac aggregation, Stripe/fiat,
        autotune banner, live request stream, per-job feed,
        earnings breakdown, token rotation, machine removal)
  § 2.  Auth & session model (resolves AUTH-1, AUTH-2);
        deployment-mode gating reiterated here as binding
  § 3.  Layout + host string (Open Q7)
  § 4.  Surface inventory (A–E, one subsection each)
  § 5.  API contract + field-source tables + thresholds table
        Three tables are mandatory; every UI field in §4 MUST appear
        in exactly one of them:
        (a) Endpoint-backed dynamic fields. Columns: surface ref
            (e.g. A.1), field name, source endpoint, JSON path,
            polling cadence, cache policy, source spec citation
            (real section label, e.g. "SPEC-005 §11.4", NOT a
            line number).
        (b) Static / spec-backed fields (no runtime API call).
            Columns: surface ref, field name, source artifact
            (e.g. "SPEC-003 §4 / FR-C2 install.sh preflight"),
            display mode (rendered markdown | inline copy | etc.).
            Required for: B.1 requirements grid, B.2 setup
            snippets, all `portal-config.json`-sourced values,
            Surface D placeholder bullets.
        (c) Deferred fields. Columns: surface ref, field name,
            why deferred (1 line), owning spec amendment, Open Q
            number. Required for every field the spec drops from
            v0.1.
        Thresholds table (separate from a/b/c): every threshold
        variable mentioned in §4 (offline duration, fault rate,
        etc.) MUST appear with columns: variable name, default
        value, source SPEC-002 config key (or "new — Open Q"),
        owner, override path. No threshold may remain unresolved
        in the spec body — either it has a config-key source or
        it is in the table with a TBD pointing to a specific
        Open Q. JSON-path column is required only for endpoint-
        backed rows.
  § 6.  Visual design tokens — one line: "inherits SPEC-009 §6
        verbatim; deviations enumerated below" — list deviations
        or state "none".
  § 7.  Non-goals for v0.1
        Mandatory non-goals (in addition to §1.2 scope cuts):
          - No remote command execution. The portal renders CTAs
            as copy-to-clipboard shell snippets only.
          - No multi-Mac aggregation (Open Q1).
          - No fiat payout UX of any kind (SPEC-005 §1.3).
          - No anomaly-detection ML — thresholds-only.
          - No mobile-native app — responsive web only.
          - No localStorage of the provider auth token in v0.1.
  § 8.  Acceptance criteria — layered, NOT a flat checklist.
        Required AC groups:
          (a) Per-surface ACs (one group per surface A–E)
          (b) Auth ACs (deployment-mode gating renders unavailable
              page; wrong-subject token → 403 handled gracefully;
              missing token → 401 → login prompt; no operator-key
              call paths exist anywhere in the bundle)
          (c) Field-source ACs — every UI field shown in §4 MUST
              appear as a row in exactly one §5 field-source table
              (endpoint-backed, static/spec-backed, or deferred);
              deferred rows MUST cite the Open Q inside the
              deferred table, not in place of a row. Smoke check
              that bundles ship zero references to `/poolz` or
              `/admin/*`.
          (d) Privacy ACs (no buyer-identifying fields anywhere in
              the portal; explicit list of fields that the portal
              displays from upstream endpoints, with a one-line
              "this is provider-only data" justification per field)
          (e) Open-Q assumption ACs (each Open Q has an "if not
              answered, portal does X" line; AC is "X actually
              happens")
          (f) Single-machine ACs (UI has no concept of "N machines";
              copy uses "this Mac" not "your fleet" / "your
              machines" / pluralised wording)
  § 9.  Open questions
        Mandatory minimum set:
          Q1  Multi-Mac owner identity
          Q2  Releases repo + GitHub API rate limit + CORS posture
          Q3  Fiat payout rail (future spec)
          Q4  SPEC-005 earnings breakdown amendment
          Q5  Upstream-spec amendments omnibus — the "v0.1 needs
              this but the upstream spec does not expose it"
              bucket. Covers (and the Q5 body in §9 MUST list
              every item below verbatim, so a writer cannot cite
              Q5 against a deferred field without an explicit
              owning amendment):
                - SPEC-002 — provider-scoped browser-callable
                  surface for per-machine detail. Specifically:
                  `hostname`, `model_id`, `model_params_b`,
                  `ram_gb`, `max_context_tokens`,
                  `max_concurrency`, `throughput_tps_estimate`,
                  `binary_version`, `attestation`, `endpoint_url`
                  (all the SPEC-001 hello fields that exist but
                  flow only over the provider WS), signing tier,
                  heartbeat history, per-provider routing weight,
                  request tail + privacy redaction policy,
                  coordinator-broadcast relay for the advisory
                  `recommended_binary_version` nudge (SPEC-003
                  FR-C7 — advisory only, NOT a hard floor).
                - SPEC-001 — metrics-shape amendment to expose
                  rate (requests/min, tokens/min) and latency
                  histograms (p50/p95) on the local health
                  endpoint, which §6.4 does not currently return.
          Q6  Provider-side token rotation + self-service removal
          Q7  Portal host string + nginx + DNS
          Q8  Deployment-mode detection mechanism
              (operator config | probe | defer)
          Q9  Browser-to-coordinator CORS / reverse-proxy topology
          Q10 Browser-local bridge for the local CLI
              (`GET /v1/health` CORS + port discovery + HTTPS
              mixed-content)
          Q11 Notification delivery infrastructure (email/Slack/
              push/SMS) — future spec; SPEC-005 §2.11 D11 forbids
              inline
        Each Open Q MUST have: question, why it matters, who
        decides, what the spec assumes in the meantime, what the
        portal renders if the answer is not yet available.
  § 10. Dependencies & coupling
        Explicit list of which existing specs SPEC-014 reads from
        without modifying (SPEC-001, SPEC-002, SPEC-003, SPEC-005,
        SPEC-009, SPEC-013) and which it would force amendments to
        if Open Qs resolve a certain way (SPEC-002 for D.1/D.2 and
        E rotation/removal; SPEC-005 for C.3/C.4 breakdowns; a new
        spec for the fiat payout rail).
        Include the clean-room paragraph (see Constraint #6).
  § 11. Implementation phasing
        Suggest PR-sized build phases. v0.1 is intentionally
        narrow — Phase 1A (scaffolding + auth + deployment-mode
        config + Machine surface A.1/A.2/A.3 only), 1B (Setup &
        Updates + version feed under Open Q2 assumptions),
        1C (Earn aggregate only + read-only Identity card +
        Monitoring placeholder). v0.2 builds (and reopens audit)
        only after the Open Qs land their owning-spec amendments.
        Each phase ends with its own IMPL audit gate per the
        project's audit-loop rule (memory: feedback-build-audit-
        loop).

## Critical constraints

**1. No invention. Every field lands in exactly one §5 table.**
Every UI field shown in §4 MUST live in exactly one of the three
§5 tables:
  (a) endpoint-backed dynamic — needs source endpoint + JSON path
      + source spec section + polling/cache policy;
  (b) static / spec-backed — needs source artifact (spec section,
      README heading, or operator-declared `portal-config.json`
      key) + display mode; no endpoint required;
  (c) deferred — needs why-deferred + owning spec amendment +
      Open Q number; no source required.
Inventing endpoints, JSON shapes, or spec sections inside SPEC-014
is the failure mode the prompt is designed to prevent. A field
that resists categorisation goes in (c) — there is no fourth bucket.

**2. No coordinator-side changes inside SPEC-014.**
The portal is a read-side surface over endpoints that already exist.
Any new endpoint goes through an amendment to its owning spec
(SPEC-002 for coordinator, SPEC-005 for billing) with its own
audit cycle. Naming the amendment as a dependency is fine; writing
its contents is not.

**3. No operator-keyed endpoints from browser code.**
`/poolz` (FR-O2), `/admin/blacklist`, `/admin/provisional`, and
`/admin/ledger/*` are all gated by an operator key that the portal
MUST NEVER see. The spec MUST include an acceptance criterion that
greps the bundle for these paths and fails the build if any appear.

**4. Buyer console design parity.**
Visual design tokens, typography, sidebar geometry, dark-surface
palette: inherit from SPEC-009 §6 verbatim. Any deviation must be
justified in the spec and listed in §6 deviations.

**5. No fiat, no Stripe, no checkout. Period.**
SPEC-005 §1.3 and §2.1 D1 lock this. The spec MUST mirror that
constraint and MUST NOT include any UI element that implies fiat
withdrawal is imminent or available. The future payout rail is
Open Q3.

**6. Clean-room hygiene (Darkbloom screenshots).**
The user shared screenshots from a competitor seller portal
(Darkbloom) when commissioning SPEC-014. Treatment:
  - The screenshots are NOT normative. The repo specs are
    normative. Multi-machine status patterns are industry-
    convergent (AWS EC2 instances, Cloudflare Tunnels, Tailscale
    machines view,
    GitHub Actions runners) and the spec MAY reference them as
    convergent patterns.
  - You MAY use the screenshots as loose visual inspiration for
    panel taxonomy and status pills.
  - You MUST NOT copy strings verbatim. You MUST NOT inspect any
    Darkbloom source code at any point.
  - Document this stance in §10 dependencies & coupling.

**7. The spec is a v0.1 draft and will be re-audited.**
Per repo convention (memory: feedback-spec-audit-loop-before-pr),
this SPEC will go through codex audit → fix → re-audit until 0
CRITICAL/MAJOR/MEDIUM before the PR opens. Write v0.1 to *be
auditable*: every UI field traceable to §5; every threshold in the
thresholds table; every Open Q honest; every citation by section
number.

## Style requirements (mirror existing specs)

  - File header: title line, then `**Version:** 0.1`, then
    `**Status:** Draft (pre round-1 audit)`, then `**Date drafted:**`
    (today, ISO format), then `**Depends on:**` list with versions.
  - Use the SPEC-013 header style verbatim where the fields apply.
  - Tables use the markdown pipe form, not HTML.
  - Code blocks: fenced, no language tag for shell snippets that mix
    prose, `bash` tag for pure shell.
  - Diagrams: ASCII only, no Mermaid (consistent with SPEC-009 §2).
  - Maximum line length: soft 100; hard 120. Reflow long sentences.
  - No emojis. No marketing language. No "we believe", "we think",
    "we feel". Declarative voice.

## Length target

The output SPEC should land at 450–700 lines. SPEC-009 (the closest
analogue) is 178 lines but covers a single-pane app with no auth.
SPEC-014 is broader (five surfaces with Surface D as a placeholder,
auth + deployment-mode gating,
four normative tables in §5 — endpoint-backed, static, deferred,
thresholds — eleven Open Qs, layered ACs) so it will
be 3-4× longer. If you blow past 750 lines, you are probably
restating things the upstream specs already say — strip back and
cite by section number.

## Deliverables

When you are done:

  1. `/Users/augstar/macprovider-poc/specs/SPEC-014-provider-portal.md`
     — the SPEC v0.1 document.

  2. `/Users/augstar/macprovider-poc/frontdoor/provider-portal/`
     — a directory containing exactly two files:
       - `.gitkeep` (empty)
       - `README.md` (one line: pointer to SPEC-014)

  3. A short text summary (paste into your final response, not into
     a file): the eleven Open Questions you ended up filing
     (Q1-Q11; see §9), the
     scope cuts you applied (vs the round-1 draft of this prompt),
     and any places where you had to make a judgement call that an
     operator should sanity-check before audit.

Do not stage, commit, or push anything. The operator will review the
spec, then run the AUDIT_SPEC_014_PROMPT loop, then open the PR.

=== END PROMPT ===
```

---

## Audit fix provenance

### Round 1 (v0.1 → v0.2) — 2 CRITICAL / 6 HIGH / 5 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| Fleet vs per-Mac provider_id | CRITICAL | Single-machine scope + Open Q1 |
| Stripe contradicts SPEC-005 D1/§1.3 | CRITICAL | Surface C rewrite, no withdraw UX, Open Q3 |
| Route-disabled deployment mode | HIGH | Deployment-mode gating section + Auth §2 |
| UI fields not in existing endpoints | HIGH | "No invention. Cite or defer." constraint + §5 endpoint-source table |
| D.3 live tail no defer rule | HIGH | D.3 dropped from v0.1 |
| /poolz operator-keyed | HIGH | Constraint #3 + AC group (c) bundle grep |
| Token rotation / machine removal | HIGH | Surface E reduced + Open Q6 |
| Autotune banner | HIGH | B.2 banner prohibited; CTA-only |
| Threshold variables undefined | MEDIUM | §5 thresholds table requirement |
| GitHub Releases under-specified | MEDIUM | Open Q2 |
| Darkbloom "normative" contradiction | MEDIUM | Constraint #6 reframed |
| ACs too shallow | MEDIUM | §8 layered ACs (6 groups) |
| Line budget too small | MEDIUM | Raised to 450–700 |

### Round 2 (v0.2 → v0.3) — 0 CRITICAL / 7 HIGH / 3 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| Token-only sign-in cannot derive provider_id | HIGH | AUTH-1 requires both provider_id AND token paste; SPEC-002 §7.3 token opacity cited |
| Token provenance contradicts SPEC-003 FR-C9 | HIGH | AUTH-1 cites both paths (FR-P12 pinned + FR-C9 provisional self-mint) |
| Deployment-mode gating has no detection path | HIGH | New AUTH-3 + Open Q8 (operator config / probe / defer) |
| Browser-to-coordinator infra silently assumed | HIGH | Open Q9 + recommend same-origin reverse proxy |
| Monitoring required but every feature deferred | HIGH | Surface D collapsed to single placeholder card, zero API calls |
| Version "hard floor" contradicts SPEC-003 FR-C7 | HIGH | "Update available" is advisory-only; hard-floor language removed everywhere |
| Notifications invent email infra (SPEC-005 D11) | HIGH | E.2 dropped; Open Q11 for future notification spec |
| Mandatory reading omits SPEC-001 | MEDIUM | SPEC-001 added to reading list |
| Local health/metrics assumes browser-local bridge | MEDIUM | A.4 dropped; Open Q10 for CORS/port/HTTPS contract |
| §7.4 vs §7.5 citation wrong for /admin/blacklist | MEDIUM | Corrected to §7.4 with §7.4-vs-§7.5 distinction made binding |

### Round 3 (v0.3 → v0.4) — 0 CRITICAL / 3 HIGH / 4 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| A.1/E.1 required hardware fields not in SPEC-001 hello | HIGH | Both restricted to actual hello fields (provider_id, hostname, model_id, model_params_b, ram_gb, capacity, binary_version, attestation, endpoint_url); Apple-model / GPU cores / serial-prefix dropped from v0.1 |
| Version pill needs browser-callable source (none exists) | HIGH | A.1 update pill + A.3 update row + B.4 broadcast panel all deferred to v0.2 under Open Q5 |
| AUTH-1 cites nonexistent `~/.config/macprovider/provider_token` file | HIGH | Corrected to top-level YAML key in `config.yaml` per SPEC-003 FR-C9.3 |
| AUTH-3 detection-vs-declaration framing + missing stale-config guard | MEDIUM | Renamed to "Operator-declared deployment mode"; fail-CLOSED on missing config; runbook + AC requirements added; future runtime discovery deferred to Open Q8 |
| §5 endpoint-source table over-constrained for static/spec-backed UI | MEDIUM | §5 split into (a) endpoint-backed dynamic / (b) static spec-backed / (c) deferred, plus thresholds table; JSON path required only for (a) |
| Stale "four surfaces" / "seven Open Qs" counts | MEDIUM | All count language synced to 5 surfaces / 11 Open Qs / 4 §5 tables |
| Fake `§<line-number>` citations in prose | MEDIUM | All swapped for real section labels (SPEC-002 §7.3/§7.4, SPEC-003 FR-C4/FR-C9.1/FR-C9.3, SPEC-005 §11.5/§2.11) |

### Round 4 (v0.4 → v0.5) — 0 CRITICAL / 2 HIGH / 4 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| A.1/E.1 hello fields unsourced from browser | HIGH | Identity restricted to {provider_id, tier, state} from `GET /v1/pool/check` (SPEC-002 §7.4); hostname/model/RAM/binary_version all deferred to Open Q5 |
| B.3 "N versions behind" needs installed binary_version (browser-unreachable) | HIGH | Per-entry comparison badge deferred; B.3 lists releases without "currently installed" overlay in v0.1 |
| E.1 tier source cited as hello_ack (WS-only) | MEDIUM | Tier source corrected to `/v1/pool/check` (SPEC-002 §7.4) |
| `phase3-binary/README.md §Requirements` does not exist | MEDIUM | B.1 source switched to SPEC-003 §4 / FR-C2 (install.sh preflight); mandatory-reading note records actual README headings |
| `SPEC-003 §C` is not a real section label | MEDIUM | Replaced everywhere with `SPEC-003 §4 (Functional requirements — Part C) / FR-C2` |
| `SPEC-005 §3` cited as ASCII-diagram precedent (it is "Terms and definitions") | MEDIUM | Removed; SPEC-009 §2 is the sole ASCII-diagram precedent |

### Round 5 (v0.5 → v0.6) — 0 CRITICAL / 1 HIGH / 3 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| A.3 "Self-signed binary" still asks for hello-payload field (not browser-callable) | HIGH | Unconditionally deferred behind Open Q5 + Q10 |
| Q5 used as omnibus but §9 names it only as monitoring | MEDIUM | Q5 reworded as the omnibus SPEC-002 amendment (machine detail / signing tier / version state / heartbeat / routing / broadcast relay / privacy) |
| Constraint #1 ("no invention") contradicts §5 three-table model | MEDIUM | Constraint #1 rewritten to enumerate the three tables; (b) static and (c) deferred explicitly accepted |
| Loose citations (SPEC-003 step 10, SPEC-005 D11, SPEC-013 egress) | MEDIUM | All normalised to `SPEC-003 §4 / FR-C2 step 10`, `SPEC-005 §2.11 D11`, `SPEC-013 §6 / NFR-4` |

### Round 6 (v0.6 → v0.7) — 0 CRITICAL / 0 HIGH / 3 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| Round-5 citation cleanup incomplete (`§C`, `step 10`, `SPEC-003 SPEC-003` typo) | MEDIUM | All three sites fixed; mandatory-reading entry now points at FR-D1 / FR-D2 for the requirements grid |
| B.1 cited wrong SPEC-003 FR (FR-C2 is install, not requirements) | MEDIUM | B.1 source switched to SPEC-003 §5 / FR-D1 (requirements list) + FR-D2 (RAM-to-model sizing); FR-C2 left to install command only |
| Orphan "endpoint-source table" rule remained from pre-v0.6 §5 model | MEDIUM | Rewritten to require exactly-one-of-three §5 tables (matches Constraint #1 wording) |

### Round 7 (v0.7 → v0.8) — 0 CRITICAL / 0 HIGH / 3 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| Mandatory-reading entry still said requirements "live implicit in FR-C2" | MEDIUM | Rewritten to point at SPEC-003 §5 / FR-D1 + FR-D2, consistent with the round-6 B.1 fix |
| AC group (c) said "§5 row OR an Open Q" — let writer skip deferred-table rows | MEDIUM | Tightened to require deferred fields to live IN the deferred table, with the Open Q inside that row |
| A.4 claimed `/v1/health` exposes tokens/min + p50/p95 (it does not) | MEDIUM | Rewritten to separate "current loaded model" (exists; needs browser bridge) from "rates + latency histograms" (need both a SPEC-001 schema amendment AND a SPEC-002 browser-callable endpoint — both filed under Open Q5) |

### Round 8 (v0.8 → v0.9) — 0 CRITICAL / 0 HIGH / 5 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| `macprovider-cli install` does not exist | MEDIUM | B.2 step 1 rewritten — install.sh handles model + launchd; "install" subcommand is fictional and explicitly called out as such |
| B.1 grid swapped "internet" for "RAM" vs FR-D1 | MEDIUM | B.1 reset to FR-D1 exact set (hardware, OS, disk, network); RAM-to-model sizing split into adjacent B.1a card sourced from FR-D2 |
| Q5 description omits the SPEC-001 metrics-shape amendment | MEDIUM | Q5 body expanded to enumerate both SPEC-002 and SPEC-001 amendments |
| Deployment-mode rationale wrong ("no token exists" — SPEC-003 FR-C9 mints regardless) | MEDIUM | Rationale corrected: gating is because SPEC-005 §11.5 disables the route, not because no token exists |
| Mission statement leaked "version state" while every version surface is deferred | MEDIUM | Mission paragraph reframed to v0.1-vs-v0.2 split; bullet list is the v0.2+ aspiration, v0.1 ships status + earnings only |

### Round 9 (v0.9 → v0.10) — 0 CRITICAL / 0 HIGH / 2 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| "Self-mint runs regardless of flag" contradicts SPEC-003 FR-C9.5 | MEDIUM | Rationale corrected — `=false` mode ALLOWS tokenless admission (and thus minting); `=true` mode rejects tokenless pre-admission per FR-C9.5; portal unavailability rationale stays "SPEC-005 §11.5 disables the route" |
| Q5 body omitted hostname/capacity/attestation/endpoint_url though A.1 defers them to Q5 | MEDIUM | Q5 body expanded to enumerate every SPEC-001 hello field by name |

### Round 10 (v0.10 → v0.11) — 0 CRITICAL / 0 HIGH / 2 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| A.3 "Offline + heartbeat-miss threshold" cannot be sourced — /v1/pool/check returns only the state enum | MEDIUM | A.3 offline row narrowed to the state enum (`"unavailable"`/`"unknown"`); rich heartbeat-age diagnosis deferred to Open Q5 |
| Q5 said "version nudge / floor pill" — reintroduced the forbidden hard-floor concept | MEDIUM | "floor pill" stripped; nudge now explicitly cited as advisory-only per SPEC-003 FR-C7 |

### Round 11 (v0.11 → v0.12) — 0 CRITICAL / 0 HIGH / 2 MEDIUM, all applied

| Finding | Severity | Fix |
|---------|----------|-----|
| "Only browser-callable per-provider endpoint" wording contradicts Surface C earnings endpoint | MEDIUM | Narrowed to "only browser-callable per-provider STATUS/IDENTITY endpoint" with explicit pointer to SPEC-005 §11.4 for earnings |
| Exhaustive list of SPEC-003 §6.2 subcommands cited as `{status, update, update --check, uninstall}` was incomplete (also has `serve`, `self-test`) | MEDIUM | Replaced fragile enumeration with "verify against SPEC-003 §6.2 before citing any CLI verb"; only the targeted negative claim ("install is not in that table") retained |

## Audit follow-on

After the spec lands, create `specs/AUDIT_SPEC_014_PROMPT.md` modelled
on `specs/AUDIT_SPEC_013_PROMPT.md` and run the codex audit loop. Do
not open a PR until 0 CRITICAL / 0 MAJOR / 0 MEDIUM findings remain.
See memory note `feedback-spec-audit-loop-before-pr` for the rule.

## Implementation follow-on

Once SPEC-014 v1.0 (or later) is LOCKED, generate phased build prompts
(`BUILD_SPEC_014_v1_0_IMPL_PHASE_1A_PROMPT.md`, etc.) per the spec's
§11 phasing. Each phase ends with its own IMPL audit gate
(`AUDIT_SPEC_014_v1_0_IMPL_PHASE_*_PROMPT.md`) before its PR opens —
the same discipline applied to SPEC-001 / SPEC-002 / SPEC-013.
