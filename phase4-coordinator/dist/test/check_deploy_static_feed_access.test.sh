#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"

grep -q 'chmod o+x /opt/macprovider' "$DEPLOY_SH" ||
  fail "deploy must chmod o+x /opt/macprovider for nginx static feed traversal"

# Step 3 must re-apply o+x immediately after install -d resets mode to 0750.
awk '
  /install -d -o root -g macprovider -m 0750 \/opt\/macprovider/ {
    if (!getline nxt || nxt !~ /chmod o\+x \/opt\/macprovider/) {
      exit 1
    }
  }
  END { exit 0 }
' "$DEPLOY_SH" || fail "step 3 must chmod o+x immediately after install -d /opt/macprovider"

grep -q 'sudo -u www-data test -r /opt/macprovider/static/autotune-candidates.json' "$DEPLOY_SH" ||
  fail "deploy smoke must verify www-data can read static feeds"

echo "PASS: deploy static feed nginx access guards present"
