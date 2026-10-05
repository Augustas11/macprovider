# shellcheck shell=bash
# #1816 in-VM helpers. Source after the shared #1690 lib.sh, lib-deploy.sh and
# lib-scn.sh (/root/e2e/h/vm). Run as root inside the fake-Pearl VM.
E2E_H16=/root/e2e/h16
K=/root/e2e/keys
RELDIR=/root/e2e/releases            # flat --source-dir release sets
UPD=/usr/local/sbin/macprovider-pearl-update
UPD_CONF=/etc/macprovider/pearl-updater.conf
UPD_STATE=/var/lib/macprovider-pearl-updater
NEW_TAG=v1.8.211
OLD_TAG=v1.8.210
CANARY_USER=e2ecanary
CANARY_ID=e2e-prov-canary
CREATOR=acct-e2e-1816-creator
MEMBER_ACCT=acct-e2e-1816-member     # SPEC-042-R016 non-creator owner of e2e-prov-5
POOL_WINDOW_S="${E2E_POOL_WINDOW_S:-120}"
# Non-catalog identities (never in the signed catalog or its artifact feed).
H_GGUF=$(printf 'e2e-1816 non-catalog gguf G' | sha256sum | cut -c1-64)
H_GGUF2=$(printf 'e2e-1816 non-catalog gguf G2' | sha256sum | cut -c1-64)
H_MLX=$(printf 'e2e-1816 non-catalog mlx snapshot N' | sha256sum | cut -c1-64)
H_MLX2=$(printf 'e2e-1816 non-catalog mlx snapshot N2' | sha256sum | cut -c1-64)
# Catalog identities of the activation release (recommendable rows):
# meta-llama/llama-3.2-3b-instruct GGUF q4_k_m (artifact feed) and its MLX snapshot.
H_CAT_GGUF=6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff
H_CAT_MLX=e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90
# Entry prices (credits per Mtok) inside the runbook section 1 bounds, high
# enough that a price change moves the rounded credits of an 8+20 token request.
G_RATES="400000,100000,2000000"
N_RATES="300000,75000,1500000"
BOUNDS_JSON='{"min_prompt_rate_per_mtok":13500,"max_prompt_rate_per_mtok":425000,"min_prompt_cache_hit_rate_per_mtok":3375,"max_prompt_cache_hit_rate_per_mtok":106250,"min_completion_rate_per_mtok":27000,"max_completion_rate_per_mtok":2160000}'

sides() { echo "$(cat /root/e2e/coordinator.side)/$(cat /root/e2e/gateway.side)"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# coord_yaml_edit <python-snippet>: edit /opt/macprovider/coordinator.yaml as
# a dict `c` (PyYAML round trip; the live file is operator-owned on Pearl).
coord_yaml_edit() {
  python3 - "$1" <<'PY'
import sys, yaml, json
p = "/opt/macprovider/coordinator.yaml"
c = yaml.safe_load(open(p))
exec(sys.argv[1])
open(p, "w").write(yaml.safe_dump(c, sort_keys=False))
PY
}
coord_restart() {
  systemctl restart macprovider-coordinator
  local i; for i in $(seq 1 90); do coord_healthz >/dev/null 2>&1 && return 0; sleep 1; done
  journalctl -u macprovider-coordinator --no-pager -n 30 >&2; return 1
}

# ---- Pearl updater -----------------------------------------------------------
# run_updater <mode> <tag> <srcdir> <logfile>: the REAL installed updater in
# test mode (--source-dir; PEARL_UPDATER_TEST_PUBLIC_KEY is the VM release key)
# as root with the macprovider egid (production runs the service as root with
# the trusted group; test mode uses egid as the trusted gid). PATH puts the
# catalog-canary ssh first (the system ssh; no shim).
run_updater() {
  local mode="$1" tag="$2" src="$3" logf="$4" rc=0
  install -d -m 0755 /root/e2e/shim-bin && install -m 0755 $E2E_H16/lib/python3-shim /root/e2e/shim-bin/python3
  /usr/bin/python3 $E2E_H16/tools/verify-cache.py record /usr/local/share/macprovider/scripts/catalog-release.py verify-directory \
    --directory "$src" --tier2-coordinator-config /opt/macprovider/coordinator.yaml >>"$logf.verify" 2>&1
  PATH=/root/e2e/shim-bin:$PATH MACPROVIDER_UPDATER_TESTING=1 PEARL_UPDATER_TEST_PUBLIC_KEY=$K/release-signing-public.pem SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    setpriv --regid=macprovider --clear-groups -- "$UPD" "--$mode" --tag "$tag" --source-dir "$src" >"$logf" 2>&1 || rc=$?
  echo "rc=$rc" >>"$logf"
  return $rc
}
audit_tail() { tail -n "${1:-20}" "$UPD_STATE/audit.jsonl" 2>/dev/null; }

# ---- canary provider (a fake CLI run as a real user over real ssh) ----------
canary_ctl() { su - "$CANARY_USER" -c "launchctl $*"; }
canary_status() { curl -fsS --max-time 5 http://127.0.0.1:19196/v1/status; }

# ---- nginx ------------------------------------------------------------------
NGX_COORD=/etc/nginx/sites-available/coordinator.malibu.tech
# nginx_add_catalog_artifacts: runbook docs/runbooks/catalog-artifact-feed-release.md
# "manual additive nginx step": copy exactly the two catalog-artifacts blocks
# from the release's phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf
# into the live vhost before `location /v1/ { return 404; }`, nginx -t, reload.
nginx_add_catalog_artifacts() {
  python3 - "$1" "$NGX_COORD" <<'PY'
import re, sys
src, live = open(sys.argv[1]).read(), open(sys.argv[2]).read()
blocks = re.findall(r"(?ms)^    location = /v1/catalog-artifacts(?:\.sig)? \{.*?^    \}\n", src)
assert len(blocks) == 2, "expected two catalog-artifacts blocks in the release conf"
if "location = /v1/catalog-artifacts" in live:
    sys.exit("live vhost already has catalog-artifacts")
m = re.search(r"(?m)^    location /v1/ \{", live)
assert m, "no catch-all location /v1/ in the live vhost"
open(sys.argv[2], "w").write(live[:m.start()] + "".join(blocks) + "\n" + live[m.start():])
PY
  nginx -t 2>&1 | tail -1 && systemctl reload nginx
}

# ---- trusted pools ----------------------------------------------------------
PM="python3 $E2E_H16/tools/pool-models.py"
pool_id() { cat "/root/e2e/pools16/$1/pool_id" 2>/dev/null; }
pmid() { echo "pool/$(pool_id "$1")/$2"; }
# pool_traffic <run> <pool-name> <model> [engine] [mix] [workers]
pool_traffic() {
  local run="$1" pool="$2" model="$3" engine="${4:-}" mix="${5:-ns=3,st=3,st_dc=1,ns_dc=1}" workers="${6:-2}"
  local hdr=(--header "X-MacProvider-Pool-Select:$(pool_id "$pool")")
  [ -n "$engine" ] && hdr+=(--header "X-MacProvider-Engine-Select:$engine")
  MODEL="$model" traffic "$run" "$mix" "${hdr[@]}" --workers "$workers"
}
# wait_pool_model_routeable <label> <pool|pool-id> <pool-model-id> <runtime-source|null> <provider-id> [min-admission-event-id] [max-seconds]
wait_pool_model_routeable() {
  local label="$1" pool="$2" model="$3" runtime="$4" provider="$5" min_event="${6:-0}" max="${7:-90}"
  local pid="$pool" t=0 evdir="${EV:-$E2E_EVIDENCE/p$PASS_ID-routeable}" poolz models events check bk
  [ -f "/root/e2e/pools16/$pool/pool_id" ] && pid="$(pool_id "$pool")"
  mkdir -p "$evdir" 2>/dev/null || true
  poolz="$evdir/$label.poolz.json"; models="$evdir/$label.models.json"; events="$evdir/$label.admission-events.txt"; check="$evdir/$label.routeable.check"
  bk="$(cat /root/e2e/buyer-api-key 2>/dev/null || true)"
  while [ "$t" -le "$max" ]; do
    curl_bearer "$(opkey)" -s http://127.0.0.1:8444/poolz >"$poolz" 2>"$poolz.err" || true
    [ -n "$bk" ] && curl_bearer "$bk" -s https://api.malibu.tech/v1/models -H "X-MacProvider-Pool-Select: $pid" >"$models" 2>"$models.err" || true
    csql "SELECT id, provider_id, state, reason_code, binding_scope, pool_id, pool_model_id, pool_manifest_version FROM model_admission_events WHERE provider_id='$provider' AND id > ${min_event:-0} ORDER BY id DESC LIMIT 5" >"$events" 2>"$events.err" || true
    if python3 - "$poolz" "$models" "$events" "$provider" "$pid" "$model" "$runtime" <<'PY' >"$check" 2>&1
import json, sys
poolz_path, models_path, events_path, provider, pool_id, model_id, runtime = sys.argv[1:8]
missing = []
try:
    d = json.load(open(poolz_path))
    rows = d.get("providers") or d.get("pool") or []
    if isinstance(rows, dict):
        rows = rows.get("providers") or []
except Exception as exc:
    rows = []
    missing.append("poolz unreadable: %s" % exc)
hit = None
for row in rows:
    if (row.get("provider_id") or row.get("id")) == provider:
        hit = row
        break
if not hit:
    missing.append("provider %s absent from /poolz" % provider)
else:
    if hit.get("state") != "ready":
        missing.append("provider state=%r" % hit.get("state"))
    # routing_eligible describes the provider's global catalog path. Pool-only
    # entries legitimately report false here even while their scoped route is
    # healthy, so pool routeability is proven by admission + the pool model view.
    if hit.get("catalog_admission_mode") != "pool_entry":
        missing.append("catalog_admission_mode=%r" % hit.get("catalog_admission_mode"))
    if runtime and runtime != "null" and hit.get("runtime_source") != runtime:
        missing.append("runtime_source=%r" % hit.get("runtime_source"))
try:
    md = json.load(open(models_path))
    model_rows = md.get("data") or []
except Exception as exc:
    model_rows = []
    missing.append("models view unreadable: %s" % exc)
mh = next((m for m in model_rows if m.get("id") == model_id), None)
if not mh:
    missing.append("pool models view missing %s" % model_id)
else:
    for key in ("provider_count", "total_slots"):
        val = mh.get(key)
        if isinstance(val, (int, float)) and val <= 0:
            missing.append("%s=%s for %s" % (key, val, model_id))
fresh = False
fresh_id = ""
lines = []
try:
    lines = [line.strip().split("|") for line in open(events_path) if line.strip()]
except Exception as exc:
    missing.append("admission events unreadable: %s" % exc)
for cols in lines:
    if len(cols) >= 7 and cols[1] == provider and cols[2] == "catalog_priced" and cols[4] == "pool" and cols[5] == pool_id and cols[6] == model_id:
        fresh = True
        fresh_id = cols[0]
        break
if not fresh:
    missing.append("no fresh pool binding event for %s/%s" % (provider, model_id))
if missing:
    print("; ".join(missing))
    sys.exit(1)
print("%s ready, %s exposed, fresh binding event id=%s" % (provider, model_id, fresh_id))
PY
    then
      result "$label" PASS "$(head -1 "$check") after ${t}s"
      return 0
    fi
    sleep 2; t=$((t + 2))
  done
  result "$label" FAIL "not routeable within ${max}s: $(head -1 "$check" 2>/dev/null | head -c 700); events=$(tr '\n' ';' <"$events" 2>/dev/null | head -c 300)"
  return 1
}
# wait_run_route_snapshots <run> <want> [max-seconds]: wait until loadgen has
# started the intended requests and the coordinator has written their route
# snapshots. This makes "in flight" scenarios mutate pool state only after the
# target requests have actually routed, not after an arbitrary sleep.
wait_run_route_snapshots() {
  local run="$1" want="$2" max="${3:-45}" t=0 started=0 routed=0 ids
  local started_file="$E2E_EVIDENCE/$run.load.jsonl.started"
  while [ "$t" -le "$max" ]; do
    if [ -s "$started_file" ]; then
      ids="$(python3 - "$started_file" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1]):
    try:
        r = json.loads(line)
    except Exception:
        continue
    rid = r.get("rid")
    if rid:
        rows.append("'" + rid.replace("'", "''") + "'")
print(",".join(rows))
PY
)"
      started="$(python3 - "$started_file" <<'PY'
import sys
print(sum(1 for line in open(sys.argv[1]) if line.strip()))
PY
)"
      if [ -n "$ids" ]; then
        routed="$(csql "SELECT COUNT(*) FROM settlement_route_snapshots WHERE request_id IN ($ids)" 2>/dev/null || echo 0)"
      fi
    fi
    [ "${started:-0}" -ge "$want" ] && [ "${routed:-0}" -ge "$want" ] && { log "run $run routed $routed/$want after ${t}s"; return 0; }
    sleep 1; t=$((t + 1))
  done
  log "run $run did not route $want requests within ${max}s (started=${started:-0}, routed=${routed:-0})"
  return 1
}
# pool_check <label> <run> <pool-oracle args...>: drain + base oracle + pool oracle.
pool_check() {
  local label="$1" run="$2"; shift 2
  local d=0 c=0
  drain "$run" "${DRAIN_MAX:-480}" || d=1
  python3 $E2E_H16/tools/pool-oracle.py --base-oracle $E2E_H/tools/oracle.py --allow "${ORACLE_ALLOW:-I5}" --prefix "$run" \
    --load "$E2E_EVIDENCE/$run.load.jsonl" --out "$E2E_EVIDENCE/$run.pool-oracle.json" "$@" >"$E2E_EVIDENCE/$run.pool-oracle.txt" 2>&1 || c=1
  if [ $d = 0 ] && [ $c = 0 ]; then result "$label" PASS "run $run: $(head -1 "$E2E_EVIDENCE/$run.pool-oracle.txt")"
  else result "$label" FAIL "run $run drain=$d oracle=$c: $(head -8 "$E2E_EVIDENCE/$run.pool-oracle.txt" | tr '\n' ' ' | head -c 900)"; fi
  return $((d + c))
}
# wait_window <pool> <manifest-version>: until that manifest's window is active (+5 s for the sweep).
wait_window() {
  local nb; nb="$($PM window "$1" "$2" | cut -d' ' -f1)"
  [ -n "$nb" ] || return 1
  local now; now=$(date +%s)
  [ "$nb" -gt "$now" ] && sleep $((nb - now + 5))
  return 0
}
# wait_fresh_window <pool> [minimum-runway-seconds]: keep ordinary traffic out
# of an already-scheduled activation boundary. Boundary behavior has its own
# continuous-traffic coverage in S5; S3 proves steady-state paid settlement.
wait_fresh_window() {
  local pool="$1" minimum="${2:-30}" version window nb na now
  while :; do
    version="$($PM latest "$pool")"
    window="$($PM window "$pool" "$version")" || { sleep 2; continue; }
    read -r nb na <<<"$window"
    now="$(date +%s)"
    if [ "$now" -lt "$nb" ]; then
      sleep $((nb - now + 5))
      return 0
    fi
    [ $((na - now)) -ge "$minimum" ] && return 0
    sleep 2
  done
}
snapshots_for() { csql "SELECT COUNT(*) FROM settlement_route_snapshots WHERE json_extract(route_snapshot_json,'\$.pool_model_id') = '$1'"; }
global_pool_snapshots() { csql "SELECT COUNT(*) FROM settlement_route_snapshots WHERE json_extract(route_snapshot_json,'\$.pool_model_id') IS NOT NULL AND coalesce(json_extract(route_snapshot_json,'\$.pool_id'),'')=''"; }
compare_catalog_shape() { # compare_catalog_shape <label> <run> <message>
  local label="$1" run="$2" msg="$3" out="$E2E_EVIDENCE/$run.shape.txt"
  if python3 $E2E_H/tools/compare-shape.py "$E2E_EVIDENCE/baseline-p$PASS_ID.oracle.json" "$E2E_EVIDENCE/$run.oracle.json" >"$out" 2>&1; then
    result "$label" PASS "$msg: outcome shape identical to the S1 baseline"
  elif ! grep -q '<-- DIFF' "$out"; then
    result "$label" FAIL "$msg: compare-shape failed without a parseable diff ($(head -c 400 "$out"))"
  elif grep '<-- DIFF' "$out" | grep -Ev '^(ns_dc|st_dc)[[:space:]]' >/dev/null; then
    result "$label" FAIL "$msg: stable request outcome shape differs ($(grep '<-- DIFF' "$out" | tr '\n' ';' | head -c 600))"
  else
    result "$label" INFO "$msg: only disconnect-shape outcomes differ under the mixed pair ($(grep '<-- DIFF' "$out" | tr '\n' ';' | head -c 600))"
  fi
}
# keeper_on / keeper_off: the window keeper re-signs each pool's current staged
# entries into the next window before the active one ends (windows are short so
# an entry change activates within one window; see the plan).
keeper_on() {
  systemctl reset-failed e2e-1816-keeper 2>/dev/null || true
  systemd-run --unit=e2e-1816-keeper --collect -E HOME=/root bash -c "exec python3 $E2E_H16/tools/pool-models.py keeper --lead 50 >>/root/e2e/logs/keeper.log 2>&1" >/dev/null
}
keeper_off() { systemctl stop e2e-1816-keeper 2>/dev/null || true; }
fakeprov_args() { printf 'FAKEPROV_ARGS=%s\n' "$2" >/root/e2e/fakeprov-$1.env; }
