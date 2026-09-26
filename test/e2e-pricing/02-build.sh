#!/usr/bin/env bash
# Tier E2 step 2: build the linux/amd64 coordinator + gateway (+ sidecars) at
# each scratch release tag with the repo's own `make build-linux`, and cache
# them under $E2E_WORK/bins/<tag>/. e2e_checkout_tag (lib/common.sh) restores
# the right set into the checkout before a deploy.
#
# build-linux.sh emits phase4-coordinator/dist/stats-hardware-verifier-linux-amd64,
# which older trees' .gitignore does not list (fixed in tree), so the deploy's
# clean-checkout check would fail right after a build at the pre-#1693 tag. The
# scratch clone excludes it via .git/info/exclude (local only).
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$E2E_REPO"
grep -qx 'phase4-coordinator/dist/stats-hardware-verifier-linux-amd64' .git/info/exclude ||
  echo 'phase4-coordinator/dist/stats-hardware-verifier-linux-amd64' >>.git/info/exclude
orig="$(git rev-parse --abbrev-ref HEAD)"
for tag in "$E2E_TAG_PRE" "$E2E_TAG_ENABLE" ${E2E_EXTRA_TAGS:-}; do
  git checkout -q "$tag"
  make build-linux >"$E2E_LOGS/build-$tag.log" 2>&1 || { tail -20 "$E2E_LOGS/build-$tag.log"; e2e_die "build at $tag failed"; }
  mkdir -p "$E2E_WORK/bins/$tag"
  cp phase4-coordinator/dist/*-linux-amd64 phase5-gateway/dist/gateway-linux-amd64 "$E2E_WORK/bins/$tag/"
  [ -z "$(git status --porcelain)" ] || e2e_die "build dirtied the checkout at $tag"
  bash "$E2E_HARNESS/lib/make-gh-release.sh" "$tag"
  e2e_log "built $tag: $(shasum -a 256 "$E2E_WORK/bins/$tag/coordinator-linux-amd64" | cut -c1-16)"
done
git checkout -q "$orig" 2>/dev/null || git checkout -q main
