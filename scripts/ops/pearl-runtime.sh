#!/usr/bin/env bash
# Pearl coordinator/gateway runtime release entry point.
#
# Usage:
#   scripts/ops/pearl-runtime.sh status            read-only; one JSON object on stdout,
#                                                  human summary on stderr
#   scripts/ops/pearl-runtime.sh next              print the next documented step
#   scripts/ops/pearl-runtime.sh next --run        run exactly that one step
#   scripts/ops/pearl-runtime.sh next --done STEP --evidence TEXT
#
# The target tag comes from PEARL_RUNTIME_VERSION (vX.Y.Z). Read the "Consumed
# identities" row of docs/releases/cli-release-train.md before choosing it:
# CLI candidates and Pearl runtime tags share the 1.8.x namespace.
#
# Order (docs/runbooks/pearl-coordinator-rollout.md "Hard rules", "Preflight",
# "Runtime apply"; docs/releases/cli-release-train.md Session protocol):
#   1 code_changed      coordinator/gateway code differs from the live tag (rule 2:
#                       never cut a runtime release to ship tooling only)
#   2 signed_tag        signed annotated tag on origin/main HEAD
#   3 dispatch          pearl-runtime-release.yml on main (one in flight at most)
#   4 env_approval      production-release approval (owner account)
#   5 plan              Pearl preflight + macprovider-pearl-update --plan (read-only)
#   6 apply             systemd-run updater --apply (15-20 min network down)
#   7 wait_updater      bounded wait for the updater unit to exit
#   8 health            coordinator and gateway /healthz report the tag
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, GATEWAY_URL,
# PEARL_SSH, PEARL_RUNTIME_VERSION, UPDATER_WAIT_MAX_S (default 2700),
# MACPROVIDER_OPS_OWNER (for --run).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME/NEXT_* are read by lib/common.sh

OPS_NAME=pearl-runtime
# Every runnable step here touches Pearl (even --plan runs as root there).
OPS_REQUIRE_CLEAN_FOR_ALL=1
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

ROLLOUT_DOC="docs/runbooks/pearl-coordinator-rollout.md"
APPLY_DOWNTIME="15-20 minutes of network down (runtime apply), unless the short-quiesce updater hotfix is installed"


max_remote_tag() {
  git -C "$REPO_ROOT" ls-remote --tags origin 'v*' 2>/dev/null |
    sed -nE 's#.*refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -n1
}

gather() {
  local main_sha live gw_live T
  main_sha="$(origin_main_sha)"
  is_sha40 "$main_sha" || die "cannot resolve origin/main"
  fact origin_main_sha "$main_sha"

  live=""; gw_live=""
  if fetch_coordinator_health; then
    live="$(json_field "$OPS_TMP_DIR/healthz.json" 'd["version"]')"
  fi
  # Versions are validated before they reach a git refspec.
  if [ -n "$live" ] && ! [[ "$live" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fact live_coordinator_version_invalid "$live"
    live=""
  fi
  if [ -n "$(gateway_url)" ] && [ "$(http_get "$(gateway_url)/healthz" "$OPS_TMP_DIR/gw.json")" = "200" ]; then
    gw_live="$(json_field "$OPS_TMP_DIR/gw.json" 'd["version"]')"
  fi
  fact live_coordinator_version "$live"
  fact live_gateway_version "$gw_live"
  local max_tag
  max_tag="$(max_remote_tag)"
  fact highest_remote_tag "v$max_tag"

  local id status concl active="" runs_note=""
  while IFS=$'\t' read -r id status concl _; do
    [ -n "$id" ] || continue
    [ "$status" != "completed" ] && [ -z "$active" ] && active="$id:$status"
    runs_note="$runs_note $id:$status/$concl"
  done <<EOF
$(workflow_runs pearl-runtime-release.yml 5)
EOF
  fact pearl_runtime_release_runs "${runs_note# }"
  fact pearl_runtime_release_active "$active"
  local prod_active
  prod_active="$(production_release_active_runs | tr '\t\n' ': ' | sed 's/ $//')"
  fact production_release_active_runs "$prod_active"

  T="${PEARL_RUNTIME_VERSION:-}"
  if [ -n "$T" ] && ! [[ "$T" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    refuse "PEARL_RUNTIME_VERSION must be vMAJOR.MINOR.PATCH"
  fi
  fact target_version "$T"
  NEXT_RUNBOOK="$ROLLOUT_DOC"

  if [ -z "$live" ]; then
    set_next live_state blocked "Read the live coordinator version" "" "COORDINATOR_URL is unset or /healthz is unreadable"
  fi

  # 1. rule 2: the release must change coordinator/gateway code.
  local ref="origin/main" changed=unknown unknown_why="live coordinator version unreadable"
  if [ -n "$T" ] && remote_tag_exists "$T"; then
    git -C "$REPO_ROOT" fetch -q origin "refs/tags/$T:refs/tags/$T" 2>/dev/null || true
    ref="$T"
  fi
  if [ -n "$live" ]; then
    git -C "$REPO_ROOT" fetch -q origin "refs/tags/$live:refs/tags/$live" 2>/dev/null || true
    if ! git -C "$REPO_ROOT" rev-parse -q --verify "$live^{commit}" >/dev/null; then
      unknown_why="live tag $live is not available locally (fetch failed or tag missing)"
    elif ! git -C "$REPO_ROOT" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
      unknown_why="$ref is not available locally"
    else
      # Tests, fixtures, docs and dist/ deploy tooling do not change the shipped binaries.
      local diff_rc=0
      git -C "$REPO_ROOT" diff --quiet "$live" "$ref" -- phase4-coordinator phase5-gateway \
        ':(exclude)*_test.go' ':(exclude)*/testdata/*' ':(exclude)*.md' \
        ':(exclude)phase4-coordinator/dist/*' ':(exclude)phase5-gateway/dist/*' 2>/dev/null || diff_rc=$?
      case "$diff_rc" in
        0) changed=false ;;
        1) changed=true ;;
        *) unknown_why="git diff $live..$ref failed (rc=$diff_rc)" ;;
      esac
    fi
  fi
  fact code_changed_vs_live "$changed"
  if [ -n "$T" ] && [ "$T" = "$live" ] && [ "$gw_live" = "$T" ]; then
    local s
    for s in code_changed signed_tag dispatch env_approval plan apply wait_updater; do step "$s" "done" ""; done
    step health "done" "coordinator and gateway report $T"
    set_next "done" "done" "$T is live" ""
    return
  fi
  case "$changed" in
    true) step code_changed "done" "$ref changes shipped coordinator/gateway code vs live $live" ;;
    false)
      step code_changed blocked "$ref coordinator/gateway code == live $live"
      set_next code_changed blocked "Cut a runtime release" "" \
        "shipped coordinator/gateway code at $ref is identical to live $live (only tests/docs/dist tooling differ); a runtime apply buys nothing and costs a full outage (rollout rule 2). Fix the tooling instead." ;;
    *)
      step code_changed blocked "$unknown_why"
      set_next code_changed blocked "Compare shipped code with the live runtime" "" \
        "cannot tell whether $ref changes shipped coordinator/gateway code: $unknown_why; refusing to proceed (rollout rule 2)" ;;
  esac

  if [ -z "$T" ]; then
    local suggest
    suggest="v$(python3 -c 'import sys; a=sys.argv[1].split("."); a[2]=str(int(a[2])+1); print(".".join(a))' "${max_tag:-0.0.0}")"
    step signed_tag pending "no PEARL_RUNTIME_VERSION"
    set_next signed_tag blocked "Choose the runtime tag" "PEARL_RUNTIME_VERSION=$suggest $0 status" \
      "set PEARL_RUNTIME_VERSION; $suggest is the next unused tag on origin, confirm it against the Consumed identities row of docs/releases/cli-release-train.md"
    return
  fi
  OPS_SCOPE="pearl-runtime-$T"

  # 2. signed annotated tag on main HEAD.
  if remote_tag_exists "$T"; then
    local ttype signed=false
    ttype="$(git -C "$REPO_ROOT" cat-file -t "$T" 2>/dev/null || true)"
    git -C "$REPO_ROOT" verify-tag "$T" >/dev/null 2>&1 && signed=true
    fact tag_object_type "$ttype"
    fact tag_signature_verified_locally "$signed"
    if [ "$ttype" = tag ]; then
      step signed_tag "done" "$T annotated (local signature check: $signed)"
    else
      step signed_tag blocked "$T is a lightweight tag"
      set_next signed_tag blocked "Signed annotated tag $T" "" "$T exists on origin but is not an annotated tag; tags are immutable, choose the next unused version"
    fi
  else
    step signed_tag pending ""
    if [ "$(semver_cmp "${T#v}" "${max_tag:-0.0.0}")" != "1" ]; then
      set_next signed_tag blocked "Signed annotated tag $T" "" "$T is not above the highest remote tag v$max_tag; consumed tags are never reused"
    else
      set_next signed_tag mutate "Push signed annotated tag $T on origin/main HEAD $main_sha" \
"git tag -s -a $T -m 'Pearl runtime $T' $main_sha
git push origin refs/tags/$T"
    fi
  fi

  # 3-4. dispatch and approval.
  local rel_assets
  rel_assets="$(gh release view "$T" -R "$(gh_repo)" --json assets --jq '[.assets[].name] | join(" ")' 2>/dev/null || true)"
  local has_release=false
  [[ " $rel_assets " == *" pearl-release.json "* ]] && has_release=true
  fact release_assets_present "$has_release"
  case "$has_release" in
    true)
      step dispatch "done" "release $T carries pearl-release.json"
      step env_approval "done" "" ;;
    *)
      if [ -n "$active" ]; then
        step dispatch in_progress "run $active"
        case "$active" in
          *:waiting)
            step env_approval pending "run ${active%%:*} waits on production-release"
            set_next env_approval manual "Approve production-release for runtime run ${active%%:*} (owner account)" \
              "gh run view ${active%%:*} -R $(gh_repo)   # approve the pending deployment from the owner account" ;;
          *)
            set_next dispatch blocked "Wait for runtime run ${active%%:*}" "gh run watch ${active%%:*} -R $(gh_repo)" \
              "pearl-runtime-release run $active is in flight; refusing a second dispatch" ;;
        esac
      else
        step dispatch pending ""
        step env_approval pending ""
        if [ -n "$prod_active" ]; then
          set_next dispatch blocked "Dispatch pearl-runtime-release $T" "" \
            "production-release group busy (a waiting discovery-head renewal blocks it until approved): $prod_active"
        else
          set_next dispatch mutate "Dispatch pearl-runtime-release.yml for $T on main" \
            "gh workflow run pearl-runtime-release.yml -R $(gh_repo) --ref main -f version=$T -f prerelease=true"
        fi
      fi ;;
  esac

  # 5. preflight + plan (read-only on Pearl).
  local plan_fresh=false
  if marker_done "$OPS_SCOPE" plan &&
    [ -n "$(find "$(marker_path "$OPS_SCOPE" plan)" -mmin -120 2>/dev/null)" ]; then
    plan_fresh=true
  fi
  if marker_done "$OPS_SCOPE" apply; then
    step plan "done" ""
  elif [ "$plan_fresh" = true ]; then
    step plan "done" "plan within the last 2 h"
  else
    step plan pending ""
    if [ -z "${PEARL_SSH:-}" ]; then
      set_next plan blocked "Preflight and plan on Pearl" "" "PEARL_SSH is unset"
    elif [ -z "$NEXT_ID" ]; then
      # Rendered only when this is the next step; a render failure aborts gather.
      local preflight_cmd
      preflight_cmd="$(render_runbook "$RB_PEARL_PREFLIGHT")"
      set_next plan read "Pearl preflight and updater --plan for $T (read-only)" \
"$preflight_cmd
ssh \"\$PEARL_SSH\" 'for l in /run/lock/macprovider-pearl-updater.lock /opt/macprovider/.coordinator-deploy.lock; do flock -n \$l true || { echo \"lock busy: \$l\" >&2; exit 1; }; done'
ssh \"\$PEARL_SSH\" '/usr/local/sbin/macprovider-pearl-update --plan --tag $T'"
      next_meta plan "$ROLLOUT_DOC#preflight-every-time" "" plan
    fi
  fi

  # 6. apply. A recorded apply whose updater unit failed while the live
  # version stayed behind was rolled back by the updater: offer it again
  # (after resetting the failed transient unit, which blocks systemd-run).
  local apply_rolled_back=false
  if marker_done "$OPS_SCOPE" apply && [ "$live" != "$T" ] && [ -n "${PEARL_SSH:-}" ] &&
    ssh "$PEARL_SSH" "systemctl is-failed --quiet mp-update-${T#v}" 2>/dev/null; then
    apply_rolled_back=true
    rm -f "$(marker_path "$OPS_SCOPE" apply)"
  fi
  if marker_done "$OPS_SCOPE" apply; then
    step apply "done" "$(marker_field "$OPS_SCOPE" apply 'd.get("recorded_at")')"
  else
    if [ "$apply_rolled_back" = true ]; then
      step apply pending "previous apply of $T failed and was rolled back; read its journal first (runbook rule 4)"
    else
      step apply pending ""
    fi
    if [ -z "$NEXT_ID" ]; then
      local apply_cmd
      apply_cmd="$(render_runbook "$RB_PEARL_APPLY" "${T#v}")"
      if [ "$apply_rolled_back" = true ]; then
        apply_cmd="ssh \"\$PEARL_SSH\" 'systemctl reset-failed mp-update-${T#v}'
$apply_cmd"
      fi
      set_next apply mutate "Apply runtime $T with the signed updater" "$apply_cmd"
    fi
    next_meta apply "$ROLLOUT_DOC#runtime-apply-signed-updater" "$APPLY_DOWNTIME" apply
  fi

  # 7. bounded wait for the transient updater unit.
  if [ "$live" = "$T" ]; then
    step wait_updater "done" "coordinator reports $T"
  else
    step wait_updater pending ""
    set_next wait_updater read "Wait (bounded) for updater unit mp-update-${T#v} to exit" \
"deadline=\$((\$(date +%s) + \${UPDATER_WAIT_MAX_S:-2700}))
while ssh \"\$PEARL_SSH\" 'systemctl is-active --quiet mp-update-${T#v}'; do
  [ \"\$(date +%s)\" -lt \"\$deadline\" ] || { echo 'updater still running at the deadline; inspect, do not retry' >&2; exit 1; }
  sleep 30
done
ssh \"\$PEARL_SSH\" 'systemctl show mp-update-${T#v} -p Result -p ExecMainStatus --no-pager || true; journalctl -u mp-update-${T#v} -n 40 --no-pager || true'"
  fi

  # 8. health.
  step health pending "coordinator=$live gateway=$gw_live"
  set_next health read "Check coordinator and gateway health report $T" \
"curl -sf \"\$COORDINATOR_URL/healthz\"; echo
curl -sf \"\$GATEWAY_URL/healthz\"; echo
curl -sf \"\$COORDINATOR_URL/healthz\" | grep -q '\"version\":\"$T\"'
curl -sf \"\$GATEWAY_URL/healthz\" | grep -q '\"version\":\"$T\"'"
}

internal() { usage >&2; exit 2; }

ops_main "$@"
