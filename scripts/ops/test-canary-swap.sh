#!/usr/bin/env bash
# Offline checks for scripts/ops/canary-swap.sh and lib/canary-swap-remote.sh:
# STUDIO_SSH=local with fake launchctl/curl and a fake provider control socket.
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$OPS_DIR/../.." && pwd)"
SWAP="$OPS_DIR/canary-swap.sh"

die() { printf '[test-canary-swap] FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '[test-canary-swap] %s\n' "$*" >&2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/canary-swap-test.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT

CAND=9.9.2
OLD=9.9.1
mkdir -p "$T/bin" "$T/home/Library/LaunchAgents" "$T/state" "$T/ops-state"
export HOME="$T/home"
export MACPROVIDER_OPS_ENV="$T/none.env"
export MACPROVIDER_OPS_STATE_DIR="$T/ops-state"
export MACPROVIDER_LIVE_LOCK="$T/live-ops.lock"
export MACPROVIDER_OPS_OWNER=test-canary
export STUDIO_SSH=local STUDIO_STATUS_PORT=18080
export CANARY_REMOTE_PATH_PREFIX="$T/bin"
export CANARY_CTL_SOCKET="$T/ctl.sock"
export CANARY_RUNNER_STOP_CMD="echo stopped >> '$T/state/runner'"
export CANARY_RUNNER_START_CMD="echo started >> '$T/state/runner'"
export CANARY_STATUS_TIMEOUT_S=3 CANARY_READY_TIMEOUT_S=20 CANARY_DRAIN_TIMEOUT_S=5 CANARY_STABLE_S=1 CANARY_POLL_S=1
export FAKE_STATE="$T/state" FAKE_INSTALL="$HOME/macprovider" FAKE_CAND="$CAND"
touch "$HOME/Library/LaunchAgents/live.malibu.provider.plist"

# Kernel manifest names, for building complete and partial metallibs.
write_metallib() {
  python3 - "$@" <<'PY'
import json, struct, sys
out, manifest, drop = sys.argv[1], sys.argv[2], sys.argv[3]
names = [n for v in json.load(open(manifest))["units"].values() for n in v if n != drop]
entries = b""
for name in names:
    raw = name.encode() + b"\0"
    tags = b"NAME" + struct.pack("<H", len(raw)) + raw + b"ENDT"
    entries += struct.pack("<I", 4 + len(tags)) + tags
header = bytearray(0x58)
header[:4] = b"MTLB"
struct.pack_into("<QQ", header, 0x18, 0x58, len(entries))
open(out, "wb").write(bytes(header) + struct.pack("<I", len(names)) + entries)
PY
}
MANIFEST="$REPO_ROOT/phase3-binary/mlx-metallib-required-kernels.json"

make_payload() { # DIR VERSION DROP_KERNEL
  mkdir -p "$1/mlx-swift_Cmlx.bundle/Contents/Resources"
  printf '#!/bin/bash\necho %s\n' "$2" >"$1/macprovider-cli"
  chmod 755 "$1/macprovider-cli"
  write_metallib "$1/mlx.metallib" "$MANIFEST" "$3"
  cp "$1/mlx.metallib" "$1/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
  printf '{}\n' >"$1/compatibility-set.json"
}
make_payload "$T/good" "$CAND" none
tar -czf "$T/good.tar.gz" -C "$T/good" macprovider-cli mlx.metallib mlx-swift_Cmlx.bundle compatibility-set.json
make_payload "$T/bad" "$CAND" gather_mm_offsets
tar -czf "$T/bad.tar.gz" -C "$T/bad" macprovider-cli mlx.metallib mlx-swift_Cmlx.bundle compatibility-set.json

reset_install() {
  rm -rf "$FAKE_INSTALL" "$FAKE_INSTALL".pre-* "$FAKE_INSTALL".failed-* "$T/state"/*
  make_payload "$FAKE_INSTALL" "$OLD" none
  echo loaded >"$T/state/job"
  echo 100 >"$T/state/pid"
  : >"$T/state/frames"
  rm -f "$MACPROVIDER_LIVE_LOCK"
}

# fake launchctl: one job; in "crash" mode the candidate's pid changes on every print.
cat >"$T/bin/launchctl" <<'SH'
#!/bin/bash
s="$FAKE_STATE"
running() { "$FAKE_INSTALL/macprovider-cli" --version; }
case "$1" in
  bootout) [[ "$2" == *-watchdog ]] || echo unloaded >"$s/job" ;;
  bootstrap) echo loaded >"$s/job"; echo $(( $(cat "$s/pid") + 1 )) >"$s/pid" ;;
  print)
    [ "$(cat "$s/job")" = loaded ] || exit 113
    [[ "$2" == *-watchdog ]] && exit 113
    if [ "$(cat "$s/mode" 2>/dev/null)" = crash ] && [ "$(running)" = "$FAKE_CAND" ]; then
      echo $(( $(cat "$s/pid") + 1 )) >"$s/pid"
    fi
    printf '\tstate = running\n\tpid = %s\n' "$(cat "$s/pid")" ;;
esac
SH
# fake curl: /v1/status of the installed binary; "silent" mode drops the candidate's status.
cat >"$T/bin/curl" <<'SH'
#!/bin/bash
s="$FAKE_STATE"
[ "$(cat "$s/job")" = loaded ] || exit 7
v="$("$FAKE_INSTALL/macprovider-cli" --version)"
if [ "$(cat "$s/mode" 2>/dev/null)" = silent ] && [ "$v" = "$FAKE_CAND" ]; then exit 7; fi
paused=false; state=serving_buyers; net=buyer_serving
if [ -f "$s/paused" ]; then paused=true; state=paused_by_operator; net=paused; fi
printf '{"binary_version":"%s","model_loaded":true,"network_state":"%s","requests_in_flight":0,"lifecycle":{"state":"%s","operator_paused":%s}}\n' "$v" "$net" "$state" "$paused"
SH
chmod +x "$T/bin/launchctl" "$T/bin/curl"

# fake control socket: records frames; pause/resume toggle the paused flag.
python3 - "$CANARY_CTL_SOCKET" "$T/state" <<'PY' &
import json, os, socket, sys
path, state = sys.argv[1], sys.argv[2]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(8)
while True:
    c, _ = srv.accept()
    frame = json.loads(c.makefile().readline())["type"]
    open(os.path.join(state, "frames"), "a").write(frame + "\n")
    if frame == "pause_request":
        open(os.path.join(state, "paused"), "w").close()
    elif frame == "resume_request" and os.path.exists(os.path.join(state, "paused")):
        os.remove(os.path.join(state, "paused"))
    c.sendall((json.dumps({"type": frame.replace("_request", "_ack"), "accepted": True}) + "\n").encode())
    c.close()
PY
SERVER_PID=$!
for _ in $(seq 1 50); do [ -S "$CANARY_CTL_SOCKET" ] && break; sleep 0.1; done

run_rc() { # WANT LABEL CMD...
  local want="$1" label="$2" rc=0
  shift 2
  "$@" >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" = "$want" ] || { cat "$T/err" >&2; die "$label: exit $rc, want $want"; }
  log "ok: $label"
}
installed() { "$FAKE_INSTALL/macprovider-cli" --version; }

# 1. check refuses a candidate whose metallib lacks gather_mm_offsets, before any ssh.
reset_install
run_rc 3 "check refuses missing gather_mm_offsets" "$SWAP" check --version "$CAND" --tarball "$T/bad.tar.gz"
grep -q "missing 1 kernel(s) from gather_mm_offsets.metal" "$T/err" || die "check did not name the missing kernel"
run_rc 3 "swap refuses missing gather_mm_offsets" "$SWAP" swap --version "$CAND" --tarball "$T/bad.tar.gz"
[ "$(installed)" = "$OLD" ] || die "refused swap changed the payload"
[ ! -f "$T/state/runner" ] || die "refused swap touched the buyer runner"
run_rc 0 "check passes a complete candidate" "$SWAP" check --version "$CAND" --tarball "$T/good.tar.gz"

# 2. healthy swap: candidate installed, backup kept, resumed, runner restarted.
reset_install
run_rc 0 "healthy swap" "$SWAP" swap --version "$CAND" --tarball "$T/good.tar.gz"
[ "$(installed)" = "$CAND" ] || die "healthy swap did not install the candidate"
ls -d "$FAKE_INSTALL".pre-"$CAND"-* >/dev/null || die "no backup of the previous payload"
grep -qx resume_request "$T/state/frames" || die "healthy swap never resumed the provider"
[ ! -f "$T/state/paused" ] || die "provider left paused"
[ "$(tr '\n' ' ' <"$T/state/runner")" = "stopped started " ] || die "runner not stopped then restarted"
[ ! -f "$MACPROVIDER_LIVE_LOCK" ] || die "live-ops lock not released"

# 3. crash loop: the candidate restarts, the previous payload comes back resumed.
reset_install
echo crash >"$T/state/mode"
run_rc 5 "crash loop restores the backup" "$SWAP" swap --version "$CAND" --tarball "$T/good.tar.gz"
grep -q "crash loop" "$T/err" || die "crash loop not named"
[ "$(installed)" = "$OLD" ] || die "crash loop left the candidate installed"
ls -d "$FAKE_INSTALL".failed-"$CAND"-* >/dev/null || die "failed payload not kept"
[ ! -f "$T/state/paused" ] || die "restored provider left paused"
[ "$(tr '\n' ' ' <"$T/state/runner")" = "stopped started " ] || die "runner not restarted after rollback"

# 4. /v1/status silence past CANARY_STATUS_TIMEOUT_S restores the backup.
reset_install
echo silent >"$T/state/mode"
run_rc 5 "status silence restores the backup" "$SWAP" swap --version "$CAND" --tarball "$T/good.tar.gz"
grep -q "/v1/status not answering for 3s" "$T/err" || die "status silence not named"
[ "$(installed)" = "$OLD" ] || die "status silence left the candidate installed"

# 5. a swap needs the lock owner and runner commands.
reset_install
run_rc 3 "swap without an owner" env -u MACPROVIDER_OPS_OWNER "$SWAP" swap --version "$CAND" --tarball "$T/good.tar.gz"
run_rc 3 "swap without runner commands" env -u CANARY_RUNNER_STOP_CMD "$SWAP" swap --version "$CAND" --tarball "$T/good.tar.gz"
[ "$(installed)" = "$OLD" ] || die "refused swap changed the payload"

log PASS
