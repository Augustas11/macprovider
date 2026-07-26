# macprovider monitor (Phase 7 P2 observability)

Lightweight Pearl-side watcher so automated provider-removal (circuit-breaker
degrade, warm-up-gate failure), pool-empty / service-down conditions, and #535
provider diagnostic failure bursts surface without SSHing into journals. **Zero
provider load** — it reads `/healthz`, `/poolz`, `/admin/providers*`, and
`/v1/status` only; it does NOT send inference. Most alerts fire on STATE
TRANSITIONS; #535 diagnostics use a bounded recent-event window plus per-event
dedupe. Pre-identity `_anonymous` auth failures use episode dedupe so a remote
client cannot force a fresh email on every poll by adding one new bad attempt.

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
| `provider_diagnostics` | repeated recent `invalid_token`, `invalid_auth_request`, `warmup_failed`, `heartbeat_stale`, or reconnect/liveness failures, including pre-identity `_anonymous` auth failures; any `version_unsupported`; optional expected-provider missing-auth window | **yes** |
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

## Provider diagnostics knobs

#535 diagnostics are enabled by default when the monitor has `OPERATOR_KEY` from
`/etc/macprovider/coordinator.env`. They read the operator-only coordinator
admin endpoints and never query Pearl SQLite directly. The poll always includes
the coordinator's capped `_anonymous` bucket so repeated pre-identity
authentication failures page without exposing claimed provider IDs or raw
protocol diagnostics.

Optional `/etc/macprovider/monitor.env` overrides:

```
PROVIDER_DIAGNOSTICS_ENABLED=1
PROVIDER_DIAGNOSTICS_EVENT_LIMIT=50
PROVIDER_DIAGNOSTICS_WINDOW_MINUTES=15
PROVIDER_DIAGNOSTICS_MIN_FAILURES=3
EXPECTED_PROVIDER_IDS=augustass-macbook-air,air5
PROVIDER_EXPECTED_AUTH_WINDOW_MINUTES=30
```

For a small prebeta cohort, leave `EXPECTED_PROVIDER_IDS` empty unless a provider
is supposed to be online for a specific window. Values must use the coordinator
provider-id grammar (`[a-zA-Z0-9_.-]`, 1-64 chars); invalid entries and entries
beyond the 100-item monitor cap are ignored. This avoids paging on normal
sleep/offline behavior while still paging on repeated auth/config/liveness
failures.
