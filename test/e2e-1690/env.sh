# shellcheck shell=bash
# #1690 fake-Pearl e2e harness: host-side environment. Source only.
#
# Division of labour (hard rule): the Mac host runs limactl, file copies and
# ssh only. Every build, test and service runs INSIDE the Lima VM $E2E_VM.
# Nothing here reaches production: no Pearl, no Studio provider, no GitHub
# writes. The Studio branch is read with `git bundle create` only.
E2E_HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
E2E_VM="${E2E_VM:-macprovider-1690}"
# Host scratch for bundles, tarballs and evidence (outside the repo tree).
E2E_WORK="${E2E_WORK:-${TMPDIR:-/tmp}/e2e-1690-work}"
mkdir -p "$E2E_WORK"
E2E_WORK="$(cd "$E2E_WORK" && pwd -P)"
# Code under test and the baseline.
# E2E_STUDIO: ssh host that holds the #1690 branch worktree E2E_STUDIO_WT;
# E2E_CANON: a local checkout with origin/main (baseline). Both read-only.
E2E_STUDIO="${E2E_STUDIO:?set E2E_STUDIO to the ssh host holding the branch under test}"
E2E_STUDIO_WT="${E2E_STUDIO_WT:?set E2E_STUDIO_WT to the branch worktree path on E2E_STUDIO}"
E2E_CANON="${E2E_CANON:?set E2E_CANON to a local checkout with the baseline ref}"   # read-only: git archive/bundle
E2E_OLD_REF="${E2E_OLD_REF:-origin/main}"
E2E_VM_ROOT=/root/e2e   # everything in the VM lives here
e2e_log() { printf '[e2e-1690 %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
e2e_die() { printf '[e2e-1690] FATAL: %s\n' "$*" >&2; exit 1; }
# Run as root inside the VM.
vm() { limactl shell --workdir / "$E2E_VM" -- sudo bash -c "$*"; }
vm_script() { limactl shell --workdir / "$E2E_VM" -- sudo bash -s -- "$@"; }
# Copy a host file into the VM (as root) at an absolute path.
vm_put() { limactl shell --workdir / "$E2E_VM" -- sudo bash -c "mkdir -p \"\$(dirname '$2')\" && cat > '$2'" <"$1"; }
export COPYFILE_DISABLE=1
