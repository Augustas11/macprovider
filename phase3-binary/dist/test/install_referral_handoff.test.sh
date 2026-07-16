#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installer="$root/phase3-binary/dist/install.sh"

python3 - "$installer" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

capture = 'REFERRAL_CODE_SOURCE_FILE="${MACPROVIDER_REFERRAL_CODE_FILE:-}"'
unset = "unset MACPROVIDER_REFERRAL_CODE_FILE"
first_child = 'GITHUB_REPO="${MACPROVIDER_GITHUB_REPO:-Augustas11/macprovider}"'
assert capture in source
assert unset in source
assert source.index(capture) < source.index(unset) < source.index(first_child)

assert 'bootstrap_auth_args+=(--referral-code-file "$REFERRAL_CODE_SOURCE_FILE")' in source
assert 'run_macprovider_cli_with_amfi_retry "${bootstrap_auth_args[@]}"' in source
assert '20|21|22|23|24|25|26|27)' in source
publish = "publish_bootstrap_identity_for_rollback"
bootstrap = 'run_macprovider_cli_with_amfi_retry "${bootstrap_auth_args[@]}"'
ensure_start = source.index("ensure_provider_credentials()")
ensure_end = source.index("submit_required_hardware_evidence()", ensure_start)
ensure_source = source[ensure_start:ensure_end]
assert ensure_source.index(publish) < ensure_source.index(bootstrap)

# The path may be passed to the CLI, but install.sh must never open, print,
# copy, hash, or persist the referral file itself.
for forbidden in (
    'cat "$REFERRAL_CODE_SOURCE_FILE"',
    'cp "$REFERRAL_CODE_SOURCE_FILE"',
    'log "$REFERRAL_CODE_SOURCE_FILE"',
    'printf "$REFERRAL_CODE_SOURCE_FILE"',
):
    assert forbidden not in source, forbidden
PY

echo "install_referral_handoff: PASS"
