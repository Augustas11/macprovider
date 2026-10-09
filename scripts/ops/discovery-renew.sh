#!/usr/bin/env bash
# Signed release-discovery renewal entry point.
#
# Usage:
#   scripts/ops/discovery-renew.sh status          read-only; one JSON object on stdout,
#                                                  human summary on stderr
#   scripts/ops/discovery-renew.sh next            print the next documented step
#   scripts/ops/discovery-renew.sh next --run      dispatch exactly one renewal run
#
# Order:
#   1 dispatch       renew-release-discovery-head.yml on main with the required
#                    168h validity window
#   2 env_approval   production-release approval (owner account)
#
# Env (or ~/.config/macprovider/ops.env): MACPROVIDER_OPS_OWNER (for --run),
# MACPROVIDER_DISCOVERY_RENEWAL_VALIDITY_HOURS (optional, must be 168).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME/NEXT_* are read by lib/common.sh

OPS_NAME=discovery-renew
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

DISCOVERY_WORKFLOW="renew-release-discovery-head.yml"
DISCOVERY_VALIDITY_HOURS="${MACPROVIDER_DISCOVERY_RENEWAL_VALIDITY_HOURS:-168}"

validate_validity() {
  [ "$DISCOVERY_VALIDITY_HOURS" = 168 ] ||
    refuse "MACPROVIDER_DISCOVERY_RENEWAL_VALIDITY_HOURS must be 168"
}

gather() {
  validate_validity
  local main_sha head_sha active="" prod_active=""
  main_sha="$(origin_main_sha)"
  is_sha40 "$main_sha" || die "cannot resolve origin/main"
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  OPS_SCOPE="discovery-renew"
  fact origin_main_sha "$main_sha"
  fact checkout_is_origin_main "$([ "$head_sha" = "$main_sha" ] && echo true || echo false)"
  fact validity_hours "$DISCOVERY_VALIDITY_HOURS"

  local id status concl sha created
  while IFS=$'\t' read -r id status concl sha created; do
    [ -n "$id" ] || continue
    [ "$status" != "completed" ] && [ -z "$active" ] && active="$id:$status"
  done <<EOF
$(workflow_runs "$DISCOVERY_WORKFLOW" 10)
EOF
  fact renewal_run_active "$active"
  prod_active="$(production_release_active_runs | tr '\t\n' ': ' | sed 's/ $//')"
  fact production_release_active_runs "$prod_active"

  NEXT_RUNBOOK=".github/workflows/$DISCOVERY_WORKFLOW"
  if [ -n "$active" ]; then
    step dispatch in_progress "$active"
    if [ "${active#*:}" = "waiting" ]; then
      step env_approval pending "run ${active%%:*} waits on production-release"
      set_next env_approval manual "Approve production-release for discovery renewal run ${active%%:*}" \
        "gh run view ${active%%:*} -R $(gh_repo)   # approve from the owner account"
    else
      step env_approval pending "$active"
      set_next dispatch blocked "Wait for discovery renewal run ${active%%:*}" \
        "gh run watch ${active%%:*} -R $(gh_repo)" \
        "discovery renewal run $active is in flight; refusing a second dispatch"
    fi
    return
  fi

  step dispatch pending ""
  step env_approval pending ""
  if [ -n "$prod_active" ]; then
    set_next dispatch blocked "Dispatch signed release-discovery renewal" "" \
      "production-release group busy: $prod_active"
  else
    set_next dispatch mutate "Dispatch signed release-discovery renewal" \
      "gh workflow run $DISCOVERY_WORKFLOW -R $(gh_repo) --ref main -f validity_hours=$DISCOVERY_VALIDITY_HOURS"
  fi
}

ops_main "$@"
