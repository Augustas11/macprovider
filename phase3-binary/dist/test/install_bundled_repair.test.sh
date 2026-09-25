#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
main = source[source.rindex("\nmain() {"):]
if "Repairing from Malibu.app bundled provider CLI (no GitHub download)." not in main:
    raise SystemExit("main() does not stage a Malibu.app bundled CLI for repair")
if "existing-install repair requires MACPROVIDER_BUNDLED_APP from Malibu.app" not in main:
    raise SystemExit("repair without a bundled Malibu.app must fail closed")
download = main.index('download_release "$tag"')
bundled = main.index("Repairing from Malibu.app bundled provider CLI (no GitHub download).")
if not bundled < download:
    raise SystemExit("bundled repair must be chosen before GitHub download_release")
if "stage_bundled_repair_payload" not in source:
    raise SystemExit("missing stage_bundled_repair_payload")
if 'Contents/Resources/compatibility-set.json' not in source:
    raise SystemExit("bundled repair must stage Malibu.app compatibility-set.json")
# Issue #1737: a non-repair (fresh) bundled install is allowed only with an
# explicit version pin, and is chosen before any release download.
fresh = main.index("Installing from the Developer ID-signed Malibu.app bundled provider CLI (no release download).")
if not fresh < download:
    raise SystemExit("fresh bundled install must be chosen before download_release")
if "a fresh install from MACPROVIDER_BUNDLED_APP requires MACPROVIDER_VERSION" not in main:
    raise SystemExit("fresh bundled install must require an explicit MACPROVIDER_VERSION pin")
for requirement in (
    'identifier "live.malibu.provider.cli" and anchor apple generic and certificate leaf[subject.OU] = "YF7XNRJUG4"',
    'identifier "tech.malibu.app" and anchor apple generic and certificate leaf[subject.OU] = "YF7XNRJUG4"',
):
    if requirement not in source:
        raise SystemExit(f"fresh bundled install must pin {requirement}")
PY

extract_function() {
  name="$1"
  awk -v start="${name}() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$INSTALL_SH"
}

for function_name in validated_bundled_cli validated_bundled_app verify_bundled_fresh_code_signature stage_bundled_repair_payload; do
  extract_function "$function_name" >> "$TMP/helpers.sh"
done

die() {
  printf '%s\n' "$2" > "$TMP/die-message"
  exit "$1"
}
log() { printf '%s\n' "$*"; }

# shellcheck source=/dev/null
source "$TMP/helpers.sh"

HOME="$TMP/home"
mkdir -m 700 "$HOME"
INSTALL_DIR="$HOME/macprovider"
mkdir -m 700 "$INSTALL_DIR"
printf '{"signed":{"components":{"provider_cli":{"version":"1.8.102"}}}}\n' \
  > "$INSTALL_DIR/compatibility-set.json"
mkdir "$INSTALL_DIR/compatibility-set-local" "$INSTALL_DIR/catalog-release"
printf 'old-mlx\n' > "$INSTALL_DIR/mlx.metallib"

app="$TMP/Malibu.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/compatibility-set-local" \
  "$app/Contents/Resources/catalog-release"
cat > "$app/Contents/MacOS/macprovider-cli" <<'EOF'
#!/bin/bash
echo "1.8.104"
EOF
chmod 0755 "$app/Contents/MacOS/macprovider-cli"
printf 'new-mlx\n' > "$app/Contents/MacOS/mlx.metallib"
printf '{"signed":{"components":{"provider_cli":{"version":"1.8.104"}}}}\n' \
  > "$app/Contents/Resources/compatibility-set.json"
printf 'local\n' > "$app/Contents/Resources/compatibility-set-local/install.sh"
printf 'catalog\n' > "$app/Contents/Resources/catalog-release/release.json"

BUNDLED_APP="$app"
BUNDLED_CLI=""
REPAIR_EXISTING_INSTALL=1
EMERGENCY_ROLLBACK=0
MACPROVIDER_ACCEPTANCE_ASSET_DIR=""
TMPDIR_PATH="$TMP/work"
mkdir -p "$TMPDIR_PATH"
tag="v1.8.104"

stage_bundled_repair_payload
[ -x "$TMPDIR_PATH/staging/macprovider-cli" ]
[ -f "$TMPDIR_PATH/staging/compatibility-set.json" ]
[ -d "$TMPDIR_PATH/staging/compatibility-set-local" ]
[ -d "$TMPDIR_PATH/staging/catalog-release" ]
[ -f "$TMPDIR_PATH/staging/mlx.metallib" ]
[ "$asset_kind" = "bundled" ]
grep -F '1.8.104' "$TMPDIR_PATH/staging/compatibility-set.json" >/dev/null
if grep -F '1.8.102' "$TMPDIR_PATH/staging/compatibility-set.json" >/dev/null; then
  echo "bundled repair staged the incumbent compatibility set" >&2
  exit 1
fi
grep -F 'new-mlx' "$TMPDIR_PATH/staging/mlx.metallib" >/dev/null

# Issue #1737: non-repair (fresh) installs from the Malibu.app bundle.
CODESIGN_LOG="$TMP/codesign.log"
write_codesign_stub() { # <path> <fail-pattern or empty>
  cat > "$1" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CODESIGN_LOG"
case "\$*" in *"${2:-__never__}"*) exit 1 ;; esac
exit 0
EOF
  chmod 0755 "$1"
}
write_codesign_stub "$TMP/codesign-ok" ""
write_codesign_stub "$TMP/codesign-app-fails" "tech.malibu.app"
write_codesign_stub "$TMP/codesign-cli-fails" "live.malibu.provider.cli"
MALIBU_APP_CODE_REQUIREMENT='identifier "tech.malibu.app" and anchor apple generic and certificate leaf[subject.OU] = "YF7XNRJUG4"'
MALIBU_CLI_CODE_REQUIREMENT='identifier "live.malibu.provider.cli" and anchor apple generic and certificate leaf[subject.OU] = "YF7XNRJUG4"'

# stage_as <repair 0|1> <codesign-bin> <work-subdir> <version-pin or ""> [tag]
stage_as() {
  local repair="$1" codesign_bin="$2" work="$3" pin="$4" want_tag="${5:-v1.8.104}"
  (
    REPAIR_EXISTING_INSTALL="$repair"
    BUNDLED_APP="$app"
    BUNDLED_CLI=""
    CODESIGN_BIN="$codesign_bin"
    if [ -n "$pin" ]; then MACPROVIDER_VERSION="$pin"; else unset MACPROVIDER_VERSION; fi
    tag="$want_tag"
    TMPDIR_PATH="$TMP/$work"
    mkdir -p "$TMPDIR_PATH"
    stage_bundled_repair_payload
  ) >/dev/null
}

# R1 — repair keeps its existing trust model and never consults codesign.
: > "$CODESIGN_LOG"
stage_as 1 "$TMP/codesign-app-fails" work-r1 ""
[ -x "$TMP/work-r1/staging/macprovider-cli" ] || { echo "R1: repair did not stage" >&2; exit 1; }
[ ! -s "$CODESIGN_LOG" ] || { echo "R1: repair must not change its verification" >&2; exit 1; }

# F1 — fresh without an explicit version pin is refused before staging.
: > "$TMP/die-message"
rc=0; stage_as 0 "$TMP/codesign-ok" work-f1 "" || rc=$?
[ "$rc" -eq 7 ] || { echo "F1: fresh bundled staging without a pin must exit 7, got $rc" >&2; exit 1; }
grep -F 'requires MACPROVIDER_VERSION' "$TMP/die-message" >/dev/null \
  || { echo "F1: wrong refusal: $(cat "$TMP/die-message")" >&2; exit 1; }
[ ! -e "$TMP/work-f1/staging/macprovider-cli" ] || { echo "F1 staged a CLI" >&2; exit 1; }

# F2 — fresh with a pin and valid Developer ID signatures stages the bundle and
# verifies both the app bundle and the private staged CLI copy.
: > "$CODESIGN_LOG"
stage_as 0 "$TMP/codesign-ok" work-f2 v1.8.104
[ -x "$TMP/work-f2/staging/macprovider-cli" ] || { echo "F2 did not stage the CLI" >&2; exit 1; }
[ -f "$TMP/work-f2/staging/compatibility-set.json" ] || { echo "F2 did not stage compatibility-set.json" >&2; exit 1; }
grep -F -- "--verify --strict --test-requirement==$MALIBU_APP_CODE_REQUIREMENT $app" "$CODESIGN_LOG" >/dev/null \
  || { echo "F2: app bundle signature not verified: $(cat "$CODESIGN_LOG")" >&2; exit 1; }
grep -F -- "--verify --strict --test-requirement==$MALIBU_CLI_CODE_REQUIREMENT $TMP/work-f2/staging/macprovider-cli" "$CODESIGN_LOG" >/dev/null \
  || { echo "F2: staged CLI signature not verified: $(cat "$CODESIGN_LOG")" >&2; exit 1; }

# F3 — an app bundle that fails its designated requirement stages nothing.
rc=0; stage_as 0 "$TMP/codesign-app-fails" work-f3 v1.8.104 || rc=$?
[ "$rc" -eq 4 ] || { echo "F3: app signature failure must exit 4, got $rc" >&2; exit 1; }
[ ! -e "$TMP/work-f3/staging/macprovider-cli" ] || { echo "F3 staged a CLI after app signature failure" >&2; exit 1; }

# F4 — a CLI that fails its designated requirement is refused.
rc=0; stage_as 0 "$TMP/codesign-cli-fails" work-f4 v1.8.104 || rc=$?
[ "$rc" -eq 4 ] || { echo "F4: CLI signature failure must exit 4, got $rc" >&2; exit 1; }

# F5 — no codesign tool fails closed.
rc=0; stage_as 0 "$TMP/no-such-codesign" work-f5 v1.8.104 || rc=$?
[ "$rc" -eq 4 ] || { echo "F5: missing codesign must exit 4, got $rc" >&2; exit 1; }

# F6 — the pinned tag must still match the bundled CLI and manifest versions.
rc=0; stage_as 0 "$TMP/codesign-ok" work-f6 v1.8.105 v1.8.105 || rc=$?
[ "$rc" -eq 5 ] || { echo "F6: bundled version mismatch must exit 5, got $rc" >&2; exit 1; }

# F7 — fresh bundled staging still refuses acceptance assets and emergency rollback.
rc=0
( MACPROVIDER_ACCEPTANCE_ASSET_DIR="$TMP"; stage_as 0 "$TMP/codesign-ok" work-f7 v1.8.104 ) || rc=$?
[ "$rc" -eq 7 ] || { echo "F7: acceptance mix must exit 7, got $rc" >&2; exit 1; }
rc=0
( EMERGENCY_ROLLBACK=1; stage_as 0 "$TMP/codesign-ok" work-f7b v1.8.104 ) || rc=$?
[ "$rc" -eq 7 ] || { echo "F7: emergency rollback mix must exit 7, got $rc" >&2; exit 1; }

echo "install_bundled_repair: PASS"
