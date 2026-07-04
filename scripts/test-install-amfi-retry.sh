#!/usr/bin/env bash
# Hermetic regression guard for install.sh's post-install
# AMFI/Taskgated SIGKILL retry + inode-refresh helper.
#
# Extracts `run_macprovider_cli_with_amfi_retry` from install.sh, wires
# it against a mock `macprovider-cli` whose exit behavior is scripted
# per scenario, and asserts:
#
#   1. Happy path: rc 0 first try → helper returns 0, no sleep, no
#      retry log emitted.
#   2. Exit 10 pass-through: autotune's "recommendation stale" signal
#      must reach the caller unchanged; must NOT be retried as if it
#      were a SIGKILL.
#   3. SIGKILL-then-success (FLAVOR 1): rc 137 first try, rc 0 on 2s
#      retry → helper returns 0, emits the transient-race log only.
#   4. SIGKILL-thrice: rc 137 on all three attempts (initial, 2s
#      retry, inode-refresh retry) → helper returns 137, emits all
#      three diagnostic lines (transient-race, inode-refresh,
#      genuine-signature-failure).
#   5. Non-137 non-zero pass-through: rc 1 first try → helper returns
#      1, no retry.
#   6. Caller pattern A — `if HELPER; then ...; else rc=$?; ...`: the
#      caller must observe the CLI's original exit code in `$?` inside
#      the else branch, matching install.sh's freshness-check call
#      site.
#   7. Caller pattern B — `HELPER ... || die`: non-zero triggers the
#      `||` branch, matching install.sh's donor-mode call site.
#   8. `set -e` preservation: after the helper returns (through `if`
#      or `||`), the enclosing shell's -e state is unchanged. The
#      helper must NOT accidentally leak `set +e/-e` toggles into the
#      caller.
#   9. SIGKILL-twice-then-success (FLAVOR 2): rc 137 on initial + 2s
#      retry, rc 0 on the inode-refresh retry → helper returns 0,
#      emits the transient-race + inode-refresh logs, does NOT emit
#      the genuine-signature-failure log. The binary's inode must
#      differ before vs. after (proving cp/rm/cp actually ran).
#  10. Inode-refresh idempotent on non-137 rc: if attempt 2 succeeds
#      via FLAVOR 1 fix, the inode is NOT touched (proving the helper
#      does not do unnecessary filesystem work).
#
# Motivating incidents:
#   - 2026-07-03 fresh v1.7.9 install on Apple M5 macOS 26.5.
#     `installer -pkg` succeeded, Gatekeeper accepted the package,
#     but the first `autotune --recommend --freshness-check` was
#     SIGKILL'd with a CODESIGNING "Taskgated Invalid Signature"
#     verdict and the install aborted. FLAVOR 1: the same command
#     re-run manually by the same shell moments later succeeded.
#   - 2026-07-03 fresh v1.7.10 install on the same M5. This time BOTH
#     the first invocation AND the 2s-later retry were SIGKILL'd
#     persistently, but the SAME binary content ran cleanly when
#     copied to a different path. FLAVOR 2: the AMFI kernel cache
#     had a stuck rejection tied to the specific inode
#     `installer -pkg` created; `rm` + fresh `cp` gave the file a
#     new inode and AMFI re-evaluated successfully.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

fatal() {
  printf '[install-amfi-retry-test] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$INSTALL_SH" ] || fatal "missing installer: $INSTALL_SH"

# Extract the helper function block from install.sh. The helper begins
# at the `run_macprovider_cli_with_amfi_retry()` line and ends at the
# next top-level `}` at column 0.
lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-amfi-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-amfi.XXXXXX")"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT

awk '
  /^run_macprovider_cli_with_amfi_retry\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" > "$lib"

if ! grep -q '^run_macprovider_cli_with_amfi_retry()' "$lib"; then
  fatal "could not extract run_macprovider_cli_with_amfi_retry from $INSTALL_SH"
fi

# shellcheck source=/dev/null
. "$lib"

# Test rig: INSTALL_DIR must exist and contain a mock macprovider-cli
# whose behavior is controllable per scenario.
INSTALL_DIR="$workdir/install"
mkdir -p "$INSTALL_DIR"

# Capture the helper's log output for assertion. `log` is a script-
# level function in install.sh; the extraction above pulls only the
# helper, so we define `log` here for the tests.
LOG_FILE="$workdir/log.out"
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

reset_log() { : > "$LOG_FILE"; }
log_contains() { grep -q -- "$1" "$LOG_FILE"; }
log_line_count() { wc -l < "$LOG_FILE" | tr -d ' '; }

install_mock() {
  # Writes a mock macprovider-cli that follows the given script body.
  cat > "$INSTALL_DIR/macprovider-cli" <<MOCK
#!/usr/bin/env bash
$1
MOCK
  chmod +x "$INSTALL_DIR/macprovider-cli"
}

COUNTER_FILE="$workdir/counter"

pass=0
fail=0
report() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass=$((pass + 1))
    printf 'PASS %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s: want=%q got=%q\n' "$name" "$want" "$got" >&2
  fi
}

################################################################
# Case 1 — success first try
################################################################
reset_log
install_mock 'exit 0'
rc=0
run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1 || rc=$?
report "case1-success-first-try" 0 "$rc"
report "case1-no-retry-log" 0 "$(log_line_count)"

################################################################
# Case 2 — exit 10 (autotune "stale") pass-through, no retry
################################################################
reset_log
install_mock 'exit 10'
rc=0
run_macprovider_cli_with_amfi_retry autotune --recommend --freshness-check >/dev/null 2>&1 || rc=$?
report "case2-exit-10-stale-passthrough" 10 "$rc"
report "case2-no-retry-log-on-exit-10" 0 "$(log_line_count)"

################################################################
# Case 3 — SIGKILL on first, success on 2s retry (FLAVOR 1)
################################################################
reset_log
rm -f "$COUNTER_FILE"
install_mock "
n=\$(cat \"$COUNTER_FILE\" 2>/dev/null || echo 0)
n=\$((n + 1))
echo \"\$n\" > \"$COUNTER_FILE\"
if [ \"\$n\" -eq 1 ]; then kill -KILL \$\$; fi
exit 0
"
rc=0
run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1 || rc=$?
report "case3-sigkill-then-success-rc" 0 "$rc"
if log_contains "Retrying once after 2s"; then
  report "case3-first-retry-log-emitted" yes yes
else
  report "case3-first-retry-log-emitted" yes no
fi
if log_contains "AMFI cache may be pinned to the pkg-installer inode"; then
  report "case3-inode-refresh-log-not-emitted" no yes
else
  report "case3-inode-refresh-log-not-emitted" no no
fi

################################################################
# Case 4 — SIGKILL thrice (initial + 2s retry + inode-refresh retry)
# → rc 137 with all three diagnostic lines emitted.
################################################################
reset_log
rm -f "$COUNTER_FILE"
install_mock 'kill -KILL $$'
rc=0
run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1 || rc=$?
report "case4-sigkill-thrice-rc" 137 "$rc"
if log_contains "Retrying once after 2s"; then
  report "case4-first-retry-log-emitted" yes yes
else
  report "case4-first-retry-log-emitted" yes no
fi
if log_contains "AMFI cache may be pinned to the pkg-installer inode"; then
  report "case4-inode-refresh-log-emitted" yes yes
else
  report "case4-inode-refresh-log-emitted" yes no
fi
if log_contains "SIGKILL'd after the inode refresh"; then
  report "case4-genuine-signature-failure-log-emitted" yes yes
else
  report "case4-genuine-signature-failure-log-emitted" yes no
fi

################################################################
# Case 5 — non-137 non-zero (e.g. rc=1) pass-through, no retry
################################################################
reset_log
install_mock 'exit 1'
rc=0
run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1 || rc=$?
report "case5-exit-1-passthrough" 1 "$rc"
report "case5-no-retry-log-on-exit-1" 0 "$(log_line_count)"

################################################################
# Case 6 — `if HELPER; then ...; else rc=$?` pattern from
# install.sh's freshness-check call site preserves original exit
# code in the else branch.
################################################################
reset_log
install_mock 'exit 10'
inner_rc=-1
if run_macprovider_cli_with_amfi_retry autotune --recommend --freshness-check >/dev/null 2>&1; then
  inner_rc=0
else
  inner_rc=$?
fi
report "case6-if-else-preserves-original-exit" 10 "$inner_rc"

################################################################
# Case 7 — `HELPER ... || die` pattern from install.sh's donor-mode
# call site fires the `||` branch on non-zero.
################################################################
reset_log
install_mock 'exit 2'
triggered=0
run_macprovider_cli_with_amfi_retry autotune --recommend --apply --donor-mode >/dev/null 2>&1 || triggered=1
report "case7-or-die-triggered-on-non-zero" 1 "$triggered"

################################################################
# Case 8 — set -e state is unchanged in the caller after the
# helper returns (both success and non-zero paths).
################################################################
reset_log
install_mock 'exit 0'
run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1 || true
case "$-" in *e*) e_after_success=1 ;; *) e_after_success=0 ;; esac
report "case8-set-e-preserved-after-success" 1 "$e_after_success"

reset_log
install_mock 'exit 10'
if run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1; then :; else :; fi
case "$-" in *e*) e_after_nonzero=1 ;; *) e_after_nonzero=0 ;; esac
report "case8-set-e-preserved-after-nonzero" 1 "$e_after_nonzero"

################################################################
# Case 9 — SIGKILL-twice-then-success (FLAVOR 2). Initial + 2s
# retry both SIGKILL. After the inode refresh, the third attempt
# succeeds. Helper must return 0, emit the transient-race +
# inode-refresh logs, and NOT emit the genuine-signature-failure
# log. The binary's inode must differ before vs. after the refresh
# (proving cp/rm/cp actually ran).
################################################################
reset_log
rm -f "$COUNTER_FILE"
install_mock "
n=\$(cat \"$COUNTER_FILE\" 2>/dev/null || echo 0)
n=\$((n + 1))
echo \"\$n\" > \"$COUNTER_FILE\"
if [ \"\$n\" -le 2 ]; then kill -KILL \$\$; fi
echo \"third-attempt-ok\"
exit 0
"
inode_before="$(ls -i "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')"
rc=0
out="$(run_macprovider_cli_with_amfi_retry autotune --recommend 2>&1)" || rc=$?
inode_after="$(ls -i "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')"
report "case9-sigkill-twice-then-success-rc" 0 "$rc"
if [ "$inode_before" != "$inode_after" ]; then
  report "case9-inode-changed-after-refresh" changed changed
else
  report "case9-inode-changed-after-refresh" changed same
fi
if log_contains "Retrying once after 2s"; then
  report "case9-first-retry-log-emitted" yes yes
else
  report "case9-first-retry-log-emitted" yes no
fi
if log_contains "AMFI cache may be pinned to the pkg-installer inode"; then
  report "case9-inode-refresh-log-emitted" yes yes
else
  report "case9-inode-refresh-log-emitted" yes no
fi
if log_contains "SIGKILL'd after the inode refresh"; then
  report "case9-genuine-signature-failure-log-not-emitted" no yes
else
  report "case9-genuine-signature-failure-log-not-emitted" no no
fi
if echo "$out" | grep -q "third-attempt-ok"; then
  report "case9-third-attempt-output-visible" yes yes
else
  report "case9-third-attempt-output-visible" yes no
fi

################################################################
# Case 10 — FLAVOR 1 success does NOT touch the inode. If the 2s
# retry succeeds, we must NOT do the cp/rm/cp dance (defends against
# unnecessary filesystem work).
################################################################
reset_log
rm -f "$COUNTER_FILE"
install_mock "
n=\$(cat \"$COUNTER_FILE\" 2>/dev/null || echo 0)
n=\$((n + 1))
echo \"\$n\" > \"$COUNTER_FILE\"
if [ \"\$n\" -eq 1 ]; then kill -KILL \$\$; fi
exit 0
"
inode_before="$(ls -i "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')"
rc=0
run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1 || rc=$?
inode_after="$(ls -i "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')"
report "case10-flavor1-success-rc" 0 "$rc"
if [ "$inode_before" = "$inode_after" ]; then
  report "case10-inode-unchanged-on-flavor1-success" same same
else
  report "case10-inode-unchanged-on-flavor1-success" same changed
fi

################################################################
# Summary
################################################################
printf -- '---\n'
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
