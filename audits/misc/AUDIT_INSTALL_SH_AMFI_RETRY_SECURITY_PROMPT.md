# AUDIT: install.sh AMFI/Taskgated race retry — SECURITY lens

## Change under audit

Branch: `fix/install-sh-taskgated-retry` on top of `origin/main` (v1.7.9).

One file changed: `phase3-binary/dist/install.sh` (+31 / -3).

Read the DIFF with:

```
git -C /Users/augstar/macprovider-installsh-retry diff origin/main -- phase3-binary/dist/install.sh
```

## What the change does

Adds a helper `run_macprovider_cli_with_amfi_retry` that, when the
first invocation of the freshly-installed `~/.local/bin/macprovider-cli`
is SIGKILL'd by the kernel (bash exit 137), sleeps 2s and retries the
same command exactly once. The `install.sh` script's three post-install
CLI call sites (`--recommend --apply`, `--recommend --apply
--donor-mode`, `--recommend --freshness-check`) now flow through the
helper.

Full context (crash reports, live repro) is in
`specs/AUDIT_INSTALL_SH_AMFI_RETRY_CODE_PROMPT.md`.

## SECURITY lens — what to audit

Focus strictly on SECURITY properties: signature verification, retry
loops as a bypass mechanism, argument injection, DoS.

1. **Signature-check bypass via retry.** The kernel SIGKILL'd the
   binary because the AMFI signature check failed on the first execve.
   Argue whether a retry could legitimately succeed on a binary whose
   signature is genuinely invalid — i.e. is there any scenario where
   the first check correctly rejects a tampered binary and the second
   check spuriously accepts it? Consider: cache poisoning after a
   partial `installer -pkg`, race between staging path and final path
   during pkg extraction, AMFI cache priming attacks. If any such
   scenario is credible, the retry helper is a signature-check bypass
   and must be either scoped tighter (e.g. re-verify `codesign -v`
   before retry) or removed.

2. **`codesign -v` gate before retry.** Argue whether the helper
   should re-verify the binary's code signature via `codesign -v
   --strict "$INSTALL_DIR/macprovider-cli"` before attempting the
   retry, to establish that the binary is genuinely valid and the
   first SIGKILL was a transient AMFI cache miss rather than a real
   signature failure. Trade-off: adds latency and can itself race,
   but produces a stronger security posture.

3. **Retry count / rate.** The helper retries exactly once with a 2s
   sleep. Confirm this cannot be turned into a DoS by an attacker who
   somehow triggers repeated SIGKILL — bounded to 2 total attempts,
   so worst-case latency is `T + 2s + T`. No unbounded retry loop.

4. **`"$@"` argument handling.** The helper forwards `"$@"` to the
   CLI. Are there any argument injection risks? Note that all three
   call sites pass hardcoded flag names and a `"$CONFIG_PATH"` value.
   `CONFIG_PATH` is a script-level variable derived from `$HOME` and
   a literal path; it is not user-controllable at runtime. Confirm.

5. **Log line content.** The helper's log line includes `$rc`. `rc`
   is set only from `$?` (integer). Confirm no injection surface.

6. **Interaction with existing kill switches.** The install script
   respects `MACPROVIDER_NO_PROMPT`, `MACPROVIDER_NO_LAUNCHD`,
   `DRY_RUN`, etc. The helper does not bypass any of these — it only
   runs when the caller was already going to run the CLI. Confirm.

7. **Retry timing enables side-channel?** The 2-second sleep is a
   fixed constant, not derived from any secret. Confirm.

8. **Comparison with existing retry surfaces.** `install.sh` already
   contains other retry-adjacent surfaces (e.g. the pkg download
   retry-with-resume added in SPEC-023 v1.7.4). Argue whether the new
   helper is consistent with the existing patterns or introduces a
   novel retry semantics that operators may misunderstand.

9. **Pre-existing behavior when helper is disabled.** Before this
   change, a SIGKILL'd first invocation `die`d the install and left
   the operator's system in a partially-configured state (binary
   installed, no config, no launchd job). Argue whether that failure
   mode was itself a security concern (e.g. an operator retrying via
   an alternate path that might weaken security). If yes, the retry
   is a security POSITIVE, not just a UX fix.

10. **AMFI Taskgated race — is this a known macOS 26 primitive we
    should be reporting instead of working around?** Not required to
    file with Apple, but flag if the workaround is masking a genuine
    OS bug we might want to report.

## Bar

CRITICAL / HIGH / MEDIUM findings must be fixed. LOW / INFO may ship
with PR-body documentation. Return a structured list; no speculative
findings without a concrete attack scenario.
