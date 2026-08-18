# Provider Portal — `frontdoor/provider-portal/`

Single-file web bundle implementing the seller-facing provider portal
per [SPEC-014](../../specs/SPEC-014-provider-portal.md).

## Files

- `index.html` — the entire bundle (inline JS + CSS, no build step, no
  CDN). Renders all five surfaces (Machine, Setup & Updates, Earn,
  Monitoring placeholder, Identity).
- `portal-config.json.example` — copy to `portal-config.json` at the
  portal host root and edit before deploying. The portal fails CLOSED
  if `portal-config.json` is missing or malformed (SPEC-014 §2.3).
- `check-bundle.sh` — build-time grep guard for AC 8(b) (operator-key
  isolation) + AC 8(f) (single-machine copy hygiene). Exits 0 on
  clean bundle, 1 on prohibited match, 2 if `index.html` is missing.
  CI MUST run this before serving the file (see "CI" below).
- `mining-health.test.mjs` — Node smoke tests for the portal's local
  Mining Health reason-code adapter and unavailable-vs-zero reward
  rendering.
- `README.md` — this file.

## Operator deploy

1. Copy `portal-config.json.example` to `portal-config.json` at the
   portal host root (served at `/portal-config.json`). Edit the three
   keys to match your deployment:
   - `coordinator_base_url` — the coordinator origin (e.g.
     `https://coordinator.malibu.tech`).
   - `releases_repo_owner_name` — GitHub `owner/name` slug (must match
     `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`).
   - `require_provider_tokens` — strict boolean `true`. The portal
     refuses to start in any other mode (SPEC-014 §2.4 and §2.3).
   - `github_oauth_enabled` — strict boolean. Leave `false` for v0.1
     paste-token behavior; set to `true` AFTER deploying a coordinator
     with `GITHUB_OAUTH_ENABLED=true` and the v0.2 schema migrations
     applied. If this is true without coordinator support, the portal
     fails loud per SPEC-014 v0.2 §10.
   The loader rejects any unknown top-level key.
2. Host `index.html` alongside an operator-owned reverse proxy on the
   SAME origin that forwards `/v1/pool/check`,
   `/v1/provider/malibu-accrual`, `/v1/provider/wallet`,
   `/v1/provider/malibu-reward-audit`, and `/providers/{id}/earnings` to the
   coordinator (SPEC-014 §3 + Open Q9). The MALIBU accrual route must
   preserve the provider `Authorization` header and use the buyer-mux
   coordinator port; the wallet and reward-audit routes have the same
   provider-authenticated no-store requirement, as shown in
   `dist/nginx-portal.malibu.tech.conf`.
   For GitHub auth mode, also forward `/v1/auth/github/*`,
   `/v1/auth/me/*`, `/v1/auth/logout`, and
   `/v1/install/pair/refresh`. If the proxy is missing, the portal
   renders a loud red banner naming §3 / Open Q9 and refuses to fall
   back to an absolute coordinator URL.
3. Run `./check-bundle.sh` (locally or in CI) before serving. The
   script exits 0 on a clean bundle.

## CI

CI MUST run `frontdoor/provider-portal/check-bundle.sh` on any PR
that touches files under `frontdoor/provider-portal/`. The repo's
CI hook lives outside this directory and is added in a follow-up
operator step (see SPEC-014 §10.4 operator runbook).
Run `node --test frontdoor/provider-portal/mining-health.test.mjs`
when changing the Earn / Mining Health mapping.

## Mining Health vocabulary

The Earn surface maps current portal projections to the same local
Mining Health reason codes Malibu.app renders from `AgentSnapshot`.
Portal inference is best-effort because the portal does not have
Malibu.app's local lifecycle snapshot. These codes are intentionally
small and backend-ready:

- `earning`
- `idle_no_work`
- `not_running`
- `provider_paused`
- `provider_error`
- `local_on_battery`
- `local_thermal_pressure`
- `local_model_preparing`
- `reward_projection_unavailable`
- `wallet_missing`
- `trust_tier_provisional`
- `provider_daily_cap_held`
- `wallet_daily_cap_held`
- `rewards_held`
- `trusted_withdrawable`
- `eligible_waiting_settlement`
- `customer_availability_pending`

When a future backend eligibility reason model becomes authoritative,
keep this UI map as the adapter boundary and prefer stable backend
codes over local inference.

## Auth model summary

- **AUTH-1 (sign-in):** provider pastes `provider_id` AND
  `provider_token`. Stored in JS module scope only. Page reload returns
  to sign-in. Sign-out clears all session state.
- **AUTH-2 (status handling):** authenticated calls send
  `Authorization: Bearer <provider_token>` and embed `provider_id` in
  the path. 401 → sign back out; 403 and 404 render identical
  "sign-in rejected" copy so the user cannot tell which fired.
  After two consecutive 401/403/404 on the SAME surface in the
  SAME session, the sign-in screen adds a stale-config notice.
- **AUTH-3 (deployment-mode loader):** fail-CLOSED loader for
  `/portal-config.json`. Missing file, non-200, malformed JSON,
  unknown top-level key, non-`true` `require_provider_tokens`, or
  non-boolean `github_oauth_enabled` → unavailable page with zero
  further network calls. When `github_oauth_enabled` is omitted, it
  defaults to `false`.

## Phase status

- **Phase 1A:** scaffold, AUTH-3 loader, AUTH-1 sign-in, AUTH-2
  handling, stale-config guard, Surface A (Machine).
- **Phase 1B:** Surface B (Setup & Updates: requirements grid,
  RAM-to-model sizing card, numbered setup steps, GitHub Releases
  feed with rate-limit + CORS fail-loud).
- **Phase 1C:** Surfaces C (Earn) + D (Monitoring placeholder) +
  E (Identity) + `check-bundle.sh` build-time grep guard.

v0.2 reopens once SPEC-014's Open Qs land their owning-spec
amendments. v0.1 is intentionally narrow.
