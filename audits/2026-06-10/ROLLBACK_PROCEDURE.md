# Coordinator rollback procedure

**Scope**: swap the live `/opt/macprovider/coordinator` binary on the Pearl
VPS (`coordinator.streamvc.live`) back to the previous build, in under
30 seconds, when the deploy script's provenance check shows the wrong
version or when a smoke test against the new binary fails.

**Prerequisites**:
- SSH access to the VPS as `root` (e.g. `ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194`).
- The `.prev` snapshot exists at `/opt/macprovider/coordinator.prev`. The
  deploy script (`phase4-coordinator/dist/deploy-pearl-vps.sh`) creates
  this in step 4/9, before installing the new binary. If you are
  rolling back a deploy that did **not** go through this script, check
  for the snapshot first — without it you'll need to re-deploy a known-
  good build from your laptop instead.

## Fast path (binary swap, no config change)

Use this when the **new binary** is the problem and the previous
`coordinator.yaml`/service unit are still fine.

```bash
ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194 '
  set -e
  if [ ! -x /opt/macprovider/coordinator.prev ]; then
    echo "no .prev snapshot — fast rollback not possible" >&2
    exit 1
  fi
  mv /opt/macprovider/coordinator /opt/macprovider/coordinator.bad
  # #244 R4+R5: artifact ownership tightened to root:macprovider 0750
  install -o root -g macprovider -m 0750 /opt/macprovider/coordinator.prev /opt/macprovider/coordinator
  systemctl restart macprovider-coordinator
  sleep 2
  systemctl is-active macprovider-coordinator
'
```

Verify from the operator Mac:

```bash
curl -fsS https://coordinator.streamvc.live/healthz \
  | python3 -m json.tool
# Expect:  "version": "<previous git-describe>"
```

If `is-active` returns `active` and the version field matches the
previous build, the rollback is complete. Total wall-clock: ~10–20s.

## Why `install` not `mv` for the restore

Keeping `coordinator.prev` in place after the restore lets the next
rollback (if the operator pushes a third build that also fails) still
have the same known-good snapshot to fall back to. The "bad" binary
goes to `coordinator.bad` rather than being deleted so a post-mortem
can `strings` / `nm` / re-run it locally.

We use `install -o root -g macprovider -m 0750` rather than `cp -p` so
the restored binary's ownership is set explicitly per invocation
(#244 R4+R5: the new posture is root-owned, macprovider-group with
group-execute — the daemon's User=macprovider is in the group so it
can exec the binary, but cannot rewrite it). A `cp -p` would propagate
whatever owner/mode the `.prev` file happens to carry, which would
silently drift the live binary if `.prev` came from a snapshot built
under different rules.

## When the fast path is wrong

The `.prev` snapshot only covers the binary. If the deploy that broke
prod **also** changed `coordinator.yaml` (operator key rotation,
routing tier flip, tier-2 catalog change), restoring the binary alone
leaves you on the new YAML with the old binary's expectations — which
may be a *different* broken state. In that case:

1. Stop the service: `systemctl stop macprovider-coordinator`.
2. From your operator Mac, check out the commit that produced the
   known-good build (`git log --oneline phase4-coordinator/`), and run
   `phase4-coordinator/dist/deploy-pearl-vps.sh` against that tree.
   The deploy script's provenance check at step 8/9 will confirm the
   restored version matches.

## Auto-rollback is not wired up

The deploy script's step 8/9 provenance assertion is non-fatal by
design — it prints a `WARN` line on mismatch but does not auto-swap
the `.prev` binary back. Reasoning:

- Auto-rollback hides drift. An operator who sees the WARN line and
  decides to keep the new build (e.g. because the mismatch is benign
  from a `git stash` they forgot) is making an informed decision; an
  auto-rollback would have already reverted and the operator would
  not know they had drifted.
- Auto-rollback in the failure mode where the new binary's `/healthz`
  returns the *expected* version but is silently broken on a code
  path the script doesn't probe would not have helped anyway.

The full version-pin / blue-green path is a future M-tier item.

### `STRICT_PROVENANCE=1` for the binary-predates-instrumentation case

There is one provenance state where the deploy script will exit
non-zero if the operator opts in: when `/healthz` returns no `version`
field at all. That case (printed as `CRITICAL provenance MISSING` in
step 8/9) almost certainly means the deployed binary predates PR #18
and the entire rollback gate is bypassed — which is qualitatively
different from a normal "deployed != expected" drift, because the
operator can't reason about the running code from scrollback alone.

Default is still non-fatal (operator decision). Set
`STRICT_PROVENANCE=1 bash deploy-pearl-vps.sh` to abort with exit
code 7 on the missing-version state. Recommended for any deploy
where downstream automation expects the M0-5 instrumentation to be
present.

## Rebuilding the `.prev` snapshot from scratch

If `/opt/macprovider/coordinator.prev` is missing (manual deploys,
disk wipe), populate it from the next deploy by re-running
`deploy-pearl-vps.sh` — its step 4/9 will snapshot the binary that is
about to be replaced. To populate it WITHOUT a new deploy:

```bash
ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194 '
  install -o macprovider -g macprovider -m 0755 /opt/macprovider/coordinator /opt/macprovider/coordinator.prev
'
```

This makes the *current* binary the rollback target. Useful right
before a risky maintenance window: take the snapshot when you know
the system is healthy. Using `install(1)` (rather than `cp -p`)
keeps ownership explicit even if the running binary on this VPS
happens to be root-owned for any reason.
