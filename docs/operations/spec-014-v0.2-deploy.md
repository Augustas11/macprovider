# SPEC-014 v0.2 GitHub Auth Deploy Runbook

This runbook is the operator gate for SPEC-014 v0.2 GitHub auth and terminal-to-browser pairing. Keep both flags off until the Phase 2E gate is green:

- Coordinator env flag: `GITHUB_OAUTH_ENABLED=false`
- Portal config flag: `"github_oauth_enabled": false`

The rollback is a flag flip. The schema additions are forward-compatible and remain unused while the flags are off.

## Pre-deploy Checklist

- Phase 2A coordinator changes are merged on the release branch and their implementation audit has zero critical, high, or medium findings.
- Phase 2B binary claim handoff changes are merged on the release branch and their implementation audit has zero critical, high, or medium findings.
- Phase 2C CLI claim/status changes are merged on the release branch and their implementation audit has zero critical, high, or medium findings.
- Phase 2D provider portal changes are merged on the release branch and their implementation audit has zero critical, high, or medium findings.
- Phase 2E integration gate is green locally and in CI:
  - `bash frontdoor/provider-portal/check-bundle.sh`
  - `make test-integration`
  - GitHub Actions job `spec-014-v0-2-gate`
- No deployment enables GitHub OAuth until the coordinator, binary/CLI, and portal bundle are all shipped.
- Confirm `specs/` has no local diff. SPEC-014 v0.2 is locked.

## Step 1: Deploy Coordinator With Flag Off

Ship the Phase 2A coordinator binary first with GitHub OAuth disabled.

Required coordinator setting:

```bash
GITHUB_OAUTH_ENABLED=false
```

Recommended verification:

```bash
curl -fsS https://<coordinator-host>/healthz
coordinator-cli list-pair-ot-mints --provider-id=test
```

Expected result:

- `/healthz` returns healthy.
- `list-pair-ot-mints --provider-id=test` returns no rows on a fresh deployment.
- `GET /v1/auth/github/start` is not exposed while the flag is off.

Run all coordinator migrations before moving to the next step. The new tables may exist while the feature is off; that is expected.

## Step 2: Deploy Binary And CLI

Ship the Phase 2B and Phase 2C binary/CLI through the normal release channel:

```bash
get.malibu.tech/install.sh
```

Expected behavior with the coordinator flag off:

- Existing installs continue to connect and serve traffic.
- Tokenless admission remains compatible with the prior deployment state.
- `claim_url` handling is inert unless the coordinator sends pairing material.
- `macprovider-cli status` continues to work for existing installs.
- `macprovider-cli claim --no-browser` can refresh pairing material only when the coordinator exposes the pairing endpoint.

Do not tell users to pair yet. The portal flag is still off.

## Step 3: Deploy Portal Bundle With Flag Off

Ship the Phase 2D provider portal bundle to the portal host, for example:

```json
{
  "coordinator_base_url": "https://<coordinator-host>",
  "releases_repo_owner_name": "Augustas11/macprovider",
  "require_provider_tokens": true,
  "github_oauth_enabled": false
}
```

Run the bundle guard before deploy:

```bash
bash frontdoor/provider-portal/check-bundle.sh
```

Expected behavior:

- The legacy v0.1 portal flow remains available.
- A cold load does not call `/v1/auth/*`.
- Any config with a non-boolean `github_oauth_enabled` fails closed.
- Any config with extra keys fails closed.

## Step 4: Provision GitHub OAuth App

Create the GitHub OAuth app before flipping either flag.

GitHub app settings:

- Homepage URL: `https://<portal-host>`
- Authorization callback URL: `https://<coordinator-host>/v1/auth/github/callback`

Coordinator settings required when enabling:

```bash
GITHUB_OAUTH_ENABLED=true
GITHUB_OAUTH_CLIENT_ID=<github-client-id>
GITHUB_OAUTH_CLIENT_SECRET=<github-client-secret>
GITHUB_OAUTH_REDIRECT_URI=https://<coordinator-host>/v1/auth/github/callback
PORTAL_BASE_URL=https://<portal-host>
```

Optional cookie scope:

```bash
MP_SESSION_COOKIE_DOMAIN=<shared-parent-domain>
```

Only set `MP_SESSION_COOKIE_DOMAIN` when the portal and coordinator hosts are intentionally under that domain. The coordinator validates the value against `PORTAL_BASE_URL` and fails closed on mismatch.

## Step 5: Flip The Flags

Flip the coordinator first:

```bash
GITHUB_OAUTH_ENABLED=true
```

Restart the coordinator and verify startup. A missing client ID, client secret, redirect URI, or portal base URL must make the process exit non-zero.

Then flip the portal config:

```json
"github_oauth_enabled": true
```

Redeploy the portal bundle. This is a one-line config change after the Phase 2D bundle is already deployed.

Expected behavior after both flags are true:

- `/claim?ot=<pair_ot>` strips the query string immediately to `/claim`.
- The portal starts GitHub OAuth with `return_to=/claim` and `pair_ot=<pair_ot>`.
- Cookie-authenticated portal requests use `credentials: include`.
- Cookie-authenticated portal requests never send an `Authorization` header.

## Step 6: Smoke-Test Pairing

Use a real Mac install for the smoke test.

1. Start a provider that does not already have an owner.
2. Confirm the binary receives `assigned_provider_token`, `pair_ot`, and `claim_url`.
3. Confirm `~/.config/macprovider/claim_url` exists with mode `0600`.
4. Open the claim URL.
5. Complete GitHub OAuth.
6. Confirm the browser returns to `/claim`, binds the provider, and redirects to `/`.
7. Confirm the dashboard shows exactly the claimed provider.
8. Confirm the binary receives `ownership_event {"event":"bound"}`.
9. Confirm the binary deletes `claim_url` and writes owner status.

Post-smoke checks:

```bash
coordinator-cli list-pair-ot-mints --provider-id=<provider-id>
macprovider-cli status
```

Expected result:

- Mint log includes the pairing event.
- CLI status shows the provider as claimed by the GitHub login.
- Coordinator logs do not contain the raw `pair_ot`.
- Binary output contains the raw `pair_ot` only inside the user-facing `claim_url`.

## Step 7: Declare Gate Passed

Declare the gate passed only after:

- Local `make test-integration` is green.
- Local `bash frontdoor/provider-portal/check-bundle.sh` is green.
- CI job `spec-014-v0-2-gate` is green.
- Phase 2E implementation audit has zero critical, high, or medium findings.
- The smoke test in Step 6 passes against a real Mac install.

Append the decision entry to `beta/DECISION_CRITERIA.md` after the gate passes. The entry should reference this runbook and all five phase audit artifacts.

## Rollback Plan

Rollback is flag-first and does not require a schema rollback.

Coordinator rollback:

```bash
GITHUB_OAUTH_ENABLED=false
```

Restart the coordinator. Expected result:

- `/v1/auth/github/start` returns 404.
- `/v1/auth/me/providers` returns 404.
- `/v1/install/pair/refresh` returns 404.
- Existing provider traffic continues through the pre-v0.2 path.

Portal rollback:

```json
"github_oauth_enabled": false
```

Redeploy the portal config. Expected result:

- A cold portal load makes zero `/v1/auth/*` calls.
- The legacy v0.1 portal experience is restored.

Data rollback:

- Do not drop the SPEC-014 tables.
- `github_identities`, `provider_ownership`, `pair_ots`, `mp_sessions`, `oauth_states`, and `pair_ot_mint_log` are forward-compatible while unused.
- Pairing state naturally expires through the coordinator pruner.

Emergency operator sequence:

1. Flip portal config to false and redeploy.
2. Flip coordinator env to false and restart.
3. Verify GitHub routes return 404.
4. Verify provider traffic and existing dashboards still work.
5. Capture logs and mint rows for postmortem before retrying.

## Known Limitations

- Sign-out is scoped to the provider portal session and is not a global GitHub sign-out.
- The coordinator does not revoke GitHub grants; operators revoke the OAuth app grant from GitHub if needed.
- The `mp_session` cookie is host-only by default unless `MP_SESSION_COOKIE_DOMAIN` is deliberately configured.
- The portal requires a same-origin proxy for `/v1/auth/*` and `/v1/install/pair/refresh` in GitHub mode.
- Pairing one-time tokens are short-lived and burned on bind; users should refresh with `macprovider-cli claim` if a token expires.

## Decision Entry Template

Do not commit this template in the Phase 2E branch commit. The operator appends the final numbered entry to `beta/DECISION_CRITERIA.md` after the gate passes.

```markdown
<next>. SPEC-014 v0.2 GitHub auth and terminal-to-browser pairing gate passed on <date>.
   - Phases shipped: 2A coordinator GitHub OAuth/pairing store; 2B binary claim handoff; 2C CLI claim/status; 2D provider portal GitHub-cookie mode; 2E integration gate, CI, and runbook.
   - Audit rounds: 2A=<n>; 2B=<n>; 2C=<n>; 2D=<n>; 2E=<n>. All closed with 0 critical/high/medium findings.
   - Implementation audit artifacts: <2A artifact>, <2B artifact>, <2C artifact>, <2D artifact>, <2E artifact>.
   - Spec audit artifacts: specs/SPEC-014-v0.2-audit*.md.
   - Runbook: docs/operations/spec-014-v0.2-deploy.md.
```
