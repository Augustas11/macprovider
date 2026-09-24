# shellcheck shell=bash
# Shared helpers for the tier E2 steps and scenarios. Source after env.sh.

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
  # deploy-pearl-vps.sh
  export SSH_KEY="$E2E_KEYS/pearl_root_ed25519" VPS_HOST="$E2E_PEARL" VPS_USER=root
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

# ---- lane runs with saved evidence ---------------------------------------------
# e2e_preflight <name> <commit> [extra args]: saves the verdict JSON; returns rc.
e2e_preflight() {
  local name="$1" commit="$2" rc=0; shift 2
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
