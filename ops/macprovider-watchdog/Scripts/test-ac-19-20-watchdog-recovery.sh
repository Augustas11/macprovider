#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Compatibility entry point for the historical AC-19/20 watchdog test path.
# SPEC-020 v0.1.13 moved rollback mutation to installer/CLI recovery owners;
# the companion watchdog must now prove it does not mutate stale rollback state.
exec bash "$REPO_ROOT/phase3-binary/dist/test/watchdog_rollback_paths.test.sh"
