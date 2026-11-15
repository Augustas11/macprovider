#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# The protocol package lives once, at the repo root. Coordinator-only
# enrollment, store, and authority code stays in the coordinator module
# and calls that package. The gateway must not grow a second copy.
if [[ -d "$repo_root/phase5-gateway/internal/relayblind" ]]; then
  printf 'gateway relayblind copy must not exist\n' >&2
  exit 1
fi
for name in types.go crypto.go pin.go capability.go privacy.go privacy_reject.go directory.go; do
  if [[ -f "$repo_root/phase4-coordinator/internal/relayblind/$name" ]]; then
    printf 'coordinator still has a protocol copy of %s\n' "$name" >&2
    exit 1
  fi
  if [[ ! -f "$repo_root/relayblind/$name" ]]; then
    printf 'shared module is missing %s\n' "$name" >&2
    exit 1
  fi
done

(
  cd "$repo_root/relayblind"
  go test .
)
(
  cd "$repo_root/phase4-coordinator"
  go test ./internal/relayblind
)
(
  cd "$repo_root/phase5-gateway"
  go test ./cmd/relay-blind-client
)
