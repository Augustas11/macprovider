#!/usr/bin/env bash
# E2E WORKAROUND commit on scratch main (reported product bug, NOT fixed in the
# worktree): the lane's under-lock content-gate on Pearl runs
# `catalog-release.py content-gate`, whose verify_directory() resolves the
# Tier-2 trust root from <verifier>/../phase4-coordinator/dist/coordinator.yaml,
# which aa_install_helpers never ships -> lane=invalid-release -> every
# catalog-content/pricing --deploy aborts before mutating ("remote publish
# aborted before mutating current (rc=2)"). This ships the commit's tracked
# coordinator.yaml beside the verifier so the post-activation paths can be
# exercised. Skip with E2E_NO_GATE_WORKAROUND=1 to reproduce the bug.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
[ "${E2E_NO_GATE_WORKAROUND:-0}" != 1 ] || exit 0
cd "$E2E_REPO"
[ -z "$(git status --porcelain)" ] || e2e_die dirty
git checkout -q main
grep -q 'E2E WORKAROUND' scripts/catalog-content-release.sh && { echo "already applied"; exit 0; }
if grep -q 'E2E WORKAROUND' scripts/lib/autotune-activate.sh; then git reset -q --hard HEAD~1 && git push -q -f origin HEAD:main; fi
python3 - <<'PY'
p = "scripts/lib/autotune-activate.sh"; s = open(p).read()
anchor = '  CONTINUITY_VERIFIER="$LOCK_HELPER_DIR/scripts/catalog-release.py"\n'
add = anchor + '''  # E2E WORKAROUND (tier E2 scratch repo only): the verifier's default Tier-2
  # trust root is <verifier>/../phase4-coordinator/dist/coordinator.yaml.
  SSH "mkdir -p -m 0700 '$LOCK_HELPER_DIR/phase4-coordinator/dist' && cat >'$LOCK_HELPER_DIR/phase4-coordinator/dist/coordinator.yaml'" \\
    < "$REPO_ROOT/phase4-coordinator/dist/coordinator.yaml" || fatal "cannot install the Tier-2 trust root beside the verifier"
'''
assert s.count(anchor) == 1
open(p, "w").write(s.replace(anchor, add))
PY
# Second reported bug: the under-lock coverage dry-load runs as `macprovider`
# with --config $pricing_candidate where pricing_dir="$(dirname "$verifier")/../pricing"
# resolves THROUGH $LOCK_HELPER_DIR/scripts (mode 0700 root) -> "permission
# denied" -> coverage unknown -> publish aborted. Canonicalise the path.
python3 - <<'PY'
p = "scripts/catalog-content-release.sh"; s = open(p).read()
old = 'pricing_dir="$(dirname "$verifier")/../pricing"\n'
new = 'pricing_dir="$(cd "$(dirname "$verifier")/.." && pwd -P)/pricing"  # E2E WORKAROUND\n'
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
PY
git commit -q -am "E2E WORKAROUND: ship the Tier-2 trust root beside the Pearl verifier; canonical pricing_dir"
git push -q origin main && git fetch -q
echo "applied $(git rev-parse HEAD)"
