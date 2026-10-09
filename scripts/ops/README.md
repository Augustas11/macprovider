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
  step changed while it waited, it refuses. The lock stays held until you
  release it, because a train spans several steps.
- Runbook commands are never read from the Markdown at run time. They are
  constants in `lib/runbook-commands.sh`; `test-runbook-commands.sh` fails when
  one drifts from its fenced block on `origin/main`.
- `cli-release.sh` registers each new CLI on Pearl before it can be
  promoted. The operator-owned `privacy_release_setup` step prints the
  one-time Pearl setup while Pearl has no privacy release metadata dir. Step
  `privacy_release_identity` stages the verified `pearl-release.json` as
  `v<ver>.json` there (hot, no restart). The read-only `registrations` gate,
  evaluated on every status, requires the running coordinator to hold the
  registrations (loaded-identity metric, boot config digests) and gates the
  canary, promotion, the recommendation bump and rollout verification.
  `canary_smoke --probe` also fails on a privacy rejection of the canary in
  Pearl's journal. `verify_live_rollout` runs `_check-privacy-rejections`
  first: two samples of the unapproved-rejection counter over a window
  (`PRIVACY_REJECTION_WINDOW_SECONDS`, default 180).
- `cli-release.sh` step `release_tag`, just before `promotion`, creates the
  signed annotated `v<ver>` tag on the verified candidate SHA with the
  operator's git signing key, checks it with `git verify-tag`, and pushes it;
  the promotion workflow requires that tag to exist. It is done when origin's
  `v<ver>` is annotated, peels to the candidate SHA and its exact remote tag
  object passes `git verify-tag`; it refuses an unsigned, untrusted,
  lightweight or other-commit `v<ver>`.
- Steps the operator owns are `manual`: an environment approval click, a
  Pearl `coordinator.yaml` edit, or a provider restart. `next` prints the
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
```

When a script needs ssh and its variable is unset, it fails and names the
variable.

## Release-train status lines

`release-train-status.sh` prints the "Current published release and fleet
target" and "Active candidate" sections of `docs/releases/cli-release-train.md`
from GitHub and `/healthz` (plus `MIRROR_LATEST_URL` when set). Paste its
output over those sections instead of typing status by hand.
