#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export GOCACHE="${GOCACHE:-/private/tmp/macprovider-go-build-cache}"

echo "AC-6 graceful SIGTERM drain requires the external multi-stream harness and is not yet automated by unit tests." >&2
exit 2
