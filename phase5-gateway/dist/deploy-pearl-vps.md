# Phase 5 Pearl Deployment Notes

This is an operator runbook draft. Do not deploy from the build session without an explicit production authorization.

1. Build the gateway binary on the target OS or copy a matching build artifact to `/opt/macprovider/gateway`.
2. Copy `gateway.yaml.example` to `/opt/macprovider/gateway.yaml` and set secrets through `/etc/macprovider/gateway.env`:
   - `COORDINATOR_OPERATOR_KEY`
   - `MACPROVIDER_KEY_HASH_SECRET`
   - `MACPROVIDER_DEMO_SIGNING_SECRET`
   - `GITHUB_OAUTH_CLIENT_ID`
   - `GITHUB_OAUTH_CLIENT_SECRET`
3. Ensure coordinator buyer URL is loopback: `http://127.0.0.1:8443`.
4. Install `dist/macprovider-gateway.service` as `/etc/systemd/system/macprovider-gateway.service`.
5. Install `dist/nginx-api.streamvc.live.conf` as `/etc/nginx/sites-available/api.streamvc.live` and enable it from `sites-enabled`.
6. Run dry checks:
   - `systemd-analyze verify /etc/systemd/system/macprovider-gateway.service`
   - `nginx -t`
   - `/opt/macprovider/gateway --config /opt/macprovider/gateway.yaml --check`
7. Start in this order:
   - `systemctl restart macprovider-coordinator`
   - `systemctl enable --now macprovider-gateway`
   - `systemctl reload nginx`
8. Smoke checks:
   - `curl -i https://api.streamvc.live/v1/status`
   - `curl -i -H "Authorization: Bearer <key>" https://api.streamvc.live/v1/models`
   - OpenAI SDK chat call with `base_url=https://api.streamvc.live/v1`.

Operator endpoints under `/admin/*` are intentionally not exposed by the public `api.streamvc.live` nginx site. Use loopback on the Pearl host or a separate trusted operator channel for kill-switch, feedback summary, and capacity controls.

Rollback:

1. Disable the `api.streamvc.live` nginx site or point `/v1/*` back to the previous target.
2. `systemctl stop macprovider-gateway`.
3. Restore the previous nginx config and `systemctl reload nginx`.
