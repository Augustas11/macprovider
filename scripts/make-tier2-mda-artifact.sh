#!/usr/bin/env bash
# Package operator-provided Apple MDA certificate-chain/CSR evidence for B6 providers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GOCACHE="${GOCACHE:-/private/tmp/macprovider-go-build-cache}"
export GOCACHE

cd "$REPO_ROOT/phase4-coordinator"
exec go run ./cmd/tier2-mda-artifact make "$@"
