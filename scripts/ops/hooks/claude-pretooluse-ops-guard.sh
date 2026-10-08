#!/usr/bin/env bash
# Claude Code PreToolUse guard: live release, deploy and restart commands go
# through the scripts/ops entry points, never typed directly.
#
# Reads the hook JSON on stdin. For Bash tool calls, exits 2 with a message on
# stderr (which blocks the call and is shown to the agent) when the command:
#   - dispatches acceptance-candidate.yml, promote-acceptance-candidate.yml,
#     release.yml or pearl-runtime-release.yml (gh workflow run, or gh api .../dispatches)
#   - runs deploy-pearl-vps.sh, catalog-content-release.sh --deploy,
#     publish-native-mtp-revocations.sh --deploy, macprovider-pearl-update --apply
#     or systemctl restart macprovider-coordinator
#   - is gh pr create|edit or git commit whose message (inline, heredoc, or a
#     --body-file / -F file) has a GitHub closing keyword followed by #N or
#     owner/repo#N, negated or not ("does not close #12" still closes #12)
#   - tries to set MACPROVIDER_OPS_ENTRYPOINT itself
#
# Allowed: everything else, any command when MACPROVIDER_OPS_ENTRYPOINT=1 is
# set in the hook's own environment, and invocations of scripts/ops/*.sh.
# Exit 0 = allow; exit 2 = block. Malformed input is allowed (fail open): this
# guard only enforces the runbook route; it is not a security boundary.
set -euo pipefail

if [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = "1" ]; then
  cat >/dev/null
  exit 0
fi

exec python3 -c '
import json, os, re, shlex, sys

try:
    event = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if event.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (event.get("tool_input") or {}).get("command") or ""
if not cmd.strip():
    sys.exit(0)
cwd = event.get("cwd") or os.getcwd()

def block(reason, route=None, advice=None):
    if advice is None:
        advice = "Use %s instead (status, then next, then next --run). See scripts/ops/README.md." % route
    sys.stderr.write("BLOCKED by scripts/ops/hooks/claude-pretooluse-ops-guard.sh: %s\n%s\n" % (reason, advice))
    sys.exit(2)

if re.search(r"\bMACPROVIDER_OPS_ENTRYPOINT\s*=", cmd):
    block("the entry-point marker is set by scripts/ops only, never by hand", "scripts/ops/<train>.sh")

# Split into simple-command segments on shell separators so a flag in one
# command does not satisfy a pattern in another.
segments = [s for s in re.split(r"\|\||&&|[;|\n]|\$\(|`", cmd) if s.strip()]

CLI = "scripts/ops/cli-release.sh"
CAT = "scripts/ops/catalog-activate.sh"
RT = "scripts/ops/pearl-runtime.sh"
WORKFLOWS = {
    "acceptance-candidate": CLI,
    "promote-acceptance-candidate": CLI,
    "release": CLI,
    "pearl-runtime-release": RT,
}
wf_re = re.compile(r"(?<![\w.-])(acceptance-candidate|promote-acceptance-candidate|release|pearl-runtime-release)\.ya?ml(?![\w.-])")

for seg in segments:
    s = seg.strip()
    if re.search(r"(^|[\s/])scripts/ops/[\w.-]+\.sh\b", s) and not re.search(r"\bgh\s|deploy-pearl-vps|systemctl", s):
        continue
    if re.search(r"\bgh\b.*\bworkflow\s+run\b", s) or (re.search(r"\bgh\s+api\b", s) and "/dispatches" in s):
        m = wf_re.search(s)
        if m:
            block("direct dispatch of %s.yml" % m.group(1), WORKFLOWS[m.group(1)])
    if re.search(r"deploy-pearl-vps\.sh", s):
        block("direct deploy-pearl-vps.sh", CAT + " (catalog) or " + RT + " (runtime)")
    if re.search(r"catalog-content-release\.sh\b", s) and re.search(r"(^|\s)--deploy\b", s):
        block("direct catalog-content-release.sh --deploy", CAT)
    if re.search(r"publish-native-mtp-revocations\.sh\b", s) and re.search(r"(^|\s)--deploy\b", s):
        block("direct publish-native-mtp-revocations.sh --deploy", CAT)
    if re.search(r"macprovider-pearl-update\b", s) and re.search(r"(^|\s)--apply\b", s):
        block("direct macprovider-pearl-update --apply", RT)
    if re.search(r"\bsystemctl\b.*\brestart\b.*\bmacprovider-coordinator\b", s):
        block("direct coordinator restart", CAT + " or " + RT)

# Closing keywords in PR bodies/titles and commit messages.
is_pr = re.search(r"\bgh\s+pr\s+(create|edit)\b", cmd)
is_commit = re.search(r"\bgit\s+(-C\s+\S+\s+)?commit\b", cmd)
if is_pr or is_commit:
    text = cmd
    try:
        tokens = shlex.split(cmd, comments=False, posix=True)
    except ValueError:
        tokens = []
    for i, tok in enumerate(tokens[:-1]):
        if tok in ("--body-file", "-F", "--file"):
            path = tokens[i + 1]
            if path != "-":
                path = os.path.join(cwd, os.path.expanduser(path))
                try:
                    with open(path, errors="replace") as f:
                        text += "\n" + f.read(200000)
                except OSError:
                    pass
    kw = re.compile(
        r"\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b[\s:]*(\(?\s*)([\w.-]+/[\w.-]+)?#\d+",
        re.IGNORECASE)
    m = kw.search(text)
    if m:
        block(
            "message contains the GitHub closing keyword \"%s\"; GitHub closes the issue on merge, even after a negation" % m.group(0).strip(),
            advice="Reference the issue without a closing keyword, for example \"Refs #N\" or \"Part of #N\".")
sys.exit(0)
'
