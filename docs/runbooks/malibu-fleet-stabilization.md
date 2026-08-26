# Malibu fleet status ledger

Use this runbook for the operator fleet ledger controlled by
[GitHub issue #1188](https://github.com/Augustas11/macprovider/issues/1188).
This is the provider-state truth workflow. It is not the Malibu app UX/repair
umbrella and it should not own app copy, install flows, release notes wording,
or provider-specific UI design.

Privacy boundary: do not add provider names, hostnames, full provider ids,
payout details, or other provider-identifying details to GitHub issues, PR
bodies, this runbook, or public reports. Use anonymous labels such as External
provider incident A/B in GitHub-facing text and keep identifying mappings in
private operator notes only.

## Ledger fields

Every provider row records these raw facts separately when the source has them:

- provider id
- hostname
- Malibu app version
- CLI version
- watchdog/repair state
- model
- coordinator presence
- routing eligibility
- trust tier
- hash status
- attestation status
- encrypted leg
- catalog admission mode
- admission/policy flags
- Tier-2 policy eligibility
- Tier-2 policy reason
- reward hold reason
- last heartbeat
- last error

Blank fields mean the selected source did not expose that fact. Do not fill
missing fields by asking every provider for exports until coordinator/admin
state has been checked.

## User-facing buckets

Each row resolves to exactly one bucket:

- Healthy
- Repair provider software
- Offline/connectivity
- Trust verification needed
- Cooldown/requalification

Bucket precedence is:

1. `Repair provider software`: updater, watchdog, app/CLI version-floor,
   `catalog_admission_mode=update_bridge`, or repair evidence signals. If
   Repair or a fresh Malibu app install already failed and the old watchdog is
   still blocking, keep this bucket but record
   `watchdog_repair_state=watchdog_layer_repair_blocked` and stop repeating
   generic Repair advice. `update_bridge` is coordinator-directed first-hop
   update recovery: the provider can be visible to operators while not being
   buyer-routable. `catalog_admission_mode=legacy` is preserved as raw catalog
   evidence but stays in the generic routing/cooldown lane unless another fresh
   software-repair signal is present.
2. `Offline/connectivity`: offline coordinator presence, unavailable state,
   missing coordinator TCP/WebSocket evidence, or no coordinator presence in
   the source snapshot. Last-known connectivity diagnostics attached to a live,
   connected, routing-eligible coordinator row are evidence only unless the
   diagnostic is newer than the live heartbeat/activity or comes from a
   diagnostics-only fallback source.
3. `Cooldown/requalification`: demotion cooldown, quarantine, degraded/canary,
   benchmark, admission-sandbox, or connected-but-not-routing signals.
4. `Trust verification needed`: provisional/rejected trust tier, self-minted or
   bearerless auth, invalid token, hardware/app attestation, receipt, or
   provider-token trust signals. Direct Tier-2 integrity failures such as model
   hash mismatch/invalid status or failed/stale attestation stay out of
   `Healthy` even when the provider is connected and route-capable.
   Required-missing policy decisions are authoritative only when the
   coordinator/admin source emits row-level `tier2_policy_eligible=false` with
   `tier2_policy_reason`; requirement-shaped `/poolz` config fields alone are
   preserved as raw facts but are not treated as a final row verdict.
5. `Healthy`: connected and routing eligible with no higher-precedence signal.

These buckets are intentionally user-facing. Raw facts can still say trusted,
locked, serving, offline, repair failed, or cooldown, but the row gets one
bucket so operators do not surface contradictory combined states.

## Operator-first workflow

Start with coordinator truth:

```bash
mkdir -p ~/.config/macprovider/operator-secrets
chmod 700 ~/.config/macprovider/operator-secrets
install -m 600 /dev/null ~/.config/macprovider/operator-secrets/operator-token
# Put only the operator bearer in operator-token before running the ledger.

python3 scripts/malibu_fleet_ledger.py \
  --admin-url https://coordinator.malibu.tech \
  --operator-token-file ~/.config/macprovider/operator-secrets/operator-token \
  --format csv
```

With `--admin-url`, the script pulls `/admin/providers` and augments live rows
from `/poolz` by default. `/admin/providers` supplies connected/offline
last-known state and diagnostics. `/poolz` supplies live hostname, trust tier,
model, heartbeat, routing eligibility, Tier-2 integrity/admission facts, and
autoupdate telemetry when the provider is currently connected.

Avoid printing operator tokens in shell history when a local file is available:

```bash
python3 scripts/malibu_fleet_ledger.py \
  --admin-url https://coordinator.malibu.tech \
  --operator-env-file ~/.config/macprovider/operator-secrets/coordinator.env \
  --format csv

python3 scripts/malibu_fleet_ledger.py \
  --admin-url https://coordinator.malibu.tech \
  --operator-token-file ~/.config/macprovider/operator-secrets/operator-token \
  --format csv
```

Token files and env files used with the ledger must be owned by the operator
and mode `0600`; parent secret directories should be `0700`. Explicit file
credential sources fail closed when empty, unreadable, group/world-readable, or
missing the selected env key. The admin URL must use HTTPS, except explicit
loopback development hosts such as `http://127.0.0.1`, `http://localhost`, or
`http://[::1]`. Do not include credentials, query strings, or fragments in
`--admin-url`; admin redirects are rejected.

Ledger JSON/CSV output is private operator material. Do not commit it, attach it
to public issues or PRs, or paste it into public reports. Save local reports
with restrictive defaults:

```bash
umask 077
python3 scripts/malibu_fleet_ledger.py \
  --admin-url https://coordinator.malibu.tech \
  --operator-token-file ~/.config/macprovider/operator-secrets/operator-token \
  --format csv > ~/.config/macprovider/operator-secrets/fleet-ledger.csv
chmod 600 ~/.config/macprovider/operator-secrets/fleet-ledger.csv
```

Saved responses can be classified offline:

```bash
python3 scripts/malibu_fleet_ledger.py \
  --admin-json /path/to/admin-providers.json \
  --poolz-json /path/to/poolz.json
```

Use Malibu diagnostics exports only as fallback evidence when coordinator/admin
state cannot explain the provider symptoms:

```bash
python3 scripts/malibu_fleet_ledger.py /path/to/malibu-diagnostics.json
python3 scripts/malibu_fleet_ledger.py --format csv /path/to/*.json
```

## External provider incident A-style evidence

Anonymous incident evidence can show the important split: Malibu.app can update
while the launchd CLI and watchdog remain old. PRs #1082, #1090, and #1091
fixed parts of HOME-ACL repair, reward trust, and repair/UI handling, but #1188
tracks the operator ledger only. Malibu app UX and repair flows belong to
[#1184](https://github.com/Augustas11/macprovider/issues/1184); anonymous
incident follow-up can be linked through
[#1189](https://github.com/Augustas11/macprovider/issues/1189) or
[#1190](https://github.com/Augustas11/macprovider/issues/1190).

For External provider incident A-style evidence:

- raw facts may show trusted or serving coordinator signals;
- watchdog logs may show `autoupdate recovery_error=acl_write_rejected:$HOME`;
- later evidence may say Repair or a new Malibu app install already failed.

Classify that row as `bucket=Repair provider software` with
`watchdog_repair_state=watchdog_layer_repair_blocked`. The operator next action
is not another generic install or Repair prompt. Preserve provider identity and
collect read-only watchdog launchd/log evidence in private operator notes for
the incident owner.

## Scope boundary

Link fleet-ledger work to
[issue #1188](https://github.com/Augustas11/macprovider/issues/1188). Link app
copy, install/repair UX, release notes, and provider-specific recovery issues as
separate child evidence or separate epics. Diagnostics exports are fallback
evidence, not the primary workflow.
