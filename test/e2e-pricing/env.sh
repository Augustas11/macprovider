# shellcheck shell=bash
# Tier E2 (#1693 pricing lane) harness environment. Source this file; it only
# defines variables and functions.
#
# Nothing here touches production: the "Pearl" is the Lima VM $E2E_VM, every
# key is generated under $E2E_WORK/keys, and the curl/dig shims in bin/ refuse
# any production host they do not remap to the VM.

E2E_HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
E2E_SRC_REPO="$(cd "$E2E_HARNESS/../.." && pwd -P)"
E2E_WORK="${E2E_WORK:-$HOME/.cache/macprovider-e2e-pricing}"
E2E_VM="${E2E_VM:-macprovider-1693}"
E2E_KEYS="$E2E_WORK/keys"
E2E_REPO="$E2E_WORK/repo"            # scratch clone the operator lane runs from
E2E_BARE="$E2E_WORK/origin.git"      # plays origin (never GitHub)
E2E_BARE_URL="file://$E2E_BARE"
E2E_SSH_CONFIG="$E2E_WORK/ssh_config"
# Per-run evidence/logs dirs may be set by the caller (E2E_RUN=run1 -> evidence-run1/, logs-run1/).
E2E_LOGS="${E2E_LOGS:-$E2E_WORK/logs${E2E_RUN:+-$E2E_RUN}}"
E2E_EVIDENCE="${E2E_EVIDENCE:-$E2E_WORK/evidence${E2E_RUN:+-$E2E_RUN}}"
E2E_CANARY_HOME="$E2E_WORK/canary-home"
E2E_TLS_PORT="${E2E_TLS_PORT:-18443}"
# Commits: the pre-#1693 main (tag v1.8.191) and the branch head under test.
E2E_PRE_BASE="${E2E_PRE_BASE:-98e3e4af2b6d5a249aab48bdbec8c9289f6a77e2}"
E2E_BRANCH_HEAD="${E2E_BRANCH_HEAD:-$(git -C "$E2E_SRC_REPO" rev-parse HEAD)}"
# Scratch release tags (numeric vX.Y.Z, as the deploy requires).
E2E_TAG_PRE=v90.0.1
E2E_TAG_ENABLE=v90.1.0
E2E_AUTOTUNE_KEY_ID=e2e-autotune-static-v1
E2E_RELEASE_A=e2e-2026-09-24-release-a
E2E_PEARL=pearl-e2e
E2E_CANARY=canary-e2e
E2E_CANARY_PROVIDER_ID=e2e-canary-provider

mkdir -p "$E2E_WORK" "$E2E_LOGS" "$E2E_EVIDENCE"

e2e_log() { printf '[e2e %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
e2e_die() { printf '[e2e] FATAL: %s\n' "$*" >&2; exit 1; }

# (Re)write the ssh config: Lima's forwarded SSH port can change on restart,
# and the lane hardcodes `-p 22`, so the VM is reached through ProxyCommand.
e2e_write_ssh_config() {
  local port
  port="$(limactl list "$E2E_VM" --format '{{.SSHLocalPort}}' 2>/dev/null)"
  [ -n "$port" ] && [ "$port" != 0 ] || e2e_die "VM $E2E_VM has no SSH port (is it running?)"
  umask 077
  cat >"$E2E_SSH_CONFIG" <<EOF
Host $E2E_PEARL
  HostName 127.0.0.1
  User root
  ProxyCommand /usr/bin/nc 127.0.0.1 $port
  HostKeyAlias $E2E_PEARL
  IdentityFile $E2E_KEYS/pearl_root_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $E2E_KEYS/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
  ServerAliveInterval 15
  ServerAliveCountMax 4
EOF
}

# Re-pin the VM host key over Lima's own channel (Lima regenerates the guest's
# SSH host keys on every `limactl start`: cloud-init sees a new instance-id).
e2e_repin_hostkey() {
  local hk
  hk="$(limactl shell "$E2E_VM" -- sudo cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')" || return 1
  [ -n "$hk" ] || return 1
  printf '%s %s\n' "$E2E_PEARL" "$hk" >"$E2E_KEYS/known_hosts"
}

# Run a command on the VM as root through the same transport the lane uses.
vm() { /usr/bin/ssh -F "$E2E_SSH_CONFIG" "$E2E_PEARL" "$@"; }
vm_script() { /usr/bin/ssh -F "$E2E_SSH_CONFIG" "$E2E_PEARL" bash -s -- "$@"; }

# PATH for every operator-lane invocation: shims first.
e2e_lane_path() { printf '%s:%s' "$E2E_HARNESS/bin" "$PATH"; }

e2e_export() {
  export E2E_RUN E2E_LOGS E2E_EVIDENCE E2E_WORK E2E_KEYS E2E_SSH_CONFIG E2E_CANARY_HOME E2E_TLS_PORT E2E_HARNESS E2E_PEARL E2E_CANARY
}
e2e_export
export COPYFILE_DISABLE=1
