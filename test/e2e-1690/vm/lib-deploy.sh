# shellcheck shell=bash
# In-VM operator actions: install the coordinator the way the Pearl deploy
# does, deploy the gateway with the REAL phase5-gateway/dist/deploy-pearl-vps.sh,
# flip gateway config keys, nginx 503 cut-over. Source after lib.sh.

# autotune_install <worktree>: the committed signed release (production keys,
# public signatures) as /opt/macprovider/autotune/releases/<id> + current.
autotune_install() {
  local wt="$1" id dir
  id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["release_id"])' "$wt/phase3-binary/catalog/autotune/release.json")"
  dir=/opt/macprovider/autotune/releases/$id
  install -d -o root -g macprovider -m 0750 /opt/macprovider/autotune /opt/macprovider/autotune/releases "$dir"
  for f in rate-card.json rate-card.json.sig demand-rank.json demand-rank.json.sig autotune-candidates.json autotune-candidates.json.sig; do
    install -o root -g macprovider -m 0640 "$wt/phase3-binary/dist/static/$f" "$dir/$f"
  done
  for f in tier2-catalog.json release.json trusted-keys.json; do
    install -o root -g macprovider -m 0640 "$wt/phase3-binary/catalog/autotune/$f" "$dir/$f"
  done
  ln -sfn "releases/$id" /opt/macprovider/autotune/current.next && mv -T /opt/macprovider/autotune/current.next /opt/macprovider/autotune/current
}

coord_healthz() { curl -fsS --max-time 5 http://127.0.0.1:8443/healthz; }

# coord_install <old|new>: binary swap as deploy-pearl-vps.sh / the updater do
# (the .prev snapshot, root:macprovider 0750, the tree's systemd unit), then a
# graceful restart and a /healthz wait. HARNESS LIMITATION: the full
# phase4-coordinator/dist/deploy-pearl-vps.sh (signed release tags, GitHub
# release assets, catalog canary Mac) is not run here; #1690 does not change it
# and the #1693 harness exercises it.
coord_install() {
  local side="$1" b=/root/e2e/bins/$1
  [ -x "$b/coordinator-linux-amd64" ] || die "no $side coordinator build"
  systemctl stop macprovider-coordinator 2>/dev/null || true
  [ -x /opt/macprovider/coordinator ] && install -o root -g macprovider -m 0750 /opt/macprovider/coordinator /opt/macprovider/coordinator.prev
  install -o root -g macprovider -m 0750 "$b/coordinator-linux-amd64" /opt/macprovider/coordinator
  install -o root -g root -m 0755 "$b/coordinator-cli-linux-amd64" /opt/macprovider/coordinator-cli
  install -o root -g root -m 0644 /root/e2e/wt-$side/phase4-coordinator/dist/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  systemctl daemon-reload
  systemctl enable macprovider-coordinator >/dev/null 2>&1
  systemctl start macprovider-coordinator
  local i
  for i in $(seq 1 90); do coord_healthz >/dev/null 2>&1 && break; sleep 1; done
  coord_healthz >/dev/null 2>&1 || { journalctl -u macprovider-coordinator --no-pager -n 40 >&2; die "coordinator ($side) did not become healthy"; }
  echo "$side" >/root/e2e/coordinator.side
  log "coordinator=$side healthz: $(coord_healthz | head -c 300)"
}

# gw_deploy <old|new> [label]: the real gateway deploy script from that tree,
# SSHing to root@127.0.0.1. Prints and records the "db snapshot saved at" path.
gw_deploy() {
  local side="$1" label="${2:-$1}" wt=/root/e2e/wt-$1 rc=0 logf
  logf=$E2E_LOGS/gw-deploy-$label-$(date -u +%H%M%S).log
  cp /root/e2e/bins/$side/gateway-linux-amd64 "$wt/phase5-gateway/dist/gateway-linux-amd64"
  ( cd "$wt" && PATH="$E2E_H/shims:$PATH" SSH_KEY=/root/.ssh/e2e_operator VPS_HOST=127.0.0.1 VPS_USER=root \
      bash phase5-gateway/dist/deploy-pearl-vps.sh ) >"$logf" 2>&1 || rc=$?
  rm -f "$wt/phase5-gateway/dist/gateway-linux-amd64"
  grep -o 'db snapshot saved at [^ ]*' "$logf" | sed 's/db snapshot saved at //' | tail -1 >/root/e2e/gw-snapshot-$label.path || true
  echo "$side" >/root/e2e/gateway.side
  log "gateway deploy $side rc=$rc log=$logf snapshot=$(cat /root/e2e/gw-snapshot-$label.path)"
  [ "$rc" = 0 ] || tail -25 "$logf" >&2
  # The live gateway /healthz carries no in_flight_requests metric, so the
  # script's step 2c refuses (exit 4) on every non-first deploy. An operator
  # confirms a quiet window by other means and reruns with FORCE_RESTART=1,
  # exactly as the script instructs; the refusal is recorded as a finding.
  if [ "$rc" = 4 ] && [ "${FORCE_RESTART:-0}" != 1 ] && grep -q 'did not report a numeric in-flight metric' "$logf"; then
    result "gw-deploy-$label-step2c" INFO "deploy-pearl-vps.sh step 2c refused (exit 4): gateway /healthz has no in_flight_requests metric; rerunning with FORCE_RESTART=1 after checking no active reservation ($(gwsql "SELECT COUNT(*) FROM quota_reservations WHERE status='active'") active)"
    FORCE_RESTART=1 gw_deploy "$side" "$label"
    return $?
  fi
  return "$rc"
}

gw_healthz() { curl -fsS --max-time 5 http://127.0.0.1:9443/healthz; }
gw_restart() {
  systemctl restart macprovider-gateway
  local i; for i in $(seq 1 60); do gw_healthz >/dev/null 2>&1 && return 0; sleep 1; done
  journalctl -u macprovider-gateway --no-pager -n 30 >&2; die "gateway did not come back"
}
# gw_set <dotted.key> <yaml scalar>: edit /opt/macprovider/gateway.yaml in place.
gw_set() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
path = "/opt/macprovider/gateway.yaml"
key, val = sys.argv[1], yaml.safe_load(sys.argv[2])
doc = yaml.safe_load(open(path))
cur = doc
parts = key.split(".")
for p in parts[:-1]:
    cur = cur.setdefault(p, {})
cur[parts[-1]] = val
open(path, "w").write(yaml.safe_dump(doc, sort_keys=False))
PY
  chown macprovider:macprovider /opt/macprovider/gateway.yaml; chmod 0640 /opt/macprovider/gateway.yaml
}

# wait_providers <n>: until the coordinator reports n ready providers.
wait_providers() {
  local want="$1" i n=0
  for i in $(seq 1 90); do
    n="$(coord_healthz 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("pool_ready",0))' 2>/dev/null || echo 0)"
    [ "${n:-0}" -ge "$want" ] && return 0
    sleep 2
  done
  log "only ${n:-0}/$want providers ready"; return 1
}

# nginx buyer cut-over (rollback step 1 as written in the runbook).
nginx_block_buyers() {
  python3 - <<'PY'
import re
p = "/etc/nginx/sites-available/api.malibu.tech"
s = open(p).read()
open(p + ".e2e-pre503", "w").write(s)
out, i = [], 0
lines = s.split("\n")
while i < len(lines):
    line = lines[i]
    m = re.match(r"^(\s*)location\s+(.*?)\s*\{\s*$", line)
    if m:
        j, depth, body = i + 1, 1, []
        while depth:
            depth += lines[j].count("{") - lines[j].count("}")
            if depth:
                body.append(lines[j])
            j += 1
        target = m.group(2).strip()
        proxies_gw = any("proxy_pass http://127.0.0.1:9443" in b for b in body)
        if proxies_gw and target != "= /healthz":
            out += [line, m.group(1) + "    return 503;", m.group(1) + "}"]
        else:
            out += lines[i:j]
        i = j
        continue
    out.append(line)
    i += 1
open(p, "w").write("\n".join(out))
PY
  nginx -t 2>&1 | tail -1 && systemctl reload nginx
}
nginx_unblock_buyers() {
  mv /etc/nginx/sites-available/api.malibu.tech.e2e-pre503 /etc/nginx/sites-available/api.malibu.tech && nginx -t 2>&1 | tail -1 && systemctl reload nginx
}
