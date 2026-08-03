# Signed Pearl release updater

The Pearl updater installs coordinator and gateway binaries as one guarded
transaction. It is deliberately disabled after installation and never changes
Tier-2 policy, enables internal provider canaries, or clears provider sanctions.
The authenticated recovery action from PR #538 remains operator-only.

## Release trust contract

Pearl has four separate release/config sources of truth:

- **Pearl runtime release**: the signed coordinator/gateway runtime bundle for
  Pearl. Its required assets are `coordinator-linux-amd64`,
  `coordinator-cli-linux-amd64`, `gateway-linux-amd64`,
  `pearl-release.json`, `pearl-release.json.sig`, `checksums.txt`, and
  `checksums.txt.sig`. Runtime-only releases set
  `release_lane: "pearl_runtime"` and do not carry provider app,
  Malibu.app, catalog, or static-feed assets. The updater preserves the live
  `tier2.catalog_path` and feed state for this lane. The protected runtime
  workflow publishes this lane as a GitHub prerelease with `make_latest=false`,
  so it never takes over the provider-app stable `/releases/latest` authority
  and is applied only by explicit tag.
- **Provider app release**: the signed Mac provider CLI, Malibu.app package,
  standalone tarball, and provider artifact index. Release verification for
  this lane proves the standalone CLI and Malibu-embedded CLI byte identity;
  it is not proof that Pearl has a usable coordinator/gateway runtime bundle.
- **Catalog/feed release**: the Tier-2 catalog, trusted keys,
  autotune-candidates feed, demand-rank feed, signatures, release ledger, and
  provider-side catalog admission evidence. This lane owns policy/feed
  identity and static-feed signatures; it is not a coordinator/gateway binary
  rollout.
- **Pearl config release/reconciliation**: the reviewed
  `ops/pearl/config/source-of-truth.yaml` classification plus the live
  Pearl config preserved by `CONFIG_MODE=preserve-live`. This lane decides
  which live fields may remain operator-owned; it does not publish or install
  runtime binaries.

The older catalog-bound Pearl bundle remains supported as
`release_lane: "pearl_runtime_catalog"` for backwards-compatible releases that
intentionally couple coordinator/gateway runtime assets with catalog/feed
assets. In that lane, `pearl-release.json` must include the exact repository,
tag, commit, component hashes, embedded versions, architecture, provider
version advertised by the coordinator configuration, signed provider admission
policy (`bridge_required` during migration or `strict_post_migration` after
closure), and the catalog release identity/files. Runtime-only releases carry
only the signed runtime component hashes plus a strict no-op admission shape;
they must not carry `provider_advertised_version`, and `catalog` is absent or
`null`.

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

The only historical exception is the exact pre-publication v1.8.39 recovery in
the signing runbook §8.1: its first signed tag belonged to a failed workflow
that created no GitHub Release or public asset. That old object is lease-deleted
before a replacement candidate is built, and the replacement tag becomes
immutable when recreated. This exception cannot apply to an ordinary or
already-published Pearl release.

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

Live coordinator and gateway binaries are always normalized to
`root:macprovider 0750` from the named systemd service group. The updater never
inherits daemon ownership from a legacy or drifted destination file. The same
invariant applies during rollback, and every atomic replacement is read back
for exact group, mode, and checksum before service start.

The first adoption may start from older deployment-script binaries whose
embedded versions are clean `git describe` identities such as
`v1.8.26-4-g64083ef`. The updater accepts that exact, non-dirty shape only when
no durable updater release state exists, derives the downgrade floor from the
base tag, and requires the signed candidate to be strictly newer than that
floor. Commit-only, dirty, ambiguous, same-base, and downgrade identities fail
closed. After the first successful transaction persists signed release state,
legacy git-describe bootstrap is no longer accepted.

## One-time installation

First deploy the issue #825 r6 live-fleet liveness revision of #584's redesigned
canary buyer exactly as reviewed, including its root-only `LoadCredential`
files, safety observer, emergency stop, and classified no-load exits. Ordinary
liveness follows the currently ready/routable provider fleet and no longer
requires the expected-fleet file's static provider count or model set; legacy
rollback and qualification checks remain scoped to their explicit protected
fleet. The updater pins that complete runtime, service, and timer as rollout
authority `issue-825-canary-fleet-r6` at source commit `fb3f4f1680b9cf2404c0f40317bef3696d659f58`;
the default `PEARL_UPDATER_BUYER_CANARY_MODE=required` posture fails `--plan`
on any SHA drift, missing credential, invalid protected-fleet expected-fleet
document, absent reviewed enable gate, active emergency-disable sentinel,
unexpected unit drop-in, stale systemd fragment, or changed three-minute
canary budget. The one allowed canary drop-in is the updater's exact root-owned
transaction gate installed below.
Leave `/etc/macprovider-canary-buyer/enabled` absent until Issue #584's
real-hardware, recovery, and operating-day evidence has reviewed sign-off.
The updater intentionally refuses even `--plan` in `required` mode until that
gate is present; creating it authorizes the redesigned liveness probe as a
rollout gate, not the scheduled timer.

An explicitly sealed production window may instead set
`PEARL_UPDATER_BUYER_CANARY_MODE=disabled` in the root-owned updater
configuration. That mode never starts the buyer canary. It requires both
enable gates absent, an empty root-owned `0644` `DISABLED` sentinel, the timer
disabled/inactive, and the oneshot service inactive. The updater rechecks that
posture before state capture, after stable public fleet recovery, and after
the exact physical catalog-provider proof. Public identity, three consecutive
protected-fleet samples, admission policy, exact catalog admission, and the
physical provider canary remain mandatory. The default remains `required`.
Runtime-only `pearl_runtime` releases are not eligible for this disabled mode:
because they deliberately omit the exact catalog/provider gates, apply requires
`PEARL_UPDATER_BUYER_CANARY_MODE=required` and a passing buyer canary.

From the authority commit's reviewed checkout, install the four runtime files
as executable root-owned files and the two units as non-executable root-owned
fragments. Provision all four `LoadCredential` inputs as exact `0600` files,
remove the retired environment file, and reload systemd without enabling either
schedule. The reviewed expected-fleet JSON remains a qualification and rollback
identity allowlist: every listed provider ID must be unique, every model value
must be non-empty, and duplicate model IDs are allowed when several providers
serve the same model. Ordinary liveness does not require that file's provider
cardinality or distinct model set to match Pearl's current fleet; it derives the
run baseline from the initial ready/routable `/poolz` rows and probes the live
available models from gateway status.

```bash
sudo install -d -o root -g root -m 0755 /opt/macprovider-canary-buyer
sudo install -o root -g root -m 0755 \
  test/e2e/canary-buyer/probe.mjs \
  test/e2e/canary-buyer/safety.mjs \
  test/e2e/canary-buyer/run-canary.sh \
  test/e2e/canary-buyer/emergency-disable.sh \
  /opt/macprovider-canary-buyer/
sudo install -o root -g root -m 0644 \
  test/e2e/canary-buyer/canary-buyer.service \
  test/e2e/canary-buyer/canary-buyer.timer \
  /etc/systemd/system/
sudo install -d -o root -g root -m 0750 /etc/macprovider
sudo install -o root -g root -m 0600 /dev/null \
  /etc/macprovider/canary-buyer.token
sudo install -o root -g root -m 0600 /dev/null \
  /etc/macprovider/canary-buyer.heartbeat
sudo install -o root -g root -m 0600 /dev/null \
  /etc/macprovider/canary-buyer.operator-token
sudo install -o root -g root -m 0600 \
  /secure/reviewed-canary-expected-fleet.json \
  /etc/macprovider/canary-buyer.expected-fleet.json
printf '%s\n' "$CANARY_BUYER_TOKEN" | sudo tee /etc/macprovider/canary-buyer.token >/dev/null
printf '%s\n' "$CANARY_HEARTBEAT_URL" | sudo tee /etc/macprovider/canary-buyer.heartbeat >/dev/null
printf '%s\n' "$CANARY_OPERATOR_TOKEN" | sudo tee /etc/macprovider/canary-buyer.operator-token >/dev/null
sudo rm -f /etc/macprovider/canary-buyer.env
sudo install -d -o root -g root -m 0755 \
  /etc/macprovider-canary-buyer
sudo systemctl daemon-reload
sudo systemctl disable --now canary-buyer.timer
```

Only after Issue #584 sign-off, create the empty reviewed gate. This authorizes
manual rollout serving checks but still does not enable the timer:

```bash
sudo install -o root -g root -m 0644 /dev/null \
  /etc/macprovider-canary-buyer/enabled
```

Create a separate root-only Better Stack Uptime API credential. This token is
not the canary heartbeat ping URL and should have only the heartbeat read/update
permission needed for the configured resource:

```bash
sudo install -o root -g root -m 0600 /dev/null \
  /etc/macprovider/pearl-updater.betterstack-token
printf '%s\n' "$BETTERSTACK_UPTIME_API_TOKEN" | \
  sudo tee /etc/macprovider/pearl-updater.betterstack-token >/dev/null
```

Provision one enrolled catalog-aware canary Mac as the release commit witness.
Store the coordinator operator key, not the gateway/coordinator service token,
as the catalog-canary bearer for `details=deployment`, and store a dedicated
read-only SSH key as root-owned `0600` files on Pearl. The
`/v1/pool/check?details=deployment` evidence path is operator-only; service
tokens are rejected. Store the canary Mac host key in a dedicated root-owned
`0600` known-hosts file; the hardened service cannot read root's home directory
and always uses `StrictHostKeyChecking=yes`. Configure these values in
`/etc/macprovider/pearl-updater.conf`:

```text
PEARL_UPDATER_CATALOG_CANARY_PROVIDER_ID=<exact-provider-id>
PEARL_UPDATER_CATALOG_CANARY_AUTH_TOKEN_FILE=/etc/macprovider/pearl-updater.catalog-canary-token
PEARL_UPDATER_CATALOG_CANARY_SSH_TARGET=<operator-user>@<canary-host>
PEARL_UPDATER_CATALOG_CANARY_SSH_PORT=<canary-ssh-port, default 22>
PEARL_UPDATER_CATALOG_CANARY_SSH_KEY_FILE=/etc/macprovider/pearl-updater.catalog-canary-ssh-key
PEARL_UPDATER_CATALOG_CANARY_KNOWN_HOSTS_FILE=/etc/macprovider/pearl-updater.catalog-canary-known-hosts
PEARL_UPDATER_CATALOG_CANARY_INSTALL_DIR=macprovider/catalog-release
```

The SSH account needs only local read/inspection access to its own provider
installation, LaunchAgent, local status port, and `lsof`. It does
not receive the coordinator bearer token. `--plan` fails closed when either
identity or secret file is missing, unsafe, or malformed.

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
sudo -u macprovider -g macprovider /usr/local/sbin/macprovider-pearl-updater-alert \
  --check-config macprovider-pearl-updater.service
sudo -u macprovider -g macprovider /usr/local/sbin/macprovider-pearl-updater-alert \
  macprovider-pearl-updater-preflight.service
```

An empty `GMAIL_APP_PASSWORD` means the existing monitor is journal-only and
blocks rollout. Populate the Gmail app password, run both commands, and confirm
the preflight message reached the independent mailbox before continuing.
Reconciliation deliberately does not depend on this credential, so an
interrupted transaction can still roll back if alert delivery configuration is
later lost.

## Pearl runtime release preflight

When rolling a specific tag, verify release identity before invoking the live
updater. This prevents the operator from discovering too late that a tag exists
without the Pearl runtime release assets, or that the tag/source identity does
not match the reviewed deploy target:

```bash
git fetch origin --tags
expected_commit="$(git rev-parse HEAD)"
scripts/verify-pearl-runtime-release.sh \
  --tag vX.Y.Z \
  --expected-commit "$expected_commit"
```

This preflight checks the immutable git tag target, `pearl-release.json`,
`coordinator-linux-amd64`, `gateway-linux-amd64`,
`coordinator-cli-linux-amd64`, and signed checksum controls. If
`pearl-release.json` declares `release_lane: "pearl_runtime_catalog"` or omits
`release_lane` for a legacy catalog-bound bundle, the preflight also requires
the catalog/feed assets and their signed hashes. If it declares
`release_lane: "pearl_runtime"`, missing catalog/feed assets are accepted and
the updater leaves `tier2.catalog_path` unchanged. A GitHub tag that exists
without coordinator or gateway runtime assets must be reported as missing Pearl
runtime assets, not as a generic CLI/provider-app release failure. It is
intentionally not a substitute for `macprovider-pearl-update`: the updater
still performs signature verification, transaction staging, rollback,
provider-drain protection, and serving gates before any live mutation.

If the preflight fails because the GitHub Release is missing Pearl runtime
assets, do not apply an older available release just because its plan succeeds.
Select or cut a reviewed runtime release whose tag, metadata commit, and deploy
source match. Do not move an existing public tag to repair identity drift.

For the safe issue #785 path, publish a runtime-only Pearl release from the
exact reviewed source commit. Runtime-only GitHub releases are deliberately
published as prereleases with `make_latest=false`; they are never selected by
the updater's automatic stable-release discovery and must be applied by
explicit tag. Verify that tag with the command above, then run the updater
against that same tag with `PEARL_UPDATER_BUYER_CANARY_MODE` left at
`required` and the buyer canary gate reviewed/enabled:

```bash
sudo /usr/local/sbin/macprovider-pearl-update --plan --tag vX.Y.Z
sudo /usr/local/sbin/macprovider-pearl-update --apply --tag vX.Y.Z
```

After the signed coordinator/gateway pair is live, resume the direct deploy
with `CONFIG_MODE=preserve-live`. That deploy may reconcile reviewed Pearl
config ownership, but it must not be used to replace only one runtime binary or
to smuggle a catalog/feed change into the runtime lane.

## First production rollout

1. Confirm the candidate release workflow and tests succeeded. Capture the
   canary Mac's prior signed provider tag, then prefetch and verify the candidate
   provider payload without mutating the live provider:

```bash
~/macprovider/macprovider-cli --version | tee canary-prior-provider-tag.txt
KEEP_DOWNLOADS=1 scripts/verify-tier2-provider-release.sh --tag v1.8.39
```

   Keep the prior provider live. The verifier proves the signed checksum
   manifest, artifact hash, and complete provider payload; it does not authorize
   a provider-first install against the legacy coordinator.
2. In the default `required` mode, confirm #584's redesigned canary runtime and
   credential configuration are installed. The reviewed enable gate is
   required for rollout use; the emergency-disable sentinel must remain absent:

```bash
sudo systemctl start canary-buyer.service
systemctl show --property=Result --property=ExecMainStatus canary-buyer.service
sudo test -s /etc/macprovider/canary-buyer.token
sudo test -s /etc/macprovider/canary-buyer.heartbeat
sudo test -s /etc/macprovider/canary-buyer.operator-token
sudo test -s /etc/macprovider/canary-buyer.expected-fleet.json
sudo test -f /etc/macprovider-canary-buyer/enabled
sudo test ! -e /var/lib/macprovider-canary-buyer/DISABLED
sudo test ! -e /etc/macprovider/canary-buyer.env
systemctl show --property=LoadCredential canary-buyer.service
```

   In a separately sealed `disabled` window, do not create an enable gate and
   do not start the oneshot. Confirm the explicit updater mode and hard-disabled
   posture instead:

```bash
sudo grep -Fx 'PEARL_UPDATER_BUYER_CANARY_MODE=disabled' \
  /etc/macprovider/pearl-updater.conf
systemctl is-enabled canary-buyer.timer || true
systemctl is-active canary-buyer.timer || true
systemctl is-active canary-buyer.service || true
sudo test ! -e /etc/macprovider-canary-buyer/enabled
sudo test ! -e /etc/macprovider/canary-buyer.enabled
sudo test -f /var/lib/macprovider-canary-buyer/DISABLED
sudo test ! -s /var/lib/macprovider-canary-buyer/DISABLED
sudo test "$(stat -c '%U:%G:%a' \
  /var/lib/macprovider-canary-buyer/DISABLED)" = root:root:644
sudo test ! -e /run/macprovider-canary-buyer/legacy-rollback.json
```

   A fleet already emitting direct v2 telemetry must return exactly
   `Result=success` and `ExecMainStatus=0`. A legacy v1.8.30 fleet behind the
   pre-bridge coordinator must instead fail closed with status `1` and only the
   exact expected providers' `provider_signal_missing` reasons. That failure is
   required evidence that the old coordinator cannot authorize the substitute;
   it is not serving proof. After the updater activates the reviewed bridge,
   the new coordinator may classify those same exact ID/model/version rows
   `legacy_bridge`; r6 accepts that classification only as a substitute for the
   missing direct signal while retaining every pool, routing, connection, and
   heartbeat invariant. Before that canary starts, the updater requires three
   consecutive authenticated public `/poolz` samples that contain every exact
   protected provider as ready and routing-eligible and retain the captured
   ready-provider floor. A failed or timed-out canary oneshot is explicitly
   stopped and proven inactive with no queued job before rollback may touch
   state. The updater requires the post-activation run to exit `0` before it
   emits `provider_install_ready`. Any other reason, classified no-load status
   `20`/`21`, or heartbeat delivery failure (exit `3`) aborts the rollout.
3. Before apply, preserve a protected `/poolz` snapshot containing every exact
   provider ID and admission/routing state plus `summary.ready` and
   `summary.free_slots`. Record an operator-approved ready-provider floor of at
   least two. Signed `pearl-release.json` must contain the reviewed
   `provider_admission_rollout` bridge policy. The updater computes its bounded
   RFC3339 deadline at apply time, transactionally stages
   `autotune.provider_admission_bridge_deadline` plus
   `autotune.enforce_provider_admission: false`, validates the complete
   candidate config, and restores the prior config on rollback.
4. Confirm every connected provider supports graceful drain/reconnect. Only
   then set `PEARL_UPDATER_ALLOW_PROVIDER_DRAIN=1`. Configure the updater's
   commit policy to match this bridge rollout:

```text
PEARL_UPDATER_PROVIDER_ADMISSION_POLICY=bridge_required
PEARL_UPDATER_MINIMUM_POOL_READY_AFTER_ROLLOUT=<operator-approved-floor-at-least-2>
PEARL_UPDATER_PROVIDER_RECOVERY_TIMEOUT_S=900
PEARL_UPDATER_SERVICE_HEALTH_TIMEOUT_S=60
PEARL_UPDATER_MINIMUM_BRIDGE_REMAINING_S=1200
```

   The updater rejects a post-rollout local `/healthz.pool_ready` below that
   floor, strict admission during this bridge rollout, or a bridge without the
   configured safe remaining window.
5. Set `PEARL_UPDATER_ENABLED=1` and keep the config, revocation list, Better
   Stack token, catalog-canary operator-key bearer, and catalog-canary SSH key
   `root:root 0600`.
6. Prove the live root-owned config carries the exact outer handoff deadline
   and bridge safety window before starting the plan. These reads expose no
   credentials:

```bash
sudo grep -Fx 'PEARL_UPDATER_PROVIDER_RECOVERY_TIMEOUT_S=900' /etc/macprovider/pearl-updater.conf
sudo grep -Fx 'PEARL_UPDATER_SERVICE_HEALTH_TIMEOUT_S=60' /etc/macprovider/pearl-updater.conf
sudo grep -Fx 'PEARL_UPDATER_MINIMUM_BRIDGE_REMAINING_S=1200' /etc/macprovider/pearl-updater.conf
```

   Any missing line is a fail-closed preflight failure. The 900-second provider
   recovery timeout is the updater's outer wall-clock handoff deadline; the
   candidate's internal prewarm and measured-probe timeouts are idle-progress
   budgets and do not replace or extend that deadline.

7. Run a plan, then start the manual apply in operator terminal A:

```bash
sudo /usr/local/sbin/macprovider-pearl-update --plan
sudo /usr/local/sbin/macprovider-pearl-update --apply
```

   Leave terminal A attached: `--apply` remains synchronous and rollback-armed.
   In a separate read-only terminal, wait for the durable handoff emitted only
   after backend health, buyer serving, capacity preservation, signed bridge
   policy, and exact catalog admission have passed:

```bash
sudo tail -Fn0 /var/lib/macprovider-pearl-updater/audit.jsonl | \
  jq -e --unbuffered 'select(.event == "provider_install_ready" and .outcome == "waiting")'
```

   Only after that exact JSON event appears, run the already pinned provider
   installer on the single canary Mac from operator terminal B. Complete it
   inside `PEARL_UPDATER_PROVIDER_RECOVERY_TIMEOUT_S`; otherwise terminal A
   rolls the backend transaction back:

```bash
curl -fsSL https://get.streamvc.live/install.sh | \
  MACPROVIDER_VERSION=v1.8.39 MACPROVIDER_NO_PROMPT=1 bash
```

   The installer commits only after the bridge coordinator reports that exact
   provider buyer-serving on the `current` envelope. The updater independently
   binds the same provider ID, release, policy, digest, signer, and row identity
   to the seven on-Mac catalog files and the live text vnode before disarming
   rollback. If the provider install fails, its transaction restores the prior
   provider while the still-armed updater rolls back the backend. Follow the
   explicit emergency prior-tag rollback contract in
   `catalog-release-provider-upgrade.md`; never use an unpinned downgrade or an
   expired bridge.

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
failure restores the exact captured backend versions, archive/stats units, and
heartbeat state without touching a live binary, configuration file, or
database. It restores the canary timer only when it was previously active and
the reviewed enable gate still exists with no emergency-disable sentinel; it
never replays a previously in-flight oneshot service. The updater then installs both binaries
with same-filesystem atomic renames. It
starts the coordinator first, verifies local version and advertised provider
version, starts the gateway, verifies the signed coordinator bridge settings and
the configured `pool_ready` floor, waits for a routing-eligible provider to
reconnect and pass warmup, and verifies local and public semantic health. In
`required` mode it then runs `canary-buyer.service` with a 12-minute updater
deadline around its verified three-minute unit budget. Systemd records
deliberate no-load exits `20` and `21` as classified unit outcomes, but the
updater requires both `Result=success` and the original `ExecMainStatus=0`; a
removed enable gate or newly asserted emergency sentinel can never satisfy
serving validation. In `disabled` mode it never starts the buyer canary and
instead re-verifies the hard-disabled posture after public fleet convergence.
It then requires the configured provider to be
buyer-serving on the exact current release/policy/digest/signer/row envelope
and independently proves that the trusted canary Mac has all seven exact catalog
files and that its live launchd PID uses the inspected binary text vnode and
listener. The redesigned #584 buyer liveness canary alone cannot commit a catalog release.
Only after the configured buyer-canary posture and the exact physical provider
proof succeed does the updater persist success and disarm rollback. A
client-side timeout in `required` mode explicitly stops and verifies
cancellation of the canary systemd job. The prior timer state is restored after
success or rollback only while both kill-switch conditions remain safe; the
oneshot service is never replayed. The heartbeat's exact prior paused state is
restored and verified with a fresh GET before the updater exits.

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
gateway, archive/stats units, conditionally eligible canary timer, and Better
Stack state is restored; the canary oneshot service is never replayed. The journal is deleted only
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
version. It reruns the #584 canary in `required` mode; in `disabled` mode it
instead re-proves the hard-disabled posture after public fleet recovery. The previously active
archive/stats services are restored before their timers, and no timer is
restored until that full serving proof succeeds. Even then the canary timer
remains stopped if its enable gate is missing or its emergency-disable sentinel
exists, including when either kill switch changes during timer restoration.
When restoring a pre-direct-telemetry backend, r6 may create
`/run/macprovider-canary-buyer/legacy-rollback.json` only inside the active
phase-journal restoration. That root-owned `0644` control binds the exact
captured protected provider ID/model fleet, the exact prior advertised binary
version, the 64-hex transaction ID, and an expiry no more than 15 minutes away.
It substitutes only for missing provider v2 signals on unclassified legacy
rows and, during the scoped legacy rollback recovery/final-serving window only,
tolerates readiness/signal/count loss or disappearance for one unexercised
duplicate-model row when another authorized same-model provider is ready,
routable, and fresh. If the duplicate row is still present, it must remain
unclassified and identity/version/session-stable. Bridge/current/previous modes,
wrong versions/models/IDs, stale sessions, exercised-provider loss,
unique-model capacity loss, and all other canary failures remain rejected. The updater
removes the control on every success or failure exit. Its presence outside a
restoration blocks an ordinary rollout canary.
The Better Stack heartbeat is then returned to its exact pre-maintenance paused
state. Transaction snapshots and root-only JSON audit records live under
`/var/lib/macprovider-pearl-updater`.

Manual interrupted-transaction recovery is idempotent:

```bash
sudo systemctl stop canary-buyer.timer canary-buyer.service
sudo /usr/local/sbin/macprovider-pearl-update --reconcile
sudo test ! -e /run/macprovider-canary-buyer/legacy-rollback.json
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
confirm both public health endpoints, `/v1/status`, the #584 canary result,
Better Stack state, and absence of `active-transaction.json`, then enable:

```bash
sudo systemctl enable --now macprovider-pearl-updater.timer
systemctl list-timers macprovider-pearl-updater.timer
```

Disable immediately with:

```bash
sudo systemctl disable --now macprovider-pearl-updater.timer
```
