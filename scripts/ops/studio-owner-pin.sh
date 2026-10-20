#!/usr/bin/env bash
# Remove the Studio GLM provider's temporary 4/owner concurrency pin only
# after the installed CLI is the exact published, signed release and the
# installed live-verified policy independently supplies a four-slot ceiling.
#
# Usage:
#   scripts/ops/studio-owner-pin.sh status
#   scripts/ops/studio-owner-pin.sh next
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/studio-owner-pin.sh next --run
#
# The mutating step stops the buyer runner, then the remote transaction pauses
# and drains the provider, removes only max_concurrency_override and
# max_concurrency_source under the provider-config lock, restarts, and waits up
# to 20 minutes for a new stable buyer-serving PID at four slots. The journal
# remains armed through the existing provider-attributed gateway proof. Any
# failure or signal restores only the two pin fields before restarting the
# buyer runner; unrelated concurrent config edits are preserved.
#
# Required private environment (normally ~/.config/macprovider/ops.env):
# STUDIO_SSH, STUDIO_SSH_KEY (optional), STUDIO_STATUS_PORT,
# STUDIO_OWNER_PIN_INSTALL_DIR, STUDIO_OWNER_PIN_CONFIG,
# STUDIO_OWNER_PIN_JOURNAL, CANARY_LAUNCHD_LABEL, CANARY_CTL_SOCKET,
# CANARY_RUNNER_STOP_CMD, CANARY_RUNNER_START_CMD, GATEWAY_URL,
# BUYER_TOKEN_FILE, PEARL_SSH and PEARL_COORDINATOR_DB.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_NAME=studio-owner-pin
# shellcheck source=lib/common.sh
. "$OPS_DIR/lib/common.sh"

MODEL="zai-org/glm-5.3-flash"
STUDIO_HARDWARE_MODEL="Mac15,14"
OPS_SCOPE=studio-owner-pin
PROBE="$OPS_DIR/lib/studio-owner-pin-probe.py"
CONFIG_HELPER="$OPS_DIR/lib/studio-owner-pin-config.py"
REMOTE="$OPS_DIR/lib/canary-swap-remote.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

plain_remote_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *"/../"* ]] && [[ "$1" != */.. ]] && [[ "$1" != *"//"* ]]
}

q() {
  case "$1" in *"'"*) refuse "owner-pin setting contains a single quote" ;; esac
  printf "'%s'" "$1"
}

require_settings() {
  require_studio_ssh
  [ "$STUDIO_SSH" != local ] || refuse "the owner-pin transaction must run on the designated Studio over SSH, never on this operator Mac"
  case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac
  local name value
  for name in STUDIO_OWNER_PIN_INSTALL_DIR STUDIO_OWNER_PIN_CONFIG STUDIO_OWNER_PIN_JOURNAL; do
    value="${!name:-}"
    if [ -z "$value" ] || ! plain_remote_path "$value"; then
      refuse "$name must be an absolute plain path"
    fi
  done
  [ -n "${CANARY_RUNNER_STOP_CMD:-}" ] && [ -n "${CANARY_RUNNER_START_CMD:-}" ] ||
    refuse "CANARY_RUNNER_STOP_CMD and CANARY_RUNNER_START_CMD are required"
  STATUS_TIMEOUT_S="${CANARY_STATUS_TIMEOUT_S:-900}"
  READY_TIMEOUT_S="${CANARY_READY_TIMEOUT_S:-1200}"
  DRAIN_TIMEOUT_S="${CANARY_DRAIN_TIMEOUT_S:-600}"
  STABLE_S="${CANARY_STABLE_S:-120}"
  POLL_S="${CANARY_POLL_S:-5}"
  for value in "$STATUS_TIMEOUT_S" "$READY_TIMEOUT_S" "$DRAIN_TIMEOUT_S" "$STABLE_S" "$POLL_S"; do
    case "$value" in ""|*[!0-9]*) refuse "CANARY_*_S values must be whole seconds" ;; esac
  done
  [ "$READY_TIMEOUT_S" -gt 0 ] && [ "$READY_TIMEOUT_S" -le 1200 ] ||
    refuse "CANARY_READY_TIMEOUT_S must be 1..1200"
  for value in "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}" "${CANARY_CTL_SOCKET:-}"; do q "$value" >/dev/null; done
}

# Read only the durable journal first. Recovery must not depend on a running
# provider, GitHub, release markers, buyer credentials, or Pearl access.
journal_probe() {
  studio_ssh "python3 - --journal-only --journal $(q "$STUDIO_OWNER_PIN_JOURNAL") --expected-config $(q "$STUDIO_OWNER_PIN_CONFIG")" < "$PROBE" 2>/dev/null
}

remote_probe() {
  studio_ssh "python3 - --install-dir $(q "$STUDIO_OWNER_PIN_INSTALL_DIR") --config $(q "$STUDIO_OWNER_PIN_CONFIG") --journal $(q "$STUDIO_OWNER_PIN_JOURNAL") --port $(q "$STUDIO_STATUS_PORT") --model $(q "$MODEL")" < "$PROBE"
}

jget() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1],{"d":d}); print(json.dumps(v) if isinstance(v,(dict,list,bool)) else ("" if v is None else v))' "$2" 2>/dev/null || true; }

VERSION="" BINARY_SHA="" PROVIDER_SHA="" POLICY_SHA="" POLICY_RELEASE="" POLICY_TUPLE="" PRE_PID="" PROBE_JSON=""

published_identity_ok() {
  local scope marker bytes pearl release expected_cdhash
  scope="cli-release-$VERSION"
  marker="$(marker_path "$scope" signed_byte_verification)"
  [ -f "$marker" ] || return 1
  BINARY_SHA="$(json_field "$marker" 'd.get("binary_sha256")')"
  bytes="$(json_field "$marker" 'd.get("bytes_dir")')"
  [ -n "$BINARY_SHA" ] && [ -d "$bytes" ] || return 1
  pearl="$bytes/pearl-release.json"
  [ -f "$pearl" ] || return 1
  [ "$(json_field "$pearl" 'd.get("provider_code_identity",{}).get("binary_version")')" = "$VERSION" ] || return 1
  [ "$(json_field "$pearl" 'd.get("provider_code_identity",{}).get("binary_sha256")')" = "$BINARY_SHA" ] || return 1
  [ "$(jget "$PROBE_JSON" 'd["installed"]["binary_sha256"]')" = "$BINARY_SHA" ] || return 1
  [ "$(jget "$PROBE_JSON" 'd["installed"]["binary_version"]')" = "$VERSION" ] || return 1
  [ "$(jget "$PROBE_JSON" 'd["installed"]["team_id"]')" = "$(json_field "$pearl" 'd["provider_code_identity"]["team_id"]')" ] || return 1
  [ "$(jget "$PROBE_JSON" 'd["installed"]["identifier"]')" = "$(json_field "$pearl" 'd["provider_code_identity"]["signing_identifier"]')" ] || return 1
  expected_cdhash="$(json_field "$pearl" 'next((s.get("code_cdhash") for s in d["provider_code_identity"].get("slices",[]) if s.get("arch")=="arm64"), None)')"
  [ -n "$expected_cdhash" ] && [ "$(jget "$PROBE_JSON" 'd["installed"]["cdhash"]')" = "$expected_cdhash" ] || return 1
  release="$(gh release view "v$VERSION" -R "$(gh_repo)" --json tagName,isDraft,isPrerelease,publishedAt 2>/dev/null)" || return 1
  [ "$(jget "$release" 'd["tagName"]')" = "v$VERSION" ] &&
    [ "$(jget "$release" 'd["isDraft"]')" = false ] &&
    [ "$(jget "$release" 'd["isPrerelease"]')" = false ] &&
    [ -n "$(jget "$release" 'd["publishedAt"]')" ]
}

serving_tuple_ok() {
  [ "$(jget "$1" 'd["status"]["binary_version"]')" = "$VERSION" ] &&
    [ "$(jget "$1" 'd["status"]["model"]')" = "$MODEL" ] &&
    [ "$(jget "$1" 'd["status"]["model_loaded"]')" = true ] &&
    [ "$(jget "$1" 'd["status"]["network_state"]')" = buyer_serving ] &&
    [ "$(jget "$1" 'd["status"]["capacity.max_concurrency"]')" = 4 ] &&
    [ "$(jget "$1" 'd["status"]["continuous_batching.active"]')" = true ] &&
    [ "$(jget "$1" 'd["status"]["continuous_batching.policy.load_status"]')" = live_verified ] &&
    [ "$(jget "$1" 'd["status"]["continuous_batching.policy.authorized"]')" = true ] &&
    [ "$(jget "$1" 'd["status"]["continuous_batching.policy.policy_sha256"]')" = "$POLICY_SHA" ] &&
    [ "$(jget "$1" 'd["status"]["continuous_batching.policy.release_id"]')" = "$POLICY_RELEASE" ] &&
    [ "$(jget "$1" 'd["status"]["continuous_batching.policy.tuple_sha256"]')" = "$POLICY_TUPLE" ] &&
    [ "$(jget "$1" 'd["status"]["continuous_batching.self_check.served_slots"]')" = 4 ] &&
    [ "$(jget "$1" 'd["status"]["continuous_batching.scheduler.slots_total"]')" = 4 ] &&
    [ "$(jget "$1" 'd["status"]["coordinator.connected"]')" = true ] &&
    [ "$(jget "$1" 'd["status"]["lifecycle.operator_paused"]')" != true ]
}

load_probe_values() {
  VERSION="$(jget "$PROBE_JSON" 'd["installed"]["binary_version"]')"
  POLICY_SHA="$(jget "$PROBE_JSON" 'd["policy"]["sha256"]')"
  POLICY_RELEASE="$(jget "$PROBE_JSON" 'd["policy"]["release_id"]')"
  POLICY_TUPLE="$(jget "$PROBE_JSON" 'd["policy"]["tuple_sha256"]')"
  PROVIDER_SHA="$(jget "$PROBE_JSON" 'd["status"]["provider_id_sha256"]')"
  PRE_PID="$(jget "$PROBE_JSON" 'd["status"]["service_instance.pid"]')"
}

gather() {
  require_settings
  local journal completion pin_a pin_b cmp
  journal="$(journal_probe)" || { fact journal unreadable; step recovery blocked "journal probe failed"; set_next recovery blocked "Inspect the durable Studio transaction journal" "" "journal probe failed"; return; }
  fact journal "$(jget "$journal" 'd["journal"]["state"]')"
  [ "$(jget "$journal" 'd["hardware_model"]')" = "$STUDIO_HARDWARE_MODEL" ] || { step restore blocked "wrong hardware host"; set_next restore blocked "Refuse Studio transaction" "" "SSH target is not the designated Mac15,14 Studio"; return; }
  if [ "$(jget "$journal" 'd["journal"]["state"]')" = present ]; then
    VERSION="$(jget "$journal" 'd["journal"]["version"]')"
    PROVIDER_SHA="$(jget "$journal" 'd["journal"]["provider_id_sha256"]')"
    POLICY_SHA="$(jget "$journal" 'd["journal"]["policy_sha256"]')"
    POLICY_RELEASE="$(jget "$journal" 'd["journal"]["policy_release_id"]')"
    POLICY_TUPLE="$(jget "$journal" 'd["journal"]["policy_tuple_sha256"]')"
    step restore pending "unfinished phase $(jget "$journal" 'd["journal"]["phase"]')"
    set_next restore mutate "Restore the scoped 4/owner pin before any other action" "scripts/ops/studio-owner-pin.sh _apply restore"
    NEXT_DOWNTIME="Studio provider restart/model load; no Pearl restart; buyer runner is restored on every exit"
    return
  fi
  PROBE_JSON="$(remote_probe)" || { fact preflight failed; step remove blocked "sanitized Studio probe failed"; set_next remove blocked "Refuse owner-pin removal" "" "sanitized Studio probe failed"; return; }
  load_probe_values
  [ "$(jget "$PROBE_JSON" 'd["hardware_model"]')" = "$STUDIO_HARDWARE_MODEL" ] || { step remove blocked "wrong hardware host"; set_next remove blocked "Refuse owner-pin removal" "" "SSH target is not the designated Mac15,14 Studio"; return; }
  fact version "$VERSION"; fact model "$(jget "$PROBE_JSON" 'd["status"]["model"]')"; fact network_state "$(jget "$PROBE_JSON" 'd["status"]["network_state"]')"
  fact policy_release_id "$POLICY_RELEASE"; fact policy_tuple_sha256 "$POLICY_TUPLE"
  is_semver "$VERSION" || { step remove blocked "installed CLI version is not semver"; set_next remove blocked "Refuse owner-pin removal" "" "installed CLI version is not semver"; return; }
  cmp="$(semver_cmp "$VERSION" 1.8.260)"
  [ "$cmp" -ge 0 ] || { step remove blocked "requires queue-clamp-capable CLI >= 1.8.260"; set_next remove blocked "Refuse owner-pin removal" "" "installed CLI is older than 1.8.260"; return; }
  POLICY_SHA="$(jget "$PROBE_JSON" 'd["policy"]["sha256"]')"
  [ "$(jget "$PROBE_JSON" 'd["policy"]["max_served_slots"]')" = 4 ] || { step remove blocked "installed GLM policy ceiling is not four"; set_next remove blocked "Refuse owner-pin removal" "" "installed signed policy has no four-slot GLM ceiling"; return; }
  serving_tuple_ok "$PROBE_JSON" || { step remove blocked "live tuple is not exact/ready"; set_next remove blocked "Refuse owner-pin removal" "" "provider is not buyer-serving on the exact signed four-slot tuple"; return; }
  published_identity_ok || { step remove blocked "installed CLI is not the exact published signed release"; set_next remove blocked "Refuse owner-pin removal" "" "published signed installed identity check failed"; return; }
  fact installed_binary_sha256 "$BINARY_SHA"
  pin_a="$(jget "$PROBE_JSON" 'd["config"]["max_concurrency_override"]')"
  pin_b="$(jget "$PROBE_JSON" 'd["config"]["max_concurrency_source"]')"
  completion="$(marker_path "$OPS_SCOPE" complete)"
  if [ -z "$pin_a$pin_b" ]; then
    if [ -f "$completion" ] && [ "$(json_field "$completion" 'd.get("version")')" = "$VERSION" ] &&
       [ "$(json_field "$completion" 'd.get("binary_sha256")')" = "$BINARY_SHA" ] &&
       [ "$(json_field "$completion" 'd.get("policy_sha256")')" = "$POLICY_SHA" ] &&
       [ "$(json_field "$completion" 'd.get("provider_id_sha256")')" = "$PROVIDER_SHA" ]; then
      step remove "done" "published $VERSION serving at signed ceiling 4; provider-attributed proof recorded"
      set_next complete "done" "Owner pin is removed and proven" ""
    else
      step remove blocked "pin absent without this transaction's completion marker"
      set_next remove blocked "Refuse untracked owner-pin state" "" "pin is absent but no matching durable completion record exists"
    fi
    return
  fi
  [ "$pin_a" = 4 ] && [ "$pin_b" = owner ] || { step remove blocked "pin is not exact 4/owner"; set_next remove blocked "Refuse owner-pin removal" "" "owned fields are not the exact expected 4/owner pair"; return; }
  step remove pending "exact published signed $VERSION and signed four-slot GLM ceiling verified"
  set_next remove mutate "Remove the Studio concurrency owner pin transactionally" "scripts/ops/studio-owner-pin.sh _apply remove"
  NEXT_DOWNTIME="Studio provider drain/restart and 7-13 minute GLM model load (20 minute bound); no Pearl restart; buyer runner is restored on every exit"
}

stage_file() {
  local source="$1" target="$2"
  studio_ssh "python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); data=sys.stdin.buffer.read(); os.write(fd,data); os.fsync(fd); os.close(fd)' $(q "$target")" < "$source"
}

REMOTE_STAGE="" RUNNER_TOUCHED=0 TX_ARMED=0 REMOTE_ACTIVE=0 IN_CLEANUP=0

remote_args() {
  printf '%s ' "$(q "$VERSION")" "$(q "$STUDIO_OWNER_PIN_INSTALL_DIR")" "$(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}")" \
    "$(q "${CANARY_CTL_SOCKET:-}")" "$(q "$STUDIO_STATUS_PORT")" "$(q "$STATUS_TIMEOUT_S")" \
    "$(q "$READY_TIMEOUT_S")" "$(q "$DRAIN_TIMEOUT_S")" \
    "$(q "$STABLE_S")" "$(q "$POLL_S")" "$(q "$REMOTE_STAGE/result")" \
    "$(q "$STUDIO_OWNER_PIN_CONFIG")" "$(q "$STUDIO_OWNER_PIN_JOURNAL")" "$(q "$REMOTE_STAGE/config.py")" \
    "$(q "$BINARY_SHA")" "$(q "$PROVIDER_SHA")" "$(q "$MODEL")" "$(q "$POLICY_SHA")" \
    "$(q "$POLICY_RELEASE")" "$(q "$POLICY_TUPLE")"
}

run_remote() {
  local mode="$1" deadline rc="" args
  args="$(remote_args)"
  # Mark uncertainty before dispatch: an SSH error can happen after the
  # detached process started but before its pid reaches this controller.
  REMOTE_ACTIVE=1
  studio_ssh "rm -f $(q "$REMOTE_STAGE/result"); cd $(q "$REMOTE_STAGE") || exit 1; nohup bash remote.sh $mode $args > run.log 2>&1 < /dev/null & pid=\$!; printf '%s\\n' \"\$pid\" > $(q "$REMOTE_STAGE/remote.pid")" || return 6
  deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S + 2 * READY_TIMEOUT_S + 600 ))
  while [ -z "$rc" ]; do
    rc="$(studio_ssh "cat $(q "$REMOTE_STAGE/result") 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]')" || true
    [ -n "$rc" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || return 6
    sleep "$POLL_S"
  done
  REMOTE_ACTIVE=0
  studio_ssh "cat $(q "$REMOTE_STAGE/run.log")" >&2 || true
  return "$rc"
}

quiesce_remote() {
  local pid rc="" deadline
  [ "$REMOTE_ACTIVE" = 1 ] || return 0
  pid="$(studio_ssh "cat $(q "$REMOTE_STAGE/remote.pid")" 2>/dev/null | tr -d '[:space:]')" || return 1
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  studio_ssh "python3 -c 'import os,signal,subprocess,sys; p=int(sys.argv[1]); c=subprocess.check_output([\"ps\",\"-p\",str(p),\"-o\",\"command=\"],text=True); ok=(\"bash remote.sh \" in c and sys.argv[2] in c); sys.exit(1) if not ok else os.kill(p,signal.SIGTERM)' $(q "$pid") $(q "$REMOTE_STAGE/result")" || return 1
  deadline=$(( $(date +%s) + READY_TIMEOUT_S + 120 ))
  while [ -z "$rc" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    rc="$(studio_ssh "cat $(q "$REMOTE_STAGE/result") 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]')" || true
    [ -n "$rc" ] || sleep "$POLL_S"
  done
  [ -n "$rc" ] || return 1
  REMOTE_ACTIVE=0
  [ "$rc" != 5 ] || TX_ARMED=0
  return 0
}

recover_if_armed() {
  [ "$TX_ARMED" = 1 ] || return 0
  log "restoring the scoped owner pin before returning control"
  if run_remote restore-owner-pin; then TX_ARMED=0; return 0; fi
  log "!!! owner-pin recovery remains journaled; run this entry point again before other Studio work"
  return 1
}

apply_cleanup() {
  local rc=$?
  [ "$IN_CLEANUP" = 0 ] || exit "$rc"
  IN_CLEANUP=1
  trap - EXIT INT TERM HUP
  if [ "$REMOTE_ACTIVE" = 1 ] && ! quiesce_remote; then
    log "!!! detached Studio transaction state is uncertain; scratch and journal retained"
    rc=6
  elif [ "$TX_ARMED" = 1 ]; then
    recover_if_armed || rc=6
  fi
  if [ "$RUNNER_TOUCHED" = 1 ]; then
    bash -c "$CANARY_RUNNER_START_CMD" >&2 || { log "!!! buyer runner restart failed"; rc=6; }
  fi
  if [ -n "$REMOTE_STAGE" ] && [ "$REMOTE_ACTIVE" = 0 ] && [ "$TX_ARMED" = 0 ]; then
    studio_ssh "python3 -c 'import os,shutil,sys; p=sys.argv[1]; root=os.path.join(os.path.expanduser(\"~\"),\"macprovider-owner-pin-staging\"); assert os.path.dirname(p)==root and os.path.basename(p).startswith(\"run-\"); shutil.rmtree(p)' $(q "$REMOTE_STAGE")" >/dev/null 2>&1 || true
  fi
  cleanup_ops
  exit "$rc"
}

apply_transaction() {
  local action="$1" result post post_pid proof
  require_settings
  PROBE_JSON="$(remote_probe)" || true
  if [ "$action" = restore ]; then
    result="$(journal_probe)" || refuse "durable journal is unreadable"
    [ "$(jget "$result" 'd["journal"]["state"]')" = present ] || refuse "no owner-pin journal to recover"
    [ "$(jget "$result" 'd["hardware_model"]')" = "$STUDIO_HARDWARE_MODEL" ] ||
      refuse "SSH target is not the designated Mac15,14 Studio"
    VERSION="$(jget "$result" 'd["journal"]["version"]')"; PROVIDER_SHA="$(jget "$result" 'd["journal"]["provider_id_sha256"]')"
    POLICY_SHA="$(jget "$result" 'd["journal"]["policy_sha256"]')"; POLICY_RELEASE="$(jget "$result" 'd["journal"]["policy_release_id"]')"
    POLICY_TUPLE="$(jget "$result" 'd["journal"]["policy_tuple_sha256"]')"; BINARY_SHA=""
  else
    [ -n "$PROBE_JSON" ] || refuse "sanitized Studio probe failed"
    load_probe_values
    [ "$(jget "$PROBE_JSON" 'd["hardware_model"]')" = "$STUDIO_HARDWARE_MODEL" ] ||
      refuse "SSH target is not the designated Mac15,14 Studio"
    published_identity_ok || refuse "installed CLI no longer matches the exact published signed release"
    serving_tuple_ok "$PROBE_JSON" || refuse "provider tuple changed before dispatch"
  fi
  # shellcheck disable=SC2016  # HOME expands on the Studio, not here.
  REMOTE_STAGE="$(studio_ssh 'umask 077; mkdir -p "$HOME/macprovider-owner-pin-staging"; chmod 700 "$HOME/macprovider-owner-pin-staging"; mktemp -d "$HOME/macprovider-owner-pin-staging/run-XXXXXX"')" || refuse "could not create protected Studio scratch"
  case "$REMOTE_STAGE" in /*/macprovider-owner-pin-staging/run-*) ;; *) refuse "unexpected Studio scratch path" ;; esac
  trap apply_cleanup EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
  stage_file "$REMOTE" "$REMOTE_STAGE/remote.sh" || refuse "could not stage reviewed lifecycle helper"
  stage_file "$CONFIG_HELPER" "$REMOTE_STAGE/config.py" || refuse "could not stage reviewed config helper"
  [ "$(studio_ssh "shasum -a 256 $(q "$REMOTE_STAGE/remote.sh") | awk '{print \$1}'")" = "$(shasum -a 256 "$REMOTE" | awk '{print $1}')" ] || refuse "staged lifecycle helper hash mismatch"
  [ "$(studio_ssh "shasum -a 256 $(q "$REMOTE_STAGE/config.py") | awk '{print \$1}'")" = "$(shasum -a 256 "$CONFIG_HELPER" | awk '{print $1}')" ] || refuse "staged config helper hash mismatch"
  if [ "$CANARY_RUNNER_STOP_CMD" != none ]; then
    RUNNER_TOUCHED=1
    bash -c "$CANARY_RUNNER_STOP_CMD" >&2 || refuse "buyer runner stop failed"
  fi
  if [ "$action" = restore ]; then
    TX_ARMED=1
    run_remote restore-owner-pin
    TX_ARMED=0
    return 0
  fi
  PRE_PID="$(jget "$PROBE_JSON" 'd["status"]["service_instance.pid"]')"
  TX_ARMED=1
  if run_remote remove-owner-pin; then :; else result=$?; [ "$result" = 5 ] && TX_ARMED=0; return "$result"; fi
  proof="$({ CATALOG_REQUIRE_NATIVE_MTP_FORWARD=true PROBE_MODEL="$MODEL" "$OPS_DIR/catalog-activate.sh" _gateway-proof; } 2>&1)" || {
    log "provider-attributed gateway proof failed"; return 1;
  }
  post="$(remote_probe)" || { log "post-proof Studio probe failed"; return 1; }
  serving_tuple_ok "$post" || { log "post-proof signed tuple check failed"; return 1; }
  post_pid="$(jget "$post" 'd["status"]["service_instance.pid"]')"
  [ -n "$PRE_PID" ] && [ -n "$post_pid" ] && [ "$post_pid" != "$PRE_PID" ] || { log "provider did not expose the required new PID"; return 1; }
  studio_ssh "python3 $(q "$REMOTE_STAGE/config.py") finish --config $(q "$STUDIO_OWNER_PIN_CONFIG") --journal $(q "$STUDIO_OWNER_PIN_JOURNAL")" >/dev/null || {
    log "could not finalize owner-pin journal after proof"; return 1;
  }
  TX_ARMED=0
  mark_done "$OPS_SCOPE" complete "published signed $VERSION; four-slot GLM ceiling; new PID; provider-attributed gateway proof" \
    "$(python3 -c 'import hashlib,json,sys; print(json.dumps({"version":sys.argv[1],"binary_sha256":sys.argv[2],"policy_sha256":sys.argv[3],"policy_release_id":sys.argv[4],"policy_tuple_sha256":sys.argv[5],"provider_id_sha256":sys.argv[6],"previous_pid":sys.argv[7],"new_pid":sys.argv[8],"gateway_proof_sha256":hashlib.sha256(sys.argv[9].encode()).hexdigest()}))' "$VERSION" "$BINARY_SHA" "$POLICY_SHA" "$POLICY_RELEASE" "$POLICY_TUPLE" "$PROVIDER_SHA" "$PRE_PID" "$post_pid" "$proof")"
}

internal() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse "internal actions run only through next --run"
  case "$1" in
    _apply) case "${2:-}" in remove|restore) apply_transaction "$2" ;; *) usage >&2; exit 2 ;; esac ;;
    *) usage >&2; exit 2 ;;
  esac
}

ops_main "$@"
