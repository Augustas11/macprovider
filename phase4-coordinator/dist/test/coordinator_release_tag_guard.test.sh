#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
BUILD_SH="$SCRIPT_DIR/../../scripts/build-linux.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"
bash -n "$BUILD_SH"

grep -qF '_coordinator_release_tag_version()' "$BUILD_SH" ||
  fail "build script must keep an extractable release-tag helper"
grep -qF '_coordinator_release_tag_version()' "$DEPLOY_SH" ||
  fail "deploy script must keep an extractable release-tag helper"
grep -qF 'ALLOW_NON_RELEASE_COORDINATOR_BUILD=1' "$BUILD_SH" ||
  fail "build script must require an explicit local/dev opt-out for non-release artifacts"
grep -qF 'FORCE_DIRTY is only allowed with ALLOW_NON_RELEASE_COORDINATOR_BUILD=1' "$BUILD_SH" ||
  fail "build script must prevent FORCE_DIRTY from stamping dirty production artifacts as release builds"
grep -qF "GOENV=off GOFLAGS='' GOWORK=off GOOS=linux GOARCH=amd64 go build" "$BUILD_SH" ||
  fail "production coordinator builds must disable ambient Go environment poisoning"
grep -qF 'COORDINATOR_RELEASE_IDENTITY="$(_coordinator_release_tag_version "$MODULE_DIR")"' "$DEPLOY_SH" ||
  fail "deploy script must preflight the exact release tag before production SSH mutation"
grep -qF 'SHA256:6DgoKNaOgF5c7NPHTAbNxJ2LT0uuj8U/3zObOOZjRiA' "$BUILD_SH" ||
  fail "build script must pin the authorized release tag signer"
grep -qF 'SHA256:6DgoKNaOgF5c7NPHTAbNxJ2LT0uuj8U/3zObOOZjRiA' "$DEPLOY_SH" ||
  fail "deploy script must pin the authorized release tag signer"
grep -qF 'https://github.com/Augustas11/macprovider.git' "$BUILD_SH" ||
  fail "build script must pin release tag lookup to canonical GitHub URL"
grep -qF 'https://github.com/Augustas11/macprovider.git' "$DEPLOY_SH" ||
  fail "deploy script must pin release tag lookup to canonical GitHub URL"
grep -qF 'GH_HOST=github.com bash "$REPO_ROOT/scripts/verify-pearl-runtime-release.sh"' "$DEPLOY_SH" ||
  fail "deploy script must force gh release preflight to github.com"
grep -qF -- '--repository "Augustas11/macprovider"' "$DEPLOY_SH" ||
  fail "deploy script must pin the GitHub release repository"
grep -qF -- '--remote "origin"' "$DEPLOY_SH" ||
  fail "deploy script must pin the release-tag remote"
! grep -qF '${GITHUB_REPOSITORY:-' "$DEPLOY_SH" ||
  fail "deploy script must not accept caller-controlled GitHub release repositories"
! grep -qF '${RELEASE_TAG_REMOTE:-' "$DEPLOY_SH" ||
  fail "deploy script must not accept caller-controlled release-tag remotes"
grep -qF 'verify-pearl-runtime-release.sh' "$DEPLOY_SH" ||
  fail "deploy script must preflight signed Pearl runtime release assets before production SSH mutation"
grep -qF 'git -C "$REPO_ROOT" archive --format=tar "$COORDINATOR_RELEASE_COMMIT"' "$DEPLOY_SH" ||
  fail "deploy must pin tracked inputs from the verified release commit"
grep -qF 'git -C "$REPO_ROOT" archive --format=tar "$COORDINATOR_RELEASE_COMMIT" -- phase4-coordinator' "$BUILD_SH" ||
  fail "production build must compile from a snapshot of the verified release commit"
grep -qF 'deploy-inputs.sha256' "$DEPLOY_SH" ||
  fail "deploy must verify remote staged input digests before install/execute"
grep -qF 'recovery-inputs.sha256' "$DEPLOY_SH" ||
  fail "deploy must verify recovery guard staged input digests before install"
grep -qF 'tcp-inputs.sha256' "$DEPLOY_SH" ||
  fail "deploy must verify TCP staged input digests before remote sysctl mutation"
grep -qF 'python3 "$AUTOTUNE_RELEASE_VERIFY" check-tier2-binding' "$DEPLOY_SH" ||
  fail "deploy must use the pinned catalog-release verifier for Tier-2 binding checks"
grep -qF 'EXPECTED_VERSION="$COORDINATOR_RELEASE_VERSION"' "$DEPLOY_SH" ||
  fail "deploy provenance must compare healthz against the preflighted exact release tag"
! grep -qF 'EXPECTED_VERSION=$(git describe --always --dirty --tags' "$DEPLOY_SH" ||
  fail "deploy provenance must not derive expected version from git describe"
grep -qF 'refusing coordinator-cli replacement from direct deploy' "$DEPLOY_SH" ||
  fail "deploy must not replace coordinator-cli from ignored local artifacts"
grep -qF 'refusing stats-billing-mirror replacement from direct deploy' "$DEPLOY_SH" ||
  fail "deploy must not replace stats-billing-mirror from ignored local artifacts"
grep -qF 'refusing stats-hardware-verifier replacement from direct deploy' "$DEPLOY_SH" ||
  fail "deploy must not replace stats-hardware-verifier from ignored local artifacts"
grep -qF '_coordinator_verify_deployed_version "$HEALTHZ_BODY" "$EXPECTED_VERSION" || exit $?' "$DEPLOY_SH" ||
  fail "deploy provenance mismatch must be fatal before the commit marker"
! grep -qF 'WARN provenance mismatch' "$DEPLOY_SH" ||
  fail "deploy provenance mismatch must not be warning-only"
release_check_line="$(grep -nF 'COORDINATOR_RELEASE_IDENTITY="$(_coordinator_release_tag_version "$MODULE_DIR")"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
token_load_line="$(grep -nF '_load_catalog_canary_auth_token' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)"
[ -n "$release_check_line" ] && [ -n "$token_load_line" ] && [ "$release_check_line" -lt "$token_load_line" ] ||
  fail "deploy must reject non-release checkouts before reading catalog canary credentials"
provenance_check_line="$(grep -nF '_coordinator_verify_deployed_version "$HEALTHZ_BODY" "$EXPECTED_VERSION" || exit $?' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
commit_line="$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-rollback/committed' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
[ -n "$provenance_check_line" ] && [ -n "$commit_line" ] && [ "$provenance_check_line" -lt "$commit_line" ] ||
  fail "deploy must verify exact release provenance before committing rollback state"

work="$(mktemp -d "${TMPDIR:-/tmp}/coordinator-release-tag-guard.XXXXXX")"
trap 'rm -rf "$work"' EXIT
real_git="$(command -v git)"
export REAL_GIT="$real_git"
mkdir -p "$work/bin"
cat > "$work/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-C" ] && [ "$((i + 1))" -lt "${#args[@]}" ]; then
    repo="${args[$((i + 1))]}"
  fi
done
for arg in "$@"; do
  if [ "$arg" = "verify-tag" ]; then
    [ "${FAKE_GIT_VERIFY_TAG_FAIL:-0}" != "1" ] || exit 1
    if [ "${FAKE_GIT_VERIFY_TAG_UNAUTHORIZED:-0}" = "1" ]; then
      echo 'Good "git" signature for attacker@example.invalid with ED25519 key SHA256:unauthorized' >&2
      exit 0
    fi
    if [ "${FAKE_GIT_VERIFY_TAG_SPOOF_PRINCIPAL:-0}" = "1" ]; then
      echo 'Good "git" signature for SHA256:6DgoKNaOgF5c7NPHTAbNxJ2LT0uuj8U/3zObOOZjRiA with ED25519 key SHA256:unauthorized' >&2
      exit 0
    fi
    echo 'Good "git" signature for augstar@gmail.com with ED25519 key SHA256:6DgoKNaOgF5c7NPHTAbNxJ2LT0uuj8U/3zObOOZjRiA' >&2
    exit 0
  fi
done
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "remote" ] && [ "${args[$((i + 1))]:-}" = "get-url" ] && [ "${args[$((i + 2))]:-}" = "origin" ]; then
    echo "https://github.com/Augustas11/macprovider.git"
    exit 0
  fi
  if [ "${args[$i]}" = "ls-remote" ] && [ "${args[$((i + 1))]:-}" = "https://github.com/Augustas11/macprovider.git" ]; then
    [ -n "$repo" ] || {
      echo "fake git: missing -C repo for canonical ls-remote" >&2
      exit 2
    }
    local_origin="$("$REAL_GIT" -C "$repo" remote get-url origin)"
    args[$((i + 1))]="$local_origin"
    exec "$REAL_GIT" "${args[@]}"
  fi
done
exec "$REAL_GIT" "$@"
SH
chmod +x "$work/bin/git"
export PATH="$work/bin:$PATH"

extract_build_helper="$work/build-helper.sh"
extract_deploy_helper="$work/deploy-helper.sh"
extract_provenance_helper="$work/provenance-helper.sh"
awk '/^_coordinator_release_tag_version\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$BUILD_SH" > "$extract_build_helper"
awk '/^_coordinator_release_tag_version\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$extract_deploy_helper"
awk '/^_coordinator_verify_deployed_version\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$extract_provenance_helper"

init_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.name release-tag-guard-test
  git -C "$repo" config user.email release-tag-guard-test@example.invalid
  printf '%s\n' one > "$repo/value"
  git -C "$repo" add value
  git -C "$repo" commit -qm one
  git init --bare -q "$repo.git"
  git -C "$repo" remote add origin "$repo.git"
  git -C "$repo" push -q origin HEAD:refs/heads/main
}

publish_annotated_tag() {
  local repo="$1" tag="$2"
  git -C "$repo" tag -a "$tag" -m "$tag"
  git -C "$repo" push -q origin "refs/tags/$tag"
}

run_build_helper() {
  local repo="$1"
  (
    cd "$repo"
    # shellcheck disable=SC2034 # consumed by the extracted build helper
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    # shellcheck disable=SC1090
    . "$extract_build_helper"
    _coordinator_release_tag_version
  )
}

run_deploy_helper() {
  local repo="$1"
  (
    # shellcheck disable=SC1090
    . "$extract_deploy_helper"
    _coordinator_release_tag_version "$repo"
  )
}

repo_exact="$work/exact"
init_repo "$repo_exact"
publish_annotated_tag "$repo_exact" v1.8.70
exact_commit="$(git -C "$repo_exact" rev-parse HEAD)"
[ "$(run_build_helper "$repo_exact")" = "v1.8.70 $exact_commit" ] ||
  fail "build helper must return the exact numeric release tag"
[ "$(run_deploy_helper "$repo_exact")" = "v1.8.70 $exact_commit" ] ||
  fail "deploy helper must return the exact numeric release tag"

if FAKE_GIT_VERIFY_TAG_FAIL=1 run_build_helper "$repo_exact" >"$work/unsigned.out" 2>&1; then
  fail "build helper accepted a release tag whose signature verification failed"
fi
grep -qF 'does not verify as a trusted signed tag' "$work/unsigned.out" ||
  fail "build helper must reject unsigned or untrusted release tags"

if FAKE_GIT_VERIFY_TAG_UNAUTHORIZED=1 run_deploy_helper "$repo_exact" >"$work/unauthorized.out" 2>&1; then
  fail "deploy helper accepted a release tag signed by an unauthorized key"
fi
grep -qF 'signed by an unauthorized release signer' "$work/unauthorized.out" ||
  fail "deploy helper must reject release tags signed by unauthorized keys"

if FAKE_GIT_VERIFY_TAG_SPOOF_PRINCIPAL=1 run_build_helper "$repo_exact" >"$work/spoof-principal.out" 2>&1; then
  fail "build helper accepted a release tag with the authorized fingerprint only in the signer principal"
fi
grep -qF 'signed by an unauthorized release signer' "$work/spoof-principal.out" ||
  fail "build helper must match the authorized signer line exactly"

repo_lightweight="$work/lightweight"
init_repo "$repo_lightweight"
git -C "$repo_lightweight" tag v1.8.77
git -C "$repo_lightweight" push -q origin refs/tags/v1.8.77
if run_deploy_helper "$repo_lightweight" >"$work/lightweight.out" 2>&1; then
  fail "deploy helper accepted a lightweight release tag"
fi
grep -qF 'not an annotated signed release tag' "$work/lightweight.out" ||
  fail "deploy helper must reject lightweight numeric tags"

repo_main="$work/main"
init_repo "$repo_main"
if run_build_helper "$repo_main" >"$work/main-build.out" 2>&1; then
  fail "build helper accepted an untagged main checkout"
fi
grep -qF 'HEAD is not exactly a numeric release tag' "$work/main-build.out" ||
  fail "build helper must explain untagged checkout rejection"
if run_deploy_helper "$repo_main" >"$work/main-deploy.out" 2>&1; then
  fail "deploy helper accepted an untagged main checkout"
fi
grep -qF 'git describe from main' "$work/main-deploy.out" ||
  fail "deploy helper must name the git-describe-from-main footgun"

repo_ahead="$work/ahead"
init_repo "$repo_ahead"
publish_annotated_tag "$repo_ahead" v1.8.71
printf '%s\n' two > "$repo_ahead/value"
git -C "$repo_ahead" commit -qam two
if run_build_helper "$repo_ahead" >"$work/ahead-build.out" 2>&1; then
  fail "build helper accepted a vX.Y.Z-N-gHASH checkout"
fi
grep -qF 'HEAD is not exactly a numeric release tag' "$work/ahead-build.out" ||
  fail "build helper must reject commits ahead of a release tag"

repo_bad_tag="$work/bad-tag"
init_repo "$repo_bad_tag"
git -C "$repo_bad_tag" tag v1.8.72-1-gabcdef
if run_build_helper "$repo_bad_tag" >"$work/bad-tag.out" 2>&1; then
  fail "build helper accepted a describe-shaped non-release tag"
fi
grep -qF 'HEAD is not exactly a numeric release tag' "$work/bad-tag.out" ||
  fail "build helper must reject describe-shaped tags"

repo_multi="$work/multi"
init_repo "$repo_multi"
git -C "$repo_multi" tag -a v1.8.73 -m v1.8.73
git -C "$repo_multi" tag -a v1.8.74 -m v1.8.74
if run_deploy_helper "$repo_multi" >"$work/multi.out" 2>&1; then
  fail "deploy helper accepted multiple numeric release tags on one commit"
fi
grep -qF 'multiple numeric release tags' "$work/multi.out" ||
  fail "deploy helper must reject ambiguous multiple release tags"

repo_dirty="$work/dirty"
init_repo "$repo_dirty"
publish_annotated_tag "$repo_dirty" v1.8.75
printf '%s\n' dirty > "$repo_dirty/untracked"
if run_deploy_helper "$repo_dirty" >"$work/dirty.out" 2>&1; then
  fail "deploy helper accepted a dirty release-tag checkout"
fi
grep -qF 'requires a clean release-tag checkout' "$work/dirty.out" ||
  fail "deploy helper must reject dirty production deploy checkouts"

repo_nested="$work/nested-root"
init_repo "$repo_nested"
publish_annotated_tag "$repo_nested" v1.8.76
mkdir -p "$repo_nested/phase4-coordinator"
printf '%s\n' root-dirty > "$repo_nested/root-untracked"
if run_deploy_helper "$repo_nested/phase4-coordinator" >"$work/nested-dirty.out" 2>&1; then
  fail "deploy helper accepted a dirty repository root when called with the coordinator module"
fi
grep -qF 'requires a clean release-tag checkout' "$work/nested-dirty.out" ||
  fail "deploy helper must reject root-level dirtiness, not only module dirtiness"

(
  # shellcheck disable=SC1090
  . "$extract_provenance_helper"
  if _coordinator_verify_deployed_version '{"version":"v1.8.76"}' v1.8.76 >"$work/provenance-match.out" 2>&1; then
    grep -qF 'provenance OK' "$work/provenance-match.out" ||
      fail "matching deployed release must report provenance OK"
  else
    fail "matching deployed release was rejected"
  fi
  if _coordinator_verify_deployed_version '{"version":"v1.8.75"}' v1.8.76 >"$work/provenance-mismatch.out" 2>&1; then
    fail "mismatched deployed release was warning-only"
  fi
  grep -qF 'aborting deploy: provenance mismatch' "$work/provenance-mismatch.out" ||
    fail "mismatched deployed release must abort before commit"
  if _coordinator_verify_deployed_version '{"status":"ok"}' v1.8.76 >"$work/provenance-missing.out" 2>&1; then
    fail "missing deployed release version was accepted"
  fi
  grep -qF 'CRITICAL provenance MISSING' "$work/provenance-missing.out" ||
    fail "missing deployed release version must abort before commit"
)

echo "PASS: coordinator release tag guards reject git-describe deploy footguns"
