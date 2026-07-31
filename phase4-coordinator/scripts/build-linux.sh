#!/usr/bin/env bash
# build-linux.sh — produce version-stamped linux/amd64 coordinator binaries:
#   dist/coordinator-linux-amd64       — the long-running daemon (version-stamped)
#   dist/coordinator-cli-linux-amd64   — operator token-management CLI
#                                        (revoke-token / list-tokens /
#                                         prune-tokens / revoke-and-kick)
#   dist/stats-inventory-sync-linux-amd64
#                                      — operator hardware inventory sync
#   dist/stats-billing-mirror-linux-amd64
#                                      — SQLite→Postgres stats billing mirror
#   dist/stats-hardware-verifier-linux-amd64
#                                      — autotune hardware evidence verifier
#
# Production builds must run from exactly one numeric release tag (vX.Y.Z).
# Set ALLOW_NON_RELEASE_COORDINATOR_BUILD=1 only for local/dev artifacts; that
# opt-out restores the old git-describe stamp and is not accepted by the Pearl
# production deploy.
#
# Refuses to build with uncommitted changes by default; set FORCE_DIRTY=1
# to override only together with ALLOW_NON_RELEASE_COORDINATOR_BUILD=1 (the
# resulting dev binary's version string will end in "-dirty" via
# `git describe --dirty` for modified-tracked dirty, or "-dirty-forced"
# appended below for untracked-only dirty).
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE_DIR="$(pwd -P)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

_coordinator_release_tag_version() {
  local candidates count tag head rows tag_object peeled_count peeled_commit tag_type verify_output remote_url
  local release_tag_remote="origin"
  local release_tag_remote_url="https://github.com/Augustas11/macprovider.git"
  local release_tag_signer_line='Good "git" signature for augstar@gmail.com with ED25519 key SHA256:6DgoKNaOgF5c7NPHTAbNxJ2LT0uuj8U/3zObOOZjRiA'
  candidates="$(git -C "$REPO_ROOT" tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  count="$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  case "$count" in
    1)
      tag="$candidates"
      ;;
    0)
      echo "refusing production coordinator build: HEAD is not exactly a numeric release tag (vX.Y.Z)" >&2
      echo "  Build production coordinator artifacts from the signed release tag, not from main or git describe output." >&2
      echo "  For local/dev artifacts only, set ALLOW_NON_RELEASE_COORDINATOR_BUILD=1." >&2
      return 1
      ;;
    *)
      echo "refusing production coordinator build: HEAD has multiple numeric release tags:" >&2
      printf '%s\n' "$candidates" | sed 's/^/  - /' >&2
      return 1
      ;;
  esac

  tag_type="$(git -C "$REPO_ROOT" cat-file -t "$tag" 2>/dev/null || true)"
  if [ "$tag_type" != tag ]; then
    echo "refusing production coordinator build: $tag is not an annotated signed release tag" >&2
    return 1
  fi
  if ! verify_output="$(git -C "$REPO_ROOT" verify-tag "$tag" 2>&1)"; then
    echo "refusing production coordinator build: $tag does not verify as a trusted signed tag" >&2
    return 1
  fi
  if ! printf '%s\n' "$verify_output" | grep -qxF "$release_tag_signer_line"; then
    echo "refusing production coordinator build: $tag was signed by an unauthorized release signer" >&2
    return 1
  fi
  remote_url="$(git -C "$REPO_ROOT" remote get-url "$release_tag_remote" 2>/dev/null || true)"
  case "$remote_url" in
    https://github.com/Augustas11/macprovider.git|git@github.com:Augustas11/macprovider.git|ssh://git@github.com/Augustas11/macprovider.git) ;;
    *)
      echo "refusing production coordinator build: $release_tag_remote must point at the canonical Augustas11/macprovider GitHub repository" >&2
      return 1
      ;;
  esac
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  rows="$(git -C "$REPO_ROOT" ls-remote "$release_tag_remote_url" "refs/tags/$tag" "refs/tags/$tag^{}")"
  tag_object="$(printf '%s\n' "$rows" | awk -v ref="refs/tags/$tag" '$2 == ref { print $1 }')"
  peeled_commit="$(printf '%s\n' "$rows" | awk -v ref="refs/tags/$tag^{}" '$2 == ref { print $1 }')"
  peeled_count="$(printf '%s\n' "$peeled_commit" | awk 'NF { count++ } END { print count + 0 }')"
  if [ -z "$tag_object" ] || [ "$peeled_count" != 1 ] || [ "$peeled_commit" != "$head" ]; then
    echo "refusing production coordinator build: $tag is not the protected remote annotated tag for HEAD on $release_tag_remote" >&2
    return 1
  fi
  printf '%s %s\n' "$tag" "$head"
}

# `git status --porcelain` catches BOTH modified-tracked AND untracked
# files (relative to this module's pwd). `git diff --quiet` would miss a
# new .go file dropped in by an emergency hotfix, which would then ship
# in a binary whose -ldflags-stamped version still reports "clean" via
# `git describe` (which also ignores untracked files for its --dirty
# suffix). See M0-5 Phase 1 follow-up.
DIRTY_STATE="$(git -C "$REPO_ROOT" status --porcelain)"
if [ -n "${FORCE_DIRTY:-}" ] && [ "${ALLOW_NON_RELEASE_COORDINATOR_BUILD:-0}" != "1" ]; then
  echo "refusing FORCE_DIRTY for production coordinator build" >&2
  echo "  FORCE_DIRTY is only allowed with ALLOW_NON_RELEASE_COORDINATOR_BUILD=1 for local/dev artifacts." >&2
  exit 1
fi
if [ -z "${FORCE_DIRTY:-}" ] && [ -n "$DIRTY_STATE" ]; then
  echo "refusing to build with uncommitted or untracked changes (set FORCE_DIRTY=1 to override)" >&2
  git -C "$REPO_ROOT" status --short >&2
  exit 1
fi

BUILD_WORK_DIR="$SOURCE_DIR"
RELEASE_BUILD_INPUT_DIR=""
COORDINATOR_RELEASE_COMMIT=""
if [ "${ALLOW_NON_RELEASE_COORDINATOR_BUILD:-0}" = "1" ]; then
  VERSION="$(git describe --always --dirty --tags 2>/dev/null || git rev-parse --short HEAD)"
else
  COORDINATOR_RELEASE_IDENTITY="$(_coordinator_release_tag_version)"
  VERSION="${COORDINATOR_RELEASE_IDENTITY%% *}"
  COORDINATOR_RELEASE_COMMIT="${COORDINATOR_RELEASE_IDENTITY#* }"
  RELEASE_BUILD_INPUT_DIR="$(umask 077 && mktemp -d -t macprovider-release-build.XXXXXXXX)" || {
    echo "refusing production coordinator build: mktemp failed for verified release input snapshot" >&2
    exit 1
  }
  trap 'rm -rf "${RELEASE_BUILD_INPUT_DIR:-}"' EXIT HUP INT TERM
  git -C "$REPO_ROOT" archive --format=tar "$COORDINATOR_RELEASE_COMMIT" -- phase4-coordinator | tar -xf - -C "$RELEASE_BUILD_INPUT_DIR"
  BUILD_WORK_DIR="$RELEASE_BUILD_INPUT_DIR/phase4-coordinator"
fi
# `git describe --dirty` only marks modifications to tracked files. If
# FORCE_DIRTY=1 overrode an UNTRACKED-only dirty state (a brand-new file
# the operator hasn't `git add`'d yet), the version stamp would otherwise
# look clean — defeating the rollback gate's ability to spot a forced
# build. Append "-dirty-forced" in that case so the binary's /healthz
# response self-identifies as an override build.
if [ -n "${FORCE_DIRTY:-}" ] && [ -n "$DIRTY_STATE" ]; then
  case "$VERSION" in
    *-dirty) ;;  # git describe already marked the modified-tracked path
    *) VERSION="${VERSION}-dirty-forced" ;;
  esac
fi

OUT="$SOURCE_DIR/dist/coordinator-linux-amd64"
mkdir -p "$SOURCE_DIR/dist"
(cd "$BUILD_WORK_DIR" && GOENV=off GOFLAGS='' GOWORK=off GOOS=linux GOARCH=amd64 go build -ldflags "-X main.version=${VERSION}" -o "$OUT" ./cmd/coordinator)
echo "built $OUT @ ${VERSION}"

# coordinator-cli ships alongside the daemon so the operator has token
# management (revoke-token, list-tokens, prune-tokens, revoke-and-kick)
# available on Pearl without sqlite3 surgery. SPEC-003 v0.8.3 narrowed
# the FR-C9.4 lockout class but did NOT eliminate it (used-token
# persist-failure still requires manual revoke); the CLI also covers
# routine prune-tokens / list-tokens. No version stamp — the CLI has
# no main.version symbol; the deploy script logs which build it just
# installed.
CLI_OUT="$SOURCE_DIR/dist/coordinator-cli-linux-amd64"
(cd "$BUILD_WORK_DIR" && GOENV=off GOFLAGS='' GOWORK=off GOOS=linux GOARCH=amd64 go build -o "$CLI_OUT" ./cmd/coordinator-cli)
echo "built $CLI_OUT @ ${VERSION}"

INVENTORY_OUT="$SOURCE_DIR/dist/stats-inventory-sync-linux-amd64"
(cd "$BUILD_WORK_DIR" && GOENV=off GOFLAGS='' GOWORK=off GOOS=linux GOARCH=amd64 go build -o "$INVENTORY_OUT" ./cmd/stats-inventory-sync)
echo "built $INVENTORY_OUT @ ${VERSION}"

BILLING_MIRROR_OUT="$SOURCE_DIR/dist/stats-billing-mirror-linux-amd64"
(cd "$BUILD_WORK_DIR" && GOENV=off GOFLAGS='' GOWORK=off GOOS=linux GOARCH=amd64 go build -o "$BILLING_MIRROR_OUT" ./cmd/stats-billing-mirror)
echo "built $BILLING_MIRROR_OUT @ ${VERSION}"

HARDWARE_VERIFIER_OUT="$SOURCE_DIR/dist/stats-hardware-verifier-linux-amd64"
(cd "$BUILD_WORK_DIR" && GOENV=off GOFLAGS='' GOWORK=off GOOS=linux GOARCH=amd64 go build -o "$HARDWARE_VERIFIER_OUT" ./cmd/stats-hardware-verifier)
echo "built $HARDWARE_VERIFIER_OUT @ ${VERSION}"
