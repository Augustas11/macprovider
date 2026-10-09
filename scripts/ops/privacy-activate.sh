#!/usr/bin/env bash
# Configuration-only SPEC-049 §8.3 activation; never cuts a runtime or CLI.
# Use status, next, then MACPROVIDER_OPS_OWNER=<session> next --run.
set -euo pipefail
OPS_NAME=privacy-activate
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() { printf 'Usage: %s status | next [--run]\n' "$0"; }

remote_state() {
  [ -n "${PEARL_SSH:-}" ] || die 'PEARL_SSH is required'
  ssh -o BatchMode=yes "$PEARL_SSH" python3 - "$@" < "$OPS_DIR/lib/privacy-activation.py"
}

gather() {
  OPS_SCOPE=privacy-224-entry251
  if [ "${PRIVACY_ACTIVATION_DISABLE:-0}" = 1 ]; then
    set_next disable mutate 'Disable private routing durably; preserve ordinary traffic' \
      'bash scripts/ops/privacy-activate.sh _disable'
    next_meta disable docs/runbooks/privacy-network-activation.md 'none; no service restart'
    return
  fi
  remote_state status > "$OPS_TMP_DIR/privacy.json" || die 'privacy preflight failed'
  local approved
  approved="$(json_field "$OPS_TMP_DIR/privacy.json" 'd["approved"]')"
  fact approved_identity_224 "$approved"
  if [ "$(json_field "$OPS_TMP_DIR/privacy.json" 'd["disabled"]')" = true ]; then
    set_next disabled blocked 'Privacy kill switch is engaged' '' 'investigate the recorded incident before enabling'
  elif [ "$approved" != true ]; then
    set_next approve_identity mutate 'Approve verified signed CLI224 for eligible-network enrollment' \
      'bash scripts/ops/privacy-activate.sh _approve'
    next_meta approve_identity docs/runbooks/privacy-network-activation.md \
      'one coordinator restart, typically 13–40 seconds; no database copy or provider restart'
  else
    if ! marker_done "$OPS_SCOPE" buyer_confirmation; then
      set_next buyer_confirmation mutate 'Confirm private stream and nonstream buyers using the reference client' \
        'python3 scripts/ops/lib/privacy-buyer-confirm.py'
      next_meta buyer_confirmation docs/runbooks/privacy-network-activation.md \
        'none; four bounded buyer requests, no provider or coordinator restart' buyer_confirmation
    elif ! marker_done "$OPS_SCOPE" settlement_confirmation; then
      set_next settlement_confirmation manual 'Verify private settlement receipts and ordinary traffic; commit handback' \
        'Follow docs/runbooks/privacy-network-activation.md settlement receipt check and committed handback.'
    else
      set_next accepted done 'Buyer confirmation and settlement handback recorded for this bounded activation' ''
    fi
  fi
}

internal() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse 'use next --run'
  if [ "${1:-}" = _disable ]; then remote_state disable; return; fi
  [ "${1:-}" = _approve ] || die 'unknown internal command'
  local url='https://github.com/Augustas11/macprovider/releases/download/v1.8.224'
  curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 1048576 --max-time 60 "$url/pearl-release.json" -o "$OPS_TMP_DIR/release.json"
  curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 16384 --max-time 60 "$url/pearl-release.json.sig" -o "$OPS_TMP_DIR/release.sig"
  openssl dgst -sha256 -verify "$REPO_ROOT/ops/pearl-updater/release-signing-public.pem" \
    -signature "$OPS_TMP_DIR/release.sig" "$OPS_TMP_DIR/release.json" >&2
  local payload
  payload="$(python3 - "$OPS_TMP_DIR/release.json" <<'PY'
import base64, sys
print(base64.b64encode(open(sys.argv[1], 'rb').read()).decode())
PY
)"
  remote_state apply "$payload"
}

ops_main "$@"
