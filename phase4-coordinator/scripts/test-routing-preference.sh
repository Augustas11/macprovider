#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export GOCACHE="${GOCACHE:-/private/tmp/macprovider-go-build-cache}"

go test ./internal/buyer -run 'TestChatCompletionsRoutingPreferences|TestChatCompletionsContextLengthRoutesOrReturns413' -count=1
