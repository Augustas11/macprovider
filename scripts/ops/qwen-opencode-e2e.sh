#!/usr/bin/env bash
# Recoverable same-provider Qwen/OpenCode live gateway acceptance.
#
# Usage:
#   scripts/ops/qwen-opencode-e2e.sh status
#   scripts/ops/qwen-opencode-e2e.sh next
#   scripts/ops/qwen-opencode-e2e.sh next --run
#   scripts/ops/qwen-opencode-e2e.sh diagnostic
#
# Live environment (normally from the untracked ops env file):
#   QWEN_E2E_WRITTEN_HANDBACK private shared handoff recording Studio release
#   QWEN_E2E_HANDBACK       local output path for the derived release binding
#   QWEN_E2E_CLI            absolute path of the handed-back signed CLI on Studio
#   QWEN_E2E_CONFIG         absolute path of the incumbent provider config on Studio
#   QWEN_E2E_JOURNAL        absolute non-repository journal path on Studio
#   QWEN_E2E_OPENCODE       absolute Studio OpenCode 1.17.9 executable
#   BUYER_TOKEN_FILE        absolute local owner-only Malibu buyer token file
#   STUDIO_SSH, COORDINATOR_URL, MACPROVIDER_OPS_OWNER
#
# `diagnostic` is deliberately separate from live ops.  It requires
# QWEN_E2E_DIAGNOSTIC_CONFIG/JOURNAL/VALIDATOR to be regular files below the
# system temporary directory and only exercises prepare/restore mechanics.
set -euo pipefail

OPS_NAME=qwen-opencode-e2e
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

HELPER="$OPS_DIR/lib/qwen-provider-transaction.py"
RECORDER="$OPS_DIR/lib/opencode-gateway-check.py"
TARGET_ONE=qwen3-coder-30b-a3b-instruct
TARGET_TWO=qwen3-30b-a3b-instruct-2507
TARGET_ONE_KEY=qwen3-coder-30b-a3b-instruct
TARGET_TWO_KEY=qwen/qwen3-30b-a3b-instruct-2507
RELEASE_TEAM_ID=YF7XNRJUG4
RELEASE_SIGNING_IDENTIFIER=live.malibu.provider.cli

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

quote_args() {
  local output="" item quoted
  for item in "$@"; do
    printf -v quoted '%q' "$item"
    output="$output $quoted"
  done
  printf '%s' "${output# }"
}

studio_command() {
  local command
  command="$(quote_args "$@")"
  studio_ssh "$command"
}

studio_helper() {
  local command
  command="$(quote_args python3 - "$@")"
  studio_ssh "$command" < "$HELPER"
}

require_abs() {
  case "$2" in /*) ;; *) refuse "$1 must be an absolute path" ;; esac
}

validate_handback() {
  local source="${QWEN_E2E_HANDBACK:-}"
  [ -n "$source" ] || return 1
  require_abs QWEN_E2E_HANDBACK "$source"
  python3 - "$source" "$OPS_TMP_DIR/handback.json" <<'PY'
import json, os, re, stat, sys
source, output = sys.argv[1:]
try:
    info = os.lstat(source)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise ValueError("unsafe handback file")
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result: raise ValueError("duplicate key")
            result[key] = value
        return result
    value = json.load(open(source, encoding="utf-8"), object_pairs_hook=pairs)
    required = {"schema_version", "campaign_id", "provider_id", "binary_version", "cli_sha256",
                "code_cdhash", "team_id", "signing_identifier", "written_handoff_sha256"}
    if set(value) != required or value["schema_version"] != "macprovider.qwen_e2e_handback.v1":
        raise ValueError("schema")
    safe = re.compile(r"^[A-Za-z0-9._/@:+-]{1,256}$")
    if not all(isinstance(value[key], str) and safe.fullmatch(value[key])
               for key in ("campaign_id", "provider_id", "team_id", "signing_identifier")):
        raise ValueError("unsafe identity")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value["binary_version"]):
        raise ValueError("version")
    if not re.fullmatch(r"[0-9a-f]{64}", value["cli_sha256"]): raise ValueError("sha")
    if not re.fullmatch(r"[0-9a-f]{40,64}", value["code_cdhash"]): raise ValueError("cdhash")
    if not re.fullmatch(r"[0-9a-f]{64}", value["written_handoff_sha256"]): raise ValueError("handoff sha")
    json.dump(value, open(output, "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
except Exception:
    sys.exit(3)
PY
}

handback_field() { json_field "$OPS_TMP_DIR/handback.json" "d[$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")]"; }

written_handoff_sha() {
  local source="${QWEN_E2E_WRITTEN_HANDBACK:-}"
  [ -n "$source" ] || return 1
  require_abs QWEN_E2E_WRITTEN_HANDBACK "$source"
  python3 - "$source" "${1:-}" <<'PY'
import hashlib, os, re, stat, sys
path, version = sys.argv[1:]
info = os.lstat(path)
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size > 1_048_576:
    raise SystemExit(3)
text = open(path, "rb").read().decode("utf-8")
record_text = r"(?:Studio released by [A-Za-z0-9._@+-]+|([0-9]+\.[0-9]+\.[0-9]+) owner pin removed)"
release = re.compile(r"^\s*(?:[-*+]\s+)?" + record_text + r"[.!]?\s*$")
markdown_release = re.compile(
    r"^\s*(?:[-*+]\s+)?\*\*(?:[0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9]{2}:[0-9]{2}Z\s+)?"
    + record_text
    + r"\*\*(?::\s+signed\s+([0-9]+\.[0-9]+\.[0-9]+);\s+original provider is buyer-serving\.)?\s*$"
)
reservation = re.compile(
    r"(?:Studio (?:reserved|claimed)\b|owner pin (?:set|added|restored)\b|"
    r"STUDIO LOCK\b|\bowns the provider\b)", re.I
)
records = []
for index, line in enumerate(text.splitlines()):
    match = release.fullmatch(line) or markdown_release.fullmatch(line)
    if match:
        versions = {group for group in match.groups() if group}
        if len(versions) > 1: raise SystemExit(3)
        pinned = next(iter(versions), None)
        records.append((index, line.strip(), pinned))
if not records: raise SystemExit(3)
index, record, pinned = records[-1]
if version and pinned and pinned != version: raise SystemExit(3)
if any(reservation.search(line) for line in text.splitlines()[index + 1:]): raise SystemExit(3)
print(hashlib.sha256((record + "\n").encode()).hexdigest())
PY
}

verify_published_release_identity() {
  local version="$1" sha="$2" cdhash="$3" team="$4" identifier="$5"
  local dir="$OPS_TMP_DIR/published-release-$version" published
  mkdir -p "$dir"
  published="$(gh release view "v$version" -R "$(gh_repo)" --json isDraft,isPrerelease,publishedAt \
    --jq 'select(.isDraft == false and .isPrerelease == false) | .publishedAt' 2>/dev/null || true)"
  [ -n "$published" ] || return 1
  gh release download "v$version" -R "$(gh_repo)" -p pearl-release.json -p pearl-release.json.sig \
    -D "$dir" >/dev/null 2>&1 || return 1
  openssl dgst -sha256 -verify "$REPO_ROOT/ops/pearl-updater/release-signing-public.pem" \
    -signature "$dir/pearl-release.json.sig" "$dir/pearl-release.json" >/dev/null 2>&1 || return 1
  python3 - "$dir/pearl-release.json" "$version" "$sha" "$cdhash" "$team" "$identifier" \
    "$RELEASE_TEAM_ID" "$RELEASE_SIGNING_IDENTIFIER" <<'PY'
import json, sys
path, version, sha, cdhash, team, identifier, trusted_team, trusted_identifier = sys.argv[1:]
d=json.load(open(path)); ident=d.get("provider_code_identity") or {}
slices=ident.get("slices") or []
arm=[row for row in slices if isinstance(row,dict) and row.get("arch")=="arm64"]
expected=(version,sha,cdhash,trusted_team,trusted_identifier)
actual=(ident.get("binary_version"),ident.get("binary_sha256"),
        arm[0].get("code_cdhash") if len(arm)==1 else None,
        ident.get("team_id"),ident.get("signing_identifier"))
if d.get("tag") != "v"+version or d.get("release_version") != version or actual != expected:
    raise SystemExit(3)
if (team,identifier) != (trusted_team,trusted_identifier): raise SystemExit(3)
PY
}

fetch_market() {
  local base code
  base="$(coordinator_url)"
  [ -n "$base" ] || return 1
  code="$(http_get "$base/v1/autotune-candidates" "$OPS_TMP_DIR/candidates.json")"
  [ "$code" = 200 ] || return 1
  code="$(http_get "$base/v1/rate-card" "$OPS_TMP_DIR/rates.json")"
  [ "$code" = 200 ] || return 1
  python3 - "$OPS_TMP_DIR/candidates.json" "$OPS_TMP_DIR/rates.json" "$OPS_TMP_DIR/market.json" <<'PY'
import json, re, sys
candidates, rates = (json.load(open(path)) for path in sys.argv[1:3])
expected = {
 "qwen3-coder-30b-a3b-instruct": ("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "6e302ea604ad9ab206367e2c501d1571023e7b6d", "10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0"),
 "qwen/qwen3-30b-a3b-instruct-2507": ("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", "e9675aa3ca5f900ccef55267914466d55ab325fa", "a0ca3d59f301f08ae4c4c2010b07f80b890d35f4e8562c213b1d01aed8328e42"),
}
aliases = {"qwen/qwen3-30b-a3b-instruct-2507": "qwen3-30b-a3b-instruct-2507"}
bound_rates = {}
for key, (model, revision, digest) in expected.items():
    row = (candidates.get("rows") or {}).get(key)
    if not isinstance(row, dict) or (row.get("model_id"), row.get("model_revision"), row.get("model_sha256"), row.get("runtime_status")) != (model, revision, digest, "recommendable"):
        raise SystemExit(3)
    rate = (rates.get("rows") or {}).get(aliases.get(key, key))
    actual = tuple((rate or {}).get(name) for name in (
        "prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok"))
    if any(type(value) is not int or value <= 0 or value > 2**63 - 1 for value in actual):
        raise SystemExit(3)
    bound_rates[aliases.get(key, key)] = actual
for value in (candidates.get("version"), rates.get("version")):
    if not isinstance(value, str) or not value or len(value) > 256: raise SystemExit(3)
json.dump({"catalog_version": candidates["version"], "rate_card_version": rates["version"],
           "target_rates": bound_rates},
          open(sys.argv[3], "w"), sort_keys=True, separators=(",", ":"))
PY
}

read_studio_status() {
  studio_command "$QWEN_E2E_CLI" status --json --config "$QWEN_E2E_CONFIG"
}

status_pid() { json_field "$1" '(d.get("service_instance") or {}).get("pid")'; }

validate_status() {
  local file="$1" expected_model="$2" previous_pid="${3:-}"
  python3 - "$file" "$HB_VERSION" "$HB_PROVIDER" "$expected_model" "$LIVE_RELEASE" "$LIVE_DIGEST" "$previous_pid" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
version, provider, model, release, digest, previous = sys.argv[2:]
pid = (d.get("service_instance") or {}).get("pid")
bad = []
if d.get("binary_version") != version: bad.append("binary_version")
if d.get("provider_id") != provider: bad.append("provider_id")
if d.get("model") != model: bad.append("model")
if d.get("model_loaded") is not True or d.get("status") not in ("ready", "busy"): bad.append("model_ready")
if d.get("operator_paused") is not False: bad.append("operator_paused")
if d.get("network_state") != "buyer_serving": bad.append("network_state")
if (d.get("coordinator") or {}).get("connected") is not True: bad.append("coordinator.connected")
catalog = d.get("catalog") or {}
if catalog.get("state") != "live_verified": bad.append("catalog.state")
if catalog.get("release_id") != release or catalog.get("digest") != digest: bad.append("catalog.release")
if type(pid) is not int or pid < 1: bad.append("service_instance.pid")
if previous and str(pid) == previous: bad.append("service_instance.pid_not_changed")
if bad: raise SystemExit("status mismatch: " + ",".join(bad))
print(pid)
PY
}

poll_ready() {
  local expected_model="$1" previous_pid="$2" output="$3"
  local deadline now
  deadline=$(( $(date +%s) + ${QWEN_E2E_READY_TIMEOUT:-1200} ))
  while :; do
    if read_studio_status > "$output.tmp" 2>/dev/null &&
       validate_status "$output.tmp" "$expected_model" "$previous_pid" >/dev/null 2>&1; then
      mv "$output.tmp" "$output"
      validate_status "$output" "$expected_model" "$previous_pid"
      return 0
    fi
    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || return 1
    sleep 5
  done
}

verify_installed_cli() {
  local actual_sha version_line signature
  studio_ssh "/usr/sbin/system_profiler SPHardwareDataType -json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get(\"SPHardwareDataType\") or []; raise SystemExit(0 if rows and rows[0].get(\"machine_name\")==\"Mac Studio\" else 3)'" >/dev/null || return
  studio_command /usr/bin/test -f "$QWEN_E2E_CLI" || return
  studio_command /usr/bin/test -x "$QWEN_E2E_CLI" || return
  actual_sha="$(studio_command /usr/bin/shasum -a 256 "$QWEN_E2E_CLI" | awk '{print $1}')" || return
  [ "$actual_sha" = "$HB_SHA" ] || return 1
  studio_command /usr/bin/codesign --verify --strict "$QWEN_E2E_CLI" >/dev/null 2>&1 || return
  signature="$(studio_command /usr/bin/codesign -dvvv "$QWEN_E2E_CLI" 2>&1)" || return
  [ "$(printf '%s\n' "$signature" | sed -n 's/^CDHash=//p' | head -1)" = "$HB_CDHASH" ] || return 1
  [ "$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p' | head -1)" = "$HB_TEAM" ] || return 1
  [ "$(printf '%s\n' "$signature" | sed -n 's/^Identifier=//p' | head -1)" = "$HB_IDENTIFIER" ] || return 1
  version_line="$(studio_command "$QWEN_E2E_CLI" --version)" || return
  printf '%s\n' "$version_line" | grep -Eq "(^|[^0-9])${HB_VERSION//./\\.}([^0-9]|$)" || return 1
}

studio_preflight() {
  local status_file="$1" pid executable executable_real cli_real
  verify_installed_cli || return 1
  read_studio_status > "$status_file" || return
  pid="$(status_pid "$status_file")"
  [ -n "$pid" ] || return 1
  executable="$(studio_command /usr/sbin/lsof -a -p "$pid" -d txt -Fn | sed -n 's/^n//p' | head -1)" || return
  [ -n "$executable" ] || return 1
  executable_real="$(studio_command /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$executable")" || return
  cli_real="$(studio_command /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$QWEN_E2E_CLI")" || return
  [ -n "$executable_real" ] && [ "$executable_real" = "$cli_real" ] || return 1
}

load_live_context() {
  HB_VERSION="$(handback_field binary_version)"
  HB_PROVIDER="$(handback_field provider_id)"
  HB_SHA="$(handback_field cli_sha256)"
  HB_CDHASH="$(handback_field code_cdhash)"
  HB_TEAM="$(handback_field team_id)"
  HB_IDENTIFIER="$(handback_field signing_identifier)"
  HB_HANDOFF_SHA="$(handback_field written_handoff_sha256)"
  LIVE_RELEASE="$(json_field "$OPS_TMP_DIR/preflight-status.json" '(d.get("catalog") or {}).get("release_id")')"
  LIVE_DIGEST="$(json_field "$OPS_TMP_DIR/preflight-status.json" '(d.get("catalog") or {}).get("digest")')"
  INCUMBENT_MODEL="$(json_field "$OPS_TMP_DIR/preflight-status.json" 'd.get("model")')"
  RATE_VERSION="$(json_field "$OPS_TMP_DIR/market.json" 'd["rate_card_version"]')"
  CATALOG_VERSION="$(json_field "$OPS_TMP_DIR/market.json" 'd["catalog_version"]')"
  [ -n "$LIVE_RELEASE" ] && [ "$LIVE_RELEASE" = "$CATALOG_VERSION" ] &&
    [ -n "$LIVE_DIGEST" ] && [ -n "$INCUMBENT_MODEL" ] && [ -n "$RATE_VERSION" ]
}

derive_handback() {
  local output="$1" status_file="$OPS_TMP_DIR/bind-status.json"
  local pid executable executable_real cli_real actual_sha version_line version signature cdhash team identifier provider handoff_sha campaign
  read_studio_status > "$status_file" || return
  pid="$(status_pid "$status_file")"
  [ -n "$pid" ] || return 1
  provider="$(json_field "$status_file" 'd.get("provider_id")')"
  [ -n "$provider" ] || return 1
  studio_ssh "/usr/sbin/system_profiler SPHardwareDataType -json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get(\"SPHardwareDataType\") or []; raise SystemExit(0 if rows and rows[0].get(\"machine_name\")==\"Mac Studio\" else 3)'" >/dev/null || return
  studio_command /usr/bin/test -f "$QWEN_E2E_CLI" || return
  studio_command /usr/bin/test -x "$QWEN_E2E_CLI" || return
  actual_sha="$(studio_command /usr/bin/shasum -a 256 "$QWEN_E2E_CLI" | awk '{print $1}')" || return
  printf '%s\n' "$actual_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
  studio_command /usr/bin/codesign --verify --strict "$QWEN_E2E_CLI" >/dev/null 2>&1 || return
  signature="$(studio_command /usr/bin/codesign -dvvv "$QWEN_E2E_CLI" 2>&1)" || return
  cdhash="$(printf '%s\n' "$signature" | sed -n 's/^CDHash=//p' | head -1 | tr 'A-F' 'a-f')"
  team="$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  identifier="$(printf '%s\n' "$signature" | sed -n 's/^Identifier=//p' | head -1)"
  version_line="$(studio_command "$QWEN_E2E_CLI" --version)" || return
  version="$(python3 - "$version_line" <<'PY'
import re, sys
values = re.findall(r"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])", sys.argv[1])
if len(set(values)) != 1: raise SystemExit(3)
print(values[0])
PY
)"
  verify_published_release_identity "$version" "$actual_sha" "$cdhash" "$team" "$identifier" || return 1
  handoff_sha="$(written_handoff_sha "$version")" || return
  executable="$(studio_command /usr/sbin/lsof -a -p "$pid" -d txt -Fn | sed -n 's/^n//p' | head -1)" || return
  [ -n "$executable" ] || return 1
  executable_real="$(studio_command /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$executable")" || return
  cli_real="$(studio_command /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$QWEN_E2E_CLI")" || return
  [ -n "$executable_real" ] && [ "$executable_real" = "$cli_real" ] || return 1
  campaign="qwen-${version}-${handoff_sha:0:12}"
  python3 - "$output" "$campaign" "$provider" "$version" "$actual_sha" "$cdhash" "$team" "$identifier" "$handoff_sha" <<'PY'
import json, os, re, stat, sys, tempfile
path, campaign, provider, version, sha, cdhash, team, identifier, handoff_sha = sys.argv[1:]
if not os.path.isabs(path): raise SystemExit(3)
try:
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise SystemExit(3)
except FileNotFoundError:
    pass
safe = re.compile(r"^[A-Za-z0-9._/@:+-]{1,256}$")
if not all(safe.fullmatch(value) for value in (campaign, provider, team, identifier)): raise SystemExit(3)
value = {"schema_version":"macprovider.qwen_e2e_handback.v1", "campaign_id":campaign,
         "provider_id":provider, "binary_version":version, "cli_sha256":sha,
         "code_cdhash":cdhash, "team_id":team, "signing_identifier":identifier,
         "written_handoff_sha256":handoff_sha}
directory = os.path.dirname(path)
os.makedirs(directory, mode=0o700, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".qwen-handback.", dir=directory)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":")); stream.write("\n")
        stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)
finally:
    try: os.unlink(temporary)
    except FileNotFoundError: pass
PY
}

gather() {
  local handback_ok=false inputs_ok=false preflight_ok=false journal_state=unknown restore_required=false
  OPS_SCOPE="qwen-opencode-unbound"
  for name in QWEN_E2E_CLI QWEN_E2E_CONFIG QWEN_E2E_JOURNAL; do
    [ -n "${!name:-}" ] || { set_next inputs blocked "Configure Qwen E2E inputs" "" "$name is unset"; return; }
  done
  require_abs QWEN_E2E_CLI "$QWEN_E2E_CLI"
  require_abs QWEN_E2E_CONFIG "$QWEN_E2E_CONFIG"
  require_abs QWEN_E2E_JOURNAL "$QWEN_E2E_JOURNAL"
  require_studio_ssh
  if studio_helper inspect --journal "$QWEN_E2E_JOURNAL" > "$OPS_TMP_DIR/journal.json" 2>/dev/null; then
    journal_state="$(json_field "$OPS_TMP_DIR/journal.json" 'd.get("status")')"
    restore_required="$(json_field "$OPS_TMP_DIR/journal.json" 'd.get("restore_required")')"
  fi
  fact journal_state "$journal_state"
  fact restore_required "$restore_required"
  if [ "$restore_required" = true ]; then
    set_next restore mutate "Restore the incumbent provider after an interrupted Qwen transaction" \
      "$OPS_DIR/qwen-opencode-e2e.sh _restore"
    return
  fi
  if validate_handback; then handback_ok=true; fi
  fact handback_valid "$handback_ok"
  if [ "$handback_ok" = false ]; then
    for name in QWEN_E2E_WRITTEN_HANDBACK QWEN_E2E_HANDBACK; do
      [ -n "${!name:-}" ] || { set_next handback blocked "Configure the written handoff binding" "" "$name is unset"; return; }
    done
    require_abs QWEN_E2E_HANDBACK "$QWEN_E2E_HANDBACK"
    written_handoff_sha >/dev/null || {
      set_next handback blocked "Wait for the explicit Studio handback" "" "written handoff does not record Studio release or owner-pin removal"
      return
    }
    set_next bind mutate "Derive and record the signed Studio release binding" \
      "$OPS_DIR/qwen-opencode-e2e.sh _bind"
    return
  fi
  local campaign
  campaign="$(handback_field campaign_id)"
  OPS_SCOPE="qwen-opencode-$campaign"
  [ "$(written_handoff_sha "$(handback_field binary_version)")" = "$(handback_field written_handoff_sha256)" ] || {
    set_next handback blocked "Re-bind the changed written Studio handback" "" "the written handoff no longer matches the campaign binding"
    return
  }
  for name in QWEN_E2E_OPENCODE BUYER_TOKEN_FILE; do
    [ -n "${!name:-}" ] || { set_next inputs blocked "Configure Qwen E2E inputs" "" "$name is unset"; return; }
  done
  require_abs QWEN_E2E_OPENCODE "$QWEN_E2E_OPENCODE"
  require_abs BUYER_TOKEN_FILE "$BUYER_TOKEN_FILE"
  python3 - "$BUYER_TOKEN_FILE" <<'PY' || {
import os, stat, sys
info=os.lstat(sys.argv[1])
if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
        or info.st_mode & 0o077 or info.st_size < 1 or info.st_size > 8193):
    raise SystemExit(3)
PY
    set_next inputs blocked "Protect the buyer credential input" "" "BUYER_TOKEN_FILE must be an owner-only regular file of bounded size"
    return
  }
  inputs_ok=true
  fact inputs_valid "$inputs_ok"
  if ! fetch_market; then
    set_next market blocked "Verify exact live Qwen catalog and rates" "" "live signed market rows are unavailable or differ from the qualified targets"
    return
  fi
  HB_VERSION="$(handback_field binary_version)"; HB_PROVIDER="$(handback_field provider_id)"
  HB_SHA="$(handback_field cli_sha256)"; HB_CDHASH="$(handback_field code_cdhash)"
  HB_TEAM="$(handback_field team_id)"; HB_IDENTIFIER="$(handback_field signing_identifier)"
  if studio_preflight "$OPS_TMP_DIR/preflight-status.json"; then preflight_ok=true; fi
  fact studio_signed_preflight "$preflight_ok"
  [ "$preflight_ok" = true ] || {
    set_next preflight blocked "Verify the handed-back signed release on Studio" "" "hardware, running-byte identity, signature, version, provider identity, or local status did not match handback"
    return
  }
  load_live_context || {
    set_next catalog blocked "Read incumbent live catalog identity" "" "Studio status did not expose an exact live catalog release and digest"
    return
  }
  validate_status "$OPS_TMP_DIR/preflight-status.json" "$INCUMBENT_MODEL" >/dev/null || {
    set_next ready blocked "Wait for the handed-back incumbent to be buyer-serving" "" "incumbent is not connected, live_verified, and buyer_serving"
    return
  }
  fact binary_version "$HB_VERSION"
  fact live_catalog_release "$LIVE_RELEASE"
  fact incumbent_model "$INCUMBENT_MODEL"
  if marker_done "$OPS_SCOPE" campaign; then
    set_next complete "done" "Both exact Qwen models passed OpenCode live-gateway acceptance and the incumbent was restored" ""
    return
  fi
  set_next campaign mutate "Run both Qwen OpenCode acceptances and restore the incumbent" \
    "$OPS_DIR/qwen-opencode-e2e.sh _campaign"
  NEXT_DOWNTIME="Studio provider buyer traffic is unavailable during bounded restart and model-load windows; Pearl is not restarted"
  NEXT_MARK=campaign
}

upload_file() {
  local local_file="$1" remote_file="$2"
  local code='import os,sys,tempfile
path=sys.argv[1]; parent=os.path.dirname(path)
if not os.path.isabs(path) or os.path.lexists(path): raise SystemExit(3)
fd,tmp=tempfile.mkstemp(prefix=".upload.",dir=parent)
try:
 os.fchmod(fd,0o600)
 with os.fdopen(fd,"wb") as stream:
  stream.write(sys.stdin.buffer.read()); stream.flush(); os.fsync(stream.fileno())
 os.link(tmp,path,follow_symlinks=False)
 directory=os.open(parent,os.O_RDONLY)
 try: os.fsync(directory)
 finally: os.close(directory)
finally:
 try: os.unlink(tmp)
 except FileNotFoundError: pass'
  studio_command /usr/bin/python3 -c "$code" "$remote_file" < "$local_file"
}

create_remote_scratch() {
  local path base
  path="$(studio_command /usr/bin/mktemp -d -t macprovider-qwen-e2e)" || return 1
  base="${path##*/}"
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$base" in macprovider-qwen-e2e.*) ;; *) return 1 ;; esac
  studio_command /bin/chmod 0700 "$path" || {
    studio_command /bin/rmdir "$path" >/dev/null 2>&1 || true
    return 1
  }
  studio_command /usr/bin/python3 -c 'import os,stat,sys; s=os.lstat(sys.argv[1]); raise SystemExit(0 if stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o700 else 3)' "$path" || {
    studio_command /bin/rmdir "$path" >/dev/null 2>&1 || true
    return 1
  }
  printf '%s\n' "$path"
}

remove_remote_scratch() {
  [ -n "${REMOTE_SCRATCH:-}" ] || return 0
  local base="${REMOTE_SCRATCH##*/}"
  case "$REMOTE_SCRATCH" in /*) ;; *) return 1 ;; esac
  case "$base" in macprovider-qwen-e2e.*) ;; *) return 1 ;; esac
  studio_command /usr/bin/python3 -c 'import os,stat,sys; s=os.lstat(sys.argv[1]); raise SystemExit(0 if stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o700 else 3)' "$REMOTE_SCRATCH" || return 1
  studio_command /bin/rm -f "$REMOTE_REC_ONE" "$REMOTE_REC_TWO" "$REMOTE_RECORDER" >/dev/null
  studio_command /bin/rmdir "$REMOTE_SCRATCH" >/dev/null
}

emit_recommendation() {
  local target_key="$1" local_file="$2"
  studio_command "$QWEN_E2E_CLI" autotune --recommend --check-only --installed-only \
    --candidate-models "$target_key" --json --no-submit-hardware-evidence --config "$QWEN_E2E_CONFIG" > "$local_file"
}

verify_remote_recommendation() {
  local target="$1" remote_file="$2"
  studio_helper verify-recommendation --recommendation "$remote_file" --target "$target" \
    --binary-version "$HB_VERSION" --catalog-version "$LIVE_RELEASE" --catalog-hash "$LIVE_DIGEST" \
    --rate-card-version "$RATE_VERSION" >/dev/null
}

verify_local_rate_version() {
  python3 - "$1" "$RATE_VERSION" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
if (d.get("inputs") or {}).get("rate_card_version") != sys.argv[2]: raise SystemExit(3)
PY
}

adopt_recommendation() {
  local remote_file="$1" output="$2" attempt=0 rc
  while [ "$attempt" -lt 12 ]; do
    attempt=$((attempt + 1))
    if studio_command "$QWEN_E2E_CLI" models adopt-recommendation --json --config "$QWEN_E2E_CONFIG" \
      --recommendation-json "$remote_file" > "$output" 2>&1; then
      return 0
    else
      rc=$?
    fi
    [ "$rc" = 6 ] && grep -Eq 'cooldown_[0-9]+' "$output" || return "$rc"
    sleep 10
  done
  return 6
}

restart_and_wait() {
  local expected="$1" before_file="$2" after_file="$3" before_pid
  before_pid="$(status_pid "$before_file")"
  [ -n "$before_pid" ] || return 1
  studio_command "$QWEN_E2E_CLI" restart --config "$QWEN_E2E_CONFIG" >/dev/null
  poll_ready "$expected" "$before_pid" "$after_file" >/dev/null
}

checkpoint_remote() {
  local phase="$1" target="$2" remote_file="$3"
  studio_helper checkpoint --config "$QWEN_E2E_CONFIG" --journal "$QWEN_E2E_JOURNAL" --phase "$phase" \
    --recommendation "$remote_file" --target "$target" --binary-version "$HB_VERSION" \
    --catalog-version "$LIVE_RELEASE" --catalog-hash "$LIVE_DIGEST" \
    --rate-card-version "$RATE_VERSION" >/dev/null
}

begin_adoption_remote() {
  local phase="$1" target="$2" remote_file="$3"
  studio_helper begin-adoption --config "$QWEN_E2E_CONFIG" --journal "$QWEN_E2E_JOURNAL" --phase "$phase" \
    --recommendation "$remote_file" --target "$target" --binary-version "$HB_VERSION" \
    --catalog-version "$LIVE_RELEASE" --catalog-hash "$LIVE_DIGEST" \
    --rate-card-version "$RATE_VERSION" >/dev/null
}

save_recorder_result() {
  local source="$1" target="$2" destination="$3"
  mkdir -p "$(dirname "$destination")"
  python3 - "$source" "$target" "$destination" <<'PY'
import json, os, stat, sys, tempfile
source, target, destination = sys.argv[1:]
try: value=json.load(open(source))
except Exception: value={"schema_version":"macprovider.opencode_gateway_check.v1","status":"fail","accepted":False,"error_code":"recorder_output_invalid"}
if (value.get("model") or {}).get("gateway_id") not in (None, target):
    value={"schema_version":"macprovider.opencode_gateway_check.v1","status":"fail","accepted":False,"error_code":"recorder_model_mismatch"}
allowed=("schema_version","status","accepted","error_code","client","model","requests","opencode","receipt_validation")
safe={key:value[key] for key in allowed if key in value}
safe["target"]=target
directory=os.path.dirname(destination); fd,tmp=tempfile.mkstemp(prefix=".qwen-result.",dir=directory)
try:
 os.fchmod(fd,0o600)
 with os.fdopen(fd,"w") as f: json.dump(safe,f,sort_keys=True,separators=(",",":")); f.write("\n"); f.flush(); os.fsync(f.fileno())
 os.replace(tmp,destination)
finally:
 try: os.unlink(tmp)
 except FileNotFoundError: pass
PY
}

run_recorder() {
  local target="$1" output="$2" evidence="$3" rc=0
  studio_command /usr/bin/python3 "$REMOTE_RECORDER" --opencode "$QWEN_E2E_OPENCODE" \
    --model "$target" --key-stdin < "$BUYER_TOKEN_FILE" > "$output" || rc=$?
  save_recorder_result "$output" "$target" "$evidence"
  [ "$rc" = 0 ] || return "$rc"
  python3 - "$output" "$target" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
if d.get("accepted") is not True or d.get("status") != "pass" or (d.get("model") or {}).get("gateway_id") != sys.argv[2] or (d.get("receipt_validation") or {}).get("status") != "verified": raise SystemExit(3)
PY
}

restore_provider() {
  local after="$OPS_TMP_DIR/restore-after.json"
  studio_helper restore --config "$QWEN_E2E_CONFIG" --journal "$QWEN_E2E_JOURNAL" \
    --validator "$QWEN_E2E_CLI" >/dev/null || return
  studio_command "$QWEN_E2E_CLI" restart --config "$QWEN_E2E_CONFIG" >/dev/null || return
  poll_ready "$INCUMBENT_MODEL" "$BASELINE_PID" "$after" >/dev/null || return
  studio_helper finish-restore --config "$QWEN_E2E_CONFIG" \
    --journal "$QWEN_E2E_JOURNAL" >/dev/null || return
}

load_journal_context() {
  local file="$1"
  INCUMBENT_MODEL="$(json_field "$file" 'd.get("baseline_model")')"
  HB_VERSION="$(json_field "$file" '(d.get("release_binding") or {}).get("binary_version")')"
  HB_PROVIDER="$(json_field "$file" '(d.get("release_binding") or {}).get("provider_id")')"
  HB_SHA="$(json_field "$file" '(d.get("release_binding") or {}).get("cli_sha256")')"
  HB_CDHASH="$(json_field "$file" '(d.get("release_binding") or {}).get("code_cdhash")')"
  HB_TEAM="$(json_field "$file" '(d.get("release_binding") or {}).get("team_id")')"
  HB_IDENTIFIER="$(json_field "$file" '(d.get("release_binding") or {}).get("signing_identifier")')"
  HB_HANDOFF_SHA="$(json_field "$file" '(d.get("release_binding") or {}).get("written_handoff_sha256")')"
  LIVE_RELEASE="$(json_field "$file" '(d.get("baseline_status") or {}).get("catalog_version")')"
  LIVE_DIGEST="$(json_field "$file" '(d.get("baseline_status") or {}).get("catalog_hash")')"
  BASELINE_PID="$(json_field "$file" '(d.get("baseline_status") or {}).get("pid")')"
  RATE_VERSION="$(json_field "$file" '(d.get("market_binding") or {}).get("rate_card_version")')"
  REMOTE_SCRATCH="$(json_field "$file" 'd.get("remote_scratch")')"
  REMOTE_REC_ONE="$REMOTE_SCRATCH/one.recommendation.json"
  REMOTE_REC_TWO="$REMOTE_SCRATCH/two.recommendation.json"
  REMOTE_RECORDER="$REMOTE_SCRATCH/opencode-gateway-check.py"
  [ -n "$INCUMBENT_MODEL" ] && [ -n "$HB_VERSION" ] && [ -n "$LIVE_RELEASE" ] &&
    [ -n "$LIVE_DIGEST" ] && [ -n "$BASELINE_PID" ] && [ -n "$RATE_VERSION" ] &&
    [ -n "$REMOTE_SCRATCH" ]
}

campaign_cleanup() {
  local rc=$? cleanup_rc=0 cleanup_status cleanup_required
  trap - EXIT INT TERM HUP
  set +e
  if studio_helper inspect --journal "$QWEN_E2E_JOURNAL" > "$OPS_TMP_DIR/cleanup-journal.json" 2>/dev/null; then
    cleanup_status="$(json_field "$OPS_TMP_DIR/cleanup-journal.json" 'd.get("status")')"
    cleanup_required="$(json_field "$OPS_TMP_DIR/cleanup-journal.json" 'd.get("restore_required")')"
    if [ "$cleanup_required" = true ] && [ "$cleanup_status" != restored ]; then
      if load_journal_context "$OPS_TMP_DIR/cleanup-journal.json" && verify_installed_cli; then
        restore_provider || cleanup_rc=$?
      else
        cleanup_rc=71
      fi
    fi
  else
    cleanup_rc=71
  fi
  remove_remote_scratch || [ "$cleanup_rc" -ne 0 ] || cleanup_rc=72
  set -e
  cleanup_ops
  [ "$cleanup_rc" = 0 ] || { log "incumbent restoration or protected scratch cleanup failed; journal remains authoritative"; exit 70; }
  exit "$rc"
}

run_campaign() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse "campaign is callable only by next --run"
  validate_handback || refuse "handback changed under the live lock"
  OPS_SCOPE="qwen-opencode-$(handback_field campaign_id)"
  fetch_market || refuse "live market changed under the live lock"
  HB_VERSION="$(handback_field binary_version)"; HB_PROVIDER="$(handback_field provider_id)"
  HB_SHA="$(handback_field cli_sha256)"; HB_CDHASH="$(handback_field code_cdhash)"
  HB_TEAM="$(handback_field team_id)"; HB_IDENTIFIER="$(handback_field signing_identifier)"
  HB_HANDOFF_SHA="$(handback_field written_handoff_sha256)"
  [ "$(written_handoff_sha "$HB_VERSION")" = "$HB_HANDOFF_SHA" ] || refuse "written Studio handback changed under the live lock"
  studio_preflight "$OPS_TMP_DIR/preflight-status.json" || refuse "Studio signed handback preflight changed under the live lock"
  load_live_context || refuse "live context is incomplete"
  validate_status "$OPS_TMP_DIR/preflight-status.json" "$INCUMBENT_MODEL" >/dev/null || refuse "incumbent is not buyer-serving"
  local transaction_id evidence_dir recorder_sha remote_recorder_sha
  transaction_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  evidence_dir="$OPS_STATE_DIR/$OPS_SCOPE/results"
  trap campaign_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  REMOTE_SCRATCH="$(create_remote_scratch)" || refuse "could not create protected Studio scratch"
  REMOTE_REC_ONE="$REMOTE_SCRATCH/one.recommendation.json"
  REMOTE_REC_TWO="$REMOTE_SCRATCH/two.recommendation.json"
  REMOTE_RECORDER="$REMOTE_SCRATCH/opencode-gateway-check.py"
  upload_file "$RECORDER" "$REMOTE_RECORDER"
  recorder_sha="$(/usr/bin/shasum -a 256 "$RECORDER" | awk '{print $1}')"
  remote_recorder_sha="$(studio_command /usr/bin/shasum -a 256 "$REMOTE_RECORDER" | awk '{print $1}')"
  [ "$recorder_sha" = "$remote_recorder_sha" ] || refuse "Studio recorder source digest mismatch"
  studio_command "$QWEN_E2E_OPENCODE" --version > "$OPS_TMP_DIR/opencode-version.txt"
  python3 - "$OPS_TMP_DIR/opencode-version.txt" <<'PY' ||
import re, sys
values=re.findall(r'(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])', open(sys.argv[1]).read())
raise SystemExit(0 if set(values)=={'1.17.9'} else 3)
PY
    refuse "Studio OpenCode is not exact version 1.17.9"
  BASELINE_PID="$(status_pid "$OPS_TMP_DIR/preflight-status.json")"
  studio_helper prepare --config "$QWEN_E2E_CONFIG" --journal "$QWEN_E2E_JOURNAL" \
    --validator "$QWEN_E2E_CLI" --transaction-id "$transaction_id" \
    --binary-version "$HB_VERSION" --provider-id "$HB_PROVIDER" --cli-sha256 "$HB_SHA" \
    --code-cdhash "$HB_CDHASH" --team-id "$HB_TEAM" --signing-identifier "$HB_IDENTIFIER" \
    --written-handoff-sha256 "$HB_HANDOFF_SHA" --baseline-catalog-version "$LIVE_RELEASE" \
    --baseline-catalog-hash "$LIVE_DIGEST" --baseline-pid "$BASELINE_PID" \
    --rate-card-version "$RATE_VERSION" --remote-scratch "$REMOTE_SCRATCH" >/dev/null
  restart_and_wait "$INCUMBENT_MODEL" "$OPS_TMP_DIR/preflight-status.json" "$OPS_TMP_DIR/prepared-status.json"

  emit_recommendation "$TARGET_ONE_KEY" "$OPS_TMP_DIR/one.recommendation.json"
  verify_local_rate_version "$OPS_TMP_DIR/one.recommendation.json"
  upload_file "$OPS_TMP_DIR/one.recommendation.json" "$REMOTE_REC_ONE"
  verify_remote_recommendation "$TARGET_ONE" "$REMOTE_REC_ONE"
  begin_adoption_remote adopting_first "$TARGET_ONE" "$REMOTE_REC_ONE"
  adopt_recommendation "$REMOTE_REC_ONE" "$OPS_TMP_DIR/one.adoption.jsonl"
  restart_and_wait "$TARGET_ONE_KEY" "$OPS_TMP_DIR/prepared-status.json" "$OPS_TMP_DIR/one.status.json"
  checkpoint_remote serving_first "$TARGET_ONE" "$REMOTE_REC_ONE"
  run_recorder "$TARGET_ONE" "$OPS_TMP_DIR/one.recorder.json" "$evidence_dir/$TARGET_ONE.json"

  emit_recommendation "$TARGET_TWO_KEY" "$OPS_TMP_DIR/two.recommendation.json"
  verify_local_rate_version "$OPS_TMP_DIR/two.recommendation.json"
  upload_file "$OPS_TMP_DIR/two.recommendation.json" "$REMOTE_REC_TWO"
  verify_remote_recommendation "$TARGET_TWO" "$REMOTE_REC_TWO"
  begin_adoption_remote adopting_second "$TARGET_TWO" "$REMOTE_REC_TWO"
  adopt_recommendation "$REMOTE_REC_TWO" "$OPS_TMP_DIR/two.adoption.jsonl"
  restart_and_wait "$TARGET_TWO_KEY" "$OPS_TMP_DIR/one.status.json" "$OPS_TMP_DIR/two.status.json"
  checkpoint_remote serving_second "$TARGET_TWO" "$REMOTE_REC_TWO"
  run_recorder "$TARGET_TWO" "$OPS_TMP_DIR/two.recorder.json" "$evidence_dir/$TARGET_TWO.json"
  checkpoint_remote acceptance_complete "$TARGET_TWO" "$REMOTE_REC_TWO"

  restore_provider
}

run_bind() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse "binding is callable only by next --run"
  [ -n "${QWEN_E2E_HANDBACK:-}" ] && [ -n "${QWEN_E2E_WRITTEN_HANDBACK:-}" ] ||
    refuse "written handoff and binding paths are required"
  written_handoff_sha >/dev/null || refuse "explicit written Studio handback is absent"
  derive_handback "$QWEN_E2E_HANDBACK" || refuse "could not derive the signed running Studio release binding"
  validate_handback || refuse "derived Studio release binding is invalid"
  [ "$(written_handoff_sha "$(handback_field binary_version)")" = "$(handback_field written_handoff_sha256)" ] ||
    refuse "derived binding does not match the written Studio handback"
}

run_restore() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse "restore is callable only by next --run"
  studio_helper inspect --journal "$QWEN_E2E_JOURNAL" > "$OPS_TMP_DIR/journal.json" ||
    refuse "transaction journal is unreadable"
  [ "$(json_field "$OPS_TMP_DIR/journal.json" 'd.get("restore_required")')" = true ] || return 0
  load_journal_context "$OPS_TMP_DIR/journal.json" || refuse "journal has no safe restoration binding"
  if [ "$(json_field "$OPS_TMP_DIR/journal.json" 'd.get("status")')" != restored ]; then
    verify_installed_cli || refuse "installed signed CLI no longer matches the journaled release binding"
    restore_provider
  fi
  remove_remote_scratch || refuse "protected Studio scratch cleanup failed"
}

run_diagnostic() {
  local config="${QWEN_E2E_DIAGNOSTIC_CONFIG:-}" journal="${QWEN_E2E_DIAGNOSTIC_JOURNAL:-}" validator="${QWEN_E2E_DIAGNOSTIC_VALIDATOR:-}"
  [ -n "$config" ] && [ -n "$journal" ] && [ -n "$validator" ] ||
    refuse "diagnostic requires QWEN_E2E_DIAGNOSTIC_CONFIG/JOURNAL/VALIDATOR"
  python3 - "$config" "$journal" "$validator" <<'PY'
import os, stat, sys, tempfile
root=os.path.realpath(tempfile.gettempdir()) + os.sep
for path in sys.argv[1:]:
    real=os.path.realpath(path)
    if not real.startswith(root): raise SystemExit(3)
for path in (sys.argv[1], sys.argv[3]):
    info=os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1: raise SystemExit(3)
PY
  local tx scratch
  tx="diagnostic-$(python3 -c 'import uuid; print(uuid.uuid4())')"
  scratch="$(dirname "$journal")/macprovider-qwen-e2e.$tx"
  mkdir -m 700 "$scratch"
  python3 "$HELPER" prepare --config "$config" --journal "$journal" --validator "$validator" \
    --transaction-id "$tx" --binary-version 0.0.0 --provider-id diagnostic \
    --cli-sha256 "$(printf '%064d' 0)" --code-cdhash "$(printf '%040d' 0)" \
    --team-id diagnostic --signing-identifier diagnostic \
    --written-handoff-sha256 "$(printf '%064d' 0)" \
    --baseline-catalog-version diagnostic --baseline-catalog-hash "$(printf '%064d' 0)" \
    --baseline-pid 1 --rate-card-version diagnostic --remote-scratch "$scratch" >/dev/null
  python3 "$HELPER" restore --config "$config" --journal "$journal" --validator "$validator" >/dev/null
  python3 "$HELPER" finish-restore --config "$config" --journal "$journal" >/dev/null
  rmdir "$scratch"
  log "isolated prepare/restore diagnostic passed; no live acceptance was performed"
}

internal() {
  case "$1" in
    _bind) run_bind ;;
    _campaign) run_campaign ;;
    _restore) run_restore ;;
    *) die "unknown internal command: $1" ;;
  esac
}

case "${1:-status}" in
  diagnostic) shift; [ "$#" = 0 ] || die "diagnostic takes no arguments"; run_diagnostic ;;
  *) ops_main "$@" ;;
esac
