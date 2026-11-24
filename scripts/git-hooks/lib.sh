#!/usr/bin/env bash
# Shared by the versioned git hooks. Sourced, not executed.

# The operator's local secret preflight (not in this repo). Override the path
# with MACPROVIDER_SECRET_PREFLIGHT. A missing preflight fails the hook: the
# hook must not silently stop scanning for secrets.
run_secret_preflight() {
  local mode="$1" bin="${MACPROVIDER_SECRET_PREFLIGHT:-$HOME/.config/macprovider/bin/macprovider-secret-preflight}"
  if [ ! -x "$bin" ]; then
    printf 'git hook: secret preflight %s is missing or not executable; set MACPROVIDER_SECRET_PREFLIGHT\n' "$bin" >&2
    return 1
  fi
  MACPROVIDER_PREFLIGHT_MODE="$mode" "$bin" "$PWD"
}
