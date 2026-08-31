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
clients from a compromised coordinator serving forged feeds. It **MUST NOT**
live on Pearl. A Pearl-root signer that mints client-trusted feeds and retargets
`autotune/current` is the same mutation surface as `deploy-pearl-vps.sh`.

Primary always-on signer: GitHub Actions
`.github/workflows/renew-autotune-static-feed-signed.yml` (Wednesday 16:00 UTC,
`environment: production-release`, antfleet-ops approval). The runner signs with
Swift CryptoKit, verifies with a sealed OpenSSL 3 bottle, and rsyncs **only
signed bytes** to Pearl. The private key is a `production-release` secret, never
a file on the coordinator host.

A Pearl compromise therefore still cannot mint a validly-signed feed.

## Operator secrets (not in the repo)

Place these on the `production-release` environment **before the first live
`--deploy`**. Until they exist, the workflow is mergeable but a scheduled run
fails closed on empty secrets. Do **not** commit key material.

| Secret | What it is |
| --- | --- |
| `AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64` | Raw 32-byte Ed25519 seed, same contents as `~/.config/macprovider/keys/autotune-static-v4.private.base64`. Do not reuse the discovery-head release-signing PEM. |
| `PEARL_AUTOTUNE_DEPLOY_SSH_KEY` | OpenSSH private key for `root@159.223.165.194`. Do not reuse the download.malibu.tech upload key (different blast radius). Host key is pinned via `scripts/dist/malibu-download-known_hosts` with `StrictHostKeyChecking=yes`. |

## What the signed job does

`scripts/renew-autotune-static-feed.sh --deploy` (default without `--deploy` is
dry-run):

1. Builds an **ephemeral git worktree**. On Actions, restamps `GITHUB_SHA`
   (the approved workflow commit), not a floating `origin/main`. Locally,
   restamps `origin/main`.
2. Re-stamps `version` + `generated_at` on candidate/demand and `generated_at`
   only on rate-card (its `version` is a rows-hash — a freshness renewal must not
   change it). Content is otherwise byte-identical.
3. `catalog-release.py generate` → canonical bytes + manifest + ledger, then
   `resign-autotune-static.sh` signs the three feeds (Swift). `verify-directory`
   uses `OPENSSL_BIN` when set (CI sealed bottle).
4. Assembles the 9-file release dir and gates it with
   `catalog-release.py verify-directory`.
5. **Dry-run stops here.** With `--deploy`:
   - refuses to run if the signing-host clock is skewed >120s vs Pearl;
   - takes `.renew.lock` (no concurrent autotune publishes);
   - **content-continuity guard**: compares the new feed (dates stripped) against
     the live feed and ABORTS on any model/gate/rate-card-row difference — a real
     catalog change must go through a reviewed release, never this cron;
   - rsyncs the signed dir into `releases/`;
   - holds the same Pearl deploy locks as `deploy-pearl-vps.sh`
     (`/run/lock/macprovider-pearl-updater.lock` then
     `/opt/macprovider/.coordinator-deploy.lock`, non-blocking). Lock files
     are validated first (`scripts/pearl_autotune_deploy_lock.py`: regular
     file, root:root, `0600`, nlink 1, `O_NOFOLLOW`) and never created;
   - re-checks content continuity **under those locks** so a coordinator
     catalog deploy cannot be overwritten by this restamp;
   - resolves coordinator `MainPID` before mutating, records the outgoing
     release as `.previous-target`, atomically retargets `current`, `SIGHUP`s;
   - verifies served `/v1/rate-card` `generated_at` **exactly** equals this
     run's stamp. Rollback of `current` / `.previous-target` runs **only if
     this run already swapped `current`**, and only while holding the same
     locks. A lock-held or pre-swap failure does not rollback (that would be
     the first mutation and can clobber an in-flight coordinator deploy).

## Weekly schedule

| When (UTC) | What |
| --- | --- |
| Monday 16:00 | discovery-head renewal (`renew-release-discovery-head.yml`) — different key, different artifact. Do not share this slot. |
| Wednesday 16:00 | **signed autotune renew** (`renew-autotune-static-feed-signed.yml`, `production-release`) |
| Tuesday 16:00 | **watch** (`renew-autotune-static-feed.yml`) — fails if live `generated_at` is ≥ 7 days old (~6 days after a successful Wednesday) |
| every 6 hours | **20-day alarm** (`autotune-feed-freshness-alarm.yml`) |

A red Tuesday watch means: inspect the Wednesday `production-release` run
(missed schedule or approval still pending). Do **not** install a laptop
LaunchAgent as the SLA — a closed laptop misses the week. Do **not** put the
feed key on Pearl.

## Laptop fallback (not the SLA)

If the Actions signer cannot run, an operator at a machine that already holds
the key can:

```bash
scripts/renew-autotune-static-feed.sh            # build + verify, no prod contact
scripts/renew-autotune-static-feed.sh --deploy   # publish + hot-reload + verify
```

Env overrides: `PEARL_SSH` (default `pearl`), `PEARL_SSH_IDENTITY`,
`PEARL_SSH_KNOWN_HOSTS`, `REMOTE_AUTOTUNE_DIR`, `COORDINATOR_UNIT`,
`COORDINATOR_HEALTH_URL`, `AUTOTUNE_STATIC_KEY_ID`,
`AUTOTUNE_STATIC_PRIVATE_KEY_PATH`, `OPENSSL_BIN`.

Verify after a run:

```bash
curl -s https://coordinator.malibu.tech/v1/rate-card \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["generated_at"])'
```

`pool_size` should be unchanged across the HUP.

## GitHub Actions backstops (no signing, no Pearl SSH)

The Tuesday cadence and 20-day alarm remain **read-only**. They fetch live
`/v1/rate-card` and call `scripts/check-autotune-feed-freshness.py` (stdin JSON,
no network, no secrets). The live URL is pinned to
`https://coordinator.malibu.tech/v1/rate-card` (no dispatch override).

```bash
curl -fsS --proto '=https' --tlsv1.2 --max-time 20 \
  https://coordinator.malibu.tech/v1/rate-card \
  | python3 scripts/check-autotune-feed-freshness.py --max-age-days 20
```

## Rollback

The prior release is retained as `.previous-target` and its directory is left in
`releases/`. Automated rollback holds the Pearl deploy locks, then:

- restores `current` and `.previous-target` if `current` still points at the
  failed renewal;
- restores `.previous-target` only if `current` never moved;
- does nothing if `current` already points at a newer release.

Manual rollback must do the same. Replace `<failed-release-id>` with the
renewal directory that should be undone:

```bash
expected='releases/<failed-renewal-id>'
orig_prev='releases/<pre-renewal-previous-id>'  # or __EMPTY__ if there was none
ssh pearl bash -s -- "$expected" "$orig_prev" <<'RB'
set -euo pipefail
root=/opt/macprovider/autotune
expected="$1"
orig_prev="$2"
[ "$orig_prev" = "__EMPTY__" ] && orig_prev=""
exec 8</run/lock/macprovider-pearl-updater.lock
flock -n 8 || { echo "Pearl updater lock held; not mutating" >&2; exit 1; }
exec 9</opt/macprovider/.coordinator-deploy.lock
flock -n 9 || { echo "coordinator deploy lock held; not mutating" >&2; exit 1; }
live="$(readlink "$root/current")"
live="${live#./}"
[ "$live" = "$expected" ] || {
  echo "current is $live, not $expected; not mutating" >&2
  exit 0
}
prev="$(cat "$root/.previous-target")"
ln -sfn "$prev" "$root/.current.rb"
mv -Tf "$root/.current.rb" "$root/current"
if [ -n "$orig_prev" ]; then printf '%s\n' "$orig_prev" > "$root/.previous-target"; else rm -f "$root/.previous-target"; fi
pid="$(systemctl show -p MainPID --value macprovider-coordinator)"
[ -n "$pid" ] && [ "$pid" != "0" ] && kill -HUP "$pid"
echo "rolled back current away from $expected"
RB
```

See also `autotune-feed-30day-freshness-expiry-fleetwide` (incident + manual
procedure this automates).
