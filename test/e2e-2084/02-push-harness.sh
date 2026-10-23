#!/usr/bin/env bash
# Step 2 (host): copy the shared #1690 harness to /root/e2e/h, the #1816 one to
# /root/e2e/h16 and this harness to /root/e2e/h84 inside the VM.
set -euo pipefail
. "$(dirname "$0")/env.sh"
tar --no-mac-metadata --no-xattrs -C "$E2E_SHARED" --exclude './fakeprov/dist' --exclude './faultproxy/dist' -cf "$E2E_WORK/h.tar" .
tar --no-mac-metadata --no-xattrs -C "$E2E_SHARED16" -cf "$E2E_WORK/h16.tar" .
tar --no-mac-metadata --no-xattrs -C "$E2E_HARNESS" --exclude './host' -cf "$E2E_WORK/h84.tar" .
for t in h h16 h84; do vm_put "$E2E_WORK/$t.tar" "$E2E_VM_ROOT/$t.tar"; done
vm "set -e; for t in h h16 h84; do rm -rf $E2E_VM_ROOT/\$t && mkdir -p $E2E_VM_ROOT/\$t && tar -xf $E2E_VM_ROOT/\$t.tar -C $E2E_VM_ROOT/\$t; done; chmod +x $E2E_VM_ROOT/h/vm/*.sh $E2E_VM_ROOT/h16/vm/*.sh $E2E_VM_ROOT/h84/vm/*.sh"
