#!/usr/bin/env bash
# Main-owned lifecycle helpers for the transient Developer ID signing keychain.
# This file is sourced by sign-acceptance-candidate.sh.

acceptance_previous_default_keychain=""
acceptance_keychain_created=0
acceptance_keychain_restore_required=0

acceptance_keychain_capture_default() {
  local raw_default
  raw_default="$(security default-keychain -d user 2>/dev/null)" || return 1
  [[ -n "$raw_default" && "$raw_default" != *$'\n'* ]] || return 1
  raw_default="$(
    printf '%s\n' "$raw_default" |
      sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
  )"
  [[ -n "$raw_default" ]] || return 1
  acceptance_previous_default_keychain="$raw_default"
}

acceptance_keychain_create_and_select() {
  local keychain="$1"
  local password="$2"

  acceptance_keychain_created=0
  acceptance_keychain_restore_required=0
  security create-keychain -p "$password" "$keychain" || return 1
  acceptance_keychain_created=1
  # Set the restore flag before changing the default so even a partial failure
  # attempts to restore the captured state.
  acceptance_keychain_restore_required=1
  security default-keychain -d user -s "$keychain" || return 1
  security unlock-keychain -p "$password" "$keychain" || return 1
  security set-keychain-settings -lut 3600 "$keychain" || return 1
}

acceptance_keychain_cleanup() {
  local keychain="$1"
  local failed=0

  if [[ "$acceptance_keychain_restore_required" == 1 ]]; then
    security default-keychain -d user -s "$acceptance_previous_default_keychain" \
      >/dev/null 2>&1 || failed=1
  fi
  if [[ "$acceptance_keychain_created" == 1 ]]; then
    security delete-keychain "$keychain" >/dev/null 2>&1 || failed=1
  fi
  return "$failed"
}
