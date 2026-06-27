# macprovider-watchdog

External LaunchAgent that detects the "silent disconnection" failure mode
in `macprovider-cli` and forces a fresh process via `launchctl kickstart -k`.

## What it fixes

Observed on `augustass-macbook-air` 2026-06-25 → 2026-06-27 (~42 hours):

- `macprovider-cli` process alive, listening on `127.0.0.1:18080` for local
  inference.
- `lsof -p <pid>` showed **no outbound TCP socket** to coordinator — the
  WebSocket connection was dead.
- `Library/Logs/macprovider/macprovider.out.log` had no entries between
  `2026-06-25 13:17` and the next manual restart, despite the heartbeat
  task being scheduled every ~5s.
- Coordinator stopped routing traffic after the 90s inactive-threshold
  fired; live `/v1/models` reported `provider_count: 0` for this Mac's
  model; operator had no signal until buyers started seeing 502s.

The Swift WS reconnect loop in `phase3-binary` v1.6.1 SHOULD recover
from this — the heartbeat task closes the WS on send failure, and
`runReconnectLoop` exponentially backs off and retries. In practice it
did not, for a duration measured in days. Root cause requires a repro
(suspected: Swift cooperative-task starvation under macOS App Nap /
power management, but unconfirmed).

This watchdog is the **operator-visibility / external recovery** layer.
It does not replace the Swift-side fix; it makes the failure mode
non-silent until that fix lands.

## How it works

Every 60 seconds (LaunchAgent `StartInterval: 60`):

1. Find the `macprovider-cli` PID by argv pattern.
2. If absent, do nothing — launchd `KeepAlive` will respawn on its own.
3. If present, count outbound `ESTABLISHED` TCP sockets on port 443.
   The provider opens exactly one (the WS to `coordinator.streamvc.live`).
4. Count `== 0` → log SILENT DISCONNECT, run
   `launchctl kickstart -k gui/$(id -u)/live.streamvc.macprovider`.
5. Wait 8s, verify a new PID exists.

Fallback path on kickstart failure: `launchctl bootout` + `bootstrap`
the agent. Anything that still fails is logged for the operator.

## Install

```
cd ops/macprovider-watchdog
./install.sh
```

`install.sh`:
- copies the plist to `~/Library/LaunchAgents/`
- boots out any previously-loaded version (so plist edits take effect)
- `launchctl bootstrap`s it into the user GUI domain
- kicks it once so `RunAtLoad` fires immediately

## Inspect

```
# launchctl knows about it
launchctl list | grep macprovider-watchdog

# tail the log
tail -F ~/Library/Logs/macprovider/watchdog.log

# probe what the watchdog probes
PID=$(pgrep -f "macprovider-cli.*augustass-macbook-air" | head -1)
lsof -p "$PID" -nP -iTCP -sTCP:ESTABLISHED | awk 'NR>1 && /->.+:443/'
```

## Uninstall

```
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist
rm ~/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist
```

## Open question (fleet-wide)

This script is local to `augustass-macbook-air` because the process
matcher is hardcoded to that provider id. Generalizing requires:

1. Read provider id from `~/.config/macprovider/config.yaml`.
2. Ship the watchdog as part of the provider installer
   (`get.streamvc.live/install.sh`), not the harness worktree.
3. Decide whether the watchdog also pings the gateway's `/v1/models`
   periodically to cross-check that coordinator sees this provider as
   `ready` (catches the case where the WS is established but the
   provider has been silently dropped from the ready pool).

Tracked for a follow-up engineering pass; this watchdog is the minimum
viable mitigation for the current internal e2e testing window.
