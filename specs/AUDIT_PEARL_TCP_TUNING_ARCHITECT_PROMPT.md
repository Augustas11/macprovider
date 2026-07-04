# AUDIT_PEARL_TCP_TUNING_ARCHITECT — ARCHITECT lane

Audit the diff that implements
`specs/BUILD_PEARL_TCP_TUNING_IMPL_PROMPT.md`.

## Your lane: ARCHITECT

### Look for

1. **Placement in deploy script**
   - Sub-step "3b/9" is inserted between existing "3/9" and "4/9"
     WITHOUT renumbering. Existing step 4-9 numbers stay stable.
   - Sub-step lands AFTER user + dirs setup (so `root:root` owner
     is available) and BEFORE nginx install (so kernel-level
     changes are settled before any long-running proxying starts).

2. **Idempotency in the pipeline shape**
   - Matches the pattern of other idempotent steps in the same
     script (e.g. certbot renew, systemd unit reload).
   - Detection method (cmp on file / value comparison) matches the
     drift-detection approach used by the existing step 1b.

3. **File organisation**
   - New directory `phase4-coordinator/dist/sysctl.d/` matches the
     naming style of `phase4-coordinator/dist/nginx-snippets/` and
     `phase4-coordinator/dist/monitor/`.
   - Test file lives under `phase4-coordinator/dist/test/` matching
     the existing shell-test convention.
   - Test naming (`check_pearl_tcp_test.sh`) matches
     `check_pearl_tls_test.sh` etc.

4. **Sysctl file precedence**
   - `99-` prefix reserves the highest position in `/etc/sysctl.d/`
     load order. Confirm no other deploy artifact wants that
     precedence.
   - No overlap with `/etc/sysctl.d/*macprovider*` from any past
     deploy. If historical files exist, deploy should log that fact
     and either upgrade or refuse fail-loud.

5. **Extensibility**
   - Would adding a fifth sysctl key later require re-writing the
     step? Verify by inspection that the step handles the file as a
     whole (install + apply + verify each key) rather than
     enumerating keys inline in the shell.
   - The verification loop reads each expected key from a data
     structure (associative array or here-doc) so adding a fifth
     value only touches the sysctl.conf file, not the script.

6. **`SKIP_TCP_TUNING` naming consistency**
   - Env var name matches existing skips (`FORCE_RESTART`,
     `SKIP_C2_CHECK`, `STRICT_PROVENANCE`, etc.) — same case, same
     0/1 semantics.
   - Documented at top of script alongside the other env vars.

7. **BBR module handling — deploy-time vs boot-time**
   - `modprobe tcp_bbr` at deploy time loads the module now, but
     the sysctl file at `/etc/sysctl.d/` alone does NOT ensure the
     module is loaded across reboots. Standard idiom is to also
     drop a `/etc/modules-load.d/tcp_bbr.conf` file OR use
     `modprobe --first-time` in the sysctl config.
   - Verify one of these is done, OR document explicitly why it's
     acceptable to rely on `tcp_bbr` being loaded on-demand at
     first BBR socket creation (which the kernel does automatically
     when `net.ipv4.tcp_congestion_control=bbr` is applied via
     sysctl.d).

8. **Scope discipline**
   - Diff touches only:
     - `phase4-coordinator/dist/sysctl.d/99-macprovider-tcp.conf`
       (new)
     - `phase4-coordinator/dist/deploy-pearl-vps.sh` (modified)
     - `phase4-coordinator/dist/test/check_pearl_tcp_test.sh` (new)
     - `specs/BUILD_PEARL_TCP_TUNING_IMPL_PROMPT.md` (new)
   - No changes to nginx configs, gateway configs, coord Go code,
     provider Swift code, systemd unit files, or CI workflows.

### Do NOT flag

- Shell correctness (CODE lane).
- Threat model (SECURITY lane).
- Findings outside the diff.

### Output

```
STATUS: ARCHITECT lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

Each finding: file:line, design concern, future scenario, fix.

## Diff to audit

`git diff` in the worktree.
