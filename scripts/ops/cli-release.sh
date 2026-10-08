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
#   5 pearl_accepted_ids    add the candidate compatibility_set_id, keep target_id
#   6 canary_smoke          exact signed-candidate install/join smoke
#   7 promotion             promote-acceptance-candidate.yml (+ env approval)
#   8 recommendation_bump   Pearl latest_binary_version + compatibility target
#   9 verify_live_rollout   verify-live-coordinator-release-rollout.yml
#  10 install_sh_republish  get-channel install.sh == released dist/install.sh
#  11 install_sh_consumer_health
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, INSTALL_SH_URL,
# PEARL_SSH, INSTALL_SH_REMOTE_PATH, MACPROVIDER_OPS_OWNER (for --run).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME/NEXT_* are read by lib/common.sh

OPS_NAME=cli-release
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

TRAIN_DOC="docs/releases/cli-release-train.md"
VERIFY_DOC="docs/runbooks/provider-cli-release-verification.md"
ROLLOUT_DOC="docs/runbooks/pearl-coordinator-rollout.md"

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

  # 5. Pearl accepted_ids (keep target).
  if [ "$published" = true ] || marker_done "$OPS_SCOPE" pearl_accepted_ids; then
    step pearl_accepted_ids "done" ""
  else
    step pearl_accepted_ids pending ""
    set_next pearl_accepted_ids manual "Add $compat_id to Pearl compatibility_set.accepted_ids (keep target_id)" \
"# docs/releases/cli-release-train.md Session protocol, docs/runbooks/provider-cli-release-verification.md
# On Pearl, under both locks, edit coordinator.yaml IN PLACE (never restore a whole-file backup):
#   compatibility_set.accepted_ids += \"$compat_id\"   (cap 8, keep target_id, drop oldest unused)
# Validate with the running coordinator's service environment, then RESTART the coordinator
# (s.cfg is a value copy; SIGHUP does not reload compatibility_set) and verify the applied
# config hash and public /healthz."
    next_meta pearl_accepted_ids "$ROLLOUT_DOC" "coordinator restart: a few seconds of buyer outage"
  fi

  # 6. canary install/join smoke.
  if [ "$published" = true ] || marker_done "$OPS_SCOPE" canary_smoke; then
    step canary_smoke "done" ""
  else
    step canary_smoke pending ""
    set_next canary_smoke manual "Exact signed-candidate install/join smoke on the canary Mac" \
"# docs/releases/cli-release-train.md Promotion gate item 4 (operator approval: restarts the live provider)
# Install the verified bytes from $OPS_STATE_DIR/$OPS_SCOPE/ on the canary, then confirm:
#   macprovider-cli --version == $V; joins via compatibility set $compat_id;
#   operator pause survives coordinator drain; one bounded buyer request is served."
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
    set_next recommendation_bump manual "Move Pearl latest_binary_version and compatibility_set.target_id to $V" \
"# docs/runbooks/provider-cli-release-verification.md 'Pearl compatibility gate before fleet recommendation'
# On Pearl, under both locks, in place: latest_binary_version: \"$V\";
#   compatibility_set.target_id = v$V's compatibility_set_id; keep the prior target in accepted_ids.
# Restart the coordinator, then confirm /healthz recommended_binary_version == $V."
    next_meta recommendation_bump "$VERIFY_DOC#pearl-compatibility-gate-before-fleet-recommendation" "coordinator restart: a few seconds of buyer outage"
  fi

  # 9. verify-live-coordinator-release-rollout.
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
        "gh workflow run verify-live-coordinator-release-rollout.yml -R $(gh_repo) --ref main -f tag=v$V"
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

internal() {
  case "$1" in
    _verify-candidate) shift; verify_candidate "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

ops_main "$@"
