# Ops entry points

Agents run these scripts for live work. They do not assemble release, deploy or
restart commands by hand. Each script encodes the order of its runbook and does
not add steps of its own:

| Script | Train | Runbooks |
|---|---|---|
| `cli-release.sh` | provider CLI candidate, promotion, fleet recommendation | `docs/releases/cli-release-train.md`, `docs/runbooks/provider-cli-release-verification.md` |
| `discovery-renew.sh` | signed release-discovery freshness renewal | `.github/workflows/renew-release-discovery-head.yml` |
| `catalog-activate.sh` | catalog, CB policy and native-MTP activation; buyer-UX conformance records (step `buyer_ux_conformance`: origin/main's record file installed on Pearl, `routing.buyer_ux_conformance_path` added in place under both Pearl locks, one SIGHUP, or one restart on a runtime that reads the file only at start) | `docs/runbooks/native-mtp-enablement.md`, `docs/runbooks/catalog-release-decision-tree.md`, `docs/runbooks/pearl-coordinator-rollout.md` |
| `pearl-runtime.sh` | coordinator and gateway runtime release; runtime train `apply` (preflight, disk check against the live databases with WAL plus max(10%, 5 GB), pending stats migrations, updater; states about 1-2 min when the candidate keeps the installed database schema fingerprint, otherwise buyers held with 503 up to about 25 min) then `health` (waits for the updater, checks both `/healthz` and the buyer hold, applies the new binary's stats migrations, prints the measured apply and buyer-visible downtime as a release-train line); `release_buyer_hold` first whenever the gateway reports `buyer_hold` with no updater unit active (runs the updater's `--reconcile`, then requires no hold); pending stats migrations (`stats_migrate`: read before the apply and applied inside `apply` and `health`, offered on their own only once the release is otherwise live; live-ops lock, no downtime); one-time retention `auto_vacuum` conversion (`PEARL_RUNTIME_TASK=retention-vacuum-conversion`); one on-demand retention run (`PEARL_RUNTIME_TASK=retention-run`, no restart); compute-integrity private corpus install (`PEARL_RUNTIME_TASK=compute-integrity-enable`, one restart); compute-integrity reference scorers in the Pearl overlay (`PEARL_RUNTIME_TASK=compute-integrity-reference-operators`, `COMPUTE_INTEGRITY_REFERENCE_OPERATORS`, one restart); operator-reviewed native-vision qualification install into the Pearl overlay (`PEARL_RUNTIME_TASK=vision-qualification`, `VISION_QUALIFICATION_FILE`, one restart as the boot-state proof; SIGHUP also applies the list); Pearl updater bundle install from the running tag (`PEARL_RUNTIME_TASK=updater-bundle`, both Pearl locks, no restart); one-time raise of the streaming walls Pearl preserves live (`PEARL_RUNTIME_TASK=stream-ceiling`: coordinator `request_timeout_s`/`provider_http.timeout_s` and gateway ceiling 3600 s, non-streaming wall 3660 s; raise-only, one coordinator then one gateway restart) | `docs/runbooks/pearl-coordinator-rollout.md`, `ops/runbooks/settlement-evidence-retention.md`, `docs/runbooks/compute-integrity-private-corpus.md`, `docs/runbooks/native-vision-acceptance.md`, `docs/runbooks/catalog-release-decision-tree.md` (Enabling rollout) |
| `canary-swap.sh` | CLI candidate onto the canary provider: `check` (MLX kernels in every shipped metallib, verified binary, baked `catalog-release/` equal to the catalog Pearl serves at `COORDINATOR_URL`) then `swap` (pause, drain, back up, payload-only swap, resume; the watchdog stays booted out until the candidate, or the restored version, is buyer_serving; a crash loop, or `/v1/status` silent for 120 s counted only from when the candidate reported its model loaded, restores the backup and resumes (exit 5); silence while the model loads is bounded only by the 1800 s ready timeout; exit 6 means that recovery did not complete and the operator must restore the canary) | `docs/releases/cli-release-train.md` (Promotion gate item 5) |
| `qwen-opencode-e2e.sh` | version-bound, same-provider live-gateway acceptance for the two qualified Qwen models; restores the incumbent from a secret-free crash journal | this README (`Qwen OpenCode acceptance`) |
| `studio-lab-window.sh` | bounded offline Studio diagnostic, profiler-only or full-matrix qualification job with fixed reviewed arguments and immutable-input completion identity; published-provider authentication, journal-first pause/drain, exact process/watchdog restoration and durable controller-loss recovery while the buyer runner remains active | `docs/runbooks/studio-lab-window.md` |
| `studio-lab-handoff.py` | recovery-only restoration of the retained `paused_live_unloaded` Studio handoff from an explicit private all-cells-complete, root-armed, hash-pinned manifest; verifies the original signed provider for 120 seconds before it starts only the stopped buyer runner, and retains both handoff and campaign lock | private handoff record |
| `live-lock.sh` | one live actor at a time | rollout rule 3 |
| `privacy-activate.sh` | existing signed identity approval; durable rollback | `docs/runbooks/privacy-network-activation.md`, SPEC-049 §8.3 |

Tests (offline): `test-ops-guard.sh`, `test-live-lock.sh`,
`test-runbook-commands.sh`, `test-entrypoints.sh`, `test-canary-swap.sh`,
`test-studio-lab-window-controller.sh`, `test-studio-lab-handoff.py`.

## Use

```bash
scripts/ops/<train>.sh status        # read-only: JSON on stdout, summary on stderr
scripts/ops/<train>.sh next          # the exact command for the next step
MACPROVIDER_OPS_OWNER=<session-label> scripts/ops/<train>.sh next --run
scripts/ops/<train>.sh next --done <step> --evidence '<proof>'   # operator-owned steps only
scripts/ops/cli-release.sh next --done canary_smoke --probe      # structured evidence only
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
  is covered by the `health` step, which waits for the unit before anything
  else, not by the lock. The lock
  is pid-bound (`--bind-pid`): if the process that took it dies without
  releasing (SIGKILL, crash), the next `acquire` on the same host takes it
  over and logs the holder. Locks taken by hand keep TTL and `--steal` only.
- `catalog-activate.sh` refuses the activation while the canary provider
  reports `lifecycle.state` `paused_by_operator` or its status is unreadable:
  the custody proof needs it `buyer_serving`, and the activation restarts it,
  which a pause outlives. The read-only preflight is offered anyway, with the
  pause as a note. A pricing-only release (verdict `pricing_only: true`: only
  credit rates of existing rate-card rows moved) needs no canary and
  activates while it is paused or down. A NO_GO names its failing checks. A pricing release runs
  only with `CATALOG_PRICING_ACK` set to the verdict's `pricing_diff_sha256`
  after the operator reviewed the price table. A release whose newly
  buyer-serving model no connected provider serves activates with evidence
  (e) owed (SPEC-023-R017 5(e)); the activation records it and the train
  keeps a post-activation `buyer_serving_e2e` step (a ledger entry per model
  that outlives later releases) until the operator records a buyer request
  attributed to the serving canary and its settlement row, naming the model.
  `PEARL_RUNTIME_TASK=updater-bundle` installs only origin's signed running
  tag that is on `origin/main`, verifies every installer-managed file, and is
  done once that install is recorded.
- Catalog activation comes before the CLI cut. A candidate bakes `origin/main`'s
  catalog release; `cli-release.sh` keeps `candidate_cut` blocked (NEXT
  `catalog-activate.sh status`) until Pearl's `/v1/autotune-release` reports
  it, and `canary-swap.sh` refuses (exit 3) a candidate whose baked catalog
  Pearl does not serve. There is no exception: native-MTP admission needs no
  cut and no rebind (SPEC-048 0.1.81), so a new tuple's admission activates
  first like any catalog change. `canary-swap.sh` accepts a live release
  strictly newer than the baked one with the same policy and rate-card
  content, and still refuses one older. CI runs the preflight's offline pricing checks
  (`scripts/catalog-pricing-preflight.py` in `make test-dist-catalog`: an
  unacknowledged rate-row move, `dist/coordinator.yaml` rate-card parity), so
  a catalog PR that `catalog-activate.sh` would refuse fails before merge.
- For a qualified CB-only model, set `PROBE_MODEL` to its exact catalog ID and
  `CATALOG_REQUIRE_NATIVE_MTP_FORWARD=false` explicitly. The live probe requires
  active CB, not absent native-MTP heads; the paid gateway proof must still move
  the target provider's CB shared-forward counter. An unset value preserves the
  historical native-MTP live probe, and `true` requires native-forward movement.
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
- Revoked-build rollback (SPEC-020-R007): with `CLI_ROLLBACK_TO_ID` (the
  previous good release's compatibility id) and `CLI_ROLLBACK_REVOKE_ID` (the
  bad release's) set, `cli-release.sh` replaces the train with one `rollback`
  step whose `next --run` recommends the previous release and revokes the bad
  one in one Pearl edit and restart. Procedure and timing:
  `docs/runbooks/provider-cli-release-verification.md` "Revoked-build rollback".
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
  Pearl's journal. It accepts a canary whose CB self-check is still
  `prior_grant_pending_recheck` when the prior grant serves (`served_slots`
  > 0, CB active) and records the pending re-check; the provider runs that
  re-check under a bounded admission hold (SPEC-038 FR-CB10), so no buyer
  traffic has to be stopped. A canary serving a model that has no entry in the
  candidate's signed CB policy (DeepSeek V4, #2134) passes with CB off and
  serial decode when its signed policy is `live_verified` for the candidate's
  release; a model with an entry still needs CB active. The next step, `canary_self_check`
  (`_check-canary-self-check`), then requires the same canary (provider,
  version, compatibility set, self-check key) to report the final `granted`
  or kept-prior-grant decision with the admission hold ended; promotion waits
  for it. `verify_live_rollout` runs `_check-privacy-rejections` first:
  two samples of the unapproved-rejection counter over a window
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
  `scripts/publish-release-mirror.sh --tag v<ver> --latest-only`: the promotion
  workflow normally mirrored the assets, so when Pearl already holds GitHub's
  exact asset set, the updater index and the pinned bootstrap python it moves
  only the pointer; otherwise (that workflow step is continue-on-error) it runs
  the full `--promote-latest` path in the same run. It refuses a tag the
  coordinator does not advertise and never moves the pointer backwards. It is blocked until `MALIBU_DOWNLOAD_SSH_KEY` is set; `GH_TOKEN`
  defaults to the repo's `gh` login. Runbook:
  `docs/runbooks/provider-cli-release-verification.md#release-mirror-byte-identity-downloadmalibutech-1737`.
- `cli-release.sh` step `install_sh_republish`, right after `promotion`, is
  runnable: `next --run` (`_install-sh-republish`) backs up the served
  `install.sh` at `INSTALL_SH_REMOTE_PATH` over `PEARL_SSH` and renames the
  release's `phase3-binary/dist/install.sh` into place from a sibling temp
  file (owner `PEARL_INSTALL_SH_OWNER` / `PEARL_INSTALL_SH_GROUP`, default
  root, mode 0755). It refuses unless the local tag `v<ver>` names the commit
  origin's tag names, and unless the installed file's SHA-256 read back equals
  the release's; it then runs the read-only
  `scripts/check-install-sh-consumer-health.sh` and fails the step if that
  fails. Consumer health is not a separate train step; the scheduled
  `install-sh-consumer-health-alarm.yml` still runs.
- `cli-release.sh` step `version_staging` opens the next cut's version-only
  staging PR once a train is complete and `main` carries provider-side
  changes (outside `phase3-binary/catalog/`) since the published tag; the
  same command is offered at `version_alignment` when `binaryVersion` is not
  above live stable. `next --run` (`_stage-version`) takes the next patch
  above live stable and every `v*` tag on origin (Pearl runtime tags share
  the namespace), sets `binaryVersion` to it and the three
  `latest_binary_version` rows to live stable in a fresh sibling worktree,
  checks the tree with `release-staged-version-policy.sh`, pushes
  `release/stage-cli-<ver>` and opens the PR "Stage provider CLI <ver>". It
  refuses while such a PR is open, when `gh pr list` fails, or when `main`
  already carries the version, and it never merges. A failure before the push
  removes its worktree and local branch; if `gh pr create` fails after the
  push, the refusal prints the exact `gh pr create` command to run. When
  origin/main or the published tag is not in the local clone the step is
  blocked on `git fetch origin --tags`.
- Steps the operator owns are `manual`: an environment approval click or a
  provider restart. `next` prints the
  documented command and `next --run` refuses. When the step is done, record
  it with `next --done`. `canary_smoke` refuses free text: it takes a canary
  status probe the script reads itself. Promotion sets
  `physical_acceptance_confirmed=true` only after it. There is no separate
  per-cut e2e step: the canary probe's paid gateway request is the cut's
  end-to-end check, and a change that needs more is qualified on its lab
  build in its PR window. A few other steps
  leave no trace that can be read live, such as the signed-byte verification
  and the gateway proof (which must move the target provider's counters and
  expires after 24 h). Their completion is kept under
  `~/.config/macprovider/ops-state/`.
- Every step command runs with `MACPROVIDER_OPS_ENTRYPOINT=1` exported. The
  guard in `hooks/` blocks the guarded commands when an agent types them
  directly. It allows them when that marker is set in the environment the
  guard itself runs in.

## Buyer runner reservation (Studio target)

The Pearl buyer runner keeps every CB row of the Studio canary busy, so a
proof request beside it finds no idle capacity (1.8.280: native MTP routed
ordinary, `no_provider_available`, CB self-check deferred). `lib/runner-reserve.sh`
pauses only the Studio target; the runner service is never stopped:

```bash
MACPROVIDER_OPS_OWNER=<label> scripts/ops/lib/runner-reserve.sh with-studio-paused -- <cmd>
MACPROVIDER_OPS_OWNER=<label> scripts/ops/lib/runner-reserve.sh pause-studio | restore
scripts/ops/lib/runner-reserve.sh status
```

- Pause removes the one row whose `provider_id` starts with
  `RUNNER_STUDIO_PROVIDER_PREFIX` from `targets.json`, keeps the exact bytes as
  `targets.json.bak-runner-reserve-<UTC>` next to it, records the reservation
  under `PEARL_RUNNER_RESERVE_DIR` and restarts the runner (its other targets
  keep traffic). Restore writes the backup bytes back and restarts once more.
- `with-studio-paused` restores on every exit of the command, on its failure
  and on INT/TERM/HUP. `restore` with nothing outstanding changes nothing. A
  reservation held by another owner is refused, never taken over; a restore
  that cannot restart the runner keeps the reservation and says so.
- `catalog-activate.sh` `gateway_proof` (the ordinary one-request proof) runs as
  a mutate step under the live-ops lock: `_gateway-proof --reserve-runner`
  pauses the Studio target, waits for the canary's `requests_in_flight` to reach
  0 (`CATALOG_PROOF_DRAIN_S`, default 600), probes, and restores. The step is
  blocked while `RUNNER_STUDIO_PROVIDER_PREFIX` is unset.
- Settings (ops.env): `RUNNER_STUDIO_PROVIDER_PREFIX=<Studio provider_id prefix>`
  (`none` when no buyer runner feeds the canary), `PEARL_RUNNER_TARGETS`
  (default `/opt/malibu-buyer-runner/targets.json`), `PEARL_RUNNER_RESERVE_DIR`
  (default `/var/lib/macprovider-ops`).

## Canary model switch

```bash
MACPROVIDER_OPS_OWNER=<label> scripts/ops/canary-swap.sh switch-model <catalog-key> [--artifact-path DIR]
```

Serves another signed catalog row on the canary (`macprovider-cli models
switch` refuses a catalog key, and two ~175 GB models cannot be warm swapped).
It prints the expected downtime first: the canary restarts and loads the new
model; the Pearl buyer runner restarts once; the coordinator is not restarted.

- The row (model id, revision, sha256, catalog version and digest) comes from
  `phase3-binary/dist/static/autotune-candidates.json` in this checkout. The
  canary's `models verify-artifact <key> --json` must exit 0 and agree with it,
  so download and verify the artifact there first.
- Under the live-ops lock, `lib/canary-switch-model.py` backs up `config.yaml`
  (`config.yaml.bak-switch-model-<UTC>`) and rewrites all nine identity fields
  (`model`, `model_artifact_path`, `model_artifact_sha256`, `model_catalog_key`,
  `model_catalog_model_id`, `model_catalog_revision`, `model_catalog_sha256`,
  `model_catalog_version`, `model_catalog_hash`) in one atomic write that the
  installed CLI validates. A config missing any field is refused, not appended.
- It kickstarts the provider, waits up to `CANARY_READY_TIMEOUT_S` for
  `/v1/status` `buyer_serving` with the new model and sha256, then sets the
  runner's Studio target `model` to the row's model id. A timeout restores
  nothing: it exits 6 and names the backup and the `switch-model <previous key>`
  that goes back. A rerun once the canary serves the key only retargets the runner.

## Qwen OpenCode acceptance

`qwen-opencode-e2e.sh` starts only after its private written handoff records
that the Studio is released by its prior owner (or that the released version's
owner pin was removed). Its first `next --run` derives a local binding record
from the running signed CLI: version, byte digest, signing identity and provider
identity. The handoff's author does not create that JSON record.

The campaign runs OpenCode and the gateway recorder on the Studio, streams the
buyer credential over SSH stdin, and keeps only sanitized results locally. It
uses a fresh protected remote scratch directory for reviewed recorder and
recommendation bytes. Before changing the incumbent config it arms a durable,
secret-free journal containing only owned config fields and release/status
bindings. `status` always selects restoration first when that journal is
unfinished, even if the provider is stopped or the public market endpoints are
unavailable. No expiry or automatic feature withdrawal is part of the flow.

Recovery can kickstart a loaded LaunchAgent even when it has no current PID,
after checking its installed plist and loaded executable/config identity.
An absent or mismatched job is refused. Serving readiness is checked separately;
a successful kickstart alone does not mark restoration complete.

Before each client run, the controller binds the incumbent provider's public
receipt-key fingerprint and the exact qualified artifact to the coordinator's
active attestation catalog. Every verified terminal receipt must match those
identities, not merely the model label. A different provider cannot satisfy
same-provider acceptance. Credential echoes are rejected before evidence is
retained, including failure evidence.

Configure the following untracked values, then use the standard `status`,
`next`, `next --run` sequence:

```bash
QWEN_E2E_WRITTEN_HANDBACK=<private shared handoff file>
QWEN_E2E_HANDBACK=<local generated binding record>
QWEN_E2E_CLI=<absolute signed CLI path on Studio>
QWEN_E2E_CONFIG=<absolute incumbent config path on Studio>
QWEN_E2E_JOURNAL=<absolute durable journal path on Studio>
QWEN_E2E_OPENCODE=<absolute OpenCode 1.17.9 path on Studio>
BUYER_TOKEN_FILE=<local owner-only buyer key file>
```

`diagnostic` is the non-live prepare/restore check. It accepts only an explicit
config, journal and validator below the system temporary directory and does not
claim gateway acceptance.

### Qwen3.6 native-MTP catalog proof

For a qualified Qwen3.6 admission, configure `PROBE_MODEL=qwen/qwen3.6-35b-a3b`
and `CATALOG_REQUIRE_NATIVE_MTP_FORWARD=true`, then use
`catalog-activate.sh status`, `next`, and `next --run`. The catalog controller
owns the live lock and invokes a fixed single-model transaction internally.
It verifies the running published signed binary against the committed admission
release input: for a decode-path admission (SPEC-048 0.1.51) the binary's
`/v1/status` `build_identity.decode_path_digest` must equal the input's
`provider_decode_path_digest`, so a later CLI cut with the same decode path
needs no rebind; an old-format input still needs the exact SHA-256 and CDHash.
It then adopts the exact Qwen artifact, requires native MTP and continuous
batching readiness, sends the paid proof, and restores the signed GLM incumbent.
The Qwen journal/config/CLI settings above still apply; OpenCode is not used by
this profile. Recommendations must support at least 4096 context tokens.

Interrupted native-MTP transactions recover through the catalog controller.
Their protected journal freezes the installed release identity; restoration
does not depend on a later catalog version or a network release lookup. The
durable lock remains held until exact incumbent restoration and protected
scratch cleanup are confirmed. A completed offline journey or merged catalog
change does not replace the attributed paid request and positive MTP-forward
delta required for live acceptance.

### Signed native pair plan

Generate `CATALOG_SIGNED_PAIR_PLAN` instead of editing a copy by hand.
`lib/signed-pair-plan.py build --template <previous plan> --model-key <key>
--previous-window-sha256 <sha> [--local-tarball <target tarball>] --out <plan>`
derives the target release id, every feed digest, the CB policy and tuple
digests and the model hash from `phase3-binary/dist/static`, takes the Studio,
receipt-reader and prior identity from the template, and writes a fresh
transaction ID, a deadline inside the arm window and mode 0600. A new binary
version must supply its own identity (`--local-tarball` plus flags); it never
inherits the template's. Run `lib/signed-pair-plan.py check --plan <plan>
--expect-model-key <goal model> --existing-release-ids <Pearl releases/ listing>`
right before `next --run`: it names every failed check (feed and CB tuple
digests, admission, projection and CB policy coverage, model key, existing
release directory, deadline, file mode) and runs the root, intent, transport
and Studio validators the transaction uses. The arm window is 30 to 60
minutes ahead, so with the default `--deadline-seconds 3300` a plan stays
usable for 25 minutes after `build`. While the Studio waits for readiness it
prints the failing check with observed and expected values, and `readiness
deadline exceeded` names the last one.

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
MALIBU_DOWNLOAD_VPS_HOST=<release mirror host address>  # scripts/publish-*.sh
VPS_HOST=<coordinator VPS address>               # dist/deploy-*.sh and tier2 activation scripts
PEARL_SSH=<ssh alias for the coordinator host>   # configure identity/known_hosts in ~/.ssh/config
PEARL_SSH_IDENTITY=<optional key file>           # used by the repo scripts that the steps call
PEARL_SSH_KNOWN_HOSTS=<optional pinned known_hosts>
REMOTE_REVOCATION_DIR=<native-MTP revocation root on the coordinator host>
STUDIO_SSH=<ssh alias for the canary Mac, or "local" when the canary provider runs on this Mac>
STUDIO_SSH_KEY=<optional key file>
STUDIO_STATUS_PORT=<provider local status port>
STUDIO_OWNER_PIN_INSTALL_DIR=<absolute Studio provider install directory>
STUDIO_OWNER_PIN_CONFIG=<absolute Studio provider config path>
STUDIO_OWNER_PIN_JOURNAL=<absolute durable Studio transaction journal path>
BUYER_TOKEN_FILE=<file holding a buyer API key>  # gateway proof only
PROBE_MODEL=<model id>                           # default: the model the canary's /v1/status reports
PEARL_COORDINATOR_DB=<coordinator database path on the coordinator host>  # gateway proof reads request_log (buyers get no provider id)
CATALOG_CANARY_PROVIDER_ID=...                   # as scripts/catalog-content-release.sh
PEARL_RUNTIME_VERSION=v<x.y.z>                   # pearl-runtime.sh target tag
# cli-release.sh Pearl layout; the defaults are the production paths:
PEARL_COORDINATOR_CONFIG=/opt/macprovider/coordinator.yaml
PEARL_COORDINATOR_OVERLAY=/etc/macprovider/coordinator.pearl-overlays.yaml
PEARL_COORDINATOR_UNIT=macprovider-coordinator
PEARL_COORDINATOR_ENV=/etc/macprovider/coordinator.env     # pearl-runtime.sh recorder and stats_migrate
PEARL_COORDINATOR_BIN=/opt/macprovider/coordinator         # pearl-runtime.sh stats_migrate
PEARL_UPDATER_STATE_ROOT=/var/lib/macprovider-pearl-updater # pearl-runtime.sh schema-change and audit reads
PEARL_COORDINATOR_METRICS_URL=http://127.0.0.1:8444/metrics
PEARL_RELEASE_IDENTITY_OWNER=root PEARL_RELEASE_IDENTITY_GROUP=macprovider
PEARL_INSTALL_ROOT=/opt/macprovider PEARL_BACKUP_ROOT=/root/macprovider-backups
PEARL_CONFIG_GUARD=/usr/local/share/macprovider/scripts/coordinator_config_guard.py
PEARL_UPDATER_LOCK=/run/lock/macprovider-pearl-updater.lock
PEARL_CONNECTION_EVENTS_DB=/var/lib/macprovider/provider_connection_events.db
PEARL_COORDINATOR_HEALTHZ_URL=http://127.0.0.1:8444/healthz  # provider listener; :8443 lacks the policy
PEARL_PRIVACY_METADATA_DIR=/opt/macprovider/privacy-release-identities
PEARL_RELEASE_PUBLIC_KEY_PATH=/usr/local/share/macprovider/release-signing-public.pem
PEARL_BUYER_UX_CONFORMANCE_PATH=/opt/macprovider/buyer-ux-conformance.json  # catalog-activate.sh buyer_ux_conformance
```

When a script needs ssh and its variable is unset, it fails and names the
variable.

## Release-train status lines

`release-train-status.sh` prints the "Current published release and fleet
target" and "Active candidate" sections of `docs/releases/cli-release-train.md`
as Markdown from GitHub and the public `/healthz` (plus `MIRROR_LATEST_URL`
when set). It needs no ssh. Paste its output over those sections instead of
typing status by hand.

## Hotfix pushes to main

`hotfix-push.sh` pushes a small tooling, test or catalog-data fix straight to
`main` only after the fast suites that cover the touched paths pass (728f0f0b3
broke `test_native_mtp_admission_sidecar.py` unseen because the main CI run was
cancelled). It plans from `origin/main..HEAD`, runs the suites, pushes
`HEAD:main`, and with `--cancel-ci` cancels the main CI run for the pushed SHA.

```bash
scripts/ops/hotfix-push.sh --dry-run      # paths, refusals and suites only
scripts/ops/hotfix-push.sh --cancel-ci    # run suites, push, cancel the main run
```

It refuses a dirty tree (untracked files included), a HEAD that is not a
fast-forward of `origin/main`, a local `main` that is neither, merge commits,
and any path AGENTS.md "Git Workflow" sends through a PR: Swift and app code,
the SwiftPM pins, `dist/install.sh`, Go, `coordinator.yaml`,
`.github/workflows`, `specs/SPEC-*.md`, `AUTHORITY.json` and
`CONFORMANCE.json`. Docs (`*.md` outside `specs/`) never need a PR. The
path-to-suite rules are in the script header; the PR-only list is its `PR_ONLY` table.
Test: `test-hotfix-push.sh`.
