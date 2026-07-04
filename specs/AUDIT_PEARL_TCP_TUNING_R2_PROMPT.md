# AUDIT_PEARL_TCP_TUNING_R2 — three lanes, ROUND 2

Round 1 audit findings that were fixed:

- **ARCHITECT M1** — verification enumerated keys inline (spec
  violation) → fixed by parsing `$tmp_conf` at deploy time and
  looping over parsed pairs.
- **ARCHITECT M2** — no BBR boot persistence → fixed by adding
  `phase4-coordinator/dist/modules-load.d/tcp_bbr.conf` +
  matching install / apply / verify steps.
- **ARCHITECT M3** — no detection of historical `*macprovider*`
  sysctl artifacts → fixed by WARN-level scan of `/etc/sysctl.d/`
  before install.
- **SECURITY M** — no rollback command in partial-apply failure
  messages → fixed by adding explicit rollback text to each of
  the three failure sites (sysctl -p failure, per-key mismatch,
  BBR verification mismatch); NOT added to the SKIP path or BBR-
  module-missing path (nothing was mutated in those).

R1 LOW / INFO findings ship as-is with PR-body documentation and
are NOT fixed in this round:

- CODE R1 LOW — `SKIP_TCP_TUNING=1` log-message wording nit.
- SECURITY R1 LOW — precedence collision check against later-
  precedence sysctl files.
- ARCHITECT R1 LOW — Makefile scope (intentional, wires test into
  test-dist).

## Your task

Run the CODE, SECURITY, and ARCHITECT audit lanes against the
R1 → R2 delta only. Do not re-litigate R1 findings; do not re-
audit code that R1 already accepted.

### CODE R2 focus

- The `while IFS='=' read -r key expected_value` loop over
  `$tmp_conf` correctly handles: blank lines, `#` comments,
  leading/trailing whitespace, missing `=` sign, keys/values with
  embedded spaces (there are none in this file but the code must
  not corrupt if there were).
- The BBR module load site invokes `modprobe tcp_bbr` on Pearl
  (not on the operator's Mac).
- The `install` invocation for `modules-load.d/tcp_bbr.conf`
  uses the same `-m 0644 -o root -g root` shape as the sysctl
  install.
- The historical-file detection loop uses `find`, `ls`, or shell
  glob without word-splitting bugs.
- The rollback message contains the canonical shell command
  string exactly as the operator would paste it — no shell
  metacharacters that would corrupt the printed command.

### SECURITY R2 focus

- The new `find`/`ls` invocation for historical files does NOT
  execute anything the found files contain (no `source`, no
  `. `). It only lists and logs.
- The rollback command text does NOT include a `sudo curl … | sh`
  or any remote-fetch step. It must be a purely local rm + sysctl
  --system.
- Adding `/etc/modules-load.d/tcp_bbr.conf` on Pearl does not
  expose any new listening service or open port.
- The new artifact file mode is `0644` (world-readable is fine
  for a kernel module load list).

### ARCHITECT R2 focus

- The file-as-source-of-truth pattern (M1 fix) is generic enough
  that adding a fifth sysctl key to the `.conf` file would work
  without touching the shell.
- `modules-load.d/tcp_bbr.conf` naming and placement match the
  existing `sysctl.d/` sibling.
- The historical-file WARN message shape (M3 fix) matches the
  existing `WARN:` conventions elsewhere in the same script.
- Rollback message includes BOTH files (`sysctl.d/` and
  `modules-load.d/`) so a partial-apply rollback covers both.

### Do NOT flag

- Anything already accepted in R1.
- R1 LOW / INFO findings.
- Anything outside the R1 → R2 delta.

## Output

Three status lines, one per lane:

```
STATUS: CODE lane R2 — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
STATUS: SECURITY lane R2 — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
STATUS: ARCHITECT lane R2 — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

## Diff to audit

`git diff` in the worktree. R2 delta includes:
- `phase4-coordinator/dist/deploy-pearl-vps.sh`: parse-loop, BBR
  boot install, historical-file WARN scan, rollback message.
- New `phase4-coordinator/dist/modules-load.d/tcp_bbr.conf`.
- `phase4-coordinator/dist/test/check_pearl_tcp_test.sh`: new
  assertions.
