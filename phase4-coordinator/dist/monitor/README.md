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
- state: `/var/lib/macprovider-monitor/monitor-state.json` (or the systemd
  `STATE_DIRECTORY` override)

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

Each alert carries a **kind**, which decides whether it is emailed. Journald
receives all of them either way.

| Kind | Alerts | Emailed by default |
| --- | --- | --- |
| `pool` | pool `ready == 0` (CRITICAL) / pool recovered (INFO) | no |
| `provider` | provider → `unavailable` / → `degraded` / dropped from pool (WARN), recovered (INFO) | no |
| `gateway_status` | gateway self-reports `idle` / `degraded` / `down` (WARN) | no |
| `service` | coordinator `/healthz` or gateway `/v1/status` unreachable (CRITICAL), `/poolz` read failed (WARN), recovery (INFO) | **yes** |
| `static_feed` | SPEC-023 autotune feeds (`/v1/autotune-candidates`, `.sig`, `/v1/demand-rank`, `.sig`) unreachable from Pearl (CRITICAL), recovery (INFO) | **yes** |

## Email volume control (`EMAIL_MUTED_KINDS`)

On a small fleet a single Mac going in and out of the pool produces
`provider` + `pool` + `gateway_status` transitions every few minutes — 237
emails in one week on Pearl, none of them operator-actionable. Those three
kinds are therefore **journal-only by default**; the kinds that mean the
Pearl-side services themselves are down still page.

Override in `/etc/macprovider/monitor.env`:

```
EMAIL_MUTED_KINDS=provider,pool,gateway_status   # the default
EMAIL_MUTED_KINDS=all                            # email off entirely
EMAIL_MUTED_KINDS=none                           # email everything (pre-mute behaviour)
```

Unknown kind names are logged and ignored rather than silently changing
routing. Muting affects **delivery only** — muted alerts still count as
alerting transitions for the state machine, and

```sh
journalctl -u macprovider-monitor -S -24h | grep -E '\[(CRITICAL|WARN)\]'
```

remains the complete record.
