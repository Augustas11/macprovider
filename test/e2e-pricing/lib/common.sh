# shellcheck shell=bash
# Shared helpers for the tier E2 steps and scenarios. Source after env.sh.

# ---- target guard (runs when this file is sourced) ----------------------------
# The lane, deploy-pearl-vps.sh, the updater and the recovery helper default to
# PEARL_SSH/VPS_HOST=pearl: the operator's REAL Pearl in ~/.ssh/config. Every
# harness step sources this file, so a step that would reach anything but the
# VM alias fails here, before its first command. The alias must resolve, in
# $E2E_SSH_CONFIG only, to this Mac's loopback (Lima's forwarded port).
# Self-test: test/e2e-pricing/lib/guard-selftest.sh.
E2E_VM_ALIAS=pearl-e2e
e2e_guard_vm_target() {
  local v resolved host proxy jump
  [ "${E2E_PEARL:-}" = "$E2E_VM_ALIAS" ] ||
    { echo "[e2e] SAFETY: E2E_PEARL='${E2E_PEARL:-}' is not the VM alias $E2E_VM_ALIAS; refusing" >&2; return 1; }
  for v in PEARL_SSH VPS_HOST; do
    [ "${!v:-}" = "$E2E_VM_ALIAS" ] ||
      { echo "[e2e] SAFETY: $v='${!v:-}' is not the VM alias $E2E_VM_ALIAS; refusing" >&2; return 1; }
  done
  [ -n "${E2E_SSH_CONFIG:-}" ] && [ -f "$E2E_SSH_CONFIG" ] ||
    { echo "[e2e] SAFETY: ssh config '${E2E_SSH_CONFIG:-}' is missing (run 00-setup-vm.sh); refusing" >&2; return 1; }
  resolved="$(/usr/bin/ssh -G -F "$E2E_SSH_CONFIG" "$E2E_VM_ALIAS" 2>/dev/null)" ||
    { echo "[e2e] SAFETY: cannot resolve $E2E_VM_ALIAS in $E2E_SSH_CONFIG; refusing" >&2; return 1; }
  host="$(awk '$1 == "hostname" { print $2; exit }' <<<"$resolved")"
  proxy="$(awk '$1 == "proxycommand" { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$resolved")"
  jump="$(awk '$1 == "proxyjump" { print $2; exit }' <<<"$resolved")"
  [ "$host" = 127.0.0.1 ] ||
    { echo "[e2e] SAFETY: $E2E_VM_ALIAS resolves to hostname '$host', not 127.0.0.1; refusing" >&2; return 1; }
  [ -z "$jump" ] || [ "$jump" = none ] ||
    { echo "[e2e] SAFETY: $E2E_VM_ALIAS has ProxyJump '$jump'; refusing" >&2; return 1; }
  case "$proxy" in
    ""|none) ;;
    "/usr/bin/nc 127.0.0.1 "*)
      case "${proxy#/usr/bin/nc 127.0.0.1 }" in ""|*[!0-9]*) echo "[e2e] SAFETY: $E2E_VM_ALIAS ProxyCommand '$proxy' is not the loopback forward; refusing" >&2; return 1 ;; esac ;;
    *) echo "[e2e] SAFETY: $E2E_VM_ALIAS ProxyCommand '$proxy' is not the loopback forward; refusing" >&2; return 1 ;;
  esac
}
export PEARL_SSH="${PEARL_SSH-$E2E_VM_ALIAS}" VPS_HOST="${VPS_HOST-$E2E_VM_ALIAS}"
e2e_guard_vm_target || exit 70

E2E_TUNNEL_PIDFILE="$E2E_WORK/tunnel.pid"
E2E_GATEWAY_LOCAL_PORT=19443     # Mac -> VM gateway 127.0.0.1:9443
E2E_BUYER_LOCAL_PORT=18843       # Mac -> VM coordinator buyer mux 127.0.0.1:8443
E2E_PROVIDER_LOCAL_PORT=18844    # Mac -> VM coordinator provider port 127.0.0.1:8444
E2E_CANARY_ENDPOINT_PORT=19190   # VM -> Mac canary stand-in inference endpoint

# ---- scratch checkout --------------------------------------------------------
e2e_checkout() { # <tag|branch|commit>: clean checkout + that tag's cached linux binaries
  local ref="$1" tag
  git -C "$E2E_REPO" checkout -q "$ref"
  tag="$(git -C "$E2E_REPO" tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)"
  if [ -n "$tag" ] && [ -d "$E2E_WORK/bins/$tag" ]; then
    cp "$E2E_WORK/bins/$tag"/coordinator*-linux-amd64 "$E2E_WORK/bins/$tag"/stats-*-linux-amd64 "$E2E_REPO/phase4-coordinator/dist/"
    cp "$E2E_WORK/bins/$tag/gateway-linux-amd64" "$E2E_REPO/phase5-gateway/dist/"
  fi
  [ -z "$(git -C "$E2E_REPO" status --porcelain)" ] || e2e_die "scratch checkout of $ref is dirty"
}

# e2e_new_tag <tag> <commit>: sign + push a new scratch release tag (mirrors
# 01-scratch-repo.sh's tag creation, minus the genesis/base-tree work — used
# for a tag cut *after* the scratch repo already exists, e.g. V10 b-fix's
# post-pricing-correction tag).
e2e_new_tag() {
  local tag="$1" commit="$2"
  git -C "$E2E_REPO" tag -s -m "$tag (e2e scratch tag)" "$tag" "$commit"
  git -C "$E2E_REPO" push -q origin "refs/tags/$tag"
  git -C "$E2E_REPO" fetch -q origin
}

# e2e_build_and_release_tag <tag>: build + cache a scratch tag's linux
# binaries and gh-release stand-in, the way 02-build.sh does for the two base
# tags (E2E_TAG_PRE/E2E_TAG_ENABLE). Leaves the checkout back where it started.
e2e_build_and_release_tag() {
  local tag="$1" orig
  orig="$(git -C "$E2E_REPO" symbolic-ref -q --short HEAD || git -C "$E2E_REPO" rev-parse HEAD)"
  grep -qx 'phase4-coordinator/dist/stats-hardware-verifier-linux-amd64' "$E2E_REPO/.git/info/exclude" ||
    echo 'phase4-coordinator/dist/stats-hardware-verifier-linux-amd64' >>"$E2E_REPO/.git/info/exclude"
  # Restore the scratch checkout on every exit path, so a failed build never
  # leaves later scenarios running tooling from the wrong tag.
  _e2e_restore_checkout() { git -C "$E2E_REPO" checkout -q -f "$orig" 2>/dev/null || git -C "$E2E_REPO" checkout -q -f main; }
  git -C "$E2E_REPO" checkout -q "$tag"
  ( cd "$E2E_REPO" && make build-linux ) >"$E2E_LOGS/build-$tag.log" 2>&1 ||
    { tail -20 "$E2E_LOGS/build-$tag.log"; _e2e_restore_checkout; e2e_die "build at $tag failed"; }
  mkdir -p "$E2E_WORK/bins/$tag"
  cp "$E2E_REPO"/phase4-coordinator/dist/*-linux-amd64 "$E2E_REPO"/phase5-gateway/dist/gateway-linux-amd64 "$E2E_WORK/bins/$tag/"
  [ -z "$(git -C "$E2E_REPO" status --porcelain)" ] || { _e2e_restore_checkout; e2e_die "build dirtied the checkout at $tag"; }
  bash "$E2E_HARNESS/lib/make-gh-release.sh" "$tag" || { _e2e_restore_checkout; e2e_die "release stand-in for $tag failed"; }
  _e2e_restore_checkout
  e2e_log "built $tag: $(shasum -a 256 "$E2E_WORK/bins/$tag/coordinator-linux-amd64" | cut -c1-16)"
}

# ---- tunnels (the canary stand-in and the Mac-side gateway poll) --------------
e2e_tunnel_up() {
  e2e_tunnel_down
  (
    while :; do
      /usr/bin/ssh -F "$E2E_SSH_CONFIG" -N -o ExitOnForwardFailure=yes \
        -L "$E2E_GATEWAY_LOCAL_PORT:127.0.0.1:9443" \
        -L "$E2E_BUYER_LOCAL_PORT:127.0.0.1:8443" \
        -L "$E2E_PROVIDER_LOCAL_PORT:127.0.0.1:8444" \
        -R "$E2E_CANARY_ENDPOINT_PORT:127.0.0.1:$E2E_CANARY_ENDPOINT_PORT" \
        "$E2E_PEARL" 2>>"$E2E_LOGS/tunnel.log"
      sleep 2
      e2e_write_ssh_config 2>/dev/null || true
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $! >"$E2E_TUNNEL_PIDFILE"
}
e2e_tunnel_down() {
  if [ -f "$E2E_TUNNEL_PIDFILE" ]; then
    local p; p="$(cat "$E2E_TUNNEL_PIDFILE")"
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
    rm -f "$E2E_TUNNEL_PIDFILE"
  fi
}

# ---- operator-lane environment -------------------------------------------------
e2e_lane_env() {
  export PATH; PATH="$(e2e_lane_path)"
  export PEARL_SSH="$E2E_PEARL"
  unset PEARL_SSH_IDENTITY PEARL_SSH_KNOWN_HOSTS
  export CATALOG_CANARY_PROVIDER_ID="$E2E_CANARY_PROVIDER_ID"
  export CATALOG_CANARY_SSH_TARGET="$E2E_CANARY"
  export CATALOG_CANARY_SSH_KEY="$E2E_KEYS/canary_ed25519"
  export CATALOG_CANARY_INSTALL_DIR="macprovider/catalog-release"
  unset CATALOG_CANARY_AUTH_TOKEN
  export CATALOG_CANARY_AUTH_TOKEN_FILE="$E2E_KEYS/operator_key"
  export CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE="macprovider-e2e-nonexistent"
  # Shortened watch windows (documented deviation; semantics unchanged).
  export CATALOG_EVIDENCE_WATCH_SECONDS="${CATALOG_EVIDENCE_WATCH_SECONDS:-60}"
  export CATALOG_EVIDENCE_POLL_SECONDS="${CATALOG_EVIDENCE_POLL_SECONDS:-10}"
  export CATALOG_GATEWAY_RATE_CARD_URL="http://127.0.0.1:$E2E_GATEWAY_LOCAL_PORT/v1/rate-card"
  export CATALOG_GATEWAY_CONVERGENCE_SECONDS="${CATALOG_GATEWAY_CONVERGENCE_SECONDS:-420}"
  # The VM is x86_64 under qemu TCG on an arm64 Mac: the coordinator's
  # pre-listen startup ledger scan (24 h of request_log, ~20k rows by late in a
  # full run) takes 10-21 min here against well under a minute on Pearl
  # (ledger_reconciliation_runs, run3). The lane's 900 s default readiness
  # budget is sized for Pearl; the controlled restart must not time out on
  # emulation alone (documented deviation; semantics unchanged).
  export CATALOG_COORDINATOR_READY_SECONDS="${CATALOG_COORDINATOR_READY_SECONDS:-3600}"
  # deploy-pearl-vps.sh
  export SSH_KEY="$E2E_KEYS/pearl_root_ed25519" VPS_HOST="$E2E_PEARL" VPS_USER=root
  e2e_guard_vm_target
}

# e2e_run_logged <timeout-s> <log> <cmd...>: run with a TERM-then-KILL watchdog.
e2e_run_logged() {
  local t="$1" log="$2" pid rc=0 waited=0
  shift 2
  ( "$@" ) >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$t" ]; then
      e2e_log "TIMEOUT after ${t}s: $* (TERM, then KILL in 120s)"
      pkill -TERM -P "$pid" 2>/dev/null || true; kill -TERM "$pid" 2>/dev/null || true
      local g=0
      while kill -0 "$pid" 2>/dev/null && [ "$g" -lt 120 ]; do sleep 1; g=$((g + 1)); done
      pkill -KILL -P "$pid" 2>/dev/null || true; kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  return "$rc"
}

# The operator lane from the scratch checkout.
e2e_lane() { (cd "$E2E_REPO" && e2e_lane_env && bash scripts/catalog-content-release.sh "$@"); }

# ---- VM-side tools (oracle, loadgen) -------------------------------------------
e2e_push_tools() {
  local d; d="$(mktemp -d)"
  cp "$E2E_HARNESS/lib/oracle.py" "$E2E_HARNESS/lib/loadgen.py" "$d/"
  mkdir -p "$d/scripts"
  for f in $(git -C "$E2E_REPO" show main:scripts/catalog-verifier-bundle.txt | grep -v '^#' | grep -v '^$'); do
    git -C "$E2E_REPO" show "main:$f" >"$d/$f"
  done
  tar -C "$d" -cf - . | vm "install -d -m 0700 /root/e2e/tools && tar -xf - -C /root/e2e/tools"
  rm -rf "$d"
}
e2e_load_start() { # <name> [--sampler]
  local name="$1"; shift
  vm "rm -rf /root/e2e/load/$name; mkdir -p /root/e2e/load/$name; (nohup python3 /root/e2e/tools/loadgen.py --key-file /root/e2e/buyer-api-key --out /root/e2e/load/$name --workers ${E2E_LOAD_WORKERS:-3} $* >/root/e2e/load/$name/loadgen.out 2>&1 </dev/null &)"
}
e2e_load_stop() { # <name>: stop and print the summary
  local name="$1" i
  vm "touch /root/e2e/load/$name/stop"
  for i in $(seq 1 90); do vm "test -f /root/e2e/load/$name/summary.json" && break; sleep 1; done
  vm "cat /root/e2e/load/$name/summary.json 2>/dev/null || echo '{\"error\":\"loadgen did not stop\"}'"
}
# journald on the VM rotates on every qemu clock step ("Time jumped backwards,
# rotating") and the coordinator logs a rate_card_normalized line per scanned
# row, so the system journal keeps well under an hour: capture the coordinator,
# and its recovery units (systemd logs OOM kills per unit) to a file per scenario instead.
e2e_journal_capture() { # <tag>: /root/e2e/journal-<tag>.log until the next capture
  vm "pkill -f '^journalctl -f .*macprovider-coordinator' 2>/dev/null; nohup sh -c 'journalctl -f -n 0 -o short-iso-precise --utc -u macprovider-coordinator -u macprovider-coordinator-deploy-recovery -u macprovider-coordinator-pricing-close | grep --line-buffered -v rate_card_normalized >>/root/e2e/journal-$1.log' >/dev/null 2>&1 </dev/null &" || true
}
e2e_baseline() { vm "python3 /root/e2e/tools/oracle.py baseline /root/e2e/baseline-$1.json" >/dev/null; }
e2e_oracle() { # <baseline-name> <extra args...>: prints verdict JSON, returns its status
  local b="$1"; shift
  vm "python3 /root/e2e/tools/oracle.py check --baseline /root/e2e/baseline-$b.json --tables /root/e2e/tables.json $*"
}
# Content-hash of the host config/state that a NO_GO must leave untouched.
e2e_host_hash() {
  vm 'cd / && find opt/macprovider etc/macprovider etc/systemd/system usr/local/sbin usr/local/share/macprovider run/macprovider -xdev \( -type f -o -type l \) \
        ! -path "opt/macprovider/autotune/.lock*" -print0 2>/dev/null | LC_ALL=C sort -z |
      xargs -0 -r sh -c '"'"'for f; do if [ -L "$f" ]; then echo "L $(readlink "$f") $f"; else echo "F $(sha256sum < "$f" | cut -c1-64) $(stat -c %a:%U:%G "$f") $f"; fi; done'"'"' _ | sha256sum | cut -c1-64'
}

# Reviewed tables for the oracle: label -> rows + card sha, from scratch commits.
e2e_tables_add() { # <label> <commit>
  local label="$1" commit="$2" f
  f="$E2E_WORK/tables.json"; [ -f "$f" ] || echo '{}' >"$f"
  git -C "$E2E_REPO" show "$commit:phase3-binary/dist/static/rate-card.json" | python3 -c '
import hashlib, json, sys
raw = sys.stdin.buffer.read(); f, label = sys.argv[1], sys.argv[2]
t = json.load(open(f)); t[label] = {"rows": json.loads(raw)["rows"], "card_sha256": hashlib.sha256(raw).hexdigest()}
json.dump(t, open(f, "w"), sort_keys=True)' "$f" "$label"
  vm "install -d -m 0700 /root/e2e && cat > /root/e2e/tables.json" <"$f"
}

# Evidence capture: a scenario appends one JSON line per assertion.
e2e_result() { # <scenario> <PASS|FAIL|BUG|GAP> <message>
  printf '{"scenario":"%s","result":"%s","ts":"%s","detail":%s}\n' "$1" "$2" "$(date -u +%FT%TZ)" \
    "$(printf '%s' "$3" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" >>"$E2E_EVIDENCE/results.jsonl"
  e2e_log "[$1] $2: $3"
}

# ---- providers ------------------------------------------------------------------
# Window slots (runbook §Enabling rollout "Window slots"): every pricing
# correction mints a new release id and ages the 3-slot window; a provider that
# never restarts keeps advertising an old release and a later preflight is
# correctly NO_GO window_coverage. The runbook's operator action is to restart
# such providers; the harness does that for its two VM fake providers before
# every preflight (E2E_REFRESH_PROVIDERS=0 disables it). The canary stand-in is
# restarted by the lane itself (kickstart after its catalog install).
# A previous scenario may leave the coordinator still booting (a reboot or a
# controlled restart replays a large WAL for minutes on qemu TCG): wait for it.
e2e_wait_coordinator() {
  vm 'for _ in $(seq 1 180); do curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8444/healthz && exit 0; sleep 10; done; exit 1' ||
    e2e_log "coordinator /healthz still not answering after 30 min"
}
e2e_refresh_providers() {
  [ "${E2E_REFRESH_PROVIDERS:-1}" = 1 ] || return 0
  vm_script <<'SH' || e2e_log "fake provider refresh: not all providers reported ready"
since="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart e2e-fakeprov@1 e2e-fakeprov@2
for _ in $(seq 1 90); do
  n=0
  for i in 1 2; do journalctl -u e2e-fakeprov@$i --since "$since" -o cat --no-pager | grep -q 'state_update ready sent' && n=$((n + 1)); done
  [ "$n" = 2 ] && exit 0
  sleep 2
done
exit 1
SH
  # The canary stand-in adopts the coordinator's live release only on (re)start,
  # like the real CLI; a renewal does not restart it, so restart it too.
  local live i
  live="$(vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'" 2>/dev/null)"
  if [ -n "$live" ] && [ -f "$E2E_CANARY_HOME/Library/LaunchAgents/live.malibu.provider.plist" ] &&
     [ "$(curl -fsS --max-time 5 http://127.0.0.1:19191/v1/status 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["catalog"]["release_id"])' 2>/dev/null)" != "$live" ]; then
    env E2E_CANARY_HOME="$E2E_CANARY_HOME" "$E2E_HARNESS/canary-bin/launchctl" kickstart
    for i in $(seq 1 60); do
      [ "$(curl -fsS --max-time 5 http://127.0.0.1:19191/v1/status 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["catalog"]["release_id"])' 2>/dev/null)" = "$live" ] && break
      sleep 2
    done
  fi
}

# Point scratch origin/main back at the newest commit whose release is the one
# live on the VM (a rolled-back / recovered pricing correction leaves reviewed
# but not-live commits on main; renewals and content releases must be cut from
# the live content, runbook §Which lane). Harness-scripted, scratch origin only.
e2e_main_to_live() {
  local live c
  live="$(vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'")"
  git -C "$E2E_REPO" fetch -q origin
  for c in $(git -C "$E2E_REPO" rev-list --first-parent origin/main); do
    if [ "$(git -C "$E2E_REPO" show "$c:phase3-binary/catalog/autotune/release.json" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["release_id"])' 2>/dev/null)" = "$live" ]; then
      if [ "$c" != "$(git -C "$E2E_REPO" rev-parse origin/main)" ]; then
        git -C "$E2E_REPO" push -q -f origin "$c:refs/heads/main"
        git -C "$E2E_REPO" fetch -q origin
        e2e_log "scratch origin/main reset to $c (live release $live)"
      fi
      git -C "$E2E_REPO" checkout -q main && git -C "$E2E_REPO" reset -q --hard origin/main
      return 0
    fi
  done
  e2e_log "no commit on origin/main carries the live release $live"; return 1
}

# Pearl updater probe (tier E2 only): a copy of the installed updater config with
# production apply enabled and a dummy LOCAL dead-man token, so --apply gets past
# "production apply is disabled" to its guards. Always run it in test mode
# (MACPROVIDER_UPDATER_TESTING=1, --source-dir) inside `unshare -n`: no network.
e2e_updater_probe_conf() {
  vm_script <<'SH'
umask 077
sed -e 's/^PEARL_UPDATER_ENABLED=.*/PEARL_UPDATER_ENABLED=1/' -e '/^PEARL_UPDATER_DEADMAN_API_TOKEN_FILE=/d' /etc/macprovider/pearl-updater.conf >/root/e2e/updater-probe.conf
grep -q '^PEARL_UPDATER_ENABLED=' /root/e2e/updater-probe.conf || echo 'PEARL_UPDATER_ENABLED=1' >>/root/e2e/updater-probe.conf
echo 'PEARL_UPDATER_DEADMAN_API_TOKEN_FILE=/root/e2e/deadman-dummy-token' >>/root/e2e/updater-probe.conf
printf 'e2edummytoken\n' >/root/e2e/deadman-dummy-token
SH
}
e2e_updater_src() { # <tag>: the tag's release stand-in at /root/e2e/updater-src
  COPYFILE_DISABLE=1 tar -C "$E2E_WORK/gh-releases/$1" -cf - . | vm "rm -rf /root/e2e/updater-src && mkdir -p /root/e2e/updater-src && tar -xf - -C /root/e2e/updater-src"
}

# ---- lane runs with saved evidence ---------------------------------------------
# e2e_preflight <name> <commit> [extra args]: saves the verdict JSON; returns rc.
e2e_preflight() {
  local name="$1" commit="$2" rc=0; shift 2
  e2e_wait_coordinator
  e2e_refresh_providers
  e2e_run_logged "${E2E_LANE_TIMEOUT:-1500}" "$E2E_LOGS/$name-preflight.log" e2e_lane --preflight --commit "$commit" "$@" || rc=$?
  grep -E '^\{"checks"' "$E2E_LOGS/$name-preflight.log" | tail -n 1 >"$E2E_EVIDENCE/$name-verdict.json" || true
  return "$rc"
}
e2e_verdict_failed() { # <verdict file>: names of failed checks
  python3 -c 'import json,sys
try: v=json.load(open(sys.argv[1]))
except Exception: print("NO-VERDICT"); raise SystemExit
print(" ".join(c["name"] for c in v.get("checks",[]) if not c["ok"]))' "$1"
}
e2e_verdict_detail() { # <verdict file> <check>
  python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
print(next((c["detail"] for c in v.get("checks",[]) if c["name"]==sys.argv[2]), ""))' "$1" "$2"
}
e2e_verdict_ack() { python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("pricing") or {}).get("pricing_diff_sha256",""))' "$1"; }
# e2e_deploy <name> <commit> [extra args]: returns the lane rc.
e2e_deploy() {
  local name="$1" commit="$2" rc=0; shift 2
  e2e_run_logged "${E2E_LANE_TIMEOUT:-2400}" "$E2E_LOGS/$name-deploy.log" e2e_lane --deploy --commit "$commit" "$@" || rc=$?
  return "$rc"
}
e2e_recover() { # <name>
  local rc=0
  e2e_run_logged "${E2E_LANE_TIMEOUT:-1200}" "$E2E_LOGS/$1-recover.log" e2e_lane --recover-pricing-txn || rc=$?
  return "$rc"
}
e2e_txn_phase() { vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/.pricing-txn/txn.json\"))[\"phase\"])' 2>/dev/null || echo none"; }
