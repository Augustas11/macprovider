# Ops entry points

Agents run these scripts for live work. They do not assemble release, deploy or
restart commands by hand. Each script encodes the order of its runbook and does
not add steps of its own:

| Script | Train | Runbooks |
|---|---|---|
| `cli-release.sh` | provider CLI candidate, promotion, fleet recommendation | `docs/releases/cli-release-train.md`, `docs/runbooks/provider-cli-release-verification.md` |
| `discovery-renew.sh` | signed release-discovery freshness renewal | `.github/workflows/renew-release-discovery-head.yml` |
| `catalog-activate.sh` | catalog, CB policy and native-MTP activation; buyer-UX conformance records (step `buyer_ux_conformance`: origin/main's record file installed on Pearl, `routing.buyer_ux_conformance_path` added in place under both Pearl locks, one SIGHUP, or one restart on a runtime that reads the file only at start) | `docs/runbooks/native-mtp-enablement.md`, `docs/runbooks/catalog-release-decision-tree.md`, `docs/runbooks/pearl-coordinator-rollout.md` |
| `pearl-runtime.sh` | coordinator and gateway runtime release; pending stats migrations (`stats_migrate`: checked before the apply and before health, applied under the live-ops lock, no downtime); one-time retention `auto_vacuum` conversion (`PEARL_RUNTIME_TASK=retention-vacuum-conversion`); one on-demand retention run (`PEARL_RUNTIME_TASK=retention-run`, no restart); compute-integrity private corpus install (`PEARL_RUNTIME_TASK=compute-integrity-enable`, one restart); operator-reviewed native-vision qualification install into the Pearl overlay (`PEARL_RUNTIME_TASK=vision-qualification`, `VISION_QUALIFICATION_FILE`, one restart as the boot-state proof; SIGHUP also applies the list); Pearl updater bundle install from the running tag (`PEARL_RUNTIME_TASK=updater-bundle`, both Pearl locks, no restart) | `docs/runbooks/pearl-coordinator-rollout.md`, `ops/runbooks/settlement-evidence-retention.md`, `docs/runbooks/compute-integrity-private-corpus.md`, `docs/runbooks/native-vision-acceptance.md`, `docs/runbooks/catalog-release-decision-tree.md` (Enabling rollout) |
| `canary-swap.sh` | CLI candidate onto the canary provider: `check` (MLX kernels in every shipped metallib, verified binary, baked `catalog-release/` equal to the catalog Pearl serves at `COORDINATOR_URL`) then `swap` (pause, drain, back up, payload-only swap, resume; the watchdog stays booted out until the candidate, or the restored version, is buyer_serving; a crash loop, or `/v1/status` silent for 120 s after the model loaded, restores the backup and resumes; silence while the model loads is bounded only by the 1800 s ready timeout) | `docs/releases/cli-release-train.md` (Promotion gate item 5) |
| `qwen-opencode-e2e.sh` | version-bound, same-provider live-gateway acceptance for the two qualified Qwen models; restores the incumbent from a secret-free crash journal | this README (`Qwen OpenCode acceptance`) |
| `air-provider.sh` | designated disconnected Air: signed 1.8.258 recovery to released 1.8.260, persistent signed-catalog Qwen3-8B adoption, four-slot paid proof and enrollment in the running buyer runner | this README (`Air recovery and adoption`) |
| `studio-owner-pin.sh` | one-time removal of the Studio GLM provider's `4/owner` concurrency pin after authenticating the published signed CLI >= 1.8.260, its checksummed artifact, exact LaunchAgent/process identity and a live-verified tuple matching the reviewed four-slot policy bytes; journal-first scoped rollback, watchdog restoration, 20-minute readiness bound, accepted-PID/crash hold and provider-attributed native-MTP gateway proof | `docs/releases/cli-release-train.md` |
| `studio-lab-window.sh` | bounded offline Studio diagnostic, profiler-only or full-matrix qualification job with fixed reviewed arguments and immutable-input completion identity; published-provider authentication, journal-first pause/drain, exact process/watchdog restoration and durable controller-loss recovery while the buyer runner remains active | `docs/runbooks/studio-lab-window.md` |
| `live-lock.sh` | one live actor at a time | rollout rule 3 |
| `privacy-activate.sh` | existing signed identity approval; durable rollback | `docs/runbooks/privacy-network-activation.md`, SPEC-049 §8.3 |

Tests (offline): `test-ops-guard.sh`, `test-live-lock.sh`,
`test-runbook-commands.sh`, `test-entrypoints.sh`, `test-canary-swap.sh`,
`test-studio-owner-pin.sh`, `test-studio-owner-pin-provenance.sh`,
`test-studio-lab-window-controller.sh`.

## Air recovery and adoption

This bounded operation unblocks the disconnected Air and missing persistent
Qwen3-8B adoption step; it is not a general fleet model-adoption interface.
Run `air-provider.sh status`, then `air-provider.sh next --run`, with the private
`MACPROVIDER_OPS_ENV` profile and normal named live-ops owner. Each invocation
performs one selected recovery, adoption or runner-enrollment step.

The private profile binds `AIR_SSH`, optional `AIR_SSH_KEY`, `AIR_INSTALL_DIR`,
`AIR_CONFIG`, `AIR_JOURNAL`, `AIR_STATUS_PORT`, `AIR_PROVIDER_SHA256` and the real
written `AIR_HANDOFF_SHA256`. Hardware is fixed to the reviewed M3 Air identity;
the private provider digest additionally prevents applying this to another Mac.
The ordinary clean-main, signed-release verification and live-lock gates apply.
Nested proof commands retain this exact target rather than reloading Studio
defaults. No locally built binary is accepted.

Recovery, adoption and restoration take the fixed designated-Air provider lock
(`~/.config/macprovider/provider-admin-air-m3.lock`), not the shared
Studio/Pearl lock: these steps do not mutate Pearl or the Studio. A Studio
campaign can therefore continue independently. There is no selectable lock
scope. Nested payload swaps take a subordinate `.payload` lock while the
parent retains the provider lock through completion and failure recovery;
nested cleanup cannot release the parent or the shared campaign lock. Ordinary
canary operations retain their existing shared-lock behavior. The paid gateway
proof targets the Air and neither stops nor reconfigures the buyer runner. Its
catalog proof markers use a private ephemeral Air namespace, never the shared
catalog campaign's acceptance markers; the proof output digest is retained in
the Air adoption journal.
Runner enrollment takes both the provider lock and the normal shared live-ops
lock, and refuses while another Studio/Pearl campaign owns the latter. Exit or
failure releases only locks acquired by this controller, including partial
acquisition; it never releases another campaign's lock.

Recovery requires the exact signed 1.8.258 incumbent, disconnected with zero
in-flight work and no operator pause. It reuses the verified 1.8.260 archive and
detached canary swap, with an authenticated durable backup record for explicit
interrupted-swap restoration. The original payload/config digests must match;
missing or modified recovery data fails closed. The restored disconnected
incumbent is not reported as buyer-ready.

Adoption uses released `models prepare-catalog` to verify/reuse or download the
artifact and a genuine installed-only, check-only recommendation (no benchmark).
The config journal validates and owns only the model/allowlist/warm-swap fields
and the qualified 512 MiB MLX cache setting. Released `provider context set`
preflights and applies the qualified 8192-token context under an armed journal
intent. Once the actual released process reports the exact signed Air tuple
with `verified_k >= 4`, the operator-requested four slots are selected through
a validated journaled `max_concurrency_source: owner` setting (SPEC-038 FR-CB11).
The measured preferred count remains distinct and is recorded, not rewritten;
no recommendation or self-check record is manufactured. After restart, the
new signed process must still report verified, served, scheduler and capacity
counts of four before paid proof or enrollment. Failure restores the incumbent
configuration; interruption selects journal restoration before new adoption.

A provider-attributed paid gateway proof and unchanged signed process identity
are required before committing the target. Only then is its identity read from
the Air and enrolled at four slots through the runner's atomic/CAS journal.
The fleet runner stays active during Air preparation; enrollment uses a brief
verified restart and restores the previous targets/start state on failure.
No Pearl coordinator restart or new CLI release is part of this operation.

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
- `catalog-activate.sh` refuses the preflight and the activation while the
  canary provider reports `lifecycle.state` `paused_by_operator`: the custody
  proof needs it `buyer_serving`, and the activation restarts it, which a
  pause outlives. A NO_GO names its failing checks. A pricing release runs
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
  Pearl does not serve. CI runs the preflight's offline pricing checks
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
  traffic has to be stopped. The next step, `canary_self_check`
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
from GitHub and `/healthz` (plus `MIRROR_LATEST_URL` when set). Paste its
output over those sections instead of typing status by hand.
