#!/usr/bin/env bash
# #1688 A3: an activation must not drop a catalog release that connected
# providers still advertise. Pins the coverage check's placement in
# deploy-pearl-vps.sh and runs the extracted coverage + activation blocks with
# the real scripts/autotune_window.py against a local fake Pearl and /poolz.
# The admissible set comes from the incoming coordinator's
# --validate-autotune-release verdict (a fake binary here: it reports the
# release and the planned window it was handed; the real verdict is pinned by
# the Go validator tests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
# realpath: autotune_window.py walks the root from / without following symlinks.
TMP="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/deploy-window-coverage-test.XXXXXXXX")"
TMP="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$TMP")"
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
late_guard_line="$(line_of 'step 6c/9: pre-restart safeguard')"
coverage_line="$(line_of 'autotune_window.py coverage --admitted-json')"
validator_line="$(line_of '--validate-autotune-release /opt/macprovider/autotune/releases/$AUTOTUNE_RELEASE_DIR_NAME')"
[ "$validator_line" -lt "$coverage_line" ] || fail "the incoming coordinator must validate before coverage"
grep -qF 'install -m 0755 $DEPLOY_TMP/coordinator-linux-amd64' "$DEPLOY_SH" || fail "coverage must run the INCOMING coordinator binary"
grep -qF 'systemd-run --quiet --wait --pipe --collect -p RuntimeMaxSec=300 -p EnvironmentFile=-/etc/macprovider/coordinator.env -p User=macprovider -p Group=macprovider' "$DEPLOY_SH" ||
  fail "the validator must run under the coordinator env and user"
grep -q 'autotune_window.py coverage --root' "$DEPLOY_SH" && fail "deploy must not use the Python admission mirror (coverage --root)"
skip_line="$(line_of 'if [ "$CATALOG_VERDICT" = "equivalent" ]; then')"
window_line="$(line_of 'autotune_window.py apply --root')"
swap_line="$(line_of 'mv -Tf \"\$_catalog_root/current.next\"')"
restart_line="$(line_of 'systemctl restart macprovider-coordinator')"
[ "$compare_line" -lt "$coverage_line" ] || fail "coverage must run after compare-live"
[ "$late_guard_line" -lt "$coverage_line" ] || fail "coverage must read /poolz after the late connected-provider guard"
for later in "$skip_line" "$window_line" "$swap_line" "$restart_line"; do
  [ "$coverage_line" -lt "$later" ] || fail "coverage must run before the window apply, the current swap and the restart"
done
skip_block="$(sed -n "${skip_line},/^else\$/p" "$DEPLOY_SH")"
case "$skip_block" in
  *'autotune_window.py coverage'*|*poolz*) fail "the equivalent branch must not run coverage" ;;
esac
grep -qF 'printf '"'"'header = "Authorization: Bearer %s"\n'"'"' "$CATALOG_CANARY_AUTH_TOKEN" | $SSH' "$DEPLOY_SH" ||
  fail "the operator key must reach Pearl only on SSH stdin"

# --- Extract the blocks ----------------------------------------------------
# #1688: the append primitive itself now lives in the shared
# scripts/lib/catalog-window-override.sh (also used by the catalog-content
# lane); deploy's local wrapper just delegates to it.
CWO_LIB="$REPO_ROOT/scripts/lib/catalog-window-override.sh"
[ -f "$CWO_LIB" ] || fail "missing shared catalog-window-override lib"
grep -q 'catalog-window-overrides.jsonl' "$CWO_LIB" || fail "shared lib lost the override append"
awk '/^_append_catalog_window_override\(\) \{$/{f=1} f{print} f&&/^}$/{exit}' "$DEPLOY_SH" > "$TMP/append-helper.sh"
grep -q 'cwo_override_remote_command' "$TMP/append-helper.sh" || fail "could not extract the override append helper"
awk '/^# #1688 A3: before an activation changes current/{f=1} f{print} f&&/^esac$/{exit}' "$DEPLOY_SH" > "$TMP/coverage-block.sh"
grep -q 'autotune_window.py coverage' "$TMP/coverage-block.sh" || fail "could not extract the coverage block"
awk '/^if \[ "\$CATALOG_VERDICT" = "equivalent" \]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$DEPLOY_SH" > "$TMP/activate-block.sh"
grep -q 'autotune_window.py apply' "$TMP/activate-block.sh" || fail "could not extract the activation block"
validate_block="$(awk '/^CATALOG_WINDOW_OVERRIDE_REASON="\$\{CATALOG_WINDOW_OVERRIDE_REASON:-\}"$/{f=1} f{print} f&&/^fi$/{exit}' "$DEPLOY_SH")"
[ -n "$validate_block" ] || fail "could not extract the window override validation"

# --- Fake Pearl + /poolz -----------------------------------------------------
ROOT="$TMP/opt/macprovider"
VAR="$TMP/var/lib/macprovider"
DEPLOY_TMP="$TMP/deploy-tmp"
INCOMING_DIR="published-2026-09-23-tier2-buyer-closure-v1-0123456789abcdef"
TOKEN="test-operator-key-0123456789abcdefghijklmnop"
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<SH
#!/usr/bin/env bash
# Fake Pearl-loopback curl: requires the bearer on stdin (--config -).
set -euo pipefail
echo "\$*" >> "$TMP/curl-calls"
config="\$(cat)"
[ "\$config" = 'header = "Authorization: Bearer $TOKEN"' ] || { echo "fake curl: bad stdin config" >&2; exit 2; }
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    http://127.0.0.1:8444/poolz) ;;
  esac
  shift
done
case "\${FAKE_POOLZ:-ok}" in
  ok) cp "$TMP/poolz.json" "\$out"; printf 200 ;;
  unauthorized) printf '{"error":"unauthorized"}' > "\$out"; printf 401 ;;
  down) echo "curl: (7) Failed to connect" >&2; exit 7 ;;
esac
SH
chmod 0755 "$TMP/bin/curl"

# Fake systemd-run: drop the unit options, run the command as-is.
cat > "$TMP/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -p) shift 2 ;;
    --*) shift ;;
    *) break ;;
  esac
done
exec "$@"
SH
chmod 0755 "$TMP/bin/systemd-run"

fake_ssh() {
  local script
  printf '%s\n' "$1" >> "$TMP/ssh-log"
  script="$(python3 - "$1" "$ROOT" "$VAR" "$UID_NOW" "$GID_NOW" <<'PY'
import sys
s, root, var, uid, gid = sys.argv[1:]
s = s.replace("/opt/macprovider", root).replace("/var/lib/macprovider", var)
s = s.replace("install -d -o macprovider -g macprovider -m 0750", "mkdir -p")
s = s.replace("flock -s 8", ":").replace("logger -t", ": logger")
s = s.replace("os.fchown(fd, 0, 0)", "pass")
s = s.replace("mv -Tf", "python3 -c 'import os,sys; os.replace(sys.argv[1], sys.argv[2])'")
s = s.replace("chown -R root:macprovider", ": chown")
for cmd in ("coverage", "plan", "apply"):
    s = s.replace(f"autotune_window.py {cmd} ", f"autotune_window.py {cmd} --required-uid {uid} --group {gid} ")
print(s, end="")
PY
)"
  PATH="$TMP/bin:$PATH" bash -c "$script"
}

# Coverage admits a release only when its candidate sidecar verifies against
# the release's own trusted-keys.json, so every fixture is really signed with
# one OpenSSL Ed25519 key (as scripts/tests/test_autotune_window.py does).
openssl genpkey -algorithm ed25519 -out "$TMP/k1.pem" 2>/dev/null || fail "openssl cannot generate an Ed25519 key"
K1_PUB_B64="$(openssl pkey -in "$TMP/k1.pem" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n')"
[ -n "$K1_PUB_B64" ] || fail "could not derive the Ed25519 public key"

# release <dir> <candidate version>: distinct, signed candidate bytes per dir.
release() {
  local d="$ROOT/autotune/releases/$1" sig
  mkdir -p "$d"
  printf '{"version":"%s","source":"x","rows":{"r":{"dir":"%s"}}}' "$2" "$1" > "$d/autotune-candidates.json"
  sig="$(openssl pkeyutl -sign -rawin -inkey "$TMP/k1.pem" -in "$d/autotune-candidates.json" | base64 | tr -d '\n')"
  printf '{"key_id":"k1","alg":"ed25519","signature":"%s"}' "$sig" > "$d/autotune-candidates.json.sig"
  printf '{"schema_version":"macprovider.autotune-keys.v1","keys":{"k1":{"public_key_base64":"%s","status":"active"}}}' \
    "$K1_PUB_B64" > "$d/trusted-keys.json"
}
sha_of() { shasum -a 256 "$ROOT/autotune/releases/$1/autotune-candidates.json" | cut -d' ' -f1; }
provider() { printf '{"provider_id":"p%s","catalog_release_id":"%s","catalog_candidate_sha256":"%s","routing_eligible":%s}' "$RANDOM" "$1" "$(sha_of "$2")" "${3:-true}"; }
pool() {
  local IFS=,
  printf '{"pool":[%s],"summary":{}}' "$*" > "$TMP/poolz.json"
}

reset() {
  rm -rf "${TMP:?}/opt" "${TMP:?}/var" "$DEPLOY_TMP"
  rm -f "$TMP/curl-calls" "$TMP/ssh-log" "$TMP/poolz.json" "$TMP/validator-calls" "$TMP/validator-window"
  mkdir -p "$ROOT/autotune/releases" "$DEPLOY_TMP/scripts"
  # The shipped verifier bundle, as $DEPLOY_TMP/scripts/ holds it on Pearl:
  # autotune_window.py loads catalog-release.py's signature checks beside it.
  for entry in $(grep -v '^#' "$REPO_ROOT/scripts/catalog-verifier-bundle.txt"); do
    cp "$REPO_ROOT/$entry" "$DEPLOY_TMP/$entry"
  done
  [ -f "$DEPLOY_TMP/scripts/autotune_window.py" ] && [ -f "$DEPLOY_TMP/scripts/catalog-release.py" ] &&
    [ -f "$DEPLOY_TMP/scripts/openrouter_pricing_engine.py" ] || fail "verifier bundle lacks the coverage closure"
  # Fake incoming coordinator: --validate-autotune-release verdict with the
  # admitted set = the release + every planned window entry (resolved beside
  # --previous-target). FAKE_VALIDATOR=reject answers ok:false, rc 1.
  cat > "$DEPLOY_TMP/coordinator-linux-amd64" <<FAKE
#!/usr/bin/env python3
import hashlib, json, os, sys
args = sys.argv[1:]
with open("$TMP/validator-calls", "a") as f:
    f.write(" ".join(args) + "\\n")
rel, prev = args[args.index("--validate-autotune-release") + 1], args[args.index("--previous-target") + 1]
def ref(d, source):
    raw = open(os.path.join(d, "autotune-candidates.json"), "rb").read()
    return {"release_id": json.loads(raw)["version"], "candidates_sha256": hashlib.sha256(raw).hexdigest(), "source": source}
with open("$TMP/validator-window", "w") as f:
    f.write(open(prev).read())
if os.environ.get("FAKE_VALIDATOR") == "reject":
    print(json.dumps({"ok": False, "admitted": [], "errors": ["autotune previous catalog: verify releases/p1: bad"]}))
    sys.exit(1)
admitted = [ref(rel, "current")] + [ref(os.path.join(os.path.dirname(prev), l.strip()), "retained")
                                   for l in open(prev) if l.strip()]
print(json.dumps({"ok": True, "admitted": admitted, "errors": [], "notes": []}))
FAKE
  chmod 0755 "$DEPLOY_TMP/coordinator-linux-amd64"
  # Live current + a full retained window; activation drops releases/p3.
  release live live-v
  release p1 p1-v
  release p2 p2-v
  release p3 p3-v
  release "$INCOMING_DIR" published-2026-09-23-tier2-buyer-closure-v1
  ln -s releases/live "$ROOT/autotune/current"
  printf 'releases/p1\nreleases/p2\nreleases/p3\n' > "$ROOT/autotune/.previous-target"
}

# shellcheck disable=SC2034 # consumed by the sourced deploy blocks
run_slice() {
  # $1 = verdict, $2 = window override b64 (may be empty). Output: $TMP/out.
  (
    set -euo pipefail
    log() { echo "$*"; }
    SSH=fake_ssh
    CATALOG_VERDICT="$1"
    CATALOG_WINDOW_OVERRIDE_B64="$2"
    CATALOG_CANARY_AUTH_TOKEN="$TOKEN"
    CATALOG_LIVE_TARGET="${LIVE_TARGET-releases/live}"
    CATALOG_LIVE_RELEASE_ID="live-v"
    AUTOTUNE_RELEASE_ID="published-2026-09-23-tier2-buyer-closure-v1"
    AUTOTUNE_RELEASE_DIR_NAME="$INCOMING_DIR"
    COORDINATOR_RELEASE_VERSION="v9.9.9"
    COORDINATOR_RELEASE_COMMIT="0123456789abcdef0123456789abcdef01234567"
    # shellcheck disable=SC1091
    . "$CWO_LIB"
    # shellcheck disable=SC1091
    . "$TMP/append-helper.sh"
    # shellcheck disable=SC1091
    . "$TMP/coverage-block.sh"
    echo "COVERAGE_DONE"
    if [ "$1" != equivalent ]; then
      # shellcheck disable=SC1091
      . "$TMP/activate-block.sh"
      echo "ACTIVATED"
    fi
  ) > "$TMP/out" 2>&1
}

current_target() { readlink "$ROOT/autotune/current"; }
window() { tr '\n' ' ' < "$ROOT/autotune/.previous-target"; }
no_token_in_argv() {
  ! grep -qF "$TOKEN" "$TMP/ssh-log" "$TMP/curl-calls" "$TMP/out" 2>/dev/null || fail "the operator key leaked into argv or the log"
}

# covered: providers on live and a retained release -> activation proceeds.
reset
pool "$(provider live-v live)" "$(provider p1-v p1 false)" '{"provider_id":"legacy","routing_eligible":true}'
run_slice descends "" || { cat "$TMP/out" >&2; fail "covered pool must activate"; }
grep -qF 'window coverage: 4 admissible release(s), 2 catalog-advertising provider(s), 0 uncovered' "$TMP/out" ||
  { cat "$TMP/out" >&2; fail "coverage report must be logged"; }
grep -q '^ACTIVATED$' "$TMP/out" || fail "covered pool must reach activation"
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "covered pool must swap current"
[ "$(window)" = "releases/live releases/p1 releases/p2 " ] || fail "covered pool must apply the window"
[ "$(wc -l < "$TMP/curl-calls" | tr -d ' ')" = "1" ] || fail "coverage must fetch /poolz exactly once"
grep -q -- '--config -' "$TMP/curl-calls" || fail "curl must read the bearer from stdin"
[ ! -e "$DEPLOY_TMP/poolz.json" ] || fail "the /poolz body must be removed after coverage"
grep -qE 'provider_id|legacy|"p[0-9]+"' "$TMP/out" && fail "the report must not name providers"
[ "$(wc -l < "$TMP/validator-calls" | tr -d ' ')" = "1" ] || fail "the incoming coordinator must validate exactly once"
grep -qF -- "--config $ROOT/coordinator.yaml --validate-autotune-release $ROOT/autotune/releases/$INCOMING_DIR --previous-target " "$TMP/validator-calls" ||
  { cat "$TMP/validator-calls" >&2; fail "validator must get the live config, the staged release and the planned window"; }
[ "$(tr '\n' ' ' < "$TMP/validator-window")" = "releases/live releases/p1 releases/p2 " ] ||
  fail "validator must be handed the window the activation writes"
no_token_in_argv

# validator rejects the release + planned window -> abort before mutation,
# even with an override.
reset
pool "$(provider live-v live)"
if FAKE_VALIDATOR=reject run_slice descends "$(printf 'x' | base64)"; then fail "a validator rejection must abort"; fi
grep -q 'rejected the release with the planned window' "$TMP/out" || { cat "$TMP/out" >&2; fail "validator rejection must say why"; }
grep -q 'could not prove connected providers keep an admissible catalog' "$TMP/out" || fail "validator rejection must abort the deploy"
[ "$(current_target)" = "releases/live" ] || fail "validator rejection must not swap current"
[ "$(window)" = "releases/p1 releases/p2 releases/p3 " ] || fail "validator rejection must not apply the window"
[ ! -e "$VAR/catalog-window-overrides.jsonl" ] || fail "validator rejection must not log an override"
[ ! -e "$DEPLOY_TMP/poolz.json" ] || fail "the /poolz body must be removed after a validator rejection"

# uncovered: a connected provider advertises the release activation drops.
reset
pool "$(provider live-v live)" "$(provider p3-v p3)" "$(provider p3-v p3 false)"
if run_slice descends ""; then fail "an uncovered advertised release must abort"; fi
grep -qF "UNCOVERED p3-v sha=$(sha_of p3 | cut -c1-16) providers=2 routing_eligible=1" "$TMP/out" ||
  { cat "$TMP/out" >&2; fail "the uncovered release must be reported with counts"; }
grep -qF 'CATALOG_WINDOW_OVERRIDE_REASON' "$TMP/out" || fail "the abort must name the override"
grep -q '^COVERAGE_DONE$' "$TMP/out" && fail "uncovered must abort before activation"
[ "$(current_target)" = "releases/live" ] || fail "uncovered must not swap current"
[ "$(window)" = "releases/p1 releases/p2 releases/p3 " ] || fail "uncovered must not apply the window"
[ ! -e "$VAR/catalog-window-overrides.jsonl" ] || fail "no override log without an override"

# regression verdict (A2 override given) is still coverage-checked.
reset
pool "$(provider p3-v p3)"
if run_slice regression ""; then fail "a regression activation must also be coverage-checked"; fi
[ "$(current_target)" = "releases/live" ] || fail "uncovered regression must not swap current"

# override: logged, then activated.
reset
pool "$(provider p3-v p3)" "$(provider live-v live)"
reason="providers pinned to p3 are being retired; ticket #1688"
run_slice descends "$(printf '%s' "$reason" | base64 | tr -d '\n')" || { cat "$TMP/out" >&2; fail "override must proceed"; }
grep -qF 'WINDOW COVERAGE OVERRIDE' "$TMP/out" || fail "override must be announced"
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "override must activate"
log="$VAR/catalog-window-overrides.jsonl"
[ "$(stat -f %Lp "$log" 2>/dev/null || stat -c %a "$log")" = "600" ] || fail "override log must be 0600"
python3 - "$log" "$reason" "$INCOMING_DIR" "$(sha_of p3)" <<'PY' || fail "override record is wrong"
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 1, lines
r = json.loads(lines[0])
assert set(r) == {"ts", "kind", "reason", "uncovered", "incoming", "live", "tag", "commit"}, r
assert r["kind"] == "window_coverage" and r["reason"] == sys.argv[2] and r["incoming"] == sys.argv[3], r
assert r["uncovered"] == [{"release_id": "p3-v", "sha": sys.argv[4], "providers": 1, "routing_eligible": 1}], r
assert r["live"] == {"target": "releases/live", "release_id": "live-v"}, r
assert r["tag"] == "v9.9.9" and r["commit"].startswith("0123"), r
PY
no_token_in_argv

# /poolz unreachable or not authenticated -> fail closed, even with an override.
for mode in down unauthorized; do
  reset
  pool "$(provider live-v live)"
  if FAKE_POOLZ=$mode run_slice descends "$(printf 'x' | base64)"; then fail "/poolz $mode must abort"; fi
  grep -q 'could not prove connected providers keep an admissible catalog' "$TMP/out" || { cat "$TMP/out" >&2; fail "/poolz $mode abort must say why"; }
  [ "$(current_target)" = "releases/live" ] || fail "/poolz $mode must not swap current"
  [ ! -e "$VAR/catalog-window-overrides.jsonl" ] || fail "/poolz $mode must not log an override"
done

# malformed /poolz -> fail closed.
reset
printf '{"pool": {}}' > "$TMP/poolz.json"
if run_slice descends ""; then fail "malformed /poolz must abort"; fi
[ "$(current_target)" = "releases/live" ] || fail "malformed /poolz must not swap current"

# equivalent and bootstrap never read /poolz.
reset
run_slice equivalent "" || { cat "$TMP/out" >&2; fail "equivalent coverage block must be a no-op"; }
[ ! -e "$TMP/curl-calls" ] && [ ! -e "$TMP/ssh-log" ] && [ ! -e "$TMP/validator-calls" ] || fail "equivalent must not run coverage"
reset
rm -f "$ROOT/autotune/current" "$ROOT/autotune/.previous-target"
LIVE_TARGET="" run_slice bootstrap "" || { cat "$TMP/out" >&2; fail "bootstrap must activate"; }
[ ! -e "$TMP/curl-calls" ] || fail "bootstrap must not read /poolz"
grep -q 'bootstrap has no live current' "$TMP/out" || fail "bootstrap must log trivial coverage"
[ "$(current_target)" = "releases/$INCOMING_DIR" ] || fail "bootstrap must activate the incoming release"

# Window override reason validation (runs before any SSH).
# shellcheck disable=SC2034 # consumed by the eval'd validation block
check_reason() {
  ( CATALOG_WINDOW_OVERRIDE_REASON="$1"; eval "$validate_block"; printf '%s' "$CATALOG_WINDOW_OVERRIDE_B64" ) 2>/dev/null
}
[ "$(check_reason 'ok reason' | base64 -d 2>/dev/null || check_reason 'ok reason' | base64 -D)" = "ok reason" ] ||
  fail "a printable reason must round-trip through base64"
check_reason "$(printf 'two\nlines')" >/dev/null && fail "multi-line reason must be rejected"
check_reason "$(printf 'tab\there')" >/dev/null && fail "control characters must be rejected"
check_reason "$(printf '%0201d' 0)" >/dev/null && fail "a reason over 200 characters must be rejected"
check_reason "\$(touch $TMP/pwned)'\"" >/dev/null || fail "shell metacharacters are printable and must be accepted as data"
[ ! -e "$TMP/pwned" ] || fail "override reason must never be evaluated"

echo "PASS: deploy_catalog_window_coverage"
