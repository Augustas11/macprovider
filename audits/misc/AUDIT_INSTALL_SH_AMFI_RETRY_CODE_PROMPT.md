# AUDIT: install.sh AMFI/Taskgated race retry — CODE lens

## Change under audit

Branch: `fix/install-sh-taskgated-retry` on top of `origin/main` (v1.7.9).

One file changed: `phase3-binary/dist/install.sh` (+31 / -3).

Read the DIFF with:

```
git -C /Users/augstar/macprovider-installsh-retry diff origin/main -- phase3-binary/dist/install.sh
```

## Context — what and why

On 2026-07-03 during a fresh v1.7.9 install on an Apple M5 32 GB running
macOS 26.5, the install script hit this failure after `installer -pkg`
succeeded and Gatekeeper / stapler validation passed:

```
[macprovider-install] Package release passed Gatekeeper assessment; quarantine cleanup is not required.
bash: line 1072: 92765 Killed: 9  "$INSTALL_DIR/macprovider-cli" autotune --recommend --freshness-check --config "$CONFIG_PATH" > /dev/null
[macprovider-install] ERROR: recommendation freshness check failed before service start
```

The `Killed: 9` = SIGKILL from the kernel. Three DiagnosticReports were
written by the crash reporter:

- PID 91936 (parent — first invocation of the binary): SIGKILL,
  `namespace: CODESIGNING`, `indicator: Invalid Page`
- PID 92550 (child): SIGKILL, same CODESIGNING verdict, faulting frame
  inside `ModelRuntime.withDrainCancellation`
- PID 92765 (the freshness-check reported at bash line 1072): EXC_CRASH,
  SIGKILL, `namespace: CODESIGNING`, `indicator: Taskgated Invalid Signature`

Immediately after the install script died, running the SAME command by
hand from the SAME shell (`~/.local/bin/macprovider-cli autotune
--recommend --freshness-check --config ...`) succeeded and printed the
expected `recommendation_stale: inputs changed since ...` diagnostic.
`codesign -dv --verbose=4` on the installed binary reported a valid
Developer ID / hardened-runtime signature. No `com.apple.quarantine`
xattr present.

This is a race between the pkg installer's post-install AMFI signature
revalidation and the install script's first execve of the freshly
written binary. The AMFI cache settles within a fraction of a second,
so one retry with a short sleep is sufficient in practice — but the
current script has no retry, and a single transient AMFI SIGKILL kills
the whole install.

## The change

Add a helper `run_macprovider_cli_with_amfi_retry` in `install.sh` that:

1. Runs `"$INSTALL_DIR/macprovider-cli" "$@"`.
2. Captures the exit code via `|| rc=$?`.
3. If `rc == 137` (bash's report for a SIGKILL'd child), logs a
   diagnostic line, `sleep 2`, and re-runs the same command exactly
   once. Returns the retried exit code.
4. All other exit codes (including autotune's own `exit 10` for
   "recommendation is stale") pass through unchanged with no retry.

Wire the helper into the 3 post-install CLI call sites that could
plausibly hit this race:

- `run_autotune_recommend_apply` main path (`--recommend --apply`)
- Same function's donor-mode branch (`--recommend --apply --donor-mode`)
- `use_fresh_recommendation_if_available` (`--recommend --freshness-check`)

## CODE lens — what to audit

Focus strictly on CODE correctness of the shell script — control flow,
variable scoping, quoting, and interaction with `set -euo pipefail`.

1. **`set -e` interaction.** The script sets `set -euo pipefail` at the
   top. The helper is called from three sites; identify each and confirm
   that a non-zero return from the helper does NOT cause the whole
   script to abort by `set -e`. In particular, verify the `if
   run_...; then ... else rc=$?; ...` pattern at the freshness-check
   site actually captures the helper's exit code into `rc` correctly
   (i.e. `$?` in the `else` branch reflects the helper's return, not
   some intermediate).

2. **Exit-code pass-through.** Autotune's `--freshness-check` returns
   exit 10 when the recommendation is stale (see
   `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift` around
   line 805 / `runRecommendationFreshnessCheck`). The install script's
   caller relies on distinguishing exit 10 (stale) from any other
   non-zero (fatal). Confirm the helper preserves the CLI's original
   exit code byte-for-byte for all non-137 outcomes, including 10.

3. **137 detection correctness.** Confirm that `[ "$rc" -eq 137 ]` is
   the correct discriminator for the bash-reported SIGKILL case on
   macOS. Any concerns about other signal exits (e.g. 138 SIGBUS,
   139 SIGSEGV, 134 SIGABRT) that might also be caused by an AMFI
   race and should be retried? Argue either way with evidence — over-
   retrying (e.g. also retrying 139) risks masking legitimate crashes;
   under-retrying (137-only) may miss a race variant.

4. **Retry idempotency / side effects.** The helper re-executes the
   same command verbatim. For each of the three call sites, verify
   that a first invocation SIGKILL'd during dyld/AMFI early init
   cannot leave partial state (e.g. a partially-written
   `last-recommendation.json`, `config.yaml`, or lock file) that the
   retry would then observe or corrupt. If the AMFI SIGKILL happens
   pre-`main`, there are no side effects — but confirm from the
   crash reports and the Swift entry path.

5. **`|| rc=$?` and `set -e`.** The helper uses
   `"$INSTALL_DIR/..." "$@" || rc=$?`. Under `set -euo pipefail`,
   confirm this pattern actually captures the exit code (and doesn't
   accidentally trigger `set -e` on the failed command). Also confirm
   the second invocation inside the `if [ "$rc" -eq 137 ]` block
   correctly resets `rc=0` before the retry so a successful retry
   doesn't inherit the failed rc.

6. **Quoting and `"$@"` expansion.** The helper forwards `"$@"` to
   `macprovider-cli`. Confirm this is correctly quoted so that CLI
   arguments containing spaces (e.g. a `--config` path with a space)
   are preserved. Also confirm the log line's use of `$rc` is safe
   (numeric only, no injection risk).

7. **Sleep duration justification.** The retry sleeps 2 seconds. Is
   that long enough to reliably clear the AMFI race window? Too long
   for user experience? Note that the observed race resolves within
   sub-second in the ad-hoc reproduction; 2s is a comfortable margin
   but not so long as to be user-visible.

8. **Log message clarity.** The retry logs to stdout via `log()`. Does
   the message adequately explain what happened and give an operator
   enough context to distinguish a real bug from a transient race?

9. **Regression risk for happy-path installs.** For installs that do
   NOT hit the race, confirm the helper is a no-op (single execve, no
   sleep, no extra log). The overhead should be a single bash function
   call.

10. **Other post-install CLI invocations.** Are there OTHER places in
    `install.sh` where a first-run macprovider-cli invocation could hit
    the same AMFI race but is NOT wrapped by the helper? Enumerate them.
    (The `nohup` foreground-provider launch at ~line 1962 is one
    candidate — argue whether that path needs the helper too.)

## Bar

Report CRITICAL / HIGH / MEDIUM / LOW / INFO findings. LOW / INFO may
ship with PR-body documentation. Fixes required for CRITICAL / HIGH /
MEDIUM.

Return your findings as a structured list; do not include speculative
findings without a concrete failure scenario.
