# Implementation audit prompt — SPEC-014 Phase 1A (Provider Portal scaffolding + auth + Surface A)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / contract / SPEC-014 review** of Phase 1A on branch
`feat/spec-014-portal-phase-1a`.

Phase 1A delivers:

| Files | Phase | Scope |
|---|---|---|
| `frontdoor/provider-portal/index.html` (NEW) | 1A | Single-file bundle: AUTH-3 loader + AUTH-1 sign-in + AUTH-2 status handling + stale-config guard + Surface A (A.1 header, A.2 counters, A.3 needs-attention) + sidebar shell + stub B/C/D/E + same-origin proxy fail-loud |
| `frontdoor/provider-portal/portal-config.json.example` (NEW) | 1A | Example config (operator copies to `portal-config.json`) |
| `frontdoor/provider-portal/README.md` (extended) | 1A | Operator setup + same-origin proxy contract + phase status |

SPEC-014 v0.8 is LOCKED. Phases 1B and 1C have NOT landed yet — your
scope is exclusively the Phase 1A working-tree state and its
anti-regression impact (none expected; the bundle is a green-field
directory).

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. This is a **read-only review** —
Codex MUST NOT modify any file, commit, push, or modify the git state
in any way. Your only output is the structured findings report.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation audit of Phase 1A of
SPEC-014 v0.8 in the working tree at
`/Users/augstar/macprovider-poc`, on branch
`feat/spec-014-portal-phase-1a`. The bundle is the single file
`frontdoor/provider-portal/index.html` (+ `portal-config.json.example`
and `README.md`).

Phases 1B and 1C have NOT landed. Findings that would only matter
once Surface B / C / D / E is implemented are out of scope unless
Phase 1A has actively painted those phases into a corner.

This is a **read-only review**. You MUST NOT edit any file, commit,
push, or modify the git state in any way. Your only output is the
structured findings report written to
`/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`.

## Context

Phase 1A's BUILD prompt is
`specs/BUILD_SPEC_014_IMPL_PHASE_1A_PROMPT.md`. SPEC-014 v0.8 is
`specs/SPEC-014-provider-portal.md`. The SPEC is LOCKED. Findings
that recommend SPEC edits are out of scope; if Phase 1A contradicts
the SPEC, the SPEC is right — file as MAJOR / CRITICAL accordingly.

## Required reading (in this order — read fully)

1. The Phase 1A working tree (uncommitted, on branch
   `feat/spec-014-portal-phase-1a`):
   - `frontdoor/provider-portal/index.html`
   - `frontdoor/provider-portal/portal-config.json.example`
   - `frontdoor/provider-portal/README.md`

2. The locked SPEC:
   - `specs/SPEC-014-provider-portal.md` end-to-end, especially §2
     (AUTH-1 / AUTH-2 / AUTH-3), §3 (layout + proxy topology + mobile
     breakpoint), §4.1 (Surface A — A.1 / A.2 / A.3 / A.4-not-rendered),
     §5.1 table (a) Phase 1A rows, §5.4 thresholds, §6 visual tokens,
     §7 non-goals, §8(a) Surface-A ACs, §8(b) auth ACs, §8(d) privacy
     ACs, §8(e Q1/Q5/Q7/Q8/Q9/Q10/Q11) ACs, §8(f) single-machine ACs.

3. The BUILD prompt:
   - `specs/BUILD_SPEC_014_IMPL_PHASE_1A_PROMPT.md`. The "Critical
     constraints" 1-14 list is binding. The "Done criteria" list is
     binding. The "Out of scope" list is binding.

4. Upstream SPECs (only the cited sections):
   - `specs/SPEC-002-coordinator.md` §7.4
     (`GET /v1/pool/check?provider_id=<id>`: `tier` enum
     `"pinned"|"provisional"`, `state` enum
     `"ready"|"draining"|"unavailable"|"unknown"`).
   - `specs/SPEC-005-billing.md` §11.4
     (`GET /providers/{id}/earnings` shape:
     `total_credits`, `current_window_credits`,
     `last_payout_ready.{window_start_utc, window_end_utc, provider_credits}`)
     and §11.5 401/403/404 contract.
   - `specs/SPEC-009-console-v2.md` §6 (visual tokens — verbatim
     source) and §2 (220 px sidebar geometry).

5. Local style reference (do NOT copy code; check idiom alignment):
   - `frontdoor/console/index.html` — DOM-helper style + inline CSS
     conventions.

## Severity definitions

- **CRITICAL** — silent SPEC-014 contract violation; a security or
  privacy hole (operator-key leak, token persistence, remote command
  execution, 403/404 discrimination); the bundle fails-OPEN on a
  required fail-CLOSED path; the bundle paints Phase 1B/1C into a
  corner from which a later phase cannot satisfy a §8 AC.

- **HIGH** — a Phase 1A AC explicitly required by SPEC-014 §8 (a/b/c/d/e/f)
  is not satisfied; an AUTH-3 strict-allowlist branch is missing or
  permissive; a Surface A field is wrong (off-by-one, wrong JSON path,
  wrong copy); a §5.4 threshold is wrong by more than ±10%.

- **MEDIUM** — a Phase 1A SPEC-014 clause is partially honored (e.g.
  copy mostly matches but is slightly off; stale-stamp threshold uses
  a different but defensible factor; mobile handling exists but is
  awkward); a §6 token deviates without a recorded reason; a DOM
  hygiene issue (innerHTML for user data) that doesn't materialize
  today but is a latent XSS vector.

- **MINOR** — quality issues that don't block the next phase: prose
  drift, naming inconsistencies, CSS dead rules, code structure that
  would benefit from a small refactor before Phase 1B extends the
  file.

- **QUESTION** — design choices Phase 1A made where the SPEC was
  silent and the operator may prefer a different default. Flag only
  if there's a real ambiguity, not stylistic preference.

## Critical constraints

1. **SPEC-014 v0.8 is LOCKED.** Findings that recommend SPEC edits
   are out of scope unless the implementation is provably correct
   and the SPEC is wrong (in which case file as QUESTION and explain).

2. **Read-only.** Do not modify any file; do not commit; do not
   create branches.

3. **Phase 1A scope.** Do NOT raise findings about missing Surface B
   (GitHub Releases feed), Surface C/D/E, or the `check-bundle.sh`
   grep guard — those are explicitly Phase 1B / 1C deliverables. DO
   raise findings if Phase 1A has already wired a B/C/D/E behavior
   incorrectly.

4. **Strict clean-room on d-inference.** Not relevant here, but
   maintain the rule.

## Audit categories — work through each

### Category A: AUTH-3 deployment-mode loader (§2.3 + §2.4)

A.1  Strict top-level-key allowlist: `coordinator_base_url`,
     `releases_repo_owner_name`, `require_provider_tokens` —
     no other keys accepted. Verify any extra key fails-CLOSED
     with the unknown-key name surfaced in the error.

A.2  `require_provider_tokens === true` ONLY. `false`, `"true"`, `1`,
     `null` all fail-CLOSED. The `false` branch MUST render the
     §2.3 explanation citing SPEC-002 FR-P12 + SPEC-005 §11.5.

A.3  Missing file / network rejection / non-200 → fail-CLOSED
     unavailable page naming the file path. ZERO subsequent
     network calls (no `/v1/pool/check`, no
     `/providers/{id}/earnings`, no GitHub).

A.4  Malformed JSON → fail-CLOSED unavailable page.

A.5  `coordinator_base_url`: non-empty string. Verify other types
     (array, null, number) fail-CLOSED.

A.6  `releases_repo_owner_name`: matches
     `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` (one slash, no scheme).
     Verify failure cases.

A.7  Operator-key isolation: the bundle MUST contain ZERO
     references to `/poolz`, `/admin/blacklist`,
     `/admin/provisional`, `/admin/promote`, `/admin/reject`,
     `/admin/ledger`, or the strings `operator_key` /
     `operator-key`. The loader MUST NEVER read or display an
     operator key, even if present in `portal-config.json` — the
     unknown-key rejection should close this hole.

### Category B: AUTH-1 sign-in + session model (§2.1, §7)

B.1  Two REQUIRED inputs (`provider_id` + `provider_token`). Empty
     submit shows an inline error. Both required strictly.

B.2  Session in JS module scope ONLY. The bundle MUST NEVER call
     `localStorage`, `sessionStorage`, `document.cookie`, or
     `window.indexedDB`. Grep MUST return zero matches.

B.3  Page reload returns to the sign-in screen (no persistence).

B.4  "Sign out" clears the in-memory session, stops pollers,
     returns to sign-in.

B.5  No autofill / `autocomplete` that would persist token in
     browser-managed password manager surfaces (the spec is silent;
     flag as QUESTION if the implementation chose `autocomplete="off"`
     vs `current-password` — the latter has user-experience benefits
     but a slight persistence risk).

### Category C: AUTH-2 status handling + stale-config guard (§2.2, §2.3)

C.1  401 → sign user back out to sign-in with copy that does NOT
     distinguish missing-vs-malformed token.

C.2  403 and 404 → IDENTICAL "sign-in rejected" copy. The user
     MUST NOT be able to tell which status fired. No branching on
     403 vs 404 in user-visible text.

C.3  5xx / other non-2xx → inline error on the earnings card; do
     NOT sign the user out.

C.4  Stale-config guard: counter `authFailBySurface[surface]`
     increments on 401/403/404 to an authenticated provider
     endpoint; resets on success. After TWO consecutive failures
     on the SAME surface in the SAME session, the §2.3 stale-config
     notice MUST be shown on the sign-in screen ADDITIONALLY to
     (not REPLACING) the 403/404-identical copy. Verify the
     transition is exactly at the threshold (≥ 2 prior failures
     before this one, not at the first).

C.5  Operator-key never prompted, parsed, or transmitted. Verify
     by reading the sign-in form fields + every `fetch()` call.

### Category D: Same-origin proxy fail-loud (§3 + Open Q9)

D.1  All calls to `/v1/pool/check` and `/providers/{id}/earnings`
     use SAME-ORIGIN relative paths. No absolute coordinator URL
     fallback anywhere.

D.2  On `fetch()` network rejection (TypeError / DNS / connection
     refused), `state.proxyMissing = true` and a loud red banner
     renders on every surface naming SPEC-014 §3 / Open Q9.

D.3  No silent retry on proxy missing. Verify the bundle does NOT
     try an absolute URL fall-through anywhere.

### Category E: Polling + cache + stale stamp (§5.4)

E.1  `/v1/pool/check` poll cadence is 30 s + manual refresh.

E.2  `/providers/{id}/earnings` poll cadence is 60 s with 60 s
     in-memory cache TTL. Do NOT re-fetch within TTL on surface
     re-render.

E.3  Stale-stamp threshold is 2 × pool cadence (60 s); once
     `now - lastSuccessfulPoolPoll > 2 × 30_000 ms`, stamp flips
     to literal `"stale"` with warning color. Subsequent
     successful poll resets the label to `"Last refreshed Xs ago"`.

E.4  Stamp re-renders every 1 s.

E.5  Pollers stop on sign-out and on auth rejection. Verify no
     leaked `setInterval` after sign-out.

### Category F: Surface A — Machine (§4.1)

F.1  A.1 header strip: `provider_id` (pasted, not from API),
     `tier`, `state`, stale stamp, manual refresh button.

F.2  Online/offline pill: `state ∈ {"ready","draining"}` → Online;
     `state ∈ {"unavailable","unknown"}` → Offline. MUST NOT
     label the pill "heartbeat-current".

F.3  A.1 does NOT show hostname / model / RAM / binary_version
     (all deferred per §5 table (c)).

F.4  A.2 counters row exactly three cards:
     - "Lifetime credits" ← `total_credits` (integer).
     - "Current window" ← `current_window_credits` (integer).
     - "Last payout-ready window" ← `last_payout_ready.provider_credits`
       PLUS `window_start_utc` / `window_end_utc` in footer.
     NO fiat conversion. NO "withdrawable balance" label. NO `$`
     symbol. Display units match wire shape verbatim.

F.5  A.3 needs-attention panel:
     - When `/v1/pool/check.state ∈ {"unavailable","unknown"}`,
       ONE row with LITERAL text
       `"This machine is currently <state>."`
       (state interpolated) + remediation hint
       `"Run macprovider-cli status to inspect local state; if the binary is healthy, re-check in a few seconds."`
       + copy-to-clipboard CTA for `macprovider-cli status`.
     - Otherwise: muted "Nothing to do — this Mac looks healthy."
     - NO other issue types in v0.1 (Update available, Self-signed
       binary, Model load failed all DEFERRED).
     - NO command-execution buttons.

F.6  A.4 is NOT rendered at all.

### Category G: Sidebar shell (§3)

G.1  220 px fixed sidebar.

G.2  Nav items in order: Machine (default), Setup & Updates,
     Earn, Monitoring, Identity.

G.3  Non-Machine surfaces render a one-line `"Coming in Phase 1B"`
     / `"Coming in Phase 1C"` stub. Clicking switches the active
     surface.

G.4  Sidebar footer: external link `https://api.streamvc.live/docs`
     with `target="_blank" rel="noopener noreferrer"`; "Sign out"
     button.

G.5  Mobile breakpoint at 720 px: sidebar collapses behind a
     hamburger OR hides gracefully; scrim overlays the main pane
     when sidebar open on mobile.

### Category H: Non-goals enforced (§7)

H.1  No remote command execution. Every CTA is copy-to-clipboard.
     No POST / PUT / DELETE / PATCH. No XMLHttpRequest. No
     `navigator.sendBeacon`. No WebSocket.

H.2  No autotune banner. Bundle MUST NOT contain
     "your latest autotune recommended" or similar.

H.3  Single-machine hygiene. Bundle MUST NOT contain "your fleet",
     "your machines", "across machines", "all machines",
     "N machines", "N/M", "x3", "machine grid".

H.4  No `localStorage` / `sessionStorage` / `document.cookie` /
     `window.indexedDB`.

H.5  No fiat UX. No `$`, no "withdrawable balance", no payout-now
     CTA.

### Category I: Visual tokens (§6 + SPEC-009 §6 verbatim)

I.1  `:root` CSS variables match SPEC-009 §6 exactly:
     `--bg:#0c0d10; --sb:#111316; --surface:#16181d;
     --border:#252830; --border2:#323743; --text:#e1e3e8;
     --muted:#878d99; --hint:#4a5060; --accent:#7c6af6;
     --accent-dim:rgba(124,106,246,.14); --ok:#22c55e;
     --warn:#f59e0b; --bad:#ef4444; color-scheme:dark;`. No
     deviations.

I.2  Body font:
     `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Inter", sans-serif`.
     Code/labels:
     `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace`.

### Category J: DOM hygiene + bundle hygiene

J.1  `innerHTML` for user-controlled data is FORBIDDEN. Any
     `innerHTML` assignment must be for a trusted static SVG.

J.2  Single file, inline JS + CSS. No `<script src=...>` to any
     CDN. No `<link rel="stylesheet" href=...>` to any CDN.

J.3  No third-party runtime dependency (npm, bundler output,
     external font, external icon). Inline only.

J.4  Bundle parses with NO `console.error` on first paint in the
     unavailable, sign-in, and Surface A flows.

### Category K: Forward-compatibility (does Phase 1A paint Phase 1B/1C into a corner?)

K.1  Phase 1B will add a GitHub Releases feed with CORS / rate-
     limit fail-loud. Phase 1A's `coordFetch()` is same-origin only;
     does the bundle's fetch layer leave room for a third-origin
     `fetch()` to `api.github.com` without confusing the
     `proxyMissing` global?

K.2  Phase 1C will add Surface E (Identity) and a build-time grep
     guard `check-bundle.sh`. Phase 1A's bundle structure should
     not block these.

### Category L: README + example-config quality

L.1  README links SPEC-014, explains the same-origin proxy
     requirement, names the three keys, warns about the strict
     allowlist, names Phase status.

L.2  `portal-config.json.example` content matches the SPEC-014
     example shape verbatim, with one trailing newline.

### Category O: Anything else

Anything the operator should know that doesn't fit A-L.

## Output structure

Write findings to a NEW file:
`/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`.

This is the FIRST implementation audit for SPEC-014. Top-of-file
frontmatter:

```
# SPEC-014 implementation audit — Phase 1A

**Audited:** working tree on branch feat/spec-014-portal-phase-1a (uncommitted)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1A, round 1 of N
**Date:** 2026-06-21
**Total findings:** [N CRITICAL / N HIGH / N MEDIUM / N MINOR / N QUESTION]
**Phase 1A readiness:** [READY TO COMMIT / FIX REQUIRED]

---

## Executive summary

[2-3 paragraphs. Was Phase 1A implemented to the BUILD prompt's
contract and SPEC-014 §2/§3/§4.1/§5.4/§6/§7/§8? Are there blockers
for commit / Phase 1B? Be specific.]
```

Then for each category A-L + O, write a section. For each finding:

```
### A.1  [SHORT TITLE]   [CRITICAL | HIGH | MEDIUM | MINOR | QUESTION]
Location: index.html line N-M (or README.md, or portal-config.json.example)

[What the code does or fails to do. 1-3 sentences.]

[Why it matters. 1-3 sentences.]

[Recommendation. 1-2 sentences. Don't rewrite the code.]
```

If a category has zero findings, write `(no findings)` under the
category header — don't omit the section.

## Out of scope for this audit

- Spec drift / spec content edits (SPEC-014 v0.8 LOCKED).
- Phase 1B work (Surface B, GitHub Releases feed).
- Phase 1C work (Surfaces C/D/E, `check-bundle.sh`).
- d-inference internals (clean-room).
- Operator nginx / DNS / Pearl VPS deployment topology (Open Q7).

=== END PROMPT ===
```
