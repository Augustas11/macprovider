#!/usr/bin/env bash
# Provider CLI release train entry point.
#
# Usage:
#   scripts/ops/cli-release.sh status              read-only; one JSON object on stdout,
#                                                  human summary on stderr
#   scripts/ops/cli-release.sh next                print the next documented step
#   scripts/ops/cli-release.sh next --run          run exactly that one step
#   scripts/ops/cli-release.sh next --done STEP --evidence TEXT
#                                                  record an operator-owned step as done
#
# Order (docs/releases/cli-release-train.md "Promotion gate" and "Core rule",
# docs/runbooks/provider-cli-release-verification.md):
#   1 version_alignment     checked-in latest_binary_version rows == live stable,
#                           binaryVersion on main > live stable
#   2 candidate_cut         acceptance-candidate.yml on the exact origin/main SHA,
#                           promotion_ready=true, strict_post_migration
#   3 candidate_env_approval  production-release approval (owner account)
#   4 signed_byte_verification  checksums, pearl-release.json signature,
#                           codesign CDHash/Team/Identifier vs provider_code_identity,
#                           verify-malibu-release-artifacts.sh
#   4a privacy_release_setup  one-time Pearl setup of privacy_class.release_code_identities
#                           (next --run: _pearl-config edit + restart, sharing the restart with
#                           step 5 when due, then stages 4b); done while Pearl's config names it
#   4b privacy_release_identity  copy the verified candidate pearl-release.json + .sig to
#                           Pearl's privacy_class.release_code_identities.metadata_dir as
#                           v<ver>.json/.sig (hot: re-read every ~60 s, no restart)
#   5 pearl_accepted_ids    next --run: _pearl-config adds the candidate compatibility_set_id
#                           (keep target_id; at the cap of 8 evict the oldest version that is not
#                           the target, not the previous stable, and not the latest connection
#                           version of any provider seen in 14 days) and restarts; done when the
#                           running coordinator's applied config lists it
#   6 canary_smoke          exact signed-candidate install/join smoke; recorded only with
#                           structured evidence: `next --done canary_smoke --probe` (the script
#                           reads the canary's /v1/status over STUDIO_SSH: binary_version ==
#                           candidate, coordinator.connected, candidate compatibility set,
#                           CB active, live_verified, authorized, local proof passed, paged KV attached,
#                           then sends one provider-attributed buyer request through the gateway;
#                           refused when Pearl's journal shows the canary's privacy advertisement
#                           rejected as posture_unapproved_code_identity in the last 10 minutes,
#                           or when the running coordinator does not hold the registrations of 7a)
#   7 e2e_gate              in-scope e2e green on the candidate (Promotion gate item 3):
#                           `next --done e2e_gate --run-id N [--run-id M ...]` (each a successful
#                           promote-signed-*-journey run whose head SHA, title or log names the
#                           candidate SHA or tag) or `--carry-forward ID` (a carry-forward record
#                           in docs/releases/cli-release-train.md naming the candidate version)
#   7a registrations        read-only gate over PEARL_SSH, on every status (it also gates 8 and
#                           9): the running coordinator holds the candidate compatibility_set_id
#                           in accepted_ids (on-disk config sha256 == its boot
#                           coordinator_config_applied digests), privacy_class is enabled, and
#                           the code_cdhash is approved by a verifying v<ver>.json it reports as
#                           loaded (relayblind_privacy_release_identity_loaded) or by an
#                           approved_code_identities entry in that applied config
#   7a2 release_tag         signed annotated tag v<ver> on the candidate SHA, pushed to origin
#                           (promote-acceptance-candidate.yml requires it); signed with the
#                           operator's git signing key, checked with git verify-tag; an existing
#                           tag counts only if its exact remote object verifies; refused when
#                           v<ver> exists unsigned/untrusted, on another commit, or lightweight
#   7b promotion            promote-acceptance-candidate.yml (+ env approval); only this step
#                           sets physical_acceptance_confirmed=true, after 4, 6, 7, 7a and 7a2
#   8 recommendation_bump   next --run: _pearl-config sets latest_binary_version and
#                           compatibility_set.target_id (prior target stays accepted), restarts,
#                           and checks /healthz recommended_binary_version
#   9 verify_live_rollout   _check-privacy-rejections (two samples of the
#                           posture_unapproved_code_identity counter over
#                           PRIVACY_REJECTION_WINDOW_SECONDS, default 180; journal fallback),
#                           then verify-live-coordinator-release-rollout.yml
#  10 install_sh_republish  get-channel install.sh == released dist/install.sh
#  11 install_sh_consumer_health
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, INSTALL_SH_URL,
# PEARL_SSH, INSTALL_SH_REMOTE_PATH, MACPROVIDER_OPS_OWNER (for --run).
# Pearl paths default to the production layout: PEARL_COORDINATOR_CONFIG,
# PEARL_COORDINATOR_OVERLAY, PEARL_COORDINATOR_UNIT, PEARL_COORDINATOR_METRICS_URL,
# PEARL_RELEASE_IDENTITY_OWNER, PEARL_RELEASE_IDENTITY_GROUP.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME/NEXT_* are read by lib/common.sh
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPS_NAME=cli-release
# Free-text --done is refused for these; see structured_done.
STRUCTURED_STEPS="canary_smoke e2e_gate"
# shellcheck source=lib/common.sh
. "$OPS_DIR/lib/common.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

TRAIN_DOC="docs/releases/cli-release-train.md"
VERIFY_DOC="docs/runbooks/provider-cli-release-verification.md"
ROLLOUT_DOC="docs/runbooks/pearl-coordinator-rollout.md"
PRIVACY_DOC="docs/runbooks/privacy-class-beta-operations.md"

PEARL_COORDINATOR_CONFIG="${PEARL_COORDINATOR_CONFIG:-/opt/macprovider/coordinator.yaml}"
PEARL_COORDINATOR_OVERLAY="${PEARL_COORDINATOR_OVERLAY:-/etc/macprovider/coordinator.pearl-overlays.yaml}"
PEARL_COORDINATOR_UNIT="${PEARL_COORDINATOR_UNIT:-macprovider-coordinator}"
PEARL_COORDINATOR_METRICS_URL="${PEARL_COORDINATOR_METRICS_URL:-http://127.0.0.1:8444/metrics}"
PEARL_RELEASE_IDENTITY_OWNER="${PEARL_RELEASE_IDENTITY_OWNER:-root}"
PEARL_RELEASE_IDENTITY_GROUP="${PEARL_RELEASE_IDENTITY_GROUP:-macprovider}"

# registrations_remote ARGS...: run lib/release-registrations.py on Pearl
# (the script travels on stdin). Every argument must be shell-safe.
registrations_remote() {
  local a
  for a in "$@"; do
    [[ "$a" =~ ^[A-Za-z0-9_./:@+=-]+$ ]] || die "unsafe argument for the Pearl registrations helper: $a"
  done
  pearl_ssh "python3 - $*" < "$OPS_LIB_DIR/release-registrations.py"
}

# Pearl layout for the coordinator.yaml edits (defaults: production).
PEARL_INSTALL_ROOT="${PEARL_INSTALL_ROOT:-/opt/macprovider}"
PEARL_CONFIG_GUARD="${PEARL_CONFIG_GUARD:-/usr/local/share/macprovider/scripts/coordinator_config_guard.py}"
PEARL_UPDATER_LOCK="${PEARL_UPDATER_LOCK:-/run/lock/macprovider-pearl-updater.lock}"
PEARL_CONNECTION_EVENTS_DB="${PEARL_CONNECTION_EVENTS_DB:-/var/lib/macprovider/provider_connection_events.db}"
PEARL_BACKUP_ROOT="${PEARL_BACKUP_ROOT:-/root/macprovider-backups}"
PEARL_COORDINATOR_HEALTHZ_URL="${PEARL_COORDINATOR_HEALTHZ_URL:-http://127.0.0.1:8443/healthz}"
PEARL_PROC_ROOT="${PEARL_PROC_ROOT:-/proc}"
PRIVACY_METADATA_DIR="${PEARL_PRIVACY_METADATA_DIR:-/opt/macprovider/privacy-release-identities}"
PRIVACY_PUBLIC_KEY_PATH="${PEARL_RELEASE_PUBLIC_KEY_PATH:-/usr/local/share/macprovider/release-signing-public.pem}"

# _pearl-config ARGS...: the train's coordinator.yaml edits plus one restart,
# by lib/pearl-cli-config.py on Pearl (both Pearl locks, anchored edit,
# backup, validation with the running coordinator's environment, restart,
# /healthz, postconditions). Only `next --run` may call it: it holds the
# live-ops lock and has printed the downtime banner.
pearl_config() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] ||
    refuse "_pearl-config runs only from '$0 next --run' (live-ops lock, downtime banner)"
  require_pearl_ssh
  local a guard_sha
  guard_sha="$(shasum -a 256 "$REPO_ROOT/scripts/lib/coordinator_config_guard.py" | awk '{print $1}')"
  for a in "$@" "$PEARL_COORDINATOR_CONFIG" "$PEARL_COORDINATOR_OVERLAY" "$PEARL_COORDINATOR_UNIT" \
    "$PEARL_INSTALL_ROOT" "$PEARL_CONFIG_GUARD" "$PEARL_UPDATER_LOCK" "$PEARL_CONNECTION_EVENTS_DB" \
    "$PEARL_BACKUP_ROOT" "$PEARL_COORDINATOR_HEALTHZ_URL" "$PEARL_PROC_ROOT"; do
    [[ "$a" =~ ^[A-Za-z0-9_./:@+=-]+$ ]] || die "unsafe argument for the Pearl config helper: $a"
  done
  pearl_ssh "python3 - apply --config $PEARL_COORDINATOR_CONFIG --overlay $PEARL_COORDINATOR_OVERLAY \
--unit $PEARL_COORDINATOR_UNIT --install-root $PEARL_INSTALL_ROOT --guard $PEARL_CONFIG_GUARD \
--guard-sha256 $guard_sha --updater-lock $PEARL_UPDATER_LOCK --events-db $PEARL_CONNECTION_EVENTS_DB \
--backup-root $PEARL_BACKUP_ROOT --healthz $PEARL_COORDINATOR_HEALTHZ_URL --proc $PEARL_PROC_ROOT $*" \
    < "$OPS_LIB_DIR/pearl-cli-config.py"
}

# candidate_release_bytes V -> 'PRJ<TAB>SIG' of the verified candidate, or nothing.
candidate_release_bytes() {
  local dir prj sig
  dir="$(marker_field "cli-release-$1" signed_byte_verification 'd.get("bytes_dir")')"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  prj="$(find "$dir" -type f -name pearl-release.json | head -n1)"
  sig="$(find "$dir" -type f -name pearl-release.json.sig | head -n1)"
  [ -n "$prj" ] && [ -n "$sig" ] && printf '%s\t%s\n' "$prj" "$sig"
}

# load_registrations V COMPAT_ID: read Pearl's registration state (read-only)
# into REG_STATE (unknown|unconfigured|missing|present|mismatch|staged),
# REG_DIR, REG_BY, REG_MISSING and REG_ERR.
load_registrations() {
  local V="$1" compat="$2" bytes prj="" sig=""
  REG_STATE=unknown; REG_DIR=""; REG_BY=""; REG_MISSING=""; REG_ERR=""; REG_COMPAT_ACCEPTED=false
  if [ -z "${PEARL_SSH:-}" ]; then
    REG_ERR="PEARL_SSH is unset"
  elif ! registrations_remote facts "$PEARL_COORDINATOR_CONFIG" "$PEARL_COORDINATOR_OVERLAY" \
    "$PEARL_COORDINATOR_UNIT" "$V" "$PEARL_COORDINATOR_METRICS_URL" > "$OPS_TMP_DIR/reg-facts.json" 2> "$OPS_TMP_DIR/reg-facts.err"; then
    REG_ERR="Pearl coordinator config unreadable: $(tail -n1 "$OPS_TMP_DIR/reg-facts.err")"
  else
    bytes="$(candidate_release_bytes "$V")"
    if [ -n "$bytes" ]; then prj="${bytes%%$'\t'*}"; sig="${bytes#*$'\t'}"; fi
    if python3 "$OPS_LIB_DIR/release-registrations.py" evaluate "$OPS_TMP_DIR/reg-facts.json" "$V" \
      "${compat:-}" "${prj:-}" "${sig:-}" > "$OPS_TMP_DIR/reg-verdict.json" 2> "$OPS_TMP_DIR/reg-verdict.err"; then
      REG_DIR="$(json_field "$OPS_TMP_DIR/reg-facts.json" 'd["metadata_dir"]')"
      REG_STATE="$(json_field "$OPS_TMP_DIR/reg-verdict.json" 'd["metadata_state"]')"
      REG_BY="$(json_field "$OPS_TMP_DIR/reg-verdict.json" 'd.get("approved_by")')"
      REG_MISSING="$(json_field "$OPS_TMP_DIR/reg-verdict.json" '"; ".join(d["missing"])')"
      REG_COMPAT_ACCEPTED="$(json_field "$OPS_TMP_DIR/reg-verdict.json" 'd.get("compat_accepted", False)')"
    else
      REG_ERR="registration evaluation failed: $(tail -n1 "$OPS_TMP_DIR/reg-verdict.err")"
    fi
  fi
  if [ "$REG_STATE" = unknown ]; then
    fact privacy_release_metadata_dir "unknown: $REG_ERR"
  else
    fact privacy_release_metadata_dir "${REG_DIR:-unset}"
  fi
  fact privacy_release_identity "$REG_STATE"
}

# checked_in_recommendation REV -> the one latest_binary_version shared by the
# three coordinator configs at REV, or "MISMATCH"/"" (release-staged-version-policy.sh rules).
checked_in_recommendation() {
  local rev="$1" f row first=""
  for f in phase4-coordinator/dist/coordinator.yaml phase4-coordinator/coordinator.yaml.example \
    phase4-coordinator/dist/coordinator.yaml.example; do
    row="$(git -C "$REPO_ROOT" show "$rev:$f" 2>/dev/null |
      sed -nE 's/^[[:space:]]*latest_binary_version:[[:space:]]*"([^"]+)".*$/\1/p')"
    [ "$(printf '%s\n' "$row" | awk 'NF{c++} END{print c+0}')" = "1" ] || { printf 'MISMATCH'; return; }
    if [ -z "$first" ]; then first="$row"; elif [ "$row" != "$first" ]; then printf 'MISMATCH'; return; fi
  done
  printf '%s' "$first"
}

gather() {
  local main_sha head_sha V A L runtime
  main_sha="$(origin_main_sha)"
  is_sha40 "$main_sha" || die "cannot resolve origin/main"
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  V="$(binary_version_at "$main_sha")"
  is_semver "$V" || die "cannot read binaryVersion at origin/main"
  A="$(checked_in_recommendation "$main_sha")"
  OPS_SCOPE="cli-release-$V"
  fact origin_main_sha "$main_sha"
  fact checkout_is_origin_main "$([ "$head_sha" = "$main_sha" ] && echo true || echo false)"
  fact binary_version "$V"
  fact checked_in_latest_binary_version "$A"

  L=""; runtime=""
  if fetch_coordinator_health; then
    L="$(json_field "$OPS_TMP_DIR/healthz.json" 'd["recommended_binary_version"]')"
    runtime="$(json_field "$OPS_TMP_DIR/healthz.json" 'd["version"]')"
  fi
  fact live_recommended_binary_version "$L"
  fact live_runtime_version "$runtime"
  # /healthz does not expose compatibility_set.target_id; it is read from the
  # coordinator's applied config on Pearl when PEARL_SSH is set and allowed.
  fact live_compatibility_target "not exposed by /healthz (read applied config on Pearl)"

  local latest_stable published=false pub_at=""
  latest_stable="$(gh release list -R "$(gh_repo)" --exclude-pre-releases --exclude-drafts -L 1 \
    --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
  fact latest_stable_github_release "$latest_stable"
  pub_at="$(gh release view "v$V" -R "$(gh_repo)" --json isPrerelease,isDraft,publishedAt \
    --jq 'select(.isPrerelease == false and .isDraft == false) | .publishedAt' 2>/dev/null || true)"
  [ -n "$pub_at" ] && published=true
  fact release_published "$published"
  fact release_published_at "$pub_at"
  fact tag_exists_on_origin "$(remote_tag_exists "v$V" && echo true || echo false)"

  # Acceptance runs whose control commit carries binaryVersion V.
  local id status concl sha created active_id="" active_status="" ok_id="" ok_sha=""
  while IFS=$'\t' read -r id status concl sha created; do
    [ -n "$id" ] || continue
    [ "$(binary_version_at "$sha")" = "$V" ] || continue
    if [ "$status" != "completed" ]; then
      [ -n "$active_id" ] || { active_id="$id"; active_status="$status"; }
    elif [ "$concl" = "success" ] && [ -z "$ok_id" ]; then
      ok_id="$id"; ok_sha="$sha"
    fi
  done <<EOF
$(workflow_runs acceptance-candidate.yml 30)
EOF
  fact candidate_run_active "${active_id:+$active_id:$active_status}"
  fact candidate_run_success "$ok_id"
  fact candidate_sha "$ok_sha"
  local artifact_state=""
  if [ -n "$ok_id" ]; then
    artifact_state="$(gh api "repos/$(gh_repo)/actions/runs/$ok_id/artifacts" \
      --jq ".artifacts[] | select(.name == \"acceptance-candidate-$ok_sha\") | if .expired then \"expired\" else \"available\" end" \
      2>/dev/null || true)"
    fact candidate_artifact "${artifact_state:-missing}"
  fi

  local promote_active="" verify_ok="" verify_active=""
  while IFS=$'\t' read -r id status concl sha created; do
    [ -n "$id" ] || continue
    [ "$status" != "completed" ] && [ -z "$promote_active" ] && promote_active="$id:$status"
  done <<EOF
$(workflow_runs promote-acceptance-candidate.yml 10)
EOF
  while IFS=$'\t' read -r id status concl sha created; do
    [ -n "$id" ] || continue
    if [ "$status" != "completed" ]; then
      [ -n "$verify_active" ] || verify_active="$id:$status"
    elif [ "$concl" = "success" ] && [ -n "$pub_at" ] && [[ "$created" > "$pub_at" ]] && [ -z "$verify_ok" ]; then
      verify_ok="$id"
    fi
  done <<EOF
$(workflow_runs verify-live-coordinator-release-rollout.yml 10)
EOF
  fact promote_run_active "$promote_active"
  fact verify_live_rollout_success "$verify_ok"
  fact verify_live_rollout_active "$verify_active"
  local prod_active
  prod_active="$(production_release_active_runs | tr '\t\n' ': ' | sed 's/ $//')"
  fact production_release_active_runs "$prod_active"

  local install_state="unknown"
  if [ -n "${INSTALL_SH_URL:-}" ] && [ "$published" = true ]; then
    if [ "$(http_get "$INSTALL_SH_URL" "$OPS_TMP_DIR/install.sh")" = "200" ] &&
      git -C "$REPO_ROOT" show "v$V:phase3-binary/dist/install.sh" > "$OPS_TMP_DIR/install.release.sh" 2>/dev/null; then
      if cmp -s "$OPS_TMP_DIR/install.sh" "$OPS_TMP_DIR/install.release.sh"; then install_state=parity; else install_state=drift; fi
    fi
  fi
  fact install_sh_vs_release "$install_state"

  decide "$main_sha" "$head_sha" "$V" "$A" "$L" "$published" "$active_id" "$active_status" \
    "$ok_id" "$ok_sha" "$artifact_state" "$promote_active" "$verify_ok" "$verify_active" "$prod_active" "$install_state"
}

decide() {
  local main_sha="$1" head_sha="$2" V="$3" A="$4" L="$5" published="$6" active_id="$7" active_status="$8"
  local ok_id="$9" ok_sha="${10}" artifact_state="${11}" promote_active="${12}" verify_ok="${13}"
  local verify_active="${14}" prod_active="${15}" install_state="${16}"
  NEXT_RUNBOOK="$TRAIN_DOC#promotion-gate-checklist"

  if [ -z "$L" ]; then
    step version_alignment unknown "live recommendation unreadable"
    set_next version_alignment blocked "Read the live coordinator recommendation" "" \
      "COORDINATOR_URL is unset or /healthz is unreadable; the train order starts from the live stable version"
    return
  fi

  # 1. version alignment (only meaningful before publication).
  if [ "$published" = true ]; then
    step version_alignment "done" "v$V published"
  elif [ "$A" = "MISMATCH" ] || [ "$A" != "$L" ]; then
    step version_alignment pending "checked-in $A != live $L"
    set_next version_alignment manual "Align the three checked-in latest_binary_version rows to live stable $L" \
"# PR on a fresh worktree: set latest_binary_version: \"$L\" in
#   phase4-coordinator/dist/coordinator.yaml
#   phase4-coordinator/coordinator.yaml.example
#   phase4-coordinator/dist/coordinator.yaml.example
bash scripts/release-staged-version-policy.sh v$V" \
      "release-staged-version-policy.sh derives the previous stable from these rows; they must name live stable $L"
  elif [ "$(semver_cmp "$V" "$L")" != "1" ]; then
    step version_alignment pending "binaryVersion $V is not above live $L"
    set_next version_alignment manual "Bump binaryVersion above $L in a version-only PR" \
      "# edit phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift: static let binaryVersion" \
      "A promotion_ready candidate must carry its final version in the accepted bytes"
  else
    step version_alignment "done" "binaryVersion $V > live $L == checked-in $A"
  fi

  # 2-3. candidate cut and its approval.
  if [ "$published" = true ]; then
    step candidate_cut "done" "superseded by publication"
    step candidate_env_approval "done" ""
  elif [ -n "$active_id" ]; then
    step candidate_cut in_progress "run $active_id ($active_status)"
    if [ "$active_status" = "waiting" ]; then
      step candidate_env_approval pending "run $active_id waits on production-release"
      set_next candidate_env_approval manual "Approve production-release for acceptance run $active_id (owner account)" \
        "gh run view $active_id -R $(gh_repo)   # approve the pending production-release deployment from the owner account"
    else
      set_next candidate_cut blocked "Wait for acceptance run $active_id" "gh run watch $active_id -R $(gh_repo)" \
        "acceptance run $active_id for v$V is $active_status; refusing a second dispatch"
    fi
  elif [ -n "$ok_id" ] && [ "$artifact_state" = "available" ] || marker_run_matches signed_byte_verification "$ok_id"; then
    step candidate_cut "done" "run $ok_id @ $ok_sha"
    step candidate_env_approval "done" ""
  else
    local why="no successful acceptance run for v$V"
    [ -z "$ok_id" ] || why="run $ok_id artifact is ${artifact_state:-missing} and was never verified"
    step candidate_cut pending "$why"
    if [ "$head_sha" != "$main_sha" ]; then
      set_next candidate_cut blocked "Cut the v$V candidate" "" \
        "run from a clean worktree whose HEAD is origin/main ($main_sha)"
    elif remote_tag_exists "v$V"; then
      set_next candidate_cut blocked "Cut the v$V candidate" "" \
        "tag v$V already exists on origin; acceptance signing is forbidden for an existing tag"
    else
      set_next candidate_cut mutate "Cut the promotion-ready v$V candidate on the exact origin/main SHA" \
"gh workflow run acceptance-candidate.yml -R $(gh_repo) --ref main \\
  -f candidate_ref=refs/heads/main -f candidate_sha=$main_sha -f tag=v$V \\
  -f provider_admission_policy=strict_post_migration -f promotion_ready=true" "$why"
    fi
    step candidate_env_approval pending ""
  fi

  # 4. signed-byte verification.
  if [ "$published" = true ] || marker_run_matches signed_byte_verification "$ok_id"; then
    step signed_byte_verification "done" "$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("checksums_sha256")')"
  else
    step signed_byte_verification pending ""
    [ -z "$ok_id" ] || set_next signed_byte_verification read "Verify the signed candidate bytes of run $ok_id" \
      "scripts/ops/cli-release.sh _verify-candidate $ok_id $ok_sha $V"
    next_meta signed_byte_verification "$VERIFY_DOC#production-release-gate"
  fi

  local compat_id
  compat_id="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("compatibility_set_id")')"

  # 4b. privacy release identity: the hot SPEC-049-R027 registration of the
  # candidate's code identity. Read live every time; never a local marker.
  load_registrations "$V" "$compat_id"
  # 4a. one-time Pearl setup of the release metadata dir. It shares its one
  # restart with the accepted_ids edit when that is still due, and stages the
  # candidate identity right after (hot), so 4a, 4b and 5 take one run.
  case "$REG_STATE" in
    unknown) step privacy_release_setup unknown "$REG_ERR" ;;
    unconfigured)
      step privacy_release_setup pending "Pearl has no release_code_identities.metadata_dir"
      local key_sha setup_cmd setup_also=""
      key_sha="$(shasum -a 256 "$REPO_ROOT/ops/pearl-updater/release-signing-public.pem" | awk '{print $1}')"
      setup_cmd="scripts/ops/cli-release.sh _pearl-config --privacy-setup $PRIVACY_METADATA_DIR $PRIVACY_PUBLIC_KEY_PATH $key_sha"
      if [ "$published" != true ] && [ -n "$compat_id" ] && [ "$REG_COMPAT_ACCEPTED" != true ]; then
        setup_cmd="$setup_cmd --accepted-id $compat_id"; setup_also=" and add $compat_id to accepted_ids"
      fi
      [ -z "$(candidate_release_bytes "$V")" ] || setup_cmd="$setup_cmd
scripts/ops/cli-release.sh _stage-privacy-identity $V"
      set_next privacy_release_setup mutate "One-time: configure privacy_class.release_code_identities on Pearl$setup_also" \
        "$setup_cmd"
      next_meta privacy_release_setup "$PRIVACY_DOC#one-time-setup-pearl" \
        "coordinator restart: a few seconds of buyer outage" privacy_release_setup ;;
    *) step privacy_release_setup "done" "metadata_dir $REG_DIR" ;;
  esac
  if [ "$REG_STATE" = staged ] || { [ "$published" = true ] && [ "$REG_STATE" = present ]; }; then
    step privacy_release_identity "done" "v$V.json in $REG_DIR"
  else
    step privacy_release_identity pending "$REG_STATE"
    case "$REG_STATE" in
      unknown)
        set_next privacy_release_identity blocked "Read Pearl's privacy release identity registration" "" "$REG_ERR" ;;
      unconfigured) ;;  # privacy_release_setup comes first
      mismatch)
        set_next privacy_release_identity blocked "Resolve the conflicting v$V.json in $REG_DIR" "" \
          "$REG_DIR/v$V.json exists with bytes that differ from the verified candidate; refusing to replace a signed release identity" ;;
      *)
        if [ -z "$(candidate_release_bytes "$V")" ]; then
          set_next privacy_release_identity blocked "Register v$V's privacy code identity on Pearl" "" \
            "no verified candidate pearl-release.json for v$V is recorded; run the signed_byte_verification step"
        else
          set_next privacy_release_identity mutate "Stage v$V's signed pearl-release.json in Pearl's privacy release metadata dir" \
            "scripts/ops/cli-release.sh _stage-privacy-identity $V"
          next_meta privacy_release_identity "$PRIVACY_DOC#approved-code-identities" \
            "none: two signed files added to $REG_DIR; the coordinator re-reads it within one challenge interval (~60 s), no restart"
        fi ;;
    esac
  fi

  # 5. Pearl accepted_ids (keep target): read live from the applied config.
  if [ "$published" = true ]; then
    step pearl_accepted_ids "done" "v$V published"
  elif [ "$REG_COMPAT_ACCEPTED" = true ]; then
    step pearl_accepted_ids "done" "$compat_id accepted by the running coordinator"
  else
    step pearl_accepted_ids pending ""
    if [ "$REG_STATE" = unknown ]; then
      set_next pearl_accepted_ids blocked "Read Pearl's compatibility_set" "" "$REG_ERR"
    elif [ -z "$compat_id" ]; then
      set_next pearl_accepted_ids blocked "Accept v$V on Pearl" "" "no verified compatibility_set_id for v$V is recorded"
    else
      # SIGHUP does not reload compatibility_set (s.cfg is a value copy): restart.
      set_next pearl_accepted_ids mutate "Add $compat_id to Pearl compatibility_set.accepted_ids (keep target_id) and restart" \
        "scripts/ops/cli-release.sh _pearl-config --accepted-id $compat_id"
      next_meta pearl_accepted_ids "$ROLLOUT_DOC" "coordinator restart: a few seconds of buyer outage" pearl_accepted_ids
    fi
  fi

  # 6. canary install/join smoke.
  if marker_canary_probe_matches "$ok_sha"; then
    step canary_smoke "done" "$(marker_field "$OPS_SCOPE" canary_smoke 'd.get("evidence")')"
  else
    step canary_smoke pending ""
    set_next canary_smoke manual "Exact signed-candidate install/join smoke on the canary Mac" \
"# docs/releases/cli-release-train.md Promotion gate item 4 (operator approval: restarts the live provider)
# Install the verified bytes from $OPS_STATE_DIR/$OPS_SCOPE/ on the canary, then confirm:
#   macprovider-cli --version == $V; joins via compatibility set $compat_id;
#   operator pause survives coordinator drain; one bounded buyer request is served.
# Record it with structured evidence (free text is refused):
#   $0 next --done canary_smoke --probe        (reads /v1/status via STUDIO_SSH and reuses catalog gateway proof)"
  fi

  # 7. in-scope e2e on the candidate (Promotion gate item 3).
  if [ "$published" = true ] || marker_candidate_matches e2e_gate "$ok_sha"; then
    step e2e_gate "done" "$(marker_field "$OPS_SCOPE" e2e_gate 'd.get("evidence")')"
  else
    step e2e_gate pending ""
    set_next e2e_gate manual "Record the in-scope e2e evidence for candidate $ok_sha" \
"# docs/releases/cli-release-train.md Promotion gate item 3: in-scope e2e green on this candidate,
# or an explicit carry-forward record. Record checkable evidence only:
#   $0 next --done e2e_gate --run-id <signed journey run id> [--run-id <id> ...]
#   $0 next --done e2e_gate --carry-forward <record id in docs/releases/cli-release-train.md>"
  fi

  # 7a. registrations: every coordinator-side registration of the candidate
  # binary is live in the running coordinator. Evaluated on every status, also
  # after publication, so it re-gates recommendation_bump and
  # verify_live_rollout (both come later in this order).
  if [ "$REG_STATE" != unknown ] && [ -z "$REG_MISSING" ]; then
    step registrations "done" "accepted_ids has $compat_id; code identity approved by $REG_BY"
  else
    step registrations pending "${REG_MISSING:-$REG_ERR}"
    set_next registrations blocked "Pearl registrations for v$V are not live" "" \
      "promotion, recommendation bump and rollout verification refused: ${REG_MISSING:-$REG_ERR}"
    next_meta registrations "$TRAIN_DOC#promotion-gate-checklist"
  fi

  # 7a2. signed release tag on the candidate SHA (the promotion workflow runs
  # verify-release-tag-target.sh --require-existing).
  local tag_state=""
  if [ "$published" = true ]; then
    step release_tag "done" "v$V published"
  else
    tag_state="$(release_tag_state "v$V" "$ok_sha")"
    case "$tag_state" in
      on_candidate) step release_tag "done" "signed annotated v$V -> $ok_sha (verify-tag ok)" ;;
      absent)
        step release_tag pending "v$V absent on origin"
        if is_sha40 "$ok_sha" && marker_run_matches signed_byte_verification "$ok_id"; then
          set_next release_tag mutate "Create and push the signed annotated tag v$V on $ok_sha" \
            "scripts/ops/cli-release.sh _release-tag $V $ok_sha"
        else
          set_next release_tag blocked "Tag v$V" "" "no verified candidate SHA for v$V is recorded"
        fi ;;
      *)
        step release_tag pending "$tag_state"
        set_next release_tag blocked "Resolve the existing v$V tag" "" \
          "v$V on origin is $tag_state, not a verified signed annotated tag on candidate $ok_sha; refusing to move or reuse it" ;;
    esac
  fi

  # 7. promotion.
  local cs
  cs="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("checksums_sha256")')"
  if [ "$published" = true ]; then
    step promotion "done" "v$V published"
  elif [ -n "$promote_active" ]; then
    step promotion in_progress "$promote_active"
    case "$promote_active" in
      *:waiting) set_next promotion_env_approval manual "Approve production-release for promotion run ${promote_active%%:*}" \
        "gh run view ${promote_active%%:*} -R $(gh_repo)   # approve from the owner account" ;;
      *) set_next promotion blocked "Wait for promotion run ${promote_active%%:*}" "gh run watch ${promote_active%%:*} -R $(gh_repo)" \
        "promotion run $promote_active is in flight; refusing a second dispatch" ;;
    esac
  else
    step promotion pending ""
    if [ -n "$prod_active" ]; then
      set_next promotion blocked "Promote v$V" "" "production-release group busy: $prod_active"
    elif ! marker_run_matches signed_byte_verification "$ok_id" ||
      ! marker_canary_probe_matches "$ok_sha" || ! marker_candidate_matches e2e_gate "$ok_sha" ||
      [ "$REG_STATE" = unknown ] || [ -n "$REG_MISSING" ] || [ "$tag_state" != on_candidate ]; then
      set_next promotion blocked "Promote v$V" "" \
        "physical_acceptance_confirmed=true needs verified bytes, canary smoke, e2e evidence, live Pearl registrations and the signed v$V tag for $ok_sha"
    else
      set_next promotion mutate "Promote acceptance run $ok_id to the public v$V release" \
"gh workflow run promote-acceptance-candidate.yml -R $(gh_repo) --ref main \\
  -f candidate_run_id=$ok_id -f candidate_sha=$ok_sha -f tag=v$V \\
  -f expected_checksums_sha256=$cs -f physical_acceptance_confirmed=true"
    fi
  fi

  # 8. recommendation / compatibility target bump.
  if [ "$L" = "$V" ]; then
    step recommendation_bump "done" "live recommends $V"
  else
    step recommendation_bump pending "live recommends $L"
    if [ -z "$compat_id" ]; then
      set_next recommendation_bump blocked "Recommend v$V" "" "no verified compatibility_set_id for v$V is recorded"
    else
      set_next recommendation_bump mutate "Move Pearl latest_binary_version and compatibility_set.target_id to $V (prior target stays accepted) and restart" \
        "scripts/ops/cli-release.sh _pearl-config --recommend $V $compat_id"
      next_meta recommendation_bump "$VERIFY_DOC#pearl-compatibility-gate-before-fleet-recommendation" \
        "coordinator restart: a few seconds of buyer outage" recommendation_bump
    fi
  fi

  # 9. verify-live-coordinator-release-rollout. The process-lifetime
  # rejection count is reported only; the dispatch is gated by
  # _check-privacy-rejections, which samples the counter twice over a window
  # so historical rejections never block it.
  if [ "$L" = "$V" ] && [ -n "${PEARL_SSH:-}" ] &&
    registrations_remote unapproved "$PEARL_COORDINATOR_UNIT" "$PEARL_COORDINATOR_METRICS_URL" \
      > "$OPS_TMP_DIR/unapproved.json" 2>/dev/null; then
    fact privacy_unapproved_rejections_lifetime "$(json_field "$OPS_TMP_DIR/unapproved.json" 'd["count"]')"
    fact privacy_unapproved_rejections_source "$(json_field "$OPS_TMP_DIR/unapproved.json" 'd["source"]')"
  fi
  if [ -n "$verify_ok" ]; then
    step verify_live_rollout "done" "run $verify_ok"
  elif [ -n "$verify_active" ]; then
    step verify_live_rollout in_progress "$verify_active"
    set_next verify_live_rollout blocked "Wait for rollout verification ${verify_active%%:*}" \
      "gh run watch ${verify_active%%:*} -R $(gh_repo)" "a rollout verification run is in flight; refusing a second dispatch"
  else
    step verify_live_rollout pending ""
    if [ -n "$prod_active" ]; then
      set_next verify_live_rollout blocked "Verify the live rollout of v$V" "" "production-release group busy: $prod_active"
    else
      set_next verify_live_rollout mutate "Verify the live coordinator rollout and publish discovery for v$V" \
"scripts/ops/cli-release.sh _check-privacy-rejections
gh workflow run verify-live-coordinator-release-rollout.yml -R $(gh_repo) --ref main -f tag=v$V"
    fi
  fi

  # 10. get-channel install.sh.
  case "$install_state" in
    parity) step install_sh_republish "done" "served == v$V dist/install.sh" ;;
    drift)
      step install_sh_republish pending "served install.sh differs from v$V"
      if [ -z "${INSTALL_SH_REMOTE_PATH:-}" ] || [ -z "${PEARL_SSH:-}" ]; then
        set_next install_sh_republish blocked "Republish install.sh from v$V" "" \
          "PEARL_SSH and INSTALL_SH_REMOTE_PATH must be set (see scripts/ops/README.md)"
      else
        set_next install_sh_republish mutate "Republish the get-channel install.sh from v$V" \
"ts=\$(date -u +%Y%m%dT%H%M%SZ)
git show v$V:phase3-binary/dist/install.sh > \"\${TMPDIR:-/tmp}/install.sh.v$V\"
ssh \"\$PEARL_SSH\" \"cp -p \$INSTALL_SH_REMOTE_PATH \$INSTALL_SH_REMOTE_PATH.bak-\$ts\"
scp \"\${TMPDIR:-/tmp}/install.sh.v$V\" \"\$PEARL_SSH:/tmp/install.sh.new\"
ssh \"\$PEARL_SSH\" \"install -o root -g root -m 0755 /tmp/install.sh.new \$INSTALL_SH_REMOTE_PATH && rm -f /tmp/install.sh.new\""
        next_meta install_sh_republish "$VERIFY_DOC#curl-channel-installsh-republish-mandatory-on-release" "none expected: static file replace on the coordinator host"
      fi
      ;;
    *)
      step install_sh_republish unknown "needs INSTALL_SH_URL and a published v$V"
      [ "$published" != true ] || set_next install_sh_republish blocked "Check install.sh parity" "" "INSTALL_SH_URL is unset or unreadable"
      ;;
  esac

  # 11. consumer health (read-only).
  if marker_done "$OPS_SCOPE" install_sh_consumer_health; then
    step install_sh_consumer_health "done" ""
  else
    step install_sh_consumer_health pending ""
    set_next install_sh_consumer_health read "Check that the served installer resolves an installable release" \
      "bash scripts/check-install-sh-consumer-health.sh"
    next_meta install_sh_consumer_health "$VERIFY_DOC" "" install_sh_consumer_health
  fi

  set_next "done" "done" "v$V train complete" ""
}

# marker_candidate_matches STEP SHA: the structured marker was recorded for candidate SHA.
marker_candidate_matches() {
  [ -n "${2-}" ] && marker_done "$OPS_SCOPE" "$1" &&
    [ "$(marker_field "$OPS_SCOPE" "$1" 'd.get("candidate_sha")')" = "$2" ]
}

marker_canary_probe_matches() {
  local sha="$1"
  [ -n "$sha" ] || return 1
  marker_done "$OPS_SCOPE" canary_smoke || return 1
  [ "$(marker_field "$OPS_SCOPE" canary_smoke 'd.get("candidate_sha")')" = "$sha" ] || return 1
  [ "$(marker_field "$OPS_SCOPE" canary_smoke 'd.get("kind")')" = "status_probe_gateway_proof" ] || return 1
  [ "$(marker_field "$OPS_SCOPE" canary_smoke 'd.get("probe", {}).get("continuous_batching_active")')" = "true" ] || return 1
  [ "$(marker_field "$OPS_SCOPE" canary_smoke 'd.get("probe", {}).get("paged_kv_decision")')" = "attached" ] || return 1
  [ "$(marker_field "$OPS_SCOPE" canary_smoke 'd.get("probe", {}).get("policy_load_status")')" = "live_verified" ] || return 1
  [ "$(marker_field "$OPS_SCOPE" canary_smoke 'd.get("probe", {}).get("policy_authorized")')" = "true" ] || return 1
  [ "$(marker_field "$OPS_SCOPE" canary_smoke 'd.get("probe", {}).get("policy_local_proof_result")')" = "passed" ] || return 1
}

# check_journey_run RUN_ID CANDIDATE_SHA VERSION -> JSON evidence on stdout, or refuse.
# The run must be a successful signed journey run that names the candidate.
check_journey_run() {
  local id="$1" sha="$2" V="$3" info
  [[ "$id" =~ ^[0-9]+$ ]] || refuse "run id must be numeric (got '$id')"
  info="$(gh api "repos/$(gh_repo)/actions/runs/$id" \
    --jq '{id, conclusion, status, head_sha, path, display_title, html_url}' 2>/dev/null)" ||
    refuse "run $id not readable via gh"
  python3 - "$info" "$sha" "$V" <<'PY' || refuse "run $id is not a successful signed journey run"
import json, re, sys
d, sha, v = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
ok = d.get("status") == "completed" and d.get("conclusion") == "success"
ok = ok and re.fullmatch(r"\.github/workflows/promote-signed-[a-z0-9-]+-journey\.yml", d.get("path") or "")
sys.exit(0 if ok else 1)
PY
  local head title named=""
  head="$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["head_sha"])')"
  title="$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["display_title"] or "")')"
  if [ "$head" = "$sha" ]; then
    named="head_sha"
  elif [[ "$title" == *"$sha"* || "$title" == *"v$V"* ]]; then
    named="display_title"
  elif gh run view "$id" -R "$(gh_repo)" --log 2>/dev/null | grep -qF -e "$sha" -e "v$V"; then
    named="run_log"
  fi
  [ -n "$named" ] || refuse "run $id does not name candidate $sha or v$V (head_sha, title or log)"
  printf '%s' "$info" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["candidate_named_by"]=sys.argv[1]; print(json.dumps(d))' "$named"
}

# structured_done STEP: record canary_smoke / e2e_gate from checkable evidence
# (DONE_RUN_IDS, DONE_CARRY, DONE_PROBE set by ops_main).
structured_done() {
  local step_id="$1" V sha compat
  V="${OPS_SCOPE#cli-release-}"
  sha="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("candidate_sha")')"
  compat="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("compatibility_set_id")')"
  is_sha40 "$sha" || refuse "verify the candidate bytes first; no verified candidate SHA is recorded"
  local runs_json="[]" id ev
  for id in $DONE_RUN_IDS; do
    id="${id##*/runs/}"; id="${id%%/*}"
    ev="$(check_journey_run "$id" "$sha" "$V")"
    runs_json="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))' "$runs_json" "$ev")"
  done
  case "$step_id" in
    canary_smoke)
      if [ "$DONE_PROBE" = 1 ]; then
        [ -n "$DONE_RUN_IDS$DONE_CARRY" ] && refuse "use one kind of evidence"
        require_studio_ssh
        case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac
        studio_ssh "curl -s -m 10 http://127.0.0.1:$STUDIO_STATUS_PORT/v1/status" > "$OPS_TMP_DIR/canary.json" ||
          refuse "canary /v1/status not readable over STUDIO_SSH"
        local probe
        probe="$(python3 - "$OPS_TMP_DIR/canary.json" "$V" "$compat" <<'PY'
import json, sys
d, v, compat = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
cb = d.get("continuous_batching") or {}
policy = cb.get("policy") or {}
got = {
    "binary_version": d.get("binary_version"),
    "coordinator_connected": (d.get("coordinator") or {}).get("connected"),
    "compatibility_set_id": d.get("compatibility_set_id"),
    "continuous_batching_active": cb.get("active"),
    "paged_kv_decision": cb.get("paged_kv_decision"),
    "policy_load_status": policy.get("load_status"),
    "policy_authorized": policy.get("authorized"),
    "policy_local_proof_result": policy.get("local_proof_result"),
}
bad = []
if got["binary_version"] != v: bad.append("binary_version %r != %r" % (got["binary_version"], v))
if got["coordinator_connected"] is not True: bad.append("coordinator.connected is not true")
if compat and got["compatibility_set_id"] != compat: bad.append("compatibility_set_id %r != %r" % (got["compatibility_set_id"], compat))
if got["continuous_batching_active"] is not True: bad.append("continuous_batching.active is not true")
if got["paged_kv_decision"] != "attached": bad.append("continuous_batching.paged_kv_decision %r != 'attached'" % (got["paged_kv_decision"],))
if got["policy_load_status"] != "live_verified": bad.append("continuous_batching.policy.load_status %r != 'live_verified'" % (got["policy_load_status"],))
if got["policy_authorized"] is not True: bad.append("continuous_batching.policy.authorized is not true")
if got["policy_local_proof_result"] != "passed": bad.append("continuous_batching.policy.local_proof_result %r != 'passed'" % (got["policy_local_proof_result"],))
if bad:
    sys.stderr.write("; ".join(bad) + "\n"); sys.exit(1)
print(json.dumps(got, sort_keys=True))
PY
)" || refuse "canary probe failed the candidate checks"
        # The coordinator must accept the canary's privacy advertisement:
        # a rejection is only a log line on Pearl, so read it there.
        local canary_id rejected
        canary_id="$(json_field "$OPS_TMP_DIR/canary.json" 'd["provider_id"]')"
        [ -n "$canary_id" ] || refuse "canary /v1/status reports no provider_id"
        require_pearl_ssh
        rejected="$(registrations_remote unapproved "$PEARL_COORDINATOR_UNIT" - "$canary_id" -10min |
          python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')" ||
          refuse "Pearl coordinator journal not readable over PEARL_SSH"
        [ "$rejected" = 0 ] ||
          refuse "Pearl rejected the canary's privacy advertisement $rejected time(s) in the last 10 minutes (posture_unapproved_code_identity): register v$V's code identity first"
        # Absence of rejections is not approval: the running coordinator must
        # positively hold every registration of this candidate.
        load_registrations "$V" "$compat"
        [ "$REG_STATE" != unknown ] && [ -z "$REG_MISSING" ] ||
          refuse "v$V is not registered in the running coordinator: ${REG_MISSING:-$REG_ERR}"
        local gateway_proof
        gateway_proof="$({ "$OPS_DIR/catalog-activate.sh" _gateway-proof; } 2>&1)" ||
          refuse "canary gateway proof failed after status validation: $gateway_proof"
        mark_done "$OPS_SCOPE" canary_smoke "status probe + gateway proof: $probe" \
          "$(python3 -c 'import json,sys; print(json.dumps({"candidate_sha": sys.argv[1], "kind": "status_probe_gateway_proof", "probe": json.loads(sys.argv[2]), "gateway_proof_sha256": __import__("hashlib").sha256(sys.argv[3].encode()).hexdigest()}))' "$sha" "$probe" "$gateway_proof")"
      elif [ -n "$DONE_RUN_IDS" ] && [ -z "$DONE_CARRY" ]; then
        refuse "canary_smoke requires --probe so continuous-batching activation is read from the upgraded provider status"
      else
        refuse "canary_smoke needs --probe; free text and run IDs are not activation evidence"
      fi ;;
    e2e_gate)
      [ "$DONE_PROBE" = 0 ] || refuse "--probe is not evidence for e2e_gate"
      if [ -n "$DONE_CARRY" ] && [ -z "$DONE_RUN_IDS" ]; then
        [[ "$DONE_CARRY" =~ ^[A-Za-z0-9._:#/-]{3,80}$ ]] || refuse "carry-forward id has unexpected characters"
        local line
        line="$(git -C "$REPO_ROOT" show "origin/main:docs/releases/cli-release-train.md" |
          python3 -c '
import sys
rid, v = sys.argv[1], sys.argv[2]
for l in sys.stdin:
    if rid in l and "carry" in l.lower() and v in l:
        print(l.strip()); break
' "$DONE_CARRY" "$V")"
        [ -n "$line" ] || refuse "no line in origin/main:docs/releases/cli-release-train.md names carry-forward '$DONE_CARRY' for $V"
        mark_done "$OPS_SCOPE" e2e_gate "carry-forward $DONE_CARRY" \
          "$(python3 -c 'import hashlib,json,sys; print(json.dumps({"candidate_sha": sys.argv[1], "kind": "carry_forward", "record_id": sys.argv[2], "record_line_sha256": hashlib.sha256(sys.argv[3].encode()).hexdigest()}))' "$sha" "$DONE_CARRY" "$line")"
      elif [ -n "$DONE_RUN_IDS" ] && [ -z "$DONE_CARRY" ]; then
        mark_done "$OPS_SCOPE" e2e_gate "journey runs: $DONE_RUN_IDS" \
          "$(python3 -c 'import json,sys; print(json.dumps({"candidate_sha": sys.argv[1], "kind": "runs", "runs": json.loads(sys.argv[2])}))' "$sha" "$runs_json")"
      else
        refuse "e2e_gate needs --run-id <id> ... or --carry-forward <id>; free text is not evidence"
      fi ;;
    *) refuse "no structured evidence defined for $step_id" ;;
  esac
  log "recorded $step_id for candidate $sha"
}

# marker_run_matches STEP RUN_ID: the step marker exists and was made for RUN_ID.
marker_run_matches() {
  [ -n "${2-}" ] && marker_done "$OPS_SCOPE" "$1" &&
    [ "$(marker_field "$OPS_SCOPE" "$1" 'd.get("run_id")')" = "$2" ]
}

# _verify-candidate RUN_ID CANDIDATE_SHA VERSION
# Read-only: download the private acceptance artifact and check the signed
# bytes as provider-cli-release-verification.md "Production release gate" 4-5, 7.
verify_candidate() {
  local run_id="$1" sha="$2" V="$3"
  if ! [[ "$run_id" =~ ^[0-9]+$ ]] || ! is_sha40 "$sha" || ! is_semver "$V"; then
    die "usage: _verify-candidate RUN_ID SHA VERSION"
  fi
  OPS_SCOPE="cli-release-$V"
  local dir="$OPS_STATE_DIR/$OPS_SCOPE/candidate-$run_id"
  rm -rf "$dir"; mkdir -p "$dir"
  log "downloading acceptance-candidate-$sha from run $run_id"
  gh run download "$run_id" -R "$(gh_repo)" -n "acceptance-candidate-$sha" -D "$dir"

  local f
  first_file() { find "$dir" -type f -name "$1" | head -n1; }
  local checksums tarball dmg prj prjsig compat
  checksums="$(first_file checksums.txt)"
  tarball="$(first_file "macprovider-cli-v$V-darwin-arm64.tar.gz")"
  dmg="$(first_file "Malibu-v$V.dmg")"
  prj="$(first_file pearl-release.json)"
  prjsig="$(first_file pearl-release.json.sig)"
  compat="$(first_file compatibility-set.json)"
  for f in checksums tarball dmg prj prjsig compat; do
    [ -n "${!f}" ] || die "acceptance artifact lacks $f"
  done

  log "checking every checksums.txt entry"
  (cd "$(dirname "$checksums")" && python3 - "$checksums" <<'PY'
import hashlib, os, sys
bad = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    digest, name = line.split(None, 1)
    name = name.lstrip("*")
    if not os.path.exists(name):
        print("MISSING %s" % name); bad += 1; continue
    h = hashlib.sha256(open(name, "rb").read()).hexdigest()
    if h != digest:
        print("MISMATCH %s" % name); bad += 1
sys.exit(1 if bad else 0)
PY
  ) || die "checksums.txt does not match the artifact bytes"

  log "verifying pearl-release.json signature"
  openssl dgst -sha256 -verify "$REPO_ROOT/ops/pearl-updater/release-signing-public.pem" \
    -signature "$prjsig" "$prj" >/dev/null || die "pearl-release.json signature does not verify"

  log "comparing the CLI code identity with provider_code_identity"
  local x="$dir/cli-check"; mkdir -p "$x"
  tar -xzf "$tarball" -C "$x" macprovider-cli
  local bin_sha cd_out
  bin_sha="$(shasum -a 256 "$x/macprovider-cli" | awk '{print $1}')"
  cd_out="$(codesign -d --arch arm64 -vvv "$x/macprovider-cli" 2>&1)"
  python3 - "$prj" "$bin_sha" "$cd_out" "$V" <<'PY' || die "provider_code_identity mismatch"
import json, sys
prj, bin_sha, cd_out, version = sys.argv[1:5]
ident = json.load(open(prj))["provider_code_identity"]
fields = dict(l.split("=", 1) for l in cd_out.splitlines() if "=" in l)
checks = {
    "binary_sha256": (ident.get("binary_sha256"), bin_sha),
    "code_cdhash": (ident["slices"][0].get("code_cdhash"), fields.get("CDHash")),
    "team_id": (ident.get("team_id"), fields.get("TeamIdentifier")),
    "signing_identifier": (ident.get("signing_identifier"), fields.get("Identifier")),
    "binary_version": (ident.get("binary_version"), version),
}
bad = [k for k, (a, b) in checks.items() if not a or a != b]
for k, (a, b) in checks.items():
    print("%-19s %s %s" % (k, "ok  " if k not in bad else "FAIL", a))
sys.exit(1 if bad else 0)
PY

  log "comparing the Malibu embedded CLI with the standalone tarball"
  bash "$REPO_ROOT/scripts/verify-malibu-release-artifacts.sh" "$dmg" --provider-tarball "$tarball"

  local cs compat_id
  cs="$(shasum -a 256 "$checksums" | awk '{print $1}')"
  compat_id="$(json_field "$compat" 'd["signed"]["compatibility_set_id"]')"
  [ "$compat_id" = "$(gh_repo):v$V@$sha" ] || die "compatibility_set_id $compat_id != $(gh_repo):v$V@$sha"
  mark_done "$OPS_SCOPE" signed_byte_verification "verified run $run_id" \
    "$(python3 -c 'import json,sys; print(json.dumps({"run_id": sys.argv[1], "candidate_sha": sys.argv[2], "checksums_sha256": sys.argv[3], "compatibility_set_id": sys.argv[4], "binary_sha256": sys.argv[5], "bytes_dir": sys.argv[6]}))' \
      "$run_id" "$sha" "$cs" "$compat_id" "$bin_sha" "$dir")"
  log "verified: checksums.txt sha256=$cs compatibility_set_id=$compat_id"
}

# release_tag_state TAG SHA -> absent | on_candidate | on <commit> | lightweight on <commit>
# | unverified on <commit> | ambiguous | unreadable, from origin's refs (the promotion
# workflow reads the same). on_candidate also requires the exact remote tag object to
# pass `git verify-tag` against the operator's signer trust (gpg keyring or
# gpg.ssh.allowedSignersFile); an unsigned or untrusted tag is "unverified".
release_tag_state() {
  local rows obj peeled
  rows="$(git -C "$REPO_ROOT" ls-remote origin "refs/tags/$1" "refs/tags/$1^{}" 2>/dev/null)" || { printf 'unreadable'; return; }
  obj="$(printf '%s\n' "$rows" | awk -v r="refs/tags/$1" '$2 == r {print $1}')"
  peeled="$(printf '%s\n' "$rows" | awk -v r="refs/tags/$1^{}" '$2 == r {print $1}')"
  if [ -z "$obj" ]; then printf 'absent'
  elif [ "$(printf '%s\n' "$obj" | wc -l | tr -d ' ')" != 1 ]; then printf 'ambiguous'
  elif [ -z "$peeled" ]; then printf 'lightweight on %s' "$obj"
  elif [ -z "${2-}" ] || [ "$peeled" != "$2" ]; then printf 'on %s' "$peeled"
  elif { git -C "$REPO_ROOT" cat-file -e "$obj" 2>/dev/null ||
      git -C "$REPO_ROOT" fetch -q --no-tags origin "refs/tags/$1" 2>/dev/null; } &&
    [ "$(git -C "$REPO_ROOT" cat-file -t "$obj" 2>/dev/null)" = tag ] &&
    git -C "$REPO_ROOT" verify-tag "$obj" >/dev/null 2>&1; then
    printf 'on_candidate'
  else printf 'unverified on %s' "$peeled"
  fi
}

# _release-tag VERSION CANDIDATE_SHA
# Create v<ver> as a signed annotated tag on the verified candidate SHA with the
# operator's git signing key, verify it, push it, and confirm origin's target.
release_tag() {
  local V="$1" sha="$2" tag state
  is_semver "$V" && is_sha40 "$sha" || die "usage: _release-tag VERSION CANDIDATE_SHA"
  tag="v$V"
  [ "$(marker_field "cli-release-$V" signed_byte_verification 'd.get("candidate_sha")')" = "$sha" ] ||
    refuse "$sha is not the verified candidate SHA for $V"
  state="$(release_tag_state "$tag" "$sha")"
  case "$state" in
    on_candidate) log "$tag already targets $sha on origin and verifies"; return 0 ;;
    absent) ;;
    *) refuse "$tag on origin is $state; refusing to create or move it" ;;
  esac
  git -C "$REPO_ROOT" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$REPO_ROOT" fetch -q origin "$sha" ||
    refuse "candidate commit $sha is not available locally or on origin"
  if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [ "$(git -C "$REPO_ROOT" rev-parse "$tag^{commit}")" = "$sha" ] &&
      [ "$(git -C "$REPO_ROOT" cat-file -t "refs/tags/$tag")" = tag ] ||
      refuse "local $tag exists and is not an annotated tag on $sha; delete the local tag and re-run"
  else
    git -C "$REPO_ROOT" tag -s -a "$tag" -m "macprovider-cli $V" "$sha" ||
      refuse "git tag -s failed; configure the operator's git signing key (user.signingkey)"
  fi
  git -C "$REPO_ROOT" verify-tag "$tag" >/dev/null 2>&1 || refuse "git verify-tag $tag failed; not pushing"
  git -C "$REPO_ROOT" push -q origin "refs/tags/$tag" || refuse "pushing $tag failed"
  [ "$(release_tag_state "$tag" "$sha")" = on_candidate ] || refuse "origin $tag does not target $sha after the push"
  log "pushed signed annotated $tag -> $sha"
}

# _check-privacy-rejections: refuse when the coordinator keeps rejecting
# privacy advertisements as posture_unapproved_code_identity now. Two samples
# of the counter PRIVACY_REJECTION_WINDOW_SECONDS apart (default 180 s, three
# posture challenge intervals); without the metric, journal lines in the window.
check_privacy_rejections() {
  local window="${PRIVACY_REJECTION_WINDOW_SECONDS:-180}" a b src delta
  [[ "$window" =~ ^[0-9]+$ ]] || die "PRIVACY_REJECTION_WINDOW_SECONDS must be a whole number"
  require_pearl_ssh
  a="$(registrations_remote unapproved "$PEARL_COORDINATOR_UNIT" "$PEARL_COORDINATOR_METRICS_URL")" ||
    refuse "rejection counter unreadable over PEARL_SSH"
  src="$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["source"])')"
  log "sampling posture_unapproved_code_identity rejections over ${window}s ($src)"
  sleep "$window"
  if [ "$src" = metric ]; then
    b="$(registrations_remote unapproved "$PEARL_COORDINATOR_UNIT" "$PEARL_COORDINATOR_METRICS_URL")" ||
      refuse "rejection counter unreadable over PEARL_SSH"
    delta="$(python3 -c 'import json,sys; a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2]); print(b["count"] - a["count"] if b["source"] == "metric" else "-reset")' "$a" "$b")"
  else
    delta="$(registrations_remote unapproved "$PEARL_COORDINATOR_UNIT" - - "-${window}s" |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')" || refuse "coordinator journal unreadable over PEARL_SSH"
  fi
  case "$delta" in
    0) ;;
    -*) refuse "the rejection counter went backwards during the window (coordinator restarted?); re-run" ;;
    *) refuse "the coordinator rejected $delta privacy advertisement(s) as posture_unapproved_code_identity in the last ${window}s; register (privacy_release_identity) or deny that code identity, then re-run" ;;
  esac
  log "no posture_unapproved_code_identity rejections in ${window}s"
}

# _stage-privacy-identity VERSION
# Copy the verified candidate pearl-release.json and its signature, byte for
# byte, into Pearl's privacy release metadata dir as v<ver>.json/.sig, then
# read them back. The coordinator verifies the signature again before it
# approves anything, so this adds no trust; it removes the config edit.
stage_privacy_identity() {
  local V="$1" bytes prj sig dir out
  is_semver "$V" || die "usage: _stage-privacy-identity VERSION"
  require_pearl_ssh
  bytes="$(candidate_release_bytes "$V")"
  [ -n "$bytes" ] || refuse "no verified candidate pearl-release.json for v$V; run the signed_byte_verification step"
  prj="${bytes%%$'\t'*}"; sig="${bytes#*$'\t'}"
  openssl dgst -sha256 -verify "$REPO_ROOT/ops/pearl-updater/release-signing-public.pem" \
    -signature "$sig" "$prj" >/dev/null || refuse "candidate pearl-release.json signature does not verify"
  [ "$(json_field "$prj" 'd["provider_code_identity"]["binary_version"]')" = "$V" ] ||
    refuse "candidate pearl-release.json provider_code_identity does not name $V"
  registrations_remote facts "$PEARL_COORDINATOR_CONFIG" "$PEARL_COORDINATOR_OVERLAY" "$PEARL_COORDINATOR_UNIT" "$V" - \
    > "$OPS_TMP_DIR/reg-facts.json" || refuse "Pearl coordinator config unreadable"
  dir="$(json_field "$OPS_TMP_DIR/reg-facts.json" 'd["metadata_dir"]')"
  [ -n "$dir" ] || refuse "Pearl has no privacy_class.release_code_identities.metadata_dir; run the privacy_release_setup step with '$0 next --run' first"
  [[ "$dir" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "unexpected metadata_dir path: $dir"
  out="$(registrations_remote stage "$dir" "$V" "$PEARL_RELEASE_IDENTITY_OWNER" "$PEARL_RELEASE_IDENTITY_GROUP" \
    "$(base64 < "$prj" | tr -d '\n')" "$(base64 < "$sig" | tr -d '\n')")" || refuse "staging v$V.json on Pearl failed"
  python3 - "$out" "$prj" "$sig" "$V" <<'PY' || refuse "Pearl read-back does not match the candidate bytes"
import hashlib, json, sys
out, prj, sig, v = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
want = {"v%s.json" % v: hashlib.sha256(open(prj, "rb").read()).hexdigest(),
        "v%s.json.sig" % v: hashlib.sha256(open(sig, "rb").read()).hexdigest()}
sys.exit(0 if out == want else 1)
PY
  log "staged v$V.json and v$V.json.sig in $dir on Pearl; the coordinator approves them within one challenge interval"
}

internal() {
  case "$1" in
    _verify-candidate) shift; verify_candidate "$@" ;;
    _stage-privacy-identity) shift; stage_privacy_identity "$@" ;;
    _release-tag) shift; release_tag "$@" ;;
    _pearl-config) shift; pearl_config "$@" ;;
    _check-privacy-rejections) shift; check_privacy_rejections "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

ops_main "$@"
