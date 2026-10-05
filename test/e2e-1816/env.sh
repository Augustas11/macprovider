# shellcheck shell=bash
# #1816 fake-Pearl VM acceptance harness: host-side environment. Source only.
#
# Extends test/e2e-1690 (the shared lib: fakeprov, loadgen, oracle,
# compare-shape, gateway.yaml, seed-buyer, live-config, in-VM lib*.sh). The
# Mac host runs limactl, git (read-only: archive/bundle) and file copies only;
# every build, key, service and test runs INSIDE the Lima VM $E2E_VM.
# Never touched: Pearl, GitHub, the Studio's live provider, and the Lima VMs
# macprovider-1693 / macprovider-540.
#
# Inputs:
#   E2E_NEW_REF   (required) the #1816 code under test: any commit-ish in
#                 $E2E_SRC (a branch, tag or sha).
#   E2E_OLD_REF   production baseline, default origin/main.
#   E2E_SRC       local checkout that holds both refs (read-only), default the
#                 repo containing this harness.
#   E2E_WORK      host scratch, default $TMPDIR/e2e-1816-work.
E2E_HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
E2E_SHARED="$(cd "$E2E_HARNESS/../e2e-1690" && pwd -P)"
E2E_VM="${E2E_VM:-macprovider-1690}"
E2E_WORK="${E2E_WORK:-${TMPDIR:-/tmp}/e2e-1816-work}"
mkdir -p "$E2E_WORK"
E2E_WORK="$(cd "$E2E_WORK" && pwd -P)"
E2E_SRC="${E2E_SRC:-$(cd "$E2E_HARNESS/../.." && pwd -P)}"
E2E_NEW_REF="${E2E_NEW_REF:?set E2E_NEW_REF to the #1816 commit-ish under test}"
E2E_OLD_REF="${E2E_OLD_REF:-origin/main}"
E2E_VM_ROOT=/root/e2e
e2e_log() { printf '[e2e-1816 %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
e2e_die() { printf '[e2e-1816] FATAL: %s\n' "$*" >&2; exit 1; }
case "$E2E_VM" in macprovider-1693|macprovider-540) e2e_die "refusing to use $E2E_VM";; esac
vm() { limactl shell --workdir / "$E2E_VM" -- sudo bash -c "$*"; }
vm_script() { limactl shell --workdir / "$E2E_VM" -- sudo bash -s -- "$@"; }
vm_put() { limactl shell --workdir / "$E2E_VM" -- sudo bash -c "mkdir -p \"\$(dirname '$2')\" && cat > '$2'" <"$1"; }
export COPYFILE_DISABLE=1
