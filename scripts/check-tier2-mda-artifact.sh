#!/usr/bin/env bash
# Validate a B6 provider MDA artifact and, when roots/challenge are supplied, coordinator acceptance.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GOCACHE="${GOCACHE:-/private/tmp/macprovider-go-build-cache}"
export GOCACHE

cd "$REPO_ROOT/phase4-coordinator"
exec go run ./cmd/tier2-mda-artifact check "$@"
