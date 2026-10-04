#!/usr/bin/env bash
# Run the signed spike app and the ad-hoc copies in this user session.
# Apps are launched through LaunchServices (`open`) by default because App
# Attest on macOS only serves a full app launched in the user's GUI session;
# --launch exec runs the executable directly for comparison.
# Collect one result JSON per combination. When a Go verifier is available,
# check attestations. A signed-app attestation that fails verification is a
# non-zero exit. An ad-hoc app that produces no attestation, or whose
# attestation fails verification, is the expected refusal.
set +x
set -euo pipefail

die() {
  printf 'run-on-target: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: run-on-target.sh --app APP --adhoc-app APP --child BIN --adhoc-child BIN --out DIR
         [--adhoc-noent-app APP] [--team TEAMID] [--bundle ID]
         [--env production|development] [--acl require|record]
         [--launch open|exec] [--verifier PATH]
EOF
  exit 2
}

app=""
adhoc_app=""
noent_app=""
child=""
adhoc_child=""
out=""
team="${TEAM_ID:-}"
bundle="${BUNDLE_ID:-tech.malibu.app}"
environment="${ATTEST_ENV:-production}"
verifier="${VERIFIER:-}"
acl="${ATTEST_ACL:-require}"
launch="open"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    --adhoc-app) adhoc_app="${2:-}"; shift 2 ;;
    --adhoc-noent-app) noent_app="${2:-}"; shift 2 ;;
    --acl) acl="${2:-}"; shift 2 ;;
    --launch) launch="${2:-}"; shift 2 ;;
    --child) child="${2:-}"; shift 2 ;;
    --adhoc-child) adhoc_child="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --team) team="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --env) environment="${2:-}"; shift 2 ;;
    --verifier) verifier="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$app" && -n "$adhoc_app" && -n "$child" && -n "$adhoc_child" && -n "$out" ]] || usage
[[ "$environment" == "production" || "$environment" == "development" ]] || die "--env must be production or development"
[[ "$acl" == "require" || "$acl" == "record" ]] || die "--acl must be require or record"
[[ "$launch" == "open" || "$launch" == "exec" ]] || die "--launch must be open or exec"
[[ -z "$noent_app" || -d "$noent_app" ]] || die "--adhoc-noent-app must be a bundle"
[[ -d "$app" && -d "$adhoc_app" ]] || die "app paths must be bundles"
[[ -f "$child" && -x "$child" && -f "$adhoc_child" && -x "$adhoc_child" ]] || die "child paths must be executable files"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

script_dir="$(cd "$(dirname "$0")" && pwd)"
verifier_dir="$(cd "$script_dir/../verifier" && pwd)"
if [[ -z "$verifier" && -x "$script_dir/../out/appattest-verify" ]]; then
  verifier="$(cd "$script_dir/../out" && pwd)/appattest-verify"
fi

have_verifier=0
if [[ -n "$verifier" ]]; then
  [[ -x "$verifier" ]] || die "--verifier is not executable"
  have_verifier=1
elif command -v go >/dev/null 2>&1; then
  have_verifier=1
fi

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    value = json.load(handle).get(sys.argv[2])
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

abs_path() {
  local dir base
  dir="$(cd "$(dirname "$1")" && pwd)"
  base="$(basename "$1")"
  printf '%s/%s\n' "$dir" "$base"
}

app="$(abs_path "$app")"
adhoc_app="$(abs_path "$adhoc_app")"
app_bin="$app/Contents/MacOS/MalibuAttestSpike"
adhoc_bin="$adhoc_app/Contents/MacOS/MalibuAttestSpike"
if [[ -n "$noent_app" ]]; then
  noent_app="$(abs_path "$noent_app")"
  [[ -x "$noent_app/Contents/MacOS/MalibuAttestSpike" ]] || die "no-entitlement app executable is missing"
fi
child="$(abs_path "$child")"
adhoc_child="$(abs_path "$adhoc_child")"
[[ -x "$app_bin" && -x "$adhoc_bin" ]] || die "MalibuAttestSpike executable is missing"

# verify-assertion re-runs the attestation checks, so its output alone carries
# the full report (aclBlob dumps included).
run_verify() {
  local result="$1"
  if [[ -n "$verifier" ]]; then
    "$verifier" verify-attestation --result "$result" --team "$team" --bundle "$bundle" --env "$environment" --acl "$acl"
    "$verifier" verify-assertion --result "$result" --team "$team" --bundle "$bundle" --env "$environment" --acl "$acl"
  else
    (cd "$verifier_dir" && go run . verify-attestation --result "$result" --team "$team" --bundle "$bundle" --env "$environment" --acl "$acl")
    (cd "$verifier_dir" && go run . verify-assertion --result "$result" --team "$team" --bundle "$bundle" --env "$environment" --acl "$acl")
  fi
}

failures=0
manifest="$out/manifest.tsv"
: > "$manifest"

# Launch one app bundle and wait up to 300 s for it to exit. `open -W -n`
# starts a fresh instance through LaunchServices with the given environment;
# on timeout the instance is killed by its executable path.
launch_app() {
  local bundle="$1"
  local result="$2"
  local child_path="$3"
  python3 - "$launch" "$bundle" "$result" "$child_path" <<'PY'
import os
import signal
import subprocess
import sys

mode, bundle, result, child = sys.argv[1:5]
binary = os.path.join(bundle, "Contents", "MacOS", "MalibuAttestSpike")
if mode == "exec":
    env = dict(os.environ, SPIKE_RESULT_PATH=result, SPIKE_CHILD_PATH=child)
    signal.alarm(300)
    os.execve(binary, [binary], env)
cmd = [
    "open", "-W", "-n",
    "--env", "SPIKE_RESULT_PATH=" + result,
    "--env", "SPIKE_CHILD_PATH=" + child,
    bundle,
]
try:
    sys.exit(subprocess.run(cmd, timeout=300).returncode)
except subprocess.TimeoutExpired:
    subprocess.run(["pkill", "-KILL", "-f", binary])
    print("launch timed out after 300 s", file=sys.stderr)
    sys.exit(124)
PY
}

run_case() {
  local name="$1"
  local bundle_path="$2"
  local child_path="$3"
  local expect="$4"
  local result="$out/$name.json"
  rm -f "$result"
  local status=0
  launch_app "$bundle_path" "$result" "$child_path" || status=$?
  local wrote=0
  if [[ -s "$result" ]]; then
    wrote=1
  fi
  printf '%s\texit=%s\twrote=%s\n' "$name" "$status" "$wrote" >> "$manifest"
  echo "case $name exit=$status result_written=$wrote"

  if [[ "$wrote" -ne 1 ]]; then
    if [[ "$expect" == "signed" ]]; then
      echo "signed app did not write $result" >&2
      failures=1
    else
      echo "ad-hoc app wrote no result; treating that as a refusal"
    fi
    return
  fi

  local supported attest child_pass
  supported="$(json_field "$result" is_supported)"
  attest="$(json_field "$result" attestation_b64)"
  child_pass="$(python3 - "$result" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    child = json.load(handle).get("child") or {}
value = child.get("pass")
print("true" if value is True else "false" if value is False else "")
PY
)"

  if [[ "$expect" == "signed" && "$child_path" == "$child" && "$child_pass" != "true" ]]; then
    echo "Developer ID child check did not pass in $name" >&2
    failures=1
  fi
  if [[ "$expect" == "signed" && "$child_path" == "$adhoc_child" && "$child_pass" != "false" ]]; then
    echo "ad-hoc child check did not fail in $name" >&2
    failures=1
  fi

  if [[ -z "$attest" ]]; then
    if [[ "$expect" == "signed" && "$supported" == "true" ]]; then
      echo "signed app is supported but wrote no attestation" >&2
      failures=1
    elif [[ "$expect" == "signed" ]]; then
      echo "signed app is_supported=$supported; pass criterion 1 needs true" >&2
      failures=1
    else
      echo "ad-hoc app wrote no attestation"
    fi
    return
  fi

  if [[ "$have_verifier" -ne 1 ]]; then
    echo "attestation is present but no verifier is available" >&2
    if [[ "$expect" == "signed" ]]; then
      failures=1
    fi
    return
  fi
  if [[ -z "$team" ]]; then
    echo "--team is required to verify $name" >&2
    failures=1
    return
  fi

  local verify_status=0
  run_verify "$result" > "$out/$name.verify.txt" 2>&1 || verify_status=$?
  cat "$out/$name.verify.txt"
  if [[ "$expect" == "signed" && "$verify_status" -ne 0 ]]; then
    echo "signed attestation failed verification ($name)" >&2
    failures=1
  elif [[ "$expect" == "adhoc" && "$verify_status" -eq 0 ]]; then
    echo "ad-hoc app produced an attestation the verifier accepted" >&2
    failures=1
  elif [[ "$expect" == "adhoc" ]]; then
    echo "ad-hoc attestation was refused by the verifier"
  else
    echo "signed attestation verified ($name)"
  fi
}

run_case "signed-app-devid-child" "$app" "$child" signed
run_case "signed-app-adhoc-child" "$app" "$adhoc_child" signed
run_case "adhoc-app-devid-child" "$adhoc_app" "$child" adhoc
if [[ -n "$noent_app" ]]; then
  run_case "adhoc-noent-app-devid-child" "$noent_app" "$child" adhoc
fi

echo "results: $out"
if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
