#!/usr/bin/env bash
# Guarded SPEC-008 Phase 1 observe-mode helper for Pearl VPS.
#
# Default mode is --plan: validate local signature + autotune/Tier-2 identity
# binding and print intended actions without changing external state.
#
# #608 finish: live --apply is RETIRED. Production Tier-2 mutation must use
# phase4-coordinator/dist/deploy-pearl-vps.sh (one release-bound transaction).
# Hermetic apply coverage lives in scripts/test-support/tier2-observe-apply-harness.sh.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/activate-tier2-observe.sh [--plan|--apply]

Environment:
  CATALOG             default: .omc/tier2/tier2-catalog.json
  PUBLIC_KEY_FILE     default: .omc/tier2/catalog-signing-key.pub
  AUTOTUNE_CANDIDATES default: phase3-binary/catalog/autotune/autotune-candidates.json
                      required for check-tier2-binding before plan (#608)
  Requires local go toolchain for signed catalog verification before plan
  Requires local python3 for autotune/Tier-2 identity binding before plan

Note: --apply is retired for live hosts. Use deploy-pearl-vps.sh.
USAGE
}

mode="plan"
case "${1:---plan}" in
  --plan) mode="plan" ;;
  --apply) mode="apply" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CATALOG="${CATALOG:-$REPO_ROOT/.omc/tier2/tier2-catalog.json}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-$REPO_ROOT/.omc/tier2/catalog-signing-key.pub}"
AUTOTUNE_CANDIDATES="${AUTOTUNE_CANDIDATES:-$REPO_ROOT/phase3-binary/catalog/autotune/autotune-candidates.json}"

PIN_DIR=""
CATALOG_OPERATOR=""
PUBLIC_KEY_OPERATOR=""
AUTOTUNE_OPERATOR=""
CATALOG_PIN_SHA=""

log() { printf '[tier2-activate] %s\n' "$*" >&2; }
die() { printf '[tier2-activate] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup_pins() {
  if [ -n "${PIN_DIR:-}" ] && [ -d "$PIN_DIR" ]; then
    case "$PIN_DIR" in
      */tier2-activate-pin.*) rm -rf "$PIN_DIR" ;;
    esac
  fi
}
trap cleanup_pins EXIT

require_file() {
  local path="$1"
  [ -f "$path" ] || die "missing file: $path"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi
  die "missing shasum or sha256sum"
}

pin_local_inputs() {
  require_file "$CATALOG"
  require_file "$PUBLIC_KEY_FILE"
  require_file "$AUTOTUNE_CANDIDATES"
  CATALOG_OPERATOR="$CATALOG"
  PUBLIC_KEY_OPERATOR="$PUBLIC_KEY_FILE"
  AUTOTUNE_OPERATOR="$AUTOTUNE_CANDIDATES"
  PIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tier2-activate-pin.XXXXXX")"
  chmod 700 "$PIN_DIR"
  cp "$CATALOG_OPERATOR" "$PIN_DIR/tier2-catalog.json"
  cp "$PUBLIC_KEY_OPERATOR" "$PIN_DIR/catalog-signing-key.pub"
  cp "$AUTOTUNE_OPERATOR" "$PIN_DIR/autotune-candidates.json"
  chmod 400 "$PIN_DIR/tier2-catalog.json" "$PIN_DIR/catalog-signing-key.pub" "$PIN_DIR/autotune-candidates.json"
  CATALOG="$PIN_DIR/tier2-catalog.json"
  PUBLIC_KEY_FILE="$PIN_DIR/catalog-signing-key.pub"
  AUTOTUNE_CANDIDATES="$PIN_DIR/autotune-candidates.json"
  CATALOG_PIN_SHA="$(sha256_file "$CATALOG")"
  log "pinned catalog/public-key/autotune bytes for verify+bind (catalog_sha256=$CATALOG_PIN_SHA)"
}

require_autotune_tier2_binding() {
  require_file "$AUTOTUNE_CANDIDATES"
  require_command python3
  if ! python3 "$REPO_ROOT/scripts/catalog-release.py" check-tier2-binding \
    --candidate "$AUTOTUNE_CANDIDATES" \
    --tier2 "$CATALOG"; then
    die "autotune/tier2 identity conflict: refusing Tier-2 plan. Use deploy-pearl-vps.sh with a matching release, or fix CATALOG / AUTOTUNE_CANDIDATES so check-tier2-binding passes."
  fi
  log "autotune/tier2 identity binding ok (candidate=$(basename "$AUTOTUNE_OPERATOR"))"
}

validate_local_inputs() {
  require_command go
  go run "$REPO_ROOT/scripts/sign-catalog.go" verify \
    -public-key "$PUBLIC_KEY_FILE" \
    "$CATALOG"
  require_autotune_tier2_binding
  local verify_sha
  verify_sha="$(sha256_file "$CATALOG")"
  if [ "$verify_sha" != "$CATALOG_PIN_SHA" ]; then
    die "pinned catalog bytes drifted after verify/bind (got $verify_sha want $CATALOG_PIN_SHA)"
  fi
}

print_plan() {
  log "validated local catalog, public key, and autotune/Tier-2 identity binding"
  cat <<PLAN
Plan only. No production state was changed.

#608: live Tier-2 mutation is retired from this helper. Prefer
phase4-coordinator/dist/deploy-pearl-vps.sh for one release transaction.
Would have uploaded pinned snapshot of $CATALOG_OPERATOR
(digest=$CATALOG_PIN_SHA) after check-tier2-binding vs $AUTOTUNE_OPERATOR.
PLAN
}

if [ "$mode" = "apply" ]; then
  die "--apply is retired for live Tier-2 mutation (#608). Use phase4-coordinator/dist/deploy-pearl-vps.sh so Tier-2 ships inside one release-bound transaction with check-tier2-binding. Hermetic apply coverage: scripts/test-support/tier2-observe-apply-harness.sh"
fi

pin_local_inputs
validate_local_inputs
print_plan
