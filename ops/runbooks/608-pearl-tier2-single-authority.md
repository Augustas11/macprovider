# #608 Pearl Tier-2 single-authority cutover

**Scope:** Step D only. Move Pearl from the independent
`/opt/macprovider/tier2-catalog.json` bridge to the signed Tier-2 feed inside
the active content-addressed catalog release, prove three exact physical
provider buyer-serving journeys, then authorize clearance of only
`exc-catalog-compatibility-bridges`.

**Out of scope:** `tier2.require_hash_verified=true`, either buyer-canary
enable gate, the buyer-canary timer, and
`exc-tier2-hash-mismatch-containment`. Those remain sealed for #609.

## 0. Required starting state

Abort before mutation unless all facts below are freshly true:

- coordinator and gateway v1.8.60 are active and healthy;
- the active signed catalog is
  `releases/published-2026-07-10-catalog-recovery-v1-386803eac2069a37`;
- active and legacy Tier-2 SHA-256 are both
  `ec2a2b64ed3a00bb0b185840ea5d9edee6a07d4ecb551775db5f69316e463d92`;
- `check-tier2-binding` reports `CONFLICT=0`, `AGREE=9`;
- effective `tier2.require_hash_verified` is exactly `false`;
- `pool.canary_enabled=false`;
- `/etc/macprovider-canary-buyer/enabled` and
  `/etc/macprovider/canary-buyer.enabled` are absent;
- `/var/lib/macprovider-canary-buyer/DISABLED` is empty, root-owned `0644`;
- `canary-buyer.timer` is disabled/inactive and
  `canary-buyer.service` is inactive;
- no direct-deploy rollback directory or updater phase journal exists.

Read-only Pearl preflight:

```bash
ssh pearl 'sudo bash -se' <<'SH'
set -eu
root=/opt/macprovider
test "$(readlink "$root/autotune/current")" = \
  releases/published-2026-07-10-catalog-recovery-v1-386803eac2069a37
test "$(sha256sum "$root/autotune/current/tier2-catalog.json" | cut -d" " -f1)" = \
  ec2a2b64ed3a00bb0b185840ea5d9edee6a07d4ecb551775db5f69316e463d92
test "$(sha256sum "$root/tier2-catalog.json" | cut -d" " -f1)" = \
  ec2a2b64ed3a00bb0b185840ea5d9edee6a07d4ecb551775db5f69316e463d92
cmp -s "$root/tier2-catalog.json" \
  "$root/autotune/current/tier2-catalog.json"
grep -Eq '^[[:space:]]*require_hash_verified:[[:space:]]*false([[:space:]]|$)' \
  "$root/coordinator.yaml"
grep -Eq '^[[:space:]]*canary_enabled:[[:space:]]*false([[:space:]]|$)' \
  /etc/macprovider/coordinator.pearl-overlays.yaml
test ! -e /etc/macprovider-canary-buyer/enabled
test ! -e /etc/macprovider/canary-buyer.enabled
test -f /var/lib/macprovider-canary-buyer/DISABLED
test ! -s /var/lib/macprovider-canary-buyer/DISABLED
test "$(stat -c '%U:%G:%a' /var/lib/macprovider-canary-buyer/DISABLED)" = \
  root:root:644
test "$(systemctl is-enabled canary-buyer.timer 2>/dev/null || true)" = disabled
test "$(systemctl is-active canary-buyer.timer 2>/dev/null || true)" = inactive
test "$(systemctl is-active canary-buyer.service 2>/dev/null || true)" = inactive
test ! -e "$root/.coordinator-deploy-rollback"
test ! -e /var/lib/macprovider-pearl-updater/active-transaction.json
SH
```

Run the reviewed binding probe against the active release and independent file.
Expected result is exactly `CONFLICT=0`, `AGREE=9`; abort on any conflict.

## 1. Install the merged Step D updater

Install only from the exact squash-merged `origin/main` revision whose PR has
green required CI, 0 CRITICAL/HIGH/MEDIUM findings in all three audit lanes,
and an exact-head `antfleet-ops` approval. Record the squash commit as
`STEP_D_MERGED_SHA`. From a clean repository on the operator workstation,
stream exactly that Git object into a new root-only Pearl staging directory.
After installation, compare every overwritten installed artifact with the
exact merged source bytes:

```bash
git cat-file -e "${STEP_D_MERGED_SHA}^{commit}"
STEP_D_BUNDLE_DIR="$(
  ssh pearl 'sudo mktemp -d /var/tmp/macprovider-step-d.XXXXXXXX'
)"
case "$STEP_D_BUNDLE_DIR" in
  /var/tmp/macprovider-step-d.*) ;;
  *) echo "unsafe Pearl staging directory" >&2; exit 1 ;;
esac
git archive "$STEP_D_MERGED_SHA" \
  ops/pearl-updater \
  scripts/catalog-release.py \
  scripts/sign-catalog.go |
  ssh pearl "sudo tar -xf - -C '$STEP_D_BUNDLE_DIR'"
ssh pearl \
  "sudo '$STEP_D_BUNDLE_DIR/ops/pearl-updater/install-pearl-updater.sh'"

manifest_line() {
  source_path="$1"
  destination_path="$2"
  printf '%s  %s\n' \
    "$(git show "${STEP_D_MERGED_SHA}:${source_path}" | shasum -a 256 | cut -d' ' -f1)" \
    "$destination_path"
}
{
  manifest_line ops/pearl-updater/macprovider-pearl-update /usr/local/sbin/macprovider-pearl-update
  manifest_line ops/pearl-updater/macprovider-pearl-update-gate /usr/local/sbin/macprovider-pearl-update-gate
  manifest_line ops/pearl-updater/macprovider-pearl-updater-alert /usr/local/sbin/macprovider-pearl-updater-alert
  manifest_line ops/pearl-updater/release-signing-public.pem /usr/local/share/macprovider/release-signing-public.pem
  manifest_line scripts/catalog-release.py /usr/local/share/macprovider/scripts/catalog-release.py
  manifest_line scripts/sign-catalog.go /usr/local/share/macprovider/scripts/sign-catalog.go
  manifest_line ops/pearl-updater/catalog-canary-proof.py /usr/local/share/macprovider/catalog-canary-proof.py
  manifest_line ops/pearl-updater/macprovider-pearl-updater.service /etc/systemd/system/macprovider-pearl-updater.service
  manifest_line ops/pearl-updater/macprovider-pearl-updater.timer /etc/systemd/system/macprovider-pearl-updater.timer
  manifest_line ops/pearl-updater/macprovider-pearl-updater-alert@.service /etc/systemd/system/macprovider-pearl-updater-alert@.service
  manifest_line ops/pearl-updater/macprovider-pearl-updater-reconcile.service /etc/systemd/system/macprovider-pearl-updater-reconcile.service
  for unit in macprovider-coordinator macprovider-gateway canary-buyer macprovider-archive-rotate stats-billing-mirror; do
    manifest_line \
      ops/pearl-updater/macprovider-pearl-updater-transaction-gate.conf \
      "/etc/systemd/system/${unit}.service.d/50-pearl-updater-transaction-gate.conf"
  done
} | ssh pearl 'sudo sha256sum -c -'
```

Keep `PEARL_UPDATER_BUYER_CANARY_MODE=disabled` and
`PEARL_UPDATER_ENABLED=1` in the root-owned updater configuration for this
sealed window. Do not create either canary enable gate.

## 2. Same-release rollback-armed cutover

Use the signed v1.8.60 release already serving on Pearl. The plan must report a
same-version repair, not an upgrade, downgrade, or skip:

```bash
sudo /usr/local/sbin/macprovider-pearl-update --plan --tag v1.8.60
# Expected action: repair_pair

STEP_D_APPLY_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export STEP_D_APPLY_STARTED_AT
sudo /usr/local/sbin/macprovider-pearl-update --apply --tag v1.8.60
```

The updater snapshots the prior config, active catalog pointer, and matching
legacy Tier-2 bytes before mutation. It stages the release-bound catalog path,
cold-starts the coordinator with the independent file absent, proves the
signed backend/catalog pair and physical provider, then commits. Any failure
before commit restores the prior config, pointer, and legacy bytes together.
Do not delete or edit the phase journal during recovery.

## 3. Post-cutover invariants and three journeys

```bash
ssh pearl 'sudo bash -se' <<'SH'
set -eu
root=/opt/macprovider
test ! -e "$root/tier2-catalog.json"
test "$(readlink "$root/autotune/current")" = \
  releases/published-2026-07-10-catalog-recovery-v1-386803eac2069a37
test "$(sha256sum "$root/autotune/current/tier2-catalog.json" | cut -d" " -f1)" = \
  ec2a2b64ed3a00bb0b185840ea5d9edee6a07d4ecb551775db5f69316e463d92
grep -Eq '^[[:space:]]*require_hash_verified:[[:space:]]*false([[:space:]]|$)' \
  "$root/coordinator.yaml"
systemctl is-active --quiet macprovider-coordinator
systemctl is-active --quiet macprovider-gateway
test ! -e /var/lib/macprovider-pearl-updater/active-transaction.json
SH

sudo /usr/local/sbin/macprovider-pearl-update \
  --prove-current --tag v1.8.60
# Expected JSON:
# action=prove_current
# single_authority_buyer_serving_cycles=3
```

`--prove-current` is read-only and refuses when an updater transaction needs
reconciliation. It refuses unless v1.8.60 is the coherent signed current
release, the effective base-plus-overlay Tier-2 path is release-bound, the
legacy path is absent, `tier2.require_hash_verified=false`, and the buyer
canary remains hard-disabled. It also binds the live coordinator and gateway
processes to the signed installed executables and to starts after the governed
configuration and active catalog pointer were published.

Each numbered cycle issues one fresh authenticated buyer request for the
physical provider's exact catalog model. Success requires a content token, a
terminal stream marker, exact `X-Provider-Id` attribution, exact response
model, and a request ID not used by either other cycle. The same cycle then
proves the physical Mac files/text vnode/listener and the matching
`buyer_serving=true` admission row for the active release, policy, digest,
signer, and row identity. This command does not start the buyer-canary service,
enable its timer, or create either enable gate.

Use the apply start timestamp as the journal boundary and require zero matches:

```bash
test -n "${STEP_D_APPLY_STARTED_AT:-}"
STEP_D_LOG="$(mktemp)"
trap 'rm -f "$STEP_D_LOG"' EXIT
sudo journalctl -u macprovider-coordinator \
  --since "$STEP_D_APPLY_STARTED_AT" --no-pager >"$STEP_D_LOG"
if grep -Ei \
  'model_hash_uncatalogued|model_hash_mismatch|catalog.*identity.*conflict|catalogbind.*(fail|error)' \
  "$STEP_D_LOG"; then
  echo "ABORT: Step D stop-condition event found" >&2
  exit 1
fi
```

Also re-run `check-tier2-binding` against the active three-feed release;
expected result remains exactly `CONFLICT=0`, `AGREE=9`.

## 4. Rollback and exception clearance

If apply fails or any stop condition appears, let the updater reconcile its
durable transaction. The first-cutover rollback restores the prior
`coordinator.yaml`, `autotune/current`, and matching legacy Tier-2 bytes
together. Never restore the legacy file alone.

After a successful committed cutover, later release rollback switches the
signed `autotune/current` release as one unit and preserves
`/opt/macprovider/tier2-catalog.json` as absent.

Only after §3 evidence is attached to issue #608 may a separate reviewed
change remove `exc-catalog-compatibility-bridges` and add its tombstone. Do not
clear `exc-tier2-hash-mismatch-containment`, flip hash verification, or enable
the buyer canary in that change.
