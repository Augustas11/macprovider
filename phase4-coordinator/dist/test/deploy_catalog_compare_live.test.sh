#!/usr/bin/env bash
# #1688 A2: a runtime deploy must not roll back or churn the live catalog.
# Pins compare-live placement in deploy-pearl-vps.sh and runs the extracted
# compare + activation blocks against a local fake Pearl root for every branch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
TMP="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/deploy-compare-live-test.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

line_of() {
  local n
  n="$(grep -nF -- "$1" "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  [ -n "$n" ] || fail "deploy-pearl-vps.sh lost: $1"
  printf '%s' "$n"
}

# --- Static placement pins -------------------------------------------------
compare_line="$(line_of 'catalog-release.py compare-live --incoming')"
preflight_line="$(line_of 'failed remote verify-directory preflight')"
backup_line="$(line_of 'remote-config backup saved at')"
stage_line="$(line_of 'mv \$_autotune_stage \$_autotune_release')"
activate_line="$(line_of 'activating verified autotune release $AUTOTUNE_RELEASE_ID')"
window_line="$(line_of 'autotune_window.py apply --root')"
skip_line="$(line_of 'if [ "$CATALOG_VERDICT" = "equivalent" ]; then')"
[ "$preflight_line" -lt "$compare_line" ] || fail "compare-live must run after the verify-directory preflight"
for later in "$backup_line" "$stage_line" "$activate_line" "$window_line" "$skip_line"; do
  [ "$compare_line" -lt "$later" ] || fail "compare-live must run before config backup, release staging and activation"
done
grep -qF '"$AUTOTUNE_RELEASE_LEDGER=release-ledger.json"' "$DEPLOY_SH" ||
  fail "release-ledger.json must be a digested deploy input"
grep -qF '$SCP "$AUTOTUNE_RELEASE_LEDGER"' "$DEPLOY_SH" ||
  fail "release-ledger.json must be uploaded with the deploy inputs"
grep -qF 'AUTOTUNE_RELEASE_LEDGER="$PINNED_AUTOTUNE_DIR/release-ledger.json"' "$DEPLOY_SH" ||
  fail "the ledger must come from the pinned deploy inputs"
skip_block="$(sed -n "${skip_line},/^else\$/p" "$DEPLOY_SH")"
case "$skip_block" in
  *autotune_window*|*current.next*) fail "the equivalent branch must not apply the window or swap current" ;;
esac

# --- Extract the two blocks ------------------------------------------------
awk '/^log "  comparing staged catalog release with live autotune\/current/{f=1} f{print} f&&/^esac$/{exit}' \
  "$DEPLOY_SH" > "$TMP/compare-block.sh"
grep -q 'CATALOG REGRESSION OVERRIDE' "$TMP/compare-block.sh" || fail "could not extract the compare-live block"
awk '/^if \[ "\$CATALOG_VERDICT" = "equivalent" \]; then$/{f=1} f{print} f&&/^fi$/{exit}' \
  "$DEPLOY_SH" > "$TMP/activate-block.sh"
grep -q 'autotune_window.py apply' "$TMP/activate-block.sh" || fail "could not extract the activation block"

# --- Fake Pearl --------------------------------------------------------------
RELEASE_FILES="demand-rank.json demand-rank.json.sig autotune-candidates.json autotune-candidates.json.sig rate-card.json rate-card.json.sig tier2-catalog.json release.json trusted-keys.json"
assemble() {
  mkdir -p "$1"
  for name in $RELEASE_FILES; do
    case "$name" in
      release.json|trusted-keys.json|tier2-catalog.json) cp "$REPO_ROOT/phase3-binary/catalog/autotune/$name" "$1/$name" ;;
      *) cp "$REPO_ROOT/phase3-binary/dist/static/$name" "$1/$name" ;;
    esac
  done
}
restamp() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
d, rid = pathlib.Path(sys.argv[1]), sys.argv[2]
def dump(o): return json.dumps(o, ensure_ascii=False, separators=(",", ":")).encode()
for name in ("autotune-candidates.json", "demand-rank.json", "rate-card.json"):
    o = json.loads((d / name).read_bytes())
    if name != "rate-card.json":
        o["version"] = rid
    o["generated_at"] = "2026-10-01T03:00:00Z"
    (d / name).write_bytes(dump(o))
m = json.loads((d / "release.json").read_bytes())
m["release_id"] = rid
(d / "release.json").write_text(json.dumps(m, indent=2))
PY
}
change_content() {
  python3 - "$1/demand-rank.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
o["compare_live_test_marker"] = True
open(sys.argv[1], "w").write(json.dumps(o))
PY
}

ROOT="$TMP/opt/macprovider"
VAR="$TMP/var/lib/macprovider"
DEPLOY_TMP="$TMP/deploy-tmp"
INCOMING_DIR="published-2026-09-23-tier2-buyer-closure-v1-0123456789abcdef"

fake_ssh() {
  local script
  script="$(python3 - "$1" "$ROOT" "$VAR" <<'PY'
import sys
s, root, var = sys.argv[1:]
s = s.replace("/opt/macprovider", root).replace("/var/lib/macprovider", var)
s = s.replace("install -d -o macprovider -g macprovider -m 0750", "mkdir -p")
s = s.replace("flock -s 8", ":").replace("logger -t", ": logger")
s = s.replace("os.fchown(fd, 0, 0)", "pass")
s = s.replace("mv -Tf", "python3 -c 'import os,sys; os.replace(sys.argv[1], sys.argv[2])'")
print(s, end="")
PY
)"
  bash -c "$script"
}

reset() {
  rm -rf "${TMP:?}/opt" "${TMP:?}/var" "$DEPLOY_TMP" "${TMP:?}/pinned"
  mkdir -p "$ROOT/autotune/releases" "$DEPLOY_TMP/scripts" "$TMP/pinned"
  assemble "$DEPLOY_TMP"
  cp "$REPO_ROOT/phase3-binary/catalog/autotune/release-ledger.json" "$DEPLOY_TMP/release-ledger.json"
  # The same shipped closure deploy uploads (catalog-verifier-bundle.txt).
  for entry in $(grep -v '^#' "$REPO_ROOT/scripts/catalog-verifier-bundle.txt"); do
    cp "$REPO_ROOT/$entry" "$DEPLOY_TMP/$entry"
  done
  cat > "$DEPLOY_TMP/scripts/autotune_window.py" <<PY
import sys
open("$TMP/window-calls", "a").write(" ".join(sys.argv[1:]) + "\\n")
PY
  rm -f "$TMP/window-calls"
  : > "$TMP/window-calls"
}
live_release() {
  assemble "$ROOT/autotune/releases/$1"
  ln -sfn "releases/$1" "$ROOT/autotune/current"
}
stage_incoming() {
  # What the unconditional staging block leaves behind.
  assemble "$ROOT/autotune/releases/$INCOMING_DIR"
  if [ ! -e "$ROOT/autotune/current" ] && [ ! -L "$ROOT/autotune/current" ]; then
    ln -sfn "releases/$INCOMING_DIR" "$ROOT/autotune/current"
  fi
}

# shellcheck disable=SC2034 # consumed by the sourced deploy blocks
run_deploy_slice() {
  # $1 = override b64 (may be empty). Output: $TMP/out, rc returned.
  (
    set -euo pipefail
    log() { echo "$*"; }
    SSH=fake_ssh
    CATALOG_RELEASE_FILES="$RELEASE_FILES"
    AUTOTUNE_RELEASE_ID="published-2026-09-23-tier2-buyer-closure-v1"
    AUTOTUNE_RELEASE_DIR_NAME="$INCOMING_DIR"
    CATALOG_REGRESSION_OVERRIDE_B64="$1"
    COORDINATOR_RELEASE_VERSION="v9.9.9"
    COORDINATOR_RELEASE_COMMIT="0123456789abcdef0123456789abcdef01234567"
    PINNED_DEPLOY_INPUT_DIR="$TMP/pinned"
    # shellcheck disable=SC1091
    . "$TMP/compare-block.sh"
    echo "VERDICT=$CATALOG_VERDICT"
    stage_incoming
    [ -z "${MOVE_CURRENT_TO:-}" ] || ln -sfn "releases/$MOVE_CURRENT_TO" "$ROOT/autotune/current"
    # shellcheck disable=SC1091
    . "$TMP/activate-block.sh"
    echo "SMOKE_RELEASE_ID=$AUTOTUNE_RELEASE_ID"
  ) > "$TMP/out" 2>&1
}

current_target() { readlink "$ROOT/autotune/current"; }

# bootstrap: no live current -> activate as today.
reset
run_deploy_slice "" || { cat "$TMP/out" >&2; fail "bootstrap deploy must activate"; }
grep -q '^VERDICT=bootstrap$' "$TMP/out" || fail "missing live current must be the bootstrap verdict"
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "bootstrap must leave current on the incoming release"

# equivalent: an uncommitted renewal restamp of the same content -> no swap, no window.
reset
live_release renewed-live
restamp "$ROOT/autotune/releases/renewed-live" published-2026-10-01-renewal-v1
run_deploy_slice "" || { cat "$TMP/out" >&2; fail "equivalent deploy must proceed"; }
grep -q '^VERDICT=equivalent$' "$TMP/out" || { cat "$TMP/out" >&2; fail "renewal restamp must be equivalent"; }
grep -qF 'catalog unchanged; runtime-only deploy keeps live release published-2026-10-01-renewal-v1' "$TMP/out" ||
  fail "equivalent must log the kept live release"
[ "$(current_target)" = "releases/renewed-live" ] || fail "equivalent must not swap current"
[ ! -s "$TMP/window-calls" ] || fail "equivalent must not run autotune_window"
[ -d "$ROOT/autotune/releases/$INCOMING_DIR" ] || fail "the incoming release must still be staged immutably"
grep -q '^SMOKE_RELEASE_ID=published-2026-10-01-renewal-v1$' "$TMP/out" ||
  fail "post-restart smokes must be rebound to the live release"
cmp -s "$TMP/pinned/live-catalog/demand-rank.json" "$ROOT/autotune/releases/renewed-live/demand-rank.json" ||
  fail "smoke expectations must be the live release bytes"

# equivalent, but current moved before activation -> abort.
reset
live_release renewed-live
restamp "$ROOT/autotune/releases/renewed-live" published-2026-10-01-renewal-v1
assemble "$ROOT/autotune/releases/other"
if MOVE_CURRENT_TO=other run_deploy_slice ""; then fail "a current moved after compare-live must abort"; fi
grep -q 'moved since compare-live' "$TMP/out" || fail "moved-current abort must say why"

# descends: live is a renewal of the committed release, tag carries new content.
reset
live_release renewed-live
restamp "$ROOT/autotune/releases/renewed-live" published-2026-10-01-renewal-v1
change_content "$DEPLOY_TMP"
run_deploy_slice "" || { cat "$TMP/out" >&2; fail "descends deploy must activate"; }
grep -q '^VERDICT=descends$' "$TMP/out" || fail "live in the ledger must be the descends verdict"
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "descends must swap current to the incoming release"
grep -q '^apply --root' "$TMP/window-calls" || fail "descends must apply the retained window"

# descends but current moved before activation -> abort, no swap.
reset
live_release renewed-live
restamp "$ROOT/autotune/releases/renewed-live" published-2026-10-01-renewal-v1
change_content "$DEPLOY_TMP"
assemble "$ROOT/autotune/releases/other"
if MOVE_CURRENT_TO=other run_deploy_slice ""; then fail "activation over a moved current must abort"; fi
[ "$(current_target)" = "releases/other" ] || fail "moved-current abort must not swap current"

# regression without override -> abort before any live mutation.
reset
live_release newer-live
change_content "$ROOT/autotune/releases/newer-live"
if run_deploy_slice ""; then fail "regression must abort"; fi
grep -q 'catalog regression' "$TMP/out" || fail "regression abort must say why"
grep -q '^VERDICT=' "$TMP/out" && fail "regression must abort before staging/activation"
[ "$(current_target)" = "releases/newer-live" ] || fail "regression must not touch current"
[ ! -e "$VAR/catalog-window-overrides.jsonl" ] || fail "no override log without an override"

# regression with override -> logged, then activated.
reset
live_release newer-live
change_content "$ROOT/autotune/releases/newer-live"
reason="rollback bad catalog; ticket #1688"
run_deploy_slice "$(printf '%s' "$reason" | base64 | tr -d '\n')" || { cat "$TMP/out" >&2; fail "override must proceed"; }
grep -q '^VERDICT=regression$' "$TMP/out" || fail "override must still report the regression verdict"
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "override must activate the incoming release"
log="$VAR/catalog-window-overrides.jsonl"
[ -f "$log" ] || fail "override must append to catalog-window-overrides.jsonl"
[ "$(stat -f %Lp "$log" 2>/dev/null || stat -c %a "$log")" = "600" ] || fail "override log must be 0600"
python3 - "$log" "$reason" "$INCOMING_DIR" <<'PY' || fail "override record is wrong"
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 1, lines
r = json.loads(lines[0])
assert r["reason"] == sys.argv[2] and r["incoming"] == sys.argv[3], r
assert r["live"] == {"target": "releases/newer-live", "release_id": "published-2026-09-23-tier2-buyer-closure-v1"}, r
assert r["tag"] == "v9.9.9" and r["commit"].startswith("0123"), r
assert set(r) == {"ts", "reason", "incoming", "live", "tag", "commit"}, r
PY
# O_APPEND: a second override appends, never truncates.
cp -p "$log" "$TMP/first-override.jsonl"
reset
mkdir -p "$VAR"
cp -p "$TMP/first-override.jsonl" "$log"
live_release newer-live
change_content "$ROOT/autotune/releases/newer-live"
run_deploy_slice "$(printf '%s' "$reason" | base64 | tr -d '\n')" || { cat "$TMP/out" >&2; fail "second override must proceed"; }
[ "$(wc -l < "$log" | tr -d ' ')" = "2" ] || fail "override log must be append-only"

# Override reason validation (runs before any SSH).
validate_block="$(awk '/^CATALOG_REGRESSION_OVERRIDE_REASON="\$\{CATALOG_REGRESSION_OVERRIDE_REASON:-\}"$/{f=1} f{print} f&&/^fi$/{exit}' "$DEPLOY_SH")"
[ -n "$validate_block" ] || fail "could not extract override validation"
# shellcheck disable=SC2034 # consumed by the eval'd validation block
check_reason() {
  ( CATALOG_REGRESSION_OVERRIDE_REASON="$1"; eval "$validate_block"; printf '%s' "$CATALOG_REGRESSION_OVERRIDE_B64" ) 2>/dev/null
}
[ "$(check_reason 'ok reason' | base64 -d 2>/dev/null || check_reason 'ok reason' | base64 -D)" = "ok reason" ] ||
  fail "a printable reason must round-trip through base64"
check_reason "$(printf 'two\nlines')" >/dev/null && fail "multi-line reason must be rejected"
check_reason "$(printf 'tab\there')" >/dev/null && fail "control characters must be rejected"
check_reason "$(printf '%0201d' 0)" >/dev/null && fail "a reason over 200 characters must be rejected"
check_reason "\$(touch $TMP/pwned)'\"" >/dev/null || fail "shell metacharacters are printable and must be accepted as data"
[ ! -e "$TMP/pwned" ] || fail "override reason must never be evaluated"

echo "PASS: deploy_catalog_compare_live"
