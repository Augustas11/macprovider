# Provider Portal — `frontdoor/provider-portal/`

Single-file web bundle implementing the seller-facing provider portal
per [SPEC-014](../../specs/SPEC-014-provider-portal.md).

## Files

- `index.html` — the entire bundle (inline JS + CSS, no build step, no
  CDN).
- `portal-config.json.example` — copy to `portal-config.json` at the
  portal host root and edit before deploying. The portal fails CLOSED
  if `portal-config.json` is missing or malformed (SPEC-014 §2.3).
- `README.md` — this file.

## Operator setup

1. Copy `portal-config.json.example` to `portal-config.json` at the
   portal host root (served at `/portal-config.json`).
2. Edit the three keys to match your deployment:
   - `coordinator_base_url` — the coordinator origin (e.g.
     `https://coordinator.streamvc.live`).
   - `releases_repo_owner_name` — GitHub `owner/name` slug (must match
     `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`).
   - `require_provider_tokens` — strict boolean `true`. The portal
     refuses to start in any other mode (SPEC-014 §2.4 and §2.3).
3. The loader rejects any unknown top-level key. Do not add extra
   keys (and do not place an operator key in this file — the portal
   would reject the file and refuse to load).

## Same-origin reverse proxy (binding)

The bundle calls `/v1/pool/check` and `/providers/{id}/earnings` on
the SAME origin as the portal. The operator MUST run a reverse proxy
on this origin that forwards those paths to the coordinator. If the
proxy is missing, the portal renders a loud red banner naming
SPEC-014 §3 / Open Q9 and refuses to silently fall back to an absolute
coordinator URL.

## Phase status

- **Phase 1A (this PR):** scaffold, AUTH-3 fail-CLOSED loader, AUTH-1
  sign-in, AUTH-2 401/403/404 identical copy, stale-config guard,
  Surface A (Machine: header strip, counters row, needs-attention).
- **Phase 1B (not yet implemented):** Surface B (Setup & Updates +
  GitHub Releases feed with CORS/rate-limit fail-loud). Sidebar items
  for Setup, Earn, Monitoring, and Identity currently render a
  one-line "Coming in Phase 1B/1C" stub so navigation works end-to-end.
- **Phase 1C (not yet implemented):** Surfaces C/D/E + sidebar polish
  + `check-bundle.sh` build-time grep guard.
