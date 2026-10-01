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
snapshots_for() { csql "SELECT COUNT(*) FROM settlement_route_snapshots WHERE json_extract(route_snapshot_json,'\$.pool_model_id') = '$1'"; }
global_pool_snapshots() { csql "SELECT COUNT(*) FROM settlement_route_snapshots WHERE json_extract(route_snapshot_json,'\$.pool_model_id') IS NOT NULL AND coalesce(json_extract(route_snapshot_json,'\$.pool_id'),'')=''"; }
# keeper_on / keeper_off: the window keeper re-signs each pool's current staged
# entries into the next window before the active one ends (windows are short so
# an entry change activates within one window; see the plan).
keeper_on() {
  systemctl reset-failed e2e-1816-keeper 2>/dev/null || true
  systemd-run --unit=e2e-1816-keeper --collect -E HOME=/root bash -c "exec python3 $E2E_H16/tools/pool-models.py keeper --lead 50 >>/root/e2e/logs/keeper.log 2>&1" >/dev/null
}
keeper_off() { systemctl stop e2e-1816-keeper 2>/dev/null || true; }
fakeprov_args() { printf 'FAKEPROV_ARGS=%s\n' "$2" >/root/e2e/fakeprov-$1.env; }
