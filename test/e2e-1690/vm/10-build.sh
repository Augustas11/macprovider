#!/usr/bin/env bash
# VM step 10: build old + new linux/amd64 coordinator (+cli, sidecars) and
# gateway with the repo's own `make build-linux` (non-release build: the
# scratch tags are not the protected signed release tags), plus the test
# tools. Output cached under /root/e2e/bins/<old|new>/.
set -euo pipefail
. /root/e2e/h/vm/lib.sh
for side in old new; do
  wt=/root/e2e/wt-$side
  out=/root/e2e/bins/$side
  if [ -x "$out/coordinator-linux-amd64" ] && [ "$(cat "$out/.commit" 2>/dev/null)" = "$(git -C "$wt" rev-parse HEAD)" ]; then
    log "build $side: cached"; continue
  fi
  log "build $side at $(git -C "$wt" describe --tags)"
  ( cd "$wt" && ALLOW_NON_RELEASE_COORDINATOR_BUILD=1 make build-linux ) >"$E2E_LOGS/build-$side.log" 2>&1 || { tail -30 "$E2E_LOGS/build-$side.log"; die "build $side failed"; }
  mkdir -p "$out"
  cp "$wt"/phase4-coordinator/dist/*-linux-amd64 "$wt/phase5-gateway/dist/gateway-linux-amd64" "$out/"
  git -C "$wt" rev-parse HEAD >"$out/.commit"
  # build outputs are gitignored except the verifier (as on 1693); keep the tree clean
  git -C "$wt" status --porcelain | grep -v '^?? phase4-coordinator/dist/stats-hardware-verifier-linux-amd64$' | grep . && die "build dirtied $side" || true
  log "built $side: $(sha256sum "$out/coordinator-linux-amd64" | cut -c1-16) gw $(sha256sum "$out/gateway-linux-amd64" | cut -c1-16)"
done
log "build tools"
( cd /root/e2e/h/fakeprov && GOFLAGS=-mod=mod go build -trimpath -o /root/e2e/bins/fakeprov . ) >"$E2E_LOGS/build-fakeprov.log" 2>&1 || { tail -30 "$E2E_LOGS/build-fakeprov.log"; die "fakeprov build failed"; }
( cd /root/e2e/h/faultproxy && go build -trimpath -o /root/e2e/bins/faultproxy . ) >"$E2E_LOGS/build-faultproxy.log" 2>&1 || { tail -30 "$E2E_LOGS/build-faultproxy.log"; die "faultproxy build failed"; }
log "tools built"
