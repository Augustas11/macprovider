#!/usr/bin/env bash
# Claude Code PreToolUse guard: live release, deploy and restart commands go
# through the scripts/ops entry points, never typed directly.
#
# Reads the hook JSON on stdin. For Bash tool calls it exits 2 (block, reason
# on stderr) when the COMMAND WORD of any simple command in the line is:
#   - gh workflow run (or gh api .../workflows/<wf>/dispatches) of
#     acceptance-candidate.yml, promote-acceptance-candidate.yml, release.yml,
#     pearl-runtime-release.yml or verify-live-coordinator-release-rollout.yml,
#     by file name, display name, or any numeric workflow id; or gh run rerun
#   - deploy-pearl-vps.sh; catalog-content-release.sh --deploy;
#     publish-native-mtp-revocations.sh --deploy; macprovider-pearl-update --apply;
#     systemctl restart / service ... restart of macprovider-coordinator
#   - gh pr create|edit|merge or git commit (any git global options) whose
#     message, inline, heredoc or --body-file/-F file, has a GitHub closing
#     keyword followed by #N, owner/repo#N or an issue/pull URL, negated or not
#   - an assignment of MACPROVIDER_OPS_ENTRYPOINT
# Wrappers (sudo, env, nohup, time, nice, ionice, timeout, xargs, systemd-run,
# eval, bash/sh -c, ssh HOST CMD) are unwrapped; read-only uses such as
# grep/rg/git log/cat/bash -n of a guarded name are allowed. Parsing lives in
# ops_guard.py.
#
# Every command is allowed when MACPROVIDER_OPS_ENTRYPOINT=1 is set in the
# hook's own environment. Malformed input is allowed (fail open): this guard
# keeps agents on the runbook route; it is not a security boundary.
set -euo pipefail

if [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = "1" ]; then
  cat >/dev/null
  exit 0
fi

exec python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ops_guard.py"
