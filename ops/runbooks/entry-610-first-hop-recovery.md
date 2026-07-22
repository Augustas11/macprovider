# Entry 610 — Production first-hop recovery (public CLI 1.8.48)

## Status

**Partial #610.** Code and automated tests land the production-supported
first-hop bridge. Physical proof from a stranded public 1.8.48 install
(disconnected + rejected journeys, buyer restore) remains required before
closing the issue.

## Why this exists

Public CLI **1.8.48** is the last pre-fix updater. It still requires a
fresh coordinator compatibility admission before `macprovider-cli update`
activates a signed release:

- `accepted_compatibility_set_id` must equal the installed set
- `recommended_compatibility_set_id` must equal the release being installed

#631 gives CLI ≥1.8.49 coordinator-independent signed discovery, but cannot
change the already-shipped 1.8.48 binary. Production therefore needs a
server-compatible bridge the old updater can accept without weakening
signature, downgrade, or revocation controls.

## Preferred path (ordinary `macprovider-cli update`)

On Pearl, overlay the live compatibility-set policy with the exact public
pre-fix set in `first_hop_bridge_ids` while `target_id` (and
`coordinator_advertised_version.latest_binary_version`) point at the current
recovery release (for example public `v1.8.56`):

```yaml
coordinator:
  compatibility_set:
    target_id: "Augustas11/macprovider:v1.8.56@0937d230cb7bbfe779480ffb72dbb6ea78d0a14b"
    accepted_ids:
      - "Augustas11/macprovider:v1.8.56@0937d230cb7bbfe779480ffb72dbb6ea78d0a14b"
      - "<current-rollback-set-id>"
    first_hop_bridge_ids:
      - "Augustas11/macprovider:v1.8.48@b84b430aad74574e8a37bc052fe4f9863d0c0ce8"
```

Properties:

- Bridge sets open a session and receive `recommended_compatibility_set_id = target_id`
- Bridge-only sessions are marked `catalog_admission_mode=update_bridge` and are
  **never** buyer-routable (`RoutingEligible` / `ServingCapable` are false)
- Bridge membership must not overlap `accepted_ids` or equal `target_id`
- Signature / downgrade / revocation checks on the CLI updater remain unchanged

Operator journey on a reachable coordinator:

```bash
# Preflight when PATH is a legacy regular-file copy (not a symlink). Public
# 1.8.48 looks for compatibility-set.json next to the launched binary; a
# standalone ~/.local/bin copy raises invalid_current_or_target_set even with
# a valid Pearl first-hop admission. One symlink repair makes ordinary update
# use the coherent ~/macprovider payload (J2 control). Newer CLIs also
# auto-repair this at update/serve/watchdog time (#616).
if [ -e "$HOME/.local/bin/macprovider-cli" ] && [ ! -L "$HOME/.local/bin/macprovider-cli" ] \
  && [ -x "$HOME/macprovider/macprovider-cli" ]; then
  ln -sfn "$HOME/macprovider/macprovider-cli" "$HOME/.local/bin/macprovider-cli"
fi

macprovider-cli update
macprovider-cli --version
macprovider-cli status
```

After the hop (≥1.8.49 provider component), remove the bridge id and rely on
signed release discovery for disconnected/rejected recovery.

## Fallback path (disconnected / no coordinator)

When the coordinator is unreachable, 1.8.48 cannot persist admission. Use the
already-public signed installer (no internal binary extraction, no launchctl
surgery):

```bash
curl -fsSL https://get.streamvc.live/install.sh | MACPROVIDER_VERSION=v1.8.56 bash
macprovider-cli --version
macprovider-cli status
```

`install.sh` upgrade-in-place installs the complete signed compatibility set
without calling the 1.8.48 coordinator-admission gate.

## Post-hop journey (already implemented by #631 + #616)

After the first recovery-capable CLI is active:

1. Disconnected manual `macprovider-cli update` via signed discovery
2. Coordinator-rejected update via signed discovery
3. Default autoupdate without an accepted session
4. Explicit `auto_update_enabled: false` still allows manual update
5. Failed activation rolls back the previous complete set
6. PATH / launchd / payload converge to one signed set (#616)

## Physical acceptance still open

Record and attach before closing #610:

1. Baseline public 1.8.48 set hash `a486a539…` / CLI hash `ae618537…`
2. Pearl first-hop bridge enabled with exact set IDs above
3. Ordinary `macprovider-cli update` activates the recovery target without
   extracting candidate binaries or `launchctl` repair
4. Repeat disconnected / rejected / opt-out / rollback / buyer HTTP 200
5. Remove `first_hop_bridge_ids` entry after the cohort empties

## Related

- Issue: https://github.com/Augustas11/macprovider/issues/610
- #631 signed recovery implementation
- #616 PATH/canonical install convergence
- Exception register: `exc-v1848-first-hop-update-bridge`
