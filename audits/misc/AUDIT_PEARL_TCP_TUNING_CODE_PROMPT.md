# AUDIT_PEARL_TCP_TUNING_CODE — CODE lane

Audit the diff that implements
`specs/BUILD_PEARL_TCP_TUNING_IMPL_PROMPT.md`. Read the BUILD prompt
for the behavioural contract, then read the diff.

## Your lane: CODE (shell / deploy-script correctness)

### Look for

1. **Shell correctness in the new deploy step**
   - `set -euo pipefail` inheritance (script-wide already set).
   - No unquoted variable expansions in paths / commands
     (`"$VPS_HOST"`, `"$SSH_KEY"`, etc.).
   - No word-splitting on `install -m 0644 -o root -g root ...` args.
   - Error paths use `die` / `fail` helper if one exists in the
     script (grep for existing pattern).
   - `scp` invocation matches existing scp calls in the same script
     for `-i "$SSH_KEY"` and `-P` port options (if used elsewhere).

2. **Sysctl file content**
   - Exact 4-key match with BUILD § "Sysctl file contents".
   - No trailing whitespace on non-blank lines.
   - Single trailing newline (not zero, not two).
   - Comment lines match verbatim.
   - No CRLF line endings.

3. **Verification steps**
   - `modprobe -n -v tcp_bbr` availability check runs BEFORE the
     `install`.
   - `modprobe tcp_bbr` load runs BEFORE `sysctl -p`.
   - Post-apply verification reads `net.ipv4.tcp_congestion_control`
     and matches `bbr` exactly (not `contains "bbr"`, not
     `startswith "bbr"`).
   - Each of the 4 sysctl keys is re-read and asserted against its
     expected value.
   - On any mismatch, the script fails-loud with a message that
     names the offending key AND the actual value observed.

4. **Idempotency**
   - Re-run detection is correct: `cmp -s` (or equivalent) against
     the on-disk copy before re-installing.
   - Second run produces "already applied" and exits 0 with no
     mutation.
   - No false-positive "already applied" when a previous partial
     deploy left the file but not the runtime state.

5. **Escape hatch**
   - `SKIP_TCP_TUNING=1` gate is checked at the top of step 3b/9.
   - Skip path logs a clear message ("SKIP_TCP_TUNING=1: bypassing
     TCP kernel tuning").
   - Skip does NOT count as failure (deploy continues).

6. **Test script correctness**
   - `check_pearl_tcp_test.sh` uses `set -euo pipefail`.
   - Assertions produce actionable failure messages (name the
     expected value, name the actual value).
   - Runs offline (no ssh, no sudo, no root, no /etc access).
   - Executable bit set (`chmod 0755`).

### Do NOT flag

- Placement / step-numbering (ARCHITECT lane).
- Threat model / privilege concerns (SECURITY lane).
- Anything outside the diff.

### Output format

```
STATUS: CODE lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

Each finding: file:line, defect, concrete failure scenario, fix.

## Diff to audit

`git diff` in the worktree. New files:
`phase4-coordinator/dist/sysctl.d/99-macprovider-tcp.conf`,
`phase4-coordinator/dist/test/check_pearl_tcp_test.sh`,
`specs/BUILD_PEARL_TCP_TUNING_IMPL_PROMPT.md`. Modified:
`phase4-coordinator/dist/deploy-pearl-vps.sh`.
