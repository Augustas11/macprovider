# Phase 5 Pearl Deployment — change-log and rollback runbook

The canonical deploy path is the scripted `deploy-pearl-vps.sh` (added in
M1-6 / DEVE-4). Run it from the operator Mac after building the binary:

```bash
cd phase5-gateway
bash dist/build-linux.sh                # produces dist/gateway-linux-amd64
bash dist/deploy-pearl-vps.sh           # idempotent SSH deploy + nginx + verify
```

`deploy-pearl-vps.sh` is modelled on the coordinator's deploy script:
fail-closed config gate as step 0 (reuses the coordinator's
`check-deploy-config.sh` for C2 timer cross-check), `.prev` binary snapshot
for one-command rollback, version-stamped provenance check on `/healthz`.

This `.md` is no longer the primary deploy procedure — it now serves as
the change-log / rollback runbook the script's comments cross-reference.

## Bootstrap prerequisites (do once, not on every deploy)

`deploy-pearl-vps.sh` assumes these are already in place on Pearl:

- The `macprovider` system user, `/opt/macprovider/`, and Pearl's
  certbot-managed certificate for `api.streamvc.live` — set up alongside the
  coordinator's first deploy (`phase4-coordinator/dist/deploy-pearl-vps.sh`).
- `/etc/macprovider/gateway.env` with:
  - `COORDINATOR_OPERATOR_KEY`
  - `MACPROVIDER_KEY_HASH_SECRET`
  - `MACPROVIDER_DEMO_SIGNING_SECRET`
  - `GITHUB_OAUTH_CLIENT_ID`
  - `GITHUB_OAUTH_CLIENT_SECRET`
- `/opt/macprovider/gateway.yaml` — `coordinator.buyer_url: http://127.0.0.1:8443`,
  `quotas.reaper_interval_hours: 1`, `quotas.reservation_max_age_hours: 24`,
  `quotas.demo_concurrency: 2` (M1-8). `deploy-pearl-vps.sh` does NOT
  overwrite this file.

## Smoke checks after deploy

```bash
curl -i https://api.streamvc.live/healthz       # 200, includes "version"
curl -i https://api.streamvc.live/v1/models     # 401 without auth
curl -i -H "Authorization: Bearer <key>" \
  https://api.streamvc.live/v1/models           # 200 with valid key
```

## Rollback

One command — relies on the `.prev` snapshot the deploy script keeps:

```bash
ssh root@159.223.165.194 '
  install -o macprovider -g macprovider -m 0755 \
    /opt/macprovider/gateway.prev /opt/macprovider/gateway && \
  systemctl restart macprovider-gateway
'
```

If the nginx site changed and that broke the rollout, revert the nginx
config separately:

```bash
ssh root@159.223.165.194 'git -C /etc/nginx/sites-available checkout HEAD~1 api.streamvc.live && nginx -t && systemctl reload nginx'
```

(That requires the operator to have started a git history in
`/etc/nginx/sites-available` — recommended for any host with config files
edited by hand.)

Operator endpoints under `/admin/*` remain intentionally not exposed by
the public `api.streamvc.live` nginx site. Use loopback on the Pearl host
or a separate trusted operator channel for kill-switch, feedback summary,
and capacity controls.
