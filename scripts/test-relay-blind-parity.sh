#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
coordinator="$repo_root/phase4-coordinator/internal/relayblind"
gateway="$repo_root/phase5-gateway/internal/relayblind"

for name in types.go crypto.go pin.go crypto_test.go; do
  cmp "$coordinator/$name" "$gateway/$name"
done

(
  cd "$repo_root/phase4-coordinator"
  go test ./internal/relayblind
)
(
  cd "$repo_root/phase5-gateway"
  go test ./internal/relayblind ./cmd/relay-blind-client
)
