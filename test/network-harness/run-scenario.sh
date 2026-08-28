#!/usr/bin/env bash
# run-scenario.sh — wrapper that resolves the scenario's declared mode,
# gates buyer-token handling on it, ensures the harness binary is built,
# and runs a scenario with a timestamped artifact directory.
#
# Defaults (auto-discovered when env not set, buyer-fleet mode only):
#   BUYER_TOKEN  read from ~/.config/macprovider/buyer-api-key
#
# Pearl SSH uses the `pearl` alias from ~/.ssh/config — no env var needed.
# Provider chaos targets THIS Mac via launchctl — no env var needed.
#
# Optional overrides via env (or .env.harness at repo root, buyer-fleet only):
#   BUYER_TOKEN
#
# Usage:
#   ./run-scenario.sh smoke.yaml
#   ./run-scenario.sh scenarios/smoke.yaml
#   ./run-scenario.sh sku-econ
#
# Exit codes propagate from the harness binary
# (0 ok, 1 runtime, 2 usage, 10 hard-invariant fail).
#
# Mode-detection safety (SEC-M-1 r2 audit): mode is resolved by the harness
# binary itself using the same YAML parser as `harness run`, not by grep/sed.
# For sku-econ scenarios, .env.harness is NEVER sourced and any inherited
# buyer/operator/demo credentials are explicitly unset before the harness
# process starts, so a swapped `target.cli_bin` (or any future code path
# that reads env) cannot exfiltrate them.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
env_file="${repo_root}/.env.harness"

scenario_arg="${1:-}"
if [[ -z "${scenario_arg}" ]]; then
  echo "usage: $0 <scenario.yaml>" >&2
  echo "available:" >&2
  ls "${here}/scenarios/" >&2
  exit 2
fi

if [[ "${scenario_arg}" == "sku-econ" ]]; then
  scenario_path="${here}/scenarios/11_sku_earn_viability.yaml"
elif [[ -f "${here}/scenarios/${scenario_arg}" ]]; then
  scenario_path="${here}/scenarios/${scenario_arg}"
elif [[ -f "${scenario_arg}" ]]; then
  scenario_path="${scenario_arg}"
else
  echo "error: scenario not found: ${scenario_arg}" >&2
  exit 2
fi

# Ensure binary is built before mode probe (cheap; go build is incremental).
( cd "${here}" && go build -o harness ./cmd/harness )

# Snapshot the resolved scenario file to a tempfile so the mode probe and
# the harness run see byte-identical content. Without this, a symlink swap
# or a concurrent editor could let `harness mode` return buyer-fleet (so
# the wrapper sources .env.harness) while the subsequent `harness run`
# loads a sku-econ document. SEC-M-1 (r3 security audit).
scenario_snapshot="$(mktemp -t "run-scenario-snapshot.XXXXXX")"
trap 'rm -f "${scenario_snapshot}"' EXIT
cat "${scenario_path}" > "${scenario_snapshot}"

# Ask the harness itself to parse the snapshot and print its resolved mode.
# Same YAML parser as `harness run`, so we can't fall out of sync.
# `harness mode` uses scenario.ProbeMode which does NOT expand ${VAR} —
# see SEC-M-1 r3 audit for why env expansion at probe time is unsafe.
resolved_mode="$("${here}/harness" mode "${scenario_snapshot}")"
export HARNESS_SCENARIO_ORIGINAL_PATH="${scenario_path}"

case "${resolved_mode}" in
  sku-econ)
    # sku-econ hits only the public-read /v1/rate-card endpoint plus the
    # local CLI. .env.harness is NOT sourced (avoids importing any secret
    # that operator may have parked there), and inherited credentials from
    # the parent shell are explicitly unset. Defense-in-depth alongside the
    # Go runner's cmd.Env = sanitizedEnv() for CLI shell-outs.
    unset BUYER_TOKEN OPERATOR_TOKEN DEMO_IDENTITY
    export HARNESS_SKU_ECON_CLI_BIN="${repo_root}/phase3-binary/.build/release/malibu-cli"
    ;;
  buyer-fleet|"")
    # buyer-fleet path: source local env file if present, then auto-discover
    # BUYER_TOKEN.
    if [[ -f "${env_file}" ]]; then
      # shellcheck disable=SC1090
      set -a; source "${env_file}"; set +a
    fi
    if [[ -z "${BUYER_TOKEN:-}" ]]; then
      if [[ -r "${HOME}/.config/macprovider/buyer-api-key" ]]; then
        BUYER_TOKEN="$(cat "${HOME}/.config/macprovider/buyer-api-key")"
        export BUYER_TOKEN
      else
        echo "error: BUYER_TOKEN not set and ~/.config/macprovider/buyer-api-key not readable" >&2
        exit 2
      fi
    fi
    ;;
  *)
    echo "error: harness mode returned unknown value: ${resolved_mode}" >&2
    exit 1
    ;;
esac

scenario_name="$(basename "${scenario_path}" .yaml)"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${here}/artifacts/${scenario_name}-${ts}"
mkdir -p "${out_dir}"

echo "[run-scenario] scenario=${scenario_path} mode=${resolved_mode:-buyer-fleet}"
echo "[run-scenario] out=${out_dir}"
echo

"${here}/harness" run "${scenario_snapshot}" --out "${out_dir}"
rc=$?

echo
echo "[run-scenario] exit=${rc} artifact_dir=${out_dir}"
exit ${rc}
