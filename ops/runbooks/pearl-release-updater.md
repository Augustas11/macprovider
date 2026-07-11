# Signed Pearl release updater

The Pearl updater installs coordinator and gateway binaries as one guarded
transaction. It is deliberately disabled after installation and never changes
Tier-2 policy, enables internal provider canaries, or clears provider sanctions.
The authenticated recovery action from PR #538 remains operator-only.

## Release trust contract

Every ordinary `vMAJOR.MINOR.PATCH` GitHub release now contains:

- `coordinator-linux-amd64`, `coordinator-cli-linux-amd64`, and
  `gateway-linux-amd64`;
- `pearl-release.json` with the exact repository, tag, commit, component
  hashes, embedded versions, architecture, and provider version advertised by
  the coordinator configuration;
- detached signatures for `pearl-release.json` and `checksums.txt`.

The protected release workflow first builds a complete unsigned candidate from
the exact fresh `origin/main` tip while the requested tag is absent. After that
unprivileged build succeeds, the operator creates the immutable tag at the
captured commit and the independent `antfleet-ops` reviewer admits the protected
signing job. That job revalidates the source, exact tag, protected environment,
candidate manifest, signed asset set, draft release ID, and immutable
publication before making the release public. A missing tag in the protected
job or a tag on any other commit fails closed; the workflow never creates,
moves, or silently reuses the tag. Once tagged, the captured commit may remain
an ancestor of a newer `origin/main` so unrelated merges during review or
notarization do not burn the immutable release identity.

The updater pins `Augustas11/macprovider` and the existing release-signing
P-256 public key in root-owned files. Neither trust anchor can be selected by
the service environment. It verifies both detached signatures, the signed
metadata checksum, component checksums, ELF amd64 headers, and each daemon's
signed version claim before installation. Downloaded code is never executed
until the signed candidate has passed the revocation, minimum-version, and
downgrade policy gates; only then does the updater execute each daemon's
`--version` and validate the staged effective coordinator configuration. Those
candidate processes run as the dedicated unprivileged
`macprovider-updater-validate` account with no production group membership,
no-new-privileges, closed inherited descriptors, a minimal allowlisted
environment, and private network, PID, mount, IPC, and UTS namespaces. The
static binaries execute in a chroot containing only the verified release pair
and copied effective YAML; host `/etc`, `/opt`, `/var`, and `/proc` are absent.
Verified binaries and copied effective YAML are placed in a root-owned,
validator-group validation tree: directories are `0750`,
binaries are non-writable `0550`, and YAML is non-writable `0640`. The live
root-only configuration is never passed to the dropped-UID process. Only
`env:NAME` values referenced by the effective coordinator
configuration are copied from the live service; unrelated service secrets are
not exposed to candidate code.

An installed release is considered current only when both live binary hashes
and the durable signed tag, commit, version, and component hashes match the
candidate. A same-version binary or state-file mismatch triggers transactional
pair repair instead of a skip.

## One-time installation

First deploy #524's canary buyer exactly as reviewed, including its root-only
`LoadCredential` files. The updater pins that probe, wrapper, service, and
timer as rollout authority `issue-524-r1`; `--plan` fails on any SHA drift,
unexpected unit drop-in, stale systemd fragment, or changed 11-minute canary
budget. The one allowed canary drop-in is the updater's exact root-owned
transaction gate installed below.

Create a separate root-only Better Stack Uptime API credential. This token is
not the canary heartbeat ping URL and should have only the heartbeat read/update
permission needed for the configured resource:

```bash
sudo install -o root -g root -m 0600 /dev/null \
  /etc/macprovider/pearl-updater.betterstack-token
printf '%s\n' "$BETTERSTACK_UPTIME_API_TOKEN" | \
  sudo tee /etc/macprovider/pearl-updater.betterstack-token >/dev/null
```

From a reviewed repository checkout on Pearl, install the updater, set
`PEARL_UPDATER_DEADMAN_HEARTBEAT_ID` to the Better Stack API resource ID, then
plan:

```bash
sudo ops/pearl-updater/install-pearl-updater.sh
sudo /usr/local/sbin/macprovider-pearl-update --plan
```

The installer enables only the conditional boot reconciliation unit; it does
not start or enable the release-apply timer. Review
`/etc/macprovider/pearl-updater.conf`, retain `PEARL_UPDATER_ENABLED=0` during
planning, and populate `/etc/macprovider/pearl-updater.revoked` with any
security-revoked release versions. The revocation file is required even when
empty; absence is a fail-closed policy error. Keep the updater config, revocation file,
and Better Stack API token `root:root 0600`. The installer preserves
`/etc/macprovider` as `root:macprovider 0750`; this is required for the
unprivileged failure sender to traverse the directory and read the existing
`root:macprovider 0640` `monitor.env` without making either path writable.

The independent failure channel reuses the production monitor's hardened
`/etc/macprovider/monitor.env` Gmail settings. All three values must be
non-empty before even `--plan` succeeds. The sender requires the exact
`root:macprovider 0640` file beneath an exact `root:macprovider 0750`
non-symlink directory and upgrades SMTP with Python's verified default TLS
context:

```bash
sudo /usr/local/sbin/macprovider-pearl-updater-alert \
  --check-config macprovider-pearl-updater.service
sudo -u macprovider /usr/local/sbin/macprovider-pearl-updater-alert \
  macprovider-pearl-updater-preflight.service
```

An empty `GMAIL_APP_PASSWORD` means the existing monitor is journal-only and
blocks rollout. Populate the Gmail app password, run both commands, and confirm
the preflight message reached the independent mailbox before continuing.
Reconciliation deliberately does not depend on this credential, so an
interrupted transaction can still roll back if alert delivery configuration is
later lost.

## First production rollout

1. Confirm the candidate release workflow and tests succeeded.
2. Confirm #524's canary units and heartbeat configuration are operational:

```bash
sudo systemctl start canary-buyer.service
systemctl show --property=Result --value canary-buyer.service
sudo test -s /etc/macprovider/canary-buyer.token
sudo test -s /etc/macprovider/canary-buyer.heartbeat
sudo test ! -e /etc/macprovider/canary-buyer.env
systemctl show --property=LoadCredential canary-buyer.service
```

   The result must be `success`; heartbeat delivery failure (exit 3) is a
   rollout failure, not a warning.
3. Confirm every connected provider supports graceful drain/reconnect. Only
   then set `PEARL_UPDATER_ALLOW_PROVIDER_DRAIN=1`.
4. Set `PEARL_UPDATER_ENABLED=1` and keep the config, revocation list, and API
   token `root:root 0600`.
5. Run a plan, then the manual apply:

```bash
sudo /usr/local/sbin/macprovider-pearl-update --plan
sudo /usr/local/sbin/macprovider-pearl-update --apply
journalctl -u macprovider-pearl-updater --since -4h --no-pager
```

Before any snapshot read, the updater creates and fsyncs a root-only phase
journal, reads Better Stack's documented heartbeat
`status` and `paused_at`, PATCHes `paused=true`, and verifies the change with a
fresh GET. It unconditionally stops `canary-buyer.timer` and
`canary-buyer.service`, both archive-rotation units, and both stats billing
mirror units and proves them inactive with no queued systemd job,
derives the exact SQLite paths from the trusted effective running coordinator
and gateway configurations, binds those paths into the durable journal, drains
gateway quota/concurrency reservations from that same captured gateway database
to a steady zero, stops gateway
then coordinator, and proves both inactive. Only after that full writer and
service quiescence does it sequentially snapshot binaries, effective
configuration, current release state, and SQLite databases and fsync the
transaction. Every configured database gets an existence record, including
databases that did not exist before the candidate. A pre-armed snapshot
failure restores the exact captured backend versions, archive/stats units,
canary timer/service, and heartbeat state without touching a live binary,
configuration file, or database. The updater then installs both binaries
with same-filesystem atomic renames. It
starts the coordinator first, verifies local version and advertised provider
version, starts the gateway, waits for a routing-eligible provider to reconnect
and pass warmup, verifies local and public semantic health, and finally runs
`canary-buyer.service` with a 12-minute updater deadline around its verified
11-minute unit budget. The #524 canary's complete SLO and heartbeat result is
the final rollout gate. A client-side timeout explicitly stops and verifies
cancellation of the canary systemd job. The prior timer/service work is
restored after success or rollback, and the heartbeat's exact prior paused
state is restored and verified with a fresh GET before the updater exits.

This API pause is the external maintenance contract: the canary's normal
45-minute dead-man grace is intentionally shorter than a worst-case backend
transaction, so relying on timing alone is forbidden. If the updater cannot
read, pause, verify, or restore the Better Stack state, it fails closed; a
restore failure is reported alongside any rollback failure.

The updater and reconciler deliberately have no outer systemd start/stop
deadline; every network request, subprocess, drain, health wait, and canary
operation has its own explicit finite bound. This prevents systemd from
terminating a valid recovery while retaining bounded failure detection at each
operation. The updater also has a recovery `ExecStopPost`. Before every
external transition or live-file mutation, the
updater fsyncs its next phase to
`/var/lib/macprovider-pearl-updater/active-transaction.json`. If systemd kills
the process, it is OOM-killed, or Pearl reboots, `--reconcile` reads that
journal before acquiring another release: an armed transaction before the
durable success commit point is rolled back; a transaction whose signed release
state was durably committed is reconciled forward by revalidating the installed
pair and rerunning all serving gates. Otherwise the exact captured coordinator,
gateway, archive/stats units, canary
service/timer, and Better Stack state is restored. The journal is deleted only
after recovery is complete. The conditional boot reconciler is ordered before
both backend services, all archive/stats units, both canary units, and the
updater. Each service that can touch a captured database or dependent backend
also has an `ExecStartPre` transaction gate. With an active journal it accepts
only a root-created, single-use permit bound to the journal transaction ID and
current kernel boot ID while the updater/reconciler still holds its exclusive
process lock. Systemd runs only this gate command with the `+` privileged
prefix; each service body still runs as its configured unprivileged or dynamic
identity. This makes a permit orphaned by SIGKILL unusable. It lets the
updater/reconciler start dependencies in
their controlled order without deadlock, while a failed reconciler leaves the
journal in place and blocks independent starts. `OnFailure` invokes a separate unprivileged sender that
delivers a CRITICAL Gmail message using the monitor credential; SMTP failure
is itself a failed alert unit and remains visible in journald.
`RefuseManualStop=yes` still blocks an ordinary manual stop; inspect progress
with `journalctl` instead.

With the shipped defaults, acquisition is bounded above by 17 minutes per asset
(three 5-minute body deadlines plus socket timeouts and backoff). A complete
six-asset release plus latest-release discovery is therefore bounded above by
two hours. Acquisition finishes before the phase journal, maintenance pause,
or any service/file mutation. Once mutation begins, the phase journal and
per-operation deadlines make reconciliation safe without an overriding
systemd watchdog racing a bounded recovery step.

## Automatic rollback

Any install, restart, semantic-health, provider-recovery, public-TLS, or buyer
canary failure first stops the archive/stats units, canary timer/service, and
both daemons and proves them inactive with no queued systemd job. If that proof fails, rollback refuses
to mutate binaries, configuration, state, or SQLite and leaves the canary timer
stopped for operator recovery. Before the first rollback action, the updater
durably sets `rollback_in_progress=true` and `success_persisted=false`. Each
ordered restore phase is journaled separately; reconciliation skips completed
phases and idempotently retries the phase that was pending at a crash. After
successful quiescence it atomically
restores the previous
binaries/configuration, removes SQLite WAL/SHM sidecars, restores integrity-
checked pre-rollout database snapshots, and durably removes any database that
the candidate created when it was absent before rollout. It starts the prior
coordinator and proves its exact captured health version before starting and
proving the prior gateway version; gateway remains stopped if coordinator
restoration fails. Rollback then proves provider reconnect/warmup, gateway
serving state, exact public TLS versions, and the restored advertised provider
version, and unconditionally reruns the #524 canary. The previously active
archive/stats services are restored before their timers, and no timer is
restored until that full serving proof succeeds.
The Better Stack heartbeat is then returned to its exact pre-maintenance paused
state. Transaction snapshots and root-only JSON audit records live under
`/var/lib/macprovider-pearl-updater`.

Manual interrupted-transaction recovery is idempotent:

```bash
sudo systemctl stop canary-buyer.timer canary-buyer.service
sudo /usr/local/sbin/macprovider-pearl-update --reconcile
sudo journalctl -u macprovider-pearl-updater -u 'macprovider-pearl-updater-alert@*' --since -4h --no-pager
```

Do not delete or edit `active-transaction.json`. If reconciliation fails, keep
the canary timer disabled and preserve the named transaction directory for
forensics and a second recovery attempt.

If rollback itself reports a failure, leave the timer disabled and recover from
the named transaction directory before accepting traffic. Do not clear a
provider sanction automatically; inspect `/poolz` and use PR #538's
authenticated provider-scoped recovery only after confirming a false sanction.

## Timer enablement

Enable the timer only after all three production drills have succeeded:

1. a manual successful apply of a protected signed release;
2. a simulated failed rollout that completes rollback and the restored-serving
   canary proof; and
3. an interrupted-transaction drill in which the updater is killed after the
   durable success state is written, followed by reboot or manual `--reconcile`,
   proving commit-forward recovery, dead-man restoration, and journal removal.

Keep the timer disabled throughout the drills. Preserve the transaction journal
for reconciliation; never fabricate or edit it by hand. After the third drill,
confirm both public health endpoints, `/v1/status`, the #524 canary result,
Better Stack state, and absence of `active-transaction.json`, then enable:

```bash
sudo systemctl enable --now macprovider-pearl-updater.timer
systemctl list-timers macprovider-pearl-updater.timer
```

Disable immediately with:

```bash
sudo systemctl disable --now macprovider-pearl-updater.timer
```
