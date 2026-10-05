#!/usr/bin/env bash
# Step 2 (host): copy the shared #1690 harness to /root/e2e/h and this
# harness to /root/e2e/h16 inside the VM. Everything after this runs in the VM.
set -euo pipefail
. "$(dirname "$0")/env.sh"
tar --no-mac-metadata --no-xattrs -C "$E2E_SHARED" --exclude './fakeprov/dist' --exclude './faultproxy/dist' -cf "$E2E_WORK/h.tar" .
tar --no-mac-metadata --no-xattrs -C "$E2E_HARNESS" -cf "$E2E_WORK/h16.tar" .
vm_put "$E2E_WORK/h.tar" "$E2E_VM_ROOT/h.tar"
vm_put "$E2E_WORK/h16.tar" "$E2E_VM_ROOT/h16.tar"
vm "rm -rf $E2E_VM_ROOT/h $E2E_VM_ROOT/h16 && mkdir -p $E2E_VM_ROOT/h $E2E_VM_ROOT/h16 && tar -xf $E2E_VM_ROOT/h.tar -C $E2E_VM_ROOT/h && tar -xf $E2E_VM_ROOT/h16.tar -C $E2E_VM_ROOT/h16 && chmod +x $E2E_VM_ROOT/h/vm/*.sh $E2E_VM_ROOT/h16/vm/*.sh"
