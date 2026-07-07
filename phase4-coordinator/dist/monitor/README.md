# macprovider monitor (Phase 7 P2 observability)

Lightweight Pearl-side watcher so automated provider-removal (circuit-breaker
degrade, warm-up-gate failure) and pool-empty / service-down conditions surface
without SSHing into journals. **Zero provider load** — it reads `/healthz`,
`/poolz`, `/v1/status` only; it does NOT send inference. Alerts fire on STATE
TRANSITIONS, not every poll.

## Files
- `macprovider-monitor.py` → `/opt/macprovider/monitor.py`
- `macprovider-monitor.service` + `macprovider-monitor.timer` → `/etc/systemd/system/`
- `/etc/macprovider/monitor.env` (created on deploy; holds optional email creds)
- state: `/var/lib/macprovider/monitor-state.json`

## Deploy
```sh
scp macprovider-monitor.py root@PEARL:/opt/macprovider/monitor.py
scp macprovider-monitor.{service,timer} root@PEARL:/etc/systemd/system/
ssh root@PEARL 'chmod 0755 /opt/macprovider/monitor.py;
  systemctl daemon-reload; systemctl enable --now macprovider-monitor.timer'
```

## Alerts
Always logged to journald (`journalctl -u macprovider-monitor`). Email is sent
additionally when `/etc/macprovider/monitor.env` has Gmail submission creds:

```
ALERT_EMAIL=augstar@gmail.com
GMAIL_USER=augstar@gmail.com
GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx
```

`GMAIL_APP_PASSWORD` is a 16-char Google **app password** (requires 2FA on the
account; generate at myaccount.google.com → Security → App passwords). Port 587
to smtp.gmail.com is open on Pearl. Until the password is filled in, the monitor
runs journal-only.

## What it alerts on (transition-based)
- pool `ready == 0` (idle / no buyer capacity) — CRITICAL
- SPEC-023 static feeds (`/static/autotune-candidates.json`, `.sig`, `/static/demand-rank.json`, `.sig`) unreachable from Pearl — CRITICAL
- a provider → `unavailable` (breaker re-trip / `warmup_failed` / removed) — WARN
- a provider → `degraded` (breaker trip / warm-up hold) — WARN
- a provider dropped from the pool — WARN
- coordinator `/healthz` or gateway `/v1/status` unreachable — CRITICAL
- recoveries — INFO
