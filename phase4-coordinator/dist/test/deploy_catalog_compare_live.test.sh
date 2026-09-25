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
live_verify_line="$(line_of 'verify-directory --directory /opt/macprovider/autotune/\$_live')"
[ "$live_verify_line" -lt "$compare_line" ] || fail "the live release must pass verify-directory before compare-live"
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
grep -qF '"$AUTOTUNE_TIER2_CONTENT_INDEX=tier2-content-index.json"' "$DEPLOY_SH" ||
  fail "tier2-content-index.json must be a digested deploy input"
grep -qF '$SCP "$AUTOTUNE_TIER2_CONTENT_INDEX"' "$DEPLOY_SH" ||
  fail "tier2-content-index.json must be uploaded with the deploy inputs"
grep -qF 'tier2-content-index --repo "$REPO_ROOT" \' "$DEPLOY_SH" && grep -qF -- '--rev "$COORDINATOR_RELEASE_COMMIT" --ledger "$AUTOTUNE_RELEASE_LEDGER"' "$DEPLOY_SH" ||
  fail "the Tier-2 content index must be built from the pinned commit's history"
grep -qF -- '--ledger $DEPLOY_TMP/release-ledger.json --tier2-content-index $DEPLOY_TMP/tier2-content-index.json' "$DEPLOY_SH" ||
  fail "compare-live must receive the Tier-2 content index"
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
# #1688: the append primitive itself now lives in the shared
# scripts/lib/catalog-window-override.sh (also used by the catalog-content
# lane); deploy's local wrapper just delegates to it.
CWO_LIB="$REPO_ROOT/scripts/lib/catalog-window-override.sh"
[ -f "$CWO_LIB" ] || fail "missing shared catalog-window-override lib"
grep -q 'catalog-window-overrides.jsonl' "$CWO_LIB" || fail "shared lib lost the override append"
awk '/^_append_catalog_window_override\(\) \{$/{f=1} f{print} f&&/^}$/{exit}' \
  "$DEPLOY_SH" > "$TMP/append-helper.sh"
grep -q 'cwo_override_remote_command' "$TMP/append-helper.sh" || fail "could not extract the override append helper"

# --- Fake Pearl --------------------------------------------------------------
BASE_FILES="demand-rank.json demand-rank.json.sig autotune-candidates.json autotune-candidates.json.sig rate-card.json rate-card.json.sig tier2-catalog.json release.json trusted-keys.json"
BOUND_FILES="$BASE_FILES autotune-artifacts.json autotune-artifacts.json.sig"
COMMITTED_ID="published-2026-09-23-tier2-buyer-closure-v1"
BOUND_ID="published-2026-09-30-artifact-bound-v1"
# BOUND=1 switches every fixture to the artifact-bound (eleven-file) release.
BOUND=0
RELEASE_FILES="$BASE_FILES"
INCOMING_ID="$COMMITTED_ID"
CR_PY="$REPO_ROOT/scripts/catalog-release.py"
assemble() {
  mkdir -p "$1"
  for name in $BASE_FILES; do
    case "$name" in
      release.json|trusted-keys.json|tier2-catalog.json) cp "$REPO_ROOT/phase3-binary/catalog/autotune/$name" "$1/$name" ;;
      *) cp "$REPO_ROOT/phase3-binary/dist/static/$name" "$1/$name" ;;
    esac
  done
  [ "$BOUND" = 0 ] || bind_release "$1"
}
# The committed release re-cut as artifact-bound release $BOUND_ID: an (empty)
# artifact feed plus its release.json binding. Unsigned, so the harness stubs
# verify-directory except in the real-verify cases below.
bind_release() {
  python3 - "$CR_PY" "$1" "$BOUND_ID" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("cr", sys.argv[1]); cr = importlib.util.module_from_spec(spec); spec.loader.exec_module(cr)
d, rid, gen = pathlib.Path(sys.argv[2]), sys.argv[3], "2026-09-30T00:00:00Z"
for name in ("autotune-candidates.json", "demand-rank.json", "rate-card.json"):
    o = json.loads((d / name).read_bytes())
    if name != "rate-card.json":
        o["version"] = rid
    o["generated_at"] = gen
    (d / name).write_bytes(cr.canonical_bytes(o))
candidate = (d / "autotune-candidates.json").read_bytes()
artifact = {"models": [], "version": rid, "release_id": rid, "generated_at": gen,
            "candidate_catalog_sha256": cr.sha256(candidate), "policy_version": "autotune-policy-v1", "source": "deploy-test"}
(d / "autotune-artifacts.json").write_bytes(cr.canonical_sorted_bytes(artifact))
(d / "autotune-artifacts.json.sig").write_bytes((d / "autotune-candidates.json.sig").read_bytes())
m = json.loads((d / "release.json").read_bytes())
m["release_id"], m["generated_at"] = rid, gen
for name in ("autotune-candidates.json", "demand-rank.json", "rate-card.json", "autotune-artifacts.json"):
    raw = (d / name).read_bytes()
    entry = m["feeds"].setdefault(name, dict(m["feeds"]["autotune-candidates.json"]))
    entry.update(sha256=cr.sha256(raw), bytes=len(raw))
    if name != "rate-card.json":
        entry["version"] = rid
(d / "release.json").write_text(json.dumps(m, indent=2))
PY
}
# The committed ledger plus a v3 artifact-bound row for $BOUND_ID, taken from an
# assembled bound release (what the tag that cut it would carry).
bound_ledger() {
  python3 - "$1" "$2" "$BOUND_ID" <<'PY'
import json, pathlib, sys
d, out, rid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
ledger = json.loads(out.read_bytes())
ledger["schema_version"] = "macprovider.autotune-release-ledger.v3"
m = json.loads((d / "release.json").read_bytes())
ledger["releases"][rid] = {
    "generated_at": m["generated_at"], "policy_version": m["policy_version"],
    "feeds": {name: {k: e[k] for k in ("bytes", "sha256", "signer_key_id", "version")} for name, e in m["feeds"].items()},
    "artifact_bindings": [], "intake_decision_sha256": None,
}
out.write_text(json.dumps(ledger, indent=2))
PY
}
# What renew-autotune-static-feed.sh leaves on Pearl: same content, new
# identity (the artifact feed's release fields included).
restamp() {
  python3 - "$CR_PY" "$1" "$2" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("cr", sys.argv[1]); cr = importlib.util.module_from_spec(spec); spec.loader.exec_module(cr)
d, rid = pathlib.Path(sys.argv[2]), sys.argv[3]
for name in ("autotune-candidates.json", "demand-rank.json", "rate-card.json"):
    o = json.loads((d / name).read_bytes())
    if name != "rate-card.json":
        o["version"] = rid
    o["generated_at"] = "2026-10-01T03:00:00Z"
    (d / name).write_bytes(cr.canonical_bytes(o))
if (d / "autotune-artifacts.json").exists():
    o = json.loads((d / "autotune-artifacts.json").read_bytes())
    o.update(version=rid, release_id=rid, generated_at="2026-10-01T03:00:00Z",
             candidate_catalog_sha256=cr.sha256((d / "autotune-candidates.json").read_bytes()))
    (d / "autotune-artifacts.json").write_bytes(cr.canonical_sorted_bytes(o))
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
s = s.replace("/etc/macprovider", root + "/../../etc/macprovider")
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
  rm -rf "${TMP:?}/opt" "${TMP:?}/var" "${TMP:?}/etc" "$DEPLOY_TMP" "${TMP:?}/pinned"
  mkdir -p "$ROOT/autotune/releases" "$DEPLOY_TMP/scripts" "$TMP/pinned" "$TMP/etc/macprovider"
  assemble "$DEPLOY_TMP"
  cp "$REPO_ROOT/phase3-binary/catalog/autotune/release-ledger.json" "$DEPLOY_TMP/release-ledger.json"
  if [ "$BOUND" = 1 ]; then
    rm -rf "$TMP/bound-base"
    assemble "$TMP/bound-base"
    bound_ledger "$TMP/bound-base" "$DEPLOY_TMP/release-ledger.json"
  fi
  # As deploy builds it locally from the pinned commit's history.
  python3 -I "$REPO_ROOT/scripts/catalog-release.py" tier2-content-index --repo "$REPO_ROOT" --rev HEAD \
    --ledger "$DEPLOY_TMP/release-ledger.json" > "$DEPLOY_TMP/tier2-content-index.json" || fail "cannot build the Tier-2 content index"
  # The same shipped closure deploy uploads (catalog-verifier-bundle.txt).
  for entry in $(grep -v '^#' "$REPO_ROOT/scripts/catalog-verifier-bundle.txt"); do
    cp "$REPO_ROOT/$entry" "$DEPLOY_TMP/$entry"
  done
  # Same trust root deploy uploads as tier2-catalog.pub.
  awk '/^tier2:/{on=1; next} on&&/^[^[:space:]#]/{on=0} on&&$1=="catalog_public_key:"{print $2}' \
    "$REPO_ROOT/phase4-coordinator/dist/coordinator.yaml" > "$DEPLOY_TMP/tier2-catalog.pub"
  [ -s "$DEPLOY_TMP/tier2-catalog.pub" ] || fail "could not derive tier2.catalog_public_key from coordinator.yaml"
  # The LIVE coordinator's configured Tier-2 key (what the live side is judged by).
  printf 'tier2:\n  catalog_public_key: %s\n' "$(cat "$DEPLOY_TMP/tier2-catalog.pub")" > "$ROOT/coordinator.yaml"
  # Record every verify-directory. VERIFY_MODE=stub accepts the re-stamped
  # (hence unsigned) fixtures; VERIFY_MODE=real runs the shipped verifier.
  mv "$DEPLOY_TMP/scripts/catalog-release.py" "$DEPLOY_TMP/scripts/catalog-release-real.py"
  cat > "$DEPLOY_TMP/scripts/catalog-release.py" <<PY
import os, runpy, sys
real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog-release-real.py")
if sys.argv[1:2] == ["verify-directory"]:
    with open("$TMP/verify-calls", "a") as calls:
        calls.write(" ".join(sys.argv[1:]) + "\n")
    if "${VERIFY_MODE:-stub}" == "stub":
        raise SystemExit(0)
sys.argv[0] = real
runpy.run_path(real, run_name="__main__")
PY
  : > "$TMP/verify-calls"
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
  mkdir -p "$ROOT/autotune/releases/$INCOMING_DIR"
  for name in $RELEASE_FILES; do cp "$DEPLOY_TMP/$name" "$ROOT/autotune/releases/$INCOMING_DIR/$name"; done
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
    AUTOTUNE_RELEASE_ID="$INCOMING_ID"
    AUTOTUNE_RELEASE_DIR_NAME="$INCOMING_DIR"
    CATALOG_REGRESSION_OVERRIDE_B64="$1"
    COORDINATOR_RELEASE_VERSION="v9.9.9"
    COORDINATOR_RELEASE_COMMIT="0123456789abcdef0123456789abcdef01234567"
    PINNED_DEPLOY_INPUT_DIR="$TMP/pinned"
    # shellcheck disable=SC1091
    . "$CWO_LIB"
    # shellcheck disable=SC1091
    . "$TMP/append-helper.sh"
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
[ "$(stat -c %a "$log" 2>/dev/null || stat -f %Lp "$log")" = "600" ] || fail "override log must be 0600"
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

# #1693 E2: after a pricing correction (floor marker present) the override must
# not roll prices back. A live release whose rate rows differ from the tag's
# (a pricing correction the tag predates) refuses; the remedy is a tag at or
# after the live release's commit. Rows equal (only other content differs) or
# no floor: the override still works.
price_move() { # rewrite one rate row, re-stamp generated_at like a pricing release
  python3 - "$1/rate-card.json" <<'PY2'
import json, sys
o = json.load(open(sys.argv[1]))
o["rows"]["default"]["prompt_rate_per_mtok"] += 1
o["generated_at"] = "2026-10-02T00:00:00Z"
open(sys.argv[1], "w").write(json.dumps(o))
PY2
}
reset
live_release priced-live
price_move "$ROOT/autotune/releases/priced-live"
printf 'commit=%s\nwritten_at=2026-10-02T00:00:00Z\n' "$(printf 'c%.0s' $(seq 40))" >"$ROOT/.pricing-runtime-floor"
if run_deploy_slice "$(printf '%s' "$reason" | base64 | tr -d '\n')"; then fail "the override must refuse to move prices after the pricing runtime floor"; fi
grep -q "refusing CATALOG_REGRESSION_OVERRIDE_REASON: the pricing runtime floor exists" "$TMP/out" || { cat "$TMP/out" >&2; fail "the price-moving override refusal must say why"; }
grep -q 'tag at or after the live release' "$TMP/out" || fail "the refusal must name the remedy"
[ "$(current_target)" = "releases/priced-live" ] || fail "a refused override must not touch current"
[ ! -e "$VAR/catalog-window-overrides.jsonl" ] || fail "a refused override must not be logged as used"
# Same floor, rows equal (a content-only regression): the override proceeds.
reset
live_release newer-live
change_content "$ROOT/autotune/releases/newer-live"
touch "$ROOT/.pricing-runtime-floor"
run_deploy_slice "$(printf '%s' "$reason" | base64 | tr -d '\n')" || { cat "$TMP/out" >&2; fail "a content-only override after the floor must proceed"; }
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "a content-only override after the floor must activate"
# No floor: price rows may differ (pre-#1693 override semantics).
reset
live_release priced-live
price_move "$ROOT/autotune/releases/priced-live"
run_deploy_slice "$(printf '%s' "$reason" | base64 | tr -d '\n')" || { cat "$TMP/out" >&2; fail "without the floor the override must proceed"; }
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "without the floor the override must activate"

# --- The live release passes verify-directory before it is classified --------
reset
live_release renewed-live
restamp "$ROOT/autotune/releases/renewed-live" published-2026-10-01-renewal-v1
run_deploy_slice "" || { cat "$TMP/out" >&2; fail "stubbed live verify must proceed"; }
grep -qF "verify-directory --directory $ROOT/autotune/releases/renewed-live --tier2-coordinator-config $ROOT/coordinator.yaml --allow-expired-tier2" \
  "$TMP/verify-calls" || fail "the live release must be verified with the LIVE coordinator's Tier-2 key, tolerating expiry"
grep -F -- "--directory $ROOT/autotune/releases/renewed-live" "$TMP/verify-calls" | grep -qF tier2-public-key-file &&
  fail "the live release must not be judged by the incoming Tier-2 trust root"
reset
live_release renewed-live
restamp "$ROOT/autotune/releases/renewed-live" published-2026-10-01-renewal-v1
printf 'tier2:\n  catalog_public_key: overlay\n' > "$TMP/etc/macprovider/coordinator.pearl-overlays.yaml"
run_deploy_slice "" || { cat "$TMP/out" >&2; fail "stubbed live verify with an overlay must proceed"; }
grep -qF -- "--tier2-coordinator-config $ROOT/coordinator.yaml --tier2-coordinator-overlay $ROOT/../../etc/macprovider/coordinator.pearl-overlays.yaml --allow-expired-tier2" \
  "$TMP/verify-calls" || fail "the live verify must pass the coordinator overlay when Pearl has one"

# Real verifier: pristine committed live verifies (control), a corrupt live
# sidecar or keyring aborts before any staging, swap, window, or override.
VERIFY_MODE=real
reset
live_release committed-live
if run_deploy_slice ""; then
  grep -q '^VERDICT=equivalent$' "$TMP/out" || { cat "$TMP/out" >&2; fail "pristine committed live must verify and be equivalent"; }
  corrupt_sidecar() {
    python3 - "$ROOT/autotune/releases/committed-live" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
other = json.loads((d / "autotune-candidates.json.sig").read_bytes())["signature"]
sig = json.loads((d / "demand-rank.json.sig").read_bytes())
sig["signature"] = other
(d / "demand-rank.json.sig").write_text(json.dumps(sig, separators=(",", ":")))
PY
  }
  corrupt_keyring() {
    python3 - "$ROOT/autotune/releases/committed-live/trusted-keys.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
k = json.loads(p.read_bytes())
keys = k["keys"]
v4, v5 = "streamvc-autotune-static-v4", "streamvc-autotune-static-v5"
keys[v4]["public_key_base64"] = keys[v5]["public_key_base64"]
p.write_text(json.dumps(k, indent=2))
PY
  }
  # Re-sign the live Tier-2 with a fresh key the LIVE coordinator is configured
  # with (the incoming trust root stays the committed key): a key rotation.
  # $1 = seconds until the live Tier-2 expires.
  resign_live_tier2() {
    local d="$ROOT/autotune/releases/committed-live"
    [ -s "$TMP/t2.pub" ] || go run "$REPO_ROOT/scripts/sign-catalog.go" keygen -public-out "$TMP/t2.pub" -private-out "$TMP/t2.priv" >/dev/null 2>&1 ||
      fail "cannot generate a Tier-2 test key"
    python3 - "$d/tier2-catalog.json" "$TMP/t2-unsigned.json" "$1" <<'PY'
import datetime, json, sys
o = json.load(open(sys.argv[1]))
o.pop("signature", None)
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
o["issued_at"] = (now - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
o["expires_at"] = (now + datetime.timedelta(seconds=int(sys.argv[3]))).strftime("%Y-%m-%dT%H:%M:%SZ")
open(sys.argv[2], "w").write(json.dumps(o, indent=2))
PY
    go run "$REPO_ROOT/scripts/sign-catalog.go" sign -key "$TMP/t2.priv" -key-id rotated-test -out "$d/tier2-catalog.json" "$TMP/t2-unsigned.json" >/dev/null 2>&1 ||
      fail "cannot sign the live Tier-2 test catalog"
    python3 - "$CR_PY" "$d" "$(cat "$TMP/t2.pub")" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("cr", sys.argv[1]); cr = importlib.util.module_from_spec(spec); spec.loader.exec_module(cr)
d, pub = pathlib.Path(sys.argv[2]), sys.argv[3].strip()
raw = (d / "tier2-catalog.json").read_bytes()
m = json.loads((d / "release.json").read_bytes())
m["feeds"]["tier2-catalog.json"].update(sha256=cr.sha256(raw), bytes=len(raw), signer_key_id=cr.tier2_trusted_key_fingerprint(pub))
# The exact serialization manifest() emits, so release.json still binds the feeds.
(d / "release.json").write_bytes(json.dumps(m, indent=2, sort_keys=True).encode("utf-8") + b"\n")
PY
    printf 'tier2:\n  catalog_public_key: %s\n' "$(cat "$TMP/t2.pub")" > "$ROOT/coordinator.yaml"
  }
  # Rotated live key: the live Tier-2 verifies against the LIVE coordinator's
  # key although the incoming trust root differs; the deploy reaches classification.
  reset
  live_release committed-live
  resign_live_tier2 3600
  run_deploy_slice "" || true
  grep -q 'LIVE catalog release autotune/current failed verify-directory' "$TMP/out" &&
    { cat "$TMP/out" >&2; fail "a live Tier-2 signed by the rotated live key must pass the live verify"; }
  grep -qE '^VERDICT=|catalog regression' "$TMP/out" || { cat "$TMP/out" >&2; fail "rotated live Tier-2 key: deploy must reach classification"; }
  # Expired live Tier-2: still signature-verified, not refused for expiry.
  reset
  live_release committed-live
  resign_live_tier2 2
  sleep 3
  run_deploy_slice "" || true
  grep -q 'LIVE catalog release autotune/current failed verify-directory' "$TMP/out" &&
    { cat "$TMP/out" >&2; fail "an EXPIRED live Tier-2 must not abort the live verify"; }
  grep -qE '^VERDICT=|catalog regression' "$TMP/out" || { cat "$TMP/out" >&2; fail "expired live Tier-2: deploy must reach classification"; }
  corrupt_tier2_sig() {
    python3 - "$ROOT/autotune/releases/committed-live/tier2-catalog.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
sig = o["signature"]["sig"]
o["signature"]["sig"] = ("B" if sig[0] != "B" else "C") + sig[1:]
open(sys.argv[1], "w").write(json.dumps(o, indent=2) + "\n")
PY
  }
  for corrupt in corrupt_sidecar corrupt_keyring corrupt_tier2_sig; do
    reset
    live_release committed-live
    "$corrupt"
    if run_deploy_slice ""; then fail "$corrupt: a live release failing verify-directory must abort"; fi
    grep -q 'LIVE catalog release autotune/current failed verify-directory' "$TMP/out" ||
      { cat "$TMP/out" >&2; fail "$corrupt: live verify abort must say why"; }
    grep -q '^VERDICT=' "$TMP/out" && fail "$corrupt: live verify failure must abort before staging/activation"
    grep -q 'compare-live:' "$TMP/out" && fail "$corrupt: live verify failure must abort before classification"
    [ "$(current_target)" = "releases/committed-live" ] || fail "$corrupt: must not touch current"
    [ ! -d "$ROOT/autotune/releases/$INCOMING_DIR" ] || fail "$corrupt: must not stage the incoming release"
    [ ! -s "$TMP/window-calls" ] || fail "$corrupt: must not run autotune_window"
    [ ! -e "$VAR/catalog-window-overrides.jsonl" ] || fail "$corrupt: must not log an override"
  done
elif grep -q 'a Go toolchain is required' "$TMP/out"; then
  echo "SKIP: no trusted Go toolchain; real live verify-directory cases NOT exercised" >&2
else
  cat "$TMP/out" >&2
  fail "pristine committed live release failed the real verify-directory"
fi
VERIFY_MODE=stub

# --- Artifact-bound (eleven-file) release set --------------------------------
BOUND=1
RELEASE_FILES="$BOUND_FILES"
INCOMING_ID="$BOUND_ID"
[ "$(echo $RELEASE_FILES | wc -w | tr -d ' ')" = 11 ] || fail "artifact-bound set must be eleven files"
bound_block="$(sed -n '/^CATALOG_RELEASE_FILES="demand-rank.json/,/^fi$/p' "$DEPLOY_SH")"
# shellcheck disable=SC2034 # consumed by the eval'd deploy block
bound_deploy_files="$(AUTOTUNE_ARTIFACT_BOUND=bound; eval "$bound_block"; echo "$CATALOG_RELEASE_FILES")"
[ "$bound_deploy_files" = "$BOUND_FILES" ] || fail "harness bound file set drifted from deploy's CATALOG_RELEASE_FILES"

# bound equivalent: live is a renewal restamp of the bound release; the smoke
# expectations rebind to a snapshot of all eleven live files.
reset
live_release renewed-live
restamp "$ROOT/autotune/releases/renewed-live" published-2026-10-01-renewal-v1
run_deploy_slice "" || { cat "$TMP/out" >&2; fail "bound equivalent deploy must proceed"; }
grep -q '^VERDICT=equivalent$' "$TMP/out" || { cat "$TMP/out" >&2; fail "bound renewal restamp must be equivalent"; }
[ "$(current_target)" = "releases/renewed-live" ] || fail "bound equivalent must not swap current"
[ ! -s "$TMP/window-calls" ] || fail "bound equivalent must not run autotune_window"
grep -q '^SMOKE_RELEASE_ID=published-2026-10-01-renewal-v1$' "$TMP/out" || fail "bound smokes must rebind to the live release"
for name in $BOUND_FILES; do
  cmp -s "$TMP/pinned/live-catalog/$name" "$ROOT/autotune/releases/renewed-live/$name" ||
    fail "bound live snapshot must carry live $name"
done

# bound descends: live is a renewal of the bound ledger row, tag has new content.
reset
live_release renewed-live
restamp "$ROOT/autotune/releases/renewed-live" published-2026-10-01-renewal-v1
change_content "$DEPLOY_TMP"
run_deploy_slice "" || { cat "$TMP/out" >&2; fail "bound descends deploy must activate"; }
grep -q '^VERDICT=descends$' "$TMP/out" || { cat "$TMP/out" >&2; fail "bound live in the ledger must descend"; }
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "bound descends must swap current"
grep -q '^apply --root' "$TMP/window-calls" || fail "bound descends must apply the retained window"
for name in $BOUND_FILES; do
  [ -f "$ROOT/autotune/releases/$INCOMING_DIR/$name" ] || fail "bound activation lacks $name"
done

# artifact-feed activation: the first bound tag over the unbound committed live
# release (its ledger row) is never equivalent, and descends.
reset
BOUND=0 live_release unbound-live
run_deploy_slice "" || { cat "$TMP/out" >&2; fail "bound activation over the unbound ledger release must proceed"; }
grep -q '^VERDICT=descends$' "$TMP/out" || { cat "$TMP/out" >&2; fail "bound activation must descend"; }
grep -q 'artifact-bound vs unbound' "$TMP/out" || fail "bound/unbound feed-set change must be reported"
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "bound activation must swap current"
grep -q '^apply --root' "$TMP/window-calls" || fail "bound activation must apply the retained window"
for name in $BOUND_FILES; do
  [ -f "$ROOT/autotune/releases/$INCOMING_DIR/$name" ] || fail "bound activation lacks $name"
done

# bound regression: live content outside the ledger aborts; the override activates.
reset
live_release newer-live
change_content "$ROOT/autotune/releases/newer-live"
if run_deploy_slice ""; then fail "bound regression must abort"; fi
grep -q 'catalog regression' "$TMP/out" || fail "bound regression abort must say why"
[ "$(current_target)" = "releases/newer-live" ] || fail "bound regression must not touch current"
reset
live_release newer-live
change_content "$ROOT/autotune/releases/newer-live"
run_deploy_slice "$(printf '%s' "$reason" | base64 | tr -d '\n')" || { cat "$TMP/out" >&2; fail "bound override must proceed"; }
grep -q '^VERDICT=regression$' "$TMP/out" || fail "bound override must report the regression verdict"
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "bound override must activate the incoming release"
python3 - "$VAR/catalog-window-overrides.jsonl" "$BOUND_ID" <<'PY' || fail "bound override record is wrong"
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert r["live"] == {"target": "releases/newer-live", "release_id": sys.argv[2]}, r
PY
BOUND=0
RELEASE_FILES="$BASE_FILES"
INCOMING_ID="$COMMITTED_ID"

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
