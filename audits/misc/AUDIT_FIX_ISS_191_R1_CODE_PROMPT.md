# AUDIT — Fix iss-191 (watchdog fleet-wide) — R1 CODE lane

## Scope

Branch `fix/iss-191-watchdog-fleet` (worktree
`/Users/augstar/macprovider-fix-191`). Read `git diff origin/main..HEAD`.

Files in scope:

- `ops/macprovider-watchdog/watchdog.sh` (new)
- `ops/macprovider-watchdog/install.sh` (new standalone installer)
- `ops/macprovider-watchdog/uninstall.sh` (new)
- `ops/macprovider-watchdog/live.streamvc.macprovider-watchdog.plist.template` (new)
- `ops/macprovider-watchdog/README.md` (new)
- `phase3-binary/dist/install.sh` (existing; added `install_watchdog` function + call site)
- `phase3-binary/dist/uninstall.sh` (existing; added watchdog removal block)
- `OPS.md` (existing; added §11)

## Context

Closes issue #191: the internal `ops/macprovider-watchdog/`
LaunchAgent — a netstat-based 60s check for ESTABLISHED outbound
TCP to coordinator.streamvc.live — was hardcoded to one operator's
provider id. This PR generalizes it across every fleet operator by:

1. Reading `provider_id` from `~/.config/macprovider/config.yaml`
   at every tick.
2. Inlining the watchdog into the public
   `get.streamvc.live/install.sh` flow so every install gets it.
3. Removing the watchdog when the main provider uninstaller runs.

The watchdog is companion to PR #204 (in-process bounded send +
Darwin.exit(1)); they are independent defenses.

## You are the CODE auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **0 C/H/M**
on diff-introduced surface.

Specifically check:

1. **Shell-injection / yaml-injection.** `read_provider_id` uses awk
   on `~/.config/macprovider/config.yaml`. A malicious config (e.g.
   provider_id with backticks / `$()` / shell metacharacters) is
   then used as a variable in `log "...provider_id=${pid}..."`. The
   value never reaches `eval` or unquoted command position — confirm
   that's actually the case for both watchdog.sh and the inlined
   copy in install.sh.
2. **launchctl kickstart semantics.** `kickstart -k` is the right
   verb for "restart this LaunchAgent now". Confirm the exit-code
   handling (`|| log ...`) is sound and doesn't mask a real failure
   the operator would want to see.
3. **netstat parsing.** macOS BSD netstat output: `Proto Recv-Q
   Send-Q Local-Address Foreign-Address (state)`. The awk matches
   `$5 == target` where target is `<ip>.<port>`. Verify the column
   index is stable across macOS versions in scope (the operator
   fleet is on macOS 14-26). Any failure mode where netstat emits
   a different column shape that would silently false-pass or
   false-fail?
4. **`set -euo pipefail` interaction.** The script has `set -euo
   pipefail`. The `has_established_conn` function returns 1 on
   "no connection found" (intentional). Used in `if cmd; then ...`
   which is allowed under `set -e`. Confirm no other place in the
   script silently exits on a non-zero return that should be
   handled.
5. **idempotency.** The standalone `ops/.../install.sh` and the
   inlined `install_watchdog` in main installer both
   `bootout`-before-`bootstrap` the LaunchAgent. Re-running either
   must not double-load the plist, leak a stale plist file, or
   leave the LaunchAgent in a partially-loaded state.
6. **inline duplication risk.** The watchdog script is duplicated
   between `ops/macprovider-watchdog/watchdog.sh` and the inlined
   heredoc in `phase3-binary/dist/install.sh:write_watchdog_script`.
   They MUST stay in sync; is there a flag in the diff that they
   are already out of sync (e.g. a comment or behavior diff)?
7. **Uninstall safety.** `phase3-binary/dist/uninstall.sh` now
   `rm -rf "$WATCHDOG_DIR"` (`$HOME/.local/share/macprovider-watchdog`).
   Confirm that path is constrained to that prefix and cannot be
   redirected by env var (the inline uninstall block uses the
   constant value; the standalone `ops/.../uninstall.sh` uses an
   env var but with a prefix guard).
8. **Dry-run path.** The standalone install.sh's `--dry-run` path
   prints the rendered plist and exits without modifying disk.
   Confirm the inlined `install_watchdog` also honors `DRY_RUN=1`
   from the parent install.sh.
9. **plutil -lint required.** Both install paths call `plutil -lint`
   on the rendered plist. Confirm the lint pre-flight catches a
   broken substitution before launchctl bootstrap is attempted.

Out of scope: the underlying issue #189 fix (already shipped in PR
#204) and any larger Phase-B watchdog redesign (coordinator-side
pool poll etc., which the issue explicitly defers).

## Output format

For each finding:

- **SEVERITY** (CRITICAL/HIGH/MEDIUM/LOW/NOTE)
- **Location** (file:line)
- **What** (one sentence)
- **Why it matters** (one sentence)
- **Suggested fix** (one or two lines)

End with `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
