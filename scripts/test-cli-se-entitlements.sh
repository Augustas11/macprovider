#!/usr/bin/env bash
# Guard the SE keychain contract for a Developer ID CLI: default keychain
# (no named access group), no restricted entitlements on signing.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
group="YF7XNRJUG4.live.malibu.provider"
ents="$root/phase3-binary/dist/malibu-cli.entitlements"
swift="$root/phase3-binary/Sources/malibu-cli/SecureEnclaveIdentity.swift"
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

[[ ! -e "$ents" ]] || fail "CLI must not ship malibu-cli.entitlements (AMFI-restricted)"
[[ -x "$require" ]] || fail "require-cli-se-entitlements.sh must be executable"
grep -Fq "static let namedProduction = \"$group\"" "$swift" ||
  fail "Swift namedProduction constant must remain $group for profiled overrides"
if grep -Fq "REPLACEME" "$swift"; then
  fail "SecureEnclaveIdentity still contains REPLACEME placeholder"
fi
if grep -Fq "static let production = \"$group\"" "$swift"; then
  fail "Swift must not default production CLI to the named keychain group"
fi
if grep -Fq -- "--entitlements phase3-binary/dist/malibu-cli.entitlements" "$release"; then
  fail "release.yml CLI codesign must not attach malibu-cli.entitlements"
fi
grep -Fq "bash scripts/require-cli-se-entitlements.sh" "$release" ||
  fail "release.yml must prove the signed CLI has no restricted entitlements"
if grep -Fq -- "--entitlements phase3-binary/dist/malibu-cli.entitlements" "$acceptance"; then
  fail "acceptance signer CLI codesign must not attach malibu-cli.entitlements"
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

printf '[test-cli-se-entitlements] ok\n'
