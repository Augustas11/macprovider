#!/usr/bin/env bash
# Hermetic checks for the SPEC-008 Phase 2 MDA artifact pack/check command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Default to a writable per-platform temp cache; /private/tmp is macOS-only
# and unwritable on Linux CI runners.
GOCACHE="${GOCACHE:-${TMPDIR:-/tmp}/macprovider-go-build-cache}"
export GOCACHE

cd "$REPO_ROOT/phase4-coordinator"
go test ./cmd/tier2-mda-artifact
printf '[tier2-mda-artifact-test] ok\n'
