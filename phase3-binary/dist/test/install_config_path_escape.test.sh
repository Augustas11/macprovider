#!/usr/bin/env bash
# Regression: autotune --apply quotes a model artifact path that contains a
# space (e.g. under ".../Application Support/...") and, on some platforms, the
# quoting JSON-escapes the slashes ("\/Users\/..."). install.sh's config
# read-back MUST unescape those so the absolute-path check (`case "$p" in /*)`)
# sees a real leading "/". Otherwise the installer wrongly concludes "no paid
# model cleared" and dies 30 with nothing committed — on ANY Mac.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract only the config read-back functions under test.
python3 - "$INSTALL_SH" > "$TMP/fn.sh" <<'PY'
import sys
names = {"read_config_artifact_path", "read_config_model", "read_config_catalog_model_id"}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = 0
while i < len(lines):
    name = lines[i].split("()", 1)[0].strip() if "()" in lines[i] else ""
    if name not in names:
        i += 1
        continue
    depth = 0
    while i < len(lines):
        line = lines[i]
        print(line)
        depth += line.count("{") - line.count("}")
        i += 1
        if depth == 0:
            break
PY

# shellcheck disable=SC1090
source "$TMP/fn.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

CONFIG_PATH="$TMP/config.yaml"
plain="/Users/admin/Library/Application Support/macprovider/models/mlx-community--Llama-3.2-3B/rev/abc"

# 1) Escaped, quoted path (the bug): slashes are backslash-escaped.
printf 'model: meta-llama/llama-3.2-3b-instruct\n' > "$CONFIG_PATH"
printf 'model_artifact_path: "\\/Users\\/admin\\/Library\\/Application Support\\/macprovider\\/models\\/mlx-community--Llama-3.2-3B\\/rev\\/abc"\n' >> "$CONFIG_PATH"

got="$(read_config_artifact_path)"
[ "$got" = "$plain" ] || fail "escaped path not unescaped: got [$got]"
case "$got" in /*) : ;; *) fail "unescaped path must start with / : [$got]" ;; esac

# read_config_model round-trips a plain (unquoted) value untouched.
[ "$(read_config_model)" = "meta-llama/llama-3.2-3b-instruct" ] \
  || fail "read_config_model changed a plain value"

# 2) Plain, unescaped, quoted path (post-ConfigApplier-fix output): unchanged.
printf 'model_artifact_path: "%s"\n' "$plain" > "$CONFIG_PATH"
got="$(read_config_artifact_path)"
[ "$got" = "$plain" ] || fail "plain quoted path altered: got [$got]"

# 3) Unquoted, space-free path (legacy): unchanged.
printf 'model_artifact_path: /tmp/macprovider-test-snapshot\n' > "$CONFIG_PATH"
got="$(read_config_artifact_path)"
[ "$got" = "/tmp/macprovider-test-snapshot" ] || fail "unquoted path altered: got [$got]"

# 4) Escaped catalog model id unescapes too (defensive).
printf 'model_catalog_model_id: "mlx-community\\/Llama-3.2-3B-Instruct-4bit"\n' > "$CONFIG_PATH"
[ "$(read_config_catalog_model_id)" = "mlx-community/Llama-3.2-3B-Instruct-4bit" ] \
  || fail "catalog model id not unescaped"

echo "PASS: install.sh config read-back unescapes JSON-escaped slashes"
