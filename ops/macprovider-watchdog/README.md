# macprovider-watchdog

External LaunchAgent that observes the installed Mac provider process.
It ships alongside every install of `macprovider-cli` via the public
`get.malibu.tech/install.sh` flow.

## What it does

Every 60 seconds, `watchdog.sh` checks that exactly one installed
`macprovider-cli` process is running and that the provider's local
`/v1/health` endpoint responds successfully. `/v1/health` returns
non-2xx for degraded, draining, or unavailable provider states, so a
provider stuck reporting `unavailable` is detected as locally unhealthy
after the watchdog has armed. Before restarting an exact provider process
that still owns the local listener, the watchdog also reads `/v1/status`
and only treats non-paused `status:"unavailable"` as restart-worthy;
operator pause, draining, and degraded states are left untouched.

When the provider has already been observed healthy in the current boot,
the watchdog requests a bounded restart with:

```bash
launchctl kickstart -k gui/$UID/live.malibu.provider
```

It also requests the same restart when launchd has no validated provider
PID for the installed binary. Startup and maintenance lifecycle leases
suppress this path, and `MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS`
defaults the restart cooldown to 300 seconds. Coordinator TCP state is
logged as advisory only; another process reaching the coordinator is not
treated as proof that the provider is healthy.

The watchdog does not own auto-update rollback recovery. If an
auto-update pending marker exists, the watchdog logs that transaction
state and leaves marker, backup, release, plist, watchdog, and Malibu app
bytes untouched for the installer, Malibu repair, or CLI startup/install
recovery owner.

It reads the provider identity from
`~/.config/macprovider/config.yaml` (the file
`macprovider-cli` itself reads) — so it generalizes across every
operator without any hardcoded provider id.

## Files

| File | Purpose |
|---|---|
| `watchdog.sh` | The poll script source (installed as `macprovider-health-monitor`). Idempotent; safe to invoke repeatedly. |
| `live.malibu.provider-watchdog.template.plist` | LaunchAgent template; substituted by `install.sh`. |
| `install.sh` | Idempotent installer. Invoked by both the main `get.malibu.tech/install.sh` flow and by an operator running this directory by hand. |
| `uninstall.sh` | Removes the LaunchAgent and the `~/.local/share/macprovider-watchdog` directory. |

## Operator runbook

### Install (standalone — most operators will not need this)

The watchdog is installed automatically by the main provider
installer. To re-install (or install manually if the operator skipped
it):

```bash
bash ops/macprovider-watchdog/install.sh
```

The install is idempotent: re-running it `bootout`s the previous
LaunchAgent before bootstrapping the new one.

### Inspect

The watchdog logs to `~/Library/Logs/macprovider/watchdog.log` (only
when it detects an issue or observes pending update state; healthy ticks are
silent so the log does not bloat). To see whether the LaunchAgent is
loaded:

```bash
launchctl list | grep live.malibu.provider-watchdog
```

To manually fire a tick out-of-cadence:

```bash
launchctl kickstart -k gui/$UID/live.malibu.provider-watchdog
```

### Uninstall

```bash
bash ops/macprovider-watchdog/uninstall.sh
```

The main provider uninstaller (`phase3-binary/dist/uninstall.sh`)
removes the watchdog too — operators only need this when they want to
remove the watchdog without removing the provider.

## Why this is bounded recovery, not competing runtime ownership

The provider process owns in-process liveness checks, and the main
`live.malibu.provider` LaunchAgent owns routine restarts through
`KeepAlive`. This external LaunchAgent only asks launchd to restart the
provider after a local-health regression that follows a previously
healthy tick, or when launchd has no validated provider PID outside a
valid startup/maintenance lease. Lifecycle leases protect expected
startup/update windows, cooldown prevents restart loops, and launchd
remains the process owner.

## Environment overrides (advanced)

Both `install.sh` and `watchdog.sh` accept env overrides for testing:

| Variable | Default |
|---|---|
| `MACPROVIDER_WATCHDOG_DIR` | `~/.local/share/macprovider-watchdog` |
| `MACPROVIDER_CONFIG_PATH` | `~/.config/macprovider/config.yaml` |
| `MACPROVIDER_LOG_DIR` | `~/Library/Logs/macprovider` |
| `MACPROVIDER_COORDINATOR_HOST` | `coordinator.malibu.tech` |
| `MACPROVIDER_SERVICE_LABEL` | `live.malibu.provider` (installer) |
| `MACPROVIDER_WATCHDOG_LABEL` | `live.malibu.provider` (watchdog target) |
| `MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS` | `300` |
| `MACPROVIDER_LAUNCHCTL` | `launchctl` |

These let an operator point the watchdog at a staging coordinator or
verify the install path before rolling to production.
