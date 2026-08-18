#!/usr/bin/env bash
# Fail unless a signed macprovider-cli carries the production
# keychain-access-groups entitlement. Unsigned local/CI builds are
# expected to lack this blob; only Developer ID release signing attaches it.
set -euo pipefail

binary="${1:-}"
group="YF7XNRJUG4.live.malibu.provider"
if [[ -z "$binary" || ! -f "$binary" ]]; then
  printf '[require-cli-se-entitlements] ERROR: missing macprovider-cli path\n' >&2
  exit 1
fi

ents="$(mktemp "${TMPDIR:-/tmp}/cli-se-ents.XXXXXX")"
cleanup() { rm -f "$ents"; }
trap cleanup EXIT

if ! codesign -d --entitlements "$ents" "$binary" >/dev/null 2>&1; then
  printf '[require-cli-se-entitlements] ERROR: could not dump entitlements from %s\n' "$binary" >&2
  exit 1
fi
if [[ ! -s "$ents" ]]; then
  printf '[require-cli-se-entitlements] ERROR: %s has an empty entitlements blob\n' "$binary" >&2
  exit 1
fi
if command -v plutil >/dev/null 2>&1; then
  plutil -convert xml1 "$ents" >/dev/null 2>&1 || true
fi
if ! grep -Fq "$group" "$ents"; then
  printf '[require-cli-se-entitlements] ERROR: %s lacks keychain-access-groups %s\n' "$binary" "$group" >&2
  exit 1
fi
if ! grep -Fq "keychain-access-groups" "$ents"; then
  printf '[require-cli-se-entitlements] ERROR: %s entitlements omit keychain-access-groups\n' "$binary" >&2
  exit 1
fi
