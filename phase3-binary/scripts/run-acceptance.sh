#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/test-startup-failure.sh"
"$SCRIPT_DIR/test-config-precedence.sh"
"$SCRIPT_DIR/test-health.sh"
"$SCRIPT_DIR/test-coordinator.sh"
"$SCRIPT_DIR/test-warm-up.sh"
"$SCRIPT_DIR/test-sigterm-drain.sh"
"$SCRIPT_DIR/harness-cooperative.sh"
"$SCRIPT_DIR/harness-adversarial.sh"

echo "acceptance scripts completed"
