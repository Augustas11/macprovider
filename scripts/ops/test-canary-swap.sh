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
T="$(cd "$T" && pwd -P)"
SERVER_PID=""
COORD_PID=""
cleanup() {
  [ -z "$COORD_PID" ] || { kill "$COORD_PID" 2>/dev/null || true; wait "$COORD_PID" 2>/dev/null || true; }
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
body = struct.pack("<I", len(names)) + entries
struct.pack_into("<Q", header, 0x10, len(header) + len(body))
open(out, "wb").write(bytes(header) + body)
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
  mkdir -p "$1/catalog-release"
  printf '{"release_id":"%s","generated_at":"%s"}\n' "${4:-rel-live}" "${5:-2026-10-22T06:00:00Z}" >"$1/catalog-release/release.json"
  printf '{"generated_at":"%s","version":"%s"}\n' "${5:-2026-10-22T06:00:00Z}" "${6:-v-live}" >"$1/catalog-release/rate-card.json"
}
PAYLOAD_MEMBERS="macprovider-cli mlx.metallib mlx-swift_Cmlx.bundle compatibility-set.json catalog-release"
make_payload "$T/good" "$CAND" none
# shellcheck disable=SC2086
tar -czf "$T/good.tar.gz" -C "$T/good" $PAYLOAD_MEMBERS
make_payload "$T/bad" "$CAND" gather_mm_offsets
# shellcheck disable=SC2086
tar -czf "$T/bad.tar.gz" -C "$T/bad" $PAYLOAD_MEMBERS
# A candidate baking a newer catalog than Pearl serves (the 1.8.262 failure).
make_payload "$T/newcat" "$CAND" none rel-new 2026-10-23T00:40:00Z v-new
# shellcheck disable=SC2086
tar -czf "$T/newcat.tar.gz" -C "$T/newcat" $PAYLOAD_MEMBERS

# Fake coordinator: Pearl serves catalog rel-live.
mkdir -p "$T/coord/v1"
printf '{"release_id":"rel-live","generated_at":"2026-10-22T06:00:00Z","status":"live_verified"}\n' >"$T/coord/v1/autotune-release"
printf '{"generated_at":"2026-10-22T06:00:00Z","version":"v-live"}\n' >"$T/coord/v1/rate-card"
COORD_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "$COORD_PORT" --bind 127.0.0.1 --directory "$T/coord" >/dev/null 2>&1 &
COORD_PID=$!
export COORDINATOR_URL="http://127.0.0.1:$COORD_PORT"
for _ in $(seq 1 50); do curl -fs -o /dev/null "$COORDINATOR_URL/v1/rate-card" && break; sleep 0.1; done

# verify_bytes TARBALL: record TARBALL as the signature-verified v$CAND bytes,
# the way cli-release.sh signed_byte_verification leaves them.
verify_bytes() {
  local dir="$T/bytes" asset="macprovider-cli-v$CAND-darwin-arm64.tar.gz" scope="$T/ops-state/cli-release-$CAND"
  rm -rf "$dir"; mkdir -p "$dir" "$scope"
  cp "$1" "$dir/$asset"
  printf '%s  %s\n' "$(shasum -a 256 "$dir/$asset" | awk '{print $1}')" "$asset" >"$dir/checksums.txt"
  rm -f "$scope/canary_swap.json"
  printf '{"candidate_sha":"%s","bytes_dir":"%s","checksums_sha256":"%s","binary_sha256":"%s"}\n' \
    "$(git -C "$REPO_ROOT" rev-parse HEAD)" "$dir" \
    "$(shasum -a 256 "$dir/checksums.txt" | awk '{print $1}')" \
    "$(shasum -a 256 "$T/good/macprovider-cli" | awk '{print $1}')" >"$scope/signed_byte_verification.json"
}

reset_install() {
  rm -rf "$FAKE_INSTALL" "$FAKE_INSTALL".pre-* "$FAKE_INSTALL".failed-* "$T/state"/* "$HOME/macprovider-canary-staging"
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
  bootout) if [[ "$2" == *-watchdog ]]; then rm -f "$s/wd"; else echo unloaded >"$s/job"; fi ;;
  bootstrap)
    if [[ "$3" == *-watchdog.plist ]]; then touch "$s/wd"; exit 0; fi
    echo loaded >"$s/job"; echo $(( $(cat "$s/pid") + 1 )) >"$s/pid"
    [ "$(running)" != "$FAKE_CAND" ] || date +%s >"$s/swapped" ;;
  print)
    if [[ "$2" == *-watchdog ]]; then [ -f "$s/wd" ] || exit 113; printf '\tstate = running\n'; exit 0; fi
    [ "$(cat "$s/job")" = loaded ] || exit 113
    mode="$(cat "$s/mode" 2>/dev/null || true)"
    # wdkick: an armed watchdog kickstarts the candidate while it is loaded.
    if [ "$mode" = wdkick ] && [ -f "$s/wd" ] && [ "$(running)" = "$FAKE_CAND" ]; then
      echo $(( $(cat "$s/pid") + 1 )) >"$s/pid"
    fi
    if { [ "$mode" = crash ] || [ "$mode" = dead ]; } && [ "$(running)" = "$FAKE_CAND" ]; then
      echo $(( $(cat "$s/pid") + 1 )) >"$s/pid"
    fi
    printf '\tstate = running\n\tpid = %s\n' "$(cat "$s/pid")" ;;
esac
SH
# fake curl: /v1/status of the installed binary. "silent" drops the candidate's
# status for good; "loadsilent" drops it for $s/loadsecs seconds after the swap
# (a large model loading), then answers; "hang" answers once with the model
# loaded, then goes silent.
cat >"$T/bin/curl" <<'SH'
#!/bin/bash
s="$FAKE_STATE"
[ "$(cat "$s/job")" = loaded ] || exit 7
v="$("$FAKE_INSTALL/macprovider-cli" --version)"
mode="$(cat "$s/mode" 2>/dev/null || true)"
if [ "$mode" = silent ] && [ "$v" = "$FAKE_CAND" ]; then exit 7; fi
if [ "$mode" = loadsilent ] && [ "$v" = "$FAKE_CAND" ] &&
   [ $(( $(date +%s) - $(cat "$s/swapped") )) -lt "$(cat "$s/loadsecs")" ]; then exit 7; fi
if [ "$mode" = hang ] && [ "$v" = "$FAKE_CAND" ]; then
  [ ! -f "$s/answered" ] || exit 7
  touch "$s/answered"
fi
# dead: the candidate crashes, and the restored version never answers again.
if [ "$mode" = dead ] && [ -f "$s/swapped" ]; then exit 7; fi
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

# 1. check refuses a candidate whose metallib lacks gather_mm_offsets; swap
#    refuses it before any ssh; swap refuses unverified --tarball bytes.
reset_install
run_rc 3 "check refuses missing gather_mm_offsets" "$SWAP" check --version "$CAND" --tarball "$T/bad.tar.gz"
grep -q "missing 1 kernel(s) from gather_mm_offsets.metal" "$T/err" || die "check did not name the missing kernel"
verify_bytes "$T/bad.tar.gz"
run_rc 3 "swap refuses missing gather_mm_offsets" "$SWAP" swap --version "$CAND"
[ "$(installed)" = "$OLD" ] || die "refused swap changed the payload"
[ ! -f "$T/state/runner" ] || die "refused swap touched the buyer runner"
run_rc 3 "swap refuses --tarball" "$SWAP" swap --version "$CAND" --tarball "$T/good.tar.gz"
verify_bytes "$T/good.tar.gz"
cp "$T/bad.tar.gz" "$T/bytes/macprovider-cli-v$CAND-darwin-arm64.tar.gz"
run_rc 3 "swap refuses bytes that differ from the signed checksums" "$SWAP" swap --version "$CAND"
grep -q "does not match its signed checksums.txt entry" "$T/err" || die "checksum binding not named"
run_rc 0 "check passes a complete candidate" "$SWAP" check --version "$CAND" --tarball "$T/good.tar.gz"

# 1a. a candidate whose baked catalog is not the one Pearl serves is refused
#     by check and by swap before anything changes (1.8.262 canary failed with
#     rate_card_update_required); so is an unreadable or unset coordinator.
run_rc 3 "check refuses a catalog Pearl does not serve" "$SWAP" check --version "$CAND" --tarball "$T/newcat.tar.gz"
grep -q "candidate bakes catalog rel-new; Pearl serves rel-live: activate the catalog first (scripts/ops/catalog-activate.sh)" "$T/err" ||
  die "catalog mismatch not named"
verify_bytes "$T/newcat.tar.gz"
run_rc 3 "swap refuses a catalog Pearl does not serve" "$SWAP" swap --version "$CAND"
grep -q "Pearl serves rel-live: activate the catalog first" "$T/err" || die "swap catalog mismatch not named"
[ "$(installed)" = "$OLD" ] || die "catalog-refused swap changed the payload"
[ ! -f "$T/state/runner" ] || die "catalog-refused swap touched the buyer runner"
[ ! -f "$MACPROVIDER_LIVE_LOCK" ] || die "catalog-refused swap took the live-ops lock"
cp "$T/coord/v1/rate-card" "$T/rate-card.live"
printf '{"generated_at":"2026-10-21T00:00:00Z","version":"v-old"}\n' >"$T/coord/v1/rate-card"
run_rc 3 "check refuses a rate card Pearl does not serve" "$SWAP" check --version "$CAND" --tarball "$T/good.tar.gz"
grep -q "rate-card.json generated_at/version" "$T/err" || die "rate-card mismatch not named"
mv "$T/rate-card.live" "$T/coord/v1/rate-card"
# 1b. a cut that packaged a first native-MTP admission scope bakes a catalog
#     older than the rebound one Pearl then serves. The provider accepts a newer
#     fetched feed of the same policy, so check passes when the rate-card content
#     version is the same; a changed price or an older/equal live stamp still refuses.
cp "$T/coord/v1/autotune-release" "$T/release.live"
cp "$T/coord/v1/rate-card" "$T/rate-card.live"
printf '{"release_id":"rel-rebound","generated_at":"2026-10-24T06:00:00Z","status":"live_verified"}\n' >"$T/coord/v1/autotune-release"
printf '{"generated_at":"2026-10-24T06:00:00Z","version":"v-new"}\n' >"$T/coord/v1/rate-card"
run_rc 0 "check passes a baked catalog older than Pearl's rebound release" "$SWAP" check --version "$CAND" --tarball "$T/newcat.tar.gz"
grep -q "Pearl serves the newer rel-rebound" "$T/err" || die "newer live release not named"
printf '{"generated_at":"2026-10-24T06:00:00Z","version":"v-repriced"}\n' >"$T/coord/v1/rate-card"
run_rc 3 "check refuses a newer live release whose rate card content differs" "$SWAP" check --version "$CAND" --tarball "$T/newcat.tar.gz"
grep -q "differs: release_id" "$T/err" || die "repriced newer release not refused"
printf '{"generated_at":"2026-10-22T06:00:00Z","version":"v-new"}\n' >"$T/coord/v1/rate-card"
run_rc 3 "check refuses a live rate card older than the baked one" "$SWAP" check --version "$CAND" --tarball "$T/newcat.tar.gz"
printf '{"release_id":"rel-rebound","generated_at":"2026-10-24T06:00:00Z","policy_version":"autotune-policy-v2","status":"live_verified"}\n' >"$T/coord/v1/autotune-release"
printf '{"generated_at":"2026-10-24T06:00:00Z","version":"v-new"}\n' >"$T/coord/v1/rate-card"
run_rc 3 "check refuses a newer live release of another policy_version" "$SWAP" check --version "$CAND" --tarball "$T/newcat.tar.gz"
mv "$T/release.live" "$T/coord/v1/autotune-release"
mv "$T/rate-card.live" "$T/coord/v1/rate-card"
run_rc 3 "check refuses without COORDINATOR_URL" env -u COORDINATOR_URL "$SWAP" check --version "$CAND" --tarball "$T/good.tar.gz"
run_rc 3 "check refuses an unreadable coordinator" env COORDINATOR_URL="$COORDINATOR_URL/missing" "$SWAP" check --version "$CAND" --tarball "$T/good.tar.gz"

# 2. healthy swap: candidate installed, backup kept, resumed, runner restarted,
#    canary_swap recorded for the canary_smoke probe.
reset_install
verify_bytes "$T/good.tar.gz"
run_rc 0 "healthy swap" "$SWAP" swap --version "$CAND"
[ "$(installed)" = "$CAND" ] || die "healthy swap did not install the candidate"
ls -d "$FAKE_INSTALL".pre-"$CAND"-* >/dev/null || die "no backup of the previous payload"
grep -qx resume_request "$T/state/frames" || die "healthy swap never resumed the provider"
[ ! -f "$T/state/paused" ] || die "provider left paused"
[ "$(tr '\n' ' ' <"$T/state/runner")" = "stopped started " ] || die "runner not stopped then restarted"
[ ! -f "$MACPROVIDER_LIVE_LOCK" ] || die "live-ops lock not released"
[ ! -d "$HOME/.macprovider-canary-swap.lock" ] || die "canary-host lock not released"
grep -q '"kernel_check": "passed"' "$T/ops-state/cli-release-$CAND/canary_swap.json" || die "no canary_swap record"

# 3. crash loop: the candidate restarts, the previous version comes back serving.
reset_install
verify_bytes "$T/good.tar.gz"
echo crash >"$T/state/mode"
run_rc 5 "crash loop restores the backup" "$SWAP" swap --version "$CAND"
grep -q "crash loop" "$T/err" || die "crash loop not named"
[ "$(installed)" = "$OLD" ] || die "crash loop left the candidate installed"
ls -d "$FAKE_INSTALL".failed-"$CAND"-* >/dev/null || die "failed payload not kept"
[ ! -f "$T/state/paused" ] || die "restored provider left paused"
[ "$(tr '\n' ' ' <"$T/state/runner")" = "stopped started " ] || die "runner not restarted after rollback"
[ ! -f "$T/ops-state/cli-release-$CAND/canary_swap.json" ] || die "failed swap recorded canary_swap"

# 4. /v1/status silence while the model loads is not a failure: a candidate
#    silent for longer than CANARY_STATUS_TIMEOUT_S (3 s) with a stable pid is
#    swapped in once it answers. Silence after the model loaded is a hang and
#    restores the backup after CANARY_STATUS_TIMEOUT_S; a candidate that never
#    answers is bounded by CANARY_READY_TIMEOUT_S.
reset_install
verify_bytes "$T/good.tar.gz"
echo loadsilent >"$T/state/mode"; echo 7 >"$T/state/loadsecs"
run_rc 0 "status silence during a long model load is not a failure" "$SWAP" swap --version "$CAND"
[ "$(installed)" = "$CAND" ] || die "a long model load rolled the candidate back"
grep -q "model loaded on $CAND after" "$T/err" || die "model load not reported"
reset_install
verify_bytes "$T/good.tar.gz"
echo hang >"$T/state/mode"
run_rc 5 "status silence after the model loaded restores the backup" "$SWAP" swap --version "$CAND"
grep -q "/v1/status not answering for 3s after the model loaded" "$T/err" || die "post-load status silence not named"
[ "$(installed)" = "$OLD" ] || die "post-load status silence left the candidate installed"
reset_install
verify_bytes "$T/good.tar.gz"
echo silent >"$T/state/mode"
run_rc 5 "a candidate that never answers is bounded by the ready timeout" env CANARY_READY_TIMEOUT_S=8 "$SWAP" swap --version "$CAND"
grep -q "not buyer_serving within 8s" "$T/err" || die "ready timeout not named"
[ "$(installed)" = "$OLD" ] || die "a silent candidate was left installed"

# 5. a rollback whose previous version does not come back serving needs the operator.
reset_install
echo dead >"$T/state/mode"
run_rc 6 "rollback that does not serve again" "$SWAP" swap --version "$CAND"
grep -q "is not buyer_serving within" "$T/err" || die "unhealthy rollback not named"
[ "$(tr '\n' ' ' <"$T/state/runner")" = "stopped " ] || die "runner restarted onto a canary that needs the operator"

# 5a. an installed watchdog stays unloaded while the candidate loads (an armed
#     watchdog would kickstart it mid-load) and is restarted once it serves.
reset_install
verify_bytes "$T/good.tar.gz"
touch "$HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist" "$T/state/wd"
echo wdkick >"$T/state/mode"
run_rc 0 "watchdog held off during the candidate load" "$SWAP" swap --version "$CAND"
[ "$(installed)" = "$CAND" ] || die "watchdog kick rolled the candidate back"
[ -f "$T/state/wd" ] || die "watchdog not restarted after the candidate served"
grep -q "watchdog live.malibu.provider-watchdog restarted" "$T/err" || die "watchdog restart not reported"
# watchdog after a rollback: restarted when the old version serves again (rc 5);
# reported as left unloaded when the operator must recover (rc 6).
reset_install
verify_bytes "$T/good.tar.gz"
touch "$T/state/wd"
echo crash >"$T/state/mode"
run_rc 5 "watchdog restarted after a rollback" "$SWAP" swap --version "$CAND"
[ -f "$T/state/wd" ] || die "watchdog not restarted after the rollback served"
reset_install
verify_bytes "$T/good.tar.gz"
touch "$T/state/wd"
echo dead >"$T/state/mode"
run_rc 6 "watchdog reported unloaded on operator recovery" "$SWAP" swap --version "$CAND"
[ ! -f "$T/state/wd" ] || die "watchdog loaded onto a canary that needs the operator"
grep -q "watchdog live.malibu.provider-watchdog left unloaded" "$T/err" || die "unloaded watchdog not reported"
rm -f "$HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist" "$T/state/wd" "$T/state/mode"

# 5b. an install dir reached through a symlinked ancestor is refused untouched.
reset_install
mkdir -p "$T/elsewhere"
mv "$FAKE_INSTALL" "$T/elsewhere/macprovider"
ln -s "$T/elsewhere" "$HOME/link"
run_rc 4 "install dir behind a symlinked ancestor" env CANARY_INSTALL_DIR="$HOME/link/macprovider" "$SWAP" swap --version "$CAND"
grep -q "resolves through a symlink" "$T/err" || die "symlinked ancestor not named"
rm "$HOME/link"; mv "$T/elsewhere/macprovider" "$FAKE_INSTALL"

# 6. preconditions: owner, runner commands, a busy canary-host lock, a
#    half-failed runner stop (restarted anyway).
reset_install
run_rc 3 "swap without an owner" env -u MACPROVIDER_OPS_OWNER "$SWAP" swap --version "$CAND"
run_rc 3 "swap without runner commands" env -u CANARY_RUNNER_STOP_CMD "$SWAP" swap --version "$CAND"
mkdir "$HOME/.macprovider-canary-swap.lock"; echo $$ >"$HOME/.macprovider-canary-swap.lock/pid"
run_rc 4 "swap refused while another swap holds the canary" "$SWAP" swap --version "$CAND"
[ -d "$HOME/.macprovider-canary-swap.lock" ] || die "refused swap removed another swap's lock"
rm -rf "$HOME/.macprovider-canary-swap.lock"
: >"$T/state/runner"
run_rc 3 "half-failed runner stop" env CANARY_RUNNER_STOP_CMD="echo stopped >> '$T/state/runner'; false" "$SWAP" swap --version "$CAND"
[ "$(tr '\n' ' ' <"$T/state/runner")" = "stopped started " ] || die "half-stopped runner not restarted"
[ "$(installed)" = "$OLD" ] || die "refused swap changed the payload"

log PASS
