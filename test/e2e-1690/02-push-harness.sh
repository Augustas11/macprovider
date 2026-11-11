#!/usr/bin/env bash
# Step 2 (host): copy this harness into the VM at /root/e2e/h. Everything
# after this runs in the VM (vm/*.sh), driven over `limactl shell`.
set -euo pipefail
. "$(dirname "$0")/env.sh"
tar --no-mac-metadata --no-xattrs -C "$E2E_HARNESS" --exclude './fakeprov/dist' --exclude './faultproxy/dist' -cf "$E2E_WORK/h.tar" .
vm_put "$E2E_WORK/h.tar" "$E2E_VM_ROOT/h.tar"
vm "rm -rf $E2E_VM_ROOT/h && mkdir -p $E2E_VM_ROOT/h && tar -xf $E2E_VM_ROOT/h.tar -C $E2E_VM_ROOT/h && chmod +x $E2E_VM_ROOT/h/vm/*.sh"
