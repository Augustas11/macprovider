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
fail-closed). A **dates-only restamp** is zero-disruption for already-connected
sockets. A **content catalog cut** is not: hello `catalog_release_id` is frozen
at `serve` start (live fetch or the CLI baked catalog). One `.previous-target`
hop is the wrong primitive for that — it used up listed-v1 on 2026-09-19 and
kicked Llama-3.2-3B boxes still advertising inband-v1 or baked gpt-oss-v1.
See `docs/reports/2026-09-19-catalog-one-hop-admission-outage.md`.

`.previous-target` is a window of **at most three** `releases/<id>` lines.
Publish prepends the outgoing current and keeps the next two unique retained
releases. A fourth line is fail-closed. Do not replace the file with a single
hop.

This three-release window is a deploy/rollback mitigation, not the durable
compatibility primitive. The durable primitive is SPEC-023-R010 row-continuity:
for every provider-facing content cut, unchanged selected rows must stay
admissible by row identity plus `PolicyEquivalent` even when a running provider
is still advertising an older live or baked catalog document. A content publish
that would depend solely on `.previous-target` depth to keep unchanged rows in
the pool is not ready for production.

## Security model — signing stays off the production host

The Ed25519 feed-signing key (`streamvc-autotune-static-v4`) is what protects
clients from a compromised coordinator serving forged feeds. It **MUST NOT**
live on Pearl. A Pearl-root signer that mints client-trusted feeds and retargets
`autotune/current` is the same mutation surface as `deploy-pearl-vps.sh`.

Primary always-on signer: GitHub Actions
`.github/workflows/renew-autotune-static-feed-signed.yml` (Wednesday 16:00 UTC,
`environment: autotune-feed-renewal`, no reviewer gate). The runner signs with
Swift CryptoKit, authenticates the previous signed release with a sealed Go
verifier at `/private/var/macprovider-go-verifier/bin/go`, verifies signatures
with a sealed OpenSSL 3 bottle, and rsyncs **only signed bytes** to Pearl.
The private key is an `autotune-feed-renewal` secret, never a file on the
coordinator host. `catalog-release.py` does not take Go from PATH.

A Pearl compromise therefore still cannot mint a validly-signed feed.

## Operator secrets (not in the repo)

Place these on the `autotune-feed-renewal` environment **before the first live
`--deploy`**. Until they exist, the workflow is mergeable but a scheduled run
fails closed on empty secrets. Do **not** commit key material.

| Secret | What it is |
| --- | --- |
| `AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64` | Raw 32-byte Ed25519 seed, same contents as `~/.config/macprovider/keys/autotune-static-v4.private.base64`. Do not reuse the discovery-head release-signing PEM. |
| `PEARL_AUTOTUNE_DEPLOY_SSH_KEY` | Dedicated OpenSSH private key for `root@159.223.165.194` (not `pearl_operator_ed25519`, not the download.malibu.tech upload key). Host key is pinned via `scripts/dist/malibu-download-known_hosts` with `StrictHostKeyChecking=yes`. |
| `RELEASE_POSTURE_TOKEN` | Fine-grained token with repository Administration read and Actions read. Same capability as the `production-release` posture token; this environment does not inherit that secret. |

## What the signed job does

`scripts/renew-autotune-static-feed.sh --deploy` (default without `--deploy` is
dry-run):

1. Builds an **ephemeral git worktree**. On Actions, restamps `GITHUB_SHA`
   (the approved workflow commit), not a floating `origin/main`, and sets
   `CATALOG_RELEASE_BASE_REF` to that SHA so `generate` can read the ledger
   from a `fetch-depth: 1` checkout that has no `origin/main` ref. Locally,
   restamps `origin/main`.
2. `catalog-release.py restamp --release-id … --generated-at …` re-stamps the
   release **source** inputs: `version` + `generated_at` on candidate/demand, and
   `generated_at` only on the rate card (its `version` is a rows-hash — a
   freshness renewal must not change it). Content is otherwise byte-identical.
   Once the catalog is artifact-bound (`catalog-release.py status` reports
   `post-activation`), the script first fetches Pearl's live `current` release
   directory as the previous signed release (or honours
   `AUTOTUNE_PREVIOUS_RELEASE_DIR`), which `generate` authenticates against the
   keyring and the ledger before it will cut the next release.
   The rate card is re-dated at `rate-card-source.json`, because `rate-card.json`
   is MATERIALISED from that source by step 3: re-dating the generated file
   directly is reverted by the very next `generate`, and the atomic-release check
   then aborts the renewal on a rate-card `generated_at` that no longer matches
   the candidate catalog. The generator exclusively writes `rate-card.json`. A
   checkout with no `rate-card-source.json` falls back to re-dating the published
   file, which is the source of truth there. The executable regression for the
   whole restamp → generate → verify sequence, in both the four-feed and
   five-feed states, is `RenewalFlowTest` in
   `scripts/tests/test_catalog_artifact_feed.py`, run by
   `scripts/test-renew-autotune-static-feed-signed.sh`.
3. `catalog-release.py generate` → canonical bytes + manifest + ledger, then
   `resign-autotune-static.sh` signs the three static feeds — four once the
   release is artifact-bound (`autotune-artifacts.json`). On Actions, generate
   requires `CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER=1` so Tier-2
   authentication uses the sealed Go at `/private/var/macprovider-go-verifier`
   rather than Homebrew/`PATH`. `verify-directory` uses `OPENSSL_BIN` when set
   (CI sealed bottle).
4. Assembles the release dir (9 files; 11 once artifact-bound: the artifact
   feed and its `.sig`) and gates it with
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

## Content catalog cuts

Freshness restamps are dates-only and MUST continue to use the continuity guard
above. A content catalog cut is different: it may add rows, reprice rows, change
status, or adjust serving policy. Before a content cut reaches Pearl, run a
catalog-admission compatibility report against the intended current release and
the fleet's known live/baked provider catalog distribution. For every current
buyer-serving model key the report must classify one of:

- `row_continuity_ok`: row identity is unchanged and `PolicyEquivalent` to the
  intended current row. These providers survive without restart under
  SPEC-023-R010 when their document is in `.previous-target` or
  `.row-continuity-target`.
- `intentional_policy_change`: row identity or admission-authoritative policy
  changed. The release notes must name the operational effect and the expected
  provider restart/update path.
- `stale_or_untrusted`: the old document, signer, tombstone status, or artifact
  evidence cannot be authenticated. This remains fail-closed.

The report must also identify any fleet share that is relying on a CLI baked
catalog fallback. Baked fallback is a provenance/refresh diagnostic, not a
hostile-catalog verdict, when the selected row is still row-continuity-ok.

Do not use a broad `releases/` directory scan as an admission substitute. If a
row needs compatibility beyond the bounded `.previous-target` window, list the
older signed release in `.row-continuity-target` (below).

### Row-continuity evidence: `.row-continuity-target` (SPEC-023 v0.15.1, #1705)

`<autotune-root>/.row-continuity-target` holds at most **8** `releases/<id>`
lines (`#` comments allowed). The coordinator loads each one with the same
keyring signature check as `.previous-target` and admits a provider still
advertising that document **only** when its selected row identity and
`PolicyEquivalent` policy equal the current release's row. Such sessions show
`catalog_admission_mode = row_continuity` in `/admin` and journal
`provider admitted by catalog row continuity`. Deploy, renewal, and rollback
never write this file. A missing or unverifiable entry admits nobody and does
not block boot; a ninth line or a malformed line does.

Keep in it every signed document a shipped CLI bakes and that providers still
run: at minimum the baked catalog of each CLI version at or above the fleet
floor. After adding or removing a line, `SIGHUP` the coordinator. Remove a line
once no connected provider advertises that release.

One-time Pearl step for the 2026-09-23 recurrence. The v1.8.123 CLI bakes
`published-2026-09-02-gpt-oss-120b-v1`:

```bash
ssh pearl
root=/opt/macprovider/autotune
ls -d "$root"/releases/published-2026-09-02-gpt-oss-120b-v1*
# verify the dir has autotune-candidates.json + .sig, then:
printf '%s\n' '# CLI baked catalogs still in the fleet (SPEC-023-R010)' \
  "releases/$(basename "$(ls -d "$root"/releases/published-2026-09-02-gpt-oss-120b-v1* | head -1)")" \
  | sudo tee "$root/.row-continuity-target"
sudo systemctl kill -s HUP macprovider-coordinator
journalctl -u macprovider-coordinator --since -5m | grep -E 'row-continuity|row continuity'
```

If that release directory was pruned, restore its signed bytes from the
catalog release artifacts first. Never hand-edit a candidate JSON; the signature
must verify.

A content publish that would evict buyer-serving unchanged rows whose document
is in neither file must still be delayed or paired with a controlled provider
restart/upgrade plan. CLIs built after #1705 also refetch the signed live
catalog on `catalog_incompatible` and adopt it when their served row is
unchanged, so they recover without a restart.

## Weekly schedule

| When (UTC) | What |
| --- | --- |
| Monday 16:00 | discovery-head renewal (`renew-release-discovery-head.yml`) — different key, different artifact. Do not share this slot. |
| Wednesday 16:00 | **signed autotune renew** (`renew-autotune-static-feed-signed.yml`, `autotune-feed-renewal`, unattended) |
| Tuesday 16:00 | **watch** (`renew-autotune-static-feed.yml`) — fails if live `generated_at` is ≥ 7 days old (~6 days after a successful Wednesday) |
| every 6 hours | **20-day alarm** (`autotune-feed-freshness-alarm.yml`) |

A red Tuesday watch means: inspect the Wednesday `autotune-feed-renewal` run
(missed schedule or job failure). Do **not** install a laptop LaunchAgent as
the SLA — a closed laptop misses the week. Do **not** put the feed key on
Pearl. The signed job has no human approval gate.

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
