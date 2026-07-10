# AUDIT: install.sh AMFI-inode refresh — ARCHITECT lens

## Change under audit

Branch: `fix/install-sh-amfi-inode-refresh` on top of `origin/main` (v1.7.10).

Read the diff with:

```
git -C /Users/augstar/macprovider-amfi-inode diff origin/main
```

See `specs/AUDIT_INSTALL_SH_AMFI_INODE_CODE_PROMPT.md` for CODE-lane
context.

## What the change does — architect-relevant summary

Extends PR #336's `run_macprovider_cli_with_amfi_retry` helper with a
third escalation step: when the 2s retry ALSO returns SIGKILL 137,
`cp/rm/cp` the binary at `$INSTALL_DIR/macprovider-cli` to give it a
new inode, then attempt one more execve.

## ARCHITECT lens — what to audit

Focus on architectural fit, scope discipline, naming, long-term
maintenance.

1. **Right layer for the fix — again.** PR #336 argued that
   `install.sh` was the right layer for the transient AMFI race
   (FLAVOR 1). Does the same argument hold for the inode-cache stuck
   rejection (FLAVOR 2)? Alternatives:
   - `.pkg` postinstall — could add its own cp/rm/cp cycle. But the
     pkg installer already wrote the file, so this would be
     re-copying from the pkg's payload cache — non-trivial.
   - `macprovider-cli` self-heal — impossible, SIGKILL is uncatchable.
   - Release-time signing pipeline — cannot address inode-cache
     invalidation issues that only manifest post-install.
   - Rely on macOS 26 point releases fixing the AMFI cache — real,
     but leaves operators broken today.

   Argue whether install.sh is still the least-bad layer for FLAVOR 2.

2. **Two failure modes lumped into one helper.** The helper now
   handles both FLAVOR 1 (transient race, 2s sleep suffices) and
   FLAVOR 2 (inode-cache stuck, needs cp/rm/cp). Argue whether this
   is right (one helper = one AMFI concern, escalate progressively)
   or wrong (should split into two named helpers for clarity: one
   `run_..._transient_amfi_retry`, one `run_..._inode_refresh_retry`).

3. **Escalation-ladder depth.** Three attempts (initial + 2s + inode
   refresh). Any risk of accumulating a fourth escalation step
   ("kernel-cache poke via `sudo kextcache -i /`", "reboot suggestion",
   etc.) over time? Recommend whether the helper should stay at 3
   steps by design or be structured to accept new steps easily.

4. **Diagnostic message clarity.** Log lines emitted at each
   escalation:
   - Attempt 1 SIGKILL: "likely a transient AMFI code-signature race
     after pkg install. Retrying once after 2s."
   - Attempt 2 SIGKILL: "the AMFI cache may be pinned to the
     pkg-installer inode. Refreshing the binary inode via cp/rm/cp
     and retrying once more."
   - Attempt 3 SIGKILL: "this is likely a genuine signature failure
     rather than the AMFI cache."

   Argue whether these messages give an operator enough context to
   triage without our documentation. Consider adding a URL to a
   knowledge-base page (yes/no — same LOW-3 argument as PR #336).

5. **Consistency with PR #336's diagnostic patterns.** PR #336's
   helper emitted diagnostics to stderr (so `>/dev/null` at the call
   site does not swallow them). This PR preserves that. Confirm.

6. **Testing regime.** 25 assertions across 10 scenarios. Contrast
   with PR #336's 16-assertion base. Are we now over-testing shell
   internals, or is this appropriate given the escalating
   fs-mutating side effects?

7. **Failure branches of the inode refresh.** The helper has multiple
   `mktemp fail → return 137`, `cp fail → return 137` branches. Each
   emits a distinct log line. Argue whether the branches are worth
   distinguishing in the log (helps operators diagnose fs issues) or
   should be simplified to one "inode refresh failed" line.

8. **Recovery instructions on catastrophic branch.** If `rm` succeeds
   but the cp-back fails, the binary at
   `$INSTALL_DIR/macprovider-cli` is gone. The helper's log tells the
   operator how to restore from `$tmp`, but `$tmp` in `mktemp` output
   is an opaque name. Should the log include the actual `$tmp` path
   value? Or is that PII / info-leak? (No, `$tmp` is a mktemp-generated
   name in the user's tempdir; not sensitive.)

9. **Committed regression test scope.** The test is now 25 assertions
   including inode-changed assertions via `ls -i`. Argue whether
   these tests should also cover fs-error branches (mktemp fail, cp
   fail, rm fail). Hermetic simulation of fs errors is possible
   (chmod 0000, read-only mount) but adds complexity.

10. **Deprecation path — when macOS fixes AMFI.** If Apple ships a
    macOS 26 point release that resolves the AMFI cache
    invalidation, this helper becomes dead code. Recommend a policy
    (tag with a removal deadline? leave as belt-and-suspenders? track
    with a dated issue?).

11. **Documentation surface.** In-file comment block explains the
    FLAVOR 1 / FLAVOR 2 distinction. Are there other docs that should
    be updated (README, SPEC-023, an existing "known macOS issues"
    page)?

12. **Memory / auto-memory system entries.** Two existing memory
    entries are relevant:
    `[[macprovider-launchd-amfi-blocker-macos-26.md]]` — about launchd
    AMFI on macOS 26.
    Argue whether a new memory entry should be added capturing the
    FLAVOR 2 discovery.

## Bar

CRITICAL / HIGH / MEDIUM must be fixed. LOW / INFO may ship with
PR-body documentation. Return findings as a structured list.
