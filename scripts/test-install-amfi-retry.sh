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
#      differ before vs. after (proving an atomic fresh-inode replacement ran).
#  10. Inode-refresh idempotent on non-137 rc: if attempt 2 succeeds
#      via FLAVOR 1 fix, the inode is NOT touched (proving the helper
#      does not do unnecessary filesystem work).
#  11. Primary install path uses the same atomic helper.
#  12. Replacement preserves exact bytes, installs mode 0755, and leaves no
#      staging file.
#  13. A missing source preserves the old target and cleans staging state.
#  14. A directory target is rejected rather than accepting `mv`-into-dir
#      semantics.
#  15. The helper fsyncs the staged bytes and containing directory around
#      `os.replace`, locking the crash-durability contract.
#  16. A post-replace durability failure is distinguished from a pre-replace
#      failure that leaves the old target installed.
#  17. The AMFI caller preserves that distinction and does not claim the old
#      inode remains after a committed-but-not-durably-confirmed replacement.
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
#     `installer -pkg` created; a fresh same-directory inode plus atomic
#     rename made AMFI re-evaluate successfully.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

fatal() {
  printf '[install-amfi-retry-test] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$INSTALL_SH" ] || fatal "missing installer: $INSTALL_SH"

# Extract the atomic replacement helper and the retry helper from install.sh.
lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-amfi-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-amfi.XXXXXX")"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT

awk '
  /^atomic_replace_provider_binary\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { closed++ }
  emit && closed == 2 { exit }
' "$INSTALL_SH" > "$lib"

if ! grep -q '^atomic_replace_provider_binary()' "$lib" \
  || ! grep -q '^run_macprovider_cli_with_amfi_retry()' "$lib"; then
  fatal "could not extract atomic replacement and AMFI retry helpers from $INSTALL_SH"
fi

# shellcheck source=/dev/null
. "$lib"

# Test rig: INSTALL_DIR must exist and contain a mock macprovider-cli
# whose behavior is controllable per scenario.
INSTALL_DIR="$workdir/install"
mkdir -p "$INSTALL_DIR"
export MACPROVIDER_CLI_EXECUTABLE="$INSTALL_DIR/macprovider-cli"

# Capture the helper's log output for assertion. `log` is a script-
# level function in install.sh; the extraction above pulls only the
# helper, so we define `log` here for the tests.
LOG_FILE="$workdir/log.out"
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

reset_log() { : > "$LOG_FILE"; }
log_contains() { grep -q -- "$1" "$LOG_FILE"; }
log_line_count() { wc -l < "$LOG_FILE" | tr -d ' '; }
inode_of() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.stat(sys.argv[1]).st_ino)
PY
}
mode_of() {
  python3 - "$1" <<'PY'
import os
import stat
import sys
print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))
PY
}

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
inode_before="$(inode_of "$INSTALL_DIR/macprovider-cli")"
rc=0
out="$(run_macprovider_cli_with_amfi_retry autotune --recommend 2>&1)" || rc=$?
inode_after="$(inode_of "$INSTALL_DIR/macprovider-cli")"
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
# retry succeeds, we must NOT replace the inode (defends against
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
inode_before="$(inode_of "$INSTALL_DIR/macprovider-cli")"
rc=0
run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1 || rc=$?
inode_after="$(inode_of "$INSTALL_DIR/macprovider-cli")"
report "case10-flavor1-success-rc" 0 "$rc"
if [ "$inode_before" = "$inode_after" ]; then
  report "case10-inode-unchanged-on-flavor1-success" same same
else
  report "case10-inode-unchanged-on-flavor1-success" same changed
fi

################################################################
# Case 11 — the primary install path must also activate the verified
# executable through the fresh-inode helper instead of overwriting an
# already-executed vnode in place.
################################################################
install_body="$(awk '
  /^install_binary\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH")"
# Exact source text is the assertion target.
# shellcheck disable=SC2016
if printf '%s\n' "$install_body" | grep -Fq \
  'atomic_replace_provider_binary "$staging_dir/macprovider-cli" "$real_binary"'; then
  report "case11-install-uses-atomic-fresh-inode" yes yes
else
  report "case11-install-uses-atomic-fresh-inode" yes no
fi
# Exact source text is the assertion target.
# shellcheck disable=SC2016
if printf '%s\n' "$install_body" | grep -Fq \
  'cp "$staging_dir/macprovider-cli" "$real_binary"'; then
  report "case11-install-avoids-in-place-overwrite" no yes
else
  report "case11-install-avoids-in-place-overwrite" no no
fi

################################################################
# Case 12 — direct activation preserves the verified bytes, installs
# executable mode 0755, changes the inode, and cleans staging state.
################################################################
atomic_dir="$workdir/atomic"
mkdir -p "$atomic_dir"
printf '%s\n' 'verified-provider-bytes' > "$atomic_dir/source"
printf '%s\n' 'old-provider-bytes' > "$atomic_dir/target"
chmod 600 "$atomic_dir/source" "$atomic_dir/target"
inode_before="$(inode_of "$atomic_dir/target")"
rc=0
atomic_replace_provider_binary "$atomic_dir/source" "$atomic_dir/target" || rc=$?
inode_after="$(inode_of "$atomic_dir/target")"
report "case12-atomic-replacement-rc" 0 "$rc"
if cmp -s "$atomic_dir/source" "$atomic_dir/target"; then
  report "case12-atomic-replacement-bytes" same same
else
  report "case12-atomic-replacement-bytes" same different
fi
report "case12-atomic-replacement-mode" 755 "$(mode_of "$atomic_dir/target")"
if [ "$inode_before" != "$inode_after" ]; then
  report "case12-atomic-replacement-inode" changed changed
else
  report "case12-atomic-replacement-inode" changed same
fi
report "case12-atomic-replacement-cleanup" 0 \
  "$(find "$atomic_dir" -maxdepth 1 -name '.macprovider-cli.install.*' | wc -l | tr -d ' ')"

################################################################
# Case 13 — pre-rename source failure leaves the prior target exact.
################################################################
printf '%s\n' 'preserve-this-target' > "$atomic_dir/target"
chmod 700 "$atomic_dir/target"
target_before_sha="$(shasum -a 256 "$atomic_dir/target" | awk '{print $1}')"
target_before_inode="$(inode_of "$atomic_dir/target")"
rc=0
atomic_replace_provider_binary "$atomic_dir/missing-source" "$atomic_dir/target" || rc=$?
if [ "$rc" -ne 0 ]; then
  report "case13-missing-source-rejected" rejected rejected
else
  report "case13-missing-source-rejected" rejected accepted
fi
report "case13-prior-target-bytes-preserved" "$target_before_sha" \
  "$(shasum -a 256 "$atomic_dir/target" | awk '{print $1}')"
report "case13-prior-target-inode-preserved" "$target_before_inode" \
  "$(inode_of "$atomic_dir/target")"
report "case13-staging-cleanup" 0 \
  "$(find "$atomic_dir" -maxdepth 1 -name '.macprovider-cli.install.*' | wc -l | tr -d ' ')"

################################################################
# Case 14 — a directory target must fail instead of receiving the
# temporary binary as a child through platform-specific mv behavior.
################################################################
mkdir -p "$atomic_dir/directory-target"
rc=0
atomic_replace_provider_binary "$atomic_dir/source" "$atomic_dir/directory-target" || rc=$?
if [ "$rc" -ne 0 ]; then
  report "case14-directory-target-rejected" rejected rejected
else
  report "case14-directory-target-rejected" rejected accepted
fi
report "case14-directory-target-remains-empty" 0 \
  "$(find "$atomic_dir/directory-target" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
report "case14-staging-cleanup" 0 \
  "$(find "$atomic_dir" -maxdepth 1 -name '.macprovider-cli.install.*' | wc -l | tr -d ' ')"

################################################################
# Case 15 — the implementation must durably order staged-file fsync,
# atomic replace, then directory fsync.
################################################################
atomic_body="$(awk '
  /^atomic_replace_provider_binary\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH")"
python3 - "$atomic_body" <<'PY'
import sys

body = sys.argv[1]
file_sync = body.index("os.fsync(temporary_fd)")
replace = body.index("os.replace(temporary, target)")
directory_sync = body.index("os.fsync(directory_fd)")
if not file_sync < replace < directory_sync:
    raise SystemExit("atomic replacement durability order is not file-fsync -> replace -> directory-fsync")
PY
report "case15-crash-durability-order" durable durable

################################################################
# Case 16 — diagnostics must distinguish a committed replacement whose
# directory durability is unconfirmed from a pre-replace failure.
################################################################
python3 - "$atomic_body" <<'PY'
import sys

body = sys.argv[1]
for required in (
    "replaced = False",
    "replaced = True",
    "if replaced:",
    "raise SystemExit(10)",
    "replacement occurred but directory durability could not be confirmed",
    "the prior target was left in place",
):
    if required not in body:
        raise SystemExit(f"missing atomic replacement state distinction: {required}")
PY
report "case16-post-replace-state-distinguished" exact exact

################################################################
# Case 17 — inject the post-replace durability status at the AMFI
# caller boundary and require exact, non-contradictory diagnostics.
################################################################
reset_log
install_mock 'kill -KILL $$'
atomic_replace_provider_binary() { return 10; }
rc=0
run_macprovider_cli_with_amfi_retry autotune --recommend >/dev/null 2>&1 || rc=$?
report "case17-post-replace-amfi-rc" 137 "$rc"
if log_contains "replacement occurred but directory durability was unconfirmed"; then
  report "case17-post-replace-log-present" yes yes
else
  report "case17-post-replace-log-present" yes no
fi
if log_contains "leaving the original binary in place"; then
  report "case17-no-contradictory-original-log" no yes
else
  report "case17-no-contradictory-original-log" no no
fi

################################################################
# Summary
################################################################
printf -- '---\n'
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
