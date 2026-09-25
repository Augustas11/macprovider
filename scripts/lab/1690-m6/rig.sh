#!/usr/bin/env bash
# #1690 M6 lab rig: a branch-built coordinator + gateway + provider CLI serving
# a llama.cpp llama-server GGUF member of a SPEC-042 Trusted Pool, fully
# isolated on 127.0.0.1:19101-19131 with lab keys under $LAB.
#
#   rig.sh model    download the pinned GGUF and check its sha256
#   rig.sh build    build coordinator, coordinator-cli, gateway, labtool, lab CLI
#   rig.sh build-spoof  build a lab-only CLI whose auth runtime_source can be
#                   overridden by LAB_SPOOF_RUNTIME_SOURCE (a hostile client)
#   rig.sh up       start everything, offer + price the candidate, create the
#                   engine's pool (A llamacpp, M mlxlm, O ollama)
#   rig.sh server-start | server-stop   start/stop only the ENGINE model server
#
# ENGINE=llamacpp (default, #1690 M6/M7) | mlxlm | ollama (#1690 M8) picks the
# one model server behind the usage tap: llama-server, mlx_lm.server from
# $LAB/venv serving MLXLM_SNAPSHOT, or Ollama's release binary in
# $LAB/ollama with OLLAMA_MODELS under $LAB. Only one runs at a time.
#   rig.sh down     stop every lab process (by recorded, verified identity only)
#
# #1690 e2e (scripts/lab/1690-e2e): ENGINE=native serves the catalog MLX row
# in-process (mlx_cache) from the lab Hugging Face cache; it offers nothing
# and joins pool A, which allows native MLX by definition.
#   rig.sh build-native         the lab-only native-preflight CLI (see cmd_build_native)
#   rig.sh configs              rewrite the configs (E2E_* env, write_configs.py)
#   rig.sh gateway-restart      restart only the gateway on the current configs
#   rig.sh coordinator-restart  restart only the coordinator
#   rig.sh proxy-start | proxy-stop   the fault proxy (E2E_PROXY_PORT, default
#                   19105) between the gateway and the coordinator buyer port
#   rig.sh status   show lab processes and the coordinator's view of the member
#
# It never signals a process by name, never uses port 8080/8443/8444, never
# reads ~/.config/macprovider, and never contacts a production host. The lab
# CLI runs through cli.sh, which redirects every home-derived path into $LAB.
# A process is signalled only after pidguard.sh re-verifies the identity it
# recorded at start. Every lab binary (coordinator, gateway, labtool, CLI) and
# the signing tool build from one exported copy of HEAD under $LAB/src*; build
# and up refuse a worktree with uncommitted tracked changes, and the worktree
# is never modified.
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
ENGINE="${ENGINE:-llamacpp}"
MLXLM_SNAPSHOT="${MLXLM_SNAPSHOT:-$LAB/models/mlx/Qwen2.5-0.5B-Instruct-4bit}"
OLLAMA_TAG="${OLLAMA_TAG:-qwen2.5:0.5b}"
export OLLAMA_MODELS="$LAB/ollama-models" OLLAMA_HOST=127.0.0.1:19130
# mlx_lm.server scans only the lab Hugging Face home and never downloads.
export HF_HOME="$LAB/home/hf" HF_HUB_OFFLINE=1
export PATH="$GO_BIN:$PATH" GOTOOLCHAIN=local LAB
# shellcheck source=pidguard.sh
. "$HERE/pidguard.sh"

mkdir -p "$LAB"/{bin,logs,models,keys,db,run,static,pools,home,tmp,provider}
chmod 700 "$LAB/keys" "$LAB/home"

secret() { python3 -c "import json,sys;print(json.load(open('$LAB/keys/secrets.json'))[sys.argv[1]])" "$1"; }
start_bg() { # name cmd...
  local pidf="$LAB/run/$1.pid" log="$LAB/logs/$1.log"; shift
  nohup "$@" >>"$log" 2>&1 &
  pg_record "$pidf" $!
}
stop_pid() { pg_stop "$LAB/run/$1.pid" 20 0.5; }
# require_clean: refuse when any tracked file differs from HEAD. The lab builds
# from HEAD and runs its helpers from this worktree, so edits would either be
# silently missing from the binaries or produce evidence for code HEAD lacks.
require_clean() {
  local dirty
  dirty=$(git -C "$WT" status --porcelain --untracked-files=no -- . ':(exclude)phase3-binary/Package.resolved')
  if [[ -n "$dirty" ]]; then
    printf 'refusing: the worktree has uncommitted changes; the lab builds and runs HEAD only\n%s\n' "$dirty" >&2
    exit 1
  fi
}
# prep_src DIR: export all of HEAD into $LAB/DIR (SRC_ROOT; SRC is its
# phase3-binary). SwiftPM's .build cache is kept; extracted files get fresh
# mtimes so every source recompiles.
prep_src() {
  require_clean
  SRC_ROOT="$LAB/$1"
  SRC="$SRC_ROOT/phase3-binary"
  if [[ -d "$SRC/.build" ]]; then mv "$SRC/.build" "$LAB/$1.build-cache"; fi
  rm -rf "${LAB:?}/$1"
  mkdir -p "$SRC_ROOT"
  git -C "$WT" archive HEAD | tar -xm -C "$SRC_ROOT"
  if [[ -d "$LAB/$1.build-cache" ]]; then mv "$LAB/$1.build-cache" "$SRC/.build"; fi
}
static_swift() {
  cp "$LAB/static/AutotuneCatalog.generated.swift" "$SRC/Sources/macprovider-cli/AutotuneCatalog.generated.swift"
  # #1690 e2e: the CLI's signed-static loader (AutotuneRecommend.swift
  # loadSignedStatic) GETs https://coordinator.malibu.tech/v1/<name>{,.sig}
  # on every serve preflight, a hardcoded production URL. Point the lab build
  # at a closed lab loopback port so the fetch fails fast and the baked lab
  # release is used, and no lab process contacts production.
  python3 - "$SRC/Sources/macprovider-cli/AutotuneRecommend.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'URL(string: "https://coordinator.malibu.tech/v1/\\(name)'
assert s.count(old) == 2, f"static feed URL sites: {s.count(old)}"
open(p, "w").write(s.replace(old, 'URL(string: "http://127.0.0.1:19108/v1/\\(name)'))
PY
}
wait_http() { for _ in $(seq 1 60); do curl -fs "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "timeout waiting for $1" >&2; return 1; }

cmd_model() {
  local f="$LAB/models/$GGUF_FILE"
  [[ -f "$f" ]] || curl -fsSL -o "$f" "https://huggingface.co/$GGUF_REPO/resolve/$GGUF_REV/$GGUF_FILE"
  [[ "$(shasum -a 256 "$f" | cut -c1-64)" == "$GGUF_SHA" ]] || { echo "GGUF sha256 mismatch" >&2; exit 1; }
  echo "model ok: $f"
}

cmd_build() {
  # Every artifact builds from one export of HEAD, never from the worktree.
  prep_src src
  (cd "$SRC_ROOT/phase4-coordinator" && go build -o "$LAB/bin/coordinator" ./cmd/coordinator && go build -o "$LAB/bin/coordinator-cli" ./cmd/coordinator-cli)
  (cd "$SRC_ROOT/phase5-gateway" && go build -o "$LAB/bin/gateway" ./cmd/gateway)
  printf '{"Replace":{"%s/cmd/lab1690m6/main.go":"%s"}}' "$SRC_ROOT/phase4-coordinator" "$SRC_ROOT/scripts/lab/1690-m6/labtool/main.go" >"$LAB/run/overlay.json"
  (cd "$SRC_ROOT/phase4-coordinator" && go build -overlay "$LAB/run/overlay.json" -o "$LAB/bin/labtool" ./cmd/lab1690m6)
  cmd_static
  # The lab CLI is the branch CLI (HEAD) with the lab static release compiled in.
  static_swift
  (cd "$SRC" && swift build -c release --product macprovider-cli)
  cp "$SRC/.build/release/macprovider-cli" "$LAB/bin/macprovider-cli-lab"
  cp "$METALLIB" "$LAB/bin/mlx.metallib"
  echo "build ok"
}

cmd_build_spoof() {
  # A spoofing client for the SPEC-042-R013 spoofed-hello case. The patch is
  # applied only to its own exported tree ($LAB/src-spoof), never the
  # worktree; the binary lives only in $LAB/bin.
  prep_src src-spoof
  static_swift
  python3 - "$SRC/Sources/macprovider-cli/CoordinatorClient.swift" <<'PY'
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
  (cd "$SRC" && swift build -c release --product macprovider-cli)
  cp "$SRC/.build/release/macprovider-cli" "$LAB/bin/macprovider-cli-lab-spoof"
  echo "spoof build ok"
}

cmd_build_native() {
  # #1690 e2e: a lab-only CLI that runs the real native catalog preflight in
  # the isolated lab. The shipped CLI skips it for an --isolate-lifecycle join
  # to a loopback coordinator (relaxesJoinAdmissionForLab), so a native member
  # joins uncatalogued and never serves. LAB_NATIVE_CATALOG_PREFLIGHT=1 turns
  # that relaxation off. Patched only in its own export ($LAB/src-native).
  prep_src src-native
  static_swift
  python3 - "$SRC/Sources/macprovider-cli/MacProviderCLI.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """        isolateLifecycle && isLoopbackCoordinatorURL(coordinatorURL)
    }"""
new = """        if ProcessInfo.processInfo.environment["LAB_NATIVE_CATALOG_PREFLIGHT"] == "1" { return false }
        return isolateLifecycle && isLoopbackCoordinatorURL(coordinatorURL)
    }"""
assert s.count(old) == 1, "relaxesJoinAdmissionForLab body not found"
open(p, "w").write(s.replace(old, new))
PY
  (cd "$SRC" && swift build -c release --product macprovider-cli)
  cp "$SRC/.build/release/macprovider-cli" "$LAB/bin/macprovider-cli-lab-native"
  echo "native build ok"
}

cmd_static() {
  [[ -f "$LAB/static/tier2-catalog.json" && -f "$LAB/static/AutotuneCatalog.generated.swift" ]] && return 0
  # MLX_SHA (#1690 M8): the real snapshot-manifest digest of MLXLM_SNAPSHOT,
  # so mlx_lm.server can bind the row; else the M6 placeholder.
  local mlx_sha="${MLX_SHA:-$(printf 'lab-1690-m6 placeholder mlx primary' | shasum -a 256 | cut -c1-64)}"
  local extra=()
  [[ -n "${MLX_RUNTIME_SOURCES:-}" ]] && extra+=(--mlx-runtime-sources "$MLX_RUNTIME_SOURCES")
  [[ -n "${OLLAMA_GGUF_SHA:-}" ]] && extra+=(--ollama-tag "$OLLAMA_TAG" --ollama-gguf-sha256 "$OLLAMA_GGUF_SHA" --ollama-gguf-size "$OLLAMA_GGUF_SIZE")
  "$LAB/bin/labtool" static-release --out-dir "$LAB/static" --key-file "$LAB/keys/static-feed.ed25519" \
    --release lab-1690-m6-r1 --generated-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --row-key "$ROW_KEY" \
    --mlx-model-id "$MLX_ID" --mlx-revision "$MLX_REV" --mlx-sha256 "$mlx_sha" \
    --gguf-sha256 "$GGUF_SHA" --gguf-size "$(stat -f %z "$LAB/models/$GGUF_FILE")" --gguf-repo "$GGUF_REPO" \
    --gguf-revision "$GGUF_REV" --gguf-file "$GGUF_FILE" --swift-out "$LAB/static/AutotuneCatalog.generated.swift" ${extra[@]+"${extra[@]}"}
  local sc="$SRC_ROOT/scripts/sign-catalog.go"
  [[ -f "$LAB/keys/tier2.priv" ]] || go run "$sc" keygen -public-out "$LAB/keys/tier2.pub" -private-out "$LAB/keys/tier2.priv"
  chmod 600 "$LAB/keys/tier2.priv"
  cat >"$LAB/static/tier2-unsigned.json" <<EOF
{"version":1,"catalog_id":"lab-1690-m6-tier2","issued_at":"$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)","expires_at":"$(date -u -v+7d +%Y-%m-%dT%H:%M:%SZ)","models":[{"artifact_kind":"mlx_weight_file","hash_scope":"macprovider.snapshot-manifest.v1","model_id":"$MLX_ID","min_ram_gb":8,"sha256":"$mlx_sha","source":"lab-1690-m6"}]}
EOF
  go run "$sc" sign -key "$LAB/keys/tier2.priv" -key-id lab-1690-m6-tier2 -out "$LAB/static/tier2-catalog.json" "$LAB/static/tier2-unsigned.json"
}

cmd_up() {
  require_clean
  python3 "$HERE/write_configs.py"
  start_bg coordinator "$LAB/bin/coordinator" -config "$LAB/run/coordinator.yaml"
  wait_http http://127.0.0.1:19101/healthz
  if [[ "$ENGINE" == native && "${E2E_NATIVE_CLEAR_ADMISSION:-0}" == 1 ]]; then
    # #1690 e2e: any model_admission_events row for a provider (a loopback
    # engine's offer, even revoked) excludes it from default catalog routing
    # (SPEC-047-R003), so the same provider can serve native again only after
    # its rows are removed. Lab DB only; the rows are backed up first.
    sqlite3 "$LAB/db/coordinator.db" ".mode insert model_admission_events" \
      "SELECT * FROM model_admission_events WHERE provider_id = 'lab-1690-m6-provider';" \
      >"$LAB/logs/admission-events-backup-$(date -u +%Y%m%dT%H%M%SZ).sql"
    sqlite3 "$LAB/db/coordinator.db" "DELETE FROM model_admission_events WHERE provider_id = 'lab-1690-m6-provider';"
  fi
  if [[ ! -f "$LAB/keys/provider-token.out" ]]; then
    (umask 077; "$LAB/bin/coordinator-cli" issue-token -db "$LAB/db/coordinator.db" -provider-id lab-1690-m6-provider -provider-name lab-1690-m6 >"$LAB/keys/provider-token.out")
  fi
  [[ -f "$LAB/keys/buyer-key-acct-lab-1690-buyer" ]] || python3 "$HERE/seed_gateway.py"
  start_bg gateway "$LAB/bin/gateway" -config "$LAB/run/gateway.yaml"
  wait_http http://127.0.0.1:19110/healthz
  cmd_server_start
  pg_verify "$LAB/run/usage-tap.pid" >/dev/null 2>&1 || start_bg usage-tap python3 "$HERE/usage_tap.py" 19131 19130 "$LAB/logs/upstream-usage.jsonl" "$LAB/run/strip-usage" "$LAB/run/slow-stream"
  if [[ ! -d "$LAB/provider/protected-credentials" ]]; then
    (umask 077; cat >"$LAB/provider/config.yaml" <<EOF
coordinator_url: ws://127.0.0.1:19102/ws/provider
provider_id: lab-1690-m6-provider
provider_token: $(grep '^token=' "$LAB/keys/provider-token.out" | cut -d= -f2)
credential_store: protected_file
enable_receipts: true
port: 19120
model: $(engine_model_ref)
model_catalog_key: $ROW_KEY
model_catalog_model_id: $MLX_ID
loopback_origin: http://127.0.0.1:19131
auto_update_enabled: false
EOF
    )
    "$HERE/cli.sh" credentials import --config "$LAB/provider/config.yaml"
  fi
  # One model line per engine; the protected credentials stay as imported.
  # Native (#1690 e2e) serves the catalog MLX snapshot in the lab Hugging
  # Face cache, pinned by its snapshot-manifest digest (what autotune
  # --apply would write; autotune itself is never run next to the live
  # provider). Loopback engines carry no artifact pin.
  python3 - "$LAB/provider/config.yaml" "$(engine_model_ref)" "$ENGINE" "${MLX_SHA:-}" \
    "$HF_HOME/hub/models--mlx-community--Qwen2.5-0.5B-Instruct-4bit/snapshots/$MLX_REV" "$MLX_REV" \
    "$LAB/static/autotune-candidates.json" <<'EOF'
import hashlib, json, re, sys
path, ref, engine, sha, snap, rev, candidates = sys.argv[1:8]
text = open(path).read()
text = re.sub(r"(?m)^model: .*$", "model: " + ref, text, count=1)
text = re.sub(r"(?m)^model_artifact_(sha256|path): .*\n", "", text)
text = re.sub(r"(?m)^model_catalog_(revision|sha256|version|hash): .*\n", "", text)
if engine == "native":
    if not sha:
        sys.exit("ENGINE=native needs MLX_SHA (scripts/lab/1690-e2e/env.sh)")
    raw = open(candidates, "rb").read()
    text += (f"model_artifact_sha256: {sha}\nmodel_artifact_path: {snap}\nmodel_catalog_revision: {rev}\n"
             f"model_catalog_sha256: {sha}\nmodel_catalog_version: {json.loads(raw)['version']}\n"
             f"model_catalog_hash: {hashlib.sha256(raw).hexdigest()}\n")
open(path, "w").write(text)
EOF
  if [[ "$ENGINE" == native && -x "$LAB/bin/macprovider-cli-lab-native" ]]; then
    LAB_CLI="$LAB/bin/macprovider-cli-lab-native" LAB_NATIVE_CATALOG_PREFLIGHT=1 "$HERE/serve.sh" start
  else
    "$HERE/serve.sh" start
  fi
  # E2E_REOFFER=1 (#1690 e2e): offer and price again even when an offer file
  # exists. One provider switching engines revokes the previous engine's
  # catalog_priced candidate (runtime_identity_drift, SPEC-047-R006), so every
  # engine switch needs a fresh offer and operator pricing, then a serve
  # restart to bind it.
  local reoffer=0
  if [[ "$ENGINE" != native && "${E2E_REOFFER:-0}" == 1 && -f "$LAB/logs/$(offer_name)" ]]; then reoffer=1; fi
  if [[ "$ENGINE" != native && ( ! -f "$LAB/logs/$(offer_name)" || $reoffer == 1 ) ]]; then
    # A re-offer while this engine's candidate is still current is refused
    # (HTTP 409); then the existing priced candidate stands.
    if ! "$HERE/cli.sh" models offer "$(engine_model_ref)" --yes --json --config "$LAB/provider/config.yaml" \
      --coordinator-url http://127.0.0.1:19102 --mlx-cache-dir "$LAB/home/hf" $(engine_offer_flags) >"$LAB/logs/$(offer_name).new"; then
      rm -f "$LAB/logs/$(offer_name).new"
      [[ $reoffer == 1 ]] || exit 1
      echo "re-offer refused; the current candidate stands"
      reoffer=2
    else
      mv "$LAB/logs/$(offer_name).new" "$LAB/logs/$(offer_name)"
    fi
  fi
  if [[ "$ENGINE" != native && $reoffer != 2 && ( $reoffer == 1 || ! -f "$LAB/logs/decision-catalog-priced$([[ $ENGINE == llamacpp ]] || echo "-$ENGINE").json" ) ]]; then
    python3 - "$LAB" "$(offer_name)" "$ENGINE" "$reoffer" <<'EOF'
import json, sys, urllib.request
lab, name, engine = sys.argv[1], sys.argv[2], sys.argv[3]
offer = json.load(open(f"{lab}/logs/{name}"))
key = json.load(open(f"{lab}/keys/secrets.json"))["operator_lab_a"]
body = {"schema": "model_admission_decision_request.v1", "provider_id": offer["provider_id"], "candidate_id": offer["candidate_id"],
        "next_state": "catalog_priced", "reason_code": "operator_lab_pool_priced",
        "expected_coordinator_event_id": offer["coordinator_event_id"],
        "idempotency_key": f"lab-1690-e2e-repriced-{offer['coordinator_event_id']}" if sys.argv[4] == "1" else
                           ("lab-1690-m6-priced-1" if engine == "llamacpp" else f"lab-1690-m8-priced-{engine}")}
req = urllib.request.Request("http://127.0.0.1:19102/admin/model-admission/decisions", data=json.dumps(body).encode(),
                             headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
doc = json.load(urllib.request.urlopen(req))
open(f"{lab}/logs/decision-catalog-priced{'' if engine == 'llamacpp' else '-' + engine}.json", "w").write(json.dumps(doc))
print("decision:", doc["admission_state"])
EOF
    if [[ $reoffer == 1 ]]; then "$HERE/serve.sh" start; fi
  fi
  case "$ENGINE" in
    llamacpp|native) [[ -d "$LAB/pools/A" ]] || python3 "$HERE/pool_setup.py" create A --encoding 2 --runtime-allowlist llamacpp_loopback ;;
    mlxlm) [[ -d "$LAB/pools/M" ]] || python3 "$HERE/pool_setup.py" create M --encoding 2 --runtime-allowlist mlxlm_loopback ;;
    ollama) [[ -d "$LAB/pools/O" ]] || python3 "$HERE/pool_setup.py" create O --encoding 2 --runtime-allowlist ollama_loopback ;;
  esac
  echo "rig up"
}

engine_model_ref() {
  case "$ENGINE" in
    llamacpp) echo "llamacpp:${GGUF_FILE%.gguf}" ;;
    mlxlm) echo "mlxlm:$(basename "$MLXLM_SNAPSHOT")" ;;
    ollama) echo "ollama:$OLLAMA_TAG" ;;
    native) echo "$ROW_KEY" ;;
    *) echo "unknown ENGINE $ENGINE" >&2; exit 2 ;;
  esac
}
offer_name() { if [[ "$ENGINE" == llamacpp ]]; then echo offer.json; else echo "offer-$ENGINE.json"; fi; }
engine_offer_flags() {
  case "$ENGINE" in
    llamacpp) echo "--skip-ollama --skip-lmstudio --skip-openai-compatible --llamacpp-origin http://127.0.0.1:19131" ;;
    mlxlm) echo "--skip-ollama --skip-lmstudio --skip-openai-compatible --skip-llamacpp" ;;
    ollama) echo "--ollama-origin http://127.0.0.1:19131 --skip-lmstudio --skip-openai-compatible --skip-llamacpp" ;;
  esac
}

# The one model server for ENGINE on 127.0.0.1:19130 (the tap is 19131).
cmd_server_start() {
  case "$ENGINE" in
    llamacpp)
      start_bg llama-server "$LLAMA_DIR/llama-server" -m "$LAB/models/$GGUF_FILE" --host 127.0.0.1 --port 19130 -c 8192 -np 4 -ngl 99 --jinja
      wait_http http://127.0.0.1:19130/health ;;
    mlxlm)
      # mlx_lm.server lists its Hugging Face cache and fails the listing when
      # the cache directory does not exist.
      mkdir -p "$HF_HOME/hub"
      start_bg mlxlm-server "$LAB/venv/bin/python3" "$LAB/venv/bin/mlx_lm.server" \
        --model "$MLXLM_SNAPSHOT" --host 127.0.0.1 --port 19130
      wait_http http://127.0.0.1:19130/health ;;
    ollama)
      start_bg ollama "$LAB/ollama/ollama" serve
      wait_http http://127.0.0.1:19130/api/version ;;
    native) ;;
  esac
}

cmd_server_stop() { for p in llama-server mlxlm-server ollama; do stop_pid "$p"; done; }

cmd_down() {
  "$HERE/serve.sh" stop
  for p in trailer-proxy usage-tap llama-server mlxlm-server ollama gateway coordinator; do stop_pid "$p"; done
  echo "rig down"
}

cmd_status() {
  for p in serve trailer-proxy usage-tap llama-server mlxlm-server ollama gateway coordinator; do
    if pid=$(pg_verify "$LAB/run/$p.pid"); then echo "$p: pid $pid"; elif [[ -f "$LAB/run/$p.pid" ]]; then echo "$p: stale pid file"; else echo "$p: stopped"; fi
  done
  if curl -fs http://127.0.0.1:19102/healthz >/dev/null 2>&1; then
    curl -s -H "Authorization: Bearer $(secret operator_key)" http://127.0.0.1:19102/poolz | python3 -c '
import json, sys
for p in json.load(sys.stdin)["pool"]:
    print({k: p.get(k) for k in ("provider_id", "runtime_source", "model_hash_algorithm", "hash_status", "catalog_admission_mode", "state", "slots_total")})'
  fi
}

cmd_gateway_restart() {
  stop_pid gateway
  start_bg gateway "$LAB/bin/gateway" -config "$LAB/run/gateway.yaml"
  wait_http http://127.0.0.1:19110/healthz
}
cmd_coordinator_restart() {
  stop_pid coordinator
  start_bg coordinator "$LAB/bin/coordinator" -config "$LAB/run/coordinator.yaml"
  wait_http http://127.0.0.1:19101/healthz
}
cmd_proxy_start() {
  pg_verify "$LAB/run/trailer-proxy.pid" >/dev/null 2>&1 && return 0
  start_bg trailer-proxy python3 "$WT/scripts/lab/1690-e2e/trailer_proxy.py" "${E2E_PROXY_PORT:-19105}" 19101 "$LAB/run/proxy-mode" "$LAB/logs/proxy.jsonl"
  sleep 0.5
}

case "${1:-}" in
  model) cmd_model ;;
  configs) python3 "$HERE/write_configs.py" ;;
  gateway-restart) cmd_gateway_restart ;;
  coordinator-restart) cmd_coordinator_restart ;;
  proxy-start) cmd_proxy_start ;;
  proxy-stop) stop_pid trailer-proxy ;;
  build) cmd_build ;;
  build-spoof) cmd_build_spoof ;;
  build-native) cmd_build_native ;;
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  server-start) cmd_server_start ;;
  server-stop) cmd_server_stop ;;
  *) echo "usage: rig.sh model|build|build-spoof|up|down|status|server-start|server-stop|configs|gateway-restart|coordinator-restart|proxy-start|proxy-stop" >&2; exit 2 ;;
esac
