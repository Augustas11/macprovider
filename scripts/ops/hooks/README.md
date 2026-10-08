# Ops guard hooks

`claude-pretooluse-ops-guard.sh` is a Claude Code `PreToolUse` hook. When an
agent types one of these commands directly, the hook blocks the Bash call
(exit 2) and names the entry point to use instead:

- `gh workflow run` (or `gh api .../dispatches`) of `acceptance-candidate.yml`,
  `promote-acceptance-candidate.yml`, `release.yml`, `pearl-runtime-release.yml`
- `deploy-pearl-vps.sh`
- `catalog-content-release.sh --deploy`
- `publish-native-mtp-revocations.sh --deploy`
- `macprovider-pearl-update --apply`
- `systemctl restart macprovider-coordinator`
- `gh pr create|edit` or `git commit` whose message, inline or in a
  `--body-file`/`-F` file, has a closing keyword (`close`, `closes`, `closed`,
  `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`) followed by `#N`
  or `owner/repo#N`. A negation does not help: GitHub closes the issue on
  "does not close #N" too.
- any command that sets `MACPROVIDER_OPS_ENTRYPOINT` itself

The hook allows invocations of `scripts/ops/*.sh`. It allows every command when
`MACPROVIDER_OPS_ENTRYPOINT=1` is set in the hook's own environment; the entry
points export it for the steps they run. The guard keeps agents on the
runbook route. It is not a security boundary. Test it with
`bash scripts/ops/test-ops-guard.sh`.

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
  promote-acceptance-candidate.yml, release.yml or pearl-runtime-release.yml;
  deploy-pearl-vps.sh; catalog-content-release.sh --deploy;
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
