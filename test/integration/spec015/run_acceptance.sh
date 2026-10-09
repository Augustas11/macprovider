#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

run() {
  printf '\n== %s ==\n' "$1"
  shift
  (cd "$ROOT" && "$@")
}

# Every other SPEC-015 AC check runs in the job that owns it, with the same
# flags, so this runner no longer repeats them (#1920):
#   cross-service receipt, v0.4 settlement and AC-14 omission tests
#     -> integration (cross-service): go test -race -count=1 ./...
#   gateway header policy -> phase5-gateway (go vet + test)
#   coordinator receipt key lifecycle -> phase4-coordinator (go vet + test)
#   Swift provider receipts and the AC-16 p95 bound -> phase3-binary (swift test)
#   AC-15 nginx receipt buffers -> deploy tooling (check-deploy-config gate)
# The manifest run below prints which job covers each AC.

run "SPEC-015 AC-01 AC-02 AC-03 AC-04 AC-05 AC-06 AC-07 AC-08 AC-09 AC-10 AC-11 AC-12 AC-13 AC-14 AC-15 AC-16 AC-17 AC-18 AC-19 AC-20 AC-21 AC-22 AC-23 AC-24 AC-25 AC-26 AC-27 manifest report" bash -lc 'cd test/integration && go test -v -race -count=1 -timeout 5m ./spec015'
run "SPEC-015 AC-09 Python/Node SDKs against real local gateway" bash -lc 'cd test/integration && SPEC015_SDK_COMPAT_GATEWAY=1 go test -race -count=1 -timeout 10m . -run TestSpec015SDKCompatAgainstGateway'
