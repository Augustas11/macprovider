#!/usr/bin/env bash
# Print cdhash, TeamIdentifier, and Identifier from `codesign -dvvv`.
# Noninteractive. Used to build privacy_class.approved_code_identities.
# Multiple CDHash lines (one per architecture) are all printed.
set -euo pipefail

if [[ $# -ne 1 || -z ${1:-} || ${1:-} == -* ]]; then
  echo "usage: privacy-class-code-identity.sh <binary>" >&2
  exit 2
fi

binary=$1
if [[ ! -e $binary ]]; then
  echo "privacy-class-code-identity: not found: $binary" >&2
  exit 2
fi

set +e
details=$(codesign -dvvv "$binary" </dev/null 2>&1)
set -e

cdhashes=$(printf '%s\n' "$details" | awk '
  /^CDHash=/ {
    value = tolower(substr($0, index($0, "=") + 1))
    if (value != "") print value
  }
')
team=$(printf '%s\n' "$details" | awk '
  /^TeamIdentifier=/ { print substr($0, index($0, "=") + 1); exit }
')
identifier=$(printf '%s\n' "$details" | awk '
  /^Identifier=/ { print substr($0, index($0, "=") + 1); exit }
')

if [[ -z $cdhashes ]]; then
  echo "privacy-class-code-identity: missing CDHash" >&2
  exit 1
fi

while IFS= read -r cdhash; do
  [[ -z $cdhash ]] && continue
  if [[ ${#cdhash} -ne 40 || ! $cdhash =~ ^[0-9a-f]+$ ]]; then
    echo "privacy-class-code-identity: CDHash is not 40 lowercase hex" >&2
    exit 1
  fi
  printf 'cdhash=%s\n' "$cdhash"
done <<< "$cdhashes"

printf 'TeamIdentifier=%s\n' "$team"
printf 'Identifier=%s\n' "$identifier"
