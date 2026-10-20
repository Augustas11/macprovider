# Guarded offline Studio diagnostic

This entry point reserves one bounded offline diagnostic window for the
four-native-row GLM campaign. It does not install a lab binary, connect one to
the live coordinator, change a catalog policy, or qualify a release.

The operator must have handed back the Studio before the window starts.
Use the existing campaign handoff and evidence; a new build is not a reason
to repeat qualification. The campaign must identify the changed decode or
scheduling code that motivates its diagnostic.

## Preparation

Build the campaign source on the designated Studio, at reduced priority,
without changing the signed provider installation. Prepare:

- A tracked-clean source clone at the exact campaign commit.
- The release-mode CLI with `MACPROVIDER_LAB_HARNESS` enabled, at
  `phase3-binary/.build/release/macprovider-cli`.
- The release-mode `GLMBench` with testing enabled, at
  `scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench`.
- The matching `mlx.metallib` beside each binary.
- `.lab-window/fixture/target`, an isolated clone of the previously verified
  model snapshot. This GLM target embeds its MTP layer; no separate `mtp`
  directory is required. Do not download or replace live model files during
  the window.

Keep source, build provenance, diagnostic outputs, and operational journals
private. Record model and source identities in the campaign's acceptance
evidence. Component profiling cannot substitute for scheduler or buyer-path
acceptance.

Configure the existing private Studio connection, install/config/journal,
launch label, control socket and status-port settings used by the owner-pin
controller. Also set:

| Setting | Meaning |
| --- | --- |
| `STUDIO_LAB_SOURCE_DIR` | Absolute path to the campaign clone on the Studio |
| `STUDIO_LAB_GIT_HEAD` | Exact 40-character campaign commit |
| `STUDIO_LAB_WINDOW_DIR` | Dedicated private directory for this window's journal and staged helpers |

The command and its arguments are fixed in
`scripts/lab/2080-native-rows/run-window-diagnostic.sh`. There is no shell
command setting. Do not change it to `serve`.

## Execute

From a clean checkout of the exact current `origin/main`:

```sh
bash scripts/ops/studio-lab-window.sh status
bash scripts/ops/studio-lab-window.sh next
MACPROVIDER_OPS_OWNER=studio-lab-window \
  bash scripts/ops/studio-lab-window.sh next --run
```

Announce the selected provider's temporary unavailability before executing.
Its model is unloaded for the offline diagnostic and then reloaded. Other
providers and the buyer runner remain running; there is no Pearl coordinator
restart.

The controller authenticates the installed binary against the published
signed release, freezes the source/artifact and configuration identities,
and takes the live-operations lock. The detached supervisor pauses and
drains the provider, stops its watchdog and launch job, runs the fixed
offline child under a deadline, and proves the child group is gone before
restoring the signed provider.

Restoration requires the original serving identity and configuration,
an exact process identity held stable for 120 seconds, and the watchdog
restored. A successful restore does not turn a failed diagnostic into a pass.

## Recovery and handback

If the SSH connection or local controller disappears, the detached supervisor
continues its bounded operation and restoration. Retain the live-operations
lock and journal until the controller has confirmed completion.

Re-run `status`, `next`, and `next --run` using the same window directory.
An existing journal takes precedence over a new run. Do not remove a journal,
force-release a lock, or bootstrap another provider while an offline child
may remain alive. A baseline identity/configuration mismatch is a safety
refusal, not permission to overwrite the changed files.

Copy the private supervisor and diagnostic results into the campaign's
evidence store. Record the diagnostic exit status separately from restoration,
the restored version and process identity, and the watchdog/runner state.
Publish only sanitized product acceptance evidence. Never describe this
offline window as live gateway or settlement proof.
