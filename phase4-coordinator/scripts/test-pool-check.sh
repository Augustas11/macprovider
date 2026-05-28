#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export GOCACHE="${GOCACHE:-/private/tmp/macprovider-go-build-cache}"

go test ./internal/buyer -run 'TestPoolCheckReturnsProviderStateAnd404|TestPoolCheckRateLimitsPerIP|TestHealthzMountedOnBuyerHandler' -count=1
