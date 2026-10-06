# Pearl coordinator rollout: runtime apply and catalog activation

Read this before any change to the production coordinator on Pearl
(`coordinator.malibu.tech`, `api.malibu.tech`). Every rule below comes from the
2026-10-05/06 v1.8.216 → v1.8.218 rollout, which cost about 50 minutes of buyer
outage across four incidents. Mechanics of the updater itself are in
[`ops/runbooks/pearl-release-updater.md`](../../ops/runbooks/pearl-release-updater.md).

## Hard rules

1. **State the downtime to the operator before every Pearl mutation.** Do it
   before you start, never after. A runtime apply has historically meant
   **15–20 minutes of network down**, unless the short-quiesce updater hotfix
   (below) is installed. A catalog activation means a coordinator restart of
   seconds.
2. **Never cut a runtime release to ship tooling only.** If the coordinator and
   gateway code is identical to what is live, a new runtime apply buys nothing
   and costs a full outage. v1.8.218 took the network down for 19 minutes to
   deliver a deploy-script fix. Prefer fixing the tooling so that it does not
   require the running version to change. If a tag really is required, say so
   and quote the downtime first.
3. **One Pearl actor at a time.** Before writing, check `ListAgents` and the
   release trains for other sessions (#1690 Trusted Pool, CLI promotion). Agree
   on who holds Pearl, and hand it back explicitly when done.
4. **Reproduce against real data before retrying a failed apply.** Every failed
   apply is another outage. The failed transaction's snapshot stays under
   `/var/lib/macprovider-pearl-updater/transactions/<id>-v<ver>/databases/`.
   Inspect that snapshot, not the live DB.

## Preflight (every time)

```bash
ssh pearl 'df -h /; du -sh /var/lib/macprovider-pearl-updater/transactions;
  systemctl list-units --all "mp-update*" --no-legend; pgrep -af "pearl-update|deploy-pearl";
  curl -s https://coordinator.malibu.tech/healthz; readlink /opt/macprovider/autotune/current'
```

- **Disk.** Each runtime apply snapshots every SQLite DB: about 13 GB for
  `coordinator.db` as of 2026-10. Unless the retention hotfix is installed,
  snapshots are never pruned. On 2026-10-06, 117 GB of snapshots had the disk at
  95%. Keep the two newest committed transactions, which are the live rollback
  points. Delete older ones only with the operator's OK. Below
  `billing_compat_floor` they cannot be restored anyway. With the #1749 updater
  installed, each successful apply prunes older `databases/` payloads to
  `PEARL_UPDATER_SNAPSHOT_RETENTION` (default 3). An apply whose signed server
  source is unchanged takes no DB copy (`ops/runbooks/pearl-release-updater.md`,
  Database snapshots).
- **Locks.** `/run/lock/macprovider-pearl-updater.lock` and
  `/opt/macprovider/.coordinator-deploy.lock` must both be free
  (`flock -n <lock> true`).

## Runtime apply (signed updater)

```bash
ssh pearl 'systemd-run --unit=mp-update-<ver> -p Environment=PYTHONDONTWRITEBYTECODE=1 \
  -p "Environment=PATH=/opt/macprovider-tools/sqlite-3.53.2/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -p UMask=0077 -p "ExecStopPost=/usr/local/sbin/macprovider-pearl-update --reconcile" \
  /usr/local/sbin/macprovider-pearl-update --apply --tag v<ver>'
```

- **SQLite version must match the coordinator.** The coordinator embeds
  modernc SQLite (3.53.2 at v1.8.218), while Pearl's system `sqlite3` is 3.45.1.
  The two round `julianday()` of sub-millisecond timestamps differently. So
  `integrity_check` under 3.45 falsely reports `row N missing from index
  idx_srao_drained_retention`, and the apply rolls back. Put the 3.53.2 CLI
  first on `PATH`, as above; it was built from the sqlite.org amalgamation at
  `/opt/macprovider-tools/sqlite-3.53.2/bin`. Never `REINDEX` with the older
  CLI: that corrupts the index for the coordinator's own engine. The #1749
  updater uses that binary by default (`PEARL_UPDATER_SQLITE_BIN` overrides it)
  and needs it, and each of its directories, to be root-owned and not group- or
  world-writable. It runs only `.backup` with traffic down, and checks the copy
  with `quick_check` after commit.
- **Timeouts.** Set `PEARL_UPDATER_SQLITE_SNAPSHOT_TIMEOUT_S=2400` for a DB over
  10 GB. Raise `PEARL_UPDATER_SERVICE_HEALTH_TIMEOUT_S` to 300 only when the
  release runs startup migrations on the money DB. Back up
  `/etc/macprovider/pearl-updater.conf` first, and restore both values
  afterwards.
- **The release must be dispatched on `main`.** The `production-release`
  environment only allows `main`:

  ```bash
  gh workflow run pearl-runtime-release.yml --ref main -f version=v<ver> -f prerelease=true
  ```

  Push the signed tag on `main`'s HEAD first. A weekly scheduled "Renew signed
  release discovery head" run waiting for antfleet-ops approval holds the same
  `production-release` concurrency group and blocks the release until it is
  approved.
- **Check the shared version namespace.** CLI candidates and Pearl runtime
  tags share `1.8.x`. Read the "Consumed identities" row in
  `docs/releases/cli-release-train.md` before picking a tag.
- **Watch for a stuck integrity check.** `ionice -c3` starves under live I/O.
  Use `nice -n 10 ionice -c2 -n7` for diagnostics. Do not use `.backup` on the
  live DB for diagnostics either: it restarts on every write and never
  finishes.

## Catalog activation (full deploy)

The updater cannot activate a catalog: runtime releases carry `catalog: null`.
Activation is `phase4-coordinator/dist/deploy-pearl-vps.sh`, run from a clean
worktree at the **same tag that is running** (`git worktree add --detach
../macprovider-pearl-v<ver> v<ver>`). It restarts the coordinator once, which
takes seconds.

### Before running

1. **nginx.** The live `coordinator.malibu.tech` vhost needs locations for
   every feed the release binds: `/v1/catalog-artifacts(.sig)` and
   `/v1/continuous-batching-policy(.sig)`. Pearl nginx lags the repo, so diff
   the live file and add only the missing blocks. Then run `nginx -t` and
   reload. Never run the **gateway** `deploy-pearl-vps.sh`.
2. **coordinator.yaml autotune keys.** Add them under both locks, after
   `rate_card_sig_path`. The deploy preflight aborts if the pair does not match
   the release binding:

   ```yaml
     catalog_artifacts_path: /opt/macprovider/autotune/current/autotune-artifacts.json
     catalog_artifacts_sig_path: /opt/macprovider/autotune/current/autotune-artifacts.json.sig
     continuous_batching_policy_path: /opt/macprovider/autotune/current/continuous-batching-policy.json
     continuous_batching_policy_sig_path: /opt/macprovider/autotune/current/continuous-batching-policy.json.sig
   ```

   The file name is **`autotune-artifacts.json`**, not `catalog-artifacts.json`.
   Back up the pre-key YAML first.
3. **The live release must pass the new verifier.** Since #1803,
   `catalog-release.py verify-directory` requires
   `continuous-batching-policy.json` in every release, including the live one.
   A 09-25-era live directory installed before #1803 lacks it. Repair it from
   `b55463f6f`: copy `continuous-batching-policy.json`, its `.sig`, and the
   amended 09-25 `release.json` into the live release directory. Before
   touching live, verify a copy with the deploy's own `verify-directory`.

### Run, with an automatic restore

If the deploy rolls back after activation, `current` returns to the old release
while `coordinator.yaml` still names `autotune-artifacts.json`. The coordinator
then **crash-loops on the missing file**; this caused a 502 outage on
2026-10-06 01:16Z. Always chain the restore:

```bash
FORCE_RESTART=1 CONFIG_MODE=preserve-live \
  CATALOG_CANARY_PROVIDER_ID=<canary-provider-id> \
  CATALOG_CANARY_SSH_TARGET=<canary-ssh-target> \
  bash phase4-coordinator/dist/deploy-pearl-vps.sh \
  || ssh pearl 'readlink /opt/macprovider/autotune/current | grep -q <new-release> ||
       { cp -a <pre-key-backup> /opt/macprovider/coordinator.yaml;
         curl -sf http://127.0.0.1:8443/healthz || systemctl restart macprovider-coordinator; }'
```

- **Deploy-script fix.** Deploy scripts older than v1.8.218 (#1860) can never
  pass the post-restart smoke for an artifact-bound release, because they do
  not fetch `/v1/catalog-artifacts`. Use v1.8.218 or later tooling.
- **Canary (this caused three rollbacks on 2026-10-06).**
  - **Why it fails without a restart.** A 1.8.207 provider freezes the catalog
    reported by its local `/v1/status` at process start (HTTPServer
    `catalogStatus`). A `hello_ack` only stages the new envelope for the next
    hello, and is rate-limited to one refresh per 300 s. So the deploy's 180 s
    canary proof can never see the new release unless the canary process
    restarts.
  - **What to do.** As soon as public `/v1/autotune-release` reports the new
    `release_id`, run
    `launchctl kickstart -k gui/$(id -u)/live.malibu.provider` on the canary
    Mac.
  - **Verify and retry.** Then check
    `curl -s http://127.0.0.1:<status-port>/v1/status`. The `catalog.release_id`
    must be the new release with `buyer_serving` and `connected: true`. If it
    came up on the old release, kickstart it again right away. The first
    kickstart at 04:01:25 still loaded 09-25; the second, at 04:04:30, passed.
  - **Credentials.** The canary also needs its ssh key and the Keychain token
    operator token (from the operator's local secret store).
  - **Durable fix.** Have `deploy-pearl-vps.sh` kickstart the canary itself
    after the feed-identity proof (#1749).
- **A failed activation strands the fleet.** Providers that adopted the new
  catalog are rejected (`catalog_incompatible`) by the rolled-back coordinator.
  Each one waits out its own 300 s refresh gate, so capacity took 3–11 minutes
  to return. Get the canary right; do not "just retry".
- **Edit `coordinator.yaml` in place only.** Other sessions edit the same file
  (`compatibility_set.accepted_ids`, `trusted_pools`). Add and remove only your
  own keys, under both locks. Never restore a whole-file backup: on 2026-10-06
  that wiped another session's 1.8.217 accept.
- **stats-inventory-sync timer.** The "left stopped" message refers to the
  timer, which has been disabled since 2026-09-30. Leave it as it was.

## After any Pearl change

- Health and version:

  ```bash
  curl -s https://coordinator.malibu.tech/healthz
  curl -s https://api.malibu.tech/healthz
  ```

- Catalog: `/catalog/current` and `/v1/autotune-release` must show the intended
  release.
- Rate card: unchanged unless intended.
- Providers: `pool_ready` should recover within a few minutes.
- Restore any temporary updater-config values.
- Record the outcome in `docs/releases/coordinator-release-train.md`, including
  the exact downtime.
- Hand Pearl back to any waiting session, with the final `coordinator.yaml`
  autotune keys.
