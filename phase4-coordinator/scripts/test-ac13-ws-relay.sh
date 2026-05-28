#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export GOCACHE="${GOCACHE:-/private/tmp/macprovider-go-build-cache}"

go test ./internal/ws ./internal/buyer -run 'TestRelayDispatchRoutesChunkAndEndByRequestID|TestChatCompletionsWSTunneledNonStreaming' -count=1
