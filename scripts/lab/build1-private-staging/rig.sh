#!/usr/bin/env bash
# Build 1 private-Qwen physical staging wrapper.
#
# This wrapper deliberately reuses the reviewed #1690 isolated coordinator /
# gateway rig while replacing only its lab model authority. It never uses live
# ports, live credentials, or the public candidate catalog.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export WT="${WT:-$(cd "$HERE/../../.." && pwd)}"
BASE_RIG="$WT/scripts/lab/1690-m6/rig.sh"

export LAB="${LAB:-/Users/a1/lab-build1-private-staging}"
export ENGINE=native
export LAB_ROW_KEY=orcarouter/qwen3.8-27b-uncensored
export LAB_MLX_ID=orcarouter/Qwen3.8-27B-Uncensored-MLX
export LAB_MLX_REV=38d0ad4e02031658fadd3828634a0174e0b8a282
export LAB_MLX_SHA=8794a87d2041dce5e915809d9e6c16da709d1763e25c4289f279d929aea88dcd
export MLX_SHA="$LAB_MLX_SHA"
export LAB_STATIC_RELEASE=build1-orcarouter-private-2026-09-26-v1
export LAB_STATIC_SIGNER_KEY_ID=streamvc-autotune-static-v4
# The Studio receives only the public signed feed. If the base rig ever tries
# to regenerate it instead of accepting the installed release, fail closed
# rather than signing lab bytes under the v4 key identifier.
export LAB_STATIC_SIGNING_KEY_FILE="$LAB/keys/v4-private-key-intentionally-absent"
export LAB_MLX_ARTIFACT_ID=mlx-4bit
export LAB_MLX_AUTHORITY_SHA="$LAB_MLX_SHA"
export LAB_MLX_AUTHORITY_SIZE=94723099062
export LAB_MLX_AUTHORITY_ARTIFACT_ID=mlx-revision-snapshot
export LAB_CATALOG_MLX_SHA=4ec355cd7cd3f48f7b6403d14ef8064b84678eb51eb2b3471d23522d2678e49d
export LAB_MLX_SIZE=16081489320
export E2E_NATIVE_CLEAR_ADMISSION=1

export BUILD1_PRIVATE_HF_CACHE="${BUILD1_PRIVATE_HF_CACHE:-$LAB/hf}"
DISCOVERY_SNAPSHOT="$BUILD1_PRIVATE_HF_CACHE/hub/models--orcarouter--Qwen3.8-27B-Uncensored-MLX/snapshots/$LAB_MLX_REV"

if [[ "${1:-}" != build-feed ]]; then
  case "$LAB" in
    /Users/a1/lab-build1-private-staging|/Users/a1/lab-build1-private-staging/*) ;;
    *) printf 'refusing: LAB must stay under /Users/a1/lab-build1-private-staging\n' >&2; exit 2 ;;
  esac
fi

if [[ "${1:-}" != build-feed && "${1:-}" != install-feed ]]; then
  : "${BUILD1_PRIVATE_SNAPSHOT:?set BUILD1_PRIVATE_SNAPSHOT to the verified durable snapshot root}"
  case "$BUILD1_PRIVATE_SNAPSHOT" in
    /*) ;;
    *) printf 'refusing: BUILD1_PRIVATE_SNAPSHOT must be absolute\n' >&2; exit 2 ;;
  esac
  [[ -d "$BUILD1_PRIVATE_SNAPSHOT/4-bit" ]] || {
    printf 'refusing: Build 1 private snapshot has no 4-bit runtime member\n' >&2
    exit 2
  }
  export MLXLM_SNAPSHOT="$BUILD1_PRIVATE_SNAPSHOT"
  export LAB_MODEL_ARTIFACT_ROOT="${BUILD1_PRIVATE_SNAPSHOT%/orcarouter--Qwen3.8-27B-Uncensored-MLX/$LAB_MLX_REV/$LAB_MLX_SHA}"
  [[ "$BUILD1_PRIVATE_SNAPSHOT" == "$LAB_MODEL_ARTIFACT_ROOT/orcarouter--Qwen3.8-27B-Uncensored-MLX/$LAB_MLX_REV/$LAB_MLX_SHA" ]] || {
    printf 'refusing: Build 1 private snapshot is outside the exact durable tuple path\n' >&2
    exit 2
  }
fi

prepare_discovery_cache() {
  [[ -d "$DISCOVERY_SNAPSHOT" ]] && return 0
  local source="$BUILD1_PRIVATE_SNAPSHOT/4-bit"
  local snapshots staging
  snapshots="$(dirname "$DISCOVERY_SNAPSHOT")"
  staging="$snapshots/.build1-private-$LAB_MLX_REV-$$"
  mkdir -p "$snapshots"
  # APFS clone-copy keeps the discovery view inside its declared cache root
  # without duplicating or modifying the durable prepared artifact.
  cp -cR "$source" "$staging"
  mv "$staging" "$DISCOVERY_SNAPSHOT"
}

require_discovery_cache() {
  [[ -f "$DISCOVERY_SNAPSHOT/config.json" ]] || {
    printf 'refusing: exact private-Qwen discovery cache is unavailable; run prepare first\n' >&2
    exit 2
  }
  find "$DISCOVERY_SNAPSHOT" -maxdepth 1 -type f -name '*.safetensors' -print -quit | grep -q . || {
    printf 'refusing: exact private-Qwen discovery cache contains no weights\n' >&2
    exit 2
  }
}

build_static_feed() {
  local output="${BUILD1_STATIC_FEED_OUT:?set BUILD1_STATIC_FEED_OUT to an absolute output directory}"
  local signing_key="${BUILD1_STATIC_SIGNING_KEY_FILE:-/Users/augstar/.config/macprovider/keys/autotune-static-v4.private.base64}"
  case "$output" in /*) ;; *) printf 'refusing: BUILD1_STATIC_FEED_OUT must be absolute\n' >&2; exit 2 ;; esac
  [[ -f "$signing_key" ]] || { printf 'refusing: stable v4 signing key is unavailable\n' >&2; exit 2; }
  mkdir -p "$output"
  local overlay labtool
  overlay="$(mktemp /tmp/build1-labtool-overlay.XXXXXX.json)"
  labtool="$(mktemp /tmp/build1-labtool.XXXXXX)"
  trap 'rm -f "$overlay" "$labtool"' RETURN
  printf '{"Replace":{"%s/cmd/lab1690m6/main.go":"%s"}}' \
    "$WT/phase4-coordinator" "$WT/scripts/lab/1690-m6/labtool/main.go" >"$overlay"
  (cd "$WT/phase4-coordinator" && go build -overlay "$overlay" -o "$labtool" ./cmd/lab1690m6)
  "$labtool" static-release \
    --out-dir "$output" --key-file "$signing_key" --key-id "$LAB_STATIC_SIGNER_KEY_ID" \
    --release "$LAB_STATIC_RELEASE" --generated-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --row-key "$LAB_ROW_KEY" --mlx-model-id "$LAB_MLX_ID" --mlx-revision "$LAB_MLX_REV" \
    --mlx-sha256 "$LAB_CATALOG_MLX_SHA" --mlx-size "$LAB_MLX_SIZE" --mlx-artifact-id "$LAB_MLX_ARTIFACT_ID" \
    --mlx-authority-sha256 "$LAB_MLX_AUTHORITY_SHA" --mlx-authority-size "$LAB_MLX_AUTHORITY_SIZE" \
    --mlx-authority-artifact-id "$LAB_MLX_AUTHORITY_ARTIFACT_ID" \
    --gguf-sha256 74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db \
    --gguf-size 1 --gguf-repo Qwen/Qwen2.5-0.5B-Instruct-GGUF \
    --gguf-revision 9217f5db79a29953eb74d5343926648285ec7e67 \
    --gguf-file qwen2.5-0.5b-instruct-q4_k_m.gguf \
    --swift-out "$output/AutotuneCatalog.generated.swift"
}

install_static_feed() {
  local source="${BUILD1_STATIC_FEED_SOURCE:?set BUILD1_STATIC_FEED_SOURCE to the generated public feed directory}"
  case "$source" in /*) ;; *) printf 'refusing: BUILD1_STATIC_FEED_SOURCE must be absolute\n' >&2; exit 2 ;; esac
  python3 - "$source" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
required = [
    "autotune-candidates.json", "demand-rank.json", "rate-card.json", "catalog-artifacts.json",
    "autotune-candidates.json.sig", "demand-rank.json.sig", "rate-card.json.sig", "catalog-artifacts.json.sig",
    "static-public-key.base64", "AutotuneCatalog.generated.swift",
]
for name in required:
    path = root / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"refusing unsafe or missing public feed file: {name}")
candidate_bytes = (root / "autotune-candidates.json").read_bytes()
candidate = json.loads(candidate_bytes)
feed = json.loads((root / "catalog-artifacts.json").read_bytes())
key = "orcarouter/qwen3.8-27b-uncensored"
if candidate.get("version") != "build1-orcarouter-private-2026-09-26-v1":
    raise SystemExit("refusing unexpected candidate release")
if feed.get("candidate_catalog_sha256") != hashlib.sha256(candidate_bytes).hexdigest():
    raise SystemExit("refusing unbound artifact feed")
model = feed.get("models", {}).get(key, {})
if model.get("primary_artifact_id") != "mlx-4bit":
    raise SystemExit("refusing unexpected primary artifact")
primary = model.get("artifacts", {}).get("mlx-4bit", {})
authority = model.get("artifacts", {}).get("mlx-revision-snapshot", {})
if primary.get("hash") != "4ec355cd7cd3f48f7b6403d14ef8064b84678eb51eb2b3471d23522d2678e49d" or primary.get("size_bytes") != 16081489320:
    raise SystemExit("refusing unexpected 4-bit member")
if authority.get("hash") != "8794a87d2041dce5e915809d9e6c16da709d1763e25c4289f279d929aea88dcd" or authority.get("size_bytes") != 94723099062:
    raise SystemExit("refusing unexpected complete-revision authority")
for name in required[4:8]:
    if json.loads((root / name).read_text()).get("key_id") != "streamvc-autotune-static-v4":
        raise SystemExit(f"refusing unexpected signer in {name}")
PY
  mkdir -p "$LAB/static"
  for name in autotune-candidates.json demand-rank.json rate-card.json catalog-artifacts.json \
    autotune-candidates.json.sig demand-rank.json.sig rate-card.json.sig catalog-artifacts.json.sig \
    static-public-key.base64 AutotuneCatalog.generated.swift; do
    cp "$source/$name" "$LAB/static/$name"
  done
  local tier2_signer="$WT/scripts/sign-catalog.go"
  mkdir -p "$LAB/keys"
  if [[ ! -f "$LAB/keys/tier2.priv" || ! -f "$LAB/keys/tier2.pub" ]]; then
    (cd "$WT" && go run "$tier2_signer" keygen \
      -public-out "$LAB/keys/tier2.pub" -private-out "$LAB/keys/tier2.priv")
  fi
  chmod 600 "$LAB/keys/tier2.priv"
  python3 - "$LAB/static/tier2-unsigned.json" "$LAB_MLX_ID" "$LAB_CATALOG_MLX_SHA" <<'PY'
import datetime, json, pathlib, sys
now = datetime.datetime.now(datetime.timezone.utc)
payload = {
    "version": 1,
    "catalog_id": "lab-1690-m6-tier2",
    "issued_at": (now - datetime.timedelta(hours=1)).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "expires_at": (now + datetime.timedelta(days=7)).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "models": [{
        "artifact_kind": "mlx_weight_file",
        "hash_scope": "macprovider.snapshot-manifest.v1",
        "model_id": sys.argv[2],
        "min_ram_gb": 8,
        "sha256": sys.argv[3],
        "source": "lab-1690-m6",
    }],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload, separators=(",", ":")) + "\n")
PY
  (cd "$WT" && go run "$tier2_signer" sign -key "$LAB/keys/tier2.priv" \
    -key-id lab-1690-m6-tier2 -out "$LAB/static/tier2-catalog.json" \
    "$LAB/static/tier2-unsigned.json")
}

case "${1:-}" in
  build-feed)
    build_static_feed
    ;;
  install-feed)
    install_static_feed
    ;;
  prepare)
    prepare_discovery_cache
    require_discovery_cache
    "$BASE_RIG" build
    "$BASE_RIG" build-native
    ;;
  rebuild-provider)
    require_discovery_cache
    "$BASE_RIG" build-native
    ;;
  request)
    require_discovery_cache
    python3 "$WT/scripts/lab/1690-m6/buyer.py" --n 1 --concurrency 1 --max-tokens 16
    ;;
  admit)
    require_discovery_cache
    python3 "$HERE/admit.py"
    ;;
  evidence)
    require_discovery_cache
    python3 "$WT/scripts/lab/1690-m6/evidence.py" --last 1
    ;;
  up|configs)
    require_discovery_cache
    exec "$BASE_RIG" "$1"
    ;;
  down|status)
    exec "$BASE_RIG" "$1"
    ;;
  *)
    printf 'usage: rig.sh build-feed|install-feed|prepare|rebuild-provider|up|admit|request|evidence|status|down|configs\n' >&2
    exit 2
    ;;
esac
