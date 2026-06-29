#!/usr/bin/env bash
# run-scenario.sh — wrapper that auto-discovers the local buyer token,
# ensures the harness binary is built, and runs a scenario with a
# timestamped artifact directory.
#
# Defaults (auto-discovered when env not set):
#   BUYER_TOKEN  read from ~/.config/macprovider/buyer-api-key
#
# Pearl SSH uses the `pearl` alias from ~/.ssh/config — no env var needed.
# Provider chaos targets THIS Mac via launchctl — no env var needed.
#
# Optional overrides via env (or .env.harness at repo root):
#   BUYER_TOKEN
#
# Usage:
#   ./run-scenario.sh smoke.yaml
#   ./run-scenario.sh scenarios/smoke.yaml
#
# Exit codes propagate from the harness binary
# (0 ok, 1 runtime, 2 usage, 10 hard-invariant fail).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
env_file="${repo_root}/.env.harness"

if [[ -f "${env_file}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "${env_file}"; set +a
fi

# Auto-discover the buyer token from the canonical config dir if not in env.
if [[ -z "${BUYER_TOKEN:-}" ]]; then
  if [[ -r "${HOME}/.config/macprovider/buyer-api-key" ]]; then
    BUYER_TOKEN="$(cat "${HOME}/.config/macprovider/buyer-api-key")"
    export BUYER_TOKEN
  else
    echo "error: BUYER_TOKEN not set and ~/.config/macprovider/buyer-api-key not readable" >&2
    exit 2
  fi
fi

scenario_arg="${1:-}"
if [[ -z "${scenario_arg}" ]]; then
  echo "usage: $0 <scenario.yaml>" >&2
  echo "available:" >&2
  ls "${here}/scenarios/" >&2
  exit 2
fi

if [[ -f "${here}/scenarios/${scenario_arg}" ]]; then
  scenario_path="${here}/scenarios/${scenario_arg}"
elif [[ -f "${scenario_arg}" ]]; then
  scenario_path="${scenario_arg}"
else
  echo "error: scenario not found: ${scenario_arg}" >&2
  exit 2
fi

# Ensure binary is built (cheap; go build is incremental).
( cd "${here}" && go build -o harness ./cmd/harness )

scenario_name="$(basename "${scenario_path}" .yaml)"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${here}/artifacts/${scenario_name}-${ts}"
mkdir -p "${out_dir}"

echo "[run-scenario] scenario=${scenario_path}"
echo "[run-scenario] out=${out_dir}"
echo

"${here}/harness" run "${scenario_path}" --out "${out_dir}"
rc=$?

echo
echo "[run-scenario] exit=${rc} artifact_dir=${out_dir}"
exit ${rc}
