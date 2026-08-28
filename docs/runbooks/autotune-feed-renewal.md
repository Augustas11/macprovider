# Autotune Static Feed Renewal (freshness re-stamp)

The coordinator's signed SPEC-023 autotune feed carries a **30-day freshness
horizon** enforced client-side: `AutotuneRecommend.swift` `loadSignedStatic`
fails closed when `now - generated_at > 30*24*3600`, which sets
`rateCardUpdateRequired` / `candidateCatalogUpdateRequired` and aborts the
provider daemon **before it connects** (`runModelCatalogPreflight`). The gate
runs only at daemon start / join, so a stale feed silently arms and providers
drop one-by-one as they restart or the coordinator cycles them. This is an
ops-renewal gap, not a design flaw — the guard on month-old signed pricing data
is correct.

**The fix is to re-date + re-sign the feed on a schedule.** Since #1268 the
coordinator hot-reloads the feed on `SIGHUP` (`reloadCoordinatorConfig` swaps
the WS admission catalog and the buyer-served `/v1/*` bytes atomically,
fail-closed), so renewal is now **zero-disruption**: no coordinator restart,
every provider WebSocket stays connected.

## Security model — signing stays off the production host

The Ed25519 feed-signing key (`streamvc-autotune-static-v4`) is what protects
clients from a compromised coordinator serving forged feeds. It MUST NOT live on
Pearl. `renew-autotune-static-feed.sh` therefore:

- signs locally, on the operator machine where the key lives
  (`~/.config/macprovider/keys/autotune-static-v4.private.base64`, `0600`),
  deriving the public key in memory and comparing it to the committed trusted
  keyring — **never printing private bytes**;
- pushes only signed bytes to Pearl and does the symlink swap + `SIGHUP` over SSH.

A Pearl compromise therefore still cannot mint a validly-signed feed.

## What the script does

`scripts/renew-autotune-static-feed.sh` (default = dry-run, `--deploy` to publish):

1. Builds an **ephemeral git worktree** off `origin/main` so it never dirties
   your checkout (`generate`/`resign` rewrite tracked feed files + the ledger).
2. Re-stamps `version` + `generated_at` on candidate/demand and `generated_at`
   only on rate-card (its `version` is a rows-hash — a freshness renewal must not
   change it). Content is otherwise byte-identical.
3. `catalog-release.py generate` → canonical bytes + manifest + ledger, then
   `resign-autotune-static.sh` signs the three feeds.
4. Assembles the 9-file release dir and gates it with
   `catalog-release.py verify-directory`.
5. **Dry-run stops here.** With `--deploy`:
   - reads the live `current` target,
   - **content-continuity guard**: compares the new feed (dates stripped) against
     the live feed and ABORTS on any model/gate/rate-card-row difference — a real
     catalog change must go through a reviewed release, never this cron;
   - rsyncs the signed dir into `releases/`, records the outgoing release as
     `.previous-target` (so nodes still on it are admitted as `previous`),
     atomically retargets `current`, and `SIGHUP`s the coordinator;
   - verifies the served `/v1/rate-card` `generated_at` refreshed within
     `FRESHNESS_MAX_AGE_SEC` (default 900s); **rolls the symlink back and re-HUPs
     on regression.**

## Manual run

```bash
# From any repo checkout (it uses its own ephemeral worktree):
scripts/renew-autotune-static-feed.sh            # build + verify, no prod contact
scripts/renew-autotune-static-feed.sh --deploy   # publish + hot-reload + verify
```

Env overrides: `PEARL_SSH`, `REMOTE_AUTOTUNE_DIR`, `COORDINATOR_UNIT`,
`COORDINATOR_HEALTH_URL`, `AUTOTUNE_STATIC_KEY_ID`.

Deploy is fail-closed and hardened: it takes an atomic remote lock (no concurrent
publishes), guards against signing-host clock skew, verifies the served
`generated_at` **exactly** equals this run's stamp (not a freshness window), and
on any post-swap regression rolls back **both** `current` and `.previous-target`
and re-HUPs.

## Weekly schedule (operator-local, macOS launchd)

Run weekly — `generated_at` is then never more than ~7 days old, leaving ~23
days of slack, so a missed run (laptop asleep) is safe. Install as a **user
LaunchAgent** on the machine that holds the signing key. This plist is
operator-local (it names local paths + the key); keep it OUT of the repo.

`~/Library/LaunchAgents/live.streamvc.autotune-feed-renewal.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>live.streamvc.autotune-feed-renewal</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$HOME/macprovider-poc" &amp;&amp; scripts/renew-autotune-static-feed.sh --deploy &gt;&gt; "$HOME/Library/Logs/autotune-feed-renewal.log" 2>&amp;1</string>
  </array>
  <!-- Mondays 16:00 UTC-ish; launchd runs once on wake if the machine was asleep. -->
  <key>StartCalendarInterval</key>
  <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>16</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardErrorPath</key><string>/tmp/autotune-feed-renewal.err</string>
  <key>RunAtLoad</key><false/>
</dict></plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/live.streamvc.autotune-feed-renewal.plist
launchctl kickstart -p gui/$(id -u)/live.streamvc.autotune-feed-renewal   # optional: run once now
```

Verify after a run: `curl -s https://coordinator.malibu.tech/v1/rate-card | python3 -c 'import sys,json;print(json.load(sys.stdin)["generated_at"])'`
should show today; provider `pool_size` should be unchanged across the HUP.

## Rollback

The prior release is retained as `.previous-target` and its directory is left in
`releases/`. To revert manually:

```bash
ssh pearl 'cd /opt/macprovider/autotune && ln -sfn "$(cat .previous-target)" .current.rb && mv -Tf .current.rb current && kill -HUP "$(systemctl show -p MainPID --value macprovider-coordinator)"'
```

See also `autotune-feed-30day-freshness-expiry-fleetwide` (incident + manual
procedure this automates).
