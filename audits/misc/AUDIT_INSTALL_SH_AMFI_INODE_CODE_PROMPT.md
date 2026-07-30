# AUDIT: install.sh AMFI-inode refresh — CODE lens

## Change under audit

Branch: `fix/install-sh-amfi-inode-refresh` on top of `origin/main` (v1.7.10).

Read the diff with:

```
git -C /Users/augstar/macprovider-amfi-inode diff origin/main
```

Two files changed:

- `phase3-binary/dist/install.sh`: extends `run_macprovider_cli_with_amfi_retry` from a 2-attempt (initial + 2s retry) helper into a 3-attempt escalation ladder (initial + 2s retry + inode-refresh retry).
- `scripts/test-install-amfi-retry.sh`: extends the regression test from 16 to 25 assertions covering the new FLAVOR 2 path.

## Context — what and why

Merged PR #336 added a helper that retries once after 2s when the first
post-install `~/.local/bin/macprovider-cli` invocation is SIGKILL'd
with a CODESIGNING / Taskgated Invalid Signature verdict. That fixed
what we now call **FLAVOR 1** — a transient AMFI signature-revalidation
race that clears within seconds.

During this session's fresh v1.7.10 install on Apple M5 macOS 26.5,
we hit a new failure mode we now call **FLAVOR 2**:

- `installer -pkg` succeeded, Gatekeeper accepted the package, stapler
  validated.
- First invocation of `~/.local/bin/macprovider-cli` → SIGKILL 137
  (existing helper caught it, logged, slept 2s).
- 2s retry → SIGKILL 137 (existing helper logged, gave up).
- The install script bailed with `die 6 "recommendation freshness
  check failed before service start"`.
- BUT: direct invocation of `~/.local/bin/macprovider-cli --version`
  in a fresh shell — minutes later, well past the 2s window — was
  ALSO SIGKILL'd persistently.
- `codesign --verify --deep --strict` reported the binary is valid
  and satisfies its designated requirement.
- `cp ~/macprovider/macprovider-cli /tmp/mp-cli-test && chmod +x
  /tmp/mp-cli-test && /tmp/mp-cli-test --version` → **succeeded** and
  printed `1.7.10`.
- `mv ~/macprovider/macprovider-cli ~/macprovider/macprovider-cli.bak
  && mv ...bak macprovider-cli && ~/macprovider/macprovider-cli
  --version` → **still SIGKILL'd** (mv preserves inode).
- `rm ~/macprovider/macprovider-cli && cp /tmp/mp-cli-test
  ~/macprovider/macprovider-cli && chmod +x
  ~/macprovider/macprovider-cli && ~/macprovider/macprovider-cli
  --version` → **succeeded** and printed `1.7.10`.

Diagnosis: the AMFI kernel cache had a stuck rejection pinned to the
specific inode `installer -pkg` created. `rm` + fresh `cp` gives the
file a new inode; AMFI re-evaluates the signature against the new
inode and passes.

## The change

Extend the escalation ladder:

```
attempt 1: run
  └── 137 → log + sleep 2 + attempt 2 (FLAVOR 1 fix)
      └── 137 → log + inode-refresh via cp/rm/cp + attempt 3
          │           (FLAVOR 2 fix)
          └── 137 → log "genuine signature failure" + return 137
Any non-137 rc anywhere returns immediately.
```

Inode refresh:

```bash
tmp="$(mktemp -t macprovider-cli-inode-refresh 2>/dev/null || mktemp)"
cp "$INSTALL_DIR/macprovider-cli" "$tmp"
rm -f "$INSTALL_DIR/macprovider-cli"
cp "$tmp" "$INSTALL_DIR/macprovider-cli"
chmod +x "$INSTALL_DIR/macprovider-cli"
rm -f "$tmp"
```

Each filesystem step is failure-guarded; on error the helper logs the
specific failure mode and returns 137.

## CODE lens — what to audit

Focus strictly on CODE correctness of the shell script — control flow,
filesystem safety, `set -e` interaction, variable quoting.

1. **Filesystem-error path safety.** For each failure branch inside the
   inode-refresh block (`mktemp` failed, `cp` to tempfile failed, `rm`
   of original failed, `cp` back failed, `chmod` failed), trace the
   resulting filesystem state. In particular, the `rm` of the original
   followed by a failed `cp` back leaves `$INSTALL_DIR/macprovider-cli`
   MISSING — the helper's log message tells the operator how to
   restore from `$tmp`, but the `$tmp` file is NOT cleaned up in that
   branch. Confirm this is intentional (so the operator can recover)
   and NOT a bug (so `/tmp` doesn't leak).
2. **`mktemp` fallback.** The line
   `mktemp -t macprovider-cli-inode-refresh 2>/dev/null || mktemp`
   handles the case where `-t` is unsupported. Confirm both invocations
   are safe (no template injection, no wide-open-permissions).
3. **`cp` preserves mode / xattrs / signature?** Argue whether the
   `cp` used preserves the binary's code-signature blob correctly.
   Mach-O binaries embed the signature in the file; `cp` reads/writes
   file contents byte-for-byte, so the signature bytes are preserved.
   Confirm.
4. **`chmod +x` after cp-back.** The `cp` copies file mode from source
   (which had +x after the initial install), so `chmod +x` is
   theoretically redundant. But `cp` on macOS defaults to NOT copying
   mode unless `-p` is passed. Confirm the explicit `chmod +x` is
   correct + necessary.
5. **`$INSTALL_DIR` quoting.** `$INSTALL_DIR` is script-level; confirm
   correct quoting in the new `cp`/`rm` calls.
6. **`set -e` interaction with `||`.** The helper uses `|| rc=$?`
   pattern to capture exit codes without triggering `set -e` on
   non-zero. Every new shell command that could plausibly fail is
   either `!`-guarded or captures rc. Confirm no path silently
   triggers set -e.
7. **`ls -i` in the test.** The test uses `ls -i ... | awk` to extract
   inode numbers. Argue whether this is portable enough (works on both
   BSD `ls` = macOS and GNU `ls` = Linux CI). shellcheck flagged
   SC2012 INFO ("use find"); is that worth adopting or is `ls -i`
   simpler + still correct?
8. **Test mock survivability across cp/rm/cp.** The test mock is a
   bash script. When the helper does `cp $tmp $INSTALL_DIR/mock`,
   the mock's content is preserved verbatim, so the attempt-3 mock
   still reads its counter from `$COUNTER_FILE` and behaves per the
   scenario. Confirm this is watertight (e.g., no relative paths or
   embedded absolute paths that would break after re-copy).
9. **Ordering — inode-refresh log BEFORE the actual cp/rm/cp.** The
   log line "AMFI cache may be pinned to the pkg-installer inode.
   Refreshing the binary inode via cp/rm/cp and retrying once more."
   fires before the filesystem work starts. If the fs work fails, the
   log line reads as a lie ("Refreshing" is present tense but the
   refresh may have failed). Argue whether to add a "refresh
   succeeded / failed" follow-up log line for symmetry.
10. **Regression test coverage sufficiency.** 25 assertions across 10
    scenarios. Are there scenarios missing?
    - Attempt 2 hits SIGKILL, inode refresh COPY-fails → attempt 3
      does not run (existing helper returns 137 with a specific log).
      Is this tested?
    - Attempt 2 hits SIGKILL, inode refresh MKTEMP-fails → attempt
      3 does not run.
    - Are the "cp/rm/cp fs-error" branches tested? Not currently;
      argue whether they should be. Simulating fs errors hermetically
      is tricky (e.g., point to a read-only path? use `chmod -w`?).

## Bar

Report CRITICAL / HIGH / MEDIUM / LOW / INFO findings. LOW / INFO may
ship with PR-body documentation. Fixes required for CRITICAL / HIGH /
MEDIUM. Return findings as a structured list; no speculative findings
without a concrete failure scenario.
