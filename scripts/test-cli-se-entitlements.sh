#!/usr/bin/env bash
# Guard the SE keychain access-group contract: Swift default, entitlements
# plist, and Developer ID signing must name the same Team-ID group.
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

[[ -f "$ents" ]] || fail "missing CLI entitlements: $ents"
[[ -x "$require" ]] || fail "require-cli-se-entitlements.sh must be executable"
grep -Fq "$group" "$ents" || fail "entitlements plist lacks $group"
grep -Fq "keychain-access-groups" "$ents" || fail "entitlements plist lacks keychain-access-groups"
if grep -Fq "com.apple.application-identifier" "$ents"; then
  fail "CLI entitlements must not include restricted application-identifier (Developer ID has no profile)"
fi
grep -Fq "static let production = \"$group\"" "$swift" ||
  fail "Swift production access group must be $group"
if grep -Fq "REPLACEME" "$swift"; then
  fail "SecureEnclaveIdentity still contains REPLACEME placeholder"
fi
grep -Fq -- "--entitlements phase3-binary/dist/macprovider-cli.entitlements" "$release" ||
  fail "release.yml CLI codesign must attach macprovider-cli.entitlements"
grep -Fq "bash scripts/require-cli-se-entitlements.sh" "$release" ||
  fail "release.yml must prove the signed CLI carries the SE access group"
grep -Fq -- "--entitlements phase3-binary/dist/macprovider-cli.entitlements" "$acceptance" ||
  fail "acceptance signer CLI codesign must attach macprovider-cli.entitlements"
grep -Fq "require-cli-se-entitlements.sh" "$acceptance" ||
  fail "acceptance signer must prove the signed CLI carries the SE access group"
grep -Fq "require-cli-se-entitlements.sh" "$verifier" ||
  fail "Malibu artifact verifier must prove the signed CLI carries the SE access group"
grep -Fq -- "--entitlements phase3-binary/dist/macprovider-cli.entitlements" "$posture" ||
  fail "release security posture test must pin CLI entitlements signing"
grep -Fq -- "--entitlements phase3-binary/dist/macprovider-cli.entitlements" "$acceptance_test" ||
  fail "acceptance security test must pin CLI entitlements signing"

printf '[test-cli-se-entitlements] ok\n'
