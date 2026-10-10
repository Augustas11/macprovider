# Ops entry points

Agents run these scripts for live work. They do not assemble release, deploy or
restart commands by hand. Each script encodes the order of its runbook and does
not add steps of its own:

| Script | Train | Runbooks |
|---|---|---|
| `cli-release.sh` | provider CLI candidate, promotion, fleet recommendation | `docs/releases/cli-release-train.md`, `docs/runbooks/provider-cli-release-verification.md` |
| `discovery-renew.sh` | signed release-discovery freshness renewal | `.github/workflows/renew-release-discovery-head.yml` |
| `catalog-activate.sh` | catalog, CB policy and native-MTP activation | `docs/runbooks/native-mtp-enablement.md`, `docs/runbooks/catalog-release-decision-tree.md`, `docs/runbooks/pearl-coordinator-rollout.md` |
| `pearl-runtime.sh` | coordinator and gateway runtime release | `docs/runbooks/pearl-coordinator-rollout.md` |
| `live-lock.sh` | one live actor at a time | rollout rule 3 |
| `privacy-activate.sh` | existing signed identity approval; durable rollback | `docs/runbooks/privacy-network-activation.md`, SPEC-049 §8.3 |

Tests (offline): `test-ops-guard.sh`, `test-live-lock.sh`,
`test-runbook-commands.sh`, `test-entrypoints.sh`.

## Use

```bash
scripts/ops/<train>.sh status        # read-only: JSON on stdout, summary on stderr
scripts/ops/<train>.sh next          # the exact command for the next step
MACPROVIDER_OPS_OWNER=<session-label> scripts/ops/<train>.sh next --run
scripts/ops/<train>.sh next --done <step> --evidence '<proof>'   # operator-owned steps only
scripts/ops/cli-release.sh next --done canary_smoke --probe      # structured evidence only
scripts/ops/cli-release.sh next --done e2e_gate --run-id <id> | --carry-forward <record-id>
scripts/ops/live-lock.sh release <session-label>                 # hand back when done
scripts/ops/live-lock.sh acquire <label> --steal                 # only past the holder's TTL
```

- `status` reads live state from GitHub, public HTTPS, and read-only ssh when
  it is configured. It never mutates anything.
- `next --run` runs one step and then stops. It refuses when a precondition
  fails, and it refuses a second dispatch while a run for the same version is
  in flight. For any step that mutates Pearl, it prints the expected downtime
  before it does anything else. A mutating step (and every runnable
  `pearl-runtime.sh` step) needs a clean checkout whose HEAD is `origin/main`.
  It then takes the live-ops lock and decides the next step again; if the
  step changed while it waited, it refuses. The lock is held only while the
  step runs: `next --run` releases it on every exit (success, failure,
  refusal, SIGINT/SIGTERM/SIGHUP), so the next step, run by any owner, is not
  blocked. A step that runs asynchronously (the Pearl `apply` updater unit)
  is covered by the read-only `wait_updater` step, not by the lock. The lock
  is pid-bound (`--bind-pid`): if the process that took it dies without
  releasing (SIGKILL, crash), the next `acquire` on the same host takes it
  over and logs the holder. Locks taken by hand keep TTL and `--steal` only.
- Runbook commands are never read from the Markdown at run time. They are
  constants in `lib/runbook-commands.sh`; `test-runbook-commands.sh` fails when
  one drifts from its fenced block on `origin/main`.
- `cli-release.sh` edits Pearl's `coordinator.yaml` itself for
  `privacy_release_setup` and `recommendation_bump`:
  `next --run` prints the downtime, holds the live-ops lock, and runs
  `lib/pearl-cli-config.py` over `PEARL_SSH` under both Pearl locks (refusing
  on a pricing transaction journal): anchored in-place edit, backup under
  `/root/macprovider-backups`, validation with the running coordinator's
  binary, user and exact environment, atomic replace, one restart,
  `/healthz` and the live postcondition, then the step is recorded. An edit
  already on disk but not applied by the running coordinator is recovered
  with a validated restart.
- Admission needs no Pearl edit (SPEC-002-R004): the coordinator admits every
  well-formed release from the `target_id` repository; only exact
  `revoked_ids` are kept off buyer traffic (update-only). `pearl_accepted_ids`
  is a read-only check that the running policy admits the candidate. The
  policy comes from `/healthz` and must equal the applied config; any
  difference blocks every Pearl-mutating step. A runtime that reports no
  policy mode is pointed at `pearl-runtime.sh`, never at an `accepted_ids`
  edit (that field is deprecated and ignored). Step `revocation_seed` applies
  the checked-in one-time seed
  (`phase4-coordinator/dist/compatibility-revoked-ids.txt`) to the live
  `revoked_ids` with one restart, on a repository-mode runtime only; a seed
  id that is the current target is deferred until `recommendation_bump`
  moves the target, then revoked by the same step.
- Release tags count only with an approved signer: list SSH signers in
  `MACPROVIDER_RELEASE_TAG_ALLOWED_SIGNERS` (an allowed-signers file, default
  `~/.config/macprovider/release-tag-allowed-signers`) or OpenPGP fingerprints
  in `MACPROVIDER_RELEASE_TAG_GPG_FINGERPRINTS`. The checkout's git trust
  settings are not used. `promotion` re-checks Pearl registrations
  (`_check-registrations`) right before dispatching; the workflow itself
  cannot reach Pearl. No step asks anyone to
  paste a restart; the ops guard still blocks a typed restart and a direct
  `_pearl-config`.
- `cli-release.sh` registers each new CLI on Pearl before it can be
  promoted. `privacy_release_setup` configures the privacy release metadata
  dir once. Step
  `privacy_release_identity` stages the verified `pearl-release.json` as
  `v<ver>.json` there (hot, no restart). The read-only `registrations` gate,
  evaluated on every status, requires the running coordinator to hold the
  registrations (loaded-identity metric, boot config digests) and gates the
  canary, promotion, the recommendation bump and rollout verification.
  `canary_smoke --probe` also fails on a privacy rejection of the canary in
  Pearl's journal. `verify_live_rollout` runs `_check-privacy-rejections`
  first: two samples of the unapproved-rejection counter over a window
  (`PRIVACY_REJECTION_WINDOW_SECONDS`, default 180) bound to one coordinator
  invocation; after a restart in the window it counts the unit journal
  instead. Pearl-side helper errors print only the file name and
  error class, never config bytes.
- `cli-release.sh` step `release_tag`, just before `promotion`, creates the
  signed annotated `v<ver>` tag on the verified candidate SHA with the
  operator's git signing key, checks it with `git verify-tag`, and pushes it;
  the promotion workflow requires that tag to exist. It is done when origin's
  `v<ver>` is annotated, peels to the candidate SHA and its exact remote tag
  object passes `git verify-tag`; it refuses an unsigned, untrusted,
  lightweight or other-commit `v<ver>`.
- `cli-release.sh` step `mirror_latest`, after `verify_live_rollout`, keeps the
  release mirror's advisory `releases/latest.json` on the recommended tag. It is
  done when the served `tag_name` equals `v<ver>`; `next --run` runs
  `scripts/publish-release-mirror.sh --tag v<ver> --promote-latest`, which itself
  refuses a tag the coordinator does not advertise and never moves the pointer
  backwards. It is blocked until `MALIBU_DOWNLOAD_SSH_KEY` is set; `GH_TOKEN`
  defaults to the repo's `gh` login. Runbook:
  `docs/runbooks/provider-cli-release-verification.md#release-mirror-byte-identity-downloadmalibutech-1737`.
- Steps the operator owns are `manual`: an environment approval click or a
  provider restart. `next` prints the
  documented command and `next --run` refuses. When the step is done, record
  it with `next --done`. `canary_smoke` and `e2e_gate` refuse free text: they
  take a canary status probe the script reads itself, signed journey run ids
  that the script checks with `gh`, or a carry-forward record in
  `docs/releases/cli-release-train.md`. Promotion sets
  `physical_acceptance_confirmed=true` only after both. A few other steps
  leave no trace that can be read live, such as the signed-byte verification
  and the gateway proof (which must move the target provider's counters and
  expires after 24 h). Their completion is kept under
  `~/.config/macprovider/ops-state/`.
- Every step command runs with `MACPROVIDER_OPS_ENTRYPOINT=1` exported. The
  guard in `hooks/` blocks the guarded commands when an agent types them
  directly. It allows them when that marker is set in the environment the
  guard itself runs in.

## Local configuration (untracked)

No host, address, user name or key path is committed. Put the targets in
`~/.config/macprovider/ops.env`, or export them. Override the file location
with `MACPROVIDER_OPS_ENV`. The variable names are:

```bash
COORDINATOR_URL=https://<coordinator-host>
GATEWAY_URL=https://<gateway-host>
INSTALL_SH_URL=https://<installer-host>/install.sh
INSTALL_SH_REMOTE_PATH=<webroot path of the served install.sh>
MALIBU_DOWNLOAD_SSH_KEY=<key file for the release mirror host>  # mirror_latest only
PEARL_SSH=<ssh alias for the coordinator host>   # configure identity/known_hosts in ~/.ssh/config
PEARL_SSH_IDENTITY=<optional key file>           # used by the repo scripts that the steps call
PEARL_SSH_KNOWN_HOSTS=<optional pinned known_hosts>
REMOTE_REVOCATION_DIR=<native-MTP revocation root on the coordinator host>
STUDIO_SSH=<ssh alias for the canary Mac>
STUDIO_SSH_KEY=<optional key file>
STUDIO_STATUS_PORT=<provider local status port>
BUYER_TOKEN_FILE=<file holding a buyer API key>  # gateway proof only
PROBE_MODEL=<model id>                           # default: the admission tuple's model
CATALOG_CANARY_PROVIDER_ID=...                   # as scripts/catalog-content-release.sh
PEARL_RUNTIME_VERSION=v<x.y.z>                   # pearl-runtime.sh target tag
# cli-release.sh Pearl layout; the defaults are the production paths:
PEARL_COORDINATOR_CONFIG=/opt/macprovider/coordinator.yaml
PEARL_COORDINATOR_OVERLAY=/etc/macprovider/coordinator.pearl-overlays.yaml
PEARL_COORDINATOR_UNIT=macprovider-coordinator
PEARL_COORDINATOR_METRICS_URL=http://127.0.0.1:8444/metrics
PEARL_RELEASE_IDENTITY_OWNER=root PEARL_RELEASE_IDENTITY_GROUP=macprovider
PEARL_INSTALL_ROOT=/opt/macprovider PEARL_BACKUP_ROOT=/root/macprovider-backups
PEARL_CONFIG_GUARD=/usr/local/share/macprovider/scripts/coordinator_config_guard.py
PEARL_UPDATER_LOCK=/run/lock/macprovider-pearl-updater.lock
PEARL_CONNECTION_EVENTS_DB=/var/lib/macprovider/provider_connection_events.db
PEARL_COORDINATOR_HEALTHZ_URL=http://127.0.0.1:8444/healthz  # provider listener; :8443 lacks the policy
PEARL_PRIVACY_METADATA_DIR=/opt/macprovider/privacy-release-identities
PEARL_RELEASE_PUBLIC_KEY_PATH=/usr/local/share/macprovider/release-signing-public.pem
```

When a script needs ssh and its variable is unset, it fails and names the
variable.

## Release-train status lines

`release-train-status.sh` prints the "Current published release and fleet
target" and "Active candidate" sections of `docs/releases/cli-release-train.md`
from GitHub and `/healthz` (plus `MIRROR_LATEST_URL` when set). Paste its
output over those sections instead of typing status by hand.
