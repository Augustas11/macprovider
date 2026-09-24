#!/usr/bin/env bash
# #1690 M6 lab rig: a branch-built coordinator + gateway + provider CLI serving
# a llama.cpp llama-server GGUF member of a SPEC-042 Trusted Pool, fully
# isolated on 127.0.0.1:19101-19131 with lab keys under $LAB.
#
#   rig.sh model    download the pinned GGUF and check its sha256
#   rig.sh build    build coordinator, coordinator-cli, gateway, labtool, lab CLI
#   rig.sh build-spoof  build a lab-only CLI whose auth runtime_source can be
#                   overridden by LAB_SPOOF_RUNTIME_SOURCE (a hostile client)
#   rig.sh up       start everything, offer + price the candidate, create pool A
#   rig.sh down     stop every lab process (by recorded PID only)
#   rig.sh status   show lab processes and the coordinator's view of the member
#
# It never signals a process by name, never uses port 8080/8443/8444, never
# reads ~/.config/macprovider, and never contacts a production host. The lab
# CLI runs through cli.sh, which redirects every home-derived path into $LAB.
set -euo pipefail
LAB="${LAB:-/Users/a1/lab-1690-m6}"
WT="${WT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
HERE="$WT/scripts/lab/1690-m6"
LLAMA_DIR="${LLAMA_DIR:-/Users/a1/bench-1690/llama.cpp-b11149/llama-b11149}"
METALLIB="${METALLIB:-/Users/a1/bench-1690/run/mlx.metallib}"
GO_BIN="${GO_BIN:-/Users/a1/sdk/go1.26.6/bin}"
GGUF_REPO=Qwen/Qwen2.5-0.5B-Instruct-GGUF
GGUF_REV=9217f5db79a29953eb74d5343926648285ec7e67
GGUF_FILE=qwen2.5-0.5b-instruct-q4_k_m.gguf
GGUF_SHA=74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
MLX_ID=mlx-community/Qwen2.5-0.5B-Instruct-4bit
MLX_REV=a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3
ROW_KEY=qwen2.5-0.5b-instruct
export PATH="$GO_BIN:$PATH" GOTOOLCHAIN=local LAB

mkdir -p "$LAB"/{bin,logs,models,keys,db,run,static,pools,home,tmp,provider}
chmod 700 "$LAB/keys" "$LAB/home"

secret() { python3 -c "import json,sys;print(json.load(open('$LAB/keys/secrets.json'))[sys.argv[1]])" "$1"; }
start_bg() { # name pidfile log cmd...
  local pidf="$LAB/run/$1.pid" log="$LAB/logs/$1.log"; shift
  nohup "$@" >>"$log" 2>&1 &
  echo $! >"$pidf"
}
stop_pid() {
  local pidf="$LAB/run/$1.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    kill -TERM "$(cat "$pidf")"
    for _ in $(seq 1 20); do kill -0 "$(cat "$pidf")" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$(cat "$pidf")" 2>/dev/null && kill -KILL "$(cat "$pidf")" || true
  fi
  rm -f "$pidf"
}
wait_http() { for _ in $(seq 1 60); do curl -fs "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "timeout waiting for $1" >&2; return 1; }

cmd_model() {
  local f="$LAB/models/$GGUF_FILE"
  [[ -f "$f" ]] || curl -fsSL -o "$f" "https://huggingface.co/$GGUF_REPO/resolve/$GGUF_REV/$GGUF_FILE"
  [[ "$(shasum -a 256 "$f" | cut -c1-64)" == "$GGUF_SHA" ]] || { echo "GGUF sha256 mismatch" >&2; exit 1; }
  echo "model ok: $f"
}

cmd_build() {
  (cd "$WT/phase4-coordinator" && go build -o "$LAB/bin/coordinator" ./cmd/coordinator && go build -o "$LAB/bin/coordinator-cli" ./cmd/coordinator-cli)
  (cd "$WT/phase5-gateway" && go build -o "$LAB/bin/gateway" ./cmd/gateway)
  printf '{"Replace":{"%s/cmd/lab1690m6/main.go":"%s"}}' "$WT/phase4-coordinator" "$HERE/labtool/main.go" >"$LAB/run/overlay.json"
  (cd "$WT/phase4-coordinator" && go build -overlay "$LAB/run/overlay.json" -o "$LAB/bin/labtool" ./cmd/lab1690m6)
  cmd_static
  # The lab CLI is the branch CLI with the lab static release compiled in.
  # The generated file is swapped only for this build and restored after.
  local gen="$WT/phase3-binary/Sources/macprovider-cli/AutotuneCatalog.generated.swift"
  cp "$LAB/static/AutotuneCatalog.generated.swift" "$gen"
  trap 'git -C "$WT" checkout -- phase3-binary/Sources/macprovider-cli/AutotuneCatalog.generated.swift' EXIT
  (cd "$WT/phase3-binary" && swift build -c release --product macprovider-cli)
  cp "$WT/phase3-binary/.build/release/macprovider-cli" "$LAB/bin/macprovider-cli-lab"
  cp "$METALLIB" "$LAB/bin/mlx.metallib"
  echo "build ok"
}

cmd_build_spoof() {
  # A spoofing client for the SPEC-042-R013 spoofed-hello case. The patch is
  # applied to the worktree only for this build and reverted after; the
  # binary lives only in $LAB/bin.
  local cc="$WT/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
  local gen="$WT/phase3-binary/Sources/macprovider-cli/AutotuneCatalog.generated.swift"
  trap 'git -C "$WT" checkout -- phase3-binary/Sources/macprovider-cli/AutotuneCatalog.generated.swift phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift' EXIT
  cp "$LAB/static/AutotuneCatalog.generated.swift" "$gen"
  python3 - "$cc" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """        if let runtimeSource {
            message["runtime_source"] = runtimeSource
        }
        if let endpointURL {"""
new = """        if let spoof = ProcessInfo.processInfo.environment["LAB_SPOOF_RUNTIME_SOURCE"] {
            if spoof != "none" { message["runtime_source"] = spoof }
        } else if let runtimeSource {
            message["runtime_source"] = runtimeSource
        }
        if let endpointURL {"""
assert s.count(old) == 1, "auth runtime_source block not found"
open(p, "w").write(s.replace(old, new))
PY
  (cd "$WT/phase3-binary" && swift build -c release --product macprovider-cli)
  cp "$WT/phase3-binary/.build/release/macprovider-cli" "$LAB/bin/macprovider-cli-lab-spoof"
  echo "spoof build ok"
}

cmd_static() {
  [[ -f "$LAB/static/tier2-catalog.json" && -f "$LAB/static/AutotuneCatalog.generated.swift" ]] && return 0
  local mlx_sha; mlx_sha=$(printf 'lab-1690-m6 placeholder mlx primary' | shasum -a 256 | cut -c1-64)
  "$LAB/bin/labtool" static-release --out-dir "$LAB/static" --key-file "$LAB/keys/static-feed.ed25519" \
    --release lab-1690-m6-r1 --generated-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --row-key "$ROW_KEY" \
    --mlx-model-id "$MLX_ID" --mlx-revision "$MLX_REV" --mlx-sha256 "$mlx_sha" \
    --gguf-sha256 "$GGUF_SHA" --gguf-size "$(stat -f %z "$LAB/models/$GGUF_FILE")" --gguf-repo "$GGUF_REPO" \
    --gguf-revision "$GGUF_REV" --gguf-file "$GGUF_FILE" --swift-out "$LAB/static/AutotuneCatalog.generated.swift"
  local sc="$WT/scripts/sign-catalog.go"
  [[ -f "$LAB/keys/tier2.priv" ]] || go run "$sc" keygen -public-out "$LAB/keys/tier2.pub" -private-out "$LAB/keys/tier2.priv"
  chmod 600 "$LAB/keys/tier2.priv"
  cat >"$LAB/static/tier2-unsigned.json" <<EOF
{"version":1,"catalog_id":"lab-1690-m6-tier2","issued_at":"$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)","expires_at":"$(date -u -v+7d +%Y-%m-%dT%H:%M:%SZ)","models":[{"artifact_kind":"mlx_weight_file","hash_scope":"macprovider.snapshot-manifest.v1","model_id":"$MLX_ID","min_ram_gb":8,"sha256":"$mlx_sha","source":"lab-1690-m6"}]}
EOF
  go run "$sc" sign -key "$LAB/keys/tier2.priv" -key-id lab-1690-m6-tier2 -out "$LAB/static/tier2-catalog.json" "$LAB/static/tier2-unsigned.json"
}

cmd_up() {
  python3 "$HERE/write_configs.py"
  start_bg coordinator "$LAB/bin/coordinator" -config "$LAB/run/coordinator.yaml"
  wait_http http://127.0.0.1:19101/healthz
  if [[ ! -f "$LAB/keys/provider-token.out" ]]; then
    (umask 077; "$LAB/bin/coordinator-cli" issue-token -db "$LAB/db/coordinator.db" -provider-id lab-1690-m6-provider -provider-name lab-1690-m6 >"$LAB/keys/provider-token.out")
  fi
  [[ -f "$LAB/keys/buyer-key-acct-lab-1690-buyer" ]] || python3 "$HERE/seed_gateway.py"
  start_bg gateway "$LAB/bin/gateway" -config "$LAB/run/gateway.yaml"
  wait_http http://127.0.0.1:19110/healthz
  start_bg llama-server "$LLAMA_DIR/llama-server" -m "$LAB/models/$GGUF_FILE" --host 127.0.0.1 --port 19130 -c 8192 -np 4 -ngl 99
  wait_http http://127.0.0.1:19130/health
  start_bg usage-tap python3 "$HERE/usage_tap.py" 19131 19130 "$LAB/logs/upstream-usage.jsonl" "$LAB/run/strip-usage" "$LAB/run/slow-stream"
  if [[ ! -d "$LAB/provider/protected-credentials" ]]; then
    (umask 077; cat >"$LAB/provider/config.yaml" <<EOF
coordinator_url: ws://127.0.0.1:19102/ws/provider
provider_id: lab-1690-m6-provider
provider_token: $(grep '^token=' "$LAB/keys/provider-token.out" | cut -d= -f2)
credential_store: protected_file
enable_receipts: true
port: 19120
model: llamacpp:${GGUF_FILE%.gguf}
model_catalog_key: $ROW_KEY
model_catalog_model_id: $MLX_ID
loopback_origin: http://127.0.0.1:19131
auto_update_enabled: false
EOF
    )
    "$HERE/cli.sh" credentials import --config "$LAB/provider/config.yaml"
  fi
  "$HERE/serve.sh" start
  if [[ ! -f "$LAB/logs/offer.json" ]]; then
    "$HERE/cli.sh" models offer "llamacpp:${GGUF_FILE%.gguf}" --yes --json --config "$LAB/provider/config.yaml" \
      --coordinator-url http://127.0.0.1:19102 --mlx-cache-dir "$LAB/home/hf" --skip-ollama --skip-lmstudio \
      --skip-openai-compatible --llamacpp-origin http://127.0.0.1:19131 >"$LAB/logs/offer.json"
    python3 - "$LAB" <<'EOF'
import json, sys, urllib.request
lab = sys.argv[1]
offer = json.load(open(f"{lab}/logs/offer.json"))
key = json.load(open(f"{lab}/keys/secrets.json"))["operator_lab_a"]
body = {"schema": "model_admission_decision_request.v1", "provider_id": offer["provider_id"], "candidate_id": offer["candidate_id"],
        "next_state": "catalog_priced", "reason_code": "operator_lab_pool_priced",
        "expected_coordinator_event_id": offer["coordinator_event_id"], "idempotency_key": "lab-1690-m6-priced-1"}
req = urllib.request.Request("http://127.0.0.1:19102/admin/model-admission/decisions", data=json.dumps(body).encode(),
                             headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
doc = json.load(urllib.request.urlopen(req))
open(f"{lab}/logs/decision-catalog-priced.json", "w").write(json.dumps(doc))
print("decision:", doc["admission_state"])
EOF
  fi
  [[ -d "$LAB/pools/A" ]] || python3 "$HERE/pool_setup.py" create A --encoding 2 --runtime-allowlist llamacpp_loopback
  echo "rig up"
}

cmd_down() {
  "$HERE/serve.sh" stop
  for p in usage-tap llama-server gateway coordinator; do stop_pid "$p"; done
  echo "rig down"
}

cmd_status() {
  for p in serve usage-tap llama-server gateway coordinator; do
    if [[ -f "$LAB/run/$p.pid" ]] && kill -0 "$(cat "$LAB/run/$p.pid")" 2>/dev/null; then echo "$p: pid $(cat "$LAB/run/$p.pid")"; else echo "$p: stopped"; fi
  done
  if curl -fs http://127.0.0.1:19102/healthz >/dev/null 2>&1; then
    curl -s -H "Authorization: Bearer $(secret operator_key)" http://127.0.0.1:19102/poolz | python3 -c '
import json, sys
for p in json.load(sys.stdin)["pool"]:
    print({k: p.get(k) for k in ("provider_id", "runtime_source", "model_hash_algorithm", "hash_status", "catalog_admission_mode", "state", "slots_total")})'
  fi
}

case "${1:-}" in
  model) cmd_model ;;
  build) cmd_build ;;
  build-spoof) cmd_build_spoof ;;
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  *) echo "usage: rig.sh model|build|build-spoof|up|down|status" >&2; exit 2 ;;
esac
