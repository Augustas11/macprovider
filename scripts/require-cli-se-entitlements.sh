#!/usr/bin/env bash
# Fail if a signed macprovider-cli carries restricted entitlements.
# Developer ID naked CLIs cannot embed a provisioning profile; AMFI SIGKILLs
# keychain-access-groups / application-identifier without one (v1.8.96).
# Unsigned local/CI builds and 1.8.93-style empty blobs are expected.
set -euo pipefail

binary="${1:-}"
if [[ -z "$binary" || ! -f "$binary" ]]; then
  printf '[require-cli-se-entitlements] ERROR: missing macprovider-cli path\n' >&2
  exit 1
fi

ents="$(mktemp "${TMPDIR:-/tmp}/cli-se-ents.XXXXXX")"
cleanup() { rm -f "$ents"; }
trap cleanup EXIT

if codesign -d --entitlements "$ents" "$binary" >/dev/null 2>&1; then
  if [[ -s "$ents" ]] && command -v plutil >/dev/null 2>&1; then
    plutil -convert xml1 "$ents" >/dev/null 2>&1 || true
  fi
fi

if [[ -s "$ents" ]] && grep -Fq "keychain-access-groups" "$ents"; then
  printf '[require-cli-se-entitlements] ERROR: %s carries restricted keychain-access-groups (AMFI requires a profile)\n' "$binary" >&2
  exit 1
fi
if [[ -s "$ents" ]] && grep -Fq "com.apple.application-identifier" "$ents"; then
  printf '[require-cli-se-entitlements] ERROR: %s carries restricted application-identifier\n' "$binary" >&2
  exit 1
fi
