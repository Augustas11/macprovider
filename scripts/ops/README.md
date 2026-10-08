# Ops entry points

Agents run these scripts for live work. They do not assemble release, deploy or
restart commands by hand. Each script encodes the order of its runbook and does
not add steps of its own:

| Script | Train | Runbooks |
|---|---|---|
| `cli-release.sh` | provider CLI candidate, promotion, fleet recommendation | `docs/releases/cli-release-train.md`, `docs/runbooks/provider-cli-release-verification.md` |
| `catalog-activate.sh` | catalog, CB policy and native-MTP activation | `docs/runbooks/native-mtp-enablement.md`, `docs/runbooks/catalog-release-decision-tree.md`, `docs/runbooks/pearl-coordinator-rollout.md` |
| `pearl-runtime.sh` | coordinator and gateway runtime release | `docs/runbooks/pearl-coordinator-rollout.md` |
| `live-lock.sh` | one live actor at a time | rollout rule 3 |

## Use

```bash
scripts/ops/<train>.sh status        # read-only: JSON on stdout, summary on stderr
scripts/ops/<train>.sh next          # the exact command for the next step
MACPROVIDER_OPS_OWNER=<session-label> scripts/ops/<train>.sh next --run
scripts/ops/<train>.sh next --done <step> --evidence '<proof>'   # operator-owned steps only
scripts/ops/live-lock.sh release <session-label>                 # hand back when done
```

- `status` reads live state from GitHub, public HTTPS, and read-only ssh when
  it is configured. It never mutates anything.
- `next --run` runs one step and then stops. It refuses when a precondition
  fails, and it refuses a second dispatch while a run for the same version is
  in flight. For any step that mutates Pearl, it prints the expected downtime
  before it does anything else. A mutating step takes the live-ops lock first.
  The lock stays held until you release it, because a train spans several
  steps.
- Steps the operator owns are `manual`: an environment approval click, a
  Pearl `coordinator.yaml` edit, or a provider restart. `next` prints the
  documented command and `next --run` refuses. When the step is done, record
  it with `next --done`. A few other steps leave no trace that can be read
  live, such as the signed-byte verification and the gateway proof. Their
  completion is kept under `~/.config/macprovider/ops-state/`.
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
```

When a script needs ssh and its variable is unset, it fails and names the
variable.
