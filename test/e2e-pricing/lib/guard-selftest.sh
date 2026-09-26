#!/usr/bin/env bash
# Self-test for the tier E2 VM-target guard in lib/common.sh. Local only: it
# never starts the VM, connects anywhere, or reads the real harness work dir
# (E2E_WORK is a temp dir; `ssh -G` only parses the generated config).
#   bash test/e2e-pricing/lib/guard-selftest.sh
set -uo pipefail
H="$(cd "$(dirname "$0")/.." && pwd -P)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
fails=0
ok() { printf '[guard-selftest] ok: %s\n' "$*"; }
bad() { printf '[guard-selftest] FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

config() { # <HostName> [ProxyCommand|-] [extra line]
  {
    printf 'Host pearl-e2e\n  HostName %s\n  User root\n' "$1"
    [ "${2:--}" = - ] || printf '  ProxyCommand %s\n' "$2"
    [ -z "${3:-}" ] || printf '  %s\n' "$3"
  } >"$W/ssh_config"
}
# run <env assignments...>: source env.sh + common.sh as a harness step does,
# then print the resolved targets. Output in $W/out, status returned.
run() {
  env -u PEARL_SSH -u VPS_HOST E2E_WORK="$W" "$@" bash -c '
    . "$1/env.sh"
    E2E_SSH_CONFIG="$E2E_WORK/ssh_config"
    . "$1/lib/common.sh"
    echo "REACHED PEARL_SSH=$PEARL_SSH VPS_HOST=$VPS_HOST"
    e2e_lane_env && echo "LANE_ENV PEARL_SSH=$PEARL_SSH VPS_HOST=$VPS_HOST"
  ' _ "$H" >"$W/out" 2>&1
}
refused() { # <label> <message fragment> <env...>
  local label="$1" frag="$2" rc=0; shift 2
  run "$@" || rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q REACHED "$W/out" && grep -q "SAFETY: .*$frag" "$W/out"; then
    ok "$label: refused before any command (rc=$rc)"
  else
    bad "$label: must refuse before any command (rc=$rc): $(cat "$W/out")"
  fi
}

config 127.0.0.1 "/usr/bin/nc 127.0.0.1 60022"
if run && grep -q '^REACHED PEARL_SSH=pearl-e2e VPS_HOST=pearl-e2e$' "$W/out" &&
   grep -q '^LANE_ENV PEARL_SSH=pearl-e2e VPS_HOST=pearl-e2e$' "$W/out"; then
  ok "loopback alias: targets default to pearl-e2e and e2e_lane_env passes"
else
  bad "loopback alias must pass: $(cat "$W/out")"
fi
run PEARL_SSH=pearl-e2e VPS_HOST=pearl-e2e && ok "explicit pearl-e2e targets pass" || bad "explicit pearl-e2e targets must pass: $(cat "$W/out")"
refused "PEARL_SSH=pearl (the operator's real host)" "PEARL_SSH='pearl'" PEARL_SSH=pearl
refused "VPS_HOST=pearl" "VPS_HOST='pearl'" VPS_HOST=pearl
refused "empty PEARL_SSH (the lane would default to pearl)" "PEARL_SSH=''" PEARL_SSH=
refused "VPS_HOST=an IP" "VPS_HOST=" VPS_HOST=203.0.113.7
config pearl.example.com "/usr/bin/nc 127.0.0.1 60022"
refused "alias HostName not loopback" "hostname 'pearl.example.com'"
config 127.0.0.1 "/usr/bin/nc 203.0.113.7 22"
refused "ProxyCommand to another host" "ProxyCommand"
config 127.0.0.1 "ssh -W %h:%p pearl"
refused "ProxyCommand through the real host" "ProxyCommand"
config 127.0.0.1 - "ProxyJump pearl"
refused "ProxyJump" "ProxyJump"
rm -f "$W/ssh_config"
refused "missing ssh config" "is missing"

# e2e_lane_env re-checks: a step that changes a target after sourcing is refused.
config 127.0.0.1 "/usr/bin/nc 127.0.0.1 60022"
rc=0
env -u PEARL_SSH -u VPS_HOST E2E_WORK="$W" bash -c '
  . "$1/env.sh"; E2E_SSH_CONFIG="$E2E_WORK/ssh_config"; . "$1/lib/common.sh"
  E2E_PEARL=pearl; e2e_lane_env && echo LANE_ENV' _ "$H" >"$W/out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && ! grep -q LANE_ENV "$W/out"; then ok "e2e_lane_env refuses a retargeted alias"; else bad "e2e_lane_env must refuse E2E_PEARL=pearl: $(cat "$W/out")"; fi

[ "$fails" -eq 0 ] || { printf '[guard-selftest] %d failure(s)\n' "$fails" >&2; exit 1; }
printf '[guard-selftest] PASS\n'
