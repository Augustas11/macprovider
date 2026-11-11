# shellcheck shell=bash
# #2084 fake-Pearl VM acceptance harness (SPEC-051 shard groups): host-side
# environment. Source only.
#
# Extends test/e2e-1690 (shared lib: fakeprov, loadgen, oracle, gateway and
# live-config renderers, in-VM lib*.sh, bootstrap) and test/e2e-1816
# (pool-models.py: Trusted Pools signed by the reviewed coordinator-cli).
# The Mac host runs limactl, git (read-only: archive / stash create) and file
# copies, plus scenario R's real Swift providers; every coordinator/gateway
# build, key, service and fake-provider test runs INSIDE the Lima VM $E2E_VM.
# Never touched: Pearl, GitHub, the Studio's live provider, the admin Air.
#
# Inputs:
#   E2E_NEW_REF   code under test, default: the harness checkout's working
#                 tree (`git stash create`, else HEAD), so uncommitted fixes
#                 are tested exactly as they will land.
#   E2E_OLD_REF   production baseline, default origin/main.
#   E2E_SRC       local checkout that holds both refs (read-only), default the
#                 repo containing this harness.
#   E2E_WORK      host scratch, default $TMPDIR/e2e-2084-work.
E2E_HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
E2E_SHARED="$(cd "$E2E_HARNESS/../e2e-1690" && pwd -P)"
E2E_SHARED16="$(cd "$E2E_HARNESS/../e2e-1816" && pwd -P)"
E2E_VM="${E2E_VM:-macprovider-2084}"
E2E_WORK="${E2E_WORK:-${TMPDIR:-/tmp}/e2e-2084-work}"
mkdir -p "$E2E_WORK"
E2E_WORK="$(cd "$E2E_WORK" && pwd -P)"
E2E_SRC="${E2E_SRC:-$(cd "$E2E_HARNESS/../.." && pwd -P)}"
E2E_OLD_REF="${E2E_OLD_REF:-origin/main}"
E2E_VM_ROOT=/root/e2e
e2e_log() { printf '[e2e-2084 %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
e2e_die() { printf '[e2e-2084] FATAL: %s\n' "$*" >&2; exit 1; }
case "$E2E_VM" in macprovider-1693|macprovider-540) e2e_die "refusing to use $E2E_VM";; esac
vm() { limactl shell --workdir / "$E2E_VM" -- sudo bash -c "$*"; }
vm_script() { limactl shell --workdir / "$E2E_VM" -- sudo bash -s -- "$@"; }
vm_put() { limactl shell --workdir / "$E2E_VM" -- sudo bash -c "mkdir -p \"\$(dirname '$2')\" && cat > '$2'" <"$1"; }
vm_get() { limactl shell --workdir / "$E2E_VM" -- sudo cat "$1"; }
export COPYFILE_DISABLE=1
