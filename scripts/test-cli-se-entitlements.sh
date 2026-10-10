#!/usr/bin/env bash
# Guard the SE keychain contract for a Developer ID CLI: default keychain
# (no named access group), no restricted entitlements on signing.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
group="YF7XNRJUG4.live.malibu.provider"
ents="$root/phase3-binary/dist/macprovider-cli.entitlements"
swift="$root/phase3-binary/Sources/macprovider-cli/SecureEnclaveIdentity.swift"
release="$root/.github/workflows/release.yml"
acceptance="$root/scripts/sign-acceptance-candidate.sh"
verifier="$root/scripts/verify-malibu-release-artifacts.sh"
require="$root/scripts/require-cli-se-entitlements.sh"
posture="$root/scripts/test-release-security-posture.sh"
acceptance_test="$root/scripts/test-acceptance-candidate-security.sh"

fail() {
  printf '[test-cli-se-entitlements] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ ! -e "$ents" ]] || fail "CLI must not ship macprovider-cli.entitlements (AMFI-restricted)"
[[ -x "$require" ]] || fail "require-cli-se-entitlements.sh must be executable"
grep -Fq "static let namedProduction = \"$group\"" "$swift" ||
  fail "Swift namedProduction constant must remain $group for profiled overrides"
if grep -Fq "REPLACEME" "$swift"; then
  fail "SecureEnclaveIdentity still contains REPLACEME placeholder"
fi
if grep -Fq "static let production = \"$group\"" "$swift"; then
  fail "Swift must not default production CLI to the named keychain group"
fi
if grep -Fq -- "--entitlements phase3-binary/dist/macprovider-cli.entitlements" "$release"; then
  fail "release.yml CLI codesign must not attach macprovider-cli.entitlements"
fi
grep -Fq "bash scripts/require-cli-se-entitlements.sh" "$release" ||
  fail "release.yml must prove the signed CLI has no restricted entitlements"
if grep -Fq -- "--entitlements phase3-binary/dist/macprovider-cli.entitlements" "$acceptance"; then
  fail "acceptance signer CLI codesign must not attach macprovider-cli.entitlements"
fi
grep -Fq "require-cli-se-entitlements.sh" "$acceptance" ||
  fail "acceptance signer must prove the signed CLI has no restricted entitlements"
grep -Fq "require-cli-se-entitlements.sh" "$verifier" ||
  fail "Malibu artifact verifier must prove the signed CLI has no restricted entitlements"
grep -Fq "must not attach restricted keychain-access-groups entitlements" "$posture" ||
  fail "release security posture test must forbid CLI entitlements signing"
grep -Fq "must not attach CLI keychain-access-groups entitlements" "$acceptance_test" ||
  fail "acceptance security test must forbid CLI entitlements signing"
grep -Fq "carries restricted keychain-access-groups" "$require" ||
  fail "require-cli-se-entitlements.sh must reject keychain-access-groups"
grep -Fq "carries the restricted App Attest entitlement" "$require" ||
  fail "require-cli-se-entitlements.sh must reject the App Attest entitlement"
grep -Fq "the CLI must sign with none" "$require" ||
  fail "require-cli-se-entitlements.sh must reject any CLI entitlement"
# App Attest is granted to Malibu.app through its profile only.
app_ents="$root/phase3-binary/app/Malibu.entitlements"
local_ents="$root/phase3-binary/app/MalibuLocal.entitlements"
grep -Fq "com.apple.developer.devicecheck.app-attest-opt-in" "$app_ents" ||
  fail "Malibu.entitlements must declare the App Attest opt-in for release signing"
if grep -Fq "<key>" "$local_ents"; then
  fail "MalibuLocal.entitlements must stay empty so ad-hoc local builds can launch"
fi
for restricted in keychain-access-groups com.apple.application-identifier get-task-allow; do
  if grep -Fq "$restricted" "$app_ents"; then
    fail "Malibu.entitlements must not commit $restricted; it is derived from the profile at signing"
  fi
done

# Behavioural proof against throwaway ad-hoc binaries (macOS hosts only).
if command -v codesign >/dev/null 2>&1; then
  work="$(mktemp -d "${TMPDIR:-/tmp}/cli-se-ents-test.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  cp /usr/bin/true "$work/plain"
  codesign --force --sign - "$work/plain" >/dev/null 2>&1
  bash "$require" "$work/plain" || fail "an entitlement-free CLI must pass"
  cat > "$work/attest.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.developer.devicecheck.app-attest-opt-in</key><array><string>CDhash</string></array></dict></plist>
PLIST
  cp /usr/bin/true "$work/attest"
  codesign --force --sign - --entitlements "$work/attest.plist" "$work/attest" >/dev/null 2>&1 ||
    fail "could not sign the App Attest probe binary"
  if bash "$require" "$work/attest" 2>/dev/null; then
    fail "a CLI claiming App Attest must be rejected"
  fi
fi

printf '[test-cli-se-entitlements] ok\n'
