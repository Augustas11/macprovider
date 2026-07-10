# AUDIT_PEARL_TCP_TUNING_SECURITY — SECURITY lane

Audit the diff that implements
`specs/BUILD_PEARL_TCP_TUNING_IMPL_PROMPT.md`.

## Your lane: SECURITY

### Look for

1. **Privilege escalation surface**
   - The `install`, `modprobe`, and `sysctl` calls are all run as
     `root` (the deploy script runs as root on Pearl per its existing
     invocation model). Verify no non-root path executes any of them.
   - No path where a user-writable temp path (e.g. `/tmp/...`) is
     re-read after upload with `install` — race between upload and
     apply on shared `/tmp`. Prefer `/root/` or use `mktemp -d`.

2. **Path injection**
   - The fixed literal `/etc/sysctl.d/99-macprovider-tcp.conf`
     matches the file naming convention (99- prefix) and does not
     collide with any Ubuntu-shipped file.
   - No interpolation of user-controlled variables into the target
     path.

3. **File integrity between upload and apply**
   - After `scp`, before `install`, no attacker with write access
     to `/tmp` can substitute the file.
   - Preferred mitigation: upload to a root-owned dir (`/root/` or
     `mktemp -d -p /root/`), NOT `/tmp/`.

4. **sysctl.d precedence collisions**
   - `99-` prefix: highest precedence in `/etc/sysctl.d/` load order.
     Verify no `/etc/sysctl.d/99-*` file already ships with Ubuntu
     or with a package the deploy might install later that would
     conflict on the same 4 keys.
   - If a conflict exists, deploy should log a warning.

5. **BBR + module-load side effects**
   - Loading `tcp_bbr` on a running server is safe — no in-flight
     connection reset. Confirm no `sysctl` command that would
     reset active TCP connections.
   - Applying `tcp_congestion_control=bbr` to a live host does not
     require a coord / gateway restart.

6. **Escape hatch abuse**
   - `SKIP_TCP_TUNING=1` bypass MUST log clearly (audit trail) so
     an operator retrospectively knows the tuning was skipped.
   - The bypass cannot be flipped mid-deploy such that the rest of
     the deploy proceeds with mixed / inconsistent state.

7. **No new listening service or open port**
   - The sysctl changes affect kernel TCP behaviour only. No new
     socket, no new listening port, no new privileged service.
     Verify by inspection.

8. **Log injection / secret exfil**
   - Log lines do NOT include sensitive values (there aren't any
     here, but verify the modprobe stderr isn't dumped to a
     buyer-accessible log).
   - `/etc/sysctl.d/99-macprovider-tcp.conf` is world-readable (mode
     0644). Content is not sensitive; kernel tuning is public
     information. Verify no accidental secret embedded.

9. **Rollback safety**
   - If step 3b/9 fails after `sysctl -p` succeeded but before
     verification passed, the applied values persist on the box.
     Deploy should surface this state clearly so the operator can
     roll back manually with `rm /etc/sysctl.d/99-macprovider-tcp.conf
     && sysctl --system`.
   - Verify the failure message includes the rollback command.

### Do NOT flag

- Non-security correctness (CODE lane).
- Naming / placement (ARCHITECT).
- Findings outside the diff.

### Output

```
STATUS: SECURITY lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

Each finding: file:line, threat model, concrete scenario, mitigation.

## Diff to audit

`git diff` in the worktree.
