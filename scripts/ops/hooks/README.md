# Ops guard hooks

`claude-pretooluse-ops-guard.sh` is a Claude Code `PreToolUse` hook; the
parsing is in `ops_guard.py`. It blocks a Bash call (exit 2) and names the
entry point to use when the command word of any simple command in it is:

- `gh workflow run` (or `gh api .../workflows/<wf>/dispatches`) of
  `acceptance-candidate.yml`, `promote-acceptance-candidate.yml`, `release.yml`,
  `pearl-runtime-release.yml` or `verify-live-coordinator-release-rollout.yml`,
  by file name or by display name (read from the workflow files), or of any
  numeric workflow id; and `gh run rerun`
- `deploy-pearl-vps.sh`
- `catalog-content-release.sh --deploy`
- `publish-native-mtp-revocations.sh --deploy`
- `macprovider-pearl-update --apply`
- `systemctl restart` (or `try-restart`, `reload-or-restart`) or
  `service ... restart` of `macprovider-coordinator`
- `gh pr create|edit|merge` or `git commit` (with any git global options)
  whose message, inline, in a heredoc, or in a `--body-file`/`-F` file, has a
  closing keyword (`close`, `closes`, `closed`, `fix`, `fixes`, `fixed`,
  `resolve`, `resolves`, `resolved`) followed by `#N`, `owner/repo#N` or a
  GitHub issue/pull URL. A negation does not help: GitHub closes the issue on
  "does not close #N" too.
- an assignment of `MACPROVIDER_OPS_ENTRYPOINT`

The line is split on `;`, `&`, `&&`, `|`, `||`, newlines and parentheses.
Comments and heredoc bodies are removed, and `$(...)` and backtick bodies are
checked as commands of their own. Wrappers are unwrapped: `sudo`, `doas`,
`env`, `nohup`, `time`, `nice`, `ionice`, `timeout`, `xargs`, `setsid`,
`systemd-run`, `chroot DIR`, `flock [-c]`, `su|runuser -c`, `script -c`,
`watch`, `eval`, `bash|sh -c PAYLOAD`, the remote command of `ssh HOST [--]
CMD`, and `source`/`.` (the sourced path is classified). A workflow named
through a shell expansion (`$WF`) is blocked because it cannot be checked. A guarded name
that is only an argument (`grep`, `rg`, `git log`, `cat`, `sed`, `bash -n`)
is allowed.

Every command is allowed when `MACPROVIDER_OPS_ENTRYPOINT=1` is set in the
hook's own environment; the entry points export it for the steps they run.
The guard keeps agents on the runbook route. It is not a security boundary.
Test it with `bash scripts/ops/test-ops-guard.sh`.

## Claude Code

Add this to `~/.claude/settings.json` under `hooks` (keep any existing
`PreToolUse` entries; this adds one more). The hook runs only in a
macprovider checkout. A worktree cut before the guard landed falls back to the
canonical checkout; set `MACPROVIDER_CANONICAL` if yours is not at
`$HOME/macprovider-poc`.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "d=\"${CLAUDE_PROJECT_DIR:-$PWD}\"; case \"$(git -C \"$d\" remote get-url origin 2>/dev/null)\" in *macprovider*) g=\"$d/scripts/ops/hooks/claude-pretooluse-ops-guard.sh\"; [ -f \"$g\" ] || g=\"${MACPROVIDER_CANONICAL:-$HOME/macprovider-poc}/scripts/ops/hooks/claude-pretooluse-ops-guard.sh\"; [ -f \"$g\" ] && exec bash \"$g\";; esac; cat >/dev/null; exit 0"
          }
        ]
      }
    ]
  }
}
```

## Codex

Codex has no equivalent blocking hook here, so the rule goes in its
instructions. Add this to `~/.codex/AGENTS.md`, or to the session prompt:

```markdown
## macprovider live operations

- Never type these directly: `gh workflow run` of acceptance-candidate.yml,
  promote-acceptance-candidate.yml, release.yml, pearl-runtime-release.yml or
  verify-live-coordinator-release-rollout.yml (by file, display name or id);
  `gh run rerun`; deploy-pearl-vps.sh; catalog-content-release.sh --deploy;
  publish-native-mtp-revocations.sh --deploy; macprovider-pearl-update --apply;
  systemctl restart macprovider-coordinator.
- Use the entry points instead: scripts/ops/cli-release.sh,
  scripts/ops/catalog-activate.sh, scripts/ops/pearl-runtime.sh. Run `status`,
  then `next`, then `MACPROVIDER_OPS_OWNER=<session> ... next --run`, one step at a
  time. Release the lock with scripts/ops/live-lock.sh release <session>.
- Never set MACPROVIDER_OPS_ENTRYPOINT yourself.
- Never put close/closes/closed/fix/fixes/fixed/resolve/resolves/resolved
  followed by #N in a commit message or PR title/body, even after "not". Write
  "Refs #N" or "Part of #N".
- Before running a command that matches the list above, check it with the guard:
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' |
    bash scripts/ops/hooks/claude-pretooluse-ops-guard.sh
  Exit 2 means: do not run it.
```
